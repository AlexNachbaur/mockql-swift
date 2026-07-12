/// The actor guarding a server's in-memory state.
///
/// Reads take an immutable snapshot; mutations run against a transactional ``MutationState``
/// whose writes are committed atomically when the handler returns.
public actor StateStore {
    private var data = StoreData()

    /// Creates an empty store.
    public init() {}

    /// Replaces the entire store contents (used by seed loading).
    func load(_ data: StoreData) {
        self.data = data
    }

    /// An immutable snapshot of the current state for query execution.
    func snapshot() -> StoreData {
        data
    }

    /// Runs a transactional mutation. Writes are committed only when `body` returns without
    /// throwing.
    func withMutationState<T: Sendable>(
        _ body: @Sendable (inout MutationState) throws -> T
    ) rethrows -> T {
        var state = MutationState(data: data)
        let result = try body(&state)
        data = state.data
        return result
    }

    // MARK: - Convenience accessors

    /// The record of the given type and id, or `nil`.
    public func record(type: String, id: String) -> GraphQLValue? {
        data.record(type: type, id: id)
    }

    /// All records of a type, in insertion order.
    public func records(ofType type: String) -> [GraphQLValue] {
        data.allRecords(type: type)
    }

    /// The current root binding for a `Query` field, or `.null`.
    public func root(_ field: String) -> GraphQLValue {
        data.roots[field] ?? .null
    }

    /// Removes all records and roots.
    public func reset() {
        data = StoreData()
    }
}
