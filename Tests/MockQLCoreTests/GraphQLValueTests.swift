import Testing

@testable import MockQLCore

@Suite struct GraphQLValueLiteralTests {
    @Test func literalsProduceExpectedCases() {
        let value: GraphQLValue = [
            "id": "user-1",
            "age": 34,
            "score": 1.5,
            "active": true,
            "nickname": nil,
            "tags": ["a", "b"],
        ]
        #expect(value["id"] == .string("user-1"))
        #expect(value["age"] == .int(34))
        #expect(value["score"] == .double(1.5))
        #expect(value["active"] == .bool(true))
        #expect(value["nickname"] == .null)
        #expect(value["tags"] == .list([.string("a"), .string("b")]))
    }
}

@Suite struct GraphQLValueAccessorTests {
    @Test func typedAccessorsReturnWrappedValues() {
        #expect(GraphQLValue.bool(true).boolValue == true)
        #expect(GraphQLValue.int(7).intValue == 7)
        #expect(GraphQLValue.int(7).doubleValue == 7.0)
        #expect(GraphQLValue.double(2.5).doubleValue == 2.5)
        #expect(GraphQLValue.string("hi").stringValue == "hi")
        #expect(GraphQLValue.enumValue("USD").enumName == "USD")
        #expect(GraphQLValue.null.isNull)
    }

    @Test func mismatchedAccessorsReturnNil() {
        #expect(GraphQLValue.string("true").boolValue == nil)
        #expect(GraphQLValue.string("7").intValue == nil)
        #expect(GraphQLValue.int(1).stringValue == nil)
        #expect(GraphQLValue.string("USD").enumName == nil)
    }

    @Test func objectSubscriptChainsThroughMissingFields() {
        let value: GraphQLValue = ["user": ["profile": ["name": "Avery"]]]
        #expect(value["user"]["profile"]["name"] == .string("Avery"))
        #expect(value["user"]["missing"]["deeper"] == .null)
        #expect(GraphQLValue.int(1)["anything"] == .null)
    }

    @Test func objectSubscriptWritesFields() {
        var value: GraphQLValue = ["name": "Avery"]
        value["name"] = "Riley"
        value["email"] = "riley@example.com"
        #expect(value["name"] == .string("Riley"))
        #expect(value["email"] == .string("riley@example.com"))
    }

    @Test func writingToNonObjectCreatesObject() {
        var value = GraphQLValue.null
        value["name"] = "Avery"
        #expect(value == .object(["name": .string("Avery")]))
    }

    @Test func listSubscriptReadsAndWrites() {
        var value: GraphQLValue = [10, 20, 30]
        #expect(value[1] == .int(20))
        #expect(value[9] == .null)
        value[1] = 25
        #expect(value[1] == .int(25))
    }

    @Test func appendBuildsLists() {
        var items = GraphQLValue.null
        items.append(["quantity": 1])
        items.append(["quantity": 2])
        #expect(items.count == 2)
        #expect(items[1]["quantity"] == .int(2))
    }

    @Test func appendToScalarIsIgnored() {
        var value = GraphQLValue.int(5)
        value.append("x")
        #expect(value == .int(5))
    }
}

@Suite struct GraphQLValueReferenceTests {
    @Test func referenceAccessorRoundTrips() {
        let reference = GraphQLValue.reference("User", id: "u1")
        #expect(reference.referenceValue?.typeName == "User")
        #expect(reference.referenceValue?.id == "u1")
        #expect(GraphQLValue.string("u1").referenceValue == nil)
    }

    @Test func dynamicIDOverloadAcceptsStringsAndInts() {
        #expect(GraphQLValue.reference("User", id: .string("u1")) == .reference("User", id: "u1"))
        #expect(GraphQLValue.reference("User", id: .int(7)) == .reference("User", id: "7"))
        #expect(GraphQLValue.reference("User", id: .null) == .null)
        #expect(GraphQLValue.reference("User", id: .bool(true)) == .null)
    }
}

@Suite struct GraphQLValueCodableTests {
    @Test func jsonRoundTripPreservesValues() throws {
        let original: GraphQLValue = [
            "string": "hello",
            "int": 42,
            "double": 3.5,
            "bool": false,
            "null": nil,
            "nested": ["list": [1, 2, 3]],
        ]
        let data = try original.jsonData()
        let decoded = try GraphQLValue.fromJSONData(data)
        #expect(decoded == original)
    }

    @Test func decodesFromJSONString() throws {
        let value = try GraphQLValue.fromJSONString(#"{"a": [true, null, 1.5], "b": "text"}"#)
        #expect(value["a"][0] == .bool(true))
        #expect(value["a"][1] == .null)
        #expect(value["a"][2] == .double(1.5))
        #expect(value["b"] == .string("text"))
    }

    @Test func boolsAndNumbersStayDistinct() throws {
        let value = try GraphQLValue.fromJSONString(#"{"flag": true, "count": 1}"#)
        #expect(value["flag"] == .bool(true))
        #expect(value["count"] == .int(1))
    }

    @Test func enumValueEncodesAsString() throws {
        let json = try GraphQLValue.enumValue("USD").jsonString()
        #expect(json == "\"USD\"")
    }

    @Test func jsonOutputIsDeterministic() throws {
        let value: GraphQLValue = ["b": 2, "a": 1, "c": 3]
        #expect(try value.jsonString() == #"{"a":1,"b":2,"c":3}"#)
    }
}

@Suite struct GraphQLValueDescriptionTests {
    @Test func descriptionRendersGraphQLStyleLiterals() {
        let value: GraphQLValue = ["name": "Avery", "age": 34]
        #expect(value.description == #"{age: 34, name: "Avery"}"#)
        #expect(GraphQLValue.enumValue("USD").description == "USD")
        #expect(GraphQLValue.list([.null, .bool(true)]).description == "[null, true]")
    }
}
