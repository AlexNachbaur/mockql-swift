/// Turns a configuration block's declarations into schema, handlers, generator bindings, and a
/// seed document.
///
/// Two modes:
/// - **Standalone** (no SDL schema): `Object`/`Query`/`Mutation`/`Subscription` declarations
///   *define* the schema. MockQL synthesizes SDL from them and runs it through the same parser
///   and validation as a schema file.
/// - **Overlay** (SDL schema provided): declarations *configure* the existing schema — handlers
///   must match existing mutation fields, `Object` blocks may only bind generators to existing
///   fields, and shape-defining declarations are rejected.
struct DSLAssembly {
    /// The type name used for mutation/subscription fields declared without `returning:`.
    /// Fields of this type resolve their selections structurally against the actual value.
    static let dynamicTypeName = "_Dynamic"

    struct Output {
        var schema: Schema
        var handlers: [String: MutationHandler]
        var generatorBindings: [String: FieldGenerator]
        var seedDocument: GraphQLValue?
    }

    private var queries: [Query] = []
    private var mutations: [Mutation] = []
    private var subscriptions: [Subscription] = []
    private var objects: [Object] = []
    private var seeds: [Seed] = []
    private var roots: [Root] = []
    private var generates: [Generate] = []

    static func assemble(_ declarations: [any MockQLDeclaration], baseSchema: Schema?) throws -> Output {
        var assembly = DSLAssembly()
        try assembly.partition(declarations)
        let schema: Schema
        var bindings: [String: FieldGenerator]
        if let baseSchema {
            try assembly.validateOverlay(against: baseSchema)
            schema = baseSchema
            bindings = assembly.overlayBindings()
        } else {
            (schema, bindings) = try assembly.synthesizeSchema()
        }
        for generate in assembly.generates {
            guard bindings[generate.key] == nil else {
                throw MockQLError(
                    category: .configuration,
                    message: "Generator for '\(generate.key)' is declared more than once"
                )
            }
            bindings[generate.key] = generate.generator
        }
        var handlers: [String: MutationHandler] = [:]
        for mutation in assembly.mutations {
            guard handlers[mutation.name] == nil else {
                throw MockQLError(
                    category: .configuration,
                    message: "Mutation handler '\(mutation.name)' is declared more than once"
                )
            }
            handlers[mutation.name] = mutation.handler
        }
        return Output(
            schema: schema,
            handlers: handlers,
            generatorBindings: bindings,
            seedDocument: assembly.seedDocument()
        )
    }

    // MARK: - Partitioning

    private mutating func partition(_ declarations: [any MockQLDeclaration]) throws {
        for declaration in declarations {
            switch declaration {
            case let query as Query: queries.append(query)
            case let mutation as Mutation: mutations.append(mutation)
            case let subscription as Subscription: subscriptions.append(subscription)
            case let object as Object: objects.append(object)
            case let seed as Seed: seeds.append(seed)
            case let root as Root: roots.append(root)
            case let generate as Generate: generates.append(generate)
            default:
                throw MockQLError(
                    category: .configuration,
                    message: "Unsupported declaration type '\(type(of: declaration))'; "
                        + "custom MockQLDeclaration conformances are not supported"
                )
            }
        }
    }

    // MARK: - Overlay mode (SDL schema present)

    private func validateOverlay(against schema: Schema) throws {
        guard queries.isEmpty else {
            throw MockQLError(
                category: .configuration,
                message: "Query declarations define a schema and cannot be combined with an SDL schema; "
                    + "seed the '\(queries[0].name)' root with a Root declaration or bind generators instead"
            )
        }
        for object in objects {
            guard let existing = schema.objectType(named: object.typeName) else {
                let clause = Suggestion.clause(for: object.typeName, in: schema.types.keys)
                throw MockQLError(
                    category: .configuration,
                    message: "Object('\(object.typeName)') does not match a type in the schema.\(clause)"
                )
            }
            for field in object.fields {
                guard case .scalar = field.kind else {
                    throw MockQLError(
                        category: .configuration,
                        message: "Object('\(object.typeName)') cannot redefine field '\(field.name)' when an "
                            + "SDL schema is used; only generator bindings are allowed here"
                    )
                }
                guard existing.field(named: field.name) != nil else {
                    let clause = Suggestion.clause(for: field.name, in: existing.fields.map(\.name))
                    throw MockQLError(
                        category: .configuration,
                        message: "Object('\(object.typeName)') binds unknown field '\(field.name)'.\(clause)"
                    )
                }
            }
        }
        try validateRootFields(
            mutations.map { ($0.name, $0.returning) },
            role: "mutation",
            rootTypeName: schema.mutationTypeName,
            schema: schema
        )
        try validateRootFields(
            subscriptions.map { ($0.name, $0.returning) },
            role: "subscription",
            rootTypeName: schema.subscriptionTypeName,
            schema: schema
        )
    }

    private func validateRootFields(
        _ declared: [(name: String, returning: String?)],
        role: String,
        rootTypeName: String?,
        schema: Schema
    ) throws {
        guard !declared.isEmpty else { return }
        guard let rootTypeName, let rootType = schema.objectType(named: rootTypeName) else {
            throw MockQLError(
                category: .configuration,
                message: "Schema defines no \(role) root type, but \(role) '\(declared[0].name)' is declared"
            )
        }
        for (name, returning) in declared {
            guard let field = rootType.field(named: name) else {
                let clause = Suggestion.clause(for: name, in: rootType.fields.map(\.name))
                throw MockQLError(
                    category: .configuration,
                    message: "Schema has no \(role) field '\(name)' on '\(rootTypeName)'.\(clause)"
                )
            }
            if let returning, field.type.namedTypeName != returning {
                throw MockQLError(
                    category: .configuration,
                    message: "\(role.capitalized) '\(name)' declares returning: '\(returning)', but the schema "
                        + "says it returns '\(field.type)'"
                )
            }
        }
    }

