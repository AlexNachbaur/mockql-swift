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
    ///   - configuration: Declarations — mutation handlers, seeds, roots, generator bindings,
    ///     and (without an SDL schema) the schema shape itself.
    public init(
        schema schemaSource: SchemaSource? = nil,
        seed seedSource: SeedSource? = nil,
        generators generatorBindings: [String: FieldGenerator] = [:],
        serverSeed: UInt64 = 0,
        @MockQLBuilder configuration: () -> [any MockQLDeclaration] = { [] }
    ) async throws {
        let baseSchema = try schemaSource?.loadSchema()
        let assembled = try DSLAssembly.assemble(configuration(), baseSchema: baseSchema)
        self.schema = assembled.schema
        self.handlers = assembled.handlers

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
        let store = StateStore()
        await store.load(data)
        self.store = store
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
        var executor = Executor(
            schema: schema,
            generators: generators,
            data: await store.snapshot(),
            fragments: document.fragments,
            variables: variables
        )
        let data = executor.executeQuery(selections: operation.selectionSet)
        return GraphQLResponse(data: data, errors: executor.errors)
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
        var result: [String: GraphQLValue] = [:]
        var errors: [GraphQLError] = []
        var dataIsNull = false

        for selection in operation.selectionSet {
            guard case .field(let field) = selection else {
                errors.append(
                    GraphQLError(message: "Mutation root selections must be plain fields (no fragments)")
                )
                continue
            }
            let path: [GraphQLPathSegment] = [.field(field.responseKey)]
            if field.name == "__typename" {
                result[field.responseKey] = .string(mutationTypeName)
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
                result[field.responseKey] = .null
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
                result[field.responseKey] = .null
                dataIsNull = dataIsNull || fieldDef.type.isNonNull
                continue
            }

            // Coerce arguments against the pre-mutation snapshot's executor (pure schema work).
            var argumentExecutor = Executor(
                schema: schema,
                generators: generators,
                data: await store.snapshot(),
                fragments: document.fragments,
                variables: variables
            )
            let input: GraphQLValue
            do {
                input = try argumentExecutor.coerceArguments(
                    fieldDef,
                    nodes: field.arguments,
                    location: field.location,
                    path: path
                )
            } catch let error as GraphQLError {
                errors.append(error)
                result[field.responseKey] = .null
                dataIsNull = dataIsNull || fieldDef.type.isNonNull
                continue
            } catch {
                errors.append(GraphQLError(message: String(describing: error), path: path))
                result[field.responseKey] = .null
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
                result[field.responseKey] = .null
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
                result[field.responseKey] = .null
                dataIsNull = dataIsNull || fieldDef.type.isNonNull
                continue
            }

            var resolver = Executor(
                schema: schema,
                generators: generators,
                data: await store.snapshot(),
                fragments: document.fragments,
                variables: variables
            )
            let value = resolver.resolveValue(
                handlerResult,
                ofType: fieldDef.type,
                selections: field.selectionSet,
                fieldName: field.name,
                path: path
            )
            errors.append(contentsOf: resolver.errors)
            result[field.responseKey] = value
            dataIsNull = dataIsNull || (fieldDef.type.isNonNull && value.isNull)
        }
        return GraphQLResponse(data: dataIsNull ? .null : .object(result), errors: errors)
    }

    // MARK: - Subscriptions

    /// Starts a subscription and returns its event stream. Events arrive when test code calls
    /// ``publish(_:payload:)``. The stream ends when the task consuming it is cancelled.
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
        let rootFields = operation.selectionSet.compactMap { selection -> FieldNode? in
            if case .field(let field) = selection { return field }
            return nil
        }
        guard rootFields.count == 1, let rootField = rootFields.first,
            rootFields.count == operation.selectionSet.count
        else {
            throw GraphQLError(message: "A subscription must select exactly one root field")
        }
        guard let fieldDef = subscriptionType.field(named: rootField.name) else {
            let clause = Suggestion.clause(for: rootField.name, in: subscriptionType.fields.map(\.name))
            throw GraphQLError(message: "Unknown subscription field '\(rootField.name)'.\(clause)")
        }
        return await hub.register(
            rootField: rootField.name,
            responseKey: rootField.responseKey,
            fieldType: fieldDef.type,
            selections: rootField.selectionSet,
            fragments: document.fragments,
            variables: variables
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
        for subscriber in subscribers {
            var executor = Executor(
                schema: schema,
                generators: generators,
                data: snapshot,
                fragments: subscriber.fragments,
                variables: subscriber.variables
            )
            let value = executor.resolveValue(
                payload,
                ofType: subscriber.fieldType,
                selections: subscriber.selections,
                fieldName: field,
                path: [.field(subscriber.responseKey)]
            )
            let response = GraphQLResponse(
                data: .object([subscriber.responseKey: value]),
                errors: executor.errors
            )
            subscriber.continuation.yield(response)
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
