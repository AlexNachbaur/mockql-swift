import Foundation
import Testing

@testable import MockQLCore

// A small, domain-neutral schema exercising argument-based filtering: a Relay connection
// (`comments`), a plain object list (`tags`, `products`), and a hook-resolved field (`search`).
private let filterSDL = """
    type Query {
        comments(postId: ID, first: Int, after: String): CommentConnection!
        tags(kind: String, group: String): [Tag!]!
        products(maxPrice: Float): [Product!]!
        search(term: String!): [Article!]!
        feed(kind: String): [FeedItem!]!
        docs(tags: String): [Doc!]!
        version: String
    }
    type Doc { id: ID! tags: [String!]! }
    type Mutation { deleteTag(id: ID!): Boolean! }
    type CommentConnection { edges: [CommentEdge!]! pageInfo: PageInfo! }
    type CommentEdge { cursor: String! node: Comment! }
    type PageInfo { hasNextPage: Boolean! hasPreviousPage: Boolean! startCursor: String endCursor: String }
    type Comment { id: ID! postId: ID! body: String! }
    type Tag { id: ID! kind: String! label: String! group: String }
    type Product { id: ID! name: String! price: Float! }
    type Article { id: ID! title: String! }
    interface FeedItem { id: ID! kind: String! }
    type Note implements FeedItem { id: ID! kind: String! text: String! }
    type Photo implements FeedItem { id: ID! kind: String! url: String! }
    """

private let filterSeed = """
    version: 1
    data:
      Comment:
        - { id: c1, postId: p1, body: one }
        - { id: c2, postId: p1, body: two }
        - { id: c3, postId: p2, body: three }
      Tag:
        - { id: t1, kind: color, label: red, group: null }
        - { id: t2, kind: color, label: blue, group: archive }
        - { id: t3, kind: size, label: large, group: null }
      Product:
        - { id: pr1, name: Cheap, price: 5.0 }
        - { id: pr2, name: Mid, price: 20.0 }
        - { id: pr3, name: Pricey, price: 100.0 }
      Article:
        - { id: a1, title: GraphQL mocking made easy }
        - { id: a2, title: Swift concurrency }
      Doc:
        - { id: d1, tags: [a, b] }
        - { id: d2, tags: [c] }
      Note:
        - { id: n1, kind: personal, text: hi }
      Photo:
        - { id: ph1, kind: work, url: "https://example.test/p.jpg" }
    roots:
      comments: [c1, c2, c3]
      tags: [t1, t2, t3]
      products: [pr1, pr2, pr3]
      docs: [d1, d2]
      feed: [Note:n1, Photo:ph1]
    """

private func makeEngine(
    @MockQLBuilder configuration: @escaping () -> [any MockQLDeclaration] = { [] }
) async throws -> MockQLEngine {
    try await MockQLEngine(schema: .sdl(filterSDL), seed: .yaml(filterSeed), configuration: configuration)
}

private func nodeIDs(_ connection: GraphQLValue) -> [String] {
    (connection["edges"].listValue ?? []).compactMap { $0["node"]["id"].stringValue }
}

private func ids(_ list: GraphQLValue) -> [String] {
    (list.listValue ?? []).compactMap { $0["id"].stringValue }
}

@Suite struct ConventionFilterTests {

