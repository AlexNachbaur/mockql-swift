import Foundation

extension GraphQLValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let list = try? container.decode([GraphQLValue].self) {
            self = .list(list)
        } else if let object = try? container.decode([String: GraphQLValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Value is not representable as a GraphQL value"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .enumValue(let value):
            // Enum values serialize as strings on the wire, per the GraphQL spec.
            try container.encode(value)
        case .list(let elements):
            try container.encode(elements)
        case .object(let fields):
            try container.encode(fields)
        case .reference(let typeName, let id):
            // References are an in-memory construct; if one leaks into serialization, encode a
            // recognizable qualified string rather than crashing.
            try container.encode("\(typeName):\(id)")
        }
    }
}

extension GraphQLValue {
    /// Decodes a `GraphQLValue` tree from JSON data.
    public static func fromJSONData(_ data: Data) throws -> GraphQLValue {
        try JSONDecoder().decode(GraphQLValue.self, from: data)
    }

    /// Decodes a `GraphQLValue` tree from a JSON string.
    public static func fromJSONString(_ string: String) throws -> GraphQLValue {
        try fromJSONData(Data(string.utf8))
    }

    /// Encodes this value tree as JSON data. Object keys are sorted for deterministic output.
    public func jsonData(prettyPrinted: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Encodes this value tree as a JSON string. Object keys are sorted for deterministic output.
    public func jsonString(prettyPrinted: Bool = false) throws -> String {
        String(decoding: try jsonData(prettyPrinted: prettyPrinted), as: UTF8.self)
    }
}
