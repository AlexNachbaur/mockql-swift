/// A dynamically-typed GraphQL value.
///
/// `GraphQLValue` is the currency of MockQL: seed documents, operation arguments, stored records,
/// and response payloads are all modeled as `GraphQLValue` trees. It conforms to the standard
/// literal protocols so values can be written naturally in Swift:
///
/// ```swift
/// let user: GraphQLValue = [
///     "id": "user-1",
///     "name": "Avery Quinn",
///     "age": 34,
///     "tags": ["admin", "beta"],
/// ]
/// ```
public enum GraphQLValue: Hashable, Sendable {
    /// The GraphQL `null` value.
    case null
    /// A `Boolean` value.
    case bool(Bool)
    /// An `Int` value.
    case int(Int)
    /// A `Float` value (GraphQL floats are double-precision).
    case double(Double)
    /// A `String` (or `ID`, or custom-scalar) value.
    case string(String)
    /// An enum value, kept distinct from strings so input coercion can validate it against the schema.
    case enumValue(String)
    /// A list of values.
    case list([GraphQLValue])
    /// An object: named fields mapping to values.
    case object([String: GraphQLValue])
    /// A reference to a stored record. Resolved against the state store when a response is
    /// built; never appears in wire responses.
    case reference(String, id: String)
}

extension GraphQLValue {
    /// `true` when this value is `.null`.
    public var isNull: Bool {
        self == .null
    }

    /// The wrapped `Bool`, if this value is a boolean.
    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// The wrapped `Int`, if this value is an integer.
    public var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    /// The numeric value as a `Double`, if this value is an integer or a float.
    public var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    /// The wrapped `String`, if this value is a string.
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// The enum member name, if this value is an enum value.
    public var enumName: String? {
        if case .enumValue(let value) = self { return value }
        return nil
    }

    /// The wrapped list, if this value is a list.
    public var listValue: [GraphQLValue]? {
        if case .list(let value) = self { return value }
        return nil
    }

    /// The wrapped object fields, if this value is an object.
    public var objectValue: [String: GraphQLValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// The referenced type name and record id, if this value is a reference.
    public var referenceValue: (typeName: String, id: String)? {
        if case .reference(let typeName, let id) = self { return (typeName, id) }
        return nil
    }

    /// Creates a reference from a dynamic id value, so handler code can write
    /// `.reference("Product", id: input["productId"])` directly. String and integer ids are
    /// accepted; anything else produces `.null`.
    public static func reference(_ typeName: String, id: GraphQLValue) -> GraphQLValue {
        switch id {
        case .string(let value):
            return .reference(typeName, id: value)
        case .int(let value):
            return .reference(typeName, id: String(value))
        default:
            return .null
        }
    }

    /// Accesses a field of an object value.
    ///
    /// Reading a missing field — or reading any field of a non-object — returns `.null`, so
    /// lookups chain safely: `state["Cart", id: "cart-1"]["owner"]["name"]`. Writing to a
    /// non-object value replaces it with an object containing just the written field.
    public subscript(key: String) -> GraphQLValue {
        get {
            guard case .object(let fields) = self else { return .null }
            return fields[key] ?? .null
        }
        set {
            var fields = objectValue ?? [:]
            fields[key] = newValue
            self = .object(fields)
        }
    }

    /// Accesses an element of a list value.
    ///
    /// Reading out-of-bounds — or indexing a non-list — returns `.null`. Writing is only applied
    /// to valid indices of an existing list; anything else is ignored.
    public subscript(index: Int) -> GraphQLValue {
        get {
            guard case .list(let elements) = self, elements.indices.contains(index) else { return .null }
            return elements[index]
        }
        set {
            guard case .list(var elements) = self, elements.indices.contains(index) else { return }
            elements[index] = newValue
            self = .list(elements)
        }
    }

    /// Appends an element to a list value.
    ///
    /// Appending to `.null` starts a new list, which makes building up list fields in mutation
    /// closures ergonomic. Appending to any other non-list value is ignored.
    public mutating func append(_ element: GraphQLValue) {
        switch self {
        case .list(var elements):
            elements.append(element)
            self = .list(elements)
        case .null:
            self = .list([element])
        default:
            break
        }
    }

    /// The number of elements in a list, or fields in an object; `0` for any other value.
    public var count: Int {
        switch self {
        case .list(let elements): return elements.count
        case .object(let fields): return fields.count
        default: return 0
        }
    }
}

/// Returns `value` unless it is `.null`, in which case the fallback is returned — so handler
/// code can write `input["quantity"] ?? 1` even though subscripts return a non-optional value.
public func ?? (value: GraphQLValue, fallback: @autoclosure () -> GraphQLValue) -> GraphQLValue {
    value.isNull ? fallback() : value
}

extension GraphQLValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) {
        self = .null
    }
}

extension GraphQLValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension GraphQLValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .int(value)
    }
}

extension GraphQLValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .double(value)
    }
}

extension GraphQLValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension GraphQLValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: GraphQLValue...) {
        self = .list(elements)
    }
}

extension GraphQLValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, GraphQLValue)...) {
        var fields = [String: GraphQLValue](minimumCapacity: elements.count)
        for (key, value) in elements {
            fields[key] = value
        }
        self = .object(fields)
    }
}

extension GraphQLValue: CustomStringConvertible {
    /// A GraphQL-literal-style rendering, used in error messages and test failure output.
    public var description: String {
        switch self {
        case .null:
            return "null"
        case .bool(let value):
            return value ? "true" : "false"
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .string(let value):
            return "\"\(value)\""
        case .enumValue(let value):
            return value
        case .list(let elements):
            return "[\(elements.map(\.description).joined(separator: ", "))]"
        case .object(let fields):
            let body = fields.sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value.description)" }
                .joined(separator: ", ")
            return "{\(body)}"
        case .reference(let typeName, let id):
            return "→\(typeName):\(id)"
        }
    }
}
