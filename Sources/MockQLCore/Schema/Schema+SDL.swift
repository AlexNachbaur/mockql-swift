extension Schema {
    /// Parses and validates a schema from SDL source text.
    ///
    /// - Parameters:
    ///   - sdl: The schema definition language document.
    ///   - sourceName: A name (usually a file path) used in error messages.
    public init(sdl: String, sourceName: String? = nil) throws {
        let document = try SDLParser.parse(sdl, sourceName: sourceName)
        self = try SchemaAssembler(sourceName: sourceName).assemble(document)
    }
}

/// Builds a validated `Schema` from a parsed SDL document.
struct SchemaAssembler {
    let sourceName: String?

    func assemble(_ document: SchemaDocument) throws -> Schema {
        var types: [String: Schema.NamedType] = builtInScalars()
        for definition in document.typeDefinitions {
            if Schema.builtInScalarNames.contains(definition.name) {
                throw error(
                    "Type name '\(definition.name)' conflicts with a built-in scalar",
                    at: definition.location
                )
            }
            types[definition.name] = try namedType(from: definition)
        }
        let roots = try rootTypeNames(document: document, types: types)
        let schema = Schema(
            types: types,
            queryTypeName: roots.query,
            mutationTypeName: roots.mutation,
            subscriptionTypeName: roots.subscription
        )
        try validate(schema, document: document)
        return schema
    }

    private func builtInScalars() -> [String: Schema.NamedType] {
        Schema.builtInScalarNames.reduce(into: [:]) { result, name in
            result[name] = .scalar(Schema.ScalarType(name: name, isBuiltIn: true))
        }
    }

    private func namedType(from definition: TypeDefinitionNode) throws -> Schema.NamedType {
        switch definition {
        case .object(let name, let interfaces, let fields, _, _):
            return .object(
                Schema.ObjectType(name: name, interfaces: interfaces, fields: try fields.map(field(from:)))
            )
        case .interface(let name, _, let fields, _, _):
            return .interface(Schema.InterfaceType(name: name, fields: try fields.map(field(from:))))
        case .union(let name, let members, _, _):
            return .union(Schema.UnionType(name: name, members: members))
        case .enumType(let name, let values, _, _):
            return .enumType(Schema.EnumType(name: name, values: values.map(\.name)))
        case .inputObject(let name, let fields, _, _):
            return .inputObject(Schema.InputObjectType(name: name, fields: try fields.map(argument(from:))))
        case .scalar(let name, _, _):
            return .scalar(Schema.ScalarType(name: name, isBuiltIn: false))
        }
    }

    private func field(from node: FieldDefinitionNode) throws -> Schema.Field {
        Schema.Field(name: node.name, type: node.type, arguments: try node.arguments.map(argument(from:)))
    }

    private func argument(from node: InputValueDefinitionNode) throws -> Schema.Argument {
        Schema.Argument(
            name: node.name,
            type: node.type,
            defaultValue: try node.defaultValue?.constantValue()
        )
    }

    private func rootTypeNames(
        document: SchemaDocument,
        types: [String: Schema.NamedType]
    ) throws -> (query: String, mutation: String?, subscription: String?) {
        if let definition = document.schemaDefinition {
            guard let query = definition.operationTypes[.query] else {
                throw error("The 'schema' definition must declare a query root type", at: definition.location)
            }
            return (query, definition.operationTypes[.mutation], definition.operationTypes[.subscription])
        }
        guard types["Query"] != nil else {
            throw error(
                "Schema defines no root query type; add 'type Query { … }' or a 'schema { query: … }' definition"
            )
        }
        return (
            "Query", types["Mutation"] != nil ? "Mutation" : nil, types["Subscription"] != nil ? "Subscription" : nil
        )
    }

    // MARK: - Validation

    private func validate(_ schema: Schema, document: SchemaDocument) throws {
        try validateRootType(schema.queryTypeName, role: "query", in: schema)
        if let mutation = schema.mutationTypeName {
            try validateRootType(mutation, role: "mutation", in: schema)
        }
        if let subscription = schema.subscriptionTypeName {
            try validateRootType(subscription, role: "subscription", in: schema)
        }
        for definition in document.typeDefinitions {
            try validateDefinition(definition, in: schema)
        }
    }

