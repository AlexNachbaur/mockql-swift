/// Validates a seed document against the schema and produces the initial store contents.
///
/// The entire document is checked before the server starts: unknown types and fields (with
/// suggestions), duplicate ids, unresolvable and dangling references, enum mismatches, and
/// non-coercible scalars are all load-time errors — never mid-test surprises.
struct SeedLoader {
    private let schema: Schema
    private let sourceName: String?
    private var data = StoreData()
    private var pendingReferences: [(typeName: String, id: String, path: String)] = []

    private init(schema: Schema, sourceName: String?) {
        self.schema = schema
        self.sourceName = sourceName
    }

    /// Loads, validates, and coerces a seed source into store data.
    static func load(_ source: SeedSource, schema: Schema) throws -> StoreData {
        var loader = SeedLoader(schema: schema, sourceName: source.sourceName)
        return try loader.run(document: try source.rawDocument())
    }

    private mutating func run(document: GraphQLValue) throws -> StoreData {
        guard let sections = document.objectValue else {
            throw error("Seed document must be a mapping with 'version', 'data', and 'roots' sections", at: "")
        }
        let allowed = ["version", "data", "roots"]
        for key in sections.keys.sorted() where !allowed.contains(key) {
            throw error("Unknown top-level key '\(key)'.\(Suggestion.clause(for: key, in: allowed))", at: key)
        }
        try validateVersion(sections["version"])
        if let dataSection = sections["data"] {
            try loadDataSection(dataSection)
        }
        if let rootsSection = sections["roots"] {
            try loadRootsSection(rootsSection)
        }
        try resolvePendingReferences()
        return data
    }

    private func validateVersion(_ value: GraphQLValue?) throws {
        guard let value else {
            throw error("Seed document is missing 'version: 1'", at: "version")
        }
        guard value == .int(1) else {
            throw error("Unsupported seed format version \(value); this MockQL supports version 1", at: "version")
        }
    }

    // MARK: - data

    private mutating func loadDataSection(_ section: GraphQLValue) throws {
        guard let types = section.objectValue else {
            throw error("'data' must be a mapping of type names to record lists", at: "data")
        }
        for typeName in types.keys.sorted() {
            let objectTypeNames = schema.types.values.compactMap { type -> String? in
                if case .object = type { return type.name }
                return nil
            }
            guard let objectType = schema.objectType(named: typeName) else {
                let clause = Suggestion.clause(for: typeName, in: objectTypeNames)
                if schema.type(named: typeName) != nil {
                    throw error("'\(typeName)' is not an object type; only object types can be seeded", at: "data")
                }
                throw error("Unknown type '\(typeName)' under 'data'.\(clause)", at: "data.\(typeName)")
            }
            guard objectType.field(named: "id") != nil else {
                throw error(
                    "Type '\(typeName)' has no 'id' field, so its records cannot be referenced; "
                        + "embed its values inline where they are used instead",
                    at: "data.\(typeName)"
                )
            }
            guard let entries = types[typeName]?.listValue else {
                throw error("'data.\(typeName)' must be a list of records", at: "data.\(typeName)")
            }
            for (index, entry) in entries.enumerated() {
                let path = "data.\(typeName)[\(index)]"
                guard let fields = entry.objectValue else {
                    throw error("Record must be a mapping of field names to values", at: path)
                }
                let coerced = try coerceRecord(fields, type: objectType, at: path)
                if let id = coerced["id"]?.stringValue, data.record(type: typeName, id: id) != nil {
                    throw error("Duplicate id '\(id)' for type '\(typeName)'", at: path)
                }
                data.insert(type: typeName, fields: coerced)
            }
        }
    }

    // MARK: - roots

    private mutating func loadRootsSection(_ section: GraphQLValue) throws {
        guard let roots = section.objectValue else {
            throw error("'roots' must be a mapping of Query fields to references", at: "roots")
        }
        let queryType = schema.queryType
        for fieldName in roots.keys.sorted() {
            guard let field = queryType.field(named: fieldName) else {
                let clause = Suggestion.clause(for: fieldName, in: queryType.fields.map(\.name))
                throw error(
                    "Unknown root field '\(fieldName)' on '\(schema.queryTypeName)'.\(clause)",
                    at: "roots.\(fieldName)"
                )
            }
            guard let value = roots[fieldName] else { continue }
            data.roots[fieldName] = try coerce(value, to: field.type, at: "roots.\(fieldName)")
        }
    }

