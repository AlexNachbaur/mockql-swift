import Foundation
import Testing

@testable import MockQLCore

private let shopSDL = """
    type Query {
        currentUser: User
        cart: Cart
        products(first: Int, after: String, last: Int, before: String): ProductConnection!
        product(id: ID!): Product
        featured: SearchItem
    }
    type Mutation {
        addToCart(productId: ID!, quantity: Int = 1): Cart!
        updateDisplayName(name: String!): User!
        restock(first: Int, after: String): ProductConnection!
    }
    type Subscription {
        orderStatusChanged: Order!
        orderUpdated(id: ID!): Order!
    }
    union SearchItem = User | Product
    type User { id: ID! name: String! email: String! phone: String }
    type Product { id: ID! name: String! priceCents: Int! }
    type Cart { id: ID! owner: User! items: [CartItem!]! }
    type CartItem { id: ID! product: Product! quantity: Int! }
    type Order { id: ID! status: OrderStatus! }
    enum OrderStatus { PENDING SHIPPED DELIVERED }
    type ProductConnection { edges: [ProductEdge!]! pageInfo: PageInfo! totalCount: Int! }
    type ProductEdge { cursor: String! node: Product! }
    type PageInfo { hasNextPage: Boolean! hasPreviousPage: Boolean! startCursor: String endCursor: String }
    """

private let shopSeed = """
    version: 1
    data:
      User:
        - { id: user-1, name: Avery Quinn, email: avery@example.com }
      Product:
        - { id: p1, name: Espresso Machine, priceCents: 64900 }
        - { id: p2, name: Burr Grinder, priceCents: 21900 }
        - { id: p3, name: Kettle, priceCents: 8900 }
      Cart:
        - { id: cart-1, owner: user-1, items: [] }
    roots:
      currentUser: user-1
      cart: cart-1
      products: [p1, p2, p3]
      featured: Product:p1
    """

private func makeShopEngine(
    @MockQLBuilder configuration: @escaping () -> [any MockQLDeclaration] = { [] }
) async throws -> MockQLEngine {
    try await MockQLEngine(schema: .sdl(shopSDL), seed: .yaml(shopSeed), configuration: configuration)
}

@Suite struct EngineQueryTests {
    @Test func resolvesSeededFieldsAndReferences() async throws {
        let engine = try await makeShopEngine()
        let response = await engine.execute(
            GraphQLRequest(query: "{ currentUser { id name email } cart { owner { name } } }")
        )
        #expect(response.errors.isEmpty)
        let data = try #require(response.data)
        #expect(data["currentUser"]["name"] == .string("Avery Quinn"))
        #expect(data["cart"]["owner"]["name"] == .string("Avery Quinn"))
    }

    @Test func aliasesAndTypenameWork() async throws {
        let engine = try await makeShopEngine()
        let response = await engine.execute(
            GraphQLRequest(query: "{ me: currentUser { __typename handle: name } }")
        )
        let data = try #require(response.data)
        #expect(data["me"]["__typename"] == .string("User"))
        #expect(data["me"]["handle"] == .string("Avery Quinn"))
    }

    @Test func generatesMissingFieldsStably() async throws {
        let engine = try await makeShopEngine()
        let first = await engine.execute(GraphQLRequest(query: "{ currentUser { phone } }"))
        let second = await engine.execute(GraphQLRequest(query: "{ currentUser { phone } }"))
        let phone = try #require(first.data?["currentUser"]["phone"].stringValue)
        #expect(phone.hasPrefix("+1"))
        #expect(first.data == second.data)
    }

    @Test func explicitGeneratorBindingWins() async throws {
        let engine = try await MockQLEngine(
            schema: .sdl(shopSDL),
            seed: .yaml(shopSeed),
            generators: ["User.phone": .constant(.string("+1 (000) 555-0100"))]
        )
        let response = await engine.execute(GraphQLRequest(query: "{ currentUser { phone } }"))
        #expect(response.data?["currentUser"]["phone"] == .string("+1 (000) 555-0100"))
    }

    @Test func fragmentsAndInlineFragmentsResolve() async throws {
        let engine = try await makeShopEngine()
        let response = await engine.execute(
            GraphQLRequest(
                query: """
                    query {
                        featured {
                            __typename
                            ... on Product { name priceCents }
                            ... on User { email }
                        }
                        currentUser { ...UserBits }
                    }
                    fragment UserBits on User { id name }
                    """
            )
        )
        #expect(response.errors.isEmpty)
        let data = try #require(response.data)
        #expect(data["featured"]["__typename"] == .string("Product"))
        #expect(data["featured"]["name"] == .string("Espresso Machine"))
        #expect(data["featured"]["email"] == .null)
        #expect(data["currentUser"]["name"] == .string("Avery Quinn"))
    }

