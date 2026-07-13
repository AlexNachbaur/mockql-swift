// MockQL re-exports the portable engine — and the platform transport, so composing MockQL with
// sibling services on one MockHost works with `import MockQL` as the only import.
@_exported import MockCoreTransport
@_exported import MockQLCore
