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
