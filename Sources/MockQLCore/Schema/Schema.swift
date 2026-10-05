/// A validated GraphQL type system: the named types plus the root operation types.
///
/// Build one from SDL with ``Schema/init(sdl:sourceName:)`` or let the result-builder DSL
/// assemble one. All type references are guaranteed to resolve after initialization.
public struct Schema: Sendable {
    /// An argument on a field, or a field of an input object type.
    public struct Argument: Sendable, Hashable {
        /// The argument (or input field) name.
        public let name: String
        /// The declared input type.
        public let type: TypeReference
        /// The value used when the argument is omitted, or `nil` when it declares no default.
        public let defaultValue: GraphQLValue?

        /// Creates an argument definition.
        public init(name: String, type: TypeReference, defaultValue: GraphQLValue? = nil) {
            self.name = name
            self.type = type
            self.defaultValue = defaultValue
        }
    }

    /// A field on an object or interface type.
    public struct Field: Sendable, Hashable {
        /// The field name.
        public let name: String
        /// The declared return type.
        public let type: TypeReference
        /// The arguments the field accepts, in declaration order.
        public let arguments: [Argument]

        /// Creates a field definition.
        public init(name: String, type: TypeReference, arguments: [Argument] = []) {
            self.name = name
            self.type = type
            self.arguments = arguments
        }

        /// The declared argument with the given name, if any.
        public func argument(named name: String) -> Argument? {
            arguments.first { $0.name == name }
        }
    }

    /// An object type: named fields, optionally implementing interfaces.
    public struct ObjectType: Sendable, Hashable {
        /// The type name.
        public let name: String
        /// The names of the interfaces this type implements.
        public let interfaces: [String]
        /// The fields the type declares, in declaration order.
        public let fields: [Field]
        private let fieldIndex: [String: Int]

        /// Creates an object type.
        public init(name: String, interfaces: [String] = [], fields: [Field]) {
            self.name = name
            self.interfaces = interfaces
            self.fields = fields
            self.fieldIndex = Dictionary(
                fields.enumerated().map { ($0.element.name, $0.offset) },
                uniquingKeysWith: { first, _ in first }
            )
        }

        /// The field with the given name, if declared.
        public func field(named name: String) -> Field? {
            fieldIndex[name].map { fields[$0] }
        }
    }

    /// An interface type.
    public struct InterfaceType: Sendable, Hashable {
        /// The interface name.
        public let name: String
        /// The fields every implementing type must provide, in declaration order.
        public let fields: [Field]

        /// Creates an interface type.
        public init(name: String, fields: [Field]) {
            self.name = name
            self.fields = fields
        }
    }

    /// A union type.
    public struct UnionType: Sendable, Hashable {
        /// The union name.
        public let name: String
        /// The names of the object types the union can resolve to.
        public let members: [String]

        /// Creates a union type.
        public init(name: String, members: [String]) {
            self.name = name
            self.members = members
        }
    }

    /// An enum type.
    public struct EnumType: Sendable, Hashable {
        /// The enum name.
        public let name: String
        /// The enum's value names, in declaration order.
        public let values: [String]

        /// Creates an enum type.
        public init(name: String, values: [String]) {
            self.name = name
            self.values = values
        }
    }

    /// An input object type.
    public struct InputObjectType: Sendable, Hashable {
        /// The input type name.
        public let name: String
        /// The input fields, in declaration order. A field's `defaultValue` applies when it is omitted.
        public let fields: [Argument]

        /// Creates an input object type.
        public init(name: String, fields: [Argument]) {
            self.name = name
            self.fields = fields
        }
    }

    /// A scalar type — one of the five built-ins or a custom scalar from the schema.
    public struct ScalarType: Sendable, Hashable {
        /// The scalar name.
        public let name: String
        /// `true` for `Int`, `Float`, `String`, `Boolean`, and `ID`; `false` for a custom scalar, whose
        /// values pass through coercion unchanged.
        public let isBuiltIn: Bool

        /// Creates a scalar type.
        public init(name: String, isBuiltIn: Bool) {
            self.name = name
            self.isBuiltIn = isBuiltIn
        }
    }

    /// Any named type in the schema.
    public enum NamedType: Sendable, Hashable {
        /// An object type.
        case object(ObjectType)
        /// An interface type.
        case interface(InterfaceType)
        /// A union type.
        case union(UnionType)
        /// An enum type.
        case enumType(EnumType)
        /// An input object type.
        case inputObject(InputObjectType)
        /// A built-in or custom scalar type.
        case scalar(ScalarType)

        /// The type's name.
        public var name: String {
            switch self {
            case .object(let type): return type.name
            case .interface(let type): return type.name
            case .union(let type): return type.name
            case .enumType(let type): return type.name
            case .inputObject(let type): return type.name
            case .scalar(let type): return type.name
            }
        }

        /// A lowercase kind word for diagnostics ("object", "enum", …).
        public var kindDescription: String {
            switch self {
            case .object: return "object"
            case .interface: return "interface"
            case .union: return "union"
            case .enumType: return "enum"
            case .inputObject: return "input object"
            case .scalar: return "scalar"
            }
        }
    }

    /// All named types, keyed by name. Includes the built-in scalars.
    public let types: [String: NamedType]
    /// The root query type.
    ///
    /// Resolved once, when the schema is built: a schema whose query root is missing or is not
    /// an object type fails to load, so this is always the real type and never a stand-in.
    public let queryType: ObjectType
    /// The name of the root query type.
    public var queryTypeName: String { queryType.name }
    /// The name of the root mutation type, when the schema defines one.
    public let mutationTypeName: String?
    /// The name of the root subscription type, when the schema defines one.
    public let subscriptionTypeName: String?

    /// The names of the five built-in scalar types.
    public static let builtInScalarNames: Set<String> = ["Int", "Float", "String", "Boolean", "ID"]

    // MARK: - Lookups

    /// The named type with the given name, if defined.
    public func type(named name: String) -> NamedType? {
        types[name]
    }

    /// The object type with the given name, if defined and an object.
    public func objectType(named name: String) -> ObjectType? {
        if case .object(let type) = types[name] { return type }
        return nil
    }

    /// The concrete object types a given output type name can resolve to: itself for objects,
    /// the members for unions, and all implementors for interfaces.
    public func possibleTypeNames(for name: String) -> [String] {
        switch types[name] {
        case .object(let type):
            return [type.name]
        case .union(let type):
            return type.members
        case .interface(let type):
            return types.values.compactMap { named in
                if case .object(let object) = named, object.interfaces.contains(type.name) {
                    return object.name
                }
                return nil
            }.sorted()
        default:
            return []
        }
    }

    /// `true` when `typeName` names an interface or union.
    public func isPolymorphic(_ typeName: String) -> Bool {
        switch types[typeName] {
        case .interface, .union: return true
        default: return false
        }
    }

    /// The field definition for a field on an object, interface, or union-member position.
    public func field(_ fieldName: String, onType typeName: String) -> Field? {
        switch types[typeName] {
        case .object(let type):
            return type.field(named: fieldName)
        case .interface(let type):
            return type.fields.first { $0.name == fieldName }
        default:
            return nil
        }
    }

    // MARK: - Construction

    init(
        types: [String: NamedType],
        queryType: ObjectType,
        mutationTypeName: String?,
        subscriptionTypeName: String?
    ) {
        self.types = types
        self.queryType = queryType
        self.mutationTypeName = mutationTypeName
        self.subscriptionTypeName = subscriptionTypeName
    }
}
