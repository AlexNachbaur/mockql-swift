# Contributing to MockQL

Thanks for your interest in contributing! MockQL is young and moving quickly, so this guide is
short — when in doubt, open an issue and ask.

## Getting started

1. Install a **Swift 6.1** toolchain — Xcode 16.4+ on macOS, a [swift.org](https://swift.org/install/)
   toolchain on Linux or Windows, or the `swift:6.1` Docker image (which is what CI uses).
2. Fork and clone the repository.
3. Build and test from the command line:

   ```sh
   swift build
   swift test
   ```

   On macOS you can also open `Package.swift` in Xcode 16.4 or later.

There are no external dependencies beyond the toolchain.

## Reporting bugs and requesting features

- Search [existing issues](https://github.com/AlexNachbaur/mockql-swift/issues) first.
- Use the issue templates — a minimal reproduction (the GraphQL operation, the MockQL
  configuration, and the observed vs. expected response) makes bugs dramatically faster to fix.
- For anything security-sensitive, **do not open a public issue** — see [SECURITY.md](SECURITY.md).

## Code style

Formatting is enforced by `swift-format` using the checked-in [.swift-format](.swift-format)
configuration. CI will fail on lint violations, so run this before pushing:

```sh
swift format lint --strict --recursive Sources Tests Package.swift
```

Beyond formatting, the project follows these rules:

- **120-character line length, 4-space indentation.**
- **No force unwraps** (`!`) in production code.
- **No `DispatchQueue`** — use Swift concurrency (`async`/`await`, actors, structured tasks).
- **Prefer value types** (structs, enums with cases) over reference types.
- **Never use caseless enums as namespaces.** Enums are for enumerated values only. For
  singletons or groupings of static members, use a `struct` with static properties or a
  `final class` with `static let shared`.
- **Stay cross-platform.** MockQL supports macOS, iOS, Linux, and Android (with Windows
  planned). Don't import Apple-only frameworks in the library targets, and stick to Foundation
  APIs available in swift-corelibs-foundation. CI builds and tests on macOS, Linux, and an
  Android emulator, and must pass on all three.

## Pull requests

- Branch from `main`; keep PRs focused on a single change.
- Add or update tests for any behavioral change.
- Update documentation (README, `docs/design/`, doc comments) when the public API changes.
- Note user-visible changes under the **Unreleased** heading in [CHANGELOG.md](CHANGELOG.md).
- Make sure `swift build`, `swift test`, and the lint command above all pass locally.

While the project is pre-1.0, the public API may change without deprecation cycles, but each
breaking change should be called out in the changelog.

## Design discussions

Larger changes (new DSL surface, state-model changes, transport work) should start as an issue
describing the problem and the proposed approach before any code is written. Design documents
live in [docs/design/](docs/design/).

## Code of conduct

All participation in this project is governed by the
[Code of Conduct](CODE_OF_CONDUCT.md).
