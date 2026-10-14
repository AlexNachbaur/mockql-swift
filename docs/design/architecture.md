# MockQL Architecture

Status: **accepted** · Last updated: 2026-10-05

## Goals

- Local, stateful GraphQL mocking for UI-test automation (XCUITest first).
- Excellent developer experience: expressive Swift APIs, precise diagnostics, sensible defaults.
- Cross-platform core: macOS, iOS, Linux, Windows, Android.
- Fully unit-testable components plus end-to-end integration coverage.

## Module layout

```
┌──────────────────────────────────────────────────────────────────┐
│ MockQL (transport + facade)      deps: MockCoreTransport, NIO    │
│   MockQLServer       single-service host facade                  │
│   MockQLService      GraphQL over HTTP (POST; GET for queries)   │
│   GraphQLWSHandler   graphql-transport-ws over WebSocket         │
├──────────────────────────────────────────────────────────────────┤
│ MockQLCore (portable engine)     deps: MockCore                  │
│   Lexer / parsers    SDL + executable documents                  │
│   Schema             type-system model + validation              │
│   MockQLBuilder DSL  Query / Mutation / Object / Seed / Root /   │
│                      Generate / Filter / Resolve declarations    │
│   SeedLoader         validate / coerce seeds against the schema  │
│   Executor           spec-compliant(-enough) resolver            │
│   SubscriptionHub    subscriber registry + event fan-out         │
│   MockQLEngine       schema + store + execute() / subscribe()    │
├──────────────────────────────────────────────────────────────────┤
│ MockCore platform (mockcore-swift, shared with MockREST)         │
│   MockCore           MockValue (aliased here as GraphQLValue),   │
│                      StateStore, generators, seed decoding       │
│                      (JSON + YAML via Yams), MockError           │
│   MockCoreTransport  MockHost / MockService on SwiftNIO          │
└──────────────────────────────────────────────────────────────────┘
```

The value model, the state store, the generators, and seed *decoding* were extracted into the
MockCore platform so that GraphQL and REST mocks can share one store on one port. `MockQLCore`
re-exports `MockCore` and keeps the original spellings as type aliases (`GraphQLValue`,
`MockQLError`), so `import MockQLCore` — or `import MockQL` — is still the only import a
consumer needs. What stays here is everything GraphQL-specific: the language, the schema, seed
*validation* against that schema, and execution.

Rules:

- `MockQLCore` must never import NIO (or any Apple-only framework), and has no direct
  third-party dependency: Yams reaches it only through MockCore, which owns YAML decoding. It is the portability boundary:
  a host that cannot or does not want to bind a port can still `import MockQLCore` and execute
  operations in-process. (This was originally motivated by Windows, which SwiftNIO was assumed
  not to support; NIOPosix has since carried a Windows port and CI tests the full stack there,
  so the boundary now earns its keep for in-process execution rather than for portability.)
- `MockQL` re-exports `MockQLCore`, so `import MockQL` is the only import most consumers need.
- The hand-written parser is a deliberate decision (over GraphQLSwift/GraphQL): diagnostics quality
  is a product feature, and it keeps NIO types out of the core.

## Key decisions

| Decision | Choice | Why |
|---|---|---|
| Transport | SwiftNIO HTTP/1.1 + WebSocket, via MockCoreTransport's `MockHost` | Industry standard, cross-platform (macOS/iOS/Linux/Windows/Android); one host can serve several protocol mocks |
| Subscriptions | `graphql-transport-ws` | What Apollo/urql/Relay speak natively |
| YAML | Yams, inside MockCore | Standard Swift YAML; hand-rolling YAML is a maintenance trap. Not a direct dependency of this package |
| GraphQL parsing | Hand-written lexer/parser | Precise, friendly errors; no NIO leakage; portability |
| State | Single actor-backed store | Serialized mutations, `Sendable`-safe reads |
| Identity | `id` field per record (per-type key paths designed in for future `@key` support) | Matches Relay/Apollo normalized caches |
| Seeds | `version`/`data`/`roots` document (see [seed-format.md](seed-format.md)) | Collision-proof, versioned, schema-validated |

## Execution model

1. **Startup**: parse schema (SDL file or DSL) → validate → load seed document → validate/coerce
   against schema (fail fast with diagnostics) → populate `StateStore`.
2. **Query**: parse operation → validate variables → walk selections against the store, resolving
   references, synthesizing Relay connections, and generating missing field values (stable per
   record+field for the server's lifetime).
3. **Mutation**: collect the root fields exactly as a query's are (fragments, `@skip`/`@include`,
   one run per response key), then dispatch each to its registered Swift closure with
   `(input, state)`; the closure mutates the store through a transactional context; the returned
   value is resolved like a query, with the same `Filter`/`Resolve` hooks.
4. **Subscription**: the root field's arguments are validated when the client subscribes;
   `server.publish(_:payload:)` from test code then fans out `next` messages to matching
   `graphql-transport-ws` subscribers, each resolved through its own selection set.

Over HTTP, `GET` runs queries only — a mutation sent by `GET` is refused with `405`. Over the
WebSocket, `subscribe` carries any operation: a query or mutation yields one `next` and then
`complete`.

## Error philosophy

Every thrown error names its source (file/line for parse & seed errors, operation path for
execution errors) and, where a typo is plausible, suggests the nearest valid alternative.
Validation happens before the server starts serving — never lazily mid-test.