    private func overlayBindings() -> [String: FieldGenerator] {
        var bindings: [String: FieldGenerator] = [:]
        for object in objects {
            for field in object.fields {
                if case .scalar(let generator) = field.kind {
                    bindings["\(object.typeName).\(field.name)"] = generator
                }
            }
        }
        return bindings
    }

    // MARK: - Standalone mode (schema synthesized from declarations)

    private func synthesizeSchema() throws -> (Schema, [String: FieldGenerator]) {
        var collector = TypeCollector()
        for object in objects {
            try collector.collect(object)
        }
        for query in queries {
            if let shape = query.shape {
                try collector.collect(shape)
            }
        }
        var sdl = ""
        var needsDynamic = false

        sdl += "type Query {\n"
        if queries.isEmpty {
            sdl += "    _ping: Boolean\n"
        }
        for query in queries {
            if let shape = query.shape {
                sdl += "    \(query.name): \(shape.typeName)\n"
            } else if let generator = query.generator {
                sdl += "    \(query.name): \(generator.scalarTypeName)!\n"
            }
        }
        sdl += "}\n"

        if !mutations.isEmpty {
            sdl += "type Mutation {\n"
            for mutation in mutations {
                let returnType = mutation.returning ?? DSLAssembly.dynamicTypeName
                needsDynamic = needsDynamic || mutation.returning == nil
                sdl += "    \(mutation.name): \(returnType)\n"
            }
            sdl += "}\n"
        }

        if !subscriptions.isEmpty {
            sdl += "type Subscription {\n"
            for subscription in subscriptions {
                let returnType = subscription.returning ?? DSLAssembly.dynamicTypeName
                needsDynamic = needsDynamic || subscription.returning == nil
                sdl += "    \(subscription.name): \(returnType)\n"
            }
            sdl += "}\n"
        }

        for (typeName, fields) in collector.types.sorted(by: { $0.key < $1.key }) {
            sdl += "type \(typeName) {\n"
            if fields["id"] == nil {
                sdl += "    id: ID!\n"
            }
            for (fieldName, sdlType) in fields.sorted(by: { $0.key < $1.key }) {
                sdl += "    \(fieldName): \(sdlType)\n"
            }
            sdl += "}\n"
        }
        if needsDynamic {
            sdl += "scalar \(DSLAssembly.dynamicTypeName)\n"
        }

        let schema: Schema
        do {
            schema = try Schema(sdl: sdl, sourceName: "MockQL DSL")
        } catch let error as MockQLError {
            throw MockQLError(
                category: .configuration,
                message: "The declared schema is invalid: \(error.message)",
                sourceName: "MockQL DSL"
            )
        }

        var bindings = collector.bindings
        for query in queries {
            if let generator = query.generator {
                bindings["\(schema.queryTypeName).\(query.name)"] = generator
            }
        }
        return (schema, bindings)
    }

    /// Collects object type shapes (including nested ones) into SDL field maps and generator
    /// bindings, merging repeated declarations of the same type and rejecting conflicts.
    private struct TypeCollector {
        var types: [String: [String: String]] = [:]
        var bindings: [String: FieldGenerator] = [:]

        mutating func collect(_ object: Object) throws {
            for field in object.fields {
                let sdlType: String
                switch field.kind {
                case .scalar(let generator):
                    sdlType = "\(generator.scalarTypeName)!"
                    bindings["\(object.typeName).\(field.name)"] = generator
                case .object(let nested):
                    sdlType = nested.typeName
                    try collect(nested)
                case .objectList(let nested):
                    sdlType = "[\(nested.typeName)!]!"
                    try collect(nested)
                case .typed(let declared):
                    sdlType = declared
                }
                if let existing = types[object.typeName]?[field.name], existing != sdlType {
                    throw MockQLError(
                        category: .configuration,
                        message: "Field '\(object.typeName).\(field.name)' is declared twice with different "
                            + "types ('\(existing)' and '\(sdlType)')"
                    )
                }
                types[object.typeName, default: [:]][field.name] = sdlType
            }
            if types[object.typeName] == nil {
                types[object.typeName] = [:]
            }
        }
    }

    // MARK: - Seeds

    private func seedDocument() -> GraphQLValue? {
        guard !seeds.isEmpty || !roots.isEmpty else { return nil }
        var dataSection: [String: GraphQLValue] = [:]
        for seed in seeds {
            var fields = seed.fields
            if let id = seed.id {
                fields["id"] = .string(id)
            }
            var entries = dataSection[seed.typeName]?.listValue ?? []
            entries.append(.object(fields))
            dataSection[seed.typeName] = .list(entries)
        }
        var document: [String: GraphQLValue] = ["version": .int(1)]
        if !dataSection.isEmpty {
            document["data"] = .object(dataSection)
        }
        if !roots.isEmpty {
            var rootsSection: [String: GraphQLValue] = [:]
            for root in roots {
                rootsSection[root.field] = root.value
            }
            document["roots"] = .object(rootsSection)
        }
        return .object(document)
    }
}
