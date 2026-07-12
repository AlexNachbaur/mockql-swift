/// Converts GraphQL source text (SDL or executable documents) into tokens.
///
/// Implements the lexical grammar from the GraphQL specification: punctuators, names, numbers,
/// strings (including block strings), with comments, commas, and whitespace ignored.
struct Lexer {
    private let characters: [Character]
    private let sourceName: String?
    private var index = 0
    private var line = 1
    private var column = 1

    private init(source: String, sourceName: String?) {
        self.characters = Array(source)
        self.sourceName = sourceName
    }

    /// Tokenizes an entire document, ending with a single `.endOfFile` token.
    static func tokenize(_ source: String, sourceName: String? = nil) throws -> [Token] {
        var lexer = Lexer(source: source, sourceName: sourceName)
        var tokens: [Token] = []
        while true {
            let token = try lexer.nextToken()
            tokens.append(token)
            if token.kind == .endOfFile {
                return tokens
            }
        }
    }

    // MARK: - Scanning

    private mutating func nextToken() throws -> Token {
        skipIgnored()
        let location = SourceLocation(line: line, column: column)
        guard let character = peek() else {
            return Token(kind: .endOfFile, location: location)
        }
        switch character {
        case "!":
            advance()
            return Token(kind: .bang, location: location)
        case "$":
            advance()
            return Token(kind: .dollar, location: location)
        case "&":
            advance()
            return Token(kind: .ampersand, location: location)
        case "(":
            advance()
            return Token(kind: .parenLeft, location: location)
        case ")":
            advance()
            return Token(kind: .parenRight, location: location)
        case ":":
            advance()
            return Token(kind: .colon, location: location)
        case "=":
            advance()
            return Token(kind: .equals, location: location)
        case "@":
            advance()
            return Token(kind: .at, location: location)
        case "[":
            advance()
            return Token(kind: .bracketLeft, location: location)
        case "]":
            advance()
            return Token(kind: .bracketRight, location: location)
        case "{":
            advance()
            return Token(kind: .braceLeft, location: location)
        case "}":
            advance()
            return Token(kind: .braceRight, location: location)
        case "|":
            advance()
            return Token(kind: .pipe, location: location)
        case ".":
            guard peek(offset: 1) == ".", peek(offset: 2) == "." else {
                throw syntaxError("Unexpected '.'; did you mean '...'?", at: location)
            }
            advance(by: 3)
            return Token(kind: .spread, location: location)
        case "\"":
            return try scanString(at: location)
        case "-", "0"..."9":
            return try scanNumber(at: location)
        default:
            if character.isNameStart {
                return scanName(at: location)
            }
            throw syntaxError("Unexpected character '\(character)'", at: location)
        }
    }

    private mutating func skipIgnored() {
        while let character = peek() {
            switch character {
            case " ", "\t", ",", "\u{FEFF}", "\n", "\r":
                advance()
            case "#":
                while let next = peek(), next != "\n", next != "\r" {
                    advance()
                }
            default:
                return
            }
        }
    }

    private mutating func scanName(at location: SourceLocation) -> Token {
        var name = ""
        while let character = peek(), character.isNameContinuation {
            name.append(character)
            advance()
        }
        return Token(kind: .name(name), location: location)
    }

    private mutating func scanNumber(at location: SourceLocation) throws -> Token {
        var text = ""
        if peek() == "-" {
            text.append("-")
            advance()
        }
        guard let first = peek(), first.isASCIIDigit else {
            throw syntaxError("Expected a digit after '-'", at: location)
        }
        appendDigits(to: &text)
        var isFloat = false
        if peek() == "." {
            isFloat = true
            text.append(".")
            advance()
            guard let digit = peek(), digit.isASCIIDigit else {
                throw syntaxError("Expected a digit after '.' in number", at: location)
            }
            appendDigits(to: &text)
        }
        if peek() == "e" || peek() == "E" {
            isFloat = true
            text.append("e")
            advance()
            if peek() == "+" || peek() == "-", let sign = peek() {
                text.append(sign)
                advance()
            }
            guard let digit = peek(), digit.isASCIIDigit else {
                throw syntaxError("Expected a digit in number exponent", at: location)
            }
            appendDigits(to: &text)
        }
        if let next = peek(), next.isNameStart || next == "." {
            throw syntaxError("Unexpected character '\(next)' after number '\(text)'", at: location)
        }
        if isFloat {
            guard let value = Double(text) else {
                throw syntaxError("Invalid float literal '\(text)'", at: location)
            }
            return Token(kind: .floatValue(value), location: location)
        }
        guard let value = Int(text) else {
            throw syntaxError("Integer literal '\(text)' does not fit in a 64-bit integer", at: location)
        }
        return Token(kind: .intValue(value), location: location)
    }

