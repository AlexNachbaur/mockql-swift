# CLAUDE.md — MockQL Swift GraphQL Mocking Service

## Decision-Making Rules

- **Never assume or default to the easiest solution.** When there are choices, options, or architectural decisions to make, stop and ask first.
- Present options with pros/cons and a recommendation, but the user has the ultimate say.
- Ask clarifying questions before proceeding when requirements are ambiguous or multiple valid approaches exist.
- Do not silently pick an approach — even if one seems obvious.
- Decisions already made (see "Decided Architecture" below) do not need re-asking — build on them.

## Project Summary

Native Swift GraphQL server for local XCUITest automation, allowing for easy pluggability for auto-generating content like names, email addresses, phone numbers, and other data in an expressive format. Includes expressive ResultBuilder patterns for defining the shape of data the user wants to return, closures for responding to mutation requests, and hooks for triggering subscription events. Maintains state in-memory to allow consistent resolution of responses. Can be seeded with initial JSON or YAML data at launch, either from a file, inline, or ResultBuilder initializers. Cross-platform: built for XCUITest first, but the core runs anywhere Swift runs (macOS, iOS, Linux, Windows, Android).

## Design Principles

1. **Developer Experience is of the utmost importance.** APIs must be ergonomic, expressive, and easy to use, and must support a variety of use-cases depending on the consumer's schema or environment (SDL file or Swift DSL; file, inline, or builder seeds; HTTP transport or in-process execution).
2. **Error messages are a product feature.** Every user-facing error (parse errors, seed validation, execution errors) must carry precise source locations/paths and actionable guidance — including "did you mean" suggestions for likely typos. Never regress diagnostic quality; the hand-written parser exists to enable this.
3. **Follow Swift developer best practices.** Easily-maintainable code, no shortcuts. Strict concurrency (Swift 6 language mode), `Sendable` correctness, small focused types, documentation comments on all public API.
4. **Everything requires unit tests.** Testability is a strict requirement. Design for it: inject randomness (seeded RNG), ports (bind ephemeral, expose the resolved URL), and file access. No untested public API.
5. **Integration tests validate the full stack** — real HTTP/WebSocket round-trips against the running server with multiple sample schemas and seed documents, not just unit-level coverage.
6. **Fail loud and early.** Seed documents and schemas are fully validated before the server starts. Silent leniency in test infrastructure is a bug factory.

## Decided Architecture

These decisions were made with the project owner and are settled:

- **License/distribution**: MIT, open source at `github.com/AlexNachbaur/mockql-swift`.
- **Toolchain/platforms**: Swift 6.1. `Package.swift` declares Apple minimums (macOS 14 / iOS 17) solely for concurrency availability; this does not limit Linux/Windows/Android support.
- **Dependency policy**: SwiftNIO for the network transport, Yams for YAML. The GraphQL SDL/operation parser is **hand-written** (diagnostics quality + portability). No other dependencies without asking.
- **Module layout**:
  - `MockQLCore` — pure portable Swift (Yams only; **never import NIO here**): value model, lexer/parsers, schema model, result-builder DSL, generators, seed loading/validation, in-memory state store, executor/engine.
  - `MockQL` — transport layer on SwiftNIO (HTTP `POST /graphql` + `graphql-transport-ws` WebSocket subscriptions) and the `MockQLServer` facade; re-exports `MockQLCore`.
- **Subscriptions**: the `graphql-transport-ws` protocol (what Apollo/urql/Relay speak).
- **Seed format v1** (full spec in `docs/design/seed-format.md`):
  - Top-level sections: `version: 1`, `data:` (records grouped by GraphQL object type name), `roots:` (wires root Query fields to stored records).
  - **Schema-driven reference resolution**: a string in an object-typed field position is a reference to a record's `id`; scalar-typed fields are always literal. `Type:id` qualified references are accepted anywhere and **required** for interface/union-typed positions.
  - Inline nested objects are allowed as anonymous embedded records (value types).
  - Omitted fields are filled by generators and stay **stable** for the server's lifetime; `field: null` pins an explicit null (only valid for nullable fields).
  - Coercion follows the GraphQL spec (numerics coerce to `ID` strings; enums validated; custom scalars pass through).
  - Relay connection synthesis: id lists auto-wrap into `edges/node/cursor/pageInfo` when the schema field is a Connection type, honoring `first`/`after`.
  - Validation is fail-fast at load with file/line diagnostics: unknown type/field (with suggestions), dangling refs, duplicate ids, enum mismatches, non-coercible scalars.

## Testing Rules

- Swift Testing (`import Testing`), not XCTest, for all new tests.
- Unit tests per module in `Tests/MockQLCoreTests` and `Tests/MockQLTests`; integration tests in `Tests/MockQLIntegrationTests` drive real HTTP/WS round-trips (URLSession / FoundationNetworking on Linux) against sample schemas + seeds stored as test resources.
- `swift build`, `swift test`, and `swift format lint --strict --recursive Sources Tests Package.swift` must pass before any commit. CI runs macOS and Linux; code must pass on both.
- No force unwraps in tests either — use `try #require(...)`.

## Code Style

- 120 character line length
- 4-space indentation
- swift-format enforced (see `.swift-format`)
- No force unwraps in production code
- No `DispatchQueue` — use Swift concurrency
- Prefer value types over reference types

## Swift Patterns & Anti-Patterns

- **NEVER use caseless enums as namespaces or containers.** Enums are for enumerated values only. For singletons, utilities, or groupings of static members, use a class or struct with a `static let shared` instance or static methods.
- For shared resources (e.g., a shared URLSession, a bootstrap coordinator), use a `final class` with `static let shared`.
- For page sizes, configuration constants, etc., use a struct with static properties — not an empty enum.

## Important Files

- `docs/design/` — Architecture and design documents (`architecture.md`, `seed-format.md`)
- `.swift-format` — Formatting configuration
- `.github/workflows/build.yml` — CI pipeline (macOS + Linux build/test, swift-format lint)
- `CHANGELOG.md` — keep the Unreleased section current as features land
