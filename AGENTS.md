# AGENTS.md

Instructions for AI coding agents working **in this repository**. If you are integrating MockQL
into another project, read [docs/agents/integration-guide.md](docs/agents/integration-guide.md)
instead.

## What this package is

A native Swift GraphQL server for local UI-test automation. It loads a real SDL schema (or a
Swift result-builder declaration), seeds in-memory state from validated YAML/JSON, answers
mutations with Swift closures over transactional state, fills unseeded fields with
deterministic generated data, and serves HTTP plus `graphql-transport-ws` subscriptions on
localhost. Built for XCUITest first; the engine runs anywhere Swift does.

MockQL is the GraphQL extension of the MockCore platform. Protocol-neutral machinery — the
value model, state store, generators, seed primitives, diagnostics, and the `MockHost`
transport — lives in [mockcore-swift](https://github.com/AlexNachbaur/mockcore-swift). Don't
duplicate it here; propose changes that benefit every protocol there instead.

## Making decisions

- **Never assume or default to the easiest solution.** When there is a real choice — an
  architectural direction, a public-API shape, a behavior an existing test deliberately
  asserts — stop and ask first.
- Present the options with trade-offs and a recommendation; the maintainer has the final say.
- Do not silently pick an approach, even when one seems obvious.
- Decisions already recorded below are settled: build on them rather than re-asking.

## Build, test, lint

```sh
make check    # lint, build, test, docs — everything below, in the order CI gates them
```

`make check` must pass before any commit. It runs:

```sh
swift format lint --strict --recursive Sources Tests Package.swift
swift build
swift test
swift package generate-documentation --target MockQLCore --target MockQL --warnings-as-errors
```

`make format` applies the formatter. The documentation build is deliberately a **local** step:
CI does not run it, so a DocC regression will only ever be caught here.

CI builds and tests on macOS, an iOS simulator, Linux (`swift:6.3` container), Windows, and an
Android emulator, and must pass on all five. Do not introduce Apple-only framework imports in
library targets, and stick to Foundation APIs that swift-corelibs-foundation also provides.

## Design principles

1. **Developer experience comes first.** APIs must be ergonomic and expressive, and must
   support the consumer's situation: SDL file or Swift DSL; file, inline, or builder seeds;
   HTTP transport or in-process execution.
2. **Error messages are a product feature.** Every user-facing error (parse, seed validation,
   execution) carries a precise source location or document path and actionable guidance —
   including "did you mean" suggestions for likely typos. Never regress an error message; the
   hand-written parser exists to make this possible.
3. **Everything requires unit tests.** Design for testability: inject randomness (seeded RNG),
   ports (bind ephemeral, expose the resolved URL), and file access. No untested public API.
4. **Integration tests validate the full stack** — real HTTP/WebSocket round trips against a
   running server with several sample schemas and seeds, not only unit-level coverage.
5. **Fail loud and early.** Seeds and schemas are fully validated before the server starts.
   Silent leniency in test infrastructure is a bug factory.

## Architecture (settled decisions — do not relitigate)

- **Toolchain/platforms**: Swift 6.3 (`swift-tools-version: 6.3`), matching every package in
  the platform. `Package.swift` declares Apple minimums (macOS 14 / iOS 17) solely for
  concurrency availability; that does not limit Linux/Windows/Android support.
- **Two modules**:
  - `MockQLCore` — the portable engine (**never import NIO here**): lexer and parsers, schema
    model, result-builder DSL, seed loading/validation, input coercion, and the executor. It
    depends only on `MockCore`, and re-exports it — `GraphQLValue` is `MockValue`,
    `MockQLError` is `MockError` — so MockCore's public API is part of MockQL's.
  - `MockQL` — the transport: a `MockService` conformance over `MockCoreTransport` (HTTP
    `POST /graphql` plus `graphql-transport-ws` WebSocket subscriptions) and the
    `MockQLServer` facade. Re-exports `MockQLCore`.
- **The GraphQL SDL/operation parser is hand-written** on purpose: diagnostic quality and
  portability.
- **Dependencies are fixed**: mockcore-swift, SwiftNIO (`NIOCore` and `NIOWebSocket`, in
  `MockQL` only), and swift-docc-plugin (build-time). YAML decoding comes from MockCore; this
  package does not depend on Yams directly. Adding any other dependency requires asking the
  maintainer first.
- **Subscriptions** speak `graphql-transport-ws` (what Apollo, urql, and Relay speak).
- **Seed format v1** — full specification in
  [docs/design/seed-format.md](docs/design/seed-format.md):
  - Top-level sections: `version: 1`, `data:` (records grouped by GraphQL object type name),
    `roots:` (wires root `Query` fields to stored records).
  - Schema-driven references: a string in an object-typed field position is a reference to a
    record's `id`; scalar-typed fields are always literal. `Type:id` qualified references are
    accepted anywhere and **required** for interface/union-typed positions.
  - Inline nested objects are anonymous embedded records (value types).
  - Omitted fields are filled by generators and stay **stable** for the server's lifetime;
    `field: null` pins an explicit null (valid only for nullable fields).
  - Coercion follows the GraphQL spec (numerics coerce to `ID` strings; enums validated;
    custom scalars pass through).
  - Relay connection synthesis: id lists auto-wrap into `edges/node/cursor/pageInfo` when the
    schema field is a Connection type, honoring `first`/`after`.
  - Validation is fail-fast at load with file/line diagnostics: unknown type or field (with
    suggestions), dangling references, duplicate ids, enum mismatches, non-coercible scalars.
- Architecture notes live in [docs/design/architecture.md](docs/design/architecture.md).

## Code style (enforced)

- swift-format with the checked-in `.swift-format`: 120 columns, 4-space indent.
- Swift 6 language mode with strict concurrency; `Sendable` correctness is not optional.
- No force unwraps anywhere (tests use `try #require(...)`); no `DispatchQueue` — Swift
  concurrency only; prefer value types and small focused types.
- Never use caseless enums as namespaces; use a struct with static members (or, for a
  genuinely shared resource, a `final class` with `static let shared`).
- Swift Testing (`import Testing`) for all tests, never XCTest.
- Every public symbol gets a doc comment; DocC must build with zero warnings.

## Testing rules

- Everything requires unit tests (`Tests/MockQLCoreTests`, `Tests/MockQLTests`).
- Full-stack behavior belongs in `Tests/MockQLIntegrationTests`: real HTTP/WebSocket round
  trips (URLSession; FoundationNetworking on Linux) against the bundled fixtures in
  `Tests/MockQLIntegrationTests/Fixtures/`.
- URLSession WebSocket tests must be gated `#if canImport(Darwin)` — the libcurl-backed
  URLSession on other platforms has no WebSocket support.
- Update `CHANGELOG.md` (Unreleased section) for user-visible changes, and say *why*.
- `MockQLVersion.current` must track the newest released heading in `CHANGELOG.md`: bump both
  in the release commit, and leave a fresh `## [Unreleased]` heading behind.

## Important files

- `docs/design/` — architecture and the seed-format specification.
- `docs/agents/integration-guide.md` — the guide for agents *using* MockQL; keep its API
  examples compiling when the public API changes.
- `.github/workflows/build.yml` — CI (lint gate, then Linux, then macOS/iOS/Windows/Android).
- `Makefile` — `make check`, the single pre-commit entry point.
