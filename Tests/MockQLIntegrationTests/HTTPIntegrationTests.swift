import Foundation
import MockQL
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Full-stack tests: a real server on an ephemeral localhost port, driven over HTTP with
/// URLSession, using the bundled sample schemas and seed files.
@Suite struct ShopOverHTTPTests {
    private func startShopServer() async throws -> MockQLServer {
        try await MockQLServer.start(
            schema: .file(try fixturePath("shop", extension: "graphqls")),
            seed: .file(try fixturePath("checkout", extension: "yaml"))
        ) {
            Mutation("addToCart") { input, state in
                let item = state.insert(
                    "CartItem",
                    [
                        "product": .reference("Product", id: input["productId"].stringValue ?? ""),
                        "quantity": input["quantity"] ?? 1,
                    ]
                )
                state.update("Cart", id: "cart-1") { cart in
                    cart["items"].append(item)
                }
                return state["Cart", id: "cart-1"]
            }
        }
    }

    @Test func queriesResolveSeededDataOverHTTP() async throws {
        let server = try await startShopServer()
        defer { Task { try await server.stop() } }
        let (status, body) = try await post(
            "{ currentUser { name email } cart { owner { name } } }",
            to: server.url
        )
        #expect(status == 200)
        #expect(body["errors"] == .null)
        #expect(body["data"]["currentUser"]["name"] == .string("Avery Quinn"))
        #expect(body["data"]["cart"]["owner"]["name"] == .string("Avery Quinn"))
        try await server.stop()
    }

    @Test func mutationsPersistStateAcrossRequests() async throws {
        let server = try await startShopServer()
        let (_, mutationBody) = try await post(
            #"mutation { addToCart(productId: "product-2", quantity: 2) { items { quantity product { name } } } }"#,
            to: server.url
        )
        #expect(mutationBody["data"]["addToCart"]["items"][0]["product"]["name"] == .string("Burr Grinder"))

        let (_, queryBody) = try await post("{ cart { items { quantity } } }", to: server.url)
        #expect(queryBody["data"]["cart"]["items"][0]["quantity"] == .int(2))
        try await server.stop()
    }

    @Test func connectionsPaginateOverHTTP() async throws {
        let server = try await startShopServer()
        let (_, body) = try await post(
            "{ products(first: 1) { edges { node { name } } pageInfo { hasNextPage } } }",
            to: server.url
        )
        #expect(body["data"]["products"]["edges"].count == 1)
        #expect(body["data"]["products"]["pageInfo"]["hasNextPage"] == .bool(true))
        try await server.stop()
    }

    @Test func embeddedValueObjectsAndGeneratedFieldsResolve() async throws {
        let server = try await startShopServer()
        let (_, body) = try await post(
            #"{ product(id: "product-1") { price { amountCents currency } } currentUser { phone } }"#,
            to: server.url
        )
        #expect(body["data"]["product"]["price"]["amountCents"] == .int(64900))
        #expect(body["data"]["product"]["price"]["currency"] == .string("USD"))
        let phone = try #require(body["data"]["currentUser"]["phone"].stringValue)
        #expect(phone.hasPrefix("+1"))
        try await server.stop()
    }

    @Test func variablesTravelOverHTTP() async throws {
        let server = try await startShopServer()
        let (_, body) = try await post(
            "query Q($id: ID!) { product(id: $id) { name } }",
            variables: ["id": "product-2"],
            to: server.url
        )
        #expect(body["data"]["product"]["name"] == .string("Burr Grinder"))
        try await server.stop()
    }

