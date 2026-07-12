/// Coerces runtime input values (operation variables and field arguments) per GraphQL input
/// coercion rules.
struct InputCoercion {
    let schema: Schema

    func coerce(
        _ value: GraphQLValue,
        to type: TypeReference,
        context: String,
        location: SourceLocation,
        path: [GraphQLPathSegment] = []
    ) throws -> GraphQLValue {
        if case .nonNull(let inner) = type {
            if value.isNull {
                throw error("Null is not allowed for non-null \(context)", location: location, path: path)
            }
            return try coerce(value, to: inner, context: context, location: location, path: path)
        }
        if value.isNull {
            return .null
        }
        switch type {
        case .nonNull(let inner):
            return try coerce(value, to: inner, context: context, location: location, path: path)
        case .list(let element):
            let elements = value.listValue ?? [value]
            return .list(
                try elements.map { try coerce($0, to: element, context: context, location: location, path: path) }
            )
        case .named(let name):
            return try coerceNamed(value, typeName: name, context: context, location: location, path: path)
        }
    }

    private func coerceNamed(
        _ value: GraphQLValue,
        typeName: String,
        context: String,
        location: SourceLocation,
        path: [GraphQLPathSegment]
    ) throws -> GraphQLValue {
        switch schema.type(named: typeName) {
        case .scalar(let scalar):
            return try coerceScalar(value, scalar: scalar, context: context, location: location, path: path)
        case .enumType(let enumType):
            guard let name = value.enumName ?? value.stringValue else {
                throw error(
                    "Expected a value of enum '\(enumType.name)' for \(context), found \(value)",
                    location: location,
                    path: path
                )
            }
            guard enumType.values.contains(name) else {
                throw error(
                    "'\(name)' is not a value of enum "
                        + "'\(enumType.name)'.\(Suggestion.clause(for: name, in: enumType.values))",
                    location: location,
                    path: path
                )
            }
            return .enumValue(name)
        case .inputObject(let inputType):
            guard let fields = value.objectValue else {
                throw error(
                    "Expected an input object '\(inputType.name)' for \(context), found \(value)",
                    location: location,
                    path: path
                )
            }
            let declaredNames = inputType.fields.map(\.name)
            for name in fields.keys.sorted() where !declaredNames.contains(name) {
                throw error(
                    "Unknown field '\(name)' on input type "
                        + "'\(inputType.name)'.\(Suggestion.clause(for: name, in: declaredNames))",
                    location: location,
                    path: path
                )
            }
            var coerced: [String: GraphQLValue] = [:]
            for field in inputType.fields {
                let provided = fields[field.name] ?? field.defaultValue
                if let provided {
                    coerced[field.name] = try coerce(
                        provided,
                        to: field.type,
                        context: "field '\(field.name)' of input '\(inputType.name)'",
                        location: location,
                        path: path
                    )
                } else if field.type.isNonNull {
                    throw error(
                        "Missing required field '\(field.name)' of input '\(inputType.name)'",
                        location: location,
                        path: path
                    )
                }
            }
            return .object(coerced)
        case .object, .interface, .union:
            throw error(
                "'\(typeName)' is an output type and cannot be used for \(context)", location: location, path: path)
        case .none:
            throw error("Unknown type '\(typeName)' for \(context)", location: location, path: path)
        }
    }

    private func coerceScalar(
        _ value: GraphQLValue,
        scalar: Schema.ScalarType,
        context: String,
        location: SourceLocation,
        path: [GraphQLPathSegment]
    ) throws -> GraphQLValue {
        guard scalar.isBuiltIn else {
            return value
        }
        switch (scalar.name, value) {
        case ("Int", .int):
            return value
        case ("Float", .int(let int)):
            return .double(Double(int))
        case ("Float", .double):
            return value
        case ("String", .string):
            return value
        case ("Boolean", .bool):
            return value
        case ("ID", .string):
            return value
        case ("ID", .int(let int)):
            return .string(String(int))
        default:
            throw error(
                "Expected \(scalar.name) for \(context), found \(value)",
                location: location,
                path: path
            )
        }
    }

    private func error(
        _ message: String,
        location: SourceLocation,
        path: [GraphQLPathSegment]
    ) -> GraphQLError {
        GraphQLError(
            message: message,
            locations: [location],
            path: path,
            extensions: ["code": .string("BAD_INPUT")]
        )
    }
}