    @Test func skipAndIncludeDirectivesAreHonored() async throws {
        let engine = try await makeShopEngine()
        let response = await engine.execute(
            GraphQLRequest(
                query: """
                    query Q($withEmail: Boolean!) {
                        currentUser {
                            name
                            email @include(if: $withEmail)
                            phone @skip(if: true)
                        }
                    }
                    """,
                variables: ["withEmail": .bool(false)]
            )
        )
        let user = try #require(response.data?["currentUser"].objectValue)
        #expect(user.keys.sorted() == ["name"])
    }

    @Test func variablesCoerceAndValidate() async throws {
        let engine = try await makeShopEngine()
        let missing = await engine.execute(
            GraphQLRequest(query: "query Q($id: ID!) { product(id: $id) { name } }")
        )
        #expect(missing.data == nil)
        #expect(missing.errors.first?.message.contains("Missing required variable '$id'") == true)

        let coerced = await engine.execute(
            GraphQLRequest(
                query: "query Q($id: ID!) { product(id: $id) { name } }",
                variables: ["id": .int(1)]
            )
        )
        // ID coerces the int to "1"; there is no product with that id, so the lookup is null.
        #expect(coerced.data?["product"] == .null)
    }

    @Test func unknownFragmentSpreadIsReportedInErrors() async throws {
        let engine = try await makeShopEngine()
        let response = await engine.execute(GraphQLRequest(query: "{ ...Missing }"))
        let error = try #require(response.errors.first, "a failed request must say why")
        #expect(error.message.contains("Unknown fragment 'Missing'"))
        // Raised before execution began, so `data` is absent — not `null` (spec §7.1.2).
        #expect(response.data == nil)
        #expect(response.responseValue.objectValue?["data"] == nil)
    }

    @Test func unknownFragmentSpreadSuggestsTheNearestFragment() async throws {
        let engine = try await makeShopEngine()
        let response = await engine.execute(
            GraphQLRequest(
                query: """
                    { currentUser { ...UserFeilds } }
                    fragment UserFields on User { name }
                    """
            )
        )
        #expect(response.errors.first?.message.contains("Did you mean 'UserFields'?") == true)
    }

    @Test func undeclaredVariableInADirectiveIsReportedInErrors() async throws {
        let engine = try await makeShopEngine()
        let response = await engine.execute(
            GraphQLRequest(query: "{ currentUser { name @skip(if: $nope) } }")
        )
        let error = try #require(response.errors.first, "a failed request must say why")
        #expect(error.message.contains("Variable '$nope' is not declared"))
        #expect(error.locations.isEmpty == false)
    }

    @Test func undeclaredVariableSuggestsADeclaredOne() async throws {
        let engine = try await makeShopEngine()
        let response = await engine.execute(
            GraphQLRequest(
                query: "query Q($first: Int) { products(first: $frist) { totalCount } }",
                variables: ["first": 1]
            )
        )
        let error = try #require(response.errors.first)
        #expect(error.message.contains("Variable '$frist' is not declared"))
        #expect(error.message.contains("Did you mean 'first'?"))
    }

    @Test func omittedNullableVariableLeavesItsArgumentAbsent() async throws {
        let engine = try await makeShopEngine()
        let response = await engine.execute(
            GraphQLRequest(query: "query Q($n: Int) { products(first: $n) { edges { node { name } } } }")
        )
        #expect(response.errors.isEmpty)
        #expect(response.data?["products"]["edges"].count == 3)
    }

    @Test func omittedVariableFeedingARequiredArgumentIsAMissingArgument() async throws {
        let engine = try await makeShopEngine()
        let response = await engine.execute(
            GraphQLRequest(query: "query Q($id: ID) { product(id: $id) { name } }")
        )
        #expect(response.errors.first?.message.contains("Missing required argument 'id'") == true)
        #expect(response.data?["product"] == .null)
    }

