import Foundation

/// Where a schema comes from: an SDL file on disk or inline SDL text.
public struct SchemaSource: Sendable {
    enum Kind: Sendable {
        case file(String)
        case sdl(String)
    }

    let kind: Kind

    /// Loads the schema from an SDL file (`.graphqls`/`.graphql`).
    public static func file(_ path: String) -> SchemaSource {
        SchemaSource(kind: .file(path))
    }

    /// An inline SDL schema.
    public static func sdl(_ text: String) -> SchemaSource {
        SchemaSource(kind: .sdl(text))
    }

    /// Reads (if needed), parses, and validates the schema.
    func loadSchema() throws -> Schema {
        switch kind {
        case .sdl(let text):
            return try Schema(sdl: text, sourceName: "inline SDL schema")
        case .file(let path):
            let text: String
            do {
                text = try String(contentsOfFile: path, encoding: .utf8)
            } catch {
                throw MockQLError(
                    category: .schema,
                    message: "Cannot read schema file: \(error.localizedDescription)",
                    sourceName: path
                )
            }
            return try Schema(sdl: text, sourceName: path)
        }
    }
}
