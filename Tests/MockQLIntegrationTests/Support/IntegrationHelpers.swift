import Foundation
import MockQL
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Locates a bundled fixture file and returns its filesystem path.
func fixturePath(_ name: String, extension ext: String) throws -> String {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
        "missing bundled fixture \(name).\(ext)"
    )
    return url.path
}

/// POSTs a GraphQL request to a running server and returns the decoded response body.
func post(
    _ query: String,
    variables: GraphQLValue = [:],
    to url: URL
) async throws -> (status: Int, body: GraphQLValue) {
    var body: GraphQLValue = ["query": .string(query)]
    if !(variables.objectValue?.isEmpty ?? true) {
        body["variables"] = variables
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try body.jsonData()
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    return (status, try GraphQLValue.fromJSONData(data))
}

/// GETs a URL and returns the raw response.
func get(_ url: URL) async throws -> (status: Int, body: Data) {
    let (data, response) = try await URLSession.shared.data(from: url)
    return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
}

/// Runs an async operation with a deadline so a missing WebSocket event fails the test instead
/// of hanging it.
func withTimeout<T: Sendable>(
    seconds: Double = 5,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        guard let first = try await group.next() else {
            throw TimeoutError()
        }
        group.cancelAll()
        return first
    }
}

struct TimeoutError: Error, CustomStringConvertible {
    var description: String {
        "timed out waiting for an async operation"
    }
}
