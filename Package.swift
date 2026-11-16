// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenScribe",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "OpenScribe", targets: ["OpenScribe"]),
        .executable(name: "OpenScribeInstaller", targets: ["OpenScribeInstaller"]),
        .executable(name: "openscribe-mcp", targets: ["OpenScribeMCP"]),
        .library(name: "OpenScribeContext", targets: ["OpenScribeContext"]),
    ],
    dependencies: [
        // Over-the-air updates (EdDSA-signed appcast). See docs/UPDATES.md.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .target(
            name: "OpenScribeObjC",
            path: "Sources/OpenScribeObjC"
        ),
        .executableTarget(
            name: "OpenScribe",
            dependencies: ["OpenScribeObjC", "OpenScribeContext", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/OpenScribe",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "OpenScribeInstaller",
            path: "Sources/OpenScribeInstaller"
        ),
        .target(
            name: "OpenScribeContext",
            path: "Sources/OpenScribeContext"
        ),
        .executableTarget(
            name: "OpenScribeMCP",
            dependencies: ["OpenScribeContext"],
            path: "Sources/OpenScribeMCP"
        ),
        .testTarget(
            name: "OpenScribeTests",
            dependencies: ["OpenScribe", "OpenScribeContext"],
            path: "Tests/OpenScribeTests"
        ),
        .testTarget(
            name: "OpenScribeContextTests",
            dependencies: ["OpenScribeContext", "OpenScribeMCP"],
            path: "Tests/OpenScribeContextTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
