import Foundation
import Testing

@testable import MockQL

@Test func fixtureResourcesAreBundled() throws {
    for (name, ext) in [("shop", "graphqls"), ("checkout", "yaml"), ("tasks", "graphqls"), ("tasks", "yaml")] {
        let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
        #expect(url != nil, "missing \(name).\(ext)")
    }
}
