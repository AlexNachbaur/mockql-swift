/// The transport-independent MockQL engine: a validated schema, seeded in-memory state,
/// registered mutation handlers, generators, and subscription fan-out.
///
/// Use the engine directly for in-process execution (no networking), or wrap it in
/// `MockQLServer` from the `MockQL` module to serve HTTP and WebSocket clients.
public final class MockQLEngine: Sendable {
    /// The validated schema being served.
    public let schema: Schema
    /// The server's in-memory state.
    public let store: StateStore
    private let generators: GeneratorRegistry
    private let handlers: [String: MutationHandler]
    private let filters: [String: FieldFilter]
    private let resolvers: [String: FieldResolver]
    /// Whether to attach per-field filtering diagnostics under `extensions.mockql`.
    private let diagnosticsEnabled: Bool
    private let hub = SubscriptionHub()

    /// Creates an engine.
    ///
    /// - Parameters:
    ///   - schemaSource: The SDL schema to serve. Omit it to define the schema entirely from
    ///     the configuration block's `Query`/`Object`/`Mutation` declarations.
    ///   - seedSource: Initial state, loaded and validated before the engine is ready.
    ///   - generatorBindings: Generators keyed by `"Type.field"` for fields absent from seed
    ///     data.
    ///   - serverSeed: Seed for deterministic data generation; equal seeds generate equal data.
    ///   - diagnostics: Whether to report, under `extensions.mockql.fields`, how each list- and
    ///     connection-typed field was filtered (see ``FieldDiagnostics``). Off by default.
    ///   - store: The state store to use — pass a sibling service's store (e.g. MockREST's) to
    ///     share state across protocols on one `MockHost`. Omit for a store of its own.
    ///   - configuration: Declarations — mutation handlers, seeds, roots, generator bindings,
    ///     and (without an SDL schema) the schema shape itself.
    public init(
        schema schemaSource: SchemaSource? = nil,
        seed seedSource: SeedSource? = nil,
        generators generatorBindings: [String: FieldGenerator] = [:],
        serverSeed: UInt64 = 0,
        diagnostics: Bool = false,
        store: StateStore? = nil,
        @MockQLBuilder configuration: () -> [any MockQLDeclaration] = { [] }
    ) async throws {
        let baseSchema = try schemaSource?.loadSchema()
        let assembled = try DSLAssembly.assemble(configuration(), baseSchema: baseSchema)
        self.schema = assembled.schema
        self.handlers = assembled.handlers
        self.filters = assembled.filters
        self.resolvers = assembled.resolvers
        self.diagnosticsEnabled = diagnostics

        var bindings = assembled.generatorBindings
        for (key, generator) in generatorBindings {
            guard bindings[key] == nil else {
                throw MockQLError(
                    category: .configuration,
                    message: "Generator for '\(key)' is bound both in the generators dictionary and in the "
                        + "configuration block; keep one"
                )
            }
            bindings[key] = generator
        }
        let registry = GeneratorRegistry(bindings: bindings, serverSeed: serverSeed)
        try registry.validate(against: assembled.schema)
        self.generators = registry

        var data = StoreData()
        if let seedSource {
            data = try SeedLoader.load(seedSource, schema: assembled.schema)
        }
        if let dslSeeds = assembled.seedDocument {
            data = try SeedLoader.load(.document(dslSeeds), schema: assembled.schema, initial: data)
        }
        if let shared = store {
            // A shared store may already hold a sibling service's seed; merge, don't replace.
            await shared.merge(data)
            self.store = shared
        } else {
            let own = StateStore()
            await own.load(data)
            self.store = own
        }
    }

    // MARK: - Execution

    /// Executes a query or mutation and returns the spec-format response. Never throws —
    /// failures come back in the response's `errors`.
    public func execute(_ request: GraphQLRequest) async -> GraphQLResponse {
        let document: ExecutableDocument
        let operation: OperationNode
        let variables: [String: GraphQLValue]
        do {
            document = try parseDocument(request.query)
            operation = try document.operation(named: request.operationName)
            variables = try coerceVariables(operation.variableDefinitions, provided: request.variables)
        } catch let error as GraphQLError {
            return .requestFailed([error])
        } catch {
            return .requestFailed([GraphQLError(message: String(describing: error))])
        }
        switch operation.type {
        case .query:
            return await executeQuery(operation, document: document, variables: variables)
        case .mutation:
            return await executeMutation(operation, document: document, variables: variables)
        case .subscription:
            return .requestFailed([
                GraphQLError(
                    message: "Subscriptions can't be executed with execute(_:); use subscribe(_:) "
                        + "or connect over the graphql-transport-ws WebSocket protocol"
                )
            ])
        }
    }

