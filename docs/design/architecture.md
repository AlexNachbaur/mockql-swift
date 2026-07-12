# MockQL Architecture

Status: **accepted** · Last updated: 2026-07-12

## Goals

- Local, stateful GraphQL mocking for UI-test automation (XCUITest first).
- Excellent developer experience: expressive Swift APIs, precise diagnostics, sensible defaults.
- Cross-platform core: macOS, iOS, Linux, Windows, Android.
- Fully unit-testable components plus end-to-end integration coverage.

## Module layout

```
┌────────────────────────────────────────────────────────┐
│ MockQL (transport + facade)              deps: NIO     │
│   MockQLServer, HTTP POST /graphql,                    │
│   graphql-transport-ws WebSocket subscriptions         │
├────────────────────────────────────────────────────────┤
│ MockQLCore (portable engine)             deps: Yams    │
│   GraphQLValue        dynamic value model              │
│   Lexer / Parser      SDL + executable documents       │
│   Schema              type-system model + validation   │
│   SchemaBuilder DSL   result-builder schema definition │
│   Generators          pluggable realistic data         │
│   SeedDocument        load / validate / coerce seeds   │
│   StateStore          actor-based in-memory records    │
│   Executor            spec-compliant(-enough) resolver │
│   MockQLEngine        schema + store + execute()       │
└────────────────────────────────────────────────────────┘
```

Rules:

- `MockQLCore` must never import NIO (or any Apple-only framework). It is the portability boundary:
  platforms without NIO support (Windows) can still `import MockQLCore` and execute operations
  in-process.
- `MockQL` re-exports `MockQLCore`, so `import MockQL` is the only import most consumers need.
- The hand-written parser is a deliberate decision (over GraphQLSwift/GraphQL): diagnostics quality
  is a product feature, and it keeps NIO types out of the core.

## Key decisions

| Decision | Choice | Why |
|---|---|---|
| Transport | SwiftNIO HTTP/1.1 + WebSocket | Industry standard, cross-platform (macOS/Linux) |
| Subscriptions | `graphql-transport-ws` | What Apollo/urql/Relay speak natively |
| YAML | Yams | Standard Swift YAML; hand-rolling YAML is a maintenance trap |
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
3. **Mutation**: dispatch to the registered Swift closure with `(input, state)`; the closure
   mutates the store through a transactional context; the returned value is resolved like a query.
4. **Subscription**: `server.publish(_:payload:)` from test code fans out `next` messages to
   matching `graphql-transport-ws` subscribers.

## Error philosophy

Every thrown error names its source (file/line for parse & seed errors, operation path for
execution errors) and, where a typo is plausible, suggests the nearest valid alternative.
Validation happens before the server starts serving — never lazily mid-test.