    // MARK: - Records

    private mutating func coerceRecord(
        _ fields: [String: GraphQLValue],
        type: Schema.ObjectType,
        at path: String
    ) throws -> [String: GraphQLValue] {
        var coerced: [String: GraphQLValue] = [:]
        for name in fields.keys.sorted() {
            guard let field = type.field(named: name) else {
                let clause = Suggestion.clause(for: name, in: type.fields.map(\.name))
                throw error("Unknown field '\(name)' on type '\(type.name)'.\(clause)", at: "\(path).\(name)")
            }
            guard let value = fields[name] else { continue }
            coerced[name] = try coerce(value, to: field.type, at: "\(path).\(name)")
        }
        return coerced
    }

    // MARK: - Value coercion

    private mutating func coerce(
        _ value: GraphQLValue,
        to type: TypeReference,
        at path: String
    ) throws -> GraphQLValue {
        if case .nonNull(let inner) = type {
            if value.isNull {
                throw error("Explicit null is not allowed for non-null type '\(type)'", at: path)
            }
            return try coerce(value, to: inner, at: path)
        }
        if value.isNull {
            return .null
        }
        switch type {
        case .nonNull(let inner):
            return try coerce(value, to: inner, at: path)
        case .list(let element):
            guard let elements = value.listValue else {
                // GraphQL input coercion wraps single values into one-element lists; seeds do too.
                return .list([try coerce(value, to: element, at: path)])
            }
            return .list(
                try elements.enumerated().map { index, item in
                    try coerce(item, to: element, at: "\(path)[\(index)]")
                }
            )
        case .named(let name):
            return try coerceNamed(value, typeName: name, at: path)
        }
    }

    private mutating func coerceNamed(
        _ value: GraphQLValue,
        typeName: String,
        at path: String
    ) throws -> GraphQLValue {
        guard let namedType = schema.type(named: typeName) else {
            throw error("Internal error: unknown type '\(typeName)'", at: path)
        }
        switch namedType {
        case .scalar(let scalar):
            return try coerceScalar(value, scalar: scalar, at: path)
        case .enumType(let enumType):
            let name = value.stringValue ?? value.enumName
            guard let name else {
                throw error("Expected a value of enum '\(enumType.name)', found \(value)", at: path)
            }
            guard enumType.values.contains(name) else {
                let clause = Suggestion.clause(for: name, in: enumType.values)
                throw error("'\(name)' is not a value of enum '\(enumType.name)'.\(clause)", at: path)
            }
            return .enumValue(name)
        case .inputObject:
            throw error("Input type '\(typeName)' cannot appear in seed data", at: path)
        case .object(let objectType):
            return try coerceObjectPosition(value, objectType: objectType, at: path)
        case .interface, .union:
            return try coercePolymorphicPosition(value, typeName: typeName, at: path)
        }
    }

    private func coerceScalar(
        _ value: GraphQLValue,
        scalar: Schema.ScalarType,
        at path: String
    ) throws -> GraphQLValue {
        guard scalar.isBuiltIn else {
            // Custom scalars pass through as authored.
            return value
        }
        switch (scalar.name, value) {
        case ("Int", .int):
            return value
        case ("Float", .int(let int)):
            return .double(Double(int))
        case ("Float", .double):
            return value
        case ("String", .string):
            return value
        case ("Boolean", .bool):
            return value
        case ("ID", .string):
            return value
        case ("ID", .int(let int)):
            return .string(String(int))
        default:
            var hint = ""
            if scalar.name == "String", value.intValue != nil || value.boolValue != nil {
                hint = " (quote the value to make it a string)"
            }
            throw error("Expected \(article(scalar.name)) value, found \(value)\(hint)", at: path)
        }
    }

