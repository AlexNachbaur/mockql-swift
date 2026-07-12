# ``MockQL``

A stateful GraphQL mocking server for UI-test automation, written in cross-platform Swift.

## Overview

MockQL runs a lightweight GraphQL server alongside your tests so your app can talk to a real,
stateful backend — one you fully control from Swift. Point it at your schema (an SDL file or a
result-builder declaration), seed it with initial data, and drive it from your test code:

```swift
import MockQL

let server = try await MockQLServer.start(
    schema: .file("Schemas/shop.graphqls"),
    seed: .file("Fixtures/checkout.yaml")
) {
    Mutation("addToCart") { input, state in
        let item = state.insert("CartItem", [
            "product": .reference("Product", id: input["productId"]),
            "quantity": input["quantity"] ?? 1,
        ])
        state.update("Cart", id: "cart-1") { cart in
            cart["items"].append(item)
        }
        return state["Cart", id: "cart-1"]
    }
}

app.launchEnvironment["GRAPHQL_URL"] = server.url.absoluteString
```

The server maintains in-memory state: a mutation performed in one step of a test is reflected in
every query that follows. Fields you don't seed are filled with realistic, deterministic data —
names, emails, phone numbers — by pluggable generators.

Importing `MockQL` re-exports the portable engine module (`MockQLCore`), so a single import
gives you the whole API: the value model (`GraphQLValue`), seeding (`SeedSource`), generators
(`FieldGenerator`), the declaration DSL (`Query`, `Mutation`, `Object`, `Seed`, …), and the
transport-free engine (`MockQLEngine`) for platforms or hosts where you want in-process
execution without networking.

### Where to start

- <doc:GettingStarted> — install the package and stand up your first server.
- <doc:XCUITestIntegration> — the end-to-end pattern for UI-test suites.
- <doc:YourFirstMockedTest> — a step-by-step tutorial building a complete mocked checkout test.
- The `MockQLCore` module documentation covers schemas, seeding, mutations, generators, and
  subscriptions in depth.

### Endpoints

A started server exposes:

| Endpoint | Purpose |
| --- | --- |
| `POST /graphql` | Standard GraphQL-over-HTTP (JSON body) |
| `GET /graphql?query=…` | Quick manual checks from a browser or curl |
| WebSocket `/graphql` | Subscriptions via the `graphql-transport-ws` protocol |
| `GET /health` | Readiness probe |

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:XCUITestIntegration>
- <doc:YourFirstMockedTest>
- ``MockQLServer``