    private mutating func appendDigits(to text: inout String) {
        while let character = peek(), character.isASCIIDigit {
            text.append(character)
            advance()
        }
    }

    private mutating func scanString(at location: SourceLocation) throws -> Token {
        if peek(offset: 1) == "\"", peek(offset: 2) == "\"" {
            return try scanBlockString(at: location)
        }
        advance()  // opening quote
        var value = ""
        while let character = peek() {
            switch character {
            case "\"":
                advance()
                return Token(kind: .stringValue(value), location: location)
            case "\n", "\r":
                throw syntaxError("Unterminated string literal", at: location)
            case "\\":
                advance()
                value.append(try scanEscapeSequence(at: location))
            default:
                value.append(character)
                advance()
            }
        }
        throw syntaxError("Unterminated string literal", at: location)
    }

    private mutating func scanEscapeSequence(at location: SourceLocation) throws -> Character {
        guard let escaped = peek() else {
            throw syntaxError("Unterminated escape sequence in string", at: location)
        }
        advance()
        switch escaped {
        case "\"": return "\""
        case "\\": return "\\"
        case "/": return "/"
        case "b": return "\u{8}"
        case "f": return "\u{C}"
        case "n": return "\n"
        case "r": return "\r"
        case "t": return "\t"
        case "u":
            var hex = ""
            for _ in 0..<4 {
                guard let digit = peek(), digit.isHexDigit else {
                    throw syntaxError("Invalid unicode escape in string; expected 4 hex digits after \\u", at: location)
                }
                hex.append(digit)
                advance()
            }
            guard let codepoint = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(codepoint) else {
                throw syntaxError("Invalid unicode escape '\\u\(hex)' in string", at: location)
            }
            return Character(scalar)
        default:
            throw syntaxError("Invalid escape sequence '\\\(escaped)' in string", at: location)
        }
    }

    private mutating func scanBlockString(at location: SourceLocation) throws -> Token {
        advance(by: 3)  // opening """
        var raw = ""
        while index < characters.count {
            if peek() == "\"", peek(offset: 1) == "\"", peek(offset: 2) == "\"" {
                advance(by: 3)
                return Token(kind: .stringValue(Lexer.dedentBlockString(raw)), location: location)
            }
            if peek() == "\\", peek(offset: 1) == "\"", peek(offset: 2) == "\"", peek(offset: 3) == "\"" {
                raw.append("\"\"\"")
                advance(by: 4)
                continue
            }
            if let character = peek() {
                raw.append(character)
                advance()
            }
        }
        throw syntaxError("Unterminated block string", at: location)
    }

    /// Strips common indentation and blank leading/trailing lines, per the spec's
    /// `BlockStringValue()` algorithm.
    private static func dedentBlockString(_ raw: String) -> String {
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var commonIndent: Int?
        for line in lines.dropFirst() {
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            if indent < line.count {
                commonIndent = min(indent, commonIndent ?? Int.max)
            }
        }
        if let commonIndent, commonIndent > 0 {
            lines = [lines[0]] + lines.dropFirst().map { String($0.dropFirst(commonIndent)) }
        }
        while let first = lines.first, first.allSatisfy({ $0 == " " || $0 == "\t" }) {
            lines.removeFirst()
        }
        while let last = lines.last, last.allSatisfy({ $0 == " " || $0 == "\t" }) {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Cursor

    private func peek(offset: Int = 0) -> Character? {
        let target = index + offset
        guard target < characters.count else { return nil }
        return characters[target]
    }

    private mutating func advance(by count: Int = 1) {
        for _ in 0..<count where index < characters.count {
            if characters[index] == "\n" {
                line += 1
                column = 1
            } else {
                column += 1
            }
            index += 1
        }
    }

    private func syntaxError(_ message: String, at location: SourceLocation) -> MockQLError {
        MockQLError(category: .syntax, message: message, sourceName: sourceName, location: location)
    }
}

extension Character {
    fileprivate var isNameStart: Bool {
        self == "_" || ("a"..."z").contains(self) || ("A"..."Z").contains(self)
    }

    fileprivate var isNameContinuation: Bool {
        isNameStart || isASCIIDigit
    }

    fileprivate var isASCIIDigit: Bool {
        ("0"..."9").contains(self)
    }
}
