// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MockQL",
    // Minimum Apple OS versions only — required for Swift concurrency APIs on Apple targets.
    // This does NOT limit platform support: Linux, Windows, and Android ignore this field
    // and are fully supported (by MockQLCore; the MockQL transport layer requires SwiftNIO).
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        // Full package: engine + HTTP/WebSocket transport. Most consumers want this.
        .library(name: "MockQL", targets: ["MockQL"]),
        // Portable engine only (no SwiftNIO) — for platforms or hosts that execute in-process.
        .library(name: "MockQLCore", targets: ["MockQLCore"]),
    ],
    dependencies: [
        // The MockCore platform: shared value model, state store, generators, seed primitives,
        // diagnostics, and the MockHost/MockService transport.
        .package(url: "https://github.com/AlexNachbaur/mockcore-swift.git", from: "0.1.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.70.0"),
        // Build-time only: enables `swift package generate-documentation` for the DocC catalogs.
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0"),
    ],
    targets: [
        .target(
            name: "MockQLCore",
            dependencies: [
                .product(name: "MockCore", package: "mockcore-swift"),
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        .target(
            name: "MockQL",
            dependencies: [
                "MockQLCore",
                .product(name: "MockCoreTransport", package: "mockcore-swift"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
            ]
        ),
        .testTarget(name: "MockQLCoreTests", dependencies: ["MockQLCore"]),
        .testTarget(name: "MockQLTests", dependencies: ["MockQL"]),
        .testTarget(
            name: "MockQLIntegrationTests",
            dependencies: ["MockQL"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
