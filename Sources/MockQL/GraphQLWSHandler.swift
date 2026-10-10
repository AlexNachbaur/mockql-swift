import Foundation
import MockQLCore
import NIOCore
import NIOWebSocket

/// Speaks the `graphql-transport-ws` subprotocol over an upgraded WebSocket connection:
/// `connection_init`/`connection_ack`, `subscribe`/`next`/`error`/`complete`, and `ping`/`pong`.
///
/// `subscribe` carries any operation, as the protocol allows: a subscription streams `next`
/// messages until it ends, while a query or mutation produces a single `next` and then
/// `complete`.
///
/// `@unchecked Sendable`: mutable state is confined to the channel's event loop, per NIO's
/// channel-handler threading model.
final class GraphQLWSHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let engine: MockQLEngine
    private var acknowledged = false
    private var assembler = TextMessageAssembler()
    private var operations = OperationRegistry()

    init(engine: MockQLEngine) {
        self.engine = engine
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text, .continuation:
            var payload = frame.unmaskedData
            let bytes = payload.readBytes(length: payload.readableBytes) ?? []
            switch assembler.append(bytes, startsMessage: frame.opcode == .text, isFinal: frame.fin) {
            case .incomplete:
                break
            case .message(let text):
                handleMessage(text, context: context)
            case .invalidUTF8:
                close(context: context, code: 1007, reason: "Text message is not valid UTF-8")
            case .unexpectedContinuation:
                close(context: context, code: 1002, reason: "Continuation frame without a message to continue")
            case .tooLarge:
                close(
                    context: context, code: 1009, reason: "Message exceeds \(TextMessageAssembler.maxMessageSize) bytes"
                )
            }
        case .ping:
            var pong = frame
            pong.opcode = .pong
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        case .connectionClose:
            cancelAllSubscriptions()
            context.close(promise: nil)
        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        cancelAllSubscriptions()
        context.fireChannelInactive()
    }

    private func cancelAllSubscriptions() {
        operations.cancelAll()
    }

    // MARK: - Protocol messages

    private func handleMessage(_ text: String, context: ChannelHandlerContext) {
        guard let message = try? GraphQLValue.fromJSONString(text), let type = message["type"].stringValue else {
            close(context: context, code: 4400, reason: "Invalid message")
            return
        }
        switch type {
        case "connection_init":
            guard !acknowledged else {
                close(context: context, code: 4429, reason: "Too many initialisation requests")
                return
            }
            acknowledged = true
            sendText(#"{"type":"connection_ack"}"#, channel: context.channel)
        case "ping":
            sendText(#"{"type":"pong"}"#, channel: context.channel)
        case "pong":
            break
        case "subscribe":
            handleSubscribe(message, context: context)
        case "complete":
            if let id = message["id"].stringValue {
                operations.cancel(id: id)
            }
        default:
            close(context: context, code: 4400, reason: "Unknown message type '\(type)'")
        }
    }

    private func handleSubscribe(_ message: GraphQLValue, context: ChannelHandlerContext) {
        guard acknowledged else {
            close(context: context, code: 4401, reason: "Unauthorized: send connection_init first")
            return
        }
        guard let id = message["id"].stringValue else {
            close(context: context, code: 4400, reason: "subscribe requires an 'id'")
            return
        }
        guard !operations.contains(id) else {
            close(context: context, code: 4409, reason: "Subscriber for \(id) already exists")
            return
        }
        guard let query = message["payload"]["query"].stringValue else {
            close(context: context, code: 4400, reason: "subscribe payload requires a 'query'")
            return
        }
        let request = GraphQLRequest(
            query: query,
            operationName: message["payload"]["operationName"].stringValue,
            variables: message["payload"]["variables"].objectValue ?? [:]
        )
        let engine = self.engine
        let channel = context.channel
        let handlerReference = NIOLoopBound(self, eventLoop: context.eventLoop)
        let token = operations.makeToken()
        let task = Task {
            await Self.runOperation(engine: engine, request: request, id: id, channel: channel)
            channel.eventLoop.execute {
                // Token-checked: by now the client may have completed this operation and started
                // another under the same id, which this cleanup must leave alone.
                handlerReference.value.operations.finish(id: id, token: token)
            }
        }
        operations.insert(task, id: id, token: token)
    }

    private static func runOperation(
        engine: MockQLEngine,
        request: GraphQLRequest,
        id: String,
        channel: Channel
    ) async {
        guard engine.operationType(of: request) == .subscription else {
            await runSingleResultOperation(engine: engine, request: request, id: id, channel: channel)
            return
        }
        do {
            let stream = try await engine.subscribe(request)
            for await event in stream where !Task.isCancelled {
                sendEvent(type: "next", id: id, payload: event.responseValue, channel: channel)
            }
        } catch let error as GraphQLError {
            // `error` is terminal: it ends the operation, and no `complete` follows it.
            sendEvent(type: "error", id: id, payload: .list([error.responseValue]), channel: channel)
            return
        } catch {
            let fallback = GraphQLError(message: String(describing: error))
            sendEvent(type: "error", id: id, payload: .list([fallback.responseValue]), channel: channel)
            return
        }
        // Cancelled means the client completed the operation itself (or the socket closed);
        // answering with `complete` would be addressed to an id it may already have reused.
        guard !Task.isCancelled else { return }
        sendEvent(type: "complete", id: id, payload: nil, channel: channel)
    }

    /// Runs a query or mutation sent over the socket: one `next` carrying the result, then
    /// `complete` — or a lone `error` when the request failed before execution began.
    private static func runSingleResultOperation(
        engine: MockQLEngine,
        request: GraphQLRequest,
        id: String,
        channel: Channel
    ) async {
        let response = await engine.execute(request)
        guard !Task.isCancelled else { return }
        guard response.data != nil else {
            sendEvent(type: "error", id: id, payload: .list(response.errors.map(\.responseValue)), channel: channel)
            return
        }
        sendEvent(type: "next", id: id, payload: response.responseValue, channel: channel)
        sendEvent(type: "complete", id: id, payload: nil, channel: channel)
    }

    // MARK: - Frame writing

    private static func sendEvent(type: String, id: String, payload: GraphQLValue?, channel: Channel) {
        var message: GraphQLValue = ["type": .string(type), "id": .string(id)]
        if let payload {
            message["payload"] = payload
        }
        guard let text = try? message.jsonString() else { return }
        Self.writeText(text, channel: channel)
    }

    private func sendText(_ text: String, channel: Channel) {
        Self.writeText(text, channel: channel)
    }

    private static func writeText(_ text: String, channel: Channel) {
        var buffer = channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .text, data: buffer), promise: nil)
    }

    private func close(context: ChannelHandlerContext, code: UInt16, reason: String) {
        cancelAllSubscriptions()
        var buffer = context.channel.allocator.buffer(capacity: reason.utf8.count + 2)
        buffer.writeInteger(code)
        buffer.writeString(reason)
        let frame = WebSocketFrame(fin: true, opcode: .connectionClose, data: buffer)
        let channel = context.channel
        context.writeAndFlush(wrapOutboundOut(frame)).whenComplete { _ in
            channel.close(promise: nil)
        }
    }
}
