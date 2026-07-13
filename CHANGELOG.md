# Changelog

All notable changes to MockQL will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **MockQL is now built on the MockCore platform** (`mockcore-swift`), the shared foundation
  extracted from this package so REST and GraphQL mocks can serve one port and one state store.
  The public API is unchanged: `GraphQLValue` and `MockQLError` are typealiases of MockCore's
  `MockValue` and `MockError`, every previously-public symbol is re-exported, and the full test
  suite passes without modification.
- `MockQLServer` is now a single-service `MockCoreTransport.MockHost` internally. Behavior for
  `POST`/`GET /graphql` (including GraphQL error envelopes) and `/health` is unchanged; requests
  to paths no service claims now receive the host's diagnostic 404 body
  (`{"error": "No registered mock service claims …"}`) instead of the previous GraphQL-style
  `{"errors": […]}` envelope. The status code is still 404.
- The Yams dependency moved to MockCore along with YAML seed decoding; MockQL no longer depends
  on it directly.

### Added

- `MockQLEngine` conforms to `MockCoreTransport.MockService`, so a GraphQL mock can be
  registered on a shared `MockHost` alongside sibling protocol mocks (e.g. MockREST) and answer
  on the same port, sharing one `StateStore`.

## [0.1.0] - 2026-07-12

### Added

- **Android support**: the full package (engine and SwiftNIO transport) builds and tests on an
  Android emulator in CI via the official Swift SDK for Android (Swift 6.3 toolchain, API 28).
- Swift Package Index manifest (`.spi.yml`) declaring documentation targets.
- **AI-agent resources**: `AGENTS.md` for agents contributing to the repository, a
  self-contained [integration guide](docs/agents/integration-guide.md) for agents adding MockQL
  to other projects (canonical patterns, pitfalls, error→fix table), and an `llms.txt` index.
- **DocC documentation**: catalogs for both modules with a getting-started guide, an XCUITest
  integration guide, a step-by-step tutorial, and topic guides for schemas, seeding, mutations
  and state, data generation, and subscriptions; doc comments across the public API; a CI job
  builds the docs with the swift-docc-plugin (new build-time-only dependency).

- **Full working server.** `MockQLServer.start(...)` binds an ephemeral localhost port and
  serves GraphQL over HTTP (`POST /graphql`, `GET /graphql?query=…`, `/health`) and
  subscriptions over the `graphql-transport-ws` WebSocket protocol.
- **Portable engine** (`MockQLCore`, no SwiftNIO): hand-written GraphQL lexer/parsers with
  precise diagnostics, validated schema model (interfaces, unions, enums, inputs, custom
  scalars), executor with fragments, `@skip`/`@include`, variables, non-null bubbling, and
  Relay connection synthesis with `first`/`after` pagination.
- **Seed format v1**: `version`/`data`/`roots` documents in YAML or JSON, schema-driven
  reference resolution, qualified `Type:id` references, embedded value objects, GraphQL-spec
  coercion, and fail-fast validation with "did you mean" suggestions.
- **Result-builder DSL**: `Query`/`Object`/`Field` schema shapes (standalone or overlaying an
  SDL schema), `Mutation` handlers with transactional `inout MutationState`, `Seed`/`Value`/
  `Root` seeding, and `Generate` bindings.
- **Deterministic data generators**: names, emails, phone numbers (formatted and E.164), UUIDs,
  URLs, usernames, sentences, ISO-8601 timestamps, ranges, and custom closures — stable per
  record/field and reproducible via `serverSeed`.
- **Stateful mutations**: an actor-backed store with atomic, transactional handler commits;
  `id`-argument fields resolve as record lookups.
- 170+ unit and integration tests, including live HTTP and WebSocket round-trips against
  bundled sample schemas and seeds.
- Initial project scaffolding: Swift package structure, CI pipeline, formatting configuration,
  and open source project documentation.
- Architecture and seed-format design documents (`docs/design/`); two-module layout
  (`MockQLCore` portable engine + `MockQL` SwiftNIO transport) with Yams and SwiftNIO
  dependencies declared.

[Unreleased]: https://github.com/AlexNachbaur/mockql-swift/compare/0.1.0...HEAD
[0.1.0]: https://github.com/AlexNachbaur/mockql-swift/releases/tag/0.1.0
