# Defining Schemas

Load a standard SDL file, or declare the schema in Swift with result builders.

## From an SDL file

Point ``SchemaSource/file(_:)`` at the same `.graphqls` file your app or backend uses. MockQL
parses the full type-system language — objects, interfaces, unions, enums, input types, custom
scalars, descriptions, and `schema { … }` root definitions — and validates every type reference
before the server starts:

```swift
let engine = try await MockQLEngine(schema: .file("Schemas/app.graphqls"))
```

Inline SDL works the same way with ``SchemaSource/sdl(_:)``, which is handy in unit tests.

Parse and validation errors carry the file, line, and column, plus a suggestion when a typo is
plausible:

```
app.graphqls:12:5: Field 'Query.user' has unknown type 'Usr'. Did you mean 'User'?
```

Custom directive definitions and applications (`@deprecated`, Federation's `@key`, …) are
accepted so real-world schema files load unchanged; MockQL does not act on them.

## From the DSL

Without an SDL file, ``Query``, ``Object``, and ``Field`` declarations *define* the schema:

```swift
let engine = try await MockQLEngine {
    Query("currentUser") {
        Object("User") {
            Field("id", .uuid)
            Field("name", .fullName)
            Field("email", .email)
            Field("age", type: "Int")
            Field("address", Object("Address") {
                Field("city", .fullName)
            })
        }
    }
    Mutation("updateDisplayName", returning: "User") { input, state in
        state.update("User", id: "user-1") { $0["name"] = input["name"] }
        return state["User", id: "user-1"]
    }
}
```

The rules in DSL (standalone) mode:

- A ``Field`` created with a generator gets that generator's scalar type (non-null) and the
  generator is bound automatically.
- `Field(_:type:)` takes any SDL type expression — `"Int!"`, `"[String!]"`, `"DateTime"`.
- Object types get an implicit `id: ID!` field when you don't declare one, so records are
  seedable and referenceable.
- A ``Mutation`` or ``Subscription`` without `returning:` resolves its result *structurally*:
  whatever object the handler returns is matched directly against the selection set.
- The declarations are compiled to SDL internally and run through the same parser and
  validation as a schema file.

## Mixing an SDL schema with declarations

When a schema source *is* provided, the configuration block configures rather than defines:
``Mutation`` handlers must match existing mutation fields, ``Object`` blocks may only bind
generators to existing fields, and shape-defining declarations are rejected — with suggestions
when a name is close:

```
Schema has no mutation field 'addToCrat' on 'Mutation'. Did you mean 'addToCart'?
```