    @Test func connectionArgumentMatchingScalarFieldFiltersNodes() async throws {
        let engine = try await makeEngine()
        let response = await engine.execute(
            GraphQLRequest(query: #"{ comments(postId: "p1") { edges { node { id } } } }"#))
        #expect(response.errors.isEmpty)
        #expect(nodeIDs(response.data?["comments"] ?? .null) == ["c1", "c2"])
    }

    @Test func plainObjectListIsFilteredByMatchingArgument() async throws {
        let engine = try await makeEngine()
        let response = await engine.execute(GraphQLRequest(query: #"{ tags(kind: "color") { id } }"#))
        #expect(response.errors.isEmpty)
        #expect(ids(response.data?["tags"] ?? .null) == ["t1", "t2"])
    }

    @Test func explicitNullArgumentDoesNotFilter() async throws {
        // An explicit `group: null` means "no filter", exactly as omitting it does — the reading
        // every real GraphQL server gives an unset optional filter.
        let engine = try await makeEngine()
        let explicit = await engine.execute(GraphQLRequest(query: "{ tags(group: null) { id } }"))
        #expect(explicit.errors.isEmpty)
        #expect(ids(explicit.data?["tags"] ?? .null) == ["t1", "t2", "t3"])
        // A non-null value still filters by equality.
        let archived = await engine.execute(GraphQLRequest(query: #"{ tags(group: "archive") { id } }"#))
        #expect(ids(archived.data?["tags"] ?? .null) == ["t2"])
        // Omitting the argument returns everything, same as the explicit null above.
        let all = await engine.execute(GraphQLRequest(query: "{ tags { id } }"))
        #expect(ids(all.data?["tags"] ?? .null) == ["t1", "t2", "t3"])
    }

    @Test func nullVariableForUnsetOptionalFilterReturnsEverything() async throws {
        // The regression this behaviour exists for. Generated clients (Apollo iOS, and the same
        // is true of Relay/urql) compile an unset optional variable into an explicit `null` in the
        // variables payload — so this is what a real app sends for "no filter selected", not an
        // exotic edge case. Before, it returned an empty list and the app silently rendered
        // nothing with no error to explain it.
        let engine = try await makeEngine()
        let response = await engine.execute(
            GraphQLRequest(
                query: "query Tags($group: String) { tags(group: $group) { id } }",
                variables: ["group": .null]
            )
        )
        #expect(response.errors.isEmpty)
        #expect(ids(response.data?["tags"] ?? .null) == ["t1", "t2", "t3"])
    }

    @Test func matchingNullValuedNodesStillPossibleWithACustomFilter() async throws {
        // The capability the convention change gives up is still available — deliberately, rather
        // than by accident — through the documented escape hatch.
        let engine = try await makeEngine {
            Filter("Query.tags") { node, arguments in
                guard let group = arguments.objectValue?["group"], group.isNull else { return true }
                return node["group"].isNull
            }
        }
        let response = await engine.execute(GraphQLRequest(query: "{ tags(group: null) { id } }"))
        #expect(response.errors.isEmpty)
        #expect(ids(response.data?["tags"] ?? .null) == ["t1", "t3"])
    }

    @Test func listOfScalarFieldIsNotTreatedAsEqualityFilter() async throws {
        // `Doc.tags` is `[String!]!` — a list, not a singular scalar — so `docs(tags:)` must not be
        // convention-filtered (an equality match against a scalar argument is meaningless here).
        let engine = try await makeEngine()
        let response = await engine.execute(GraphQLRequest(query: #"{ docs(tags: "a") { id } }"#))
        #expect(response.errors.isEmpty)
        #expect(ids(response.data?["docs"] ?? .null) == ["d1", "d2"])
    }

    @Test func interfaceElementListIsFilteredByInterfaceScalarField() async throws {
        // `kind` is a scalar field on the `FeedItem` interface — filtering a list of an interface
        // type must work the same as a list of a concrete object type.
        let engine = try await makeEngine()
        let response = await engine.execute(GraphQLRequest(query: #"{ feed(kind: "personal") { id } }"#))
        #expect(response.errors.isEmpty)
        #expect(ids(response.data?["feed"] ?? .null) == ["n1"])
    }

    @Test func absentFilterArgumentReturnsAllNodes() async throws {
        let engine = try await makeEngine()
        let response = await engine.execute(GraphQLRequest(query: "{ comments { edges { node { id } } } }"))
        #expect(nodeIDs(response.data?["comments"] ?? .null) == ["c1", "c2", "c3"])
    }

    @Test func filteringComposesWithPagination() async throws {
        let engine = try await makeEngine()
        let response = await engine.execute(
            GraphQLRequest(
                query: #"{ comments(postId: "p1", first: 1) { edges { node { id } } pageInfo { hasNextPage } } }"#))
        // postId narrows to c1/c2, then `first: 1` paginates to c1 with more available.
        #expect(nodeIDs(response.data?["comments"] ?? .null) == ["c1"])
        #expect(response.data?["comments"]["pageInfo"]["hasNextPage"] == .bool(true))
    }

    @Test func nonMatchingArgumentNameDoesNotFilter() async throws {
        // `first` is pagination, not a node field — it must never be treated as an equality filter.
        let engine = try await makeEngine()
        let response = await engine.execute(GraphQLRequest(query: "{ comments(first: 3) { edges { node { id } } } }"))
        #expect(nodeIDs(response.data?["comments"] ?? .null) == ["c1", "c2", "c3"])
    }

    @Test func danglingReferenceIsPreservedThroughFilteringToSurfaceError() async throws {
        // A record deleted by a mutation but still listed in a root becomes a dangling reference.
        // Filtering must not silently drop it — the executor's dangling-reference error must surface.
        let engine = try await makeEngine {
            Mutation("deleteTag") { input, state in
                .bool(state.delete("Tag", id: input["id"].stringValue ?? ""))
            }
        }
        _ = await engine.execute(GraphQLRequest(query: #"mutation { deleteTag(id: "t1") }"#))
        let response = await engine.execute(GraphQLRequest(query: #"{ tags(kind: "color") { id } }"#))
        #expect(response.errors.contains { $0.message.contains("Dangling reference") })
    }
}

@Suite struct FilterHookTests {

    @Test func customFilterOverridesConvention() async throws {
        let engine = try await makeEngine {
            Filter("Query.products") { node, args in
                (node["price"].doubleValue ?? 0) <= (args["maxPrice"].doubleValue ?? .infinity)
            }
        }
        let response = await engine.execute(GraphQLRequest(query: "{ products(maxPrice: 30.0) { id } }"))
        #expect(response.errors.isEmpty)
        #expect(ids(response.data?["products"] ?? .null) == ["pr1", "pr2"])
    }

    @Test func duplicateFilterForSameFieldIsRejected() async throws {
        await #expect(throws: MockQLError.self) {
            _ = try await makeEngine {
                Filter("Query.products") { _, _ in true }
                Filter("Query.products") { _, _ in false }
            }
        }
    }
}

@Suite struct ResolveHookTests {

    private func searchEngine() async throws -> MockQLEngine {
        try await makeEngine {
            Resolve("Query.search") { args, store in
                let term = args["term"].stringValue ?? ""
                return .list(
                    store.records(of: "Article")
                        .filter { $0["title"].stringValue?.localizedCaseInsensitiveContains(term) == true }
                        .map { .reference("Article", id: $0["id"]) }
                )
            }
        }
    }

    @Test func resolverProducesFieldValueFromStore() async throws {
        let engine = try await searchEngine()
        let response = await engine.execute(GraphQLRequest(query: #"{ search(term: "graphql") { id title } }"#))
        #expect(response.errors.isEmpty)
        #expect(ids(response.data?["search"] ?? .null) == ["a1"])
        #expect(response.data?["search"][0]["title"] == .string("GraphQL mocking made easy"))
    }

    @Test func resolverOutputIsNotPostFilteredByConvention() async throws {
        // `kind` matches `Tag.kind`, so the convention WOULD filter to color — but a resolver is
        // authoritative: it returns all tags and the convention must not post-filter its output.
        let engine = try await makeEngine {
            Resolve("Query.tags") { _, store in
                .list(store.records(of: "Tag").map { .reference("Tag", id: $0["id"]) })
            }
        }
        let response = await engine.execute(GraphQLRequest(query: #"{ tags(kind: "color") { id } }"#))
        #expect(ids(response.data?["tags"] ?? .null) == ["t1", "t2", "t3"])
    }

    @Test func duplicateResolverForSameFieldIsRejected() async throws {
        await #expect(throws: MockQLError.self) {
            _ = try await makeEngine {
                Resolve("Query.search") { _, _ in .list([]) }
                Resolve("Query.search") { _, _ in .list([]) }
            }
        }
    }

    @Test func filterAndResolverOnSameFieldIsRejected() async throws {
        await #expect(throws: MockQLError.self) {
            _ = try await makeEngine {
                Resolve("Query.products") { _, _ in .list([]) }
                Filter("Query.products") { _, _ in true }
            }
        }
    }
}

@Suite struct KeyValidationTests {

    @Test func filterWithUnknownFieldIsRejected() async throws {
        await #expect(throws: MockQLError.self) {
            _ = try await makeEngine { Filter("Query.produtcs") { _, _ in true } }
        }
    }

    @Test func resolverWithUnknownFieldIsRejected() async throws {
        await #expect(throws: MockQLError.self) {
            _ = try await makeEngine { Resolve("Query.serach") { _, _ in .list([]) } }
        }
    }

    @Test func keyWithUnknownTypeIsRejected() async throws {
        await #expect(throws: MockQLError.self) {
            _ = try await makeEngine { Filter("Qeury.products") { _, _ in true } }
        }
    }

    @Test func malformedKeyIsRejected() async throws {
        await #expect(throws: MockQLError.self) {
            _ = try await makeEngine { Filter("products") { _, _ in true } }
        }
    }

    @Test func filterOnNonListFieldIsRejected() async throws {
        // `version` is a scalar field — a Filter has nothing to filter there.
        await #expect(throws: MockQLError.self) {
            _ = try await makeEngine { Filter("Query.version") { _, _ in true } }
        }
    }

    @Test func keyOnInterfaceTypeIsRejected() async throws {
        // Hooks fire on the concrete object type that owns the field, never on an interface, so an
        // interface-typed key would validate but never run — reject it at configuration time.
        await #expect(throws: MockQLError.self) {
            _ = try await makeEngine { Filter("FeedItem.id") { _, _ in true } }
        }
    }

    @Test func resolverOnScalarFieldIsAllowed() async throws {
        // A Resolve may target any field — it produces the value directly.
        let engine = try await makeEngine {
            Resolve("Query.version") { _, _ in .string("1.2.3") }
        }
        let response = await engine.execute(GraphQLRequest(query: "{ version }"))
        #expect(response.errors.isEmpty)
        #expect(response.data?["version"] == .string("1.2.3"))
    }
}

@Suite("Query diagnostics")
struct QueryDiagnosticsTests {

    private func diagnostics(_ response: GraphQLResponse, field: String) -> GraphQLValue {
        response.extensions?["mockql"]["fields"][field] ?? .null
    }

    @Test func diagnosticsAreAbsentUnlessEnabled() async throws {
        // Off by default: the payload is noise unless someone is asking why a list is empty.
        let engine = try await MockQLEngine(schema: .sdl(filterSDL), seed: .yaml(filterSeed))
        let response = await engine.execute(GraphQLRequest(query: #"{ tags(group: "archive") { id } }"#))
        #expect(response.extensions == nil)
    }

    @Test func diagnosticsReportTheAppliedFilterAndCounts() async throws {
        let engine = try await MockQLEngine(schema: .sdl(filterSDL), seed: .yaml(filterSeed), diagnostics: true)
        let response = await engine.execute(GraphQLRequest(query: #"{ tags(group: "archive") { id } }"#))
        let entry = diagnostics(response, field: "Query.tags")
        #expect(entry["filteredBy"].listValue?.compactMap(\.stringValue) == ["group"])
        #expect(entry["seeded"].intValue == 3)
        #expect(entry["returned"].intValue == 1)
    }

    @Test func diagnosticsNameAnArgumentThatFilteredNothing() async throws {
        // The high-value case. `docs(tags:)` is a perfectly valid argument, but `Doc.tags` is a
        // list rather than a singular scalar, so the convention does not filter on it and the
        // query returns everything — indistinguishable, without this, from a filter that matched
        // every row. The same shape covers a drifted or misspelled argument name.
        let engine = try await MockQLEngine(schema: .sdl(filterSDL), seed: .yaml(filterSeed), diagnostics: true)
        let response = await engine.execute(GraphQLRequest(query: #"{ docs(tags: "a") { id } }"#))
        let entry = diagnostics(response, field: "Query.docs")
        #expect(entry["ignoredArguments"].listValue?.compactMap(\.stringValue) == ["tags"])
        #expect(entry["filteredBy"] == .null)
        #expect(entry["returned"].intValue == entry["seeded"].intValue)
    }

    @Test func diagnosticsShowANullArgumentIsNotAFilter() async throws {
        // Reading this is what would have identified the null-argument regression in seconds:
        // `group` present in the query, absent from `filteredBy`, everything returned.
        let engine = try await MockQLEngine(schema: .sdl(filterSDL), seed: .yaml(filterSeed), diagnostics: true)
        let response = await engine.execute(GraphQLRequest(query: "{ tags(group: null) { id } }"))
        let entry = diagnostics(response, field: "Query.tags")
        #expect(entry["filteredBy"] == .null)
        #expect(entry["ignoredArguments"].listValue?.compactMap(\.stringValue) == ["group"])
        #expect(entry["seeded"].intValue == 3)
        #expect(entry["returned"].intValue == 3)
    }

    @Test func diagnosticsMarkACustomFilter() async throws {
        let engine = try await MockQLEngine(schema: .sdl(filterSDL), seed: .yaml(filterSeed), diagnostics: true) {
            Filter("Query.tags") { node, _ in node["id"].stringValue == "t2" }
        }
        let response = await engine.execute(GraphQLRequest(query: "{ tags { id } }"))
        let entry = diagnostics(response, field: "Query.tags")
        #expect(entry["customFilter"].boolValue == true)
        #expect(entry["returned"].intValue == 1)
    }

    @Test func diagnosticsAggregateRepeatedResolutionsOfTheSameField() async throws {
        // A `"Type.field"` key can resolve many times in one response — once per parent for a
        // nested list, or once per alias as here. Recording each occurrence over the last would
        // report one arbitrary slice as though it were the whole query, which is worse than no
        // diagnostics: it reads as authoritative.
        let engine = try await MockQLEngine(schema: .sdl(filterSDL), seed: .yaml(filterSeed), diagnostics: true)
        let response = await engine.execute(
            GraphQLRequest(
                query: #"{ byKind: tags(kind: "color") { id } byGroup: tags(group: "archive") { id } }"#
            )
        )
        let entry = diagnostics(response, field: "Query.tags")
        #expect(entry["occurrences"].intValue == 2)
        // Counts sum across occurrences: three candidates considered each time.
        #expect(entry["seeded"].intValue == 6)
        // Argument names union, so neither alias's filter is hidden by the other.
        #expect(entry["filteredBy"].listValue?.compactMap(\.stringValue) == ["group", "kind"])
    }

    @Test func diagnosticsAppearInTheSerializedResponse() async throws {
        // `extensions` has to survive into the wire payload, or it is invisible to the client
        // that needs it.
        let engine = try await MockQLEngine(schema: .sdl(filterSDL), seed: .yaml(filterSeed), diagnostics: true)
        let response = await engine.execute(GraphQLRequest(query: "{ tags { id } }"))
        #expect(response.responseValue["extensions"]["mockql"]["fields"]["Query.tags"]["seeded"].intValue == 3)
    }
}
