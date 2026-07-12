# Tutorial: Your First Mocked Test

Build a complete mocked checkout flow from scratch — schema, seed, mutation handler, and the
test that exercises it.

## Overview

This tutorial walks through every layer of MockQL once, in order. At the end you'll have a
server that serves a product catalog, tracks a cart across requests, and pushes an order-status
event to the UI. Each step builds on the previous one.

### Step 1: Describe your API

Save your schema as a fixture in the test bundle (`Fixtures/shop.graphqls`). If your project
already has an SDL file for codegen, reuse that file — MockQL loads standard SDL:

```graphql
type Query {
    currentUser: User
    cart: Cart
    products(first: Int, after: String): ProductConnection!
}

type Mutation {
    addToCart(productId: ID!, quantity: Int = 1): Cart!
}

type Subscription {
    orderStatusChanged: Order!
}

type User { id: ID! name: String! email: String! }
type Product { id: ID! name: String! priceCents: Int! }
type Cart { id: ID! owner: User! items: [CartItem!]! }
type CartItem { id: ID! product: Product! quantity: Int! }
type Order { id: ID! status: OrderStatus! }
enum OrderStatus { PENDING SHIPPED DELIVERED }

type ProductConnection { edges: [ProductEdge!]! pageInfo: PageInfo! }
type ProductEdge { cursor: String! node: Product! }
type PageInfo { hasNextPage: Boolean! endCursor: String }
```

### Step 2: Seed the world

Create `Fixtures/checkout.yaml`. Top-level sections are `version`, `data` (records grouped by
type), and `roots` (wiring `Query` fields to records). Note how `owner: user-1` is just an id —
MockQL knows `Cart.owner` is a `User` from the schema:

```yaml
version: 1

data:
  User:
    - { id: user-1, name: Avery Quinn, email: avery@example.com }
  Product:
    - { id: p1, name: Espresso Machine, priceCents: 64900 }
    - { id: p2, name: Burr Grinder, priceCents: 21900 }
  Cart:
    - { id: cart-1, owner: user-1, items: [] }

roots:
  currentUser: user-1
  cart: cart-1
  products: [p1, p2]
```

The `products` root is a plain id list even though the field returns a `ProductConnection` —
MockQL synthesizes the `edges`/`pageInfo` wrapper and honors `first`/`after` pagination.

### Step 3: Handle the mutation

Start the server with a handler for `addToCart`. The handler receives the operation's coerced
input and a transactional view of state; whatever it changes is visible to every later query:

```swift
let server = try await MockQLServer.start(
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
```

### Step 4: Launch the app against it

```swift
let app = XCUIApplication()
app.launchEnvironment["GRAPHQL_URL"] = server.url.absoluteString
app.launch()
```

### Step 5: Drive the flow and assert

```swift
app.buttons["Add to cart"].tap()
XCTAssertEqual(app.staticTexts["cart-badge"].label, "1")

app.buttons["Checkout"].tap()
```

The tap sends `addToCart` to MockQL; the badge's follow-up `cart` query sees the item the
handler inserted. No stub files were edited, and the state stayed consistent across the two
requests.

### Step 6: Push a subscription event

If the order screen subscribes to `orderStatusChanged`, fire the event at the moment the test
needs it:

```swift
try await server.publish("orderStatusChanged", payload: [
    "id": "order-1",
    "status": .enumValue("SHIPPED"),
])
XCTAssertTrue(app.staticTexts["Shipped"].waitForExistence(timeout: 2))
```

### Step 7: Clean up

```swift
try await server.stop()
```

## What you learned

- Schemas load from the same SDL file your app uses; seeds are schema-validated YAML.
- Mutations are plain Swift closures over transactional state.
- Connections, generated fields, and subscriptions come for free.

From here, read <doc:XCUITestIntegration> for the reusable test-class pattern, and the
`MockQLCore` module documentation for the full seeding and generation reference.
