/// Parses executable GraphQL documents (queries, mutations, subscriptions, and fragments).
struct OperationParser {
    private var cursor: ParserCursor

    private init(source: String, sourceName: String?) throws {
        self.cursor = try ParserCursor(source: source, sourceName: sourceName)
    }

    /// Parses a complete executable document.
    static func parse(_ source: String, sourceName: String? = nil) throws -> ExecutableDocument {
        var parser = try OperationParser(source: source, sourceName: sourceName)
        return try parser.parseDocument()
    }

    private mutating func parseDocument() throws -> ExecutableDocument {
        var operations: [OperationNode] = []
        var fragments: [String: FragmentDefinitionNode] = [:]
        while !cursor.isAtEnd {
            let location = cursor.current.location
            if cursor.current.kind == .braceLeft {
                operations.append(
                    OperationNode(
                        type: .query,
                        name: nil,
                        variableDefinitions: [],
                        directives: [],
                        selectionSet: try parseSelectionSet(),
                        location: location
                    )
                )
            } else if let keyword = cursor.current.nameValue, let type = OperationType(rawValue: keyword) {
                cursor.advance()
                operations.append(try parseOperation(type: type, at: location))
            } else if cursor.matchKeyword("fragment") {
                let fragment = try parseFragmentDefinition(at: location)
                guard fragments[fragment.name] == nil else {
                    throw cursor.error("Duplicate fragment name '\(fragment.name)'", at: location)
                }
                fragments[fragment.name] = fragment
            } else {
                throw cursor.error(
                    "Expected 'query', 'mutation', 'subscription', 'fragment', or '{', "
                        + "found \(cursor.current.describedForErrors)"
                )
            }
        }
        let named = operations.compactMap(\.name)
        if named.count != Set(named).count {
            throw cursor.error("Operation names must be unique within a document")
        }
        return ExecutableDocument(operations: operations, fragments: fragments)
    }

    private mutating func parseOperation(type: OperationType, at location: SourceLocation) throws -> OperationNode {
        let name = cursor.current.nameValue.map { name -> String in
            cursor.advance()
            return name
        }
        let variableDefinitions = try parseVariableDefinitions()
        let directives = try cursor.parseDirectives(allowVariables: true)
        let selectionSet = try parseSelectionSet()
        return OperationNode(
            type: type,
            name: name,
            variableDefinitions: variableDefinitions,
            directives: directives,
            selectionSet: selectionSet,
            location: location
        )
    }

    private mutating func parseVariableDefinitions() throws -> [VariableDefinitionNode] {
        guard cursor.match(.parenLeft) else { return [] }
        var definitions: [VariableDefinitionNode] = []
        var seen = Set<String>()
        while !cursor.match(.parenRight) {
            if cursor.isAtEnd {
                throw cursor.error("Unterminated variable definitions; expected ')'")
            }
            let location = cursor.current.location
            try cursor.expect(.dollar, context: "to begin a variable definition")
            let (name, _) = try cursor.expectName(context: "after '$' in variable definition")
            try cursor.expect(.colon, context: "after variable name '$\(name)'")
            let type = try cursor.parseTypeReference()
            let defaultValue = cursor.match(.equals) ? try cursor.parseValue(allowVariables: false) : nil
            guard seen.insert(name).inserted else {
                throw cursor.error("Duplicate variable '$\(name)'", at: location)
            }
            definitions.append(
                VariableDefinitionNode(name: name, type: type, defaultValue: defaultValue, location: location)
            )
        }
        return definitions
    }

    private mutating func parseSelectionSet() throws -> [SelectionNode] {
        let open = cursor.current.location
        try cursor.expect(.braceLeft, context: "to begin a selection set")
        var selections: [SelectionNode] = []
        while !cursor.match(.braceRight) {
            if cursor.isAtEnd {
                throw cursor.error("Unterminated selection set; expected '}'", at: open)
            }
            selections.append(try parseSelection())
        }
        guard !selections.isEmpty else {
            throw cursor.error("Selection set must not be empty", at: open)
        }
        return selections
    }

    private mutating func parseSelection() throws -> SelectionNode {
        let location = cursor.current.location
        if cursor.match(.spread) {
            if let name = cursor.current.nameValue, name != "on" {
                cursor.advance()
                let directives = try cursor.parseDirectives(allowVariables: true)
                return .fragmentSpread(name: name, directives: directives, location: location)
            }
            let typeCondition =
                cursor.matchKeyword("on")
                ? try cursor.expectName(context: "after 'on' in inline fragment").name
                : nil
            let directives = try cursor.parseDirectives(allowVariables: true)
            let selectionSet = try parseSelectionSet()
            return .inlineFragment(
                typeCondition: typeCondition,
                directives: directives,
                selectionSet: selectionSet,
                location: location
            )
        }
        let (nameOrAlias, _) = try cursor.expectName(context: "for a field selection")
        var alias: String?
        var name = nameOrAlias
        if cursor.match(.colon) {
            alias = nameOrAlias
            name = try cursor.expectName(context: "after alias '\(nameOrAlias):'").name
        }
        let arguments = try cursor.parseArgumentNodes(allowVariables: true)
        let directives = try cursor.parseDirectives(allowVariables: true)
        let selectionSet = cursor.current.kind == .braceLeft ? try parseSelectionSet() : []
        return .field(
            FieldNode(
                alias: alias,
                name: name,
                arguments: arguments,
                directives: directives,
                selectionSet: selectionSet,
                location: location
            )
        )
    }

    private mutating func parseFragmentDefinition(at location: SourceLocation) throws -> FragmentDefinitionNode {
        let (name, nameLocation) = try cursor.expectName(context: "after 'fragment'")
        guard name != "on" else {
            throw cursor.error("Fragment name must not be 'on'", at: nameLocation)
        }
        guard cursor.matchKeyword("on") else {
            throw cursor.error("Expected 'on' after fragment name '\(name)'")
        }
        let (typeCondition, _) = try cursor.expectName(context: "after 'on' in fragment definition")
        let directives = try cursor.parseDirectives(allowVariables: true)
        let selectionSet = try parseSelectionSet()
        return FragmentDefinitionNode(
            name: name,
            typeCondition: typeCondition,
            directives: directives,
            selectionSet: selectionSet,
            location: location
        )
    }
}
