# MockQL

[![Build](https://github.com/AlexNachbaur/mockql-swift/actions/workflows/build.yml/badge.svg)](https://github.com/AlexNachbaur/mockql-swift/actions/workflows/build.yml)
[![Swift 6.1](https://img.shields.io/badge/Swift-6.1-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%20%7C%20iOS%20%7C%20Linux%20%7C%20Windows%20%7C%20Android-blue.svg)](#requirements)
[![License: MIT](https://img.shields.io/badge/License-MIT-lightgrey.svg)](LICENSE)

A native Swift GraphQL mocking server for local UI-test automation.

MockQL runs a lightweight, stateful GraphQL server alongside your tests so your app can talk to
a real backend — one you fully control from Swift, with no fixtures folder full of brittle JSON
files and no network flakiness. It was built for XCUITest automation, but the server is written
in cross-platform Swift and runs anywhere a Swift toolchain does.

> **Status: pre-1.0.** The full stack shown below — SDL and DSL schemas, YAML/JSON seeding,
> stateful mutations, Relay connection synthesis, and `graphql-transport-ws` subscriptions — is
> implemented and covered by unit and integration tests. The API may still evolve before
> `1.0.0`; breaking changes are called out in the [CHANGELOG](CHANGELOG.md).

## Why MockQL?

UI tests that hit live backends are slow and flaky. UI tests that stub the network layer with
canned JSON are fast but rot quickly — every schema change means hand-editing fixtures, and
stateless stubs can't model flows like "add an item to the cart, then see it on the cart screen."

MockQL takes a different approach:

- **Bring your schema, or build one in Swift** — load your real GraphQL schema file (SDL), or
  declare one inline with an expressive `ResultBuilder` DSL.
- **Pluggable data generation** — auto-generate realistic names, email addresses, phone numbers
  (formatted or strict E.164), UUIDs, timestamps, and other content instead of hardcoding
  `"Test User 1"` everywhere. Generated values are deterministic and stable per record and field.
- **Stateful by design** — MockQL maintains in-memory state, so a mutation performed in one step
  of a test is reflected in every query that follows. Responses stay consistent for the lifetime
  of the server.
- **Mutation closures** — respond to mutation requests with plain Swift closures that read and
  update server state.
- **Subscription hooks** — trigger GraphQL subscription events from your test code to exercise
  real-time UI.
- **Flexible seeding** — bootstrap initial state from JSON or YAML, loaded from a file, provided
  inline, or composed with result-builder initializers.

## Defining a schema

There are two ways to tell MockQL what your API looks like.

**Load a GraphQL schema file (SDL).** Point MockQL at the same `.graphqls` file your app or
backend already uses. Every type is automatically mockable; attach generators to fields you want
populated with realistic data:

```swift
import MockQL

let server = try await MockQLServer.start(
    schema: .file("Schemas/shop.graphqls"),
    generators: [
        "User.name": .fullName,
        "User.email": .email,
        "User.phone": .phoneNumber,
    ]
)
```

**Or declare the schema in Swift.** For small tests — or projects without an SDL file handy —
describe the shape of your data with the result-builder DSL:

```swift
let server = try await MockQLServer.start {
    Query("currentUser") {
        Object("User") {
            Field("id", .uuid)
            Field("name", .fullName)
            Field("email", .email)
        }
    }
}
```

## Seeding initial state

Most tests want to start from a known world: *a signed-in user, two products, an empty cart.*
Seed data can come from a file, an inline string, or a result-builder initializer:

```swift
// From a file bundled with your test target…
let server = try await MockQLServer.start(
    schema: .file("Schemas/shop.graphqls"),
    seed: .file("Fixtures/checkout.yaml")
)

// …inline…
let server = try await MockQLServer.start(
    schema: .file("Schemas/shop.graphqls"),
    seed: .yaml("""
        version: 1
        data:
          Product:
            - id: product-1
              name: Espresso Machine
              priceCents: 64900
        """)
)

// …or built in Swift.
let server = try await MockQLServer.start(schema: .file("Schemas/shop.graphqls")) {
    Seed("Product", id: "product-1") {
        Value("name", "Espresso Machine")
        Value("priceCents", 64900)
    }
}
```

### Seed file format

Seed files are plain YAML or JSON with three top-level sections: `version`, `data` (records
grouped by GraphQL object type name), and `roots` (which wires root `Query` fields to stored
records):

```yaml
# Fixtures/checkout.yaml
version: 1

data:
  Product:
    - id: product-1
      name: Espresso Machine
      priceCents: 64900
      price: { amountCents: 64900, currency: USD }   # nested map = embedded value object
    - id: product-2
      name: Burr Grinder
      priceCents: 21900

  User:
    - id: user-1
      name: Avery Quinn
      email: avery@example.com

  Cart:
    - id: cart-1
      owner: user-1        # Cart.owner is typed `User` → resolved as a reference
      items: []            # starts empty; mutations append here

roots:
  currentUser: user-1
  cart: cart-1
  products: [product-1, product-2]
  featured: Product:product-1   # qualified reference — required for union/interface fields
```

The rules:

- **References are schema-driven, not string-driven.** A string in a field whose schema type is
  an object type (`Cart.owner: User`) is a reference to that record's `id`; a string in a
  scalar-typed field is always a literal. For interface- or union-typed fields, use the
  qualified `Type:id` form so MockQL knows the concrete type.
- **Nested maps embed value objects.** Types like `Money` or `Address` don't need top-level
  entries — write them inline where they're used.
- **Omitted fields are auto-generated.** If `User.phone` isn't in the seed file but a test
  queries it, the configured generator (or a type-appropriate default) fills it in — and the
  value stays stable for the lifetime of the server. Write `field: null` to pin an explicit null.
- **Relay connections are synthesized.** If a field is a Connection type (`ProductConnection`),
  a plain id list auto-wraps into `edges`/`node`/`pageInfo`, honoring `first`/`after`.
- **Everything is validated at load, before the server starts** — unknown types or fields (with
  "did you mean" suggestions), dangling references, duplicate ids, enum and scalar mismatches
  all fail fast with file/line diagnostics instead of surfacing mid-test.

The same document as JSON:

```json
{
  "version": 1,
  "data": {
    "Product": [
      { "id": "product-1", "name": "Espresso Machine", "priceCents": 64900 },
      { "id": "product-2", "name": "Burr Grinder", "priceCents": 21900 }
    ],
    "User": [{ "id": "user-1", "name": "Avery Quinn", "email": "avery@example.com" }],
    "Cart": [{ "id": "cart-1", "owner": "user-1", "items": [] }]
  },
  "roots": {
    "currentUser": "user-1",
    "cart": "cart-1",
    "products": ["product-1", "product-2"]
  }
}
```

The full specification lives in [docs/design/seed-format.md](docs/design/seed-format.md).

## Handling mutations

Mutations are plain Swift closures. Each closure receives the operation's input and a handle to
the server's state store; whatever it changes is visible to every subsequent query, so your app
sees a consistent world across the whole test:

```swift
let server = try await MockQLServer.start(
    schema: .file("Schemas/shop.graphqls"),
    seed: .file("Fixtures/checkout.yaml")
) {
    Mutation("addToCart") { input, state in
        state.update("Cart", id: "cart-1") { cart in
            cart["items"].append([
                "product": .reference("Product", id: input["productId"]),
                "quantity": input["quantity"] ?? 1,
            ])
        }
        return state["Cart", id: "cart-1"]
    }

    Mutation("updateDisplayName") { input, state in
        state.update("User", id: "user-1") { user in
            user["name"] = input["name"]
        }
        return state["User", id: "user-1"]
    }
}
```

Put together in an XCUITest:

```swift
func testAddingItemUpdatesCartBadge() async throws {
    let server = try await MockQLServer.start(
        schema: .file("Schemas/shop.graphqls"),
        seed: .file("Fixtures/checkout.yaml")   // cart-1 starts with no items
    ) {
        Mutation("addToCart") { input, state in
            state.update("Cart", id: "cart-1") { cart in
                cart["items"].append([
                    "product": .reference("Product", id: input["productId"]),
                    "quantity": 1,
                ])
            }
            return state["Cart", id: "cart-1"]
        }
    }

    let app = XCUIApplication()
    app.launchEnvironment["GRAPHQL_URL"] = server.url.absoluteString
    app.launch()

    app.buttons["Add to cart"].tap()
    // The app sends the addToCart mutation; MockQL updates its state.
    // The cart badge re-queries `cart` and now reflects one item.
    XCTAssertEqual(app.staticTexts["cart-badge"].label, "1")
}
```

## Subscriptions

The server speaks the [`graphql-transport-ws`](https://github.com/enisdenjo/graphql-ws/blob/master/PROTOCOL.md)
protocol — what Apollo, urql, and Relay use — at `server.webSocketURL`. Push events from test
code to exercise real-time UI:

```swift
try await server.publish("orderStatusChanged", payload: [
    "id": "order-1",
    "status": .enumValue("SHIPPED"),
])
```

Payload fields you omit are filled by generators, and payloads may reference seeded records
(`.reference("Order", id: "order-1")`).

## Installation

### Swift Package Manager

Add MockQL to your package dependencies:

```swift
dependencies: [
    .package(url: "https://github.com/AlexNachbaur/mockql-swift.git", from: "0.1.0")
]
```

Then add it to your **test target** (MockQL is a test-time tool; it does not belong in your app
target):

```swift
.testTarget(
    name: "MyAppUITests",
    dependencies: [
        .product(name: "MockQL", package: "mockql-swift")
    ]
)
```

In Xcode: **File ▸ Add Package Dependencies…**, enter the repository URL, and link the `MockQL`
library to your UI testing bundle.

## Requirements

MockQL requires a **Swift 6.1** toolchain and is written in cross-platform Swift — no
Apple-only framework dependencies.

| Platform | Support |
|---|---|
| macOS 14+ / iOS 17+ | Supported; built and tested in CI |
| Linux | Supported; built and tested in CI |
| Android (API 28+) | Supported; built and tested in CI on an Android emulator |
| Windows | Expected to work (core engine); CI verification planned |

Android builds use the official [Swift SDK for Android](https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html)
(Swift 6.3+ toolchain for cross-compilation; the package manifest itself stays at
swift-tools-version 6.1). The full stack — including the SwiftNIO transport — runs on Android,
not just the core engine.

The Apple OS minimums exist only to satisfy Swift concurrency availability on Apple targets —
they don't limit support elsewhere. MockQL is built with strict Swift concurrency: no
`DispatchQueue`, no data races.

The package ships two libraries: **`MockQL`** (the full server — engine plus SwiftNIO-backed
HTTP and `graphql-transport-ws` WebSocket transport) and **`MockQLCore`** (the portable,
NIO-free engine — schema, seeds, state, and in-process execution — for platforms where SwiftNIO
isn't available, such as Windows).

## TODO

- [ ] Windows CI configuration and build scripts
- [ ] GraphQL introspection support (for GraphiQL and codegen tooling)
- [ ] Recorded-response seeding: normalize a captured `{"data": …}` payload into records

## Documentation

Full API documentation — including a getting-started guide, an XCUITest integration guide, a
step-by-step tutorial, and deep dives on schemas, seeding, mutations, generators, and
subscriptions — is written as DocC catalogs and hosted on the
[Swift Package Index](https://swiftpackageindex.com/AlexNachbaur/mockql-swift/documentation).
Build it locally with:

```sh
swift package generate-documentation --target MockQL --target MockQLCore
```

Architecture and design documents live in [docs/design/](docs/design/).

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) for the development
setup, code style rules, and pull request process, and note the
[Code of Conduct](CODE_OF_CONDUCT.md). Security issues should be reported privately per
[SECURITY.md](SECURITY.md).

## License

MockQL is released under the [MIT License](LICENSE).

Copyright © 2026 Alex Nachbaur.
