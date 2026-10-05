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

    private func schemaError(_ sdl: String) -> MockQLError? {
        do {
            _ = try Schema(sdl: sdl)
            return nil
        } catch {
            return error as? MockQLError
        }
    }

    @Test func queryTypeIsTheDeclaredRootType() throws {
        let schema = try Schema(sdl: "schema { query: Root } type Root { ping: Boolean }")
        #expect(schema.queryType.name == "Root")
        #expect(schema.queryType.field(named: "ping") != nil)
        #expect(schema.queryTypeName == "Root")
    }

    @Test func rejectsANonObjectQueryRoot() {
        let error = schemaError("schema { query: Root } enum Root { A }")
        #expect(error?.message == "The query root type 'Root' must be an object type, not an enum")
        let missing = schemaError("schema { query: Rot } type Root { a: Int }")
        #expect(missing?.message.contains("The query root type 'Rot' is not defined") == true)
        #expect(missing?.message.contains("Did you mean 'Root'?") == true)
    }

    @Test func rejectsATypeMissingAnInterfaceField() {
        let error = schemaError(
            """
            type Query { node: Node }
            interface Node { id: ID! label: String }
            type User implements Node { id: ID! }
            """
        )
        #expect(error?.category == .schema)
        #expect(
            error?.message == "Type 'User' implements 'Node' but does not define its field 'label: String'"
        )
        #expect(error?.location?.line == 3)
    }

    @Test func rejectsAnIncompatibleInterfaceFieldType() {
        let error = schemaError(
            """
            type Query { node: Node }
            interface Node { id: ID! }
            type User implements Node { id: Int }
            """
        )
        #expect(
            error?.message
                == "Field 'User.id' has type 'Int', which is not compatible with 'ID!' declared by interface 'Node'"
        )
    }

    @Test func acceptsCovariantInterfaceFieldTypes() throws {
        // Non-null where the interface is nullable, and an implementor where it names an interface.
        _ = try Schema(
            sdl: """
                type Query { node: Node }
                interface Node { id: ID parent: Node children: [Node] }
                type User implements Node { id: ID! parent: User! children: [User!]! }
                """
        )
    }

    @Test func rejectsMismatchedInterfaceFieldArguments() {
        let missing = schemaError(
            """
            type Query { a: Int }
            interface Paged { items(first: Int): [Int] }
            type Feed implements Paged { items: [Int] }
            """
        )
        #expect(missing?.message.contains("Field 'Feed.items' is missing argument 'first: Int'") == true)

        let retyped = schemaError(
            """
            type Query { a: Int }
            interface Paged { items(first: Int): [Int] }
            type Feed implements Paged { items(first: String): [Int] }
            """
        )
        #expect(retyped?.message.contains("has type 'String', but interface 'Paged' declares it as 'Int'") == true)

        let extraRequired = schemaError(
            """
            type Query { a: Int }
            interface Paged { items: [Int] }
            type Feed implements Paged { items(scope: String!): [Int] }
            """
        )
        #expect(extraRequired?.message.contains("Argument 'scope' of 'Feed.items' is required") == true)
    }

    @Test func rejectsDefaultValuesOfTheWrongType() {
        let argument = schemaError(#"type Query { items(first: Int = "ten"): [Int] }"#)
        #expect(argument?.category == .schema)
        #expect(
            argument?.message
                == #"Expected Int for the default value of argument 'first' of 'Query.items', found "ten""#
        )
        #expect(argument?.location != nil)

        let enumDefault = schemaError("type Query { items(sort: Sort = UPP): [Int] } enum Sort { UP DOWN }")
        #expect(enumDefault?.message.contains("'UPP' is not a value of enum 'Sort'") == true)
        #expect(enumDefault?.message.contains("Did you mean 'UP'?") == true)

        let inputField = schemaError("type Query { a(f: Filter): Int } input Filter { limit: Int! = null }")
        #expect(inputField?.message.contains("the default value of field 'limit' of input type 'Filter'") == true)
    }

    @Test func acceptsWellTypedDefaultValues() throws {
        let schema = try Schema(
            sdl: """
                type Query {
                    items(first: Int = 10, sort: Sort = UP, ids: [ID!] = [1, "b"], f: Filter = { limit: 2 }): [Int]
                }
                enum Sort { UP DOWN }
                input Filter { limit: Int = 5 ratio: Float = 1 }
                """
        )
        #expect(schema.queryType.field(named: "items")?.argument(named: "first")?.defaultValue == .int(10))
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
