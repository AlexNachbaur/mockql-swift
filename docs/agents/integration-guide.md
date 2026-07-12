# MockQL Integration Guide for AI Coding Agents

You are integrating **MockQL** — a stateful GraphQL mocking server in Swift — into a project's
test suite. This document is self-contained: it gives you the exact APIs, the canonical
patterns, and the mistakes to avoid. Copy it into the consuming project's agent instructions
(`AGENTS.md` / `CLAUDE.md`) or reference it by URL.

Requirements: Swift 6.1+, macOS 14+/iOS 17+ hosts (also runs on Linux and Android). MockQL is
a **test-time tool**: add it to test targets only, never to an app target, and never expose it
to non-loopback networks.

## Install

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/AlexNachbaur/mockql-swift.git", from: "0.1.0")
],
// in the UI/integration test target only:
.testTarget(
    name: "MyAppUITests",
    dependencies: [.product(name: "MockQL", package: "mockql-swift")]
)
```

In Xcode projects: File ▸ Add Package Dependencies…, link the `MockQL` library to the UI
testing bundle.

## The canonical XCUITest pattern

Follow this shape unless the project already has a different established one:

```swift
import MockQL
import XCTest

final class CheckoutTests: XCTestCase {
    var server: MockQLServer!
    var app: XCUIApplication!

    override func setUp() async throws {
        server = try await MockQLServer.start(
            schema: .file(path(to: "shop.graphqls")),   // reuse the project's real SDL file
            seed: .file(path(to: "checkout.yaml"))
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
        app = XCUIApplication()
        app.launchEnvironment["GRAPHQL_URL"] = server.url.absoluteString
    }

    override func tearDown() async throws {
        try await server.stop()
    }
}
```

The app under test must read the endpoint from its environment
(`ProcessInfo.processInfo.environment["GRAPHQL_URL"]`) when constructing its GraphQL client.
If it doesn't yet, add that override — it is the only app-side change MockQL needs.

## Seed files (YAML or JSON)

```yaml
version: 1                      # required, literally 1

data:                           # records grouped by GraphQL object type name
  Product:
    - id: p1                    # id is the record's address; ints coerce to strings
      name: Espresso Machine
      priceCents: 64900
      price: { amountCents: 64900, currency: USD }   # nested map = embedded value object
  Cart:
    - { id: cart-1, owner: user-1, items: [] }       # owner: User-typed → a reference
  User:
    - { id: user-1, name: Avery Quinn, email: avery@example.com }

roots:                          # wires Query root fields to records
  currentUser: user-1
  cart: cart-1
  products: [p1]                # id list is fine even for Relay Connection fields
  featured: Product:p1          # interface/union positions REQUIRE the qualified Type:id form
```

Rules you can rely on (and must not fight):

- References are **schema-driven**: a string in an object-typed field is a reference; in a
  scalar-typed field it is a literal. Forward references and cycles are fine.
- Fields you omit are **auto-generated deterministically** (stable for the server's lifetime).
  Only seed what the test asserts on. Write `field: null` to pin a null (nullable fields only).
- Relay connections synthesize from plain id lists — never hand-write `edges`/`pageInfo`.
- The entire document is validated at `start(...)`, which **throws before the server runs** on
  unknown types/fields, dangling references, duplicate ids, or enum typos — with messages like
  `Unknown field 'emial' on type 'User'. Did you mean 'email'? (at data.User[0].emial)`.
  Read the error; it names the fix.

Small, test-specific seeds can be layered in Swift instead of editing the shared file:

```swift
Seed("Product", id: "sale-1", ["name": "Flash Sale", "priceCents": 100])
Root("products", ["p1", "sale-1"])
```

## Mutation handlers

- Signature: `Mutation("name") { input, state in … }` — `input` is the coerced GraphQL
  arguments; `state` is transactional (`inout`): all writes commit when the closure returns,
  a `throw` discards them and becomes a GraphQL field error.
- `input["quantity"] ?? 1` works (MockQL defines `??` on its value type).
- Return the value the mutation resolves to — usually `state["Type", id: …]` or an inserted
  record. References resolve through post-mutation state.
- **Pitfall:** never call `state.insert`/`state.delete` inside a `state.update { … }` closure —
  Swift exclusivity forbids overlapping access. Insert first, then update (as in the example).
- When using an SDL schema, `Mutation("name")` must match an existing schema field, or `start`
  throws with a suggestion.

## Subscriptions

The server speaks `graphql-transport-ws` at `server.webSocketURL` (Apollo/urql/Relay native).
Push events from test code at the moment the test needs them:

```swift
try await server.publish("orderStatusChanged", payload: [
    "id": "order-1",
    "status": .enumValue("SHIPPED"),     // enum values use .enumValue, not plain strings
])
```

Publishing to zero subscribers is a silent no-op. If the test subscribes over the socket first,
wait for registration before publishing:

```swift
while await server.engine.activeSubscriptionCount() == 0 {
    try await Task.sleep(nanoseconds: 10_000_000)
}
```

## Best practices checklist

- ✅ Reuse the project's real `.graphqls` SDL file — never write a parallel schema by hand.
- ✅ Default port (`0`, ephemeral) so parallel test runners never collide. Never hardcode ports.
- ✅ One server per test (or test class) — state isolation comes free.
- ✅ Seed only what the test asserts on; let generators fill the rest.
- ✅ Asserting on generated values is safe — pass `serverSeed:` for cross-run reproducibility.
- ✅ Assert server-side state directly when UI assertions are awkward:
  `await server.engine.store.record(type: "Cart", id: "cart-1")`.
- ✅ Always `try await server.stop()` in teardown.
- ❌ Do not stub `URLProtocol` alongside MockQL; pick one mechanism.
- ❌ Do not add MockQL to the app target or ship it in production code paths.
- ❌ Do not bind to `0.0.0.0` or use MockQL as a real backend.

## Common startup errors → fixes

| Error contains | Meaning | Fix |
| --- | --- | --- |
| `Did you mean '…'?` | Typo in a type/field/root/enum name | Apply the suggestion |
| `Dangling reference` | Seed references an id that no record has | Add the record or fix the id |
| `requires a qualified reference` | Plain id in an interface/union position | Use `Type:id` |
| `Explicit null is not allowed for non-null type` | `null` on a `Type!` field | Remove it or make the schema field nullable |
| `No handler registered for mutation '…'` (at runtime) | App called a mutation you didn't handle | Add `Mutation("…") { input, state in … }` |
| `missing 'version: 1'` | Seed file lacks the version key | Add `version: 1` at the top |

## Verify your integration

1. `swift build` / build the test target — resolves and compiles.
2. Run one test; if `MockQLServer.start` throws, the message tells you exactly what to fix.
3. Sanity-check by hand: `curl 'http://127.0.0.1:PORT/graphql?query={__typename}'` while paused
   at a breakpoint, or `GET /health`.

Full documentation: <https://swiftpackageindex.com/AlexNachbaur/mockql-swift/documentation> ·
Seed format spec: [docs/design/seed-format.md](../design/seed-format.md)
