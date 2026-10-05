/// The result builder for MockQL configuration blocks: queries, mutations, subscriptions,
/// object shapes, seeds, roots, and generator bindings.
@resultBuilder
public struct MockQLBuilder {
    /// Combines the statements of a block into one list.
    public static func buildBlock(_ components: [any MockQLDeclaration]...) -> [any MockQLDeclaration] {
        components.flatMap { $0 }
    }

    /// Lifts a single declaration into the builder's list form.
    public static func buildExpression(_ expression: any MockQLDeclaration) -> [any MockQLDeclaration] {
        [expression]
    }

    /// Supports `if` without `else`: the branch's declarations, or none when it was not taken.
    public static func buildOptional(_ component: [any MockQLDeclaration]?) -> [any MockQLDeclaration] {
        component ?? []
    }

    /// Supports `if`/`else` and `switch`: the declarations of the first branch.
    public static func buildEither(first component: [any MockQLDeclaration]) -> [any MockQLDeclaration] {
        component
    }

    /// Supports `if`/`else` and `switch`: the declarations of the second branch.
    public static func buildEither(second component: [any MockQLDeclaration]) -> [any MockQLDeclaration] {
        component
    }

    /// Supports `for`…`in` loops: the declarations of every iteration, in order.
    public static func buildArray(_ components: [[any MockQLDeclaration]]) -> [any MockQLDeclaration] {
        components.flatMap { $0 }
    }

    /// Supports `if #available`: the declarations of the availability-gated branch.
    public static func buildLimitedAvailability(
        _ component: [any MockQLDeclaration]
    ) -> [any MockQLDeclaration] {
        component
    }
}

/// The result builder for the fields of an ``Object`` declaration.
@resultBuilder
public struct FieldListBuilder {
    /// Combines the statements of a block into one list.
    public static func buildBlock(_ components: [Field]...) -> [Field] {
        components.flatMap { $0 }
    }

    /// Lifts a single field into the builder's list form.
    public static func buildExpression(_ expression: Field) -> [Field] {
        [expression]
    }

    /// Supports `if` without `else`: the branch's fields, or none when it was not taken.
    public static func buildOptional(_ component: [Field]?) -> [Field] {
        component ?? []
    }

    /// Supports `if`/`else` and `switch`: the fields of the first branch.
    public static func buildEither(first component: [Field]) -> [Field] {
        component
    }

    /// Supports `if`/`else` and `switch`: the fields of the second branch.
    public static func buildEither(second component: [Field]) -> [Field] {
        component
    }

    /// Supports `for`…`in` loops: the fields of every iteration, in order.
    public static func buildArray(_ components: [[Field]]) -> [Field] {
        components.flatMap { $0 }
    }
}

/// The result builder for the values of a ``Seed`` declaration.
@resultBuilder
public struct SeedValueBuilder {
    /// Combines the statements of a block into one list.
    public static func buildBlock(_ components: [Value]...) -> [Value] {
        components.flatMap { $0 }
    }

    /// Lifts a single value into the builder's list form.
    public static func buildExpression(_ expression: Value) -> [Value] {
        [expression]
    }

    /// Supports `if` without `else`: the branch's values, or none when it was not taken.
    public static func buildOptional(_ component: [Value]?) -> [Value] {
        component ?? []
    }

    /// Supports `if`/`else` and `switch`: the values of the first branch.
    public static func buildEither(first component: [Value]) -> [Value] {
        component
    }

    /// Supports `if`/`else` and `switch`: the values of the second branch.
    public static func buildEither(second component: [Value]) -> [Value] {
        component
    }

    /// Supports `for`…`in` loops: the values of every iteration, in order.
    public static func buildArray(_ components: [[Value]]) -> [Value] {
        components.flatMap { $0 }
    }
}
