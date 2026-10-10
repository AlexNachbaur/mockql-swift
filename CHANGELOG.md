# Changelog

All notable changes to MockQL will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Fixes from the October 2026 audit (finding ids `MQ-…` in the workspace `AUDIT.md`). Several are
**behaviour changes**: MockQL now rejects things it used to accept in silence. Each one is a case
where the mock was more lenient than the real server it stands in for — which is exactly how a
test passes against the mock and the feature fails in production.

### Added

- **Backward pagination: `last` and `before`.** Connections now implement the whole Relay cursor
  algorithm — `after`/`before` narrow the window, then `first` keeps its head and `last` its
  tail — with `hasNextPage`/`hasPreviousPage` reported accordingly. The two arguments were
  previously accepted and ignored, so "load previous messages" silently returned the first page
  again. (MQ-7)
- **`MockQLServer.start(diagnostics:store:)`.** The engine has taken both for a while; the server
  facade most tests actually call could pass neither, so turning on query diagnostics or sharing
  a `StateStore` with a sibling service meant abandoning the convenience initializer. Both
  default to their previous behaviour. (MQ-12)
- **Queries and mutations over the WebSocket.** `graphql-transport-ws` lets `subscribe` carry any
  operation, and clients configured to send everything down one socket do exactly that. A query
  or mutation now yields a single `next` and then `complete`; it used to be refused with
  "subscribe(_:) requires a subscription operation". (MQ-9)
- **Surrogate-pair and braced unicode escapes in string literals.** `"\uD83D\uDE00"` — how
  JSON-minded tooling writes anything outside the Basic Multilingual Plane — and `"\u{1F600}"`
  both lex to the one character they mean. Each half of a pair was previously rejected as an
  invalid escape, so an operation carrying an escaped emoji failed to parse. (MQ-16)

### Changed

- **`GET` no longer executes mutations.** A mutation sent as `GET /graphql?query=mutation…` is
  refused with `405 Method Not Allowed` (`Allow: POST`) and a GraphQL error body, and its handler
  does not run. `GET` must be safe to repeat and prefetch; a real GraphQL-over-HTTP server
  refuses this, and an app that depended on it working would only find out in production. (MQ-22)
- **`Int` is range-checked to 32 bits.** An `Int` argument or variable outside
  −2,147,483,648…2,147,483,647 is now a `BAD_INPUT` error naming the value, as the specification
  requires and real servers enforce. If a schema carries millisecond timestamps or large ids in
  `Int`, the real server is already rejecting them — use `Float` or a custom scalar. (MQ-18)
- **A negative `first` or `last` is an error**, not "no limit": the field fails with
  `Argument 'first' of 'Query.products' must be a non-negative integer, found -1`. (MQ-7)
- **Subscription arguments are validated when the client subscribes.** They were never coerced at
  all, so `orderUpdated` could be subscribed to without its required `id: ID!`, or with an
  argument that doesn't exist, and the client simply waited on a stream that was never valid.
  Missing, unknown (with a "did you mean"), and mistyped arguments now fail the subscription up
  front — over the socket, as a protocol `error`. (MQ-8)
- **Schemas are checked for interface conformance and default-value types at load.** A type that
  declares `implements Node` must now provide every field of `Node`, with a compatible type and
  the same arguments; an argument or input-field default must be a valid value of its declared
  type (`first: Int = "ten"` and a misspelt enum default are load errors, the latter with a
  suggestion). Both used to load cleanly and then fail — or quietly misbehave — on whichever
  request first relied on them. (MQ-21)
- **Ambiguous configuration is rejected instead of resolved by position.** Inside a
  configuration block, these now throw a `configuration` error before the engine starts: a
  `Seed` given a literal that isn't an object of fields (it used to become an empty record), a
  `Seed` with two `Value`s for the same field, two `Root`s for the same field, and — over an SDL
  schema — two `Object` blocks binding a generator to the same field. In each case the last one
  used to win without a word. (MQ-20)
