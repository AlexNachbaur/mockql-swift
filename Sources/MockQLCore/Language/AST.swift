/// A reference to a type in a GraphQL document: `User`, `[User]`, `User!`, `[User!]!`, …
public indirect enum TypeReference: Hashable, Sendable, CustomStringConvertible {
    case named(String)
    case list(TypeReference)
    case nonNull(TypeReference)

    /// The innermost named type (`[User!]!` → `User`).
    public var namedTypeName: String {
        switch self {
        case .named(let name): return name
        case .list(let inner), .nonNull(let inner): return inner.namedTypeName
        }
    }

    /// `true` when the outermost wrapper is non-null.
    public var isNonNull: Bool {
        if case .nonNull = self { return true }
        return false
    }

    /// The type with an outer non-null wrapper removed (`User!` → `User`); other types unchanged.
    public var nullable: TypeReference {
        if case .nonNull(let inner) = self { return inner }
        return self
    }

    /// `true` when the type (ignoring an outer non-null) is a list.
    public var isList: Bool {
        if case .list = nullable { return true }
        return false
    }

    /// The element type when this is a list (ignoring an outer non-null), else `nil`.
    public var listElementType: TypeReference? {
        if case .list(let element) = nullable { return element }
        return nil
    }

    public var description: String {
        switch self {
        case .named(let name): return name
        case .list(let inner): return "[\(inner)]"
        case .nonNull(let inner): return "\(inner)!"
        }
    }
}

/// A value literal as written in a document, which unlike `GraphQLValue` may contain variables.
indirect enum ASTValue: Hashable, Sendable {
    case variable(String)
    case int(Int)
    case float(Double)
    case string(String)
    case bool(Bool)
    case null
    case enumValue(String)
    case list([ASTValue])
    case object([String: ASTValue])
}

/// A directive application: `@skip(if: $flag)`.
struct DirectiveNode: Hashable, Sendable {
    let name: String
    let arguments: [String: ASTValue]
    let location: SourceLocation
}

/// One argument in a field's argument list.
struct ArgumentNode: Hashable, Sendable {
    let name: String
    let value: ASTValue
    let location: SourceLocation
}

/// A field selection: `alias: name(args) @directives { selections }`.
struct FieldNode: Hashable, Sendable {
    let alias: String?
    let name: String
    let arguments: [ArgumentNode]
    let directives: [DirectiveNode]
    let selectionSet: [SelectionNode]
    let location: SourceLocation

    /// The key this field appears under in the response (the alias when present).
    var responseKey: String {
        alias ?? name
    }
}

/// A single entry in a selection set.
indirect enum SelectionNode: Hashable, Sendable {
    case field(FieldNode)
    case fragmentSpread(name: String, directives: [DirectiveNode], location: SourceLocation)
    case inlineFragment(
        typeCondition: String?,
        directives: [DirectiveNode],
        selectionSet: [SelectionNode],
        location: SourceLocation
    )
}

/// The three GraphQL operation types.
public enum OperationType: String, Hashable, Sendable {
    case query
    case mutation
    case subscription
}

/// A variable declared in an operation's signature: `$id: ID! = "user-1"`.
struct VariableDefinitionNode: Hashable, Sendable {
    let name: String
    let type: TypeReference
    let defaultValue: ASTValue?
    let location: SourceLocation
}

/// One operation (query/mutation/subscription) in an executable document.
struct OperationNode: Hashable, Sendable {
    let type: OperationType
    let name: String?
    let variableDefinitions: [VariableDefinitionNode]
    let directives: [DirectiveNode]
    let selectionSet: [SelectionNode]
    let location: SourceLocation
}

/// A named fragment definition.
struct FragmentDefinitionNode: Hashable, Sendable {
    let name: String
    let typeCondition: String
    let directives: [DirectiveNode]
    let selectionSet: [SelectionNode]
    let location: SourceLocation
}

/// A parsed executable document: operations plus named fragments.
struct ExecutableDocument: Hashable, Sendable {
    let operations: [OperationNode]
    let fragments: [String: FragmentDefinitionNode]

    /// Selects the operation to run: the named one, or the sole operation when unnamed.
    func operation(named name: String?) throws -> OperationNode {
        if let name {
            guard let match = operations.first(where: { $0.name == name }) else {
                let known = operations.compactMap(\.name)
                throw GraphQLError(
                    message: "Unknown operation '\(name)'.\(Suggestion.clause(for: name, in: known))"
                )
            }
            return match
        }
        guard operations.count == 1, let only = operations.first else {
            throw GraphQLError(
                message: operations.isEmpty
                    ? "Document contains no operations"
                    : "Document contains \(operations.count) operations; specify 'operationName'"
            )
        }
        return only
    }
}
