import Foundation
import Testing

@testable import MockQL

@Suite struct QueryStringParsingTests {
    @Test func parsesQueryOperationNameAndVariables() throws {
        let uri =
            "/graphql?query=%7B%20a%20%7D&operationName=Op&variables=%7B%22x%22%3A%201%7D"
        let request = try #require(HTTPHandler.requestFromQueryString(uri: uri))
        #expect(request.query == "{ a }")
        #expect(request.operationName == "Op")
        #expect(request.variables["x"] == .int(1))
    }

    @Test func missingQueryParameterReturnsNil() {
        #expect(HTTPHandler.requestFromQueryString(uri: "/graphql?operationName=Op") == nil)
        #expect(HTTPHandler.requestFromQueryString(uri: "/graphql") == nil)
    }

    @Test func malformedVariablesAreIgnoredNotFatal() throws {
        let request = try #require(
            HTTPHandler.requestFromQueryString(uri: "/graphql?query=%7B%20a%20%7D&variables=nope")
        )
        #expect(request.variables.isEmpty)
    }
}

@Suite struct ServerLifecycleTests {
    @Test func startsOnEphemeralPortAndStops() async throws {
        let server = try await MockQLServer.start {
            Query("greeting", .constant(.string("hi")))
        }
        #expect(server.port > 0)
        #expect(server.url.absoluteString == "http://127.0.0.1:\(server.port)/graphql")
        #expect(server.webSocketURL.absoluteString == "ws://127.0.0.1:\(server.port)/graphql")

        // In-process execution works without any HTTP round-trip.
        let response = await server.execute(GraphQLRequest(query: "{ greeting }"))
        #expect(response.data?["greeting"] == .string("hi"))

        try await server.stop()
    }

