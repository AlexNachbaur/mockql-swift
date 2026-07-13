import MockCore

extension GeneratorRegistry {
    /// Validates that every binding refers to a real `Type.field` in the schema.
    ///
    /// This is the GraphQL side of generator validation: `GeneratorRegistry` itself lives in
    /// MockCore and knows nothing about schemas, so each protocol extension checks the binding
    /// keys against its own schema model.
    func validate(against schema: Schema) throws {
        for key in bindingKeys {
            let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                throw MockQLError(
                    category: .configuration,
                    message: "Generator key '\(key)' must have the form 'Type.field'"
                )
            }
            let (typeName, fieldName) = (parts[0], parts[1])
            guard let type = schema.type(named: typeName) else {
                let clause = Suggestion.clause(for: typeName, in: schema.types.keys)
                throw MockQLError(
                    category: .configuration,
                    message: "Generator '\(key)' refers to unknown type '\(typeName)'.\(clause)"
                )
            }
            guard case .object(let object) = type else {
                throw MockQLError(
                    category: .configuration,
                    message: "Generator '\(key)' refers to '\(typeName)', which is not an object type"
                )
            }
            guard object.field(named: fieldName) != nil else {
                let clause = Suggestion.clause(for: fieldName, in: object.fields.map(\.name))
                throw MockQLError(
                    category: .configuration,
                    message: "Generator '\(key)' refers to unknown field '\(fieldName)' on '\(typeName)'.\(clause)"
                )
            }
        }
    }
}
