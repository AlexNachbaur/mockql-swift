import Foundation
import Testing

@testable import MockQLCore

@Test func versionIsSemanticVersion() {
    let components = MockQLVersion.current.split(separator: ".")
    #expect(components.count == 3)
    #expect(components.allSatisfy { Int($0) != nil })
}

/// The constant is maintained by hand, and a release that forgets it ships a version that
/// misreports itself. Checked against the changelog, which every release already edits.
@Test func versionMatchesTheNewestReleasedChangelogEntry() throws {
    let changelog = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("CHANGELOG.md")
    // The source tree is not present when the suite runs on a simulator or an emulator.
    guard let text = try? String(contentsOf: changelog, encoding: .utf8) else { return }
    // Split on any newline: a Windows checkout has CRLF endings, and "\r\n" is one Character,
    // so splitting on "\n" would never split at all.
    let released = text.split(whereSeparator: \.isNewline).lazy
        .filter { $0.hasPrefix("## [") && !$0.hasPrefix("## [Unreleased]") }
        .compactMap { $0.dropFirst(4).split(separator: "]").first.map(String.init) }
        .first
    #expect(try #require(released) == MockQLVersion.current)
}