    private func validateRootType(_ name: String, role: String, in schema: Schema) throws {
        guard let type = schema.type(named: name) else {
            throw error("The \(role) root type '\(name)' is not defined\(suggestion(for: name, in: schema))")
        }
        guard case .object = type else {
            throw error("The \(role) root type '\(name)' must be an object type, not \(article(type.kindDescription))")
        }
    }

    private func validateDefinition(_ definition: TypeDefinitionNode, in schema: Schema) throws {
        switch definition {
        case .object(let name, let interfaces, let fields, _, let location):
            for interfaceName in interfaces {
                guard let interface = schema.type(named: interfaceName) else {
                    throw error(
                        "Type '\(name)' implements unknown interface "
                            + "'\(interfaceName)'\(suggestion(for: interfaceName, in: schema))",
                        at: location
                    )
                }
                guard case .interface = interface else {
                    throw error(
                        "Type '\(name)' implements '\(interfaceName)', which is \(article(interface.kindDescription)), "
                            + "not an interface",
                        at: location
                    )
                }
            }
            try validateFields(fields, ownerName: name, in: schema)
        case .interface(let name, _, let fields, _, _):
            try validateFields(fields, ownerName: name, in: schema)
        case .union(let name, let members, _, let location):
            for member in members {
                guard let memberType = schema.type(named: member) else {
                    throw error(
                        "Union '\(name)' includes unknown type '\(member)'\(suggestion(for: member, in: schema))",
                        at: location
                    )
                }
                guard case .object = memberType else {
                    throw error(
                        "Union '\(name)' includes '\(member)', which is \(article(memberType.kindDescription)); "
                            + "union members must be object types",
                        at: location
                    )
                }
            }
        case .inputObject(let name, let fields, _, let location):
            for field in fields {
                try validateInputType(
                    field.type,
                    context: "Field '\(field.name)' of input type '\(name)'",
                    in: schema,
                    at: location
                )
            }
        case .enumType, .scalar:
            break
        }
    }

    private func validateFields(_ fields: [FieldDefinitionNode], ownerName: String, in schema: Schema) throws {
        for field in fields {
            let fieldTypeName = field.type.namedTypeName
            guard let fieldType = schema.type(named: fieldTypeName) else {
                throw error(
                    "Field '\(ownerName).\(field.name)' has unknown type "
                        + "'\(fieldTypeName)'\(suggestion(for: fieldTypeName, in: schema))",
                    at: field.location
                )
            }
            if case .inputObject = fieldType {
                throw error(
                    "Field '\(ownerName).\(field.name)' cannot return input type '\(fieldTypeName)'",
                    at: field.location
                )
            }
            for argument in field.arguments {
                try validateInputType(
                    argument.type,
                    context: "Argument '\(argument.name)' of '\(ownerName).\(field.name)'",
                    in: schema,
                    at: argument.location
                )
            }
        }
    }

    private func validateInputType(
        _ type: TypeReference,
        context: String,
        in schema: Schema,
        at location: SourceLocation
    ) throws {
        let name = type.namedTypeName
        guard let namedType = schema.type(named: name) else {
            throw error("\(context) has unknown type '\(name)'\(suggestion(for: name, in: schema))", at: location)
        }
        switch namedType {
        case .scalar, .enumType, .inputObject:
            break
        case .object, .interface, .union:
            throw error(
                "\(context) must be an input type (scalar, enum, or input object), "
                    + "but '\(name)' is \(article(namedType.kindDescription))",
                at: location
            )
        }
    }

    // MARK: - Helpers

    private func suggestion(for name: String, in schema: Schema) -> String {
        Suggestion.clause(for: name, in: schema.types.keys)
    }

    private func article(_ kind: String) -> String {
        let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
        if let first = kind.first, vowels.contains(first) {
            return "an \(kind)"
        }
        return "a \(kind)"
    }

    private func error(_ message: String, at location: SourceLocation? = nil) -> MockQLError {
        MockQLError(category: .schema, message: message, sourceName: sourceName, location: location)
    }
}
