import Testing

@testable import MockQLCore

@Suite struct SchemaTests {
    private let shopSDL = """
        type Query {
            currentUser: User
            products(first: Int, after: String): ProductConnection!
        }
        type Mutation { updateDisplayName(name: String!): User! }
        type User implements Node { id: ID! name: String! }
        interface Node { id: ID! }
        union SearchResult = User | Product
        enum Currency { USD EUR }
        input ProductFilter { currency: Currency = USD limit: Int }
        scalar DateTime
        type Product implements Node { id: ID! name: String! addedAt: DateTime }
        type ProductConnection { edges: [ProductEdge!]! }
        type ProductEdge { node: Product! }
        """

    @Test func buildsSchemaFromSDL() throws {
        let schema = try Schema(sdl: shopSDL)
        #expect(schema.queryTypeName == "Query")
        #expect(schema.mutationTypeName == "Mutation")
        #expect(schema.subscriptionTypeName == nil)
        let user = try #require(schema.objectType(named: "User"))
        #expect(user.field(named: "name")?.type == .nonNull(.named("String")))
        #expect(user.interfaces == ["Node"])
        let products = try #require(schema.field("products", onType: "Query"))
        #expect(products.argument(named: "first")?.type == .named("Int"))
    }

    @Test func registersBuiltInAndCustomScalars() throws {
        let schema = try Schema(sdl: shopSDL)
        for name in ["Int", "Float", "String", "Boolean", "ID"] {
            guard case .scalar(let scalar) = try #require(schema.type(named: name)) else {
                Issue.record("Expected \(name) to be a scalar")
                return
            }
            #expect(scalar.isBuiltIn)
        }
        guard case .scalar(let dateTime) = try #require(schema.type(named: "DateTime")) else {
            Issue.record("Expected DateTime to be a scalar")
            return
        }
        #expect(!dateTime.isBuiltIn)
    }

    @Test func capturesInputDefaults() throws {
        let schema = try Schema(sdl: shopSDL)
        guard case .inputObject(let filter) = try #require(schema.type(named: "ProductFilter")) else {
            Issue.record("Expected an input object")
            return
        }
        #expect(filter.fields.first?.defaultValue == .enumValue("USD"))
    }

    @Test func computesPossibleTypes() throws {
        let schema = try Schema(sdl: shopSDL)
        #expect(schema.possibleTypeNames(for: "User") == ["User"])
        #expect(schema.possibleTypeNames(for: "SearchResult") == ["User", "Product"])
        #expect(schema.possibleTypeNames(for: "Node") == ["Product", "User"])
        #expect(schema.isPolymorphic("Node"))
        #expect(schema.isPolymorphic("SearchResult"))
        #expect(!schema.isPolymorphic("User"))
    }

    @Test func honorsExplicitSchemaDefinition() throws {
        let schema = try Schema(
            sdl: """
                schema { query: Root }
                type Root { ping: Boolean }
                """
        )
        #expect(schema.queryTypeName == "Root")
        #expect(schema.mutationTypeName == nil)
    }

    @Test func requiresAQueryRootType() {
        #expect(throws: MockQLError.self) {
            try Schema(sdl: "type User { id: ID! }")
        }
    }

    @Test func rejectsUnknownFieldTypesWithSuggestion() {
        do {
            _ = try Schema(sdl: "type Query { user: Usr } type User { id: ID! }")
            Issue.record("Expected an error")
        } catch let error as MockQLError {
            #expect(error.message.contains("unknown type 'Usr'"))
            #expect(error.message.contains("Did you mean 'User'?"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func rejectsInvalidTypeRelationships() {
        // Union member that is an enum.
        #expect(throws: MockQLError.self) {
            try Schema(sdl: "type Query { a: Int } enum E { X } union U = E")
        }
        // Implementing a non-interface.
        #expect(throws: MockQLError.self) {
            try Schema(sdl: "type Query { a: Int } type A { x: Int } type B implements A { x: Int }")
        }
        // Output field returning an input type.
        #expect(throws: MockQLError.self) {
            try Schema(sdl: "type Query { f: Filter } input Filter { limit: Int }")
        }
        // Argument taking an object type.
        #expect(throws: MockQLError.self) {
            try Schema(sdl: "type Query { f(user: User): Int } type User { id: ID! }")
        }
        // Redefining a built-in scalar.
        #expect(throws: MockQLError.self) {
            try Schema(sdl: "type Query { a: Int } scalar String")
        }
    }
}
