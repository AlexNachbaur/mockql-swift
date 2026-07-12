import Testing

@testable import MockQLCore

@Suite struct OperationParserTests {
    @Test func parsesShorthandQuery() throws {
        let document = try OperationParser.parse("{ currentUser { id name } }")
        let operation = try document.operation(named: nil)
        #expect(operation.type == .query)
        #expect(operation.name == nil)
        guard case .field(let field) = try #require(operation.selectionSet.first) else {
            Issue.record("Expected a field selection")
            return
        }
        #expect(field.name == "currentUser")
        #expect(field.selectionSet.count == 2)
    }

    @Test func parsesNamedOperationWithVariables() throws {
        let source = """
            query GetUser($id: ID!, $limit: Int = 10) {
                user(id: $id) { name }
            }
            """
        let operation = try OperationParser.parse(source).operation(named: "GetUser")
        #expect(operation.variableDefinitions.count == 2)
        let limit = try #require(operation.variableDefinitions.last)
        #expect(limit.name == "limit")
        #expect(limit.type == .named("Int"))
        #expect(limit.defaultValue == .int(10))
        let id = try #require(operation.variableDefinitions.first)
        #expect(id.type == .nonNull(.named("ID")))
    }

    @Test func parsesAliasesAndArguments() throws {
        let document = try OperationParser.parse(#"{ first: product(id: "p1", flags: [1, 2]) { name } }"#)
        let operation = try document.operation(named: nil)
        guard case .field(let field) = try #require(operation.selectionSet.first) else {
            Issue.record("Expected a field selection")
            return
        }
        #expect(field.alias == "first")
        #expect(field.name == "product")
        #expect(field.responseKey == "first")
        #expect(field.arguments.count == 2)
        #expect(field.arguments.first?.value == .string("p1"))
        #expect(field.arguments.last?.value == .list([.int(1), .int(2)]))
    }

    @Test func parsesInputObjectsAndEnums() throws {
        let document = try OperationParser.parse("{ search(filter: { status: ACTIVE, limit: 5 }) { id } }")
        let operation = try document.operation(named: nil)
        guard case .field(let field) = try #require(operation.selectionSet.first),
            case .object(let filter) = try #require(field.arguments.first?.value)
        else {
            Issue.record("Expected an input object argument")
            return
        }
        #expect(filter["status"] == .enumValue("ACTIVE"))
        #expect(filter["limit"] == .int(5))
    }

    @Test func parsesFragmentsAndSpreads() throws {
        let source = """
            query { currentUser { ...UserFields ... on Admin { permissions } } }
            fragment UserFields on User { id name }
            """
        let document = try OperationParser.parse(source)
        #expect(document.fragments["UserFields"]?.typeCondition == "User")
        let operation = try document.operation(named: nil)
        guard case .field(let user) = try #require(operation.selectionSet.first) else {
            Issue.record("Expected a field selection")
            return
        }
        guard case .fragmentSpread(let name, _, _) = try #require(user.selectionSet.first) else {
            Issue.record("Expected a fragment spread")
            return
        }
        #expect(name == "UserFields")
        guard case .inlineFragment(let condition, _, let selections, _) = try #require(user.selectionSet.last) else {
            Issue.record("Expected an inline fragment")
            return
        }
        #expect(condition == "Admin")
        #expect(selections.count == 1)
    }

    @Test func parsesDirectives() throws {
        let document = try OperationParser.parse("{ user { phone @include(if: $withPhone) } }")
        let operation = try document.operation(named: nil)
        guard case .field(let user) = try #require(operation.selectionSet.first),
            case .field(let phone) = try #require(user.selectionSet.first)
        else {
            Issue.record("Expected nested field selections")
            return
        }
        #expect(phone.directives.first?.name == "include")
        #expect(phone.directives.first?.arguments["if"] == .variable("withPhone"))
    }

    @Test func parsesMutationsAndSubscriptions() throws {
        let document = try OperationParser.parse(
            """
            mutation Add { addToCart(productId: "p1") { id } }
            subscription Watch { orderStatusChanged { status } }
            """
        )
        #expect(try document.operation(named: "Add").type == .mutation)
        #expect(try document.operation(named: "Watch").type == .subscription)
    }

    @Test func selectingOperationRequiresNameWhenAmbiguous() throws {
        let document = try OperationParser.parse("query A { a } query B { b }")
        #expect(throws: GraphQLError.self) { try document.operation(named: nil) }
        #expect(try document.operation(named: "A").name == "A")
    }

    @Test func unknownOperationNameGetsSuggestion() throws {
        let document = try OperationParser.parse("query GetUser { user { id } }")
        do {
            _ = try document.operation(named: "GetUsr")
            Issue.record("Expected an error")
        } catch let error as GraphQLError {
            #expect(error.message.contains("Did you mean 'GetUser'?"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func rejectsMalformedDocuments() {
        #expect(throws: MockQLError.self) { try OperationParser.parse("{ }") }
        #expect(throws: MockQLError.self) { try OperationParser.parse("query { user( ) { id } }") }
        #expect(throws: MockQLError.self) { try OperationParser.parse("query ($x: Int, $x: Int) { f }") }
        #expect(throws: MockQLError.self) { try OperationParser.parse("query A { a } query A { b }") }
        #expect(throws: MockQLError.self) { try OperationParser.parse("fragment on on User { id }") }
        #expect(throws: MockQLError.self) { try OperationParser.parse("{ f(a: 1, a: 2) }") }
        #expect(throws: MockQLError.self) { try OperationParser.parse("wat { id }") }
    }

    @Test func rejectsVariablesInConstantPositions() {
        #expect(throws: MockQLError.self) {
            try OperationParser.parse("query ($a: Int = $b) { f }")
        }
    }
}
