# Seed Document Format (v1)

Status: **accepted** · Last updated: 2026-07-12

Seed documents bootstrap MockQL's in-memory state. They are plain YAML or JSON, loadable from a
file, an inline string, or built with result builders (which produce the same model).

## Document structure

```yaml
version: 1          # required; the seed-format version

data:               # records, grouped by GraphQL object type name
  Product:
    - id: product-1
      name: Espresso Machine
      priceCents: 64900
  User:
    - id: user-1
      name: Avery Quinn
      email: avery@example.com
  Cart:
    - id: cart-1
      owner: user-1          # Cart.owner is typed `User` → resolved as a reference
      items: []

roots:              # wires root Query fields to stored records
  currentUser: user-1
  cart: cart-1
  products: [product-1, product-2]
  featured: Product:product-1   # qualified form
```

`version`, `data`, and `roots` are the only top-level keys. Unknown top-level keys are an error.
The sectioned layout is deliberate: type names live under `data`, so a schema type named `query`
or `version` can never collide with document structure, and `version` gives the format room to
evolve without silently misreading old fixtures.

## Records and identity

- Each entry under `data.<TypeName>` is one stored record. `<TypeName>` must be an object type in
  the schema.
- `id` is the record's address within its type. Duplicate ids within a type are an error.
- Records without an `id` field in the schema cannot be referenced, only embedded (see below).
- The identity key is `id` in v1, but the store is built around per-type key paths so Federation
  `@key`-style custom keys (e.g. `Product` keyed by `sku`) can be configured later without a
  format break.

## Reference resolution (schema-driven)

Whether a value is a reference or a literal is decided by the **schema**, never by string shape:

| Field's schema type | Seed value | Meaning |
|---|---|---|
| Scalar (`String`, `ID`, …) | `"user-1"` | Literal string, always |
| Object type (`User`) | `"user-1"` | Reference to `User` with id `user-1` |
| Object type | `User:user-1` | Qualified reference (accepted anywhere) |
| Interface / union | `User:user-1` | Qualified reference — **required**, since the id alone cannot pick the concrete type |
| Interface / union | `"user-1"` | Error, with a fix-it suggesting the qualified form |
| Any object-typed position | nested map | Anonymous embedded record (see below) |

References may form cycles and may be forward references — resolution happens after the whole
document is parsed.

## Embedded (anonymous) records

Value-like types (`Money`, `Address`, …) rarely deserve top-level entries. A nested map in an
object-typed position is stored as an anonymous record of the field's type (or, if the type
declares an `id` and the map provides one, a normal addressable record):

```yaml
data:
  Product:
    - id: product-1
      price: { amountCents: 64900, currency: USD }
```

## Omitted fields, generators, and explicit null

- A field omitted from a record is filled on first access by the configured generator for
  `Type.field` (or a type-appropriate default), and the value is **stable** for the lifetime of
  the server.
- `field: null` pins an explicit null. It is an error on a non-null field.
- Non-null object-typed fields with no seed value and no generator capable of producing them are
  a load-time error, not a mid-test surprise.

## Coercion rules

Follow GraphQL spec semantics:

- Numeric YAML/JSON values coerce to `ID` strings (`id: 42` → `"42"`).
- `Int`/`Float`/`Boolean` validate strictly (no string-to-number guessing).
- Enum values must be members of the schema enum; case-sensitive.
- Custom scalars (`DateTime`, `JSON`, …) pass through as authored.

## Roots

`roots` maps fields of the schema's root `Query` type to stored records:

- Object-typed root fields take a reference (plain or qualified, same rules as above).
- List-typed root fields take a list of references.
- **Connection synthesis**: if the root (or any) field is a Relay-style Connection type
  (`PostConnection` with `edges { node }` / `pageInfo`), a plain id list is auto-wrapped into the
  connection shape, and `first`/`after` arguments paginate over the seeded order.
- Root fields not listed in `roots` fall back to generated data on first access.

## Validation (fail fast)

The entire document is validated against the schema at load time, before the server starts.
Errors carry the source name plus a document path (`data.User[0].email`) and include "did you
mean" suggestions where a near-miss exists. (YAML line/column positions are a planned
improvement over document paths.) At minimum, these are load-time errors:

- unknown top-level key; missing/unsupported `version`
- unknown type name under `data`; unknown field on a record; unknown root field
- duplicate `id` within a type; dangling reference; unqualified reference in a polymorphic position
- enum value not in the schema; value not coercible to the declared scalar
- explicit `null` for a non-null field

## Recorded-response seeding (roadmap)

A future seed source accepts a captured GraphQL response (`{"data": {...}}`) and normalizes it
into records, Apollo-cache-style, to make migration from JSON-stub fixtures nearly free.
