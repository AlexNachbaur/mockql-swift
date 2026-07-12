# Seeding Data

Bootstrap server state from YAML or JSON documents — or build seeds in Swift.

## The seed document

Seed documents have three top-level sections. `data` groups records by GraphQL object type;
`roots` wires the schema's root `Query` fields to stored records:

```yaml
version: 1

data:
  Product:
    - id: product-1
      name: Espresso Machine
      priceCents: 64900
      price: { amountCents: 64900, currency: USD }   # embedded value object
  User:
    - { id: user-1, name: Avery Quinn, email: avery@example.com }
  Cart:
    - { id: cart-1, owner: user-1, items: [] }

roots:
  currentUser: user-1
  cart: cart-1
  products: [product-1]
  featured: Product:product-1   # qualified reference for a union/interface position
```

Load it from a file, an inline string, or JSON — all through ``SeedSource``:

```swift
seed: .file("Fixtures/checkout.yaml")
seed: .yaml("version: 1\ndata: …")
seed: .json(#"{"version": 1, "data": {…}}"#)
```

## References are schema-driven

Whether a value is a reference or a literal is decided by the schema, never by string shape.
`owner: user-1` is a reference because `Cart.owner` is typed `User`; the same string in a
`String`-typed field is just text. For interface- or union-typed positions, qualify the
reference as `Type:id` so the concrete type is known. References may be forward and may form
cycles; resolution happens after the whole document is parsed.

## What you can rely on

- **Everything validates before the server starts.** Unknown types and fields (with "did you
  mean" suggestions), duplicate ids, dangling references, enum mismatches, and non-coercible
  scalars are load-time errors pointing at a document path like `data.User[0].email`.
- **Coercion follows the GraphQL spec.** `id: 42` coerces to the ID string `"42"`; ints coerce
  to `Float` fields; enums are validated against their members; custom scalars pass through
  as authored.
- **Omitted fields generate.** Any field absent from a record is filled by its generator on
  demand and stays stable for the server's lifetime — see <doc:GeneratingData>. Write
  `field: null` to pin an explicit null (only legal on nullable fields).
- **Connections synthesize.** A plain id list in a Relay-connection-typed position becomes a
  full `edges`/`node`/`pageInfo` structure, with `first`/`after` pagination handled for you.
- **Single values wrap.** A lone value in a list-typed position becomes a one-element list,
  matching GraphQL input coercion.

## Seeding from Swift

``Seed``, ``Value``, and ``Root`` declarations are the third seed source. They layer on top of
an external seed document — references can point across layers, and the combined result is
validated as one world:

```swift
let engine = try await MockQLEngine(
    schema: .file("Schemas/shop.graphqls"),
    seed: .file("Fixtures/base.yaml")
) {
    Seed("Product", id: "sale-1") {
        Value("name", "Flash Sale Item")
        Value("priceCents", 100)
    }
    Root("products", ["product-1", "sale-1"])
}
```

The full format specification lives in the repository at `docs/design/seed-format.md`.
