import Foundation
import MockQLCore

/// GraphQL-over-HTTP request parsing.
///
/// The HTTP transport itself lives in `MockCoreTransport` (`MockHost` routes requests to the
/// engine's `MockService` conformance); what remains here is the GraphQL-specific piece —
/// turning a `GET /graphql?query=…` URI into a ``GraphQLRequest``.
struct HTTPHandler {
    /// Parses the `query`, `operationName`, and `variables` parameters of a GET request URI,
    /// or returns `nil` when there is no `query`. Malformed `variables` JSON is ignored rather
    /// than fatal, matching common GraphQL-over-HTTP server behavior.
    static func requestFromQueryString(uri: String) -> GraphQLRequest? {
        guard let components = URLComponents(string: uri),
            let items = components.queryItems,
            let query = items.first(where: { $0.name == "query" })?.value
        else {
            return nil
        }
        let operationName = items.first(where: { $0.name == "operationName" })?.value
        var variables: [String: GraphQLValue] = [:]
        if let rawVariables = items.first(where: { $0.name == "variables" })?.value,
            let parsed = try? GraphQLValue.fromJSONString(rawVariables),
            let object = parsed.objectValue
        {
            variables = object
        }
        return GraphQLRequest(query: query, operationName: operationName, variables: variables)
    }
}
