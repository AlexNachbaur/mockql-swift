import Testing

@testable import MockQLCore

@Suite struct SDLParserTests {
    @Test func parsesObjectTypesWithFieldsAndArguments() throws {
        let source = """
            type Query {
                currentUser: User
                products(first: Int, after: String): ProductConnection!
            }

            type User {
                id: ID!
                name: String!
                tags: [String!]
            }
            """
        let document = try SDLParser.parse(source)
        #expect(document.typeDefinitions.count == 2)
        guard case .object(let name, _, let fields, _, _) = try #require(document.typeDefinitions.first) else {
            Issue.record("Expected an object type")
            return
        }
        #expect(name == "Query")
        #expect(fields.map(\.name) == ["currentUser", "products"])
        let products = try #require(fields.last)
        #expect(products.type == .nonNull(.named("ProductConnection")))
        #expect(products.arguments.map(\.name) == ["first", "after"])
        guard case .object(_, _, let userFields, _, _) = try #require(document.typeDefinitions.last) else {
            Issue.record("Expected an object type")
            return
        }
        #expect(userFields.last?.type == .list(.nonNull(.named("String"))))
    }

    @Test func parsesInterfacesUnionsEnumsInputsAndScalars() throws {
        let source = """
            interface Node { id: ID! }
            type User implements Node & Timestamped { id: ID! createdAt: DateTime! }
            union Actor = User | Bot
            enum Status { ACTIVE | INACTIVE }
            input Filter { status: Status = ACTIVE limit: Int }
            scalar DateTime
            """
        // Note: enums don't use pipes in real SDL; keep valid syntax here.
        let valid = source.replacingOccurrences(of: "ACTIVE | INACTIVE", with: "ACTIVE INACTIVE")
        let document = try SDLParser.parse(valid)
        guard case .object(_, let interfaces, _, _, _) = document.typeDefinitions[1] else {
            Issue.record("Expected an object type")
            return
        }
        #expect(interfaces == ["Node", "Timestamped"])
        guard case .union(_, let members, _, _) = document.typeDefinitions[2] else {
            Issue.record("Expected a union type")
            return
        }
        #expect(members == ["User", "Bot"])
        guard case .enumType(_, let values, _, _) = document.typeDefinitions[3] else {
            Issue.record("Expected an enum type")
            return
        }
        #expect(values.map(\.name) == ["ACTIVE", "INACTIVE"])
        guard case .inputObject(_, let inputFields, _, _) = document.typeDefinitions[4] else {
            Issue.record("Expected an input type")
            return
        }
        #expect(inputFields.first?.defaultValue == .enumValue("ACTIVE"))
        guard case .scalar(let scalarName, _, _) = document.typeDefinitions[5] else {
            Issue.record("Expected a scalar type")
            return
        }
        #expect(scalarName == "DateTime")
    }

    @Test func parsesDescriptionsAndSchemaDefinition() throws {
        let source = """
            "The root of all queries"
            type QueryRoot { ping: Boolean }

            schema {
                query: QueryRoot
            }
            """
        let document = try SDLParser.parse(source)
        guard case .object(_, _, _, let description, _) = try #require(document.typeDefinitions.first) else {
            Issue.record("Expected an object type")
            return
        }
        #expect(description == "The root of all queries")
        #expect(document.schemaDefinition?.operationTypes[.query] == "QueryRoot")
    }

    @Test func acceptsAndIgnoresDirectiveDefinitionsAndApplications() throws {
        let source = """
            directive @key(fields: String!) repeatable on OBJECT | INTERFACE

            type Product @key(fields: "sku") {
                sku: String! @deprecated(reason: "use id")
            }
            """
        let document = try SDLParser.parse(source)
        #expect(document.typeDefinitions.count == 1)
        #expect(document.typeDefinitions.first?.name == "Product")
    }

    @Test func parsesTheShopFixtureShapedSchema() throws {
        let source = """
            type Query {
                currentUser: User
                cart: Cart
                products(first: Int, after: String): ProductConnection!
            }
            type Mutation { addToCart(productId: ID!, quantity: Int = 1): Cart! }
            type Subscription { orderStatusChanged: Order! }
            type User { id: ID! name: String! }
            type Cart { id: ID! items: [CartItem!]! }
            type CartItem { id: ID! quantity: Int! }
            type Order { id: ID! status: OrderStatus! }
            enum OrderStatus { PENDING SHIPPED DELIVERED }
            type ProductConnection { edges: [ProductEdge!]! pageInfo: PageInfo! }
            type ProductEdge { cursor: String! node: Product! }
            type Product { id: ID! name: String! }
            type PageInfo { hasNextPage: Boolean! endCursor: String }
            """
        let document = try SDLParser.parse(source)
        #expect(document.typeDefinitions.count == 12)
        guard case .object(_, _, let mutationFields, _, _) = document.typeDefinitions[1] else {
            Issue.record("Expected the Mutation type")
            return
        }
        #expect(mutationFields.first?.arguments.last?.defaultValue == .int(1))
    }

    @Test func rejectsInvalidSchemas() {
        #expect(throws: MockQLError.self) { try SDLParser.parse("type User { }") }
        #expect(throws: MockQLError.self) { try SDLParser.parse("type User { id: ID! id: ID! }") }
        #expect(throws: MockQLError.self) { try SDLParser.parse("type A { x: Int } type A { y: Int }") }
        #expect(throws: MockQLError.self) { try SDLParser.parse("enum E { }") }
        #expect(throws: MockQLError.self) { try SDLParser.parse("union U = ") }
        #expect(throws: MockQLError.self) { try SDLParser.parse("extend type User { email: String }") }
        #expect(throws: MockQLError.self) { try SDLParser.parse("schema { query: Q } schema { query: R }") }
        #expect(throws: MockQLError.self) { try SDLParser.parse("schema { frobnicate: Q }") }
    }

    @Test func topLevelTypoGetsSuggestion() {
        do {
            _ = try SDLParser.parse("tpye User { id: ID! }", sourceName: "app.graphqls")
            Issue.record("Expected an error")
        } catch let error as MockQLError {
            #expect(error.message.contains("Did you mean 'type'?"))
            #expect(error.sourceName == "app.graphqls")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}
