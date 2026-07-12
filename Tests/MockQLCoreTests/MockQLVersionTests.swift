import Testing

@testable import MockQLCore

@Test func versionIsSemanticVersion() {
    let components = MockQLVersion.current.split(separator: ".")
    #expect(components.count == 3)
    #expect(components.allSatisfy { Int($0) != nil })
}