- **An undeclared variable is reported as such.** `Variable '$x' was not provided` covered two
  different mistakes; now that a declared-but-omitted variable is legal (see Fixed), what remains
  is a variable the operation never declared, and the message says so:
  `Variable '$x' is not declared by this operation.`, with a suggestion drawn from the variables
  it does declare.
- **A null in a non-null position is reported once, and says what was null.** A null element of
  `[Item!]!` produced up to three errors — one for the element (labelled as the field), one for
  the list, and one more per non-null ancestor. There is now exactly one, at the element's path:
  `Cannot return null for non-nullable element 1 of list field 'Cart.items'`. Likewise, when a
  specific error already explains the null (a dangling reference, say), no generic
  `Cannot return null…` is stacked on top of it. (MQ-19)
- **Source columns count Unicode scalars**, as the specification defines source text, rather than
  Swift grapheme clusters. Locations in ASCII documents are unchanged; a column that follows a
  multi-scalar character (a decomposed accent, a flag emoji) on the same line shifts right.
  (MQ-16)

### Fixed

- **An interface narrowed to a sub-interface no longer fails schema validation.** The
  conformance check added below resolved covariance through the list of *object* implementors
  only, so `interface Named implements Node` could not stand in for a field declared as `Node`
  — valid SDL that was rejected at startup (found in review). `Schema.InterfaceType` now carries
  `interfaces`, interfaces are checked against the interfaces they implement, and covariance
  walks them.
- **A `Resolve` on a root `Mutation` or `Subscription` field is rejected at startup** instead
  of being accepted and never run. The handler (or `publish`) produces that value and the
  executor passes it through, so the hook could not fire; a configured hook that silently does
  nothing is the kind of leniency this release removes. `Filter` on those fields still applies.
- **Request errors omit `data` rather than carrying `null`.** The spec (§7.1.2) distinguishes an
  error raised before execution — `data` absent — from a failed execution — `data: null`. Over
  the WebSocket these now arrive as a terminal `error` message, as the protocol expects, rather
  than a `next`.
- **A WebSocket text message is capped at 16 MiB, and a `continuation` frame with no message to
  continue closes the socket with 1002.** NIO caps each frame; a client sending endless
  non-final continuation frames could otherwise grow memory without bound.
- The `405` for a `GET` mutation lists `Allow: GET, POST` — the methods the resource supports,
  per RFC 9110 — rather than `POST` alone.
- **Request errors were swallowed, leaving `{"data": null}` and nothing else.** An unknown
  fragment spread, a `@skip`/`@include` with a missing or non-Boolean `if`, or an undeclared
  variable in a directive threw inside the executor, and the top-level `catch` discarded the
  error on its way to returning null. The client saw a failed request with no reason — from the
  app's side, indistinguishable from a legitimately empty result. The error is now in `errors`,
  with its location and suggestion. (MQ-1)
- **Omitting a nullable variable was an error.** `query Q($n: Int) { products(first: $n) }` sent
  without `n` failed with "Variable '$n' was not provided". The specification says a declared
  variable with no value makes the argument *absent*, so its default applies — and that is the
  ordinary case for every client that only sends the variables the caller set. (MQ-2)
- **The mutation root ignored `@skip`/`@include`, rejected fragments, and could run a handler
  twice.** A mutation field under `@skip(if: true)` ran its handler and changed state anyway.
  A fragment spread at the mutation root was refused outright. Two selections of the same
  response key ran the handler once each. The mutation root is now collected exactly as a query's
  is: directives are honored, fragments are expanded, and fields sharing a response key run once
  with their selection sets merged. (MQ-3)
- **`Filter` and `Resolve` hooks, and query diagnostics, did not apply inside mutation payloads
  or subscription events.** The same field — `Board.cards(minPoints:)` — returned different
  results depending on whether a query, a mutation's payload, or a subscription event reached
  it, because only the query path was handed the hooks. All three now behave identically, and
  `diagnostics: true` reports on all three. (MQ-5)
