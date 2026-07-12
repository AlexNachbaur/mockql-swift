/// The complete in-memory state of a MockQL server: records grouped by type, per-type insertion
/// order, and the root `Query` field bindings.
///
/// A plain value type so it can be snapshotted for reads and transactionally replaced by
/// mutations.
struct StoreData: Sendable, Hashable {
    /// Records: type name → record id → object value.
    var records: [String: [String: GraphQLValue]] = [:]
    /// Per-type insertion order of record ids, used for list resolution and pagination.
    var order: [String: [String]] = [:]
    /// Root `Query` field bindings (typically references or lists of references).
    var roots: [String: GraphQLValue] = [:]
    /// Counter backing generated record ids.
    var autoIDCounter: Int = 0

    /// The record of the given type and id, or `nil`.
    func record(type: String, id: String) -> GraphQLValue? {
        records[type]?[id]
    }

    /// All records of a type, in insertion order.
    func allRecords(type: String) -> [GraphQLValue] {
        (order[type] ?? []).compactMap { records[type]?[$0] }
    }

    /// Inserts a record, generating an id when the fields don't carry one.
    /// - Returns: The record's id.
    @discardableResult
    mutating func insert(type: String, fields: [String: GraphQLValue]) -> String {
        var fields = fields
        let id: String
        if let provided = fields["id"]?.stringValue {
            id = provided
        } else {
            autoIDCounter += 1
            id = "\(type.lowercased())-auto-\(autoIDCounter)"
            fields["id"] = .string(id)
        }
        if records[type]?[id] == nil {
            order[type, default: []].append(id)
        }
        records[type, default: [:]][id] = .object(fields)
        return id
    }

    /// Removes a record. Returns `true` when it existed.
    @discardableResult
    mutating func delete(type: String, id: String) -> Bool {
        guard records[type]?.removeValue(forKey: id) != nil else { return false }
        order[type]?.removeAll { $0 == id }
        return true
    }
}
