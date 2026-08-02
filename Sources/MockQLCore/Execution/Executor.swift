/// Resolves one operation's selection sets against an immutable store snapshot.
///
/// Implements the GraphQL execution semantics MockQL needs: field collection with fragments and
/// `@skip`/`@include`, argument and variable coercion, reference dereferencing, deterministic
/// generation of missing values, Relay connection synthesis, and non-null error bubbling.
struct Executor {
    let schema: Schema
    let generators: GeneratorRegistry
    let data: StoreData
    let fragments: [String: FragmentDefinitionNode]
    let variables: [String: GraphQLValue]
    /// Custom connection/list filters, keyed `"Type.field"` (overrides the argument-name
    /// convention for that field).
    let filters: [String: FieldFilter]
    /// Custom field resolvers, keyed `"Type.field"` (bypasses seeded-node lookup for that field).
    let resolvers: [String: FieldResolver]
    private(set) var errors: [GraphQLError] = []
    /// Whether to record per-field filtering diagnostics. Off by default — the cost is small
    /// but the output is noise unless someone is asking "why is this list empty?".
    let diagnosticsEnabled: Bool
    /// Per-field filtering diagnostics, keyed `"Type.field"`. Empty unless enabled.
    private(set) var diagnostics: [String: FieldDiagnostics] = [:]

    /// Connection pagination arguments — never treated as node-field filters.
    private static let paginationArguments: Set<String> = ["first", "last", "before", "after"]

    /// Thrown when a non-null position resolves to null; caught at the nearest nullable ancestor.
    private struct NullViolation: Error {}

    init(
        schema: Schema,
        generators: GeneratorRegistry,
        data: StoreData,
        fragments: [String: FragmentDefinitionNode],
        variables: [String: GraphQLValue],
        filters: [String: FieldFilter] = [:],
        resolvers: [String: FieldResolver] = [:],
        diagnosticsEnabled: Bool = false
    ) {
        self.diagnosticsEnabled = diagnosticsEnabled
        self.schema = schema
        self.generators = generators
        self.data = data
        self.fragments = fragments
        self.variables = variables
        self.filters = filters
        self.resolvers = resolvers
    }

    // MARK: - Entry points

    /// Resolves a query's root selection set. Root field values come from the store's roots.
    mutating func executeQuery(selections: [SelectionNode]) -> GraphQLValue {
        let source = ResolutionSource(
            typeName: schema.queryTypeName,
            fields: data.roots,
            recordID: "root",
            isRoot: true
        )
        do {
            return .object(try resolveSelectionSet(selections, on: source, path: []))
        } catch {
            return .null
        }
    }

    /// Resolves one root field's selections against an already-computed value (a mutation
    /// handler's result or a subscription payload).
    mutating func resolveValue(
        _ value: GraphQLValue,
        ofType type: TypeReference,
        selections: [SelectionNode],
        fieldName: String,
        path: [GraphQLPathSegment]
    ) -> GraphQLValue {
        do {
            return try complete(
                raw: value,
                type: type,
                fieldName: fieldName,
                parent: ResolutionSource(typeName: schema.queryTypeName, fields: [:], recordID: "root", isRoot: true),
                arguments: .object([:]),
                selections: selections,
                path: path
            )
        } catch {
            return .null
        }
    }

    // MARK: - Selection sets

    /// The object value a selection set is being resolved against.
    private struct ResolutionSource {
        let typeName: String
        let fields: [String: GraphQLValue]
        let recordID: String?
        var isRoot = false
    }

    private mutating func resolveSelectionSet(
        _ selections: [SelectionNode],
        on source: ResolutionSource,
        path: [GraphQLPathSegment]
    ) throws -> [String: GraphQLValue] {
        var result: [String: GraphQLValue] = [:]
        for (responseKey, fieldNodes) in try collectFields(selections, concreteTypeName: source.typeName) {
            let fieldPath = path + [.field(responseKey)]
            result[responseKey] = try resolveField(fieldNodes, on: source, path: fieldPath)
        }
        return result
    }