- **A mutation's null-violation error blamed the `Query` type, and its pagination arguments were
  dropped.** `Cannot return null for non-nullable field 'Query.updateDisplayName'` now names
  `Mutation` (or `Subscription`); and a mutation returning a connection honors its own
  `first`/`after`/`last`/`before`. A handler's return value is otherwise passed through as
  given — it is never re-filtered by the mutation's own arguments. (MQ-6)
- **A cursor with a negative index crashed the process.** `after: "cursor:-9"` computed a
  negative array index and trapped, taking the test host down with it. Cursors pointing outside
  the list now clamp to it and yield an empty page.
- **WebSocket: `complete` followed `error`; a reused id could be evicted; split characters were
  corrupted.** `error` is terminal in `graphql-transport-ws`, but a `complete` was sent after it.
  When a client completed an operation and immediately reused its id, the finished operation's
  cleanup removed the *new* one from the connection's bookkeeping (and announced a stale
  `complete` for it). And a fragmented text message was decoded frame by frame, so a multi-byte
  UTF-8 character straddling two frames turned into replacement characters; frames are now
  joined before decoding, and a message that is not valid UTF-8 closes the socket with 1007.
  (MQ-9)
- **Combining marks confused the lexer.** Lexing by grapheme cluster meant a `"` followed by a
  combining mark was no longer recognised as a quote, and a letter carrying a combining mark with
  no precomposed form (`b` + U+0301) passed as a name character. The lexer now works on Unicode
  scalars, and names are ASCII-only as the grammar says. (MQ-16)
- **Building MockQL as a dependency emitted four "result unused" warnings** from the SDL parser,
  and the DocC build emitted eight more that the local documentation step should have been
  failing on. Both are clean. (MQ-15)

### Documentation

- Every public declaration now has a doc comment — `Schema`'s nested types and their properties,
  the result-builder statics, and the `MockService` members among them. (MQ-14)
- `docs/design/architecture.md` describes the module layout as it is since the MockCore
  extraction (no `SchemaBuilder DSL` or `SeedDocument`; the value model, store, and generators
  live in MockCore; Yams is not a direct dependency). The README no longer implies the WebSocket
  integration tests run on all five platforms — they run on Apple platforms only — and
  `docs/design/README.md` points at the shipped documentation instead of listing it as planned.
  (MQ-13)

## [0.5.0] - 2026-08-02

### Added

- **Query diagnostics (`diagnostics: true`).** Every list- and connection-typed field reports how
  it was narrowed, under `extensions.mockql.fields`: the arguments applied as filters, the
  arguments that were present but filtered nothing, the node counts before and after, and whether
  a `Filter` or `Resolve` hook took over.

  Filtering is quiet by design — an argument naming no scalar node field is ignored, and a filter
  matching nothing returns an empty list — and from the client both look exactly like a mis-seeded
  store. `ignoredArguments` is the high-value half: an argument you expected to filter showing up
  there means it does not name a singular scalar field on the node type.

  A field resolving more than once in a response — once per parent for a nested list, once per
  alias — is aggregated rather than overwritten: counts sum, argument names union, and an
  `occurrences` count says how many were folded in.

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

[Unreleased]: https://github.com/AlexNachbaur/mockql-swift/compare/0.5.0...HEAD
[0.5.0]: https://github.com/AlexNachbaur/mockql-swift/compare/0.4.1...0.5.0
[0.4.1]: https://github.com/AlexNachbaur/mockql-swift/compare/0.4.0...0.4.1
[0.4.0]: https://github.com/AlexNachbaur/mockql-swift/compare/0.3.0...0.4.0
[0.3.0]: https://github.com/AlexNachbaur/mockql-swift/compare/0.2.0...0.3.0
[0.2.0]: https://github.com/AlexNachbaur/mockql-swift/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/AlexNachbaur/mockql-swift/releases/tag/0.1.0