    private func executeQuery(
        _ operation: OperationNode,
        document: ExecutableDocument,
        variables: [String: GraphQLValue]
    ) async -> GraphQLResponse {
        var executor = makeExecutor(
            data: await store.snapshot(),
            fragments: document.fragments,
            variables: variables,
            declaredVariables: operation.declaredVariableNames
        )
        let data = executor.executeQuery(selections: operation.selectionSet)
        return GraphQLResponse(
            data: data,
            errors: executor.errors,
            extensions: executor.diagnostics.mockQLExtensions
        )
    }

    /// An executor over `data` carrying this engine's hooks and diagnostics setting, so a field
    /// behaves the same whether it is reached from a query, a mutation payload, or a
    /// subscription event.
    private func makeExecutor(
        data: StoreData,
        fragments: [String: FragmentDefinitionNode],
        variables: [String: GraphQLValue],
        declaredVariables: Set<String>
    ) -> Executor {
        Executor(
            schema: schema,
            generators: generators,
            data: data,
            fragments: fragments,
            variables: variables,
            declaredVariables: declaredVariables,
            filters: filters,
            resolvers: resolvers,
            diagnosticsEnabled: diagnosticsEnabled
        )
    }

    private func executeMutation(
        _ operation: OperationNode,
        document: ExecutableDocument,
        variables: [String: GraphQLValue]
    ) async -> GraphQLResponse {
        guard let mutationTypeName = schema.mutationTypeName,
            let mutationType = schema.objectType(named: mutationTypeName)
        else {
            return .requestFailed([GraphQLError(message: "Schema defines no mutation root type")])
        }
        let declaredVariables = operation.declaredVariableNames
        // Field collection and argument coercion are pure schema work and read no state, so the
        // planner runs over an empty store rather than taking a snapshot it would never look at.
        var planner = makeExecutor(
            data: StoreData(),
            fragments: document.fragments,
            variables: variables,
            declaredVariables: declaredVariables
        )
        // Collected exactly as a query's root is: `@skip`/`@include` are honored, fragments are
        // expanded, and fields sharing a response key are grouped so their handler runs once.
        let rootFields: [(key: String, nodes: [FieldNode])]
        do {
            rootFields = try planner.collectRootFields(operation.selectionSet, typeName: mutationTypeName)
        } catch let error as GraphQLError {
            return GraphQLResponse(data: .null, errors: [error])
        } catch {
            return GraphQLResponse(data: .null, errors: [GraphQLError(message: String(describing: error))])
        }

        var result: [String: GraphQLValue] = [:]
        var errors: [GraphQLError] = []
        var diagnostics: [String: FieldDiagnostics] = [:]
        var dataIsNull = false

        for (responseKey, nodes) in rootFields {
            guard let field = nodes.first else { continue }
            let path: [GraphQLPathSegment] = [.field(responseKey)]
            if field.name == "__typename" {
                result[responseKey] = .string(mutationTypeName)
                continue
            }
            guard let fieldDef = mutationType.field(named: field.name) else {
                let clause = Suggestion.clause(for: field.name, in: mutationType.fields.map(\.name))
                errors.append(
                    GraphQLError(
                        message: "Unknown mutation field '\(field.name)'.\(clause)",
                        locations: [field.location],
                        path: path
                    )
                )
                result[responseKey] = .null
                continue
            }
            guard let handler = handlers[field.name] else {
                let clause = Suggestion.clause(for: field.name, in: handlers.keys)
                errors.append(
                    GraphQLError(
                        message: "No handler registered for mutation '\(field.name)'; register one with "
                            + "Mutation(\"\(field.name)\") { input, state in … }.\(clause)",
                        locations: [field.location],
                        path: path
                    )
                )
                result[responseKey] = .null
                dataIsNull = dataIsNull || fieldDef.type.isNonNull
                continue
            }

            let input: GraphQLValue
            do {
                input = try planner.coerceArguments(
                    fieldDef,
                    nodes: field.arguments,
                    location: field.location,
                    path: path
                )
            } catch let error as GraphQLError {
                errors.append(error)
                result[responseKey] = .null
                dataIsNull = dataIsNull || fieldDef.type.isNonNull
                continue
            } catch {
                errors.append(GraphQLError(message: String(describing: error), path: path))
                result[responseKey] = .null
                dataIsNull = dataIsNull || fieldDef.type.isNonNull
                continue
            }

            // Run the handler transactionally, then resolve its result against the new state.
            let handlerResult: GraphQLValue
            do {
                handlerResult = try await store.withMutationState { state in
                    try handler(input, &state)
                }
            } catch let error as GraphQLError {
                errors.append(
                    GraphQLError(message: error.message, locations: [field.location], path: path)
                )
                result[responseKey] = .null
                dataIsNull = dataIsNull || fieldDef.type.isNonNull
                continue
            } catch {
                errors.append(
                    GraphQLError(
                        message: "Mutation '\(field.name)' failed: \(String(describing: error))",
                        locations: [field.location],
                        path: path
                    )
                )
                result[responseKey] = .null
                dataIsNull = dataIsNull || fieldDef.type.isNonNull
                continue
            }

            var resolver = makeExecutor(
                data: await store.snapshot(),
                fragments: document.fragments,
                variables: variables,
                declaredVariables: declaredVariables
            )
            let value = resolver.resolveValue(
                handlerResult,
                ofType: fieldDef.type,
                selections: nodes.flatMap(\.selectionSet),
                fieldName: field.name,
                parentTypeName: mutationTypeName,
                arguments: input,
                path: path
            )
            errors.append(contentsOf: resolver.errors)
            for (fieldKey, entry) in resolver.diagnostics {
                diagnostics[fieldKey, default: FieldDiagnostics()].merge(entry)
            }
            result[responseKey] = value
            dataIsNull = dataIsNull || (fieldDef.type.isNonNull && value.isNull)
        }
        return GraphQLResponse(
            data: dataIsNull ? .null : .object(result),
            errors: errors,
            extensions: diagnostics.mockQLExtensions
        )
    }

