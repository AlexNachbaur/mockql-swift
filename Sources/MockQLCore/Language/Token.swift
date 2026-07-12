/// A single lexical token of a GraphQL document.
struct Token: Hashable, Sendable {
    /// The kind of token, carrying the token's value where applicable.
    enum Kind: Hashable, Sendable {
        case bang
        case dollar
        case ampersand
        case parenLeft
        case parenRight
        case spread
        case colon
        case equals
        case at
        case bracketLeft
        case bracketRight
        case braceLeft
        case braceRight
        case pipe
        case name(String)
        case intValue(Int)
        case floatValue(Double)
        case stringValue(String)
        case endOfFile
    }

    let kind: Kind
    let location: SourceLocation

    /// The name carried by a `.name` token, or `nil` for any other kind.
    var nameValue: String? {
        if case .name(let value) = kind { return value }
        return nil
    }

    /// A short human-readable rendering for use in parse-error messages.
    var describedForErrors: String {
        switch kind {
        case .bang: return "'!'"
        case .dollar: return "'$'"
        case .ampersand: return "'&'"
        case .parenLeft: return "'('"
        case .parenRight: return "')'"
        case .spread: return "'...'"
        case .colon: return "':'"
        case .equals: return "'='"
        case .at: return "'@'"
        case .bracketLeft: return "'['"
        case .bracketRight: return "']'"
        case .braceLeft: return "'{'"
        case .braceRight: return "'}'"
        case .pipe: return "'|'"
        case .name(let value): return "'\(value)'"
        case .intValue(let value): return "integer '\(value)'"
        case .floatValue(let value): return "float '\(value)'"
        case .stringValue: return "string value"
        case .endOfFile: return "end of document"
        }
    }
}
