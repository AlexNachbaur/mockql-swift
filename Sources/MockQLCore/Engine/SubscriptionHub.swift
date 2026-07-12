import Foundation

/// Tracks active subscription operations and fans published events out to them.
actor SubscriptionHub {
    struct Entry {
        let id: UUID
        let rootField: String
        let responseKey: String
        let fieldType: TypeReference
        let selections: [SelectionNode]
        let fragments: [String: FragmentDefinitionNode]
        let variables: [String: GraphQLValue]
        let continuation: AsyncStream<GraphQLResponse>.Continuation
    }

    private var entries: [UUID: Entry] = [:]

    /// Registers a subscriber and returns its event stream.
    func register(
        rootField: String,
        responseKey: String,
        fieldType: TypeReference,
        selections: [SelectionNode],
        fragments: [String: FragmentDefinitionNode],
        variables: [String: GraphQLValue]
    ) -> AsyncStream<GraphQLResponse> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<GraphQLResponse>.makeStream()
        continuation.onTermination = { _ in
            Task { await self.remove(id) }
        }
        entries[id] = Entry(
            id: id,
            rootField: rootField,
            responseKey: responseKey,
            fieldType: fieldType,
            selections: selections,
            fragments: fragments,
            variables: variables,
            continuation: continuation
        )
        return stream
    }

    private func remove(_ id: UUID) {
        entries.removeValue(forKey: id)
    }

    /// The subscribers currently listening to a subscription field.
    func subscribers(to rootField: String) -> [Entry] {
        entries.values.filter { $0.rootField == rootField }
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
