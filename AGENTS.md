# AGENTS.md

Instructions for AI coding agents working **in this repository**. If you are integrating MockQL
into another project, read [docs/agents/integration-guide.md](docs/agents/integration-guide.md)
instead.

## Build, test, lint

```sh
swift build
swift test
swift format lint --strict --recursive Sources Tests Package.swift
swift package generate-documentation --target MockQLCore --target MockQL   # docs must build clean
```

All four must pass before any commit. CI additionally runs the test suite on Linux
(`swift:6.1` container) and on an Android emulator; do not introduce Apple-only framework
imports in library targets.

## Architecture (settled decisions — do not relitigate)

- Two modules: `MockQLCore` (portable engine — **never import NIO here**) and `MockQL`
  (SwiftNIO HTTP + `graphql-transport-ws` transport; re-exports core).
- The GraphQL SDL/operation parser is hand-written on purpose: diagnostic quality is a product
  feature. Every user-facing error carries a source location or document path and, where a typo
  is plausible, a "did you mean" suggestion. Never regress an error message.
- Seed format v1 is specified in [docs/design/seed-format.md](docs/design/seed-format.md);
  architecture in [docs/design/architecture.md](docs/design/architecture.md).
- Dependencies are fixed: SwiftNIO, Yams, swift-docc-plugin (build-time). Adding any other
  dependency requires asking the maintainer first.

## Code style (enforced)

- swift-format with the checked-in `.swift-format`: 120 columns, 4-space indent.
- No force unwraps anywhere (tests use `try #require(...)`); no `DispatchQueue` — Swift
  concurrency only; prefer value types.
- Never use caseless enums as namespaces; use structs with static members.
- Swift Testing (`import Testing`) for all tests, never XCTest.
- Every public symbol gets a doc comment; DocC must build with zero warnings.

## Testing rules

- Everything requires unit tests (`Tests/MockQLCoreTests`, `Tests/MockQLTests`).
- Full-stack behavior belongs in `Tests/MockQLIntegrationTests` (real HTTP/WebSocket round
  trips against the bundled fixtures in `Tests/MockQLIntegrationTests/Fixtures/`).
- Update `CHANGELOG.md` (Unreleased section) for user-visible changes.
