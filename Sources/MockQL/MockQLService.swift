import Foundation
import MockCoreTransport
import MockQLCore

/// Serves a ``MockQLEngine`` over HTTP + the `graphql-transport-ws` WebSocket, with configurable
/// transport paths.
///
/// By default both GraphQL over HTTP (`POST`/`GET`) and the subscription WebSocket upgrade are
/// served on `/graphql`, which is what lets REST and GraphQL mocks share one port. Some servers
/// split the two — queries and mutations on `/graphql`, subscriptions on a dedicated realtime path
/// such as `/realtime/connect`. Pass `subscriptionPath` (and/or `httpPath`) to mirror that layout,
/// so a client configured for the real server talks to the mock without special-casing it.
///
/// ```swift
/// // Subscriptions on a dedicated path; queries/mutations still on /graphql:
/// try await MockHost.start(host: host, port: port) {
///     engine.service(subscriptionPath: "/realtime/connect")
/// }
/// ```
public struct MockQLService: MockService {
    /// The engine backing this service.
    public let engine: MockQLEngine
    /// Path serving GraphQL over HTTP (`POST` and `GET`). Defaults to `/graphql`.
    public let httpPath: String
    /// Path answering the `graphql-transport-ws` WebSocket upgrade. Defaults to `/graphql`.
    public let subscriptionPath: String

    /// Creates a service for `engine`. Both paths default to `/graphql`; override
    /// `subscriptionPath` (and/or `httpPath`) to match a server that separates them.
    public init(engine: MockQLEngine, httpPath: String = "/graphql", subscriptionPath: String = "/graphql") {
        self.engine = engine
        self.httpPath = httpPath
        self.subscriptionPath = subscriptionPath
    }

    public var name: String { "MockQL" }

    public func claims(_ request: MockRequest) -> Bool {
        request.path == httpPath && (request.method == "POST" || request.method == "GET")
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
                return Self.errorResponse(status: 400, message: "GET \(httpPath) requires a 'query' parameter")
            }
            graphQLRequest = parsed
        }
        let result = await engine.execute(graphQLRequest)
        guard let payload = try? result.jsonData() else {
            return Self.errorResponse(status: 500, message: "Failed to serialize response")
        }
        return .json(payload)
    }

    public func webSocketUpgrade(for request: MockRequest) -> MockWebSocketUpgrade? {
        // Exact match: the host consults this hook independently of claims(_:), so a prefix
        // match would let MockQL preempt sibling services on paths like /graphqlx.
        guard request.path == subscriptionPath else { return nil }
        return MockWebSocketUpgrade(subprotocol: "graphql-transport-ws") {
            GraphQLWSHandler(engine: engine)
        }
    }

    public func shutdown() async {
        await engine.shutdown()
    }

    /// A GraphQL-spec error payload (`{"errors": [...]}`) with the given HTTP status.
    private static func errorResponse(status: Int, message: String) -> MockResponse {
        let body =
            (try? GraphQLResponse.requestFailed([GraphQLError(message: message)]).jsonData())
            ?? Data(#"{"errors":[{"message":"internal error"}]}"#.utf8)
        return .json(body, status: status)
    }
}

/// Backwards-compatible conformance: a bare ``MockQLEngine`` is a `MockService` serving `/graphql`
/// for both HTTP and the subscription WebSocket. Use ``MockQLEngine/service(httpPath:subscriptionPath:)``
/// to serve them on different paths.
extension MockQLEngine: MockService {
    public var name: String { asDefaultService.name }

    public func claims(_ request: MockRequest) -> Bool {
        asDefaultService.claims(request)
    }

    public func respond(to request: MockRequest) async -> MockResponse {
        await asDefaultService.respond(to: request)
    }

    public func webSocketUpgrade(for request: MockRequest) -> MockWebSocketUpgrade? {
        asDefaultService.webSocketUpgrade(for: request)
    }

    // `shutdown()` — required by `MockService` — is already part of the engine's public API.

    /// The engine served on the default `/graphql` paths.
    private var asDefaultService: MockQLService { MockQLService(engine: self) }
}

extension MockQLEngine {
    /// Wraps this engine as a ``MockQLService`` with configurable transport paths, for mounting on
    /// a shared `MockHost` alongside other services.
    ///
    /// - Parameters:
    ///   - httpPath: Path serving GraphQL over HTTP. Defaults to `/graphql`.
    ///   - subscriptionPath: Path answering the `graphql-transport-ws` upgrade. Defaults to `/graphql`.
    /// - Returns: A ``MockQLService`` serving this engine on the given paths.
    public func service(httpPath: String = "/graphql", subscriptionPath: String = "/graphql") -> MockQLService {
        MockQLService(engine: self, httpPath: httpPath, subscriptionPath: subscriptionPath)
    }
}
