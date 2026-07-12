/// An argument or input-object field definition: `name: Type = default`.
struct InputValueDefinitionNode: Hashable, Sendable {
    let name: String
    let type: TypeReference
    let defaultValue: ASTValue?
    let description: String?
    let location: SourceLocation
}

/// A field definition on an object or interface type.
struct FieldDefinitionNode: Hashable, Sendable {
    let name: String
    let arguments: [InputValueDefinitionNode]
    let type: TypeReference
    let description: String?
    let location: SourceLocation
}

/// One enum member.
struct EnumValueDefinitionNode: Hashable, Sendable {
    let name: String
    let description: String?
    let location: SourceLocation
}

/// A type definition in an SDL document.
enum TypeDefinitionNode: Hashable, Sendable {
    case object(
        name: String, interfaces: [String], fields: [FieldDefinitionNode], description: String?,
        location: SourceLocation)
    case interface(
        name: String, interfaces: [String], fields: [FieldDefinitionNode], description: String?,
        location: SourceLocation)
    case union(name: String, members: [String], description: String?, location: SourceLocation)
    case enumType(name: String, values: [EnumValueDefinitionNode], description: String?, location: SourceLocation)
    case inputObject(name: String, fields: [InputValueDefinitionNode], description: String?, location: SourceLocation)
    case scalar(name: String, description: String?, location: SourceLocation)

    var name: String {
        switch self {
        case .object(let name, _, _, _, _),
            .interface(let name, _, _, _, _),
            .union(let name, _, _, _),
            .enumType(let name, _, _, _),
            .inputObject(let name, _, _, _),
            .scalar(let name, _, _):
            return name
        }
    }

    var location: SourceLocation {
        switch self {
        case .object(_, _, _, _, let location),
            .interface(_, _, _, _, let location),
            .union(_, _, _, let location),
            .enumType(_, _, _, let location),
            .inputObject(_, _, _, let location),
            .scalar(_, _, let location):
            return location
        }
    }
}

/// An explicit `schema { query: … }` definition.
struct SchemaDefinitionNode: Hashable, Sendable {
    let operationTypes: [OperationType: String]
    let location: SourceLocation
}

/// A parsed SDL document.
struct SchemaDocument: Hashable, Sendable {
    let typeDefinitions: [TypeDefinitionNode]
    let schemaDefinition: SchemaDefinitionNode?
}