    /// Collects the fields to resolve for a concrete type, expanding fragments and honoring
    /// `@skip`/`@include`. Duplicate response keys merge their sub-selections, per the spec.
    private mutating func collectFields(
        _ selections: [SelectionNode],
        concreteTypeName: String,
        visitedFragments: Set<String> = []
    ) throws -> [(key: String, nodes: [FieldNode])] {
        var order: [String] = []
        var grouped: [String: [FieldNode]] = [:]
        for selection in selections {
            switch selection {
            case .field(let field):
                guard try includeSelection(field.directives) else { continue }
                if grouped[field.responseKey] == nil {
                    order.append(field.responseKey)
                }
                grouped[field.responseKey, default: []].append(field)
            case .inlineFragment(let typeCondition, let directives, let selectionSet, _):
                guard try includeSelection(directives) else { continue }
                guard typeConditionMatches(typeCondition, concreteTypeName: concreteTypeName) else { continue }
                try mergeCollected(
                    collectFields(selectionSet, concreteTypeName: concreteTypeName, visitedFragments: visitedFragments),
                    into: &order,
                    grouped: &grouped
                )
            case .fragmentSpread(let name, let directives, let location):
                guard try includeSelection(directives) else { continue }
                guard !visitedFragments.contains(name) else { continue }
                guard let fragment = fragments[name] else {
                    throw requestError(
                        "Unknown fragment '\(name)'.\(Suggestion.clause(for: name, in: fragments.keys))",
                        at: location
                    )
                }
                guard typeConditionMatches(fragment.typeCondition, concreteTypeName: concreteTypeName) else {
                    continue
                }
                try mergeCollected(
                    collectFields(
                        fragment.selectionSet,
                        concreteTypeName: concreteTypeName,
                        visitedFragments: visitedFragments.union([name])
                    ),
                    into: &order,
                    grouped: &grouped
                )
            }
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    private func mergeCollected(
        _ collected: [(key: String, nodes: [FieldNode])],
        into order: inout [String],
        grouped: inout [String: [FieldNode]]
    ) throws {
        for (key, nodes) in collected {
            if grouped[key] == nil {
                order.append(key)
            }
            grouped[key, default: []].append(contentsOf: nodes)
        }
    }

    private func typeConditionMatches(_ condition: String?, concreteTypeName: String) -> Bool {
        guard let condition else { return true }
        if condition == concreteTypeName { return true }
        return schema.possibleTypeNames(for: condition).contains(concreteTypeName)
    }

    private mutating func includeSelection(_ directives: [DirectiveNode]) throws -> Bool {
        for directive in directives {
            guard directive.name == "skip" || directive.name == "include" else { continue }
            guard let condition = directive.arguments["if"] else {
                throw requestError("@\(directive.name) requires an 'if' argument", at: directive.location)
            }
            let value = try resolveArgumentValue(condition, at: directive.location)
            guard let flag = value.boolValue else {
                throw requestError("@\(directive.name)(if:) must be a Boolean", at: directive.location)
            }
            if directive.name == "skip" && flag { return false }
            if directive.name == "include" && !flag { return false }
        }
        return true
    }

    // MARK: - Fields

    private mutating func resolveField(
        _ nodes: [FieldNode],
        on source: ResolutionSource,
        path: [GraphQLPathSegment]
    ) throws -> GraphQLValue {
        guard let primary = nodes.first else { return .null }
        if primary.name == "__typename" {
            return .string(source.typeName)
        }
        guard let fieldDef = schema.field(primary.name, onType: source.typeName) else {
            let known = knownFieldNames(onType: source.typeName)
            errors.append(
                GraphQLError(
                    message: "Unknown field '\(primary.name)' on type "
                        + "'\(source.typeName)'.\(Suggestion.clause(for: primary.name, in: known))",
                    locations: [primary.location],
                    path: path
                )
            )
            return .null
        }
        let arguments: GraphQLValue
        do {
            arguments = try coerceArguments(fieldDef, nodes: primary.arguments, location: primary.location, path: path)
        } catch let error as GraphQLError {
            errors.append(error)
            return .null
        }
        // A registered Resolve hook fully produces the field value, bypassing seeded-node lookup.
        let raw: GraphQLValue?
        if let resolver = resolvers["\(source.typeName).\(primary.name)"] {
            raw = resolver(arguments, StoreView(data))
        } else {
            raw = source.fields[primary.name]
        }
        let selections = nodes.flatMap(\.selectionSet)
        do {
            return try complete(
                raw: raw,
                type: fieldDef.type,
                fieldName: primary.name,
                parent: source,
                arguments: arguments,
                selections: selections,
                path: path
            )
        } catch let violation as NullViolation {
            throw violation
        }
    }

    private func knownFieldNames(onType typeName: String) -> [String] {
        switch schema.type(named: typeName) {
        case .object(let type): return type.fields.map(\.name)
        case .interface(let type): return type.fields.map(\.name)
        default: return []
        }
    }

    // MARK: - Value completion

    private mutating func complete(
        raw: GraphQLValue?,
        type: TypeReference,
        fieldName: String,
        parent: ResolutionSource,
        arguments: GraphQLValue,
        selections: [SelectionNode],
        path: [GraphQLPathSegment]
    ) throws -> GraphQLValue {
        if case .nonNull(let inner) = type {
            let value = try complete(
                raw: raw,
                type: inner,
                fieldName: fieldName,
                parent: parent,
                arguments: arguments,
                selections: selections,
                path: path
            )
            if value.isNull {
                errors.append(
                    GraphQLError(
                        message: "Cannot return null for non-nullable field '\(parent.typeName).\(fieldName)'",
                        path: path,
                        extensions: ["code": .string("NULL_VIOLATION")]
                    )
                )
                throw NullViolation()
            }
            return value
        }
        do {
            return try completeNullable(
                raw: raw,
                type: type,
                fieldName: fieldName,
                parent: parent,
                arguments: arguments,
                selections: selections,
                path: path
            )
        } catch is NullViolation {
            // A non-null child failed; this nullable position absorbs the bubble.
            return .null
        }
    }

    private mutating func completeNullable(
        raw: GraphQLValue?,
        type: TypeReference,
        fieldName: String,
        parent: ResolutionSource,
        arguments: GraphQLValue,
        selections: [SelectionNode],
        path: [GraphQLPathSegment]
    ) throws -> GraphQLValue {
        guard let raw else {
            return try generateValue(
                type: type,
                fieldName: fieldName,
                parent: parent,
                arguments: arguments,
                selections: selections,
                path: path
            )
        }
        if raw.isNull {
            return .null
        }
        switch type {
        case .nonNull(let inner):
            return try complete(
                raw: raw,
                type: inner,
                fieldName: fieldName,
                parent: parent,
                arguments: arguments,
                selections: selections,
                path: path
            )
        case .list(let element):
            var elements = raw.listValue ?? [raw]
            // Composite-element lists (object, interface, or union) get the same custom Filter /
            // argument-name convention as connection nodes. The convention matches fields defined
            // on the element type — objects and interfaces; unions define no fields, so only a
            // custom Filter applies to them. Scalar/enum and nested-list elements are untouched.
            if let elementTypeName = compositeElementTypeName(element) {
                elements = filterNodes(
                    elements,
                    fieldKey: "\(parent.typeName).\(fieldName)",
                    nodeTypeName: elementTypeName,
                    arguments: arguments
                )
            }
            var completed: [GraphQLValue] = []
            completed.reserveCapacity(elements.count)
            for (index, item) in elements.enumerated() {
                completed.append(
                    try complete(
                        raw: item,
                        type: element,
                        fieldName: fieldName,
                        parent: parent,
                        arguments: arguments,
                        selections: selections,
                        path: path + [.index(index)]
                    )
                )
            }
            return .list(completed)
        case .named(let typeName):
            return try completeNamed(
                raw: raw,
                typeName: typeName,
                fieldName: fieldName,
                parent: parent,
                arguments: arguments,
                selections: selections,
                path: path
            )
        }
    }

    private mutating func completeNamed(
        raw: GraphQLValue,
        typeName: String,
        fieldName: String,
        parent: ResolutionSource,
        arguments: GraphQLValue,
        selections: [SelectionNode],
        path: [GraphQLPathSegment]
    ) throws -> GraphQLValue {
        if typeName == DSLAssembly.dynamicTypeName {
            return selections.isEmpty ? sanitized(raw) : try resolveDynamic(raw, selections: selections, path: path)
        }
        switch schema.type(named: typeName) {
        case .scalar, .enumType:
            return sanitized(raw)
        case .object, .interface, .union:
            // A list value in a connection-typed position is the seeded node list; synthesize.
            if let nodes = raw.listValue, let connection = schema.connectionInfo(for: typeName) {
                let filtered = filterNodes(
                    nodes,
                    fieldKey: "\(parent.typeName).\(fieldName)",
                    nodeTypeName: connection.nodeTypeName,
                    arguments: arguments
                )
                let synthesized = synthesizeConnection(nodes: filtered, info: connection, arguments: arguments)
                return try resolveObject(synthesized, concreteTypeName: typeName, selections: selections, path: path)
            }
            if let reference = raw.referenceValue {
                guard let record = data.record(type: reference.typeName, id: reference.id) else {
                    errors.append(
                        GraphQLError(
                            message: "Dangling reference: no '\(reference.typeName)' record with id "
                                + "'\(reference.id)' (was it deleted by a mutation?)",
                            path: path
                        )
                    )
                    return .null
                }
                return try resolveObject(
                    record, concreteTypeName: reference.typeName, selections: selections, path: path)
            }
            if raw.objectValue != nil {
                let concrete = raw["__typename"].stringValue ?? concreteFallback(for: typeName)
                return try resolveObject(raw, concreteTypeName: concrete, selections: selections, path: path)
            }
            errors.append(
                GraphQLError(
                    message: "Value of field '\(parent.typeName).\(fieldName)' is not an object "
                        + "(found \(raw))",
                    path: path
                )
            )
            return .null
        case .inputObject, .none:
            errors.append(GraphQLError(message: "Cannot resolve type '\(typeName)'", path: path))
            return .null
        }
    }

    private func concreteFallback(for typeName: String) -> String {
        if schema.objectType(named: typeName) != nil {
            return typeName
        }
        return schema.possibleTypeNames(for: typeName).first ?? typeName
    }

    private mutating func resolveObject(
        _ value: GraphQLValue,
        concreteTypeName: String,
        selections: [SelectionNode],
        path: [GraphQLPathSegment]
    ) throws -> GraphQLValue {
        guard !selections.isEmpty else {
            errors.append(
                GraphQLError(
                    message: "Field of object type '\(concreteTypeName)' must have a selection set",
                    path: path
                )
            )
            return .null
        }
        let source = ResolutionSource(
            typeName: concreteTypeName,
            fields: value.objectValue ?? [:],
            recordID: value["id"].stringValue
        )
        return .object(try resolveSelectionSet(selections, on: source, path: path))
    }

    // MARK: - Generation of missing values

    private mutating func generateValue(
        type: TypeReference,
        fieldName: String,
        parent: ResolutionSource,
        arguments: GraphQLValue,
        selections: [SelectionNode],
        path: [GraphQLPathSegment]
    ) throws -> GraphQLValue {
        switch type.nullable {
        case .nonNull:
            return .null
        case .list:
            return .list([])
        case .named(let typeName):
            if typeName == DSLAssembly.dynamicTypeName {
                return .null
            }
            switch schema.type(named: typeName) {
            case .scalar(let scalar):
                return generators.value(
                    typeName: parent.typeName,
                    recordID: parent.recordID,
                    field: fieldName,
                    scalarTypeName: scalar.name
                )
            case .enumType(let enumType):
                return generators.enumValue(
                    typeName: parent.typeName,
                    recordID: parent.recordID,
                    field: fieldName,
                    cases: enumType.values
                )
            case .object, .interface, .union:
                if let connection = schema.connectionInfo(for: typeName) {
                    let synthesized = synthesizeConnection(nodes: [], info: connection, arguments: arguments)
                    return try resolveObject(
                        synthesized,
                        concreteTypeName: typeName,
                        selections: selections,
                        path: path
                    )
                }
                // Fields taking an `id` argument are lookups: resolve the seeded record with
                // that id, or null when none exists — never a generated ghost.
                if let lookupID = arguments["id"].stringValue {
                    for candidate in schema.possibleTypeNames(for: typeName) {
                        if let record = data.record(type: candidate, id: lookupID) {
                            return try resolveObject(
                                record,
                                concreteTypeName: candidate,
                                selections: selections,
                                path: path
                            )
                        }
                    }
                    return .null
                }
                let concrete = concreteFallback(for: typeName)
                // A ghost record: no seeded fields, but a stable synthetic id so every field
                // generated beneath it stays consistent across reads.
                let ghostID = "\(parent.recordID ?? "root")/\(fieldName)"
                let source = ResolutionSource(typeName: concrete, fields: [:], recordID: ghostID)
                guard !selections.isEmpty else { return .null }
                return .object(try resolveSelectionSet(selections, on: source, path: path))
            case .inputObject, .none:
                return .null
            }
        }
    }

    // MARK: - Connection synthesis

    /// Filters a list- or connection-typed field's seeded nodes. A registered ``Filter`` for the
    /// field wins; otherwise the argument-name convention applies: keep nodes whose value for a
    /// scalar/enum field equals the same-named argument. Pagination arguments (`first`/`after`/…)
    /// and arguments that don't name a scalar node field are ignored. For connections this runs
    /// before pagination synthesis; for plain lists it filters the elements directly.
    private mutating func filterNodes(
        _ nodes: [GraphQLValue],
        fieldKey: String,
        nodeTypeName: String,
        arguments: GraphQLValue
    ) -> [GraphQLValue] {
        // A Resolve hook fully produces the field value, so neither the convention nor a Filter
        // post-filters its output.
        if resolvers[fieldKey] != nil {
            record(fieldKey: fieldKey, seeded: nodes.count, returned: nodes.count, customResolver: true)
            return nodes
        }
        if let predicate = filters[fieldKey] {
            let filtered = nodes.filter { node in
                // Preserve dangling references so the executor's dangling-reference error still
                // surfaces instead of being silently filtered away.
                guard let record = resolvedRecord(node) else { return true }
                return predicate(record, arguments)
            }
            record(fieldKey: fieldKey, seeded: nodes.count, returned: filtered.count, customFilter: true)
            return filtered
        }
        guard let argumentFields = arguments.objectValue else { return nodes }
        // A `null` argument means "no filter", matching how real GraphQL servers read an unset
        // optional filter.
        //
        // This is not merely a convenience: generated clients emit explicit nulls for every unset
        // optional variable. Apollo iOS compiles `query Q($status: Status) { things(status: $status) }`
        // into a request carrying `"status": null` whether or not the caller set it — so treating a
        // present null as an equality filter against null silently returned an EMPTY list for the
        // most ordinary query a real app can send, with nothing in the response to say why.
        //
        // Matching a null-valued field is still expressible, just not by accident: declare a
        // ``Filter`` for that field and compare explicitly.
        let fieldFilters = argumentFields.filter { name, value in
            !value.isNull && !Self.paginationArguments.contains(name) && isScalarField(name, onType: nodeTypeName)
        }
        guard !fieldFilters.isEmpty else {
            let ignored = nonFilteringArgumentNames(argumentFields, applied: [])
            record(fieldKey: fieldKey, seeded: nodes.count, returned: nodes.count, ignoredArguments: ignored)
            return nodes
        }
        let filtered = nodes.filter { node in
            guard let record = resolvedRecord(node) else { return true }
            return fieldFilters.allSatisfy { name, value in record[name] == value }
        }
        let applied = Set(fieldFilters.keys)
        let ignored = nonFilteringArgumentNames(argumentFields, applied: applied)
        record(
            fieldKey: fieldKey,
            seeded: nodes.count,
            returned: filtered.count,
            filteredBy: Array(applied),
            ignoredArguments: ignored
        )
        return filtered
    }

    /// Argument names that were present but applied no filter, excluding pagination.
    private func nonFilteringArgumentNames(
        _ argumentFields: [String: GraphQLValue],
        applied: Set<String>
    ) -> [String] {
        argumentFields.keys.filter { name in
            !applied.contains(name) && !Self.paginationArguments.contains(name)
        }
    }

    /// Records diagnostics for a field, when enabled.
    private mutating func record(
        fieldKey: String,
        seeded: Int,
        returned: Int,
        filteredBy: [String] = [],
        ignoredArguments: [String] = [],
        customFilter: Bool = false,
        customResolver: Bool = false
    ) {
        guard diagnosticsEnabled else { return }
        diagnostics[fieldKey] = FieldDiagnostics(
            filteredBy: filteredBy,
            ignoredArguments: ignoredArguments,
            customFilter: customFilter,
            customResolver: customResolver,
            seeded: seeded,
            returned: returned
        )
    }

    /// The record backing a node so filters can read its fields by name: an inline object as-is,
    /// or the stored record a reference points at. `nil` when the node is a *dangling* reference
    /// (no such record) — those are kept through filtering so the executor's dangling-reference
    /// error still surfaces rather than being silently dropped.
    private func resolvedRecord(_ node: GraphQLValue) -> GraphQLValue? {
        guard let reference = node.referenceValue else { return node }
        return data.record(type: reference.typeName, id: reference.id)
    }

    /// Whether `name` is a singular scalar- or enum-typed field on `typeName` — the fields the
    /// argument convention filters by equality. Object-typed fields, unknown names, and *list*
    /// fields (e.g. `[String]`, which an equality filter can't match against a scalar argument)
    /// are ignored.
    private func isScalarField(_ name: String, onType typeName: String) -> Bool {
        guard let field = schema.field(name, onType: typeName) else { return false }
        return isSingularScalarOrEnum(field.type)
    }

    /// Whether `type` is a scalar or enum, ignoring non-null wrappers but rejecting lists.
    private func isSingularScalarOrEnum(_ type: TypeReference) -> Bool {
        switch type {
        case .nonNull(let inner): return isSingularScalarOrEnum(inner)
        case .list: return false
        case .named(let name):
            switch schema.type(named: name) {
            case .scalar, .enumType: return true
            default: return false
            }
        }
    }

    /// The named composite (object/interface/union) type a list element resolves to, ignoring
    /// non-null wrappers. `nil` for scalar/enum elements or nested lists, whose elements aren't
    /// records and so aren't node-filtered.
    private func compositeElementTypeName(_ type: TypeReference) -> String? {
        switch type {
        case .nonNull(let inner): return compositeElementTypeName(inner)
        case .list: return nil
        case .named(let name):
            switch schema.type(named: name) {
            case .object, .interface, .union: return name
            default: return nil
            }
        }
    }

    private func synthesizeConnection(
        nodes: [GraphQLValue],
        info: Schema.ConnectionInfo,
        arguments: GraphQLValue
    ) -> GraphQLValue {
        var start = 0
        if let after = arguments["after"].stringValue, let index = cursorIndex(after) {
            start = index + 1
        }
        var slice = start < nodes.count ? Array(nodes[start...]) : []
        var hasNextPage = false
        if let first = arguments["first"].intValue, first >= 0, slice.count > first {
            slice = Array(slice.prefix(first))
            hasNextPage = true
        }
        let edges = slice.enumerated().map { offset, node -> GraphQLValue in
            .object(["cursor": .string(cursor(at: start + offset)), "node": node])
        }
        var connection: [String: GraphQLValue] = [
            "edges": .list(edges),
            "pageInfo": .object([
                "hasNextPage": .bool(hasNextPage),
                "hasPreviousPage": .bool(start > 0),
                "startCursor": slice.isEmpty ? .null : .string(cursor(at: start)),
                "endCursor": slice.isEmpty ? .null : .string(cursor(at: start + slice.count - 1)),
            ]),
        ]
        if info.hasTotalCount {
            connection["totalCount"] = .int(nodes.count)
        }
        return .object(connection)
    }

    private func cursor(at index: Int) -> String {
        "cursor:\(index)"
    }

    private func cursorIndex(_ cursor: String) -> Int? {
        guard cursor.hasPrefix("cursor:") else { return nil }
        return Int(cursor.dropFirst("cursor:".count))
    }

    // MARK: - Dynamic (schema-less) resolution

    private mutating func resolveDynamic(
        _ value: GraphQLValue,
        selections: [SelectionNode],
        path: [GraphQLPathSegment]
    ) throws -> GraphQLValue {
        if let elements = value.listValue {
            return .list(
                try elements.enumerated().map { index, element in
                    try resolveDynamic(element, selections: selections, path: path + [.index(index)])
                }
            )
        }
        if let reference = value.referenceValue {
            guard let record = data.record(type: reference.typeName, id: reference.id) else {
                return .null
            }
            return try resolveDynamic(record, selections: selections, path: path)
        }
        var result: [String: GraphQLValue] = [:]
        for selection in selections {
            guard case .field(let field) = selection else { continue }
            guard try includeSelection(field.directives) else { continue }
            if field.name == "__typename" {
                result[field.responseKey] = value["__typename"] ?? .null
                continue
            }
            let child = value[field.name]
            if field.selectionSet.isEmpty {
                result[field.responseKey] = sanitized(child)
            } else {
                result[field.responseKey] = try resolveDynamic(
                    child,
                    selections: field.selectionSet,
                    path: path + [.field(field.responseKey)]
                )
            }
        }
        return .object(result)
    }

    /// Replaces any references that would leak into scalar positions with resolved records
    /// stripped to plain values; other values pass through.
    private func sanitized(_ value: GraphQLValue) -> GraphQLValue {
        if let reference = value.referenceValue {
            return .string("\(reference.typeName):\(reference.id)")
        }
        return value
    }

    // MARK: - Arguments and variables

    mutating func coerceArguments(
        _ fieldDef: Schema.Field,
        nodes: [ArgumentNode],
        location: SourceLocation,
        path: [GraphQLPathSegment]
    ) throws -> GraphQLValue {
        var provided: [String: GraphQLValue] = [:]
        for node in nodes {
            provided[node.name] = try resolveArgumentValue(node.value, at: node.location)
        }
        // Fields with no declared arguments accept anything — DSL-declared mutations receive
        // their inputs without a schema-declared signature.
        if fieldDef.arguments.isEmpty {
            return .object(provided)
        }
        let declaredNames = fieldDef.arguments.map(\.name)
        for name in provided.keys.sorted() where !declaredNames.contains(name) {
            throw GraphQLError(
                message: "Unknown argument '\(name)' on field "
                    + "'\(fieldDef.name)'.\(Suggestion.clause(for: name, in: declaredNames))",
                locations: [location],
                path: path
            )
        }
        var coerced: [String: GraphQLValue] = [:]
        for argument in fieldDef.arguments {
            let value = provided[argument.name] ?? argument.defaultValue
            if let value {
                coerced[argument.name] = try InputCoercion(schema: schema).coerce(
                    value,
                    to: argument.type,
                    context: "argument '\(argument.name)' of '\(fieldDef.name)'",
                    location: location,
                    path: path
                )
            } else if argument.type.isNonNull {
                throw GraphQLError(
                    message: "Missing required argument '\(argument.name)' on field '\(fieldDef.name)'",
                    locations: [location],
                    path: path
                )
            }
        }
        return .object(coerced)
    }

    private func resolveArgumentValue(_ value: ASTValue, at location: SourceLocation) throws -> GraphQLValue {
        switch value {
        case .variable(let name):
            guard let provided = variables[name] else {
                throw GraphQLError(
                    message: "Variable '$\(name)' was not provided.\(Suggestion.clause(for: name, in: variables.keys))",
                    locations: [location]
                )
            }
            return provided
        case .int(let int):
            return .int(int)
        case .float(let double):
            return .double(double)
        case .string(let string):
            return .string(string)
        case .bool(let bool):
            return .bool(bool)
        case .null:
            return .null
        case .enumValue(let name):
            return .enumValue(name)
        case .list(let elements):
            return .list(try elements.map { try resolveArgumentValue($0, at: location) })
        case .object(let fields):
            return .object(try fields.mapValues { try resolveArgumentValue($0, at: location) })
        }
    }

    private func requestError(_ message: String, at location: SourceLocation) -> GraphQLError {
        GraphQLError(message: message, locations: [location])
    }
}
