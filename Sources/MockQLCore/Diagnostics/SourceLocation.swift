/// A 1-based line/column position within a source text (a schema document, an operation, or a
/// YAML seed file).
public struct SourceLocation: Hashable, Sendable, CustomStringConvertible {
    /// The 1-based line number.
    public let line: Int
    /// The 1-based column number.
    public let column: Int

    /// Creates a source location.
    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }

    public var description: String {
        "\(line):\(column)"
    }
}
