# Getting Started

Add MockQL to your test target and stand up a stateful GraphQL server in a few lines.

## Add the package

In `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/AlexNachbaur/mockql-swift.git", from: "0.1.0")
]
```

Then add the `MockQL` product to your **test target** — MockQL is a test-time tool and does not
belong in your app target:

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

## Start a server

The fastest path uses your existing schema file plus a seed document:

```swift
import MockQL

let server = try await MockQLServer.start(
    schema: .file("Schemas/app.graphqls"),
    seed: .file("Fixtures/base.yaml")
)
```

`start` binds an ephemeral localhost port (safe for parallel test runs) and validates everything
— the schema, the seed document, and all cross-references — before returning. A typo in a seed
file fails here, with a message like:

```
Fixtures/base.yaml: Unknown field 'emial' on type 'User'. Did you mean 'email'? (at data.User[0].emial)
```

No schema file handy? Declare one in Swift:

```swift
let server = try await MockQLServer.start {
    Query("currentUser") {
        Object("User") {
            Field("id", .uuid)
            Field("name", .fullName)
            Field("email", .email)
        }
    }
    Seed("User", id: "user-1") {
        Value("name", "Avery Quinn")
    }
    Root("currentUser", "user-1")
}
```

## Point your app at it

The app under test reads the server's URL from its launch environment:

```swift
let app = XCUIApplication()
app.launchEnvironment["GRAPHQL_URL"] = server.url.absoluteString
app.launch()
```

Inside the app, read `ProcessInfo.processInfo.environment["GRAPHQL_URL"]` when configuring your
GraphQL client (Apollo, urql via a web view, or a hand-rolled URLSession layer — anything that
speaks GraphQL over HTTP works).

## Verify it's serving

Every server exposes `GET /health` and supports plain GET queries for quick manual checks:

```
curl 'http://127.0.0.1:PORT/graphql?query={currentUser{name}}'
```

## Next steps

- <doc:XCUITestIntegration> for the full test-suite pattern.
- <doc:YourFirstMockedTest> for a guided walkthrough.
- The `MockQLCore` module documentation for seeding, mutations, generators, and subscriptions
  in depth.
