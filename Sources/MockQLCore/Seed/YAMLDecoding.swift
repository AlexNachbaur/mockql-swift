import Yams

/// Converts YAML text into a `GraphQLValue` tree using YAML core-schema scalar resolution.
struct YAMLDecoding {
    /// Decodes a YAML document. Quoted scalars stay strings; plain scalars resolve to
    /// null/bool/int/float where they match, matching what seed authors expect from YAML.
    static func decode(_ text: String, sourceName: String?) throws -> GraphQLValue {
        let root: Node?
        do {
            root = try Yams.compose(yaml: text)
        } catch let error as YamlError {
            throw MockQLError(
                category: .seed,
                message: "Seed document is not valid YAML: \(error)",
                sourceName: sourceName
            )
        }
        guard let root else {
            return .object([:])
        }
        return try value(from: root, sourceName: sourceName)
    }

    private static func value(from node: Node, sourceName: String?) throws -> GraphQLValue {
        switch node {
        case .scalar(let scalar):
            return scalarValue(scalar)
        case .sequence(let sequence):
            return .list(try sequence.map { try value(from: $0, sourceName: sourceName) })
        case .mapping(let mapping):
            var fields: [String: GraphQLValue] = [:]
            for (keyNode, valueNode) in mapping {
                guard let key = keyNode.string else {
                    throw MockQLError(
                        category: .seed,
                        message: "Seed mapping keys must be strings",
                        sourceName: sourceName
                    )
                }
                fields[key] = try value(from: valueNode, sourceName: sourceName)
            }
            return .object(fields)
        default:
            throw MockQLError(
                category: .seed,
                message: "Unsupported YAML construct in seed document (anchors/aliases are not supported)",
                sourceName: sourceName
            )
        }
    }

    private static func scalarValue(_ scalar: Node.Scalar) -> GraphQLValue {
        // Quoted or block scalars are always strings; only plain scalars resolve to other types.
        guard scalar.style == .plain || scalar.style == .any else {
            return .string(scalar.string)
        }
        let text = scalar.string
        if ["null", "Null", "NULL", "~", ""].contains(text) {
            return .null
        }
        if ["true", "True", "TRUE"].contains(text) {
            return .bool(true)
        }
        if ["false", "False", "FALSE"].contains(text) {
            return .bool(false)
        }
        if let int = Int(text) {
            return .int(int)
        }
        if isFloatLiteral(text), let double = Double(text) {
            return .double(double)
        }
        return .string(text)
    }

    /// Only resolve floats for unambiguous numeric literals — `Double("1e5")` and friends would
    /// otherwise swallow strings like version numbers.
    private static func isFloatLiteral(_ text: String) -> Bool {
        var mantissa = Substring(text)
        if mantissa.hasPrefix("-") || mantissa.hasPrefix("+") {
            mantissa = mantissa.dropFirst()
        }
        guard mantissa.contains(".") else { return false }
        let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
            && parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }
}
