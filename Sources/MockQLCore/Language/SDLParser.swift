/// Parses GraphQL schema definition language (SDL) documents.
struct SDLParser {
    private var cursor: ParserCursor

    private init(source: String, sourceName: String?) throws {
        self.cursor = try ParserCursor(source: source, sourceName: sourceName)
    }

    /// Parses a complete SDL document.
    static func parse(_ source: String, sourceName: String? = nil) throws -> SchemaDocument {
        var parser = try SDLParser(source: source, sourceName: sourceName)
        return try parser.parseDocument()
    }

    private mutating func parseDocument() throws -> SchemaDocument {
        var typeDefinitions: [TypeDefinitionNode] = []
        var schemaDefinition: SchemaDefinitionNode?
        while !cursor.isAtEnd {
            let description = cursor.parseOptionalDescription()
            let location = cursor.current.location
            guard let keyword = cursor.current.nameValue else {
                throw cursor.error("Expected a type definition, found \(cursor.current.describedForErrors)")
            }
            switch keyword {
            case "schema":
                cursor.advance()
                guard schemaDefinition == nil else {
                    throw cursor.error("Duplicate 'schema' definition", at: location)
                }
                schemaDefinition = try parseSchemaDefinition(at: location)
            case "scalar":
                cursor.advance()
                let (name, _) = try cursor.expectName(context: "after 'scalar'")
                _ = try cursor.parseDirectives(allowVariables: false)
                typeDefinitions.append(.scalar(name: name, description: description, location: location))
            case "type":
                cursor.advance()
                typeDefinitions.append(try parseObjectLikeType(kind: .object, description: description, at: location))
            case "interface":
                cursor.advance()
                typeDefinitions.append(
                    try parseObjectLikeType(kind: .interface, description: description, at: location)
                )
            case "union":
                cursor.advance()
                typeDefinitions.append(try parseUnionType(description: description, at: location))
            case "enum":
                cursor.advance()
                typeDefinitions.append(try parseEnumType(description: description, at: location))
            case "input":
                cursor.advance()
                typeDefinitions.append(try parseInputObjectType(description: description, at: location))
            case "directive":
                cursor.advance()
                try skipDirectiveDefinition()
            case "extend":
                throw cursor.error("Type extensions ('extend') are not supported yet", at: location)
            default:
                let known = ["schema", "scalar", "type", "interface", "union", "enum", "input", "directive"]
                throw cursor.error(
                    "Unexpected '\(keyword)' at top level.\(Suggestion.clause(for: keyword, in: known))",
                    at: location
                )
            }
        }
        try validateUniqueTypeNames(typeDefinitions)
        return SchemaDocument(typeDefinitions: typeDefinitions, schemaDefinition: schemaDefinition)
    }

    private func validateUniqueTypeNames(_ definitions: [TypeDefinitionNode]) throws {
        var seen = Set<String>()
        for definition in definitions where !seen.insert(definition.name).inserted {
            throw cursor.error("Duplicate type name '\(definition.name)'", at: definition.location)
        }
    }

    private mutating func parseSchemaDefinition(at location: SourceLocation) throws -> SchemaDefinitionNode {
        _ = try cursor.parseDirectives(allowVariables: false)
        try cursor.expect(.braceLeft, context: "to begin the schema definition")
        var operationTypes: [OperationType: String] = [:]
        while !cursor.match(.braceRight) {
            if cursor.isAtEnd {
                throw cursor.error("Unterminated schema definition; expected '}'", at: location)
            }
            let (keyword, keywordLocation) = try cursor.expectName(context: "for a root operation type")
            guard let operationType = OperationType(rawValue: keyword) else {
                throw cursor.error(
                    "Expected 'query', 'mutation', or 'subscription', found '\(keyword)'",
                    at: keywordLocation
                )
            }
            try cursor.expect(.colon, context: "after '\(keyword)'")
            let (typeName, _) = try cursor.expectName(context: "for the \(keyword) root type")
            guard operationTypes[operationType] == nil else {
                throw cursor.error("Duplicate root operation type '\(keyword)'", at: keywordLocation)
            }
            operationTypes[operationType] = typeName
        }
        return SchemaDefinitionNode(operationTypes: operationTypes, location: location)
    }

    private enum ObjectLikeKind {
        case object
        case interface
    }

    private mutating func parseObjectLikeType(
        kind: ObjectLikeKind,
        description: String?,
        at location: SourceLocation
    ) throws -> TypeDefinitionNode {
        let keyword = kind == .object ? "type" : "interface"
        let (name, _) = try cursor.expectName(context: "after '\(keyword)'")
        var interfaces: [String] = []
        if cursor.matchKeyword("implements") {
            cursor.match(.ampersand)
            repeat {
                interfaces.append(try cursor.expectName(context: "after 'implements'").name)
            } while cursor.match(.ampersand)
        }
        _ = try cursor.parseDirectives(allowVariables: false)
        let fields = cursor.current.kind == .braceLeft ? try parseFieldDefinitions(typeName: name) : []
        switch kind {
        case .object:
            return .object(
                name: name, interfaces: interfaces, fields: fields, description: description, location: location
            )
        case .interface:
            return .interface(
                name: name, interfaces: interfaces, fields: fields, description: description, location: location
            )
        }
    }