    @Test func getRequestsHealthAndErrorsBehave() async throws {
        let server = try await startShopServer()

        var components = try #require(URLComponents(url: server.url, resolvingAgainstBaseURL: false))
        components.queryItems = [URLQueryItem(name: "query", value: "{ currentUser { name } }")]
        let getURL = try #require(components.url)
        let (getStatus, getBody) = try await get(getURL)
        #expect(getStatus == 200)
        let parsed = try GraphQLValue.fromJSONData(getBody)
        #expect(parsed["data"]["currentUser"]["name"] == .string("Avery Quinn"))

        let healthURL = try #require(URL(string: "/health", relativeTo: server.url))
        let (healthStatus, healthBody) = try await get(healthURL)
        #expect(healthStatus == 200)
        #expect(String(decoding: healthBody, as: UTF8.self) == "ok")

        let missingURL = try #require(URL(string: "/nope", relativeTo: server.url))
        let (missingStatus, _) = try await get(missingURL)
        #expect(missingStatus == 404)

        var badRequest = URLRequest(url: server.url)
        badRequest.httpMethod = "POST"
        badRequest.httpBody = Data("not json".utf8)
        let (_, badResponse) = try await URLSession.shared.data(for: badRequest)
        #expect((badResponse as? HTTPURLResponse)?.statusCode == 400)

        try await server.stop()
    }

    @Test func graphQLErrorsComeBackInTheResponseBody() async throws {
        let server = try await startShopServer()
        let (status, body) = try await post("{ currentUser { emial } }", to: server.url)
        #expect(status == 200)
        let message = try #require(body["errors"][0]["message"].stringValue)
        #expect(message.contains("Did you mean 'email'?"))
        try await server.stop()
    }
}

@Suite struct TasksOverHTTPTests {
    private func startTasksServer() async throws -> MockQLServer {
        try await MockQLServer.start(
            schema: .file(try fixturePath("tasks", extension: "graphqls")),
            seed: .file(try fixturePath("tasks", extension: "yaml"))
        ) {
            Mutation("completeTask") { input, state in
                let taskID = input["taskId"].stringValue ?? ""
                state.update("Task", id: taskID) { task in
                    task["done"] = true
                }
                return state["Task", id: taskID]
            }
        }
    }

    @Test func interfacesResolveConcreteTypesOverHTTP() async throws {
        let server = try await startTasksServer()
        let (_, body) = try await post(
            """
            {
                board {
                    name
                    tasks {
                        title
                        assignee {
                            __typename
                            displayName
                            ... on Human { email }
                            ... on Bot { version }
                        }
                    }
                }
            }
            """,
            to: server.url
        )
        #expect(body["errors"] == .null)
        let tasks = body["data"]["board"]["tasks"]
        #expect(tasks[0]["assignee"]["__typename"] == .string("Human"))
        #expect(tasks[0]["assignee"]["email"] == .string("avery@example.com"))
        #expect(tasks[0]["assignee"]["version"] == .null)
        #expect(tasks[1]["assignee"]["__typename"] == .string("Bot"))
        #expect(tasks[1]["assignee"]["version"] == .string("2.1"))
        try await server.stop()
    }

    @Test func interfaceListRootsResolve() async throws {
        let server = try await startTasksServer()
        let (_, body) = try await post(
            "{ assignees { __typename displayName } }",
            to: server.url
        )
        #expect(body["data"]["assignees"].count == 2)
        #expect(body["data"]["assignees"][0]["__typename"] == .string("Human"))
        #expect(body["data"]["assignees"][1]["__typename"] == .string("Bot"))
        try await server.stop()
    }

    @Test func mutationAndCustomScalarWorkTogether() async throws {
        let server = try await startTasksServer()
        let (_, body) = try await post(
            #"mutation { completeTask(taskId: "t1") { title done dueAt } }"#,
            to: server.url
        )
        #expect(body["data"]["completeTask"]["done"] == .bool(true))
        // dueAt is a custom scalar with no seeded value: generated as a stable timestamp.
        let dueAt = try #require(body["data"]["completeTask"]["dueAt"].stringValue)
        #expect(dueAt.hasSuffix("Z"))
        try await server.stop()
    }

    @Test func twoServersRunIndependently() async throws {
        let first = try await startTasksServer()
        let second = try await startTasksServer()
        #expect(first.port != second.port)

        _ = try await post(#"mutation { completeTask(taskId: "t1") { done } }"#, to: first.url)
        let (_, firstBody) = try await post(#"{ task(id: "t1") { done } }"#, to: first.url)
        let (_, secondBody) = try await post(#"{ task(id: "t1") { done } }"#, to: second.url)
        #expect(firstBody["data"]["task"]["done"] == .bool(true))
        #expect(secondBody["data"]["task"]["done"] == .bool(false))

        try await first.stop()
        try await second.stop()
    }
}
