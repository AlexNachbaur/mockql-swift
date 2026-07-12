# Mutations and State

Handle mutations with plain Swift closures over transactional server state.

## The handler contract

A ``Mutation`` declaration registers a ``MutationHandler`` for a mutation field. The closure
receives the operation's input — arguments coerced against the schema, defaults applied — and
an `inout` ``MutationState``:

```swift
Mutation("addToCart") { input, state in
    let item = state.insert("CartItem", [
        "product": .reference("Product", id: input["productId"]),
        "quantity": input["quantity"] ?? 1,
    ])
    state.update("Cart", id: "cart-1") { cart in
        cart["items"].append(item)
    }
    return state["Cart", id: "cart-1"]
}
```

Handlers are synchronous and transactional: all writes commit atomically when the handler
returns, and a thrown error discards every write and surfaces as a GraphQL field error. Throw a
``GraphQLError`` to control the message the client sees.

The returned value resolves against the mutation field's selection set using post-mutation
state — return a record (or a `.reference` to one) and nested selections dereference through
the store, generating any unseeded fields.

## Working with MutationState

``MutationState`` is a value-semantics view of the whole store:

- `state["Cart", id: "cart-1"]` reads a record (missing records read as `.null`).
- `state.update(_:id:_:)` mutates a record in place.
- `state.insert(_:_:)` adds a record, generating an id if none is provided, and returns it.
- `state.delete(_:id:)` removes one.
- `state.records(ofType:)` / `state.ids(ofType:)` enumerate in insertion order.
- `state.root(_:)` / `state.setRoot(_:to:)` read and rewire root `Query` fields.

One sharp edge: because `state` is `inout`, don't call `state.insert` *inside* a
`state.update` closure — Swift's exclusivity checking forbids overlapping access. Insert first,
then update (as in the example above).

## Values and references

Everything flows through ``GraphQLValue``, which supports literals, chaining subscripts, an
`append` that starts lists from `.null`, and a `??` operator so `input["quantity"] ?? 1` works
on the non-optional subscript. `.reference(_:id:)` creates links to stored records — including
the overload taking a dynamic id straight from input.

## Execution semantics

- Root mutation fields execute **serially** in document order, per the GraphQL spec; the second
  field sees the first field's writes.
- Fields with an `id` argument act as lookups during queries: `product(id: "p1")` resolves the
  stored `Product` with that id, or null when none exists.
- A mutation field with no registered handler produces a field error that names the fix:
  `No handler registered for mutation 'addToCart'; register one with Mutation("addToCart") { … }`.

## Inspecting state from tests

``StateStore`` is accessible on the engine for direct assertions:

```swift
let cart = await engine.store.record(type: "Cart", id: "cart-1")
#expect(cart?["items"].count == 1)
```
