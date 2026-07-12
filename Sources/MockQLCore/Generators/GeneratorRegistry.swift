/// The set of generators configured for a server, plus the inference rules used when a field
/// has no explicit generator.
///
/// Explicit bindings are keyed `"Type.field"`:
///
/// ```swift
/// generators: [
///     "User.name": .fullName,
///     "User.email": .email,
/// ]
/// ```
public struct GeneratorRegistry: Sendable {
    private var bindings: [String: FieldGenerator]
    private let serverSeed: UInt64

    /// Creates a registry.
    ///
    /// - Parameters:
    ///   - bindings: Explicit generators keyed by `"Type.field"`.
    ///   - serverSeed: The seed all generated values derive from. Servers created with the same
    ///     seed generate identical data.
    public init(bindings: [String: FieldGenerator] = [:], serverSeed: UInt64 = 0) {
        self.bindings = bindings
        self.serverSeed = serverSeed
    }

    /// Validates that every binding refers to a real `Type.field` in the schema.
    func validate(against schema: Schema) throws {
        for key in bindings.keys.sorted() {
            let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                throw MockQLError(
                    category: .configuration,
                    message: "Generator key '\(key)' must have the form 'Type.field'"
                )
            }
            let (typeName, fieldName) = (parts[0], parts[1])
            guard let type = schema.type(named: typeName) else {
                let clause = Suggestion.clause(for: typeName, in: schema.types.keys)
                throw MockQLError(
                    category: .configuration,
                    message: "Generator '\(key)' refers to unknown type '\(typeName)'.\(clause)"
                )
            }
            guard case .object(let object) = type else {
                throw MockQLError(
                    category: .configuration,
                    message: "Generator '\(key)' refers to '\(typeName)', which is not an object type"
                )
            }
            guard object.field(named: fieldName) != nil else {
                let clause = Suggestion.clause(for: fieldName, in: object.fields.map(\.name))
                throw MockQLError(
                    category: .configuration,
                    message: "Generator '\(key)' refers to unknown field '\(fieldName)' on '\(typeName)'.\(clause)"
                )
            }
        }
    }

    /// Adds or replaces a binding.
    mutating func bind(typeName: String, fieldName: String, generator: FieldGenerator) {
        bindings["\(typeName).\(fieldName)"] = generator
    }

    /// Generates a stable value for a scalar-typed field of a record.
    ///
    /// Resolution order: the explicit `Type.field` binding, then field-name inference
    /// (`email` → an email address, `name` → a full name, …), then a type-appropriate default
    /// for the scalar. The result is a pure function of (server seed, type, record id, field),
    /// so repeated reads return the same value.
    func value(
        typeName: String,
        recordID: String?,
        field fieldName: String,
        scalarTypeName: String
    ) -> GraphQLValue {
        let seed = RandomSource.stableSeed(
            serverSeed: serverSeed,
            typeName: typeName,
            recordID: recordID,
            fieldName: fieldName
        )
        var context = GeneratorContext(
            typeName: typeName,
            fieldName: fieldName,
            recordID: recordID,
            random: RandomSource(seed: seed)
        )
        let generator =
            bindings["\(typeName).\(fieldName)"]
            ?? GeneratorRegistry.inferred(fieldName: fieldName, scalarTypeName: scalarTypeName)
        return generator.generate(&context)
    }

    /// Picks a stable enum member for a field with no seeded value.
    func enumValue(typeName: String, recordID: String?, field fieldName: String, cases: [String]) -> GraphQLValue {
        let seed = RandomSource.stableSeed(
            serverSeed: serverSeed,
            typeName: typeName,
            recordID: recordID,
            fieldName: fieldName
        )
        var context = GeneratorContext(
            typeName: typeName,
            fieldName: fieldName,
            recordID: recordID,
            random: RandomSource(seed: seed)
        )
        if let generator = bindings["\(typeName).\(fieldName)"] {
            return generator.generate(&context)
        }
        guard let picked = cases.randomElement(using: &context.random) else { return .null }
        return .enumValue(picked)
    }

    /// The generator used when no explicit binding exists: inferred from the field name where
    /// the name strongly implies a shape, otherwise a sensible default for the scalar type.
    static func inferred(fieldName: String, scalarTypeName: String) -> FieldGenerator {
        let lowered = fieldName.lowercased()
        switch scalarTypeName {
        case "ID":
            return .uuid
        case "Int":
            return .int()
        case "Float":
            return .double()
        case "Boolean":
            return .bool
        case "String":
            if lowered.contains("email") { return .email }
            if lowered.contains("phone") { return .phoneNumber }
            if lowered.contains("url") || lowered.contains("website") || lowered.contains("link") { return .url }
            if lowered.contains("username") || lowered.contains("handle") { return .username }
            if lowered.contains("firstname") { return .firstName }
            if lowered.contains("lastname") || lowered.contains("surname") { return .lastName }
            if lowered.contains("name") || lowered.contains("title") { return .fullName }
            if lowered.contains("description") || lowered.contains("summary") || lowered.contains("bio") {
                return .sentence
            }
            if lowered.contains("date") || lowered.contains("time") || lowered.hasSuffix("at") { return .dateTime }
            return .sentence
        default:
            // Custom scalars: date-like names get timestamps; anything else gets an opaque string.
            if lowered.contains("date") || lowered.contains("time") || lowered.hasSuffix("at")
                || scalarTypeName.lowercased().contains("date") || scalarTypeName.lowercased().contains("time")
            {
                return .dateTime
            }
            return .custom(scalarTypeName: scalarTypeName) { context in
                var random = context.random
                let word = GeneratorData.words.randomElement(using: &random) ?? "amber"
                let digits = Int.random(in: 100...999, using: &random)
                return .string("\(word)-\(digits)")
            }
        }
    }
}
