/// A mutation handler: receives the operation's coerced input arguments and a transactional
/// view of server state, and returns the value the mutation resolves to.
public typealias MutationHandler =
    @Sendable (
        _ input: GraphQLValue,
        _ state: inout MutationState
    ) throws -> GraphQLValue

/// A declaration accepted by the MockQL configuration builder.
///
/// Conforming types are the DSL vocabulary: ``Query``, ``Mutation``, ``Subscription``,
/// ``Object``, ``Seed``, ``Root``, ``Generate``, ``Filter``, and ``Resolve``. The protocol exists
/// for the result builder's typing; MockQL only understands its own declaration types.
public protocol MockQLDeclaration: Sendable {}

/// Declares a root query field.
///
/// With an object shape, the field returns that object type (defining the type when no SDL
/// schema is present):
///
/// ```swift
/// Query("currentUser") {
///     Object("User") {
///         Field("id", .uuid)
///         Field("name", .fullName)
///     }
/// }
/// ```
public struct Query: MockQLDeclaration {
    let name: String
    let shape: Object?
    let generator: FieldGenerator?

    /// A query field returning an object shape.
    public init(_ name: String, shape: () -> Object) {
        self.name = name
        self.shape = shape()
        self.generator = nil
    }

    /// A query field returning a generated scalar.
    public init(_ name: String, _ generator: FieldGenerator) {
        self.name = name
        self.shape = nil
        self.generator = generator
    }
}

/// Registers a handler for a mutation field.
///
/// When MockQL is configured from an SDL schema the field must exist on the mutation root type.
/// Without an SDL schema the declaration defines the field; pass `returning:` to give it a
/// declared result type, or omit it to resolve the handler's return value structurally.
public struct Mutation: MockQLDeclaration {
    let name: String
    let returning: String?
    let handler: MutationHandler

    /// Declares a mutation field and its handler.
    public init(_ name: String, returning: String? = nil, _ handler: @escaping MutationHandler) {
        self.name = name
        self.returning = returning
        self.handler = handler
    }
}

/// A read-only view of server state passed to a ``Resolve`` field resolver. Exposes the stored
/// records so a resolver can select, filter, or join them when producing a field's value.
public struct StoreView: Sendable {
    let data: StoreData

    init(_ data: StoreData) {
        self.data = data
    }

    /// All stored records of the given object type, in insertion order.
    public func records(of type: String) -> [GraphQLValue] { data.allRecords(type: type) }

    /// The stored record of `type` with the given `id`, or `nil` if none exists.
    public func record(type: String, id: String) -> GraphQLValue? { data.record(type: type, id: id) }
}

/// A field filter predicate: given a candidate node's stored fields and the field's coerced
/// arguments, returns whether the node belongs in the result. Registered via ``Filter``.
public typealias FieldFilter =
    @Sendable (_ node: GraphQLValue, _ arguments: GraphQLValue) -> Bool

/// Registers a custom filter for a list- or connection-typed field, keyed `"Type.field"`.
///
/// By default MockQL filters a field's seeded nodes by any argument whose name matches a scalar
/// field on the node type (e.g. `comments(postId:)` keeps `Comment`s whose `postId` equals the
/// argument). Declare a `Filter` to override that convention for a field whose arguments don't map
/// to node fields by equality — a range, a substring, or a computed match:
///
/// ```swift
/// Filter("Query.products") { node, args in
///     (node["price"].doubleValue ?? 0) <= (args["maxPrice"].doubleValue ?? .infinity)
/// }
/// ```
///
/// The predicate runs against each candidate node (references are dereferenced to their stored
/// record) before pagination arguments (`first`/`after`/…) are applied.
public struct Filter: MockQLDeclaration {
    let key: String
    let predicate: FieldFilter

    /// Declares a filter for the `"Type.field"` connection/list field.
    public init(_ key: String, _ predicate: @escaping FieldFilter) {
        self.key = key
        self.predicate = predicate
    }
}

/// A field resolver: given the field's coerced arguments and a read-only ``StoreView``, returns
/// the value the field resolves to. Registered via ``Resolve``.
public typealias FieldResolver =
    @Sendable (_ arguments: GraphQLValue, _ store: StoreView) -> GraphQLValue

