import Testing

@testable import MockQLCore

@Suite struct SeedLoaderTests {
    private var schema: Schema {
        get throws {
            try Schema(
                sdl: """
                    type Query {
                        currentUser: User
                        cart: Cart
                        products(first: Int, after: String): ProductConnection!
                        featured: SearchItem
                    }
                    union SearchItem = User | Product
                    type User { id: ID! name: String! email: String age: Int rating: Float active: Boolean }
                    type Product { id: ID! name: String! price: Money currency: Currency addedAt: DateTime }
                    type Money { amountCents: Int! currency: Currency! }
                    enum Currency { USD EUR GBP }
                    type Cart { id: ID! owner: User! items: [CartItem!]! }
                    type CartItem { id: ID! product: Product! quantity: Int! }
                    type ProductConnection { edges: [ProductEdge!]! pageInfo: PageInfo! }
                    type ProductEdge { cursor: String! node: Product! }
                    type PageInfo { hasNextPage: Boolean! endCursor: String }
                    scalar DateTime
                    """
            )
        }
    }

    private func load(_ yaml: String) throws -> StoreData {
        try SeedLoader.load(.yaml(yaml), schema: try schema)
    }

    @Test func loadsRecordsRootsAndReferences() throws {
        let data = try load(
            """
            version: 1
            data:
              User:
                - id: user-1
                  name: Avery Quinn
                  email: avery@example.com
                  age: 34
                  rating: 4
                  active: true
              Cart:
                - id: cart-1
                  owner: user-1
                  items: []
            roots:
              currentUser: user-1
              cart: cart-1
            """
        )
        let user = try #require(data.record(type: "User", id: "user-1"))
        #expect(user["name"] == .string("Avery Quinn"))
        #expect(user["age"] == .int(34))
        #expect(user["rating"] == .double(4))
        #expect(user["active"] == .bool(true))
        let cart = try #require(data.record(type: "Cart", id: "cart-1"))
        #expect(cart["owner"] == .reference("User", id: "user-1"))
        #expect(data.roots["currentUser"] == .reference("User", id: "user-1"))
    }

    @Test func coercesIDsEnumsAndEmbeddedObjects() throws {
        let data = try load(
            """
            version: 1
            data:
              Product:
                - id: 42
                  name: Espresso Machine
                  currency: EUR
                  price: { amountCents: 64900, currency: EUR }
            """
        )
        let product = try #require(data.record(type: "Product", id: "42"))
        #expect(product["id"] == .string("42"))
        #expect(product["currency"] == .enumValue("EUR"))
        #expect(product["price"]["amountCents"] == .int(64900))
        #expect(product["price"]["currency"] == .enumValue("EUR"))
    }

    @Test func customScalarsPassThrough() throws {
        let data = try load(
            """
            version: 1
            data:
              Product:
                - id: p1
                  name: Grinder
                  addedAt: 2026-03-01T12:00:00Z
            """
        )
        let product = try #require(data.record(type: "Product", id: "p1"))
        #expect(product["addedAt"] == .string("2026-03-01T12:00:00Z"))
    }

    @Test func connectionRootsAcceptPlainIDLists() throws {
        let data = try load(
            """
            version: 1
            data:
              Product:
                - { id: p1, name: A }
                - { id: p2, name: B }
            roots:
              products: [p1, p2]
            """
        )
        #expect(data.roots["products"] == .list([.reference("Product", id: "p1"), .reference("Product", id: "p2")]))
    }

    @Test func polymorphicPositionsRequireQualifiedReferences() throws {
        let qualified = try load(
            """
            version: 1
            data:
              Product:
                - { id: p1, name: A }
            roots:
              featured: Product:p1
            """
        )
        #expect(qualified.roots["featured"] == .reference("Product", id: "p1"))

        do {
            _ = try load(
                """
                version: 1
                data:
                  Product:
                    - { id: p1, name: A }
                roots:
                  featured: p1
                """
            )
            Issue.record("Expected an error for the unqualified reference")
        } catch let error as MockQLError {
            #expect(error.message.contains("qualified reference"))
            #expect(error.message.contains("User, Product") || error.message.contains("Product, User"))
        }
    }

    @Test func forwardAndCyclicReferencesResolve() throws {
        let data = try load(
            """
            version: 1
            data:
              Cart:
                - id: cart-1
                  owner: user-1
                  items: []
              User:
                - id: user-1
                  name: Avery
            """
        )
        #expect(data.record(type: "Cart", id: "cart-1") != nil)
    }