    private mutating func coerceObjectPosition(
        _ value: GraphQLValue,
        objectType: Schema.ObjectType,
        at path: String
    ) throws -> GraphQLValue {
        // A list in a connection-typed position is a shorthand for the connection's nodes.
        if let elements = value.listValue {
            guard let connection = schema.connectionInfo(for: objectType.name) else {
                throw error("Expected a reference or object for '\(objectType.name)', found a list", at: path)
            }
            guard let nodeType = schema.objectType(named: connection.nodeTypeName) else {
                throw error("Connection node type '\(connection.nodeTypeName)' is not an object type", at: path)
            }
            return .list(
                try elements.enumerated().map { index, item in
                    try coerceObjectPosition(item, objectType: nodeType, at: "\(path)[\(index)]")
                }
            )
        }
        switch value {
        case .string(let text):
            if let qualified = parseQualifiedReference(text) {
                guard qualified.typeName == objectType.name else {
                    throw error(
                        "Reference '\(text)' points at type '\(qualified.typeName)', "
                            + "but this position holds '\(objectType.name)'",
                        at: path
                    )
                }
                return recordReference(typeName: qualified.typeName, id: qualified.id, at: path)
            }
            return recordReference(typeName: objectType.name, id: text, at: path)
        case .int(let id):
            return recordReference(typeName: objectType.name, id: String(id), at: path)
        case .reference(let typeName, let id):
            guard typeName == objectType.name else {
                throw error(
                    "Reference points at type '\(typeName)', but this position holds '\(objectType.name)'",
                    at: path
                )
            }
            return recordReference(typeName: typeName, id: id, at: path)
        case .object(let fields):
            return .object(try coerceRecord(fields, type: objectType, at: path))
        default:
            throw error("Expected a reference or object for '\(objectType.name)', found \(value)", at: path)
        }
    }

    private mutating func coercePolymorphicPosition(
        _ value: GraphQLValue,
        typeName: String,
        at path: String
    ) throws -> GraphQLValue {
        let possible = schema.possibleTypeNames(for: typeName)
        let kind = schema.isPolymorphic(typeName) ? "interface/union" : "type"
        switch value {
        case .string(let text):
            guard let qualified = parseQualifiedReference(text) else {
                throw error(
                    "Field of \(kind) '\(typeName)' needs a qualified reference like "
                        + "'\(possible.first ?? "Type"):\(text)' so the concrete type is known "
                        + "(possible types: \(possible.joined(separator: ", ")))",
                    at: path
                )
            }
            guard possible.contains(qualified.typeName) else {
                throw error(
                    "'\(qualified.typeName)' is not a possible type of '\(typeName)' "
                        + "(expected one of: \(possible.joined(separator: ", ")))",
                    at: path
                )
            }
            return recordReference(typeName: qualified.typeName, id: qualified.id, at: path)
        case .reference(let referencedType, let id):
            guard possible.contains(referencedType) else {
                throw error(
                    "'\(referencedType)' is not a possible type of '\(typeName)' "
                        + "(expected one of: \(possible.joined(separator: ", ")))",
                    at: path
                )
            }
            return recordReference(typeName: referencedType, id: id, at: path)
        case .object:
            throw error(
                "Embedded objects cannot be used for \(kind) '\(typeName)'; "
                    + "use a qualified reference like 'Type:id'",
                at: path
            )
        default:
            throw error("Expected a qualified reference for '\(typeName)', found \(value)", at: path)
        }
    }

    // MARK: - References

    private mutating func recordReference(typeName: String, id: String, at path: String) -> GraphQLValue {
        pendingReferences.append((typeName, id, path))
        return .reference(typeName, id: id)
    }

    /// A string is a qualified reference when the text before the first ':' names an object type.
    private func parseQualifiedReference(_ text: String) -> (typeName: String, id: String)? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let prefix = String(text[..<colon])
        let id = String(text[text.index(after: colon)...])
        guard !id.isEmpty, schema.objectType(named: prefix) != nil else { return nil }
        return (prefix, id)
    }

    private func resolvePendingReferences() throws {
        for reference in pendingReferences {
            guard data.record(type: reference.typeName, id: reference.id) != nil else {
                let known = data.order[reference.typeName] ?? []
                let clause = Suggestion.clause(for: reference.id, in: known)
                throw error(
                    "Dangling reference: no '\(reference.typeName)' record with id '\(reference.id)'.\(clause)",
                    at: reference.path
                )
            }
        }
    }

    // MARK: - Helpers

    private func article(_ word: String) -> String {
        let vowels: Set<Character> = ["A", "E", "I", "O", "U"]
        if let first = word.first, vowels.contains(first) {
            return "an \(word)"
        }
        return "a \(word)"
    }

    private func error(_ message: String, at path: String) -> MockQLError {
        MockQLError(
            category: .seed,
            message: message,
            sourceName: sourceName,
            documentPath: path.isEmpty ? nil : path
        )
    }
}