    private mutating func parseFieldDefinitions(typeName: String) throws -> [FieldDefinitionNode] {
        let open = cursor.current.location
        try cursor.expect(.braceLeft, context: "to begin fields of '\(typeName)'")
        var fields: [FieldDefinitionNode] = []
        var seen = Set<String>()
        while !cursor.match(.braceRight) {
            if cursor.isAtEnd {
                throw cursor.error("Unterminated fields block for type '\(typeName)'; expected '}'", at: open)
            }
            let description = cursor.parseOptionalDescription()
            let (name, nameLocation) = try cursor.expectName(context: "for a field of '\(typeName)'")
            let arguments = try parseInputValueDefinitions(open: .parenLeft, close: .parenRight)
            try cursor.expect(.colon, context: "after field name '\(name)'")
            let type = try cursor.parseTypeReference()
            _ = try cursor.parseDirectives(allowVariables: false)
            guard seen.insert(name).inserted else {
                throw cursor.error("Duplicate field '\(name)' on type '\(typeName)'", at: nameLocation)
            }
            fields.append(
                FieldDefinitionNode(
                    name: name, arguments: arguments, type: type, description: description, location: nameLocation
                )
            )
        }
        guard !fields.isEmpty else {
            throw cursor.error("Type '\(typeName)' must define at least one field", at: open)
        }
        return fields
    }

    private mutating func parseInputValueDefinitions(
        open: Token.Kind,
        close: Token.Kind
    ) throws -> [InputValueDefinitionNode] {
        guard cursor.match(open) else { return [] }
        var definitions: [InputValueDefinitionNode] = []
        var seen = Set<String>()
        while !cursor.match(close) {
            if cursor.isAtEnd {
                throw cursor.error("Unterminated definition list")
            }
            let description = cursor.parseOptionalDescription()
            let (name, location) = try cursor.expectName(context: "for an input value")
            try cursor.expect(.colon, context: "after input value name '\(name)'")
            let type = try cursor.parseTypeReference()
            let defaultValue = cursor.match(.equals) ? try cursor.parseValue(allowVariables: false) : nil
            _ = try cursor.parseDirectives(allowVariables: false)
            guard seen.insert(name).inserted else {
                throw cursor.error("Duplicate input value '\(name)'", at: location)
            }
            definitions.append(
                InputValueDefinitionNode(
                    name: name, type: type, defaultValue: defaultValue, description: description, location: location
                )
            )
        }
        return definitions
    }

    private mutating func parseUnionType(
        description: String?,
        at location: SourceLocation
    ) throws -> TypeDefinitionNode {
        let (name, _) = try cursor.expectName(context: "after 'union'")
        _ = try cursor.parseDirectives(allowVariables: false)
        try cursor.expect(.equals, context: "after union name '\(name)'")
        cursor.match(.pipe)
        var members: [String] = []
        repeat {
            members.append(try cursor.expectName(context: "for a member of union '\(name)'").name)
        } while cursor.match(.pipe)
        return .union(name: name, members: members, description: description, location: location)
    }

    private mutating func parseEnumType(
        description: String?,
        at location: SourceLocation
    ) throws -> TypeDefinitionNode {
        let (name, _) = try cursor.expectName(context: "after 'enum'")
        _ = try cursor.parseDirectives(allowVariables: false)
        let open = cursor.current.location
        try cursor.expect(.braceLeft, context: "to begin values of enum '\(name)'")
        var values: [EnumValueDefinitionNode] = []
        var seen = Set<String>()
        while !cursor.match(.braceRight) {
            if cursor.isAtEnd {
                throw cursor.error("Unterminated enum '\(name)'; expected '}'", at: open)
            }
            let valueDescription = cursor.parseOptionalDescription()
            let (valueName, valueLocation) = try cursor.expectName(context: "for a value of enum '\(name)'")
            if ["true", "false", "null"].contains(valueName) {
                throw cursor.error("Enum value must not be '\(valueName)'", at: valueLocation)
            }
            _ = try cursor.parseDirectives(allowVariables: false)
            guard seen.insert(valueName).inserted else {
                throw cursor.error("Duplicate value '\(valueName)' in enum '\(name)'", at: valueLocation)
            }
            values.append(
                EnumValueDefinitionNode(name: valueName, description: valueDescription, location: valueLocation)
            )
        }
        guard !values.isEmpty else {
            throw cursor.error("Enum '\(name)' must define at least one value", at: open)
        }
        return .enumType(name: name, values: values, description: description, location: location)
    }

    private mutating func parseInputObjectType(
        description: String?,
        at location: SourceLocation
    ) throws -> TypeDefinitionNode {
        let (name, _) = try cursor.expectName(context: "after 'input'")
        _ = try cursor.parseDirectives(allowVariables: false)
        guard cursor.current.kind == .braceLeft else {
            throw cursor.error("Input type '\(name)' must define fields")
        }
        let fields = try parseInputValueDefinitions(open: .braceLeft, close: .braceRight)
        guard !fields.isEmpty else {
            throw cursor.error("Input type '\(name)' must define at least one field", at: location)
        }
        return .inputObject(name: name, fields: fields, description: description, location: location)
    }

    /// Parses and discards a `directive @name(…) repeatable? on A | B` definition. Custom
    /// directive definitions are accepted so real-world schema files load, but MockQL does not
    /// act on them.
    private mutating func skipDirectiveDefinition() throws {
        try cursor.expect(.at, context: "after 'directive'")
        let (name, _) = try cursor.expectName(context: "for the directive name")
        _ = try parseInputValueDefinitions(open: .parenLeft, close: .parenRight)
        cursor.matchKeyword("repeatable")
        guard cursor.matchKeyword("on") else {
            throw cursor.error("Expected 'on' in definition of directive '@\(name)'")
        }
        cursor.match(.pipe)
        repeat {
            _ = try cursor.expectName(context: "for a location of directive '@\(name)'")
        } while cursor.match(.pipe)
    }
}
