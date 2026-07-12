extension Schema {
    /// Structural description of a Relay-style connection type.
    struct ConnectionInfo {
        /// The connection type's name (e.g. `ProductConnection`).
        let connectionTypeName: String
        /// The edge type's name (e.g. `ProductEdge`).
        let edgeTypeName: String
        /// The node type's name (e.g. `Product`).
        let nodeTypeName: String
        /// `true` when the connection declares a `pageInfo` field.
        let hasPageInfo: Bool
        /// `true` when the connection declares a `totalCount` field.
        let hasTotalCount: Bool
    }

    /// Detects Relay-style connections structurally: an object type with an `edges` list whose
    /// element type declares a `node` field. Name suffixes are not required, so nonstandard
    /// connection names still work.
    func connectionInfo(for typeName: String) -> ConnectionInfo? {
        guard let connection = objectType(named: typeName),
            let edgesField = connection.field(named: "edges"),
            let edgeElement = edgesField.type.nullable.listElementType,
            let edgeType = objectType(named: edgeElement.namedTypeName),
            let nodeField = edgeType.field(named: "node")
        else {
            return nil
        }
        return ConnectionInfo(
            connectionTypeName: connection.name,
            edgeTypeName: edgeType.name,
            nodeTypeName: nodeField.type.namedTypeName,
            hasPageInfo: connection.field(named: "pageInfo") != nil,
            hasTotalCount: connection.field(named: "totalCount") != nil
        )
    }
}
