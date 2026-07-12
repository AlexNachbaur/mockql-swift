# Changelog

All notable changes to MockQL will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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

[Unreleased]: https://github.com/AlexNachbaur/mockql-swift/compare/main...HEAD
