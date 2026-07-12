import MockQL
import Testing

@Test func coreModuleIsReExported() {
    // MockQLVersion lives in MockQLCore; reaching it through `import MockQL` alone
    // proves the re-export works.
    #expect(!MockQLVersion.current.isEmpty)
}
