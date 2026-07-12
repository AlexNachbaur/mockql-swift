import Testing

@testable import MockQLCore

@Suite struct RandomSourceTests {
    @Test func sameSeedProducesSameSequence() {
        var first = RandomSource(seed: 42)
        var second = RandomSource(seed: 42)
        for _ in 0..<10 {
            #expect(first.next() == second.next())
        }
    }

    @Test func differentSeedsDiverge() {
        var first = RandomSource(seed: 1)
        var second = RandomSource(seed: 2)
        #expect(first.next() != second.next())
    }

    @Test func stableSeedIsPureAndDistinguishesInputs() {
        let base = RandomSource.stableSeed(serverSeed: 0, typeName: "User", recordID: "u1", fieldName: "email")
        #expect(base == RandomSource.stableSeed(serverSeed: 0, typeName: "User", recordID: "u1", fieldName: "email"))
        #expect(base != RandomSource.stableSeed(serverSeed: 0, typeName: "User", recordID: "u1", fieldName: "name"))
        #expect(base != RandomSource.stableSeed(serverSeed: 0, typeName: "User", recordID: "u2", fieldName: "email"))
        #expect(base != RandomSource.stableSeed(serverSeed: 0, typeName: "Post", recordID: "u1", fieldName: "email"))
        #expect(base != RandomSource.stableSeed(serverSeed: 9, typeName: "User", recordID: "u1", fieldName: "email"))
    }

    @Test func fieldBoundariesAreUnambiguous() {
        // ("ab", "c") must not collide with ("a", "bc").
        let first = RandomSource.stableSeed(serverSeed: 0, typeName: "ab", recordID: "c", fieldName: "x")
        let second = RandomSource.stableSeed(serverSeed: 0, typeName: "a", recordID: "bc", fieldName: "x")
        #expect(first != second)
    }
}

@Suite struct FieldGeneratorTests {
    private func generate(_ generator: FieldGenerator, seed: UInt64 = 7) -> GraphQLValue {
        var context = GeneratorContext(
            typeName: "User",
            fieldName: "field",
            recordID: "r1",
            random: RandomSource(seed: seed)
        )
        return generator.generate(&context)
    }

    @Test func emailLooksLikeAnEmailOnAnExampleDomain() throws {
        let value = try #require(generate(.email).stringValue)
        #expect(value.contains("@"))
        #expect(value.contains("example."))
        #expect(value == value.lowercased())
    }

    @Test func phoneNumberUsesTheFictionalRange() throws {
        let value = try #require(generate(.phoneNumber).stringValue)
        #expect(value.hasPrefix("+1 ("))
        #expect(value.contains(") 555-01"))
    }

    @Test func e164PhoneNumberIsStrictlyFormatted() throws {
        for seed in 0..<20 {
            let value = try #require(generate(.phoneNumberE164, seed: UInt64(seed)).stringValue)
            #expect(value.hasPrefix("+1"))
            #expect(value.count == 12)
            #expect(value.dropFirst().allSatisfy { $0.isNumber })
            #expect(value.contains("555"))
        }
    }

    @Test func uuidHasVersionFourLayout() throws {
        let value = try #require(generate(.uuid).stringValue)
        let parts = value.split(separator: "-")
        #expect(parts.map(\.count) == [8, 4, 4, 4, 12])
        #expect(parts[2].first == "4")
    }

    @Test func fullNameCombinesPools() throws {
        let value = try #require(generate(.fullName).stringValue)
        #expect(value.split(separator: " ").count == 2)
    }

    @Test func intRespectsRange() throws {
        for seed in 0..<50 {
            let value = try #require(generate(.int(in: 5...10), seed: UInt64(seed)).intValue)
            #expect((5...10).contains(value))
        }
    }

    @Test func dateTimeIsISO8601Shaped() throws {
        let value = try #require(generate(.dateTime).stringValue)
        #expect(value.count == 20)
        #expect(value.hasSuffix("Z"))
        #expect(value[value.index(value.startIndex, offsetBy: 10)] == "T")
        #expect(value.hasPrefix("202"))
    }

