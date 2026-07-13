import Foundation
import MockCoreTransport
import MockQLCore

/// MockQL's conformance to the MockCore platform's extension seam.
///
/// The engine claims `POST /graphql` and `GET /graphql`, answers the `graphql-transport-ws`
/// WebSocket upgrade for subscriptions, and leaves every other request to its sibling services
/// (or the host's diagnostic 404) — which is what lets REST and GraphQL mocks share one port.
extension MockQLEngine: MockService {
    public var name: String {
        "MockQL"
    }

    public func claims(_ request: MockRequest) -> Bool {
        request.path == "/graphql" && (request.method == "POST" || request.method == "GET")
    }

    public func respond(to request: MockRequest) async -> MockResponse {
        let graphQLRequest: GraphQLRequest
        switch request.method {
        case "POST":
            do {
                graphQLRequest = try GraphQLRequest(jsonBody: request.body)
            } catch let error as GraphQLError {
                return Self.errorResponse(status: 400, message: error.message)
            } catch {
                return Self.errorResponse(status: 400, message: "Invalid request body")
            }
        default:
            guard let parsed = HTTPHandler.requestFromQueryString(uri: request.uri) else {
                return Self.errorResponse(status: 400, message: "GET /graphql requires a 'query' parameter")
            }
            graphQLRequest = parsed
        }
        let result = await execute(graphQLRequest)
        guard let payload = try? result.jsonData() else {
            return Self.errorResponse(status: 500, message: "Failed to serialize response")
        }
        return .json(payload)
    }

    public func webSocketUpgrade(for request: MockRequest) -> MockWebSocketUpgrade? {
        // Exact match: the host consults this hook independently of claims(_:), so a prefix
        // match would let MockQL preempt sibling services on paths like /graphqlx.
        guard request.path == "/graphql" else { return nil }
        return MockWebSocketUpgrade(subprotocol: "graphql-transport-ws") {
            GraphQLWSHandler(engine: self)
        }
    }

    // `shutdown()` — required by `MockService` — is already part of the engine's public API.

    /// A GraphQL-spec error payload (`{"errors": [...]}`) with the given HTTP status.
    private static func errorResponse(status: Int, message: String) -> MockResponse {
        let body =
            (try? GraphQLResponse.requestFailed([GraphQLError(message: message)]).jsonData())
            ?? Data(#"{"errors":[{"message":"internal error"}]}"#.utf8)
        return .json(body, status: status)
    }
}
