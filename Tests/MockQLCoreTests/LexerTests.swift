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
