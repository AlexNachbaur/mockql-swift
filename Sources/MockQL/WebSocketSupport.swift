import Foundation

/// Reassembles a WebSocket text message from its frames.
///
/// A message may arrive split across a `text` frame and any number of `continuation` frames,
/// and the split falls on a byte boundary, not a character boundary — a multi-byte UTF-8
/// character can straddle two frames. So the bytes are joined first and decoded once, when the
/// final frame arrives; decoding each frame on its own corrupts exactly those characters.
struct TextMessageAssembler {
    /// The outcome of feeding one frame to the assembler.
    enum Outcome: Equatable {
        /// More frames are needed before the message is complete.
        case incomplete
        /// The final frame arrived; this is the whole message.
        case message(String)
        /// The final frame arrived, but the joined bytes are not valid UTF-8.
        case invalidUTF8
        /// A `continuation` frame arrived with no `text` frame before it (RFC 6455 §5.4).
        case unexpectedContinuation
        /// The message grew past ``maxMessageSize`` before its final frame arrived.
        case tooLarge
    }

    /// The most bytes one message may span. NIO caps each *frame*; without a cap here a client
    /// sending endless non-final continuation frames would grow memory without bound.
    static let maxMessageSize = 16 * 1024 * 1024

    private var pending: [UInt8] = []
    private var isAssembling = false

    /// Adds one frame's payload.
    ///
    /// - Parameters:
    ///   - bytes: The frame's unmasked payload.
    ///   - startsMessage: `true` for a `text` frame, `false` for a `continuation` frame. A new
    ///     `text` frame discards any unfinished message before it.
    ///   - isFinal: The frame's FIN bit.
    mutating func append(_ bytes: [UInt8], startsMessage: Bool, isFinal: Bool) -> Outcome {
        if startsMessage {
            pending.removeAll(keepingCapacity: true)
            isAssembling = true
        } else if !isAssembling {
            return .unexpectedContinuation
        }
        guard pending.count + bytes.count <= Self.maxMessageSize else {
            pending.removeAll()
            isAssembling = false
            return .tooLarge
        }
        pending.append(contentsOf: bytes)
        guard isFinal else { return .incomplete }
        isAssembling = false
        defer { pending.removeAll(keepingCapacity: true) }
        guard let text = String(bytes: pending, encoding: .utf8) else { return .invalidUTF8 }
        return .message(text)
    }
}

/// The operations running on one WebSocket connection, keyed by the id the client chose.
///
/// A client may reuse an id as soon as it has completed the previous operation, while that
/// operation's task is still winding down. Each registration therefore gets a token, and a
/// finishing task can only remove the entry it was registered under — never a newer operation
/// that has since taken the same id.
struct OperationRegistry {
    private var entries: [String: (token: UInt64, task: Task<Void, Never>)] = [:]
    private var lastToken: UInt64 = 0

    /// Whether an operation is registered under `id`.
    func contains(_ id: String) -> Bool {
        entries[id] != nil
    }

    /// The number of registered operations.
    var count: Int {
        entries.count
    }

    /// A token unique to one registration on this connection.
    mutating func makeToken() -> UInt64 {
        lastToken += 1
        return lastToken
    }

    /// Registers `task` as the operation running under `id`.
    mutating func insert(_ task: Task<Void, Never>, id: String, token: UInt64) {
        entries[id] = (token, task)
    }

    /// Cancels and forgets the operation under `id` — the client sent `complete`.
    mutating func cancel(id: String) {
        entries.removeValue(forKey: id)?.task.cancel()
    }

    /// Forgets the operation under `id` once its task has finished, but only if `token` still
    /// identifies it.
    mutating func finish(id: String, token: UInt64) {
        guard entries[id]?.token == token else { return }
        entries[id] = nil
    }

    /// Cancels and forgets every operation — the connection is closing.
    mutating func cancelAll() {
        for entry in entries.values {
            entry.task.cancel()
        }
        entries.removeAll()
    }
}
