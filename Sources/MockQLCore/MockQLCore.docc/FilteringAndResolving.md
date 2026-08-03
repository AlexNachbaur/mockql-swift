# Filtering and Resolving

Scope list and connection fields by their arguments — by convention, or with a custom hook.

## The argument-name convention

Many schemas expose a parent-scoped list or connection: `comments(postId:)`, `orders(customerId:)`,
`tasks(projectId:)`. MockQL resolves these from a flat seed with no configuration: a list- or
connection-typed field's seeded nodes are filtered by **any argument whose name matches a scalar
(or enum) field on the node type**, keeping nodes whose value for that field equals the argument.

Given `comments(postId: ID, first: Int, after: String): CommentConnection!` and a `Comment` with a
scalar `postId`:

```graphql
{ comments(postId: "p1") { edges { node { id } } } }
```

returns only the comments whose `postId` is `"p1"`. Pagination arguments (`first`, `last`, `before`,
`after`) are never treated as filters, and arguments that don't name a scalar node field are
ignored — so `comments(first: 2)` paginates without filtering. Filtering runs before connection
pagination, and applies equally to plain object lists (`tags(kind:): [Tag!]!`).

### Null arguments do not filter

An argument whose value is `null` — whether written literally or supplied by a null variable — is
**ignored**, exactly as an omitted argument is. This matches how real GraphQL servers read an unset
optional filter, and it matters because generated clients rely on it: Apollo iOS compiles

```graphql
query Tags($group: String) { tags(group: $group) { id } }
```

into a request carrying `"group": null` whether or not the caller set the variable. Treating that
as an equality filter against null would return an empty list for the most ordinary query a real
app can send.

To match nodes whose field *is* null, say so explicitly with a ``Filter`` — see below.

Node references are dereferenced against the store to read their field values, so both reference
lists (`comments: [c1, c2, c3]` in `roots:`) and inline nested objects filter correctly.

## Custom filters

When an argument doesn't map to a node field by equality — a range, a substring, a computed match —
declare a ``Filter`` for the `"Type.field"`. It replaces the convention for that field and receives
each candidate node (references already dereferenced) plus the coerced arguments:

```swift
let engine = try await MockQLEngine(schema: .sdl(sdl), seed: .yaml(seed)) {
    Filter("Query.products") { node, args in
        (node["price"].doubleValue ?? 0) <= (args["maxPrice"].doubleValue ?? .infinity)
    }
}
```

The predicate runs before pagination, so `products(maxPrice: 30, first: 10)` filters, then paginates.

## Custom resolvers

When a field's value can't be expressed as "the seeded nodes, filtered" — search, aggregation, or a
cross-type join — declare a ``Resolve`` for the `"Type.field"`. It bypasses seeded-node lookup and
returns the value itself, given the coerced arguments and a read-only ``StoreView``:

```swift
Resolve("Query.search") { args, store in
    let term = args["term"].stringValue ?? ""
    return .list(store.records(of: "Article")
        .filter { $0["title"].stringValue?.localizedCaseInsensitiveContains(term) == true }
        .map { .reference("Article", id: $0["id"]) })
}
```

Return a list of node references to have MockQL synthesize the connection (edges/`pageInfo`,
honoring pagination arguments), or a fully-formed value. A resolver is **authoritative**: its output
is not post-filtered by the convention or a `Filter`, and declaring both a `Resolve` and a `Filter`
for the same field is a configuration error.

## Topics

### Declarations

- ``Filter``
- ``Resolve``
- ``FieldFilter``
- ``FieldResolver``
- ``StoreView``

## Diagnosing an unexpected result

Filtering is deliberately quiet: an argument that names no scalar node field is ignored, and a
filter that matches nothing returns an empty list. Both are correct, and both look identical to a
mis-seeded store from the client side.

Pass `diagnostics: true` and every list or connection field reports what happened, under
`extensions.mockql.fields`:

```swift
let engine = try await MockQLEngine(schema: .sdl(sdl), seed: .yaml(seed), diagnostics: true)
```

```json
{ "data": { "tags": [] },
  "extensions": { "mockql": { "fields": {
      "Query.tags": { "filteredBy": ["group"], "seeded": 3, "returned": 0 } } } } }
```

- `filteredBy` — arguments applied as equality filters.
- `ignoredArguments` — arguments present that filtered nothing. An argument you *expected* to
  filter appearing here means it does not name a singular scalar field on the node type: a typo,
  a list-typed field, or schema drift.
- `seeded` / `returned` — candidate nodes before and after filtering, which separates "the filter
  excluded everything" from "nothing was seeded".
- `customFilter` / `customResolver` — a ``Filter`` or ``Resolve`` hook took over for that field.
- `occurrences` — present when the field resolved more than once in the response (once per parent
  for a nested list, or once per alias). Counts are summed and argument names unioned across all
  of them, so the entry describes the whole query rather than one arbitrary occurrence.

Off by default, and scoped to the response rather than a log, so it works identically in-process,
over HTTP, and on platforms with no logging backend.
