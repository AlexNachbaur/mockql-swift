# Generating Data

Fill unseeded fields with realistic, deterministic values.

## How generation works

Any field a query selects that has no seeded value is filled by a ``FieldGenerator``. The value
is a pure function of the server seed, the type name, the record id, and the field name — so it
is **stable** for the lifetime of a server, and **reproducible** across runs when you pass the
same `serverSeed`. Asserting on generated values in tests is safe.

Resolution order for a field:

1. An explicit binding for `"Type.field"`.
2. Field-name inference: `email`-ish names get emails, `phone` gets phone numbers, `url`/`link`
   get URLs, `firstName`/`lastName`/`name`/`title` get names, `description`/`bio` get
   sentences, and date-like names (or scalar types like `DateTime`) get ISO-8601 timestamps.
3. A type-appropriate default: UUIDs for `ID`, ranged ints/floats, booleans, sentences for
   `String`, a stable member for enums.

## Binding generators

Bind by dictionary at engine/server creation, with ``Generate`` declarations, or with
generator-taking ``Field`` declarations in the DSL:

```swift
generators: [
    "User.name": .fullName,
    "User.email": .email,
    "User.phone": .phoneNumberE164,
    "Product.priceCents": .int(in: 100...99900),
]
```

Bindings are validated against the schema — a typo in a type or field name fails at startup
with a suggestion.

## Built-in generators

| Generator | Example output |
| --- | --- |
| ``FieldGenerator/uuid`` | `f3b4a9c2-…` (version-4 layout) |
| ``FieldGenerator/fullName`` / ``FieldGenerator/firstName`` / ``FieldGenerator/lastName`` | `Avery Chen` |
| ``FieldGenerator/email`` | `avery.chen@example.com` (reserved example domains) |
| ``FieldGenerator/phoneNumber`` | `+1 (212) 555-0147` (fictional 555-01xx range) |
| ``FieldGenerator/phoneNumberE164`` | `+12125550147` (strict E.164, no separators) |
| ``FieldGenerator/url`` / ``FieldGenerator/username`` | `https://example.com/amber`, `amber_vale42` |
| ``FieldGenerator/sentence`` | short lorem-style text |
| ``FieldGenerator/dateTime`` | `2025-11-03T08:41:27Z` (fixed deterministic range) |
| ``FieldGenerator/bool`` / ``FieldGenerator/int(in:)`` / ``FieldGenerator/double(in:)`` | primitives, optionally ranged |
| ``FieldGenerator/constant(_:)`` / ``FieldGenerator/oneOf(_:)`` | pinned or picked values |

## Custom generators

``FieldGenerator/custom(scalarTypeName:_:)`` takes a closure over a ``GeneratorContext``, which
carries the type/field/record being generated and a pre-seeded ``RandomSource``. Draw all
randomness from that source to keep determinism:

```swift
Generate("Product.sku", .custom { context in
    .string("SKU-\(Int.random(in: 10000...99999, using: &context.random))")
})
```

## Ghost records

When a query reaches an object-typed field with no seeded value (and no `id` argument to look
up), MockQL resolves it as a *ghost record*: an unseeded object whose fields generate on demand
under a stable synthetic identity, so repeated queries see identical data.
