extension ASTValue {
    /// Converts a constant (variable-free) document value to a `GraphQLValue`.
    func constantValue() throws -> GraphQLValue {
        switch self {
        case .variable(let name):
            throw MockQLError(category: .schema, message: "Variable '$\(name)' is not allowed in a constant value")
        case .int(let value):
            return .int(value)
        case .float(let value):
            return .double(value)
        case .string(let value):
            return .string(value)
        case .bool(let value):
            return .bool(value)
        case .null:
            return .null
        case .enumValue(let value):
            return .enumValue(value)
        case .list(let elements):
            return .list(try elements.map { try $0.constantValue() })
        case .object(let fields):
            return .object(try fields.mapValues { try $0.constantValue() })
        }
    }
}
