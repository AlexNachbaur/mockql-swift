# Integrating with XCUITest

The end-to-end pattern for backing a UI-test suite with MockQL.

## Overview

An XCUITest process and the app under test are separate processes. MockQL runs inside the *test
runner* and serves over localhost, so the app connects to it like any real backend — no
`URLProtocol` stubbing, no fixtures bundled into the app.

The lifecycle per test:

1. Start a server with the schema and the seed state the test needs.
2. Pass `server.url` to the app through the launch environment.
3. Drive the UI; the app's queries and mutations hit MockQL, and state persists across requests.
4. Optionally push subscription events mid-test.
5. Stop the server in teardown.

## A complete test class

```swift
import MockQL
import XCTest

final class CheckoutTests: XCTestCase {
    var server: MockQLServer!
    var app: XCUIApplication!

    override func setUp() async throws {
        server = try await MockQLServer.start(
            schema: .file(fixture("shop.graphqls")),
            seed: .file(fixture("checkout.yaml"))
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

    func testAddingItemUpdatesCartBadge() async throws {
        app.launch()
        app.buttons["Add to cart"].tap()
        // The app sends the addToCart mutation; MockQL updates its state.
        // The cart badge re-queries `cart` and now reflects one item.
        XCTAssertEqual(app.staticTexts["cart-badge"].label, "1")
    }
}
```

`fixture(_:)` here resolves a bundled resource path, e.g.
`Bundle(for: CheckoutTests.self).url(forResource:withExtension:)`.

## Per-test seed variation

Seeds compose: load a shared baseline from a file and layer test-specific records with `Seed`
and `Root` declarations in the configuration block. References may point across the two layers,
and everything is validated together before the server starts.

```swift
server = try await MockQLServer.start(
    schema: .file(fixture("shop.graphqls")),
    seed: .file(fixture("base.yaml"))
) {
    Seed("Product", id: "sale-1", ["name": "Flash Sale Item", "priceCents": 100])
    Root("products", ["product-1", "sale-1"])
}
```

## Driving real-time UI

Subscriptions use the `graphql-transport-ws` protocol at `server.webSocketURL` — the protocol
Apollo iOS speaks natively. Trigger events from test code at the exact moment the test needs
them:

```swift
try await server.publish("orderStatusChanged", payload: [
    "id": "order-1",
    "status": .enumValue("SHIPPED"),
])
```

## Determinism and parallel tests

- Port `0` (the default) gives every server its own ephemeral port, so parallel test runners
  never collide, and each server's state is fully isolated.
- Generated field values are deterministic: stable for a server's lifetime, and reproducible
  across runs when you pass the same `serverSeed`. Asserting on a generated value is safe.

## Asserting against server state

The engine is directly accessible for state assertions that would be awkward through the UI:

```swift
let cart = await server.engine.store.record(type: "Cart", id: "cart-1")
XCTAssertEqual(cart?["items"].count, 1)
```
