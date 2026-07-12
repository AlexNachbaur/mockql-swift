import Testing

@testable import MockQLCore

@Suite struct SuggestionTests {
    @Test func suggestsCloseMatches() {
        let candidates = ["currentUser", "cart", "products"]
        #expect(Suggestion.nearest(to: "curentUser", in: candidates) == "currentUser")
        #expect(Suggestion.nearest(to: "poducts", in: candidates) == "products")
    }

    @Test func prefersCaseOnlyMismatches() {
        #expect(Suggestion.nearest(to: "currentuser", in: ["currentUser"]) == "currentUser")
    }

    @Test func rejectsDistantInputs() {
        #expect(Suggestion.nearest(to: "zebra", in: ["currentUser", "cart"]) == nil)
    }

    @Test func neverSuggestsTheInputItself() {
        #expect(Suggestion.nearest(to: "cart", in: ["cart"]) == nil)
    }

    @Test func clauseFormatsSuggestion() {
        #expect(Suggestion.clause(for: "usr", in: ["user"]) == " Did you mean 'user'?")
        #expect(Suggestion.clause(for: "zzz", in: ["user"]).isEmpty)
    }
}

@Suite struct MockQLErrorTests {
    @Test func descriptionIncludesSourceAndLocation() {
        let error = MockQLError(
            category: .seed,
            message: "Unknown field 'emial' on type 'User'. Did you mean 'email'?",
            sourceName: "checkout.yaml",
            location: SourceLocation(line: 12, column: 7)
        )
        #expect(error.description == "checkout.yaml:12:7: Unknown field 'emial' on type 'User'. Did you mean 'email'?")
    }

    @Test func descriptionIncludesDocumentPathWhenNoLocation() {
        let error = MockQLError(category: .seed, message: "Dangling reference", documentPath: "data.Cart[0].owner")
        #expect(error.description == "Dangling reference (at data.Cart[0].owner)")
    }
}

@Suite struct GraphQLErrorTests {
    @Test func responseValueMatchesSpecShape() {
        let error = GraphQLError(
            message: "Cannot return null for non-nullable field",
            locations: [SourceLocation(line: 2, column: 3)],
            path: [.field("cart"), .field("items"), .index(0)],
            extensions: ["code": .string("NULL_VIOLATION")]
        )
        let value = error.responseValue
        #expect(value["message"] == .string("Cannot return null for non-nullable field"))
        #expect(value["locations"][0] == .object(["line": .int(2), "column": .int(3)]))
        #expect(value["path"] == .list([.string("cart"), .string("items"), .int(0)]))
        #expect(value["extensions"]["code"] == .string("NULL_VIOLATION"))
    }

    @Test func emptyCollectionsAreOmittedFromResponse() {
        let value = GraphQLError(message: "boom").responseValue
        #expect(value.objectValue?.keys.sorted() == ["message"])
    }
}
