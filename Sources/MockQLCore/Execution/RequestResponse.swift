import Foundation

/// A GraphQL request: the document, an optional operation name, and variables.
public struct GraphQLRequest: Sendable, Hashable {
    /// The GraphQL document (query/mutation/subscription source text).
    public let query: String
    /// Which operation to run when the document defines several.
    public let operationName: String?
    /// Variable values, keyed by name (without the `$`).
    public let variables: [String: GraphQLValue]

    /// Creates a request.
    public init(query: String, operationName: String? = nil, variables: [String: GraphQLValue] = [:]) {
        self.query = query
        self.operationName = operationName
        self.variables = variables
    }

    /// Decodes a request from a standard GraphQL-over-HTTP JSON body:
    /// `{"query": "...", "operationName": ..., "variables": {...}}`.
    public init(jsonBody: Data) throws {
        let value: GraphQLValue
        do {
            value = try GraphQLValue.fromJSONData(jsonBody)
        } catch {
            throw GraphQLError(message: "Request body is not valid JSON")
        }
        guard let query = value["query"].stringValue else {
            throw GraphQLError(message: "Request body must include a 'query' string")
        }
        self.query = query
        self.operationName = value["operationName"].stringValue
        self.variables = value["variables"].objectValue ?? [:]
    }
}

/// A GraphQL response in the spec's response format.
public struct GraphQLResponse: Sendable, Hashable {
    /// The `data` entry; `nil` when the request failed before execution began.
    public let data: GraphQLValue?
    /// Any errors raised while validating or executing.
    public let errors: [GraphQLError]

    /// Creates a response.
    public init(data: GraphQLValue?, errors: [GraphQLError] = []) {
        self.data = data
        self.errors = errors
    }

    /// A response with only errors and no data (request-level failure).
    public static func requestFailed(_ errors: [GraphQLError]) -> GraphQLResponse {
        GraphQLResponse(data: nil, errors: errors)
    }

    /// The response as a value tree: `{"data": …, "errors": […]}`.
    public var responseValue: GraphQLValue {
        var fields: [String: GraphQLValue] = [:]
        if let data {
            fields["data"] = data
        }
        if !errors.isEmpty {
            fields["errors"] = .list(errors.map(\.responseValue))
        }
        return .object(fields)
    }

    /// The response serialized as JSON.
    public func jsonData(prettyPrinted: Bool = false) throws -> Data {
        try responseValue.jsonData(prettyPrinted: prettyPrinted)
    }
}