/// Registers a custom resolver for a field, keyed `"Type.field"`, bypassing seeded-node lookup.
///
/// Use when a field's value can't be expressed as "the seeded nodes, filtered" — e.g. search,
/// aggregation, or cross-type joins. Return a list of node references to have MockQL synthesize
/// the connection (edges/pageInfo, honoring pagination arguments), or a fully-formed value:
///
/// ```swift
/// Resolve("Query.search") { args, store in
///     let term = args["term"].stringValue ?? ""
///     return .list(store.records(of: "Article")
///         .filter { $0["title"].stringValue?.localizedCaseInsensitiveContains(term) == true }
///         .map { .reference("Article", id: $0["id"]) })
/// }
/// ```
public struct Resolve: MockQLDeclaration {
    let key: String
    let resolver: FieldResolver

    /// Declares a resolver for the `"Type.field"` field.
    public init(_ key: String, _ resolver: @escaping FieldResolver) {
        self.key = key
        self.resolver = resolver
    }
}

/// Declares a subscription field (only needed when configuring without an SDL schema).
public struct Subscription: MockQLDeclaration {
    let name: String
    let returning: String?

    /// Declares a subscription field, optionally naming its payload type.
    public init(_ name: String, returning: String? = nil) {
        self.name = name
        self.returning = returning
    }
}

/// Defines (or, over an SDL schema, configures generators for) an object type.
public struct Object: MockQLDeclaration {
    let typeName: String
    let fields: [Field]

    /// Defines an object type with the given fields.
    public init(_ typeName: String, @FieldListBuilder _ fields: () -> [Field]) {
        self.typeName = typeName
        self.fields = fields()
    }
}

/// One field inside an ``Object`` declaration.
public struct Field: Sendable {
    enum Kind: Sendable {
        case scalar(FieldGenerator)
        case object(Object)
        case objectList(Object)
        case typed(String)
    }

    let name: String
    let kind: Kind

    /// A scalar field whose values come from the given generator.
    public init(_ name: String, _ generator: FieldGenerator) {
        self.name = name
        self.kind = .scalar(generator)
    }

    /// A field holding a nested object.
    public init(_ name: String, _ object: Object) {
        self.name = name
        self.kind = .object(object)
    }

    /// A field holding a list of nested objects.
    public init(_ name: String, listOf object: Object) {
        self.name = name
        self.kind = .objectList(object)
    }

    /// A field with an explicit GraphQL type, written as SDL (e.g. `"Int!"` or `"[String!]"`).
    public init(_ name: String, type: String) {
        self.name = name
        self.kind = .typed(type)
    }
}

/// Seeds one record, equivalent to a `data:` entry in a seed file.
///
/// ```swift
/// Seed("Product", id: "product-1") {
///     Value("name", "Espresso Machine")
///     Value("priceCents", 64900)
/// }
/// ```
public struct Seed: MockQLDeclaration {
    let typeName: String
    let id: String?
    let fields: [String: GraphQLValue]

    /// Seeds a record from builder values.
    public init(_ typeName: String, id: String? = nil, @SeedValueBuilder _ values: () -> [Value]) {
        self.typeName = typeName
        self.id = id
        var fields: [String: GraphQLValue] = [:]
        for value in values() {
            fields[value.name] = value.value
        }
        self.fields = fields
    }

    /// Seeds a record from a value literal.
    public init(_ typeName: String, id: String? = nil, _ fields: GraphQLValue) {
        self.typeName = typeName
        self.id = id
        self.fields = fields.objectValue ?? [:]
    }
}

/// One field value inside a ``Seed`` declaration.
public struct Value: Sendable {
    let name: String
    let value: GraphQLValue

    /// Names a seeded field value.
    public init(_ name: String, _ value: GraphQLValue) {
        self.name = name
        self.value = value
    }
}

/// Binds a root `Query` field to seeded records, equivalent to a `roots:` entry in a seed file.
public struct Root: MockQLDeclaration {
    let field: String
    let value: GraphQLValue

    /// Binds a root field to a reference (`"user-1"`, `"User:user-1"`), a list, or a value.
    public init(_ field: String, _ value: GraphQLValue) {
        self.field = field
        self.value = value
    }
}

/// Attaches a generator to a schema field, equivalent to the `generators:` dictionary.
///
/// ```swift
/// Generate("User.email", .email)
/// ```
public struct Generate: MockQLDeclaration {
    let key: String
    let generator: FieldGenerator

    /// Binds a generator to `"Type.field"`.
    public init(_ key: String, _ generator: FieldGenerator) {
        self.key = key
        self.generator = generator
    }
}
