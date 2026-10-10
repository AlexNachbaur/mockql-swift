import Foundation

/// Tracks active subscription operations and fans published events out to them.
actor SubscriptionHub {
    /// Everything needed to resolve a published payload for one subscriber: its root field, the
    /// arguments it subscribed with, and its own selection set.
    struct Subscriber {
        let rootField: String
        let responseKey: String
        let fieldType: TypeReference
        let arguments: GraphQLValue
        let selections: [SelectionNode]
        let fragments: [String: FragmentDefinitionNode]
        let variables: [String: GraphQLValue]
        let declaredVariables: Set<String>
    }

    private struct Entry {
        let subscriber: Subscriber
        let continuation: AsyncStream<GraphQLResponse>.Continuation
    }

    private var entries: [UUID: Entry] = [:]

    /// Registers a subscriber and returns its event stream.
    func register(_ subscriber: Subscriber) -> AsyncStream<GraphQLResponse> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<GraphQLResponse>.makeStream()
        continuation.onTermination = { _ in
            Task { await self.remove(id) }
        }
        entries[id] = Entry(subscriber: subscriber, continuation: continuation)
        return stream
    }

    private func remove(_ id: UUID) {
        entries.removeValue(forKey: id)
    }

    /// The subscribers currently listening to a subscription field.
    func subscribers(
        to rootField: String
    ) -> [(subscriber: Subscriber, continuation: AsyncStream<GraphQLResponse>.Continuation)] {
        entries.values.filter { $0.subscriber.rootField == rootField }.map { ($0.subscriber, $0.continuation) }
    }

    /// The number of active subscribers (all fields).
    var activeCount: Int {
        entries.count
    }

    /// Ends every active stream (server shutdown).
    func finishAll() {
        for entry in entries.values {
            entry.continuation.finish()
        }
        entries.removeAll()
    }
}