    @Test func constantAlwaysReturnsItsValue() {
        #expect(generate(.constant(.int(9))) == .int(9))
        #expect(FieldGenerator.constant(.int(9)).scalarTypeName == "Int")
        #expect(FieldGenerator.constant(.bool(true)).scalarTypeName == "Boolean")
    }

    @Test func oneOfPicksFromTheGivenValues() {
        let options: [GraphQLValue] = [.string("a"), .string("b")]
        for seed in 0..<20 {
            #expect(options.contains(generate(.oneOf(options), seed: UInt64(seed))))
        }
    }
}

@Suite struct GeneratorRegistryTests {
    private let schema = try? Schema(
        sdl: """
            type Query { user: User }
            type User { id: ID! name: String! email: String! score: Int! }
            """
    )

    @Test func valuesAreStableAcrossReads() {
        let registry = GeneratorRegistry(serverSeed: 3)
        let first = registry.value(typeName: "User", recordID: "u1", field: "email", scalarTypeName: "String")
        let second = registry.value(typeName: "User", recordID: "u1", field: "email", scalarTypeName: "String")
        #expect(first == second)
    }

    @Test func distinctRecordsGetDistinctValues() {
        let registry = GeneratorRegistry(serverSeed: 3)
        let first = registry.value(typeName: "User", recordID: "u1", field: "email", scalarTypeName: "String")
        let second = registry.value(typeName: "User", recordID: "u2", field: "email", scalarTypeName: "String")
        #expect(first != second)
    }

    @Test func explicitBindingWins() {
        let registry = GeneratorRegistry(bindings: ["User.email": .constant(.string("pinned@example.com"))])
        let value = registry.value(typeName: "User", recordID: "u1", field: "email", scalarTypeName: "String")
        #expect(value == .string("pinned@example.com"))
    }

    @Test func inferenceMatchesFieldNames() throws {
        let email = registryValue(field: "contactEmail", scalarTypeName: "String")
        #expect(try #require(email.stringValue).contains("@"))
        let phone = registryValue(field: "phoneNumber", scalarTypeName: "String")
        #expect(try #require(phone.stringValue).hasPrefix("+1"))
        let id = registryValue(field: "anything", scalarTypeName: "ID")
        #expect(try #require(id.stringValue).count == 36)
        let flag = registryValue(field: "isActive", scalarTypeName: "Boolean")
        #expect(flag.boolValue != nil)
        let createdAt = registryValue(field: "createdAt", scalarTypeName: "String")
        #expect(try #require(createdAt.stringValue).hasSuffix("Z"))
    }

    private func registryValue(field: String, scalarTypeName: String) -> GraphQLValue {
        GeneratorRegistry(serverSeed: 5).value(
            typeName: "User",
            recordID: "u1",
            field: field,
            scalarTypeName: scalarTypeName
        )
    }

    @Test func enumFallbackPicksAMember() {
        let registry = GeneratorRegistry(serverSeed: 1)
        let value = registry.enumValue(typeName: "Order", recordID: "o1", field: "status", cases: ["A", "B"])
        #expect(value == .enumValue("A") || value == .enumValue("B"))
    }

    @Test func validateAcceptsRealFieldsAndRejectsTypos() throws {
        let schema = try #require(self.schema)
        try GeneratorRegistry(bindings: ["User.email": .email]).validate(against: schema)
        do {
            try GeneratorRegistry(bindings: ["User.emial": .email]).validate(against: schema)
            Issue.record("Expected a configuration error")
        } catch let error as MockQLError {
            #expect(error.category == .configuration)
            #expect(error.message.contains("Did you mean 'email'?"))
        }
        #expect(throws: MockQLError.self) {
            try GeneratorRegistry(bindings: ["Usr.email": .email]).validate(against: schema)
        }
        #expect(throws: MockQLError.self) {
            try GeneratorRegistry(bindings: ["nodots": .email]).validate(against: schema)
        }
    }
}