    @Test func intArgumentsOutsideThe32BitRangeAreRejected() async throws {
        let engine = try await makeShopEngine()
        let literal = await engine.execute(GraphQLRequest(query: "{ products(first: 2147483648) { totalCount } }"))
        #expect(literal.errors.first?.message.contains("outside the signed 32-bit range") == true)
        #expect(literal.errors.first?.extensions["code"] == .string("BAD_INPUT"))

        let variable = await engine.execute(
            GraphQLRequest(
                query: "query Q($n: Int) { products(first: $n) { totalCount } }",
                variables: ["n": .int(-2_147_483_649)]
            )
        )
        #expect(variable.data == nil)
        #expect(variable.errors.first?.message.contains("variable '$n'") == true)

        // The bounds themselves are in range.
        let maximum = await engine.execute(GraphQLRequest(query: "{ products(first: 2147483647) { totalCount } }"))
        #expect(maximum.errors.isEmpty)
    }

    @Test func idArgumentsLookUpSeededRecords() async throws {
        let engine = try await makeShopEngine()
        let response = await engine.execute(GraphQLRequest(query: #"{ product(id: "p2") { name } }"#))
        #expect(response.errors.isEmpty)
        #expect(response.data?["product"]["name"] == .string("Burr Grinder"))
    }

    @Test func unknownFieldGetsSuggestionInErrors() async throws {
        let engine = try await makeShopEngine()
        let response = await engine.execute(GraphQLRequest(query: "{ currentUser { emial } }"))
        let error = try #require(response.errors.first)
        #expect(error.message.contains("Did you mean 'email'?"))
        #expect(response.data?["currentUser"]["emial"] == .null)
    }

    @Test func unknownArgumentGetsSuggestion() async throws {
        let engine = try await makeShopEngine()
        let response = await engine.execute(GraphQLRequest(query: #"{ product(idd: "p1") { name } }"#))
        let error = try #require(response.errors.first)
        #expect(error.message.contains("Did you mean 'id'?"))
    }

    @Test func requestLevelParseErrorsFailTheRequest() async throws {
        let engine = try await makeShopEngine()
        let response = await engine.execute(GraphQLRequest(query: "{ currentUser { name }"))
        #expect(response.data == nil)
        #expect(response.errors.first?.extensions["code"] == .string("GRAPHQL_PARSE_FAILED"))
    }
}

@Suite struct EngineConnectionTests {
    @Test func synthesizesConnectionsFromIDLists() async throws {
        let engine = try await makeShopEngine()
        let response = await engine.execute(
            GraphQLRequest(
                query: """
                    {
                        products(first: 2) {
                            totalCount
                            edges { cursor node { name } }
                            pageInfo { hasNextPage hasPreviousPage endCursor }
                        }
                    }
                    """
            )
        )
        #expect(response.errors.isEmpty)
        let products = try #require(response.data?["products"])
        #expect(products["totalCount"] == .int(3))
        #expect(products["edges"].count == 2)
        #expect(products["edges"][0]["node"]["name"] == .string("Espresso Machine"))
        #expect(products["pageInfo"]["hasNextPage"] == .bool(true))
        #expect(products["pageInfo"]["hasPreviousPage"] == .bool(false))
    }

    @Test func paginatesWithAfterCursor() async throws {
        let engine = try await makeShopEngine()
        let firstPage = await engine.execute(
            GraphQLRequest(query: "{ products(first: 1) { pageInfo { endCursor } } }")
        )
        let cursor = try #require(firstPage.data?["products"]["pageInfo"]["endCursor"].stringValue)
        let secondPage = await engine.execute(
            GraphQLRequest(
                query:
                    "query Q($c: String) { products(first: 2, after: $c) { edges { node { name } } pageInfo { hasNextPage } } }",
                variables: ["c": .string(cursor)]
            )
        )
        let data = try #require(secondPage.data)
        #expect(data["products"]["edges"][0]["node"]["name"] == .string("Burr Grinder"))
        #expect(data["products"]["edges"][1]["node"]["name"] == .string("Kettle"))
        #expect(data["products"]["pageInfo"]["hasNextPage"] == .bool(false))
    }

    @Test func lastKeepsTheTailOfTheConnection() async throws {
        let engine = try await makeShopEngine()
        let response = await engine.execute(
            GraphQLRequest(
                query: """
                    { products(last: 2) {
                        edges { cursor node { name } }
                        pageInfo { hasNextPage hasPreviousPage startCursor endCursor }
                    } }
                    """
            )
        )
        #expect(response.errors.isEmpty)
        let products = try #require(response.data?["products"])
        #expect(products["edges"].count == 2)
        #expect(products["edges"][0]["node"]["name"] == .string("Burr Grinder"))
        #expect(products["edges"][1]["node"]["name"] == .string("Kettle"))
        #expect(products["pageInfo"]["hasPreviousPage"] == .bool(true))
        #expect(products["pageInfo"]["hasNextPage"] == .bool(false))
        #expect(products["pageInfo"]["startCursor"] == products["edges"][0]["cursor"])
        #expect(products["pageInfo"]["endCursor"] == products["edges"][1]["cursor"])
    }

    @Test func beforeCursorPagesBackward() async throws {
        let engine = try await makeShopEngine()
        let all = await engine.execute(GraphQLRequest(query: "{ products { edges { cursor } } }"))
        let lastCursor = try #require(all.data?["products"]["edges"][2]["cursor"].stringValue)
        let response = await engine.execute(
            GraphQLRequest(
                query: """
                    query Q($c: String) { products(last: 1, before: $c) {
                        edges { node { name } }
                        pageInfo { hasNextPage hasPreviousPage }
                    } }
                    """,
                variables: ["c": .string(lastCursor)]
            )
        )
        #expect(response.errors.isEmpty)
        let products = try #require(response.data?["products"])
        #expect(products["edges"].count == 1)
        #expect(products["edges"][0]["node"]["name"] == .string("Burr Grinder"))
        #expect(products["pageInfo"]["hasNextPage"] == .bool(true))
        #expect(products["pageInfo"]["hasPreviousPage"] == .bool(true))
    }

    @Test(arguments: ["first", "last"])
    func negativePageSizeIsAnError(argument: String) async throws {
        let engine = try await makeShopEngine()
        let response = await engine.execute(
            GraphQLRequest(query: "{ products(\(argument): -1) { totalCount } }")
        )
        #expect(response.errors.count == 1)
        let error = try #require(response.errors.first)
        #expect(error.message == "Argument '\(argument)' of 'Query.products' must be a non-negative integer, found -1")
        #expect(error.path == [.field("products")])
        #expect(response.data == .null)
    }

    @Test func cursorPointingOutsideTheListYieldsAnEmptyPage() async throws {
        let engine = try await makeShopEngine()
        let response = await engine.execute(
            GraphQLRequest(query: #"{ products(after: "cursor:-9", before: "cursor:-4") { edges { cursor } } }"#)
        )
        #expect(response.errors.isEmpty)
        #expect(response.data?["products"]["edges"].count == 0)
    }
}

@Suite struct EngineMutationTests {
    private func engineWithHandlers() async throws -> MockQLEngine {
        try await makeShopEngine {
            Mutation("addToCart") { input, state in
                var item: GraphQLValue = [:]
                item["product"] = .reference("Product", id: input["productId"].stringValue ?? "")
                item["quantity"] = input["quantity"] ?? 1
                let inserted = state.insert("CartItem", item)
                state.update("Cart", id: "cart-1") { cart in
                    cart["items"].append(inserted)
                }
                return state["Cart", id: "cart-1"]
            }
            Mutation("updateDisplayName") { input, state in
                state.update("User", id: "user-1") { user in
                    user["name"] = input["name"]
                }
                return state["User", id: "user-1"]
            }
            Mutation("restock") { _, state in
                .list(["p1", "p2", "p3"].map { .reference("Product", id: $0) })
            }
        }
    }

    @Test func skippedMutationFieldDoesNotRunItsHandler() async throws {
        let engine = try await engineWithHandlers()
        let response = await engine.execute(
            GraphQLRequest(
                query: """
                    mutation M($skip: Boolean!) {
                        updateDisplayName(name: "Renamed") @skip(if: $skip) { name }
                        kept: updateDisplayName(name: "Kept") @include(if: false) { name }
                    }
                    """,
                variables: ["skip": true]
            )
        )
        #expect(response.errors.isEmpty)
        #expect(response.data == .object([:]))
        #expect(await engine.store.record(type: "User", id: "user-1")?["name"] == .string("Avery Quinn"))
    }

    @Test func mutationRootFragmentsAreExpanded() async throws {
        let engine = try await engineWithHandlers()
        let response = await engine.execute(
            GraphQLRequest(
                query: """
                    mutation { ...Rename ... on Mutation { __typename } }
                    fragment Rename on Mutation { updateDisplayName(name: "Fragmented") { name } }
                    """
            )
        )
        #expect(response.errors.isEmpty)
        #expect(response.data?["updateDisplayName"]["name"] == .string("Fragmented"))
        #expect(response.data?["__typename"] == .string("Mutation"))
    }

    @Test func fieldsSharingAResponseKeyRunTheHandlerOnce() async throws {
        let engine = try await engineWithHandlers()
        let response = await engine.execute(
            GraphQLRequest(
                query: """
                    mutation {
                        addToCart(productId: "p1") { id }
                        addToCart(productId: "p1") { items { quantity } }
                    }
                    """
            )
        )
        #expect(response.errors.isEmpty)
        // One handler run, and the two selection sets merged into the one result.
        #expect(await engine.store.records(ofType: "CartItem").count == 1)
        #expect(response.data?["addToCart"]["id"] == .string("cart-1"))
        #expect(response.data?["addToCart"]["items"].count == 1)
    }

    @Test func unknownFragmentAtTheMutationRootRunsNoHandler() async throws {
        let engine = try await engineWithHandlers()
        let response = await engine.execute(
            GraphQLRequest(query: #"mutation { updateDisplayName(name: "X") { name } ...Missing }"#)
        )
        #expect(response.errors.first?.message.contains("Unknown fragment 'Missing'") == true)
        #expect(await engine.store.record(type: "User", id: "user-1")?["name"] == .string("Avery Quinn"))
    }

    @Test func omittedVariableLetsTheArgumentDefaultApply() async throws {
        let engine = try await engineWithHandlers()
        let response = await engine.execute(
            GraphQLRequest(
                query: #"mutation M($q: Int) { addToCart(productId: "p1", quantity: $q) { items { quantity } } }"#
            )
        )
        #expect(response.errors.isEmpty)
        #expect(response.data?["addToCart"]["items"][0]["quantity"] == .int(1))
    }

    @Test func nullViolationNamesTheMutationTypeNotQuery() async throws {
        let engine = try await makeShopEngine {
            Mutation("updateDisplayName") { _, _ in .null }
        }
        let response = await engine.execute(
            GraphQLRequest(query: #"mutation { updateDisplayName(name: "X") { name } }"#)
        )
        #expect(response.errors.count == 1)
        #expect(
            response.errors.first?.message
                == "Cannot return null for non-nullable field 'Mutation.updateDisplayName'"
        )
        #expect(response.data == .null)
    }

    @Test func connectionReturningMutationHonorsPaginationArguments() async throws {
        let engine = try await engineWithHandlers()
        let response = await engine.execute(
            GraphQLRequest(
                query: """
                    mutation { restock(first: 1, after: "cursor:0") {
                        totalCount
                        edges { node { name } }
                        pageInfo { hasNextPage hasPreviousPage }
                    } }
                    """
            )
        )
        #expect(response.errors.isEmpty)
        let restock = try #require(response.data?["restock"])
        #expect(restock["totalCount"] == .int(3))
        #expect(restock["edges"].count == 1)
        #expect(restock["edges"][0]["node"]["name"] == .string("Burr Grinder"))
        #expect(restock["pageInfo"]["hasNextPage"] == .bool(true))
        #expect(restock["pageInfo"]["hasPreviousPage"] == .bool(true))
    }

    @Test func mutationUpdatesStateAndResolvesResult() async throws {
        let engine = try await engineWithHandlers()
        let response = await engine.execute(
            GraphQLRequest(
                query: #"mutation { addToCart(productId: "p2") { items { quantity product { name } } } }"#
            )
        )
        #expect(response.errors.isEmpty)
        let items = try #require(response.data?["addToCart"]["items"])
        #expect(items.count == 1)
        #expect(items[0]["quantity"] == .int(1))
        #expect(items[0]["product"]["name"] == .string("Burr Grinder"))

        // State persists: a follow-up query sees the same cart.
        let followUp = await engine.execute(GraphQLRequest(query: "{ cart { items { product { name } } } }"))
        #expect(followUp.data?["cart"]["items"][0]["product"]["name"] == .string("Burr Grinder"))
    }

    @Test func argumentDefaultsApply() async throws {
        let engine = try await engineWithHandlers()
        let response = await engine.execute(
            GraphQLRequest(query: #"mutation { addToCart(productId: "p1", quantity: 3) { items { quantity } } }"#)
        )
        #expect(response.data?["addToCart"]["items"][0]["quantity"] == .int(3))
    }

    @Test func mutationsRunSeriallyAndSeeEachOther() async throws {
        let engine = try await engineWithHandlers()
        let response = await engine.execute(
            GraphQLRequest(
                query: """
                    mutation {
                        first: addToCart(productId: "p1") { items { quantity } }
                        second: addToCart(productId: "p2") { items { quantity } }
                    }
                    """
            )
        )
        #expect(response.data?["first"]["items"].count == 1)
        #expect(response.data?["second"]["items"].count == 2)
    }

    @Test func unregisteredMutationExplainsHowToRegister() async throws {
        let engine = try await makeShopEngine()
        let response = await engine.execute(
            GraphQLRequest(query: #"mutation { addToCart(productId: "p1") { id } }"#)
        )
        let error = try #require(response.errors.first)
        #expect(error.message.contains("No handler registered for mutation 'addToCart'"))
        #expect(error.message.contains(#"Mutation("addToCart")"#))
    }

    @Test func throwingHandlerBecomesFieldError() async throws {
        let engine = try await makeShopEngine {
            Mutation("updateDisplayName") { _, _ in
                throw GraphQLError(message: "name is taken")
            }
        }
        let response = await engine.execute(
            GraphQLRequest(query: #"mutation { updateDisplayName(name: "X") { name } }"#)
        )
        #expect(response.errors.first?.message == "name is taken")
        #expect(response.data == .null)
    }

    @Test func missingRequiredArgumentFailsTheField() async throws {
        let engine = try await engineWithHandlers()
        let response = await engine.execute(GraphQLRequest(query: "mutation { addToCart { id } }"))
        #expect(response.errors.first?.message.contains("Missing required argument 'productId'") == true)
    }
}

@Suite struct EngineDSLTests {
    @Test func standaloneDSLDefinesSchemaAndServes() async throws {
        let engine = try await MockQLEngine {
            Query("currentUser") {
                Object("User") {
                    Field("id", .uuid)
                    Field("name", .fullName)
                    Field("email", .email)
                }
            }
            Seed("User", id: "user-1") {
                Value("name", "Avery Quinn")
            }
            Root("currentUser", "user-1")
        }
        let response = await engine.execute(GraphQLRequest(query: "{ currentUser { id name email } }"))
        #expect(response.errors.isEmpty)
        let user = try #require(response.data?["currentUser"])
        #expect(user["name"] == .string("Avery Quinn"))
        #expect(user["email"].stringValue?.contains("@") == true)
        // The seeded record's own id wins over the generator.
        #expect(user["id"] == .string("user-1"))
    }

    @Test func dynamicMutationsResolveStructurally() async throws {
        let engine = try await MockQLEngine {
            Query("greeting", .constant(.string("hi")))
            Mutation("makeThing") { input, _ in
                ["name": input["name"] ?? "unnamed", "size": 3]
            }
        }
        let response = await engine.execute(
            GraphQLRequest(query: #"mutation { makeThing(name: "Widget") { name size } }"#)
        )
        #expect(response.errors.isEmpty)
        #expect(response.data?["makeThing"]["name"] == .string("Widget"))
        #expect(response.data?["makeThing"]["size"] == .int(3))
    }

    @Test func overlayModeRejectsShapedeclarations() async {
        do {
            _ = try await MockQLEngine(schema: .sdl(shopSDL)) {
                Query("extra") {
                    Object("Extra") { Field("id", .uuid) }
                }
            }
            Issue.record("Expected a configuration error")
        } catch let error as MockQLError {
            #expect(error.category == .configuration)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    private func configurationError(
        @MockQLBuilder _ configuration: @escaping () -> [any MockQLDeclaration]
    ) async -> MockQLError? {
        do {
            _ = try await makeShopEngine(configuration: configuration)
            return nil
        } catch {
            return error as? MockQLError
        }
    }

    @Test func seedFromANonObjectLiteralIsRejected() async {
        let error = await configurationError {
            Seed("Product", id: "p9", ["Kettle", 8900])
        }
        #expect(error?.category == .configuration)
        #expect(error?.message.contains(#"Seed("Product", id: "p9") expects an object of field values"#) == true)
    }

    @Test func seedSettingAFieldTwiceIsRejected() async {
        let error = await configurationError {
            Seed("Product", id: "p9") {
                Value("name", "Kettle")
                Value("name", "Gooseneck Kettle")
            }
        }
        #expect(error?.category == .configuration)
        #expect(error?.message == #"Seed("Product", id: "p9") sets field 'name' more than once; keep one Value"#)
    }

    @Test func rootDeclaredTwiceIsRejected() async {
        let error = await configurationError {
            Root("currentUser", "user-1")
            Root("currentUser", "user-2")
        }
        #expect(error?.category == .configuration)
        #expect(error?.message.contains("Root 'currentUser' is declared more than once") == true)
    }

    @Test func overlayGeneratorBoundTwiceIsRejected() async {
        let error = await configurationError {
            Object("User") { Field("email", .email) }
            Object("User") { Field("email", .constant("fixed@example.com")) }
        }
        #expect(error?.category == .configuration)
        #expect(error?.message == "Generator for 'User.email' is declared more than once")
    }

    @Test func overlayMutationMustExistInSchema() async {
        do {
            _ = try await MockQLEngine(schema: .sdl(shopSDL)) {
                Mutation("addToCrat") { _, _ in .null }
            }
            Issue.record("Expected a configuration error")
        } catch let error as MockQLError {
            #expect(error.message.contains("Did you mean 'addToCart'?"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func dslSeedsLayerOverExternalSeeds() async throws {
        let engine = try await MockQLEngine(schema: .sdl(shopSDL), seed: .yaml(shopSeed)) {
            Seed("Product", id: "p9", ["name": "Tamper", "priceCents": 2500])
            Root("products", ["p1", "p9"])
        }
        let response = await engine.execute(
            GraphQLRequest(query: "{ products { edges { node { name } } } }")
        )
        let edges = try #require(response.data?["products"]["edges"])
        #expect(edges.count == 2)
        #expect(edges[1]["node"]["name"] == .string("Tamper"))
    }
}

@Suite struct EngineSubscriptionTests {
    @Test func publishDeliversResolvedEvents() async throws {
        let engine = try await makeShopEngine()
        let stream = try await engine.subscribe(
            GraphQLRequest(query: "subscription { orderStatusChanged { id status } }")
        )
        try await engine.publish(
            "orderStatusChanged",
            payload: ["id": "order-1", "status": .enumValue("SHIPPED")]
        )
        var iterator = stream.makeAsyncIterator()
        let event = try #require(await iterator.next())
        #expect(event.errors.isEmpty)
        #expect(event.data?["orderStatusChanged"]["id"] == .string("order-1"))
        #expect(event.data?["orderStatusChanged"]["status"] == .enumValue("SHIPPED"))
        await engine.shutdown()
    }

    @Test func payloadFieldsGenerateWhenOmitted() async throws {
        let engine = try await makeShopEngine()
        let stream = try await engine.subscribe(
            GraphQLRequest(query: "subscription { orderStatusChanged { id status } }")
        )
        try await engine.publish("orderStatusChanged", payload: ["id": "order-2"])
        var iterator = stream.makeAsyncIterator()
        let event = try #require(await iterator.next())
        let status = try #require(event.data?["orderStatusChanged"]["status"].enumName)
        #expect(["PENDING", "SHIPPED", "DELIVERED"].contains(status))
        await engine.shutdown()
    }

    @Test func publishingUnknownFieldThrowsWithSuggestion() async throws {
        let engine = try await makeShopEngine()
        do {
            try await engine.publish("orderStatusChange", payload: [:])
            Issue.record("Expected an error")
        } catch let error as MockQLError {
            #expect(error.message.contains("Did you mean 'orderStatusChanged'?"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func subscribingWithoutARequiredArgumentIsRejected() async throws {
        let engine = try await makeShopEngine()
        do {
            _ = try await engine.subscribe(GraphQLRequest(query: "subscription { orderUpdated { id } }"))
            Issue.record("Expected the subscription to be rejected")
        } catch let error as GraphQLError {
            #expect(error.message == "Missing required argument 'id' on field 'orderUpdated'")
        }
        #expect(await engine.activeSubscriptionCount() == 0)
    }

    @Test func subscribingWithAnUnknownArgumentSuggestsTheRightOne() async throws {
        let engine = try await makeShopEngine()
        do {
            _ = try await engine.subscribe(
                GraphQLRequest(query: #"subscription { orderUpdated(idd: "o1") { id } }"#)
            )
            Issue.record("Expected the subscription to be rejected")
        } catch let error as GraphQLError {
            #expect(error.message.contains("Unknown argument 'idd'"))
            #expect(error.message.contains("Did you mean 'id'?"))
        }
    }

    @Test func subscribingWithAMistypedArgumentIsRejected() async throws {
        let engine = try await makeShopEngine()
        await #expect(throws: GraphQLError.self) {
            _ = try await engine.subscribe(
                GraphQLRequest(query: "subscription { orderUpdated(id: true) { id } }")
            )
        }
    }

    @Test func subscriptionArgumentsAcceptVariables() async throws {
        let engine = try await makeShopEngine()
        let stream = try await engine.subscribe(
            GraphQLRequest(
                query: "subscription S($id: ID!) { orderUpdated(id: $id) { id } }",
                variables: ["id": "order-7"]
            )
        )
        try await engine.publish("orderUpdated", payload: ["id": "order-7"])
        var iterator = stream.makeAsyncIterator()
        let event = try #require(await iterator.next())
        #expect(event.data?["orderUpdated"]["id"] == .string("order-7"))
        await engine.shutdown()
    }

    @Test func subscriptionRootFragmentIsExpanded() async throws {
        let engine = try await makeShopEngine()
        let stream = try await engine.subscribe(
            GraphQLRequest(
                query: """
                    subscription { ...Changed }
                    fragment Changed on Subscription { orderStatusChanged { id } }
                    """
            )
        )
        try await engine.publish("orderStatusChanged", payload: ["id": "order-1"])
        var iterator = stream.makeAsyncIterator()
        let event = try #require(await iterator.next())
        #expect(event.data?["orderStatusChanged"]["id"] == .string("order-1"))
        await engine.shutdown()
    }

    @Test func subscriptionNullViolationNamesTheSubscriptionType() async throws {
        let engine = try await makeShopEngine()
        let stream = try await engine.subscribe(
            GraphQLRequest(query: "subscription { orderStatusChanged { id } }")
        )
        try await engine.publish("orderStatusChanged", payload: .null)
        var iterator = stream.makeAsyncIterator()
        let event = try #require(await iterator.next())
        #expect(
            event.errors.map(\.message)
                == ["Cannot return null for non-nullable field 'Subscription.orderStatusChanged'"]
        )
        await engine.shutdown()
    }

    @Test func executeRejectsSubscriptionOperations() async throws {
        let engine = try await makeShopEngine()
        let response = await engine.execute(
            GraphQLRequest(query: "subscription { orderStatusChanged { id } }")
        )
        #expect(response.errors.first?.message.contains("subscribe(_:)") == true)
    }
}

@Suite struct EngineSharedStoreTests {
    @Test func injectedStoreMergesSeedInsteadOfReplacing() async throws {
        // A sibling service (e.g. MockREST) already put state in the shared store.
        let store = StateStore()
        _ = await store.withMutationState { state in
            state.insert("Product", ["id": "existing-1", "name": "Pre-seeded", "priceCents": 100])
        }

        let engine = try await MockQLEngine(schema: .sdl(shopSDL), seed: .yaml(shopSeed), store: store)

        // The engine adopted the shared store rather than making its own…
        #expect(engine.store === store)
        // …its own seed merged in…
        #expect(await store.record(type: "User", id: "user-1") != nil)
        // …and the sibling's pre-existing record survived the merge.
        let existing = await store.record(type: "Product", id: "existing-1")
        #expect(existing?["name"] == .string("Pre-seeded"))

        // Queries resolve records regardless of which service seeded them.
        let response = await engine.execute(GraphQLRequest(query: #"{ product(id: "existing-1") { name } }"#))
        #expect(response.data?["product"]["name"] == .string("Pre-seeded"))
    }

    @Test func omittingTheStoreParameterKeepsAPrivateStore() async throws {
        let first = try await MockQLEngine(schema: .sdl(shopSDL), seed: .yaml(shopSeed))
        let second = try await MockQLEngine(schema: .sdl(shopSDL), seed: .yaml(shopSeed))
        #expect(first.store !== second.store)
    }
}

@Suite struct RequestDecodingTests {
    @Test func decodesStandardJSONBody() throws {
        let body = #"{"query": "{ a }", "operationName": "Op", "variables": {"x": 1}}"#
        let request = try GraphQLRequest(jsonBody: Data(body.utf8))
        #expect(request.query == "{ a }")
        #expect(request.operationName == "Op")
        #expect(request.variables["x"] == .int(1))
    }

    @Test func rejectsBodiesWithoutQuery() {
        #expect(throws: GraphQLError.self) {
            try GraphQLRequest(jsonBody: Data(#"{"variables": {}}"#.utf8))
        }
    }
}
