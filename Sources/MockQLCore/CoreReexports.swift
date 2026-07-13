// MockQL is built on the MockCore platform: the value model, state store, generators, seeded
// RNG, seed primitives, and diagnostics all live there and are shared with sibling extensions
// like MockREST. Re-exporting keeps `import MockQLCore` the only import consumers need — and
// keeps every pre-extraction spelling (`StateStore`, `FieldGenerator`, `SeedSource`, …)
// compiling unchanged.
@_exported import MockCore

/// The dynamic value type MockQL is built on.
///
/// The type itself now lives in MockCore (as ``MockCore/MockValue``) so REST and GraphQL mocks
/// can share one state store; this alias preserves MockQL's original public spelling. Seed
/// documents, operation arguments, stored records, and response payloads are all
/// `GraphQLValue` trees.
public typealias GraphQLValue = MockValue

/// The load-time validation error type MockQL throws for schema, seed, operation-syntax, and
/// configuration problems.
///
/// The type itself now lives in MockCore (as ``MockCore/MockError``), shared by every protocol
/// extension; this alias preserves MockQL's original public spelling.
public typealias MockQLError = MockError
