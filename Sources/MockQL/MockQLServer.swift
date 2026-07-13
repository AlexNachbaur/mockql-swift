import Foundation
import MockCoreTransport
import MockQLCore

/// A running MockQL server: the engine served over HTTP + WebSocket on localhost.
///
/// ```swift
/// let server = try await MockQLServer.start(
///     schema: .file("Schemas/shop.graphqls"),
///     seed: .file("Fixtures/checkout.yaml")
/// ) {
///     Mutation("addToCart") { input, state in … }
/// }
///
/// app.launchEnvironment["GRAPHQL_URL"] = server.url.absoluteString
/// ```
///
/// A `MockQLServer` is a single-service `MockHost`. To serve GraphQL alongside other protocol
/// mocks (e.g. MockREST) on one port, register the ``engine`` on a shared `MockHost` instead —
/// it conforms to `MockService`.
public final class MockQLServer: Sendable {
    /// The engine serving this server's requests; use it for in-process execution or state
    /// inspection.
    public let engine: MockQLEngine
    /// The HTTP endpoint (`http://127.0.0.1:<port>/graphql`).
    public let url: URL
    /// The `graphql-transport-ws` WebSocket endpoint (`ws://127.0.0.1:<port>/graphql`).
    public let webSocketURL: URL
    /// The port the server is listening on.
    public let port: Int

    private let host: MockHost

    private init(engine: MockQLEngine, host: MockHost, hostName: String) throws {
        self.engine = engine
        self.host = host
        self.port = host.port
        var components = URLComponents()
        components.scheme = "http"
        components.host = hostName
        components.port = host.port
        components.path = "/graphql"
        guard let httpURL = components.url else {
            throw MockQLError(category: .configuration, message: "Cannot form server URL for host '\(hostName)'")
        }
        components.scheme = "ws"
        guard let wsURL = components.url else {
            throw MockQLError(category: .configuration, message: "Cannot form WebSocket URL for host '\(hostName)'")
        }
        self.url = httpURL
        self.webSocketURL = wsURL
    }

    /// Starts a server on localhost.
    ///
    /// - Parameters:
    ///   - schema: The SDL schema to serve; omit to define the schema in the configuration block.
    ///   - seed: Initial state, validated before the server starts accepting connections.
    ///   - generators: Generators keyed by `"Type.field"`.
    ///   - serverSeed: Seed for deterministic generated data.
    ///   - host: Interface to bind; loopback by default — MockQL is a test tool and should not
    ///     be exposed to real networks.
    ///   - port: Port to bind; `0` picks an ephemeral free port (recommended for parallel tests).
    ///   - configuration: Mutation handlers, seeds, generator bindings — or the whole schema.
    public static func start(
        schema: SchemaSource? = nil,
        seed: SeedSource? = nil,
        generators: [String: FieldGenerator] = [:],
        serverSeed: UInt64 = 0,
        host: String = "127.0.0.1",
        port: Int = 0,
        @MockQLBuilder configuration: () -> [any MockQLDeclaration] = { [] }
    ) async throws -> MockQLServer {
        let engine = try await MockQLEngine(
            schema: schema,
            seed: seed,
            generators: generators,
            serverSeed: serverSeed,
            configuration: configuration
        )
        return try await start(engine: engine, host: host, port: port)
    }

    /// Starts a server wrapping an existing engine.
    public static func start(engine: MockQLEngine, host: String = "127.0.0.1", port: Int = 0) async throws
        -> MockQLServer
    {
        let mockHost = try await MockHost.start(host: host, port: port, services: [engine])
        return try MockQLServer(engine: engine, host: mockHost, hostName: host)
    }

    // MARK: - Test-facing conveniences

    /// Executes an operation in-process (no HTTP round-trip).
    public func execute(_ request: GraphQLRequest) async -> GraphQLResponse {
        await engine.execute(request)
    }

    /// Publishes a subscription event to every connected subscriber of `field`.
    public func publish(_ field: String, payload: GraphQLValue) async throws {
        try await engine.publish(field, payload: payload)
    }

    /// Stops accepting connections, ends all subscription streams, and releases the port.
    public func stop() async throws {
        try await host.stop()
    }
}
