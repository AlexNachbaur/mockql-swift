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
