import Foundation

/// The context passed to a field generator: which field is being generated, for which record,
/// and a deterministic random source seeded for exactly that field.
public struct GeneratorContext: Sendable {
    /// The object type owning the field.
    public let typeName: String
    /// The field being generated.
    public let fieldName: String
    /// The id of the record the field belongs to, when it has one.
    public let recordID: String?
    /// A random source seeded stably for this record + field. Generators should draw all
    /// randomness from it so values stay deterministic.
    public var random: RandomSource

    /// Creates a generator context.
    public init(typeName: String, fieldName: String, recordID: String?, random: RandomSource) {
        self.typeName = typeName
        self.fieldName = fieldName
        self.recordID = recordID
        self.random = random
    }
}

/// Generates a value for a field that was not provided by seed data.
///
/// Use the built-in presets (`.fullName`, `.email`, `.phoneNumber`, …) or supply a custom
/// closure with ``FieldGenerator/custom(scalarTypeName:_:)``.
public struct FieldGenerator: Sendable {
    /// The scalar type name this generator produces, used by the DSL to infer field types.
    public let scalarTypeName: String
    let generate: @Sendable (inout GeneratorContext) -> GraphQLValue

    /// Creates a generator from a closure. Prefer the presets where one fits.
    public static func custom(
        scalarTypeName: String = "String",
        _ generate: @escaping @Sendable (inout GeneratorContext) -> GraphQLValue
    ) -> FieldGenerator {
        FieldGenerator(scalarTypeName: scalarTypeName, generate: generate)
    }

    /// Always produces the given value.
    public static func constant(_ value: GraphQLValue) -> FieldGenerator {
        let typeName: String
        switch value {
        case .int: typeName = "Int"
        case .double: typeName = "Float"
        case .bool: typeName = "Boolean"
        default: typeName = "String"
        }
        return FieldGenerator(scalarTypeName: typeName) { _ in value }
    }

    /// Picks one of the given values.
    public static func oneOf(_ values: [GraphQLValue]) -> FieldGenerator {
        FieldGenerator(scalarTypeName: "String") { context in
            values.randomElement(using: &context.random) ?? .null
        }
    }

    /// A UUID-format identifier.
    public static let uuid = FieldGenerator(scalarTypeName: "ID") { context in
        .string(Self.uuidString(using: &context.random))
    }

    /// A first name, like `"Avery"`.
    public static let firstName = FieldGenerator(scalarTypeName: "String") { context in
        .string(GeneratorData.firstNames.randomElement(using: &context.random) ?? "Avery")
    }

    /// A last name, like `"Chen"`.
    public static let lastName = FieldGenerator(scalarTypeName: "String") { context in
        .string(GeneratorData.lastNames.randomElement(using: &context.random) ?? "Chen")
    }

    /// A full name, like `"Avery Chen"`.
    public static let fullName = FieldGenerator(scalarTypeName: "String") { context in
        let first = GeneratorData.firstNames.randomElement(using: &context.random) ?? "Avery"
        let last = GeneratorData.lastNames.randomElement(using: &context.random) ?? "Chen"
        return .string("\(first) \(last)")
    }

    /// An email address on a reserved example domain, like `"avery.chen@example.com"`.
    public static let email = FieldGenerator(scalarTypeName: "String") { context in
        let first = GeneratorData.firstNames.randomElement(using: &context.random) ?? "avery"
        let last = GeneratorData.lastNames.randomElement(using: &context.random) ?? "chen"
        let domain = GeneratorData.emailDomains.randomElement(using: &context.random) ?? "example.com"
        let local = "\(first).\(last)".lowercased()
            .replacingOccurrences(of: "ö", with: "o")
            .replacingOccurrences(of: " ", with: "")
        return .string("\(local)@\(domain)")
    }

    /// A North American-format phone number, like `"+1 (212) 555-0147"`.
    ///
    /// Uses the 555-0100 through 555-0199 range reserved for fictional use.
    public static let phoneNumber = FieldGenerator(scalarTypeName: "String") { context in
        let area = Int.random(in: 200...989, using: &context.random)
        let line = Int.random(in: 0...99, using: &context.random)
        return .string(String(format: "+1 (%03d) 555-%04d", area, 100 + line))
    }

