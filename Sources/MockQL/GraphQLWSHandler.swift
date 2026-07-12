import Foundation
import MockQLCore
import NIOCore
import NIOWebSocket

/// Speaks the `graphql-transport-ws` subprotocol over an upgraded WebSocket connection:
/// `connection_init`/`connection_ack`, `subscribe`/`next`/`complete`, and `ping`/`pong`.
///
/// `@unchecked Sendable`: mutable state is confined to the channel's event loop, per NIO's
/// channel-handler threading model.
final class GraphQLWSHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let engine: MockQLEngine
    private var acknowledged = false
    private var fragmentedText: String?
    private var subscriptionTasks: [String: Task<Void, Never>] = [:]

    init(engine: MockQLEngine) {
        self.engine = engine
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text:
            let text = frame.unmaskedData.getString(at: 0, length: frame.unmaskedData.readableBytes) ?? ""
            if frame.fin {
                handleMessage(text, context: context)
            } else {
                fragmentedText = text
            }
        case .continuation:
            let text = frame.unmaskedData.getString(at: 0, length: frame.unmaskedData.readableBytes) ?? ""
            fragmentedText = (fragmentedText ?? "") + text
            if frame.fin, let complete = fragmentedText {
                fragmentedText = nil
                handleMessage(complete, context: context)
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
        for task in subscriptionTasks.values {
            task.cancel()
        }
        subscriptionTasks.removeAll()
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
                subscriptionTasks[id]?.cancel()
                subscriptionTasks[id] = nil
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
        guard subscriptionTasks[id] == nil else {
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
        let task = Task {
            await Self.runSubscription(engine: engine, request: request, id: id, channel: channel)
            channel.eventLoop.execute {
                handlerReference.value.subscriptionTasks[id] = nil
            }
        }
        subscriptionTasks[id] = task
    }

    private static func runSubscription(
        engine: MockQLEngine,
        request: GraphQLRequest,
        id: String,
        channel: Channel
    ) async {
        do {
            let stream = try await engine.subscribe(request)
            for await event in stream {
                sendEvent(type: "next", id: id, payload: event.responseValue, channel: channel)
            }
        } catch let error as GraphQLError {
            sendEvent(type: "error", id: id, payload: .list([error.responseValue]), channel: channel)
        } catch {
            let fallback = GraphQLError(message: String(describing: error))
            sendEvent(type: "error", id: id, payload: .list([fallback.responseValue]), channel: channel)
        }
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
