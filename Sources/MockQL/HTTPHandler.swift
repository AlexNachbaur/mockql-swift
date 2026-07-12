import Foundation
import MockQLCore
import NIOCore
import NIOHTTP1

/// Serves GraphQL over HTTP: `POST /graphql` with a JSON body, `GET /graphql?query=…` for quick
/// manual checks, and `GET /health` for readiness probes.
///
/// `@unchecked Sendable`: mutable state is confined to the channel's event loop, per NIO's
/// channel-handler threading model.
final class HTTPHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let engine: MockQLEngine
    private var requestHead: HTTPRequestHead?
    private var bodyBuffer: ByteBuffer?

    init(engine: MockQLEngine) {
        self.engine = engine
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            requestHead = head
            bodyBuffer = context.channel.allocator.buffer(capacity: 0)
        case .body(var chunk):
            bodyBuffer?.writeBuffer(&chunk)
        case .end:
            guard let head = requestHead else { return }
            let body = bodyBuffer
            requestHead = nil
            bodyBuffer = nil
            route(head: head, body: body, channel: context.channel)
        }
    }

    /// The Sendable subset of a request head needed to write a response.
    private struct ResponseContext: Sendable {
        let version: HTTPVersion
        let keepAlive: Bool
    }

    private func route(head: HTTPRequestHead, body: ByteBuffer?, channel: Channel) {
        let response = ResponseContext(version: head.version, keepAlive: head.isKeepAlive)
        let path = head.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? head.uri
        switch (head.method, path) {
        case (.GET, "/health"):
            Self.send(
                status: .ok, body: Data("ok".utf8), contentType: "text/plain", response: response, channel: channel)
        case (.POST, "/graphql"):
            let data = body.map { Data($0.readableBytesView) } ?? Data()
            let request: GraphQLRequest
            do {
                request = try GraphQLRequest(jsonBody: data)
            } catch let error as GraphQLError {
                Self.sendError(status: .badRequest, message: error.message, response: response, channel: channel)
                return
            } catch {
                Self.sendError(
                    status: .badRequest, message: "Invalid request body", response: response, channel: channel)
                return
            }
            respond(to: request, response: response, channel: channel)
        case (.GET, "/graphql"):
            guard let request = Self.requestFromQueryString(uri: head.uri) else {
                Self.sendError(
                    status: .badRequest,
                    message: "GET /graphql requires a 'query' parameter",
                    response: response,
                    channel: channel
                )
                return
            }
            respond(to: request, response: response, channel: channel)
        default:
            Self.sendError(
                status: .notFound,
                message: "Not found; the GraphQL endpoint is /graphql",
                response: response,
                channel: channel
            )
        }
    }

    private func respond(to request: GraphQLRequest, response: ResponseContext, channel: Channel) {
        let engine = self.engine
        Task {
            await Self.executeAndSend(engine: engine, request: request, response: response, channel: channel)
        }
    }

    private static func executeAndSend(
        engine: MockQLEngine,
        request: GraphQLRequest,
        response: ResponseContext,
        channel: Channel
    ) async {
        let result = await engine.execute(request)
        let payload: Data
        do {
            payload = try result.jsonData()
        } catch {
            sendError(
                status: .internalServerError,
                message: "Failed to serialize response",
                response: response,
                channel: channel
            )
            return
        }
        send(status: .ok, body: payload, contentType: "application/json", response: response, channel: channel)
    }

    // MARK: - Plumbing

    static func requestFromQueryString(uri: String) -> GraphQLRequest? {
        guard let components = URLComponents(string: uri),
            let items = components.queryItems,
            let query = items.first(where: { $0.name == "query" })?.value
        else {
            return nil
        }
        let operationName = items.first(where: { $0.name == "operationName" })?.value
        var variables: [String: GraphQLValue] = [:]
        if let rawVariables = items.first(where: { $0.name == "variables" })?.value,
            let parsed = try? GraphQLValue.fromJSONString(rawVariables),
            let object = parsed.objectValue
        {
            variables = object
        }
        return GraphQLRequest(query: query, operationName: operationName, variables: variables)
    }

    private static func sendError(
        status: HTTPResponseStatus,
        message: String,
        response: ResponseContext,
        channel: Channel
    ) {
        let body =
            (try? GraphQLResponse.requestFailed([GraphQLError(message: message)]).jsonData())
            ?? Data(#"{"errors":[{"message":"internal error"}]}"#.utf8)
        send(status: status, body: body, contentType: "application/json", response: response, channel: channel)
    }

    /// Writes a complete response. Safe to call from any thread; NIO serializes channel writes.
    private static func send(
        status: HTTPResponseStatus,
        body: Data,
        contentType: String,
        response: ResponseContext,
        channel: Channel
    ) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: String(body.count))
        if !response.keepAlive {
            headers.add(name: "Connection", value: "close")
        }
        let responseHead = HTTPResponseHead(version: response.version, status: status, headers: headers)
        var buffer = channel.allocator.buffer(capacity: body.count)
        buffer.writeBytes(body)
        channel.write(HTTPServerResponsePart.head(responseHead), promise: nil)
        channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
        let promise: EventLoopPromise<Void>? = response.keepAlive ? nil : channel.eventLoop.makePromise()
        if let promise {
            promise.futureResult.whenComplete { _ in
                channel.close(promise: nil)
            }
        }
        channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: promise)
    }
}
