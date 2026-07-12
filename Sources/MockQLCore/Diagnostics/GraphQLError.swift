/// One segment of a GraphQL response path (a field name or a list index).
public enum GraphQLPathSegment: Hashable, Sendable, CustomStringConvertible {
    /// A named field (or alias).
    case field(String)
    /// An index into a list value.
    case index(Int)

    public var description: String {
        switch self {
        case .field(let name): return name
        case .index(let index): return String(index)
        }
    }
}

/// A GraphQL error in the shape defined by the spec's response format: a message, optional
/// source locations, an optional response path, and optional extensions.
public struct GraphQLError: Error, Hashable, Sendable, CustomStringConvertible {
    /// A human-readable description of the problem, including any fix-it suggestions.
    public let message: String
    /// Locations in the source operation the error is associated with.
    public let locations: [SourceLocation]
    /// The response path at which the error occurred, for field-level execution errors.
    public let path: [GraphQLPathSegment]
    /// Machine-readable extra information; MockQL sets `code` for its own error categories.
    public let extensions: [String: GraphQLValue]

    /// Creates a GraphQL error.
    public init(
        message: String,
        locations: [SourceLocation] = [],
        path: [GraphQLPathSegment] = [],
        extensions: [String: GraphQLValue] = [:]
    ) {
        self.message = message
        self.locations = locations
        self.path = path
        self.extensions = extensions
    }

    public var description: String {
        var parts = [message]
        if let location = locations.first {
            parts.append("at \(location)")
        }
        if !path.isEmpty {
            parts.append("(path: \(path.map(\.description).joined(separator: ".")))")
        }
        return parts.joined(separator: " ")
    }

    /// The error as a response-format value, ready to embed in a response's `errors` list.
    public var responseValue: GraphQLValue {
        var fields: [String: GraphQLValue] = ["message": .string(message)]
        if !locations.isEmpty {
            fields["locations"] = .list(
                locations.map { .object(["line": .int($0.line), "column": .int($0.column)]) }
            )
        }
        if !path.isEmpty {
            fields["path"] = .list(
                path.map { segment in
                    switch segment {
                    case .field(let name): return .string(name)
                    case .index(let index): return .int(index)
                    }
                }
            )
        }
        if !extensions.isEmpty {
            fields["extensions"] = .object(extensions)
        }
        return .object(fields)
    }
}
