import Foundation
import Testing

@testable import MockQL

@Test func fixtureResourcesAreBundled() throws {
    let schema = Bundle.module.url(forResource: "shop", withExtension: "graphqls", subdirectory: "Fixtures")
    let seed = Bundle.module.url(forResource: "checkout", withExtension: "yaml", subdirectory: "Fixtures")
    #expect(schema != nil)
    #expect(seed != nil)
}
