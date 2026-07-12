/// The result builder for MockQL configuration blocks: queries, mutations, subscriptions,
/// object shapes, seeds, roots, and generator bindings.
@resultBuilder
public struct MockQLBuilder {
    public static func buildBlock(_ components: [any MockQLDeclaration]...) -> [any MockQLDeclaration] {
        components.flatMap { $0 }
    }

    public static func buildExpression(_ expression: any MockQLDeclaration) -> [any MockQLDeclaration] {
        [expression]
    }

    public static func buildOptional(_ component: [any MockQLDeclaration]?) -> [any MockQLDeclaration] {
        component ?? []
    }

    public static func buildEither(first component: [any MockQLDeclaration]) -> [any MockQLDeclaration] {
        component
    }

    public static func buildEither(second component: [any MockQLDeclaration]) -> [any MockQLDeclaration] {
        component
    }

    public static func buildArray(_ components: [[any MockQLDeclaration]]) -> [any MockQLDeclaration] {
        components.flatMap { $0 }
    }

    public static func buildLimitedAvailability(
        _ component: [any MockQLDeclaration]
    ) -> [any MockQLDeclaration] {
        component
    }
}

/// The result builder for the fields of an ``Object`` declaration.
@resultBuilder
public struct FieldListBuilder {
    public static func buildBlock(_ components: [Field]...) -> [Field] {
        components.flatMap { $0 }
    }

    public static func buildExpression(_ expression: Field) -> [Field] {
        [expression]
    }

    public static func buildOptional(_ component: [Field]?) -> [Field] {
        component ?? []
    }

    public static func buildEither(first component: [Field]) -> [Field] {
        component
    }

    public static func buildEither(second component: [Field]) -> [Field] {
        component
    }

    public static func buildArray(_ components: [[Field]]) -> [Field] {
        components.flatMap { $0 }
    }
}

/// The result builder for the values of a ``Seed`` declaration.
@resultBuilder
public struct SeedValueBuilder {
    public static func buildBlock(_ components: [Value]...) -> [Value] {
        components.flatMap { $0 }
    }

    public static func buildExpression(_ expression: Value) -> [Value] {
        [expression]
    }

    public static func buildOptional(_ component: [Value]?) -> [Value] {
        component ?? []
    }

    public static func buildEither(first component: [Value]) -> [Value] {
        component
    }

    public static func buildEither(second component: [Value]) -> [Value] {
        component
    }

    public static func buildArray(_ components: [[Value]]) -> [Value] {
        components.flatMap { $0 }
    }
}
