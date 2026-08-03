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
    /// Candidate nodes before filtering, summed across every occurrence.
    public var seeded = 0
    /// Nodes surviving the filter, summed across every occurrence.
    public var returned = 0
    /// How many times this field was resolved in the response.
    ///
    /// A field keyed `"Type.field"` can resolve many times in one query — `Post.comments` once
    /// per post, or the same field under two aliases with different arguments. Counts are summed
    /// and argument lists unioned across all of them, so a reader is never shown one arbitrary
    /// occurrence dressed up as the whole picture.
    public var occurrences = 0

    /// The diagnostics as a value tree, for `extensions`.
    var responseValue: GraphQLValue {
        var fields: [String: GraphQLValue] = [
            "seeded": .int(seeded),
            "returned": .int(returned),
        ]
        // Only worth saying when it changes how the numbers should be read.
        if occurrences > 1 {
            fields["occurrences"] = .int(occurrences)
        }
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

extension FieldDiagnostics {
    /// Folds another occurrence of the same field into this one.
    mutating func merge(_ other: FieldDiagnostics) {
        seeded += other.seeded
        returned += other.returned
        occurrences += other.occurrences
        filteredBy = Array(Set(filteredBy).union(other.filteredBy))
        ignoredArguments = Array(Set(ignoredArguments).union(other.ignoredArguments))
        customFilter = customFilter || other.customFilter
        customResolver = customResolver || other.customResolver
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
