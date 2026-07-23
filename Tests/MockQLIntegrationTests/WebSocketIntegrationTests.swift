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
