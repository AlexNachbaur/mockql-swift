# MockQL Design Documents

Architecture and design documents for MockQL live here. Each document should cover one area of
the system and record the decisions made, the alternatives considered, and why.

Current documents:

- [architecture.md](architecture.md) — module layout, dependency policy, execution model, and
  the decision log.
- [seed-format.md](seed-format.md) — the v1 seed document specification (`version`/`data`/`roots`,
  schema-driven references, coercion, validation).

Planned areas (documents will be added as the design solidifies):

- **Server & transport** — how the local GraphQL server runs alongside UI tests, how the app
  under test connects to it, and how the transport stays cross-platform (macOS, iOS, Linux,
  Windows, Android).
- **Schema definition** — loading a GraphQL schema file (SDL) and the `ResultBuilder`-based DSL
  for declaring queries, mutations, and response shapes in Swift.
- **Data generation** — the pluggable generator system for names, emails, phone numbers, and
  other realistic content.
- **State model** — how in-memory state is stored, updated by mutation closures, and kept
  consistent across resolutions.
- **Seeding** — loading initial state from JSON/YAML files, inline strings, or result-builder
  initializers.
- **Subscriptions** — hooks for publishing subscription events from test code.