    @Test func invalidSeedFailsBeforeTheServerStarts() async {
        do {
            _ = try await MockQLServer.start(
                schema: .sdl("type Query { user: User } type User { id: ID! name: String! }"),
                seed: .yaml(
                    """
                    version: 1
                    data:
                      User:
                        - { id: u1, nmae: Avery }
                    """
                )
            )
            Issue.record("Expected a seed validation error")
        } catch let error as MockQLError {
            #expect(error.category == .seed)
            #expect(error.message.contains("Did you mean 'name'?"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}

@Suite struct ConfigurableTransportPathTests {
    @Test func facadeReflectsCustomSubscriptionPath() async throws {
        let server = try await MockQLServer.start(subscriptionPath: "/realtime/connect") {
            Query("greeting", .constant(.string("hi")))
        }
        // GraphQL over HTTP stays on /graphql; only the WebSocket URL moves.
        #expect(server.url.absoluteString == "http://127.0.0.1:\(server.port)/graphql")
        #expect(server.webSocketURL.absoluteString == "ws://127.0.0.1:\(server.port)/realtime/connect")
        try await server.stop()
    }

    @Test func serviceRoutesHTTPAndWebSocketOnConfiguredPaths() async throws {
        let server = try await MockQLServer.start {
            Query("greeting", .constant(.string("hi")))
        }
        let service = server.engine.service(subscriptionPath: "/realtime/connect")

        // Queries/mutations remain on /graphql.
        #expect(service.claims(MockRequest(method: "POST", uri: "/graphql")))
        #expect(!service.claims(MockRequest(method: "POST", uri: "/realtime/connect")))

        // The graphql-transport-ws upgrade answers on the configured subscription path only.
        #expect(service.webSocketUpgrade(for: MockRequest(method: "GET", uri: "/realtime/connect")) != nil)
        #expect(service.webSocketUpgrade(for: MockRequest(method: "GET", uri: "/graphql")) == nil)

        try await server.stop()
    }

    @Test func defaultsServeBothOnGraphQL() async throws {
        let server = try await MockQLServer.start {
            Query("greeting", .constant(.string("hi")))
        }
        // Default engine-as-service and the explicit default service both serve the WS on /graphql.
        #expect(server.engine.webSocketUpgrade(for: MockRequest(method: "GET", uri: "/graphql")) != nil)
        #expect(server.engine.webSocketUpgrade(for: MockRequest(method: "GET", uri: "/realtime/connect")) == nil)
        let service = server.engine.service()
        #expect(service.claims(MockRequest(method: "POST", uri: "/graphql")))
        #expect(service.webSocketUpgrade(for: MockRequest(method: "GET", uri: "/graphql")) != nil)

        try await server.stop()
    }

    @Test func customHTTPPathMovesClaimsOffGraphQL() async throws {
        let server = try await MockQLServer.start {
            Query("greeting", .constant(.string("hi")))
        }
        let service = server.engine.service(httpPath: "/gql")
        #expect(service.claims(MockRequest(method: "POST", uri: "/gql")))
        #expect(!service.claims(MockRequest(method: "POST", uri: "/graphql")))
        try await server.stop()
    }

    @Test func pathsWithoutLeadingSlashAreNormalized() async throws {
        // Bare segments route and produce well-formed URLs identically to rooted paths.
        let server = try await MockQLServer.start(httpPath: "gql", subscriptionPath: "realtime") {
            Query("greeting", .constant(.string("hi")))
        }
        #expect(server.url.path == "/gql")
        #expect(server.webSocketURL.path == "/realtime")

        let service = server.engine.service(httpPath: "gql", subscriptionPath: "realtime")
        #expect(service.httpPath == "/gql")
        #expect(service.subscriptionPath == "/realtime")
        #expect(service.claims(MockRequest(method: "POST", uri: "/gql")))

        try await server.stop()
    }
}

@Suite struct ServerConfigurationTests {
    private let sdl = "type Query { tags(kind: String): [Tag!]! } type Tag { id: ID! kind: String! }"
    private let seed = """
        version: 1
        data:
          Tag:
            - { id: t1, kind: color }
            - { id: t2, kind: size }
        roots:
          tags: [t1, t2]
        """

    @Test func startCanEnableDiagnostics() async throws {
        let server = try await MockQLServer.start(schema: .sdl(sdl), seed: .yaml(seed), diagnostics: true)
        let response = await server.execute(GraphQLRequest(query: #"{ tags(kind: "color") { id } }"#))
        let field = try #require(response.extensions?["mockql"]["fields"]["Query.tags"])
        #expect(field["filteredBy"] == ["kind"])
        #expect(field["returned"] == .int(1))
        try await server.stop()
    }

    @Test func diagnosticsStayOffByDefault() async throws {
        let server = try await MockQLServer.start(schema: .sdl(sdl), seed: .yaml(seed))
        let response = await server.execute(GraphQLRequest(query: #"{ tags(kind: "color") { id } }"#))
        #expect(response.extensions == nil)
        try await server.stop()
    }

    @Test func startCanShareAStateStore() async throws {
        let shared = StateStore()
        await shared.withMutationState { state in
            state["Tag", id: "t0"] = ["kind": "preexisting"]
        }
        let server = try await MockQLServer.start(schema: .sdl(sdl), seed: .yaml(seed), store: shared)
        // The server reads and writes the store it was handed, and merged its seed into it.
        #expect(await shared.records(ofType: "Tag").count == 3)
        #expect(await server.engine.store.record(type: "Tag", id: "t0")?["kind"] == .string("preexisting"))
        try await server.stop()
    }
}

@Suite struct GetRequestTests {
    private func makeService(counter: StateStore) async throws -> MockQLService {
        let engine = try await MockQLEngine(
            schema: .sdl("type Query { hits: Int! } type Mutation { hit: Int! }"),
            store: counter
        ) {
            Mutation("hit") { _, state in
                state["Counter", id: "c"] = ["n": 1]
                return 1
            }
        }
        return engine.service()
    }

    private func getRequest(_ query: String, operationName: String? = nil) throws -> MockRequest {
        var components = URLComponents()
        components.path = "/graphql"
        components.queryItems = [URLQueryItem(name: "query", value: query)]
        if let operationName {
            components.queryItems?.append(URLQueryItem(name: "operationName", value: operationName))
        }
        return MockRequest(method: "GET", uri: try #require(components.string))
    }

    @Test func getRefusesToRunAMutation() async throws {
        let store = StateStore()
        let service = try await makeService(counter: store)
        let response = await service.respond(to: try getRequest("mutation { hit }"))

        #expect(response.status == 405)
        #expect(response.headers.contains { $0.name == "Allow" && $0.value == "GET, POST" })
        let body = try GraphQLValue.fromJSONData(response.body)
        #expect(
            body["errors"][0]["message"]
                == .string("Mutations must be sent with POST; a GET request can only run a query")
        )
        // A request-level refusal omits `data` entirely (the subscript would read a missing key
        // as `.null` too, so check the key itself).
        #expect(body.objectValue?["data"] == nil)
        // The handler never ran.
        #expect(await store.record(type: "Counter", id: "c") == nil)
    }

    @Test func getChecksTheOperationSelectedByName() async throws {
        let store = StateStore()
        let service = try await makeService(counter: store)
        let document = "query Read { hits } mutation Write { hit }"

        let read = await service.respond(to: try getRequest(document, operationName: "Read"))
        #expect(read.status == 200)

        let write = await service.respond(to: try getRequest(document, operationName: "Write"))
        #expect(write.status == 405)
        #expect(await store.record(type: "Counter", id: "c") == nil)
    }

    @Test func postStillRunsMutations() async throws {
        let store = StateStore()
        let service = try await makeService(counter: store)
        let body = try GraphQLValue.object(["query": "mutation { hit }"]).jsonData()
        let response = await service.respond(to: MockRequest(method: "POST", uri: "/graphql", body: body))
        #expect(response.status == 200)
        #expect(await store.record(type: "Counter", id: "c") != nil)
    }
}

@Suite struct TextMessageAssemblerTests {
    @Test func unfragmentedMessageDecodesImmediately() {
        var assembler = TextMessageAssembler()
        #expect(assembler.append(Array("héllo".utf8), startsMessage: true, isFinal: true) == .message("héllo"))
    }

    @Test func multiByteCharacterSplitAcrossFramesSurvives() throws {
        // "é" is 0xC3 0xA9 and "😀" is four bytes; cut both mid-character.
        let bytes = Array(#"{"type":"ping","note":"é😀"}"#.utf8)
        let firstCut = try #require(bytes.firstIndex(of: 0xC3)) + 1
        let secondCut = try #require(bytes.firstIndex(of: 0xF0)) + 2

        var assembler = TextMessageAssembler()
        #expect(assembler.append(Array(bytes[..<firstCut]), startsMessage: true, isFinal: false) == .incomplete)
        #expect(
            assembler.append(Array(bytes[firstCut..<secondCut]), startsMessage: false, isFinal: false) == .incomplete
        )
        #expect(
            assembler.append(Array(bytes[secondCut...]), startsMessage: false, isFinal: true)
                == .message(#"{"type":"ping","note":"é😀"}"#)
        )
    }

    @Test func invalidUTF8IsReportedNotRepaired() {
        var assembler = TextMessageAssembler()
        #expect(assembler.append([0x7B, 0xC3], startsMessage: true, isFinal: true) == .invalidUTF8)
    }

    @Test func continuationWithoutAStartIsAProtocolError() {
        var assembler = TextMessageAssembler()
        #expect(assembler.append(Array("x".utf8), startsMessage: false, isFinal: true) == .unexpectedContinuation)
        // Still usable for a well-formed message afterwards.
        #expect(assembler.append(Array("ok".utf8), startsMessage: true, isFinal: true) == .message("ok"))
    }

    @Test func messagesAreCappedWhileStillIncomplete() {
        var assembler = TextMessageAssembler()
        let chunk = [UInt8](repeating: 0x61, count: TextMessageAssembler.maxMessageSize / 2)
        #expect(assembler.append(chunk, startsMessage: true, isFinal: false) == .incomplete)
        #expect(assembler.append(chunk, startsMessage: false, isFinal: false) == .incomplete)
        #expect(assembler.append([0x61], startsMessage: false, isFinal: false) == .tooLarge)
        // The oversized message is discarded, and a new one can start.
        #expect(assembler.append(Array("ok".utf8), startsMessage: true, isFinal: true) == .message("ok"))
    }

    @Test func assemblerIsReusableAfterAMessage() {
        var assembler = TextMessageAssembler()
        _ = assembler.append(Array("one".utf8), startsMessage: true, isFinal: true)
        #expect(assembler.append(Array("two".utf8), startsMessage: true, isFinal: true) == .message("two"))
    }

    @Test func newTextFrameDiscardsAnUnfinishedMessage() {
        var assembler = TextMessageAssembler()
        _ = assembler.append(Array("abandoned".utf8), startsMessage: true, isFinal: false)
        #expect(assembler.append(Array("fresh".utf8), startsMessage: true, isFinal: true) == .message("fresh"))
    }
}

@Suite struct OperationRegistryTests {
    @Test func finishingAnOldOperationLeavesItsReusedIDRegistered() {
        var registry = OperationRegistry()
        let oldToken = registry.makeToken()
        registry.insert(Task {}, id: "a", token: oldToken)

        // The client completes "a", then immediately reuses the id.
        registry.cancel(id: "a")
        let newToken = registry.makeToken()
        let replacement = Task {}
        registry.insert(replacement, id: "a", token: newToken)

        // The old task's cleanup arrives late; it must not evict the new operation.
        registry.finish(id: "a", token: oldToken)
        #expect(registry.contains("a"))

        registry.finish(id: "a", token: newToken)
        #expect(!registry.contains("a"))
    }

    @Test func cancelStopsTheTaskAndFreesTheID() async {
        var registry = OperationRegistry()
        let task = Task { while !Task.isCancelled { await Task.yield() } }
        registry.insert(task, id: "a", token: registry.makeToken())
        registry.cancel(id: "a")
        #expect(!registry.contains("a"))
        await task.value
        #expect(task.isCancelled)
    }

    @Test func cancelAllEmptiesTheRegistry() {
        var registry = OperationRegistry()
        let tasks = (0..<3).map { _ in Task {} }
        for (index, task) in tasks.enumerated() {
            registry.insert(task, id: "op-\(index)", token: registry.makeToken())
        }
        #expect(registry.count == 3)
        registry.cancelAll()
        #expect(registry.count == 0)
        #expect(tasks.filter(\.isCancelled).count == 3)
    }
}
