/// An error produced while loading or validating user-supplied input (a schema document, an
/// operation, or a seed document) before the server starts serving.
///
/// MockQL treats diagnostics as a product feature: every error names where the problem is
/// (file, line and column when available, or a document path) and, when a near-miss exists,
/// suggests the likely fix.
public struct MockQLError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The broad category of problem, useful for programmatic matching in tests.
    public enum Category: String, Hashable, Sendable {
        /// A malformed GraphQL document (SDL or operation).
        case syntax
        /// A structurally valid but semantically invalid schema.
        case schema
        /// A seed document that does not match the schema or the seed-format spec.
        case seed
        /// A configuration problem (e.g. a generator attached to an unknown field).
        case configuration
    }

    /// The category of the problem.
    public let category: Category
    /// A human-readable description of the problem, including any fix-it suggestion.
    public let message: String
    /// The name of the source the error occurred in (usually a file path), when known.
    public let sourceName: String?
    /// The line/column within the source, when known.
    public let location: SourceLocation?
    /// A document path describing where in a structured document the error occurred
    /// (e.g. `data.User[0].email`), when line information is unavailable.
    public let documentPath: String?

    /// Creates an error.
    public init(
        category: Category,
        message: String,
        sourceName: String? = nil,
        location: SourceLocation? = nil,
        documentPath: String? = nil
    ) {
        self.category = category
        self.message = message
        self.sourceName = sourceName
        self.location = location
        self.documentPath = documentPath
    }

    public var description: String {
        var prefix = sourceName ?? ""
        if let location {
            prefix += prefix.isEmpty ? "\(location)" : ":\(location)"
        }
        var suffix = message
        if let documentPath {
            suffix += " (at \(documentPath))"
        }
        return prefix.isEmpty ? suffix : "\(prefix): \(suffix)"
    }
}
