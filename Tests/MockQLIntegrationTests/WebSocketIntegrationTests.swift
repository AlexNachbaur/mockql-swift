import Foundation
import MockQL
import Testing

// URLSessionWebSocketTask on Linux requires a libcurl with WebSocket support, which the swift
// Docker images don't ship yet — so the network-level graphql-transport-ws test runs on Darwin,
// where macOS CI exercises the (platform-independent) NIO WebSocket path.
#if canImport(Darwin)

    /// A minimal graphql-transport-ws client for driving subscription tests.
    private final class GraphQLWSClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
        private let task: URLSessionWebSocketTask

        init(url: URL) {
            let configuration = URLSessionConfiguration.ephemeral
            let session = URLSession(configuration: configuration)
            var request = URLRequest(url: url)
            request.setValue("graphql-transport-ws", forHTTPHeaderField: "Sec-WebSocket-Protocol")
            self.task = session.webSocketTask(with: request)
            super.init()
            task.resume()
        }

        func send(_ value: GraphQLValue) async throws {
            try await task.send(.string(try value.jsonString()))
        }

        func receive() async throws -> GraphQLValue {
            let message = try await task.receive()
            switch message {
            case .string(let text):
                return try GraphQLValue.fromJSONString(text)
            case .data(let data):
                return try GraphQLValue.fromJSONData(data)
            @unknown default:
                throw TimeoutError()
            }
        }

        /// Receives until a message of the given type arrives (skipping keep-alives).
        func receive(type: String) async throws -> GraphQLValue {
            while true {
                let message = try await receive()
                if message["type"].stringValue == type {
                    return message
                }
            }
        }

        func close() {
            task.cancel(with: .normalClosure, reason: nil)
        }
    }

    @Suite struct GraphQLWSIntegrationTests {
        private func startServer() async throws -> MockQLServer {
            try await MockQLServer.start(
                schema: .file(try fixturePath("shop", extension: "graphqls")),
                seed: .file(try fixturePath("checkout", extension: "yaml"))
            )
        }

        @Test func subscriptionEventsFlowOverTheWire() async throws {
            let server = try await startServer()
            let client = GraphQLWSClient(url: server.webSocketURL)

            try await client.send(["type": "connection_init"])
            let ack = try await withTimeout { try await client.receive(type: "connection_ack") }
            #expect(ack["type"] == .string("connection_ack"))

            try await client.send([
                "type": "subscribe",
                "id": "sub-1",
                "payload": ["query": "subscription { orderStatusChanged { id status } }"],
            ])

            // Wait until the engine has registered the subscriber before publishing.
            try await withTimeout {
                while await server.engine.activeSubscriptionCount() == 0 {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
            }

            try await server.publish(
                "orderStatusChanged",
                payload: ["id": "order-1", "status": .enumValue("SHIPPED")]
            )

            let event = try await withTimeout { try await client.receive(type: "next") }
            #expect(event["id"] == .string("sub-1"))
            #expect(event["payload"]["data"]["orderStatusChanged"]["id"] == .string("order-1"))
            #expect(event["payload"]["data"]["orderStatusChanged"]["status"] == .string("SHIPPED"))

            client.close()
            try await server.stop()
        }

        @Test func pingIsAnsweredWithPong() async throws {
            let server = try await startServer()
            let client = GraphQLWSClient(url: server.webSocketURL)

            try await client.send(["type": "connection_init"])
            _ = try await withTimeout { try await client.receive(type: "connection_ack") }
            try await client.send(["type": "ping"])
            let pong = try await withTimeout { try await client.receive(type: "pong") }
            #expect(pong["type"] == .string("pong"))

            client.close()
            try await server.stop()
        }

        @Test func subscribingBeforeInitIsRejected() async throws {
            let server = try await startServer()
            let client = GraphQLWSClient(url: server.webSocketURL)

            try await client.send([
                "type": "subscribe",
                "id": "sub-1",
                "payload": ["query": "subscription { orderStatusChanged { id } }"],
            ])
            // The server closes the socket with code 4401; the next receive must fail.
            await #expect(throws: (any Error).self) {
                _ = try await withTimeout(seconds: 3) { try await client.receive(type: "next") }
            }

            client.close()
            try await server.stop()
        }

        @Test func completingASubscriptionStopsEvents() async throws {
            let server = try await startServer()
            let client = GraphQLWSClient(url: server.webSocketURL)

            try await client.send(["type": "connection_init"])
            _ = try await withTimeout { try await client.receive(type: "connection_ack") }
            try await client.send([
                "type": "subscribe",
                "id": "sub-1",
                "payload": ["query": "subscription { orderStatusChanged { id } }"],
            ])
            try await withTimeout {
                while await server.engine.activeSubscriptionCount() == 0 {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
            }

            try await client.send(["type": "complete", "id": "sub-1"])
            try await withTimeout {
                while await server.engine.activeSubscriptionCount() > 0 {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
            }
            #expect(await server.engine.activeSubscriptionCount() == 0)

            client.close()
            try await server.stop()
        }

        private func connect(to server: MockQLServer) async throws -> GraphQLWSClient {
            let client = GraphQLWSClient(url: server.webSocketURL)
            try await client.send(["type": "connection_init"])
            _ = try await withTimeout { try await client.receive(type: "connection_ack") }
            return client
        }

        @Test func errorIsTerminalAndNotFollowedByComplete() async throws {
            let server = try await startServer()
            let client = try await connect(to: server)

            try await client.send([
                "type": "subscribe",
                "id": "bad",
                "payload": ["query": "subscription { orderStatusChange { id } }"],
            ])
            let error = try await withTimeout { try await client.receive() }
            #expect(error["type"] == .string("error"))
            #expect(error["id"] == .string("bad"))
            #expect(error["payload"][0]["message"].stringValue?.contains("Did you mean 'orderStatusChanged'?") == true)

            // Whatever the server says next must be the answer to this ping, not a `complete`.
            try await client.send(["type": "ping"])
            let next = try await withTimeout { try await client.receive() }
            #expect(next["type"] == .string("pong"))

            client.close()
            try await server.stop()
        }

        @Test func queryOverTheSocketYieldsOneResultThenCompletes() async throws {
            let server = try await startServer()
            let client = try await connect(to: server)

            try await client.send([
                "type": "subscribe",
                "id": "q1",
                "payload": ["query": "{ currentUser { name } }"],
            ])
            let result = try await withTimeout { try await client.receive() }
            #expect(result["type"] == .string("next"))
            #expect(result["id"] == .string("q1"))
            #expect(result["payload"]["data"]["currentUser"]["name"] == .string("Avery Quinn"))
            let complete = try await withTimeout { try await client.receive() }
            #expect(complete["type"] == .string("complete"))
            #expect(complete["id"] == .string("q1"))

            client.close()
            try await server.stop()
        }

        @Test func mutationOverTheSocketChangesState() async throws {
            let server = try await MockQLServer.start(
                schema: .file(try fixturePath("shop", extension: "graphqls")),
                seed: .file(try fixturePath("checkout", extension: "yaml"))
            ) {
                Mutation("updateDisplayName") { input, state in
                    state.update("User", id: "user-1") { $0["name"] = input["name"] }
                    return state["User", id: "user-1"]
                }
            }
            let client = try await connect(to: server)

            try await client.send([
                "type": "subscribe",
                "id": "m1",
                "payload": [
                    "query": "mutation Rename($name: String!) { updateDisplayName(name: $name) { name } }",
                    "variables": ["name": "Socket Renamed"],
                ],
            ])
            let result = try await withTimeout { try await client.receive() }
            #expect(result["type"] == .string("next"))
            #expect(result["payload"]["data"]["updateDisplayName"]["name"] == .string("Socket Renamed"))
            let complete = try await withTimeout { try await client.receive() }
            #expect(complete["type"] == .string("complete"))

            let (_, body) = try await post("{ currentUser { name } }", to: server.url)
            #expect(body["data"]["currentUser"]["name"] == .string("Socket Renamed"))

            client.close()
            try await server.stop()
        }

        @Test func unparseableOperationOverTheSocketIsAnError() async throws {
            let server = try await startServer()
            let client = try await connect(to: server)

            try await client.send(["type": "subscribe", "id": "x", "payload": ["query": "{ currentUser {"]])
            let message = try await withTimeout { try await client.receive() }
            #expect(message["type"] == .string("error"))
            #expect(message["id"] == .string("x"))
            #expect(message["payload"].count == 1)

            client.close()
            try await server.stop()
        }

        @Test func reusingAnIDAfterCompleteStartsACleanSubscription() async throws {
            let server = try await startServer()
            let client = try await connect(to: server)

            try await client.send([
                "type": "subscribe",
                "id": "a",
                "payload": ["query": "subscription { orderStatusChanged { id } }"],
            ])
            try await withTimeout {
                while await server.engine.activeSubscriptionCount() == 0 {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
            }

            // Complete "a" and reuse the id straight away, under an alias that tells the two apart.
            try await client.send(["type": "complete", "id": "a"])
            try await client.send([
                "type": "subscribe",
                "id": "a",
                "payload": ["query": "subscription { changed: orderStatusChanged { id } }"],
            ])

            // Publish until the new subscription answers. The first thing said about the *new*
            // operation must be its event — not a stale `complete` left over from the one it
            // replaced. An event for the old operation (no alias) may legitimately arrive first
            // if a publish lands before the server has processed the `complete`; skip those.
            let publisher = Task {
                while !Task.isCancelled {
                    try await server.publish("orderStatusChanged", payload: ["id": "order-9"])
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
            }
            let message = try await withTimeout {
                while true {
                    let candidate = try await client.receive()
                    let isOldOperationEvent =
                        candidate["type"] == .string("next")
                        && candidate["payload"]["data"]["orderStatusChanged"] != .null
                    if !isOldOperationEvent {
                        return candidate
                    }
                }
            }
            publisher.cancel()
            #expect(message["type"] == .string("next"))
            #expect(message["id"] == .string("a"))
            #expect(message["payload"]["data"]["changed"]["id"] == .string("order-9"))

            // The server still tracks the new operation, so completing it ends it.
            try await client.send(["type": "complete", "id": "a"])
            try await withTimeout {
                while await server.engine.activeSubscriptionCount() > 0 {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
            }

            client.close()
            try await server.stop()
        }

        @Test func subscriptionsFlowOverACustomSubscriptionPath() async throws {
            // Mirror a server that serves queries/mutations on /graphql but subscriptions on a
            // dedicated realtime path — the client should reach both without special-casing.
            let server = try await MockQLServer.start(
                schema: .file(try fixturePath("shop", extension: "graphqls")),
                seed: .file(try fixturePath("checkout", extension: "yaml")),
                subscriptionPath: "/realtime/connect"
            )
            #expect(server.url.path == "/graphql")
            #expect(server.webSocketURL.path == "/realtime/connect")

            let client = GraphQLWSClient(url: server.webSocketURL)
            try await client.send(["type": "connection_init"])
            _ = try await withTimeout { try await client.receive(type: "connection_ack") }
            try await client.send([
                "type": "subscribe",
                "id": "sub-1",
                "payload": ["query": "subscription { orderStatusChanged { id status } }"],
            ])
            try await withTimeout {
                while await server.engine.activeSubscriptionCount() == 0 {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
            }

            try await server.publish(
                "orderStatusChanged",
                payload: ["id": "order-1", "status": .enumValue("SHIPPED")]
            )

            let event = try await withTimeout { try await client.receive(type: "next") }
            #expect(event["id"] == .string("sub-1"))
            #expect(event["payload"]["data"]["orderStatusChanged"]["id"] == .string("order-1"))

            client.close()
            try await server.stop()
        }
    }

#endif
