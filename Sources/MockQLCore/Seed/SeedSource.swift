import Foundation

/// Where a seed document comes from: a file on disk, an inline string, or a document assembled
/// in Swift (the result-builder initializers produce the latter).
public struct SeedSource: Sendable {
    enum Kind: Sendable {
        case file(String)
        case yaml(String)
        case json(String)
        case document(GraphQLValue, sourceName: String?)
    }

    let kind: Kind

    /// Loads the seed document from a file. `.json` files parse as JSON; anything else parses
    /// as YAML (of which JSON is a subset).
    public static func file(_ path: String) -> SeedSource {
        SeedSource(kind: .file(path))
    }

    /// An inline YAML seed document.
    public static func yaml(_ text: String) -> SeedSource {
        SeedSource(kind: .yaml(text))
    }

    /// An inline JSON seed document.
    public static func json(_ text: String) -> SeedSource {
        SeedSource(kind: .json(text))
    }

    /// A seed document assembled programmatically (used by the result-builder DSL).
    static func document(_ value: GraphQLValue, sourceName: String? = nil) -> SeedSource {
        SeedSource(kind: .document(value, sourceName: sourceName))
    }

    /// The name used for this source in diagnostics.
    var sourceName: String? {
        switch kind {
        case .file(let path): return path
        case .yaml: return "inline YAML seed"
        case .json: return "inline JSON seed"
        case .document(_, let name): return name ?? "seed builder"
        }
    }

    /// Reads and parses the raw document value (no schema validation yet).
    func rawDocument() throws -> GraphQLValue {
        switch kind {
        case .document(let value, _):
            return value
        case .yaml(let text):
            return try YAMLDecoding.decode(text, sourceName: sourceName)
        case .json(let text):
            return try Self.decodeJSON(text, sourceName: sourceName)
        case .file(let path):
            let text: String
            do {
                text = try String(contentsOfFile: path, encoding: .utf8)
            } catch {
                throw MockQLError(
                    category: .seed,
                    message: "Cannot read seed file: \(error.localizedDescription)",
                    sourceName: path
                )
            }
            if path.lowercased().hasSuffix(".json") {
                return try Self.decodeJSON(text, sourceName: path)
            }
            return try YAMLDecoding.decode(text, sourceName: path)
        }
    }

    private static func decodeJSON(_ text: String, sourceName: String?) throws -> GraphQLValue {
        do {
            return try GraphQLValue.fromJSONString(text)
        } catch {
            throw MockQLError(
                category: .seed,
                message: "Seed document is not valid JSON: \(error.localizedDescription)",
                sourceName: sourceName
            )
        }
    }
}
