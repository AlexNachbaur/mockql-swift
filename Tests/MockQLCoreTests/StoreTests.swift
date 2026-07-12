import Testing

@testable import MockQLCore

@Suite struct MutationStateTests {
    private func makeState() -> MutationState {
        var data = StoreData()
        data.insert(type: "User", fields: ["id": "u1", "name": "Avery"])
        data.insert(type: "Cart", fields: ["id": "c1", "owner": .reference("User", id: "u1"), "items": .list([])])
        data.roots["cart"] = .reference("Cart", id: "c1")
        return MutationState(data: data)
    }

    @Test func subscriptReadsRecords() {
        let state = makeState()
        #expect(state["User", id: "u1"]["name"] == .string("Avery"))
        #expect(state["User", id: "missing"] == .null)
    }

    @Test func updateMutatesInPlace() {
        var state = makeState()
        state.update("User", id: "u1") { user in
            user["name"] = "Riley"
        }
        #expect(state["User", id: "u1"]["name"] == .string("Riley"))
    }

    @Test func updateOnMissingRecordIsANoOp() {
        var state = makeState()
        state.update("User", id: "ghost") { $0["name"] = "X" }
        #expect(state["User", id: "ghost"] == .null)
    }

    @Test func appendingThroughSubscriptPersists() {
        var state = makeState()
        state.update("Cart", id: "c1") { cart in
            cart["items"].append(["product": .reference("Product", id: "p1"), "quantity": 2])
        }
        #expect(state["Cart", id: "c1"]["items"].count == 1)
        #expect(state["Cart", id: "c1"]["items"][0]["quantity"] == .int(2))
    }

    @Test func insertGeneratesIDsWhenMissing() {
        var state = makeState()
        let record = state.insert("Product", ["name": "Espresso Machine"])
        let id = record["id"].stringValue
        #expect(id?.hasPrefix("product-auto-") == true)
        #expect(state.records(ofType: "Product").count == 1)
    }

    @Test func insertHonorsProvidedIDs() {
        var state = makeState()
        _ = state.insert("Product", ["id": "p9", "name": "Grinder"])
        #expect(state["Product", id: "p9"]["name"] == .string("Grinder"))
    }

    @Test func wholeRecordWriteForcesID() {
        var state = makeState()
        state["User", id: "u2"] = ["name": "Sam"]
        #expect(state["User", id: "u2"]["id"] == .string("u2"))
        #expect(state.ids(ofType: "User") == ["u1", "u2"])
    }

    @Test func deleteRemovesRecordsAndOrder() {
        var state = makeState()
        let firstDelete = state.delete("User", id: "u1")
        let secondDelete = state.delete("User", id: "u1")
        #expect(firstDelete)
        #expect(!secondDelete)
        #expect(state.records(ofType: "User").isEmpty)
    }

    @Test func rootsReadAndWrite() {
        var state = makeState()
        #expect(state.root("cart").referenceValue?.id == "c1")
        state.setRoot("featured", to: .reference("Product", id: "p1"))
        #expect(state.root("featured").referenceValue?.typeName == "Product")
        #expect(state.root("missing") == .null)
    }
}

@Suite struct StateStoreTests {
    @Test func mutationsCommitAtomically() async {
        let store = StateStore()
        await store.withMutationState { state in
            _ = state.insert("User", ["id": "u1", "name": "Avery"])
        }
        let record = await store.record(type: "User", id: "u1")
        #expect(record?["name"] == .string("Avery"))
    }

    @Test func throwingMutationDiscardsWrites() async {
        let store = StateStore()
        await store.withMutationState { state in
            _ = state.insert("User", ["id": "u1", "name": "Avery"])
        }
        struct Boom: Error {}
        do {
            try await store.withMutationState { state in
                state.update("User", id: "u1") { $0["name"] = "Corrupted" }
                throw Boom()
            }
            Issue.record("Expected the mutation to throw")
        } catch {
            // Expected.
        }
        let record = await store.record(type: "User", id: "u1")
        #expect(record?["name"] == .string("Avery"))
    }

    @Test func snapshotIsIsolatedFromLaterWrites() async {
        let store = StateStore()
        await store.withMutationState { state in
            _ = state.insert("User", ["id": "u1", "name": "Avery"])
        }
        let snapshot = await store.snapshot()
        await store.withMutationState { state in
            state.update("User", id: "u1") { $0["name"] = "Riley" }
        }
        #expect(snapshot.record(type: "User", id: "u1")?["name"] == .string("Avery"))
        let live = await store.record(type: "User", id: "u1")
        #expect(live?["name"] == .string("Riley"))
    }

    @Test func resetClearsEverything() async {
        let store = StateStore()
        await store.withMutationState { state in
            _ = state.insert("User", ["id": "u1"])
            state.setRoot("currentUser", to: .reference("User", id: "u1"))
        }
        await store.reset()
        let record = await store.record(type: "User", id: "u1")
        #expect(record == nil)
        let root = await store.root("currentUser")
        #expect(root == .null)
    }
}
