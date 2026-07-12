/// A cursor over a token stream with the grammar productions shared by the SDL and operation
/// parsers: values, type references, arguments, and directives.
struct ParserCursor {
    private let tokens: [Token]
    private var position = 0
    let sourceName: String?

    init(source: String, sourceName: String?) throws {
        self.tokens = try Lexer.tokenize(source, sourceName: sourceName)
        self.sourceName = sourceName
    }

    // MARK: - Primitives

    var current: Token {
        tokens[min(position, tokens.count - 1)]
    }

    var isAtEnd: Bool {
        current.kind == .endOfFile
    }

    @discardableResult
    mutating func advance() -> Token {
        let token = current
        if position < tokens.count - 1 {
            position += 1
        }
        return token
    }

    /// Consumes the current token when it matches `kind`.
    mutating func match(_ kind: Token.Kind) -> Bool {
        guard current.kind == kind else { return false }
        advance()
        return true
    }

    /// Consumes the current token when it is the given (contextual) keyword name.
    mutating func matchKeyword(_ keyword: String) -> Bool {
        guard current.nameValue == keyword else { return false }
        advance()
        return true
    }

    @discardableResult
    mutating func expect(_ kind: Token.Kind, context: String) throws -> Token {
        guard current.kind == kind else {
            let expected = Token(kind: kind, location: current.location).describedForErrors
            throw error("Expected \(expected) \(context), found \(current.describedForErrors)")
        }
        return advance()
    }

    mutating func expectName(context: String) throws -> (name: String, location: SourceLocation) {
        guard let name = current.nameValue else {
            throw error("Expected a name \(context), found \(current.describedForErrors)")
        }
        let location = current.location
        advance()
        return (name, location)
    }

    func error(_ message: String, at location: SourceLocation? = nil) -> MockQLError {
        MockQLError(
            category: .syntax,
            message: message,
            sourceName: sourceName,
            location: location ?? current.location
        )
    }

    // MARK: - Shared grammar

    /// Parses a value literal. Variables (`$name`) are only legal in executable positions.
    mutating func parseValue(allowVariables: Bool) throws -> ASTValue {
        let token = current
        switch token.kind {
        case .dollar:
            advance()
            let (name, _) = try expectName(context: "after '$' in variable")
            guard allowVariables else {
                throw error("Variable '$\(name)' is not allowed in this position", at: token.location)
            }
            return .variable(name)
        case .intValue(let value):
            advance()
            return .int(value)
        case .floatValue(let value):
            advance()
            return .float(value)
        case .stringValue(let value):
            advance()
            return .string(value)
        case .name("true"):
            advance()
            return .bool(true)
        case .name("false"):
            advance()
            return .bool(false)
        case .name("null"):
            advance()
            return .null
        case .name(let name):
            advance()
            return .enumValue(name)
        case .bracketLeft:
            advance()
            var elements: [ASTValue] = []
            while !match(.bracketRight) {
                if isAtEnd {
                    throw error("Unterminated list value; expected ']'", at: token.location)
                }
                elements.append(try parseValue(allowVariables: allowVariables))
            }
            return .list(elements)
        case .braceLeft:
            advance()
            var fields: [String: ASTValue] = [:]
            while !match(.braceRight) {
                if isAtEnd {
                    throw error("Unterminated input object value; expected '}'", at: token.location)
                }
                let (name, nameLocation) = try expectName(context: "for input object field")
                try expect(.colon, context: "after input object field name '\(name)'")
                guard fields[name] == nil else {
                    throw error("Duplicate input object field '\(name)'", at: nameLocation)
                }
                fields[name] = try parseValue(allowVariables: allowVariables)
            }
            return .object(fields)
        default:
            throw error("Expected a value, found \(token.describedForErrors)")
        }
    }

    /// Parses a type reference: `Name`, `[Type]`, with optional `!` wrappers.
    mutating func parseTypeReference() throws -> TypeReference {
        let base: TypeReference
        if match(.bracketLeft) {
            let element = try parseTypeReference()
            try expect(.bracketRight, context: "to close list type")
            base = .list(element)
        } else {
            let (name, _) = try expectName(context: "for a type")
            base = .named(name)
        }
        return match(.bang) ? .nonNull(base) : base
    }

    /// Parses zero or more directive applications: `@name(arg: value) …`.
    mutating func parseDirectives(allowVariables: Bool) throws -> [DirectiveNode] {
        var directives: [DirectiveNode] = []
        while current.kind == .at {
            let location = current.location
            advance()
            let (name, _) = try expectName(context: "after '@' in directive")
            let arguments = try parseArgumentValues(allowVariables: allowVariables)
            directives.append(DirectiveNode(name: name, arguments: arguments, location: location))
        }
        return directives
    }

    /// Parses an optional parenthesized argument list into name/value pairs.
    mutating func parseArgumentValues(allowVariables: Bool) throws -> [String: ASTValue] {
        try parseArgumentNodes(allowVariables: allowVariables)
            .reduce(into: [:]) { $0[$1.name] = $1.value }
    }

    /// Parses an optional parenthesized argument list, preserving source locations.
    mutating func parseArgumentNodes(allowVariables: Bool) throws -> [ArgumentNode] {
        guard match(.parenLeft) else { return [] }
        var arguments: [ArgumentNode] = []
        var seen = Set<String>()
        while !match(.parenRight) {
            if isAtEnd {
                throw error("Unterminated argument list; expected ')'")
            }
            let (name, location) = try expectName(context: "for an argument")
            try expect(.colon, context: "after argument name '\(name)'")
            let value = try parseValue(allowVariables: allowVariables)
            guard seen.insert(name).inserted else {
                throw error("Duplicate argument '\(name)'", at: location)
            }
            arguments.append(ArgumentNode(name: name, value: value, location: location))
        }
        guard !arguments.isEmpty else {
            throw error("Argument list must not be empty")
        }
        return arguments
    }

    /// Consumes a description string when present (SDL only).
    mutating func parseOptionalDescription() -> String? {
        if case .stringValue(let value) = current.kind {
            advance()
            return value
        }
        return nil
    }
}
