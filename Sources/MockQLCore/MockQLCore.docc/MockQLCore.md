# ``MockQLCore``

The portable MockQL engine: schemas, seeding, state, execution, and data generation — no
networking dependencies.

## Overview

`MockQLCore` is everything MockQL does except the network transport. It parses and validates
GraphQL schemas, loads seed documents, maintains stateful records, executes operations, and
generates deterministic mock data. The `MockQL` module builds the HTTP/WebSocket server on top
and re-exports this module, so most users just `import MockQL`.

Import `MockQLCore` directly when you want in-process execution with no server — for unit tests
of GraphQL-consuming code, or on platforms where SwiftNIO is unavailable (such as Windows):

```swift
import MockQLCore

let engine = try await MockQLEngine(
    schema: .sdl("type Query { greeting: String! }"),
    generators: ["Query.greeting": .constant(.string("hello"))]
)
let response = await engine.execute(GraphQLRequest(query: "{ greeting }"))
```

### Guides

- <doc:DefiningSchemas> — SDL files or the result-builder DSL.
- <doc:SeedingData> — the `version`/`data`/`roots` seed format and its validation rules.
- <doc:MutationsAndState> — handlers, transactional state, and the store.
- <doc:GeneratingData> — deterministic generators and field-name inference.
- <doc:WorkingWithSubscriptions> — publishing events and consuming streams.

## Topics

### Guides

- <doc:DefiningSchemas>
- <doc:SeedingData>
- <doc:MutationsAndState>
- <doc:GeneratingData>
- <doc:WorkingWithSubscriptions>

### Engine

- ``MockQLEngine``
- ``SchemaSource``
- ``SeedSource``
- ``GraphQLRequest``
- ``GraphQLResponse``

### Values

- ``GraphQLValue``

### Configuration DSL

- ``MockQLDeclaration``
- ``Query``
- ``Mutation``
- ``Subscription``
- ``Object``
- ``Field``
- ``Seed``
- ``Value``
- ``Root``
- ``Generate``
- ``MutationHandler``
- ``MockQLBuilder``
- ``FieldListBuilder``
- ``SeedValueBuilder``

### State

- ``StateStore``
- ``MutationState``

### Data generation

- ``FieldGenerator``
- ``GeneratorContext``
- ``GeneratorRegistry``
- ``RandomSource``

### Schema model

- ``Schema``
- ``TypeReference``
- ``OperationType``

### Diagnostics

- ``MockQLError``
- ``GraphQLError``
- ``GraphQLPathSegment``
- ``SourceLocation``

### Package

- ``MockQLVersion``
