/// A record of how one list- or connection-typed field was narrowed during execution.
///
/// Emitted only when diagnostics are enabled (see ``MockQLEngine/init(schema:seed:generators:serverSeed:diagnostics:store:configuration:)``)
/// and surfaced under `extensions.mockql.fields` so it can be read from any client, on any
/// platform, without a logging backend in the portable core.
public struct FieldDiagnostics: Sendable, Hashable {
    /// Arguments applied as equality filters by the argument-name convention.
    public var filteredBy: [String] = []
    /// Arguments that were present but applied no filter — pagination aside.
    ///
    /// The high-value half: an argument here that the caller *expected* to filter means it does
    /// not name a scalar field on the node type. That is almost always a typo or a schema drift,
    /// and it otherwise fails completely silently by returning everything.
    public var ignoredArguments: [String] = []
    /// Whether a custom ``Filter`` replaced the convention for this field.
    public var customFilter = false
    /// Whether a ``Resolve`` hook produced the value, bypassing filtering entirely.
    public var customResolver = false
    /// Candidate nodes before filtering.
    public var seeded = 0
    /// Nodes surviving the filter.
    public var returned = 0

    /// The diagnostics as a value tree, for `extensions`.
    var responseValue: GraphQLValue {
        var fields: [String: GraphQLValue] = [
            "seeded": .int(seeded),
            "returned": .int(returned),
        ]
        if !filteredBy.isEmpty {
            fields["filteredBy"] = .list(filteredBy.sorted().map(GraphQLValue.string))
        }
        if !ignoredArguments.isEmpty {
            fields["ignoredArguments"] = .list(ignoredArguments.sorted().map(GraphQLValue.string))
        }
        if customFilter {
            fields["customFilter"] = .bool(true)
        }
        if customResolver {
            fields["customResolver"] = .bool(true)
        }
        return .object(fields)
    }
}

extension [String: FieldDiagnostics] {
    /// The `extensions` payload for a set of per-field diagnostics, or `nil` when empty.
    var mockQLExtensions: GraphQLValue? {
        guard !isEmpty else { return nil }
        let fields = mapValues(\.responseValue)
        return .object(["mockql": .object(["fields": .object(fields)])])
    }
}
