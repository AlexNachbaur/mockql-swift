import Foundation
import MockQLCore
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

/// A running MockQL server: the engine plus an HTTP + WebSocket listener on localhost.
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

    private let channel: Channel
    private let group: MultiThreadedEventLoopGroup

    private init(engine: MockQLEngine, channel: Channel, group: MultiThreadedEventLoopGroup, port: Int, host: String)
        throws
    {
        self.engine = engine
        self.channel = channel
        self.group = group
        self.port = port
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = "/graphql"
        guard let httpURL = components.url else {
            throw MockQLError(category: .configuration, message: "Cannot form server URL for host '\(host)'")
        }
        components.scheme = "ws"
        guard let wsURL = components.url else {
            throw MockQLError(category: .configuration, message: "Cannot form WebSocket URL for host '\(host)'")
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: 1 << 20,
            shouldUpgrade: { channel, head in
                guard head.uri.hasPrefix("/graphql") else {
                    return channel.eventLoop.makeSucceededFuture(nil)
                }
                var headers = HTTPHeaders()
                let requested = head.headers[canonicalForm: "Sec-WebSocket-Protocol"]
                if requested.contains(where: { $0.lowercased().contains("graphql-transport-ws") }) {
                    headers.add(name: "Sec-WebSocket-Protocol", value: "graphql-transport-ws")
                }
                return channel.eventLoop.makeSucceededFuture(headers)
            },
            upgradePipelineHandler: { channel, _ in
                channel.pipeline.addHandler(GraphQLWSHandler(engine: engine))
            }
        )
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let httpHandler = HTTPHandler(engine: engine)
                return channel.pipeline.configureHTTPServerPipeline(
                    withServerUpgrade: (
                        upgraders: [upgrader],
                        // Once the connection upgrades to WebSocket, the HTTP handler must
                        // leave the pipeline or it would try to decode WebSocket frames.
                        completionHandler: { _ in
                            channel.pipeline.removeHandler(httpHandler, promise: nil)
                        }
                    )
                ).flatMap {
                    channel.pipeline.addHandler(httpHandler)
                }
            }
        do {
            let channel = try await bootstrap.bind(host: host, port: port).get()
            guard let boundPort = channel.localAddress?.port else {
                try await channel.close()
                try await group.shutdownGracefully()
                throw MockQLError(category: .configuration, message: "Server bound without a local address")
            }
            return try MockQLServer(engine: engine, channel: channel, group: group, port: boundPort, host: host)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
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
        await engine.shutdown()
        try await channel.close()
        try await group.shutdownGracefully()
    }
}