    // MARK: - Subscriptions

    /// Starts a subscription and returns its event stream. Events arrive when test code calls
    /// ``publish(_:payload:)``. The stream ends when the task consuming it is cancelled.
    ///
    /// The root field's arguments are coerced and validated here, exactly as a query's or
    /// mutation's are, so a missing required argument or a mistyped one fails the subscription
    /// up front instead of leaving a client waiting on a stream that was never valid.
    public func subscribe(_ request: GraphQLRequest) async throws -> AsyncStream<GraphQLResponse> {
        let document = try parseDocument(request.query)
        let operation = try document.operation(named: request.operationName)
        guard operation.type == .subscription else {
            throw GraphQLError(message: "subscribe(_:) requires a subscription operation")
        }
        let variables = try coerceVariables(operation.variableDefinitions, provided: request.variables)
        guard let subscriptionTypeName = schema.subscriptionTypeName,
            let subscriptionType = schema.objectType(named: subscriptionTypeName)
        else {
            throw GraphQLError(message: "Schema defines no subscription root type")
        }
        let declaredVariables = operation.declaredVariableNames
        var planner = makeExecutor(
            data: StoreData(),
            fragments: document.fragments,
            variables: variables,
            declaredVariables: declaredVariables
        )
        let rootFields = try planner.collectRootFields(operation.selectionSet, typeName: subscriptionTypeName)
        guard rootFields.count == 1, let nodes = rootFields.first?.nodes, let rootField = nodes.first else {
            throw GraphQLError(message: "A subscription must select exactly one root field")
        }
        guard let fieldDef = subscriptionType.field(named: rootField.name) else {
            let clause = Suggestion.clause(for: rootField.name, in: subscriptionType.fields.map(\.name))
            throw GraphQLError(
                message: "Unknown subscription field '\(rootField.name)'.\(clause)",
                locations: [rootField.location]
            )
        }
        let arguments = try planner.coerceArguments(
            fieldDef,
            nodes: rootField.arguments,
            location: rootField.location,
            path: [.field(rootField.responseKey)]
        )
        return await hub.register(
            SubscriptionHub.Subscriber(
                rootField: rootField.name,
                responseKey: rootField.responseKey,
                fieldType: fieldDef.type,
                arguments: arguments,
                selections: nodes.flatMap(\.selectionSet),
                fragments: document.fragments,
                variables: variables,
                declaredVariables: declaredVariables
            )
        )
    }

