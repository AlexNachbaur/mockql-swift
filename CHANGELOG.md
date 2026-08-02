# Changelog

All notable changes to MockQL will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Query diagnostics (`diagnostics: true`).** Every list- and connection-typed field reports how
  it was narrowed, under `extensions.mockql.fields`: the arguments applied as filters, the
  arguments that were present but filtered nothing, the node counts before and after, and whether
  a `Filter` or `Resolve` hook took over.

  Filtering is quiet by design — an argument naming no scalar node field is ignored, and a filter
  matching nothing returns an empty list — and from the client both look exactly like a mis-seeded
  store. `ignoredArguments` is the high-value half: an argument you expected to filter showing up
  there means it does not name a singular scalar field on the node type.

  Off by default. Carried in `extensions` rather than a log so it behaves identically in-process,
  over HTTP, and on platforms with no logging backend.

### Fixed

- **A `null` filter argument returned an empty list instead of everything.** The argument-name
  convention treated an explicitly-passed `null` as an equality filter *against null*, so
  `things(status: null)` matched only nodes whose `status` was null — usually none. That is
  defensible as a strict reading, but it is not what real GraphQL servers do, and it broke the
  single most common query a generated client can send: Apollo iOS (like Relay and urql) compiles
  an unset optional variable into an explicit `null` in the variables payload, so
  `query Q($status: Status) { things(status: $status) }` carries `"status": null` whether or not
  the caller set it. Consumers saw an empty result with no error explaining it — silent strictness,
  which is as much of a bug factory in test infrastructure as silent leniency.

  A null argument is now ignored, exactly as an omitted one is.

  **Behaviour change.** Matching null-valued nodes is still possible, but must now be stated
  explicitly with a `Filter` rather than falling out of the convention:

  ```swift
  Filter("Query.tags") { node, arguments in
      guard let group = arguments.objectValue?["group"], group.isNull else { return true }
      return node["group"].isNull
  }
  ```

## [0.4.1] - 2026-07-27

### Fixed

- **CRLF documents failed to lex.** A schema or operation with Windows line endings threw
  `Unexpected character` at the first line break, making every `.graphqls` file unusable on a
  default Windows git checkout. Swift's `Character` is a grapheme cluster, so `"\r\n"` is a
  single element equal to neither `"\r"` nor `"\n"`: the lexer's whitespace switch listed both
  and still missed it, `advance()` never counted the line, and block-string dedenting never
  split. Line terminators are now normalized over `unicodeScalars`, where CR and LF are always
  distinct, before tokenizing. Found by the new Windows CI job on its first run.

### Changed

- **Minimum toolchain is now Swift 6.3** (`swift-tools-version: 6.3`, was 6.1). This aligns
  every package in the platform on one toolchain: the Swift SDK for Android starts at 6.3, and
  `securestore-swift` already required it. Consumers on Swift 6.1 or 6.2 must upgrade.
- CI now builds and tests on **macOS, an iOS simulator, Linux, Windows, and an Android
  emulator**. Windows and iOS were previously untested, and iOS is the primary target for
  XCUITest automation.
- **Windows is now fully supported, transport included.** The previous claim that `MockQLCore`
  existed for "platforms where SwiftNIO is unavailable, such as Windows" was out of date —
  NIOPosix has carried a Windows port since well before 2.101. `MockQLCore` remains the
  in-process execution path, which is what it is actually useful for.
- The lint job now gates every other job, and the Linux job gates the expensive runners, so a
  formatting or compile failure is caught before macOS/Windows/Android minutes are spent.
- The documentation build no longer runs in CI. `swift package generate-documentation` remains
  a required local pre-commit step (see AGENTS.md and CONTRIBUTING.md).
- Dependabot now watches the `github-actions` ecosystem in addition to `swift`, grouped into a
  single weekly PR.

## [0.4.0] - 2026-07-25

### Added

- **Argument-based filtering for list and connection fields.** A list- or connection-typed field's
  seeded nodes are now filtered by any argument whose name matches a scalar (or enum) field on the
  node type, keeping nodes whose value equals the argument — so parent-scoped fields like
  `comments(postId:)`, `orders(customerId:)`, or `tasks(projectId:)` resolve from a flat seed with
  no configuration. Pagination arguments (`first`/`last`/`before`/`after`) and arguments that don't
  name a scalar node field are ignored; filtering runs before connection pagination and applies to
  plain object lists as well. Node references are dereferenced against the store to read field
  values. See the [Filtering and Resolving](Sources/MockQLCore/MockQLCore.docc/FilteringAndResolving.md)
  guide.
- **`Filter` declaration** — register a custom predicate `(node, arguments) -> Bool` for a
  `"Type.field"`, overriding the argument-name convention for a field whose arguments don't map to
  node fields by equality (ranges, substrings, computed matches).
- **`Resolve` declaration** — register a custom resolver `(arguments, StoreView) -> GraphQLValue`
  for a `"Type.field"`, bypassing seeded-node lookup for search, aggregation, or cross-type joins.
  Return node references to have MockQL synthesize the connection, or a fully-formed value. A
  resolver is authoritative: its output is not post-filtered, and declaring both a `Resolve` and a
  `Filter` for the same field is a configuration error. The new ``StoreView`` gives resolvers
  read-only access to stored records.
- **Configuration-time validation of `Filter`/`Resolve` keys** against the assembled schema —
  `Type.field` shape, type and field existence (with "did you mean" suggestions), and, for a
  `Filter`, that the target field returns a list or connection — so a typo fails loudly instead of
  silently doing nothing, consistent with generator-binding validation.

## [0.3.0] - 2026-07-23

### Added

- **Configurable transport paths for GraphQL over HTTP and the subscription WebSocket.** A new
  `MockQLService` value serves a `MockQLEngine` with independently-configurable `httpPath` and
  `subscriptionPath` (both defaulting to `/graphql`), plus a
  `MockQLEngine.service(httpPath:subscriptionPath:)` convenience for mounting on a shared
  `MockHost`. `MockQLServer.start(…)` gains matching `httpPath`/`subscriptionPath` parameters and
  reflects them in `url` / `webSocketURL`. This lets the mock mirror a server that splits the two
  — e.g. queries/mutations on `/graphql` and `graphql-transport-ws` subscriptions on a dedicated
  realtime path such as `/realtime/connect` — so a client configured for the real server talks to
  the mock without special-casing it. A bare `MockQLEngine` still conforms to `MockService` on
  `/graphql` for both, so existing code is unchanged.

## [0.2.0] - 2026-07-17

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

[Unreleased]: https://github.com/AlexNachbaur/mockql-swift/compare/0.2.0...HEAD
[0.2.0]: https://github.com/AlexNachbaur/mockql-swift/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/AlexNachbaur/mockql-swift/releases/tag/0.1.0