    /// An E.164-format phone number, like `"+12125550147"` — the `+`, country code, and digits
    /// only, no separators. Uses the 555-0100 through 555-0199 range reserved for fictional use.
    public static let phoneNumberE164 = FieldGenerator(scalarTypeName: "String") { context in
        let area = Int.random(in: 200...989, using: &context.random)
        let line = Int.random(in: 0...99, using: &context.random)
        return .string(String(format: "+1%03d555%04d", area, 100 + line))
    }

    /// A URL on a reserved example domain.
    public static let url = FieldGenerator(scalarTypeName: "String") { context in
        let word = GeneratorData.words.randomElement(using: &context.random) ?? "amber"
        return .string("https://example.com/\(word)")
    }

    /// A username, like `"amber_harbor42"`.
    public static let username = FieldGenerator(scalarTypeName: "String") { context in
        let first = GeneratorData.words.randomElement(using: &context.random) ?? "amber"
        let second = GeneratorData.words.randomElement(using: &context.random) ?? "vale"
        let digits = Int.random(in: 0...99, using: &context.random)
        return .string("\(first)_\(second)\(digits)")
    }

    /// A short sentence of lorem-style words.
    public static let sentence = FieldGenerator(scalarTypeName: "String") { context in
        let count = Int.random(in: 5...9, using: &context.random)
        var words: [String] = []
        for _ in 0..<count {
            words.append(GeneratorData.words.randomElement(using: &context.random) ?? "amber")
        }
        let body = words.joined(separator: " ")
        return .string(body.prefix(1).uppercased() + body.dropFirst() + ".")
    }

    /// An ISO-8601 timestamp within a fixed, deterministic range.
    public static let dateTime = FieldGenerator(scalarTypeName: "String") { context in
        // Deterministic dates: a fixed base (2026-01-01T00:00:00Z) minus up to a year of seconds.
        let offset = Int.random(in: 0...31_536_000, using: &context.random)
        let epochSeconds = 1_767_225_600 - offset
        return .string(Self.iso8601String(secondsSinceEpoch: epochSeconds))
    }

    /// A random boolean.
    public static let bool = FieldGenerator(scalarTypeName: "Boolean") { context in
        .bool(Bool.random(using: &context.random))
    }

    /// A random integer in the given range.
    public static func int(in range: ClosedRange<Int> = 0...1000) -> FieldGenerator {
        FieldGenerator(scalarTypeName: "Int") { context in
            .int(Int.random(in: range, using: &context.random))
        }
    }

    /// A random float in the given range, rounded to two decimal places.
    public static func double(in range: ClosedRange<Double> = 0...1000) -> FieldGenerator {
        FieldGenerator(scalarTypeName: "Float") { context in
            .double((Double.random(in: range, using: &context.random) * 100).rounded() / 100)
        }
    }

    // MARK: - Helpers

    private static func uuidString(using random: inout RandomSource) -> String {
        let hex = "0123456789abcdef".map(String.init)
        func digits(_ count: Int) -> String {
            var result = ""
            for _ in 0..<count {
                result += hex[Int.random(in: 0...15, using: &random)]
            }
            return result
        }
        // Version-4, variant-1 layout so the output passes common UUID validation.
        let variant = ["8", "9", "a", "b"][Int.random(in: 0...3, using: &random)]
        return "\(digits(8))-\(digits(4))-4\(digits(3))-\(variant)\(digits(3))-\(digits(12))"
    }

    private static func iso8601String(secondsSinceEpoch: Int) -> String {
        // Days-from-civil algorithm (Howard Hinnant) to avoid Foundation date formatters,
        // which keeps this pure, fast, and identical on every platform.
        let days = secondsSinceEpoch / 86_400
        let secondsOfDay = secondsSinceEpoch % 86_400
        var z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        z = month <= 2 ? year + 1 : year
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02dZ",
            z, month, day, secondsOfDay / 3600, (secondsOfDay % 3600) / 60, secondsOfDay % 60
        )
    }
}
