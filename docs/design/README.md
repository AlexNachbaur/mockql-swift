# MockQL Design Documents

Architecture and design documents for MockQL live here. Each document should cover one area of
the system and record the decisions made, the alternatives considered, and why.

Current documents:

- [architecture.md](architecture.md) — module layout, dependency policy, execution model, and
  the decision log.
- [seed-format.md](seed-format.md) — the v1 seed document specification (`version`/`data`/`roots`,
  schema-driven references, coercion, validation).

Everything else has shipped, and is documented where its users look for it — in the DocC
catalogs — rather than in a design document of its own:

| Area | Where it is documented |
|---|---|
| Server & transport | `Sources/MockQL/MockQL.docc` — `GettingStarted`, `XCUITestIntegration`, `YourFirstMockedTest` |
| Schema definition (SDL and the result-builder DSL) | `Sources/MockQLCore/MockQLCore.docc/DefiningSchemas.md` |
| Data generation | `Sources/MockQLCore/MockQLCore.docc/GeneratingData.md` |
| State model and mutations | `Sources/MockQLCore/MockQLCore.docc/MutationsAndState.md` |
| Seeding | `Sources/MockQLCore/MockQLCore.docc/SeedingData.md`, with the format itself in [seed-format.md](seed-format.md) |
| Filtering, resolvers, and query diagnostics | `Sources/MockQLCore/MockQLCore.docc/FilteringAndResolving.md` |
| Subscriptions | `Sources/MockQLCore/MockQLCore.docc/WorkingWithSubscriptions.md` |

Add a document here when a decision needs its alternatives and reasoning recorded — not to
restate how a shipped feature is used.