    @Test func singleValuesWrapIntoLists() throws {
        let data = try load(
            """
            version: 1
            data:
              User:
                - { id: u1, name: A }
              CartItem:
                - { id: ci1, product: p1, quantity: 1 }
              Product:
                - { id: p1, name: A }
              Cart:
                - id: cart-1
                  owner: u1
                  items: ci1
            """
        )
        let cart = try #require(data.record(type: "Cart", id: "cart-1"))
        #expect(cart["items"] == .list([.reference("CartItem", id: "ci1")]))
    }

    @Test func jsonSeedsBehaveIdentically() throws {
        let data = try SeedLoader.load(
            .json(
                """
                {
                  "version": 1,
                  "data": {
                    "User": [{ "id": "u1", "name": "Avery" }]
                  },
                  "roots": { "currentUser": "u1" }
                }
                """
            ),
            schema: try schema
        )
        #expect(data.roots["currentUser"] == .reference("User", id: "u1"))
    }

    @Test func quotedYAMLScalarsStayStrings() throws {
        let data = try load(
            """
            version: 1
            data:
              User:
                - id: "007"
                  name: "42"
            """
        )
        let user = try #require(data.record(type: "User", id: "007"))
        #expect(user["name"] == .string("42"))
    }

    // MARK: - Failure modes

    private func expectSeedError(_ yaml: String, contains fragment: String) {
        do {
            _ = try load(yaml)
            Issue.record("Expected a seed error containing '\(fragment)'")
        } catch let error as MockQLError {
            #expect(error.category == .seed, "unexpected category in: \(error)")
            #expect(error.description.contains(fragment), "expected '\(fragment)' in: \(error)")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func missingOrWrongVersionFails() {
        expectSeedError("data: {}", contains: "missing 'version: 1'")
        expectSeedError("version: 2", contains: "Unsupported seed format version")
    }

    @Test func unknownTopLevelKeyFails() {
        expectSeedError("version: 1\ndta: {}", contains: "Did you mean 'data'?")
    }

    @Test func unknownTypeGetsSuggestion() {
        expectSeedError(
            """
            version: 1
            data:
              Usr:
                - { id: u1 }
            """,
            contains: "Did you mean 'User'?"
        )
    }

    @Test func unknownFieldGetsSuggestion() {
        expectSeedError(
            """
            version: 1
            data:
              User:
                - { id: u1, name: A, emial: x@example.com }
            """,
            contains: "Did you mean 'email'?"
        )
    }

    @Test func duplicateIDsFail() {
        expectSeedError(
            """
            version: 1
            data:
              User:
                - { id: u1, name: A }
                - { id: u1, name: B }
            """,
            contains: "Duplicate id 'u1'"
        )
    }

    @Test func danglingReferencesFailWithSuggestion() {
        expectSeedError(
            """
            version: 1
            data:
              User:
                - { id: user-1, name: A }
            roots:
              currentUser: user-11
            """,
            contains: "Dangling reference"
        )
    }

    @Test func explicitNullOnNonNullFails() {
        expectSeedError(
            """
            version: 1
            data:
              User:
                - { id: u1, name: null }
            """,
            contains: "Explicit null is not allowed"
        )
    }

    @Test func enumTypoGetsSuggestion() {
        expectSeedError(
            """
            version: 1
            data:
              Product:
                - { id: p1, name: A, currency: USDD }
            """,
            contains: "Did you mean 'USD'?"
        )
    }

    @Test func unquotedNumberForStringGetsQuotingHint() {
        expectSeedError(
            """
            version: 1
            data:
              User:
                - { id: u1, name: 42 }
            """,
            contains: "quote the value"
        )
    }

    @Test func unknownRootFieldGetsSuggestion() {
        expectSeedError(
            """
            version: 1
            data:
              User:
                - { id: u1, name: A }
            roots:
              curentUser: u1
            """,
            contains: "Did you mean 'currentUser'?"
        )
    }

    @Test func typeWithoutIDCannotBeSeededAtTopLevel() {
        expectSeedError(
            """
            version: 1
            data:
              Money:
                - { amountCents: 100, currency: USD }
            """,
            contains: "no 'id' field"
        )
    }

    @Test func seedingNonObjectTypeFails() {
        expectSeedError(
            """
            version: 1
            data:
              Currency:
                - { id: x }
            """,
            contains: "not an object type"
        )
    }

    @Test func wrongTypeQualifiedReferenceFails() {
        expectSeedError(
            """
            version: 1
            data:
              User:
                - { id: u1, name: A }
              Cart:
                - { id: c1, owner: "Product:p1", items: [] }
              Product:
                - { id: p1, name: P }
            """,
            contains: "points at type 'Product'"
        )
    }

    @Test func invalidYAMLFailsCleanly() {
        expectSeedError("version: [unclosed", contains: "not valid YAML")
    }
}
