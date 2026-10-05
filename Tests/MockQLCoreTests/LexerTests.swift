import Testing

@testable import MockQLCore

@Suite struct LexerTests {
    private func kinds(_ source: String) throws -> [Token.Kind] {
        try Lexer.tokenize(source).map(\.kind)
    }

    @Test func tokenizesPunctuatorsAndNames() throws {
        let result = try kinds("query User { id }")
        #expect(
            result == [
                .name("query"), .name("User"), .braceLeft, .name("id"), .braceRight, .endOfFile,
            ]
        )
    }

    @Test func tokenizesAllPunctuators() throws {
        let result = try kinds("! $ & ( ) ... : = @ [ ] { } |")
        #expect(
            result == [
                .bang, .dollar, .ampersand, .parenLeft, .parenRight, .spread, .colon, .equals,
                .at, .bracketLeft, .bracketRight, .braceLeft, .braceRight, .pipe, .endOfFile,
            ]
        )
    }

    @Test func tokenizesNumbers() throws {
        #expect(try kinds("42") == [.intValue(42), .endOfFile])
        #expect(try kinds("-17") == [.intValue(-17), .endOfFile])
        #expect(try kinds("0") == [.intValue(0), .endOfFile])
        #expect(try kinds("3.5") == [.floatValue(3.5), .endOfFile])
        #expect(try kinds("-1.25e2") == [.floatValue(-125.0), .endOfFile])
        #expect(try kinds("2E-1") == [.floatValue(0.2), .endOfFile])
    }

    @Test func rejectsMalformedNumbers() {
        #expect(throws: MockQLError.self) { try Lexer.tokenize("1.") }
        #expect(throws: MockQLError.self) { try Lexer.tokenize("-") }
        #expect(throws: MockQLError.self) { try Lexer.tokenize("1e") }
        #expect(throws: MockQLError.self) { try Lexer.tokenize("123abc") }
    }

    @Test func tokenizesStringsWithEscapes() throws {
        #expect(try kinds(#""hello""#) == [.stringValue("hello"), .endOfFile])
        #expect(try kinds(#""line\nbreak""#) == [.stringValue("line\nbreak"), .endOfFile])
        #expect(try kinds(#""quote: \" done""#) == [.stringValue("quote: \" done"), .endOfFile])
        #expect(try kinds(#""A""#) == [.stringValue("A"), .endOfFile])
    }

    @Test func rejectsBadStrings() {
        #expect(throws: MockQLError.self) { try Lexer.tokenize(#""unterminated"#) }
        #expect(throws: MockQLError.self) { try Lexer.tokenize("\"line\nbreak\"") }
        #expect(throws: MockQLError.self) { try Lexer.tokenize(#""bad \q escape""#) }
        #expect(throws: MockQLError.self) { try Lexer.tokenize(#""\uZZZZ""#) }
    }

    @Test func surrogatePairEscapeDecodesToOneScalar() throws {
        #expect(try kinds(#""\uD83D\uDE00""#) == [.stringValue("😀"), .endOfFile])
        #expect(try kinds(#""a\ud83d\ude00b""#) == [.stringValue("a😀b"), .endOfFile])
    }

    @Test func bracedUnicodeEscapeDecodes() throws {
        #expect(try kinds(#""\u{1F600}""#) == [.stringValue("😀"), .endOfFile])
        #expect(try kinds(#""\u{41}\u{e9}""#) == [.stringValue("Aé"), .endOfFile])
    }

    @Test func malformedUnicodeEscapesAreRejectedWithAReason() {
        func message(_ source: String) -> String? {
            do {
                _ = try Lexer.tokenize(source)
                return nil
            } catch {
                return (error as? MockQLError)?.message
            }
        }
        // A leading surrogate with nothing to pair with, and one paired with a non-surrogate.
        #expect(message(#""\uD83D""#)?.contains("must be followed by a trailing surrogate") == true)
        #expect(message(#""\uD83D\u0041""#)?.contains("is not a trailing surrogate") == true)
        // A trailing surrogate on its own.
        #expect(message(#""\uDE00""#) == #"Invalid unicode escape '\uDE00' in string"#)
        // Braced form: empty, unclosed, and beyond the last code point.
        #expect(message(#""\u{}""#)?.contains("expected hex digits and a closing '}'") == true)
        #expect(message(#""\u{41""#)?.contains("expected hex digits and a closing '}'") == true)
        #expect(message(#""\u{110000}""#) == #"Invalid unicode escape '\u{110000}' in string"#)
    }

    @Test func combiningMarkAfterAQuoteStaysInsideTheString() throws {
        // U+0301 clusters with the quote before it into one grapheme; the lexer must still see
        // the quote.
        #expect(try kinds("\"\u{301}x\"") == [.stringValue("\u{301}x"), .endOfFile])
        #expect(try kinds("\"x\"\u{FEFF}") == [.stringValue("x"), .endOfFile])
    }

    @Test func namesAreASCIIOnly() {
        // "b" + U+0301 has no precomposed form, so as a grapheme it sorts between "a" and "z".
        #expect(throws: MockQLError.self) { try Lexer.tokenize("{ b\u{301} }") }
        #expect(throws: MockQLError.self) { try Lexer.tokenize("{ é }") }
    }

    @Test func columnsCountScalarsAfterNonASCIIText() throws {
        // "e" + U+0301 is one grapheme but two scalars, so `name` starts at column 6, not 5.
        let tokens = try Lexer.tokenize("\"e\u{301}\" name")
        #expect(tokens[1].location == SourceLocation(line: 1, column: 6))
    }

    @Test func dedentsBlockStrings() throws {
        let source = "\"\"\"\n    Hello,\n      World!\n    \"\"\""
        #expect(try kinds(source) == [.stringValue("Hello,\n  World!"), .endOfFile])
    }

    @Test func ignoresCommentsAndCommas() throws {
        let result = try kinds("a, b # trailing comment\nc")
        #expect(result == [.name("a"), .name("b"), .name("c"), .endOfFile])
    }

    @Test func tracksLineAndColumn() throws {
        let tokens = try Lexer.tokenize("query {\n  id\n}")
        let id = try #require(tokens.first { $0.nameValue == "id" })
        #expect(id.location == SourceLocation(line: 2, column: 3))
    }

    @Test func lonePeriodSuggestsSpread() {
        #expect(throws: MockQLError.self) { try Lexer.tokenize("{ .. }") }
    }

    // MARK: - Line terminators
    //
    // A CRLF document has to lex identically to an LF one. This is not hypothetical: git checks
    // out text files with CRLF on Windows by default, so it is the *normal* state of a schema
    // file there. It also cannot be asserted by reading a fixture from disk, because whether
    // that fixture has CRLF depends on the machine running the tests — so the bytes are spelled
    // out here instead.
    //
    // The trap is that Swift's `Character` is a grapheme cluster: `"\r\n"` is one element,
    // equal to neither `"\r"` nor `"\n"`, so a scanner that handles both individually still
    // rejects it.

    @Test func carriageReturnNewlineLexesLikeNewline() throws {
        #expect(try kinds("query {\r\n  id\r\n}") == kinds("query {\n  id\n}"))
    }

    @Test func loneCarriageReturnLexesLikeNewline() throws {
        #expect(try kinds("query {\r  id\r}") == kinds("query {\n  id\n}"))
    }

    @Test func lineNumbersCountCRLFAsOneLine() throws {
        let tokens = try Lexer.tokenize("query {\r\n  id\r\n}")
        let id = try #require(tokens.first { $0.nameValue == "id" })
        #expect(id.location == SourceLocation(line: 2, column: 3))
    }

    @Test func commentsEndAtACarriageReturn() throws {
        let result = try kinds("a # comment\r\nb")
        #expect(result == [.name("a"), .name("b"), .endOfFile])
    }

    @Test func blockStringsDedentAcrossCRLF() throws {
        #expect(
            try kinds("\"\"\"\r\n  Hello,\r\n    World!\r\n  \"\"\"")
                == kinds("\"\"\"\n  Hello,\n    World!\n  \"\"\"")
        )
    }

    @Test func errorCarriesSourceName() {
        do {
            _ = try Lexer.tokenize("~", sourceName: "bad.graphql")
            Issue.record("Expected a syntax error")
        } catch let error as MockQLError {
            #expect(error.sourceName == "bad.graphql")
            #expect(error.category == .syntax)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}