    /// Publishes a subscription event: every active subscriber of `field` receives a response
    /// with `payload` resolved through its own selection set.
    ///
    /// The payload may reference stored records (`.reference("Order", id: "o1")` or fields
    /// omitted and generated); it does not itself modify state.
    public func publish(_ field: String, payload: GraphQLValue) async throws {
        guard let subscriptionTypeName = schema.subscriptionTypeName,
            let subscriptionType = schema.objectType(named: subscriptionTypeName)
        else {
            throw MockQLError(category: .configuration, message: "Schema defines no subscription root type")
        }
        guard subscriptionType.field(named: field) != nil else {
            let clause = Suggestion.clause(for: field, in: subscriptionType.fields.map(\.name))
            throw MockQLError(
                category: .configuration,
                message: "Schema has no subscription field '\(field)'.\(clause)"
            )
        }
        let subscribers = await hub.subscribers(to: field)
        guard !subscribers.isEmpty else { return }
        let snapshot = await store.snapshot()
        for (subscriber, continuation) in subscribers {
            var executor = makeExecutor(
                data: snapshot,
                fragments: subscriber.fragments,
                variables: subscriber.variables,
                declaredVariables: subscriber.declaredVariables
            )
            let value = executor.resolveValue(
                payload,
                ofType: subscriber.fieldType,
                selections: subscriber.selections,
                fieldName: field,
                parentTypeName: subscriptionTypeName,
                arguments: subscriber.arguments,
                path: [.field(subscriber.responseKey)]
            )
            let response = GraphQLResponse(
                data: .object([subscriber.responseKey: value]),
                errors: executor.errors,
                extensions: executor.diagnostics.mockQLExtensions
            )
            continuation.yield(response)
        }
    }

    /// The number of active subscribers, useful for synchronizing tests.
    public func activeSubscriptionCount() async -> Int {
        await hub.activeCount
    }

    /// Ends all subscription streams.
    public func shutdown() async {
        await hub.finishAll()
    }

    // MARK: - Transport support

    /// The type of the operation `request` would run, or `nil` when its document does not parse
    /// or does not identify a single operation (in which case ``execute(_:)`` reports why).
    ///
    /// Transports need this before executing: GraphQL over HTTP must refuse a mutation sent by
    /// `GET`, and `graphql-transport-ws` routes subscriptions and single-result operations
    /// differently.
    package func operationType(of request: GraphQLRequest) -> OperationType? {
        guard let document = try? parseDocument(request.query),
            let operation = try? document.operation(named: request.operationName)
        else {
            return nil
        }
        return operation.type
    }

    // MARK: - Helpers

    private func parseDocument(_ query: String) throws -> ExecutableDocument {
        do {
            return try OperationParser.parse(query, sourceName: "operation")
        } catch let error as MockQLError {
            throw GraphQLError(
                message: error.message,
                locations: error.location.map { [$0] } ?? [],
                extensions: ["code": .string("GRAPHQL_PARSE_FAILED")]
            )
        }
    }

    private func coerceVariables(
        _ definitions: [VariableDefinitionNode],
        provided: [String: GraphQLValue]
    ) throws -> [String: GraphQLValue] {
        var coerced: [String: GraphQLValue] = [:]
        let coercion = InputCoercion(schema: schema)
        for definition in definitions {
            if let value = provided[definition.name] {
                coerced[definition.name] = try coercion.coerce(
                    value,
                    to: definition.type,
                    context: "variable '$\(definition.name)'",
                    location: definition.location
                )
            } else if let defaultValue = definition.defaultValue {
                coerced[definition.name] = try defaultValue.constantValue()
            } else if definition.type.isNonNull {
                throw GraphQLError(
                    message: "Missing required variable '$\(definition.name)' of type '\(definition.type)'",
                    locations: [definition.location]
                )
            }
        }
        return coerced
    }
}
