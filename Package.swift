// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenScribe",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "OpenScribe", targets: ["OpenScribe"]),
    ],
    targets: [
        .executableTarget(
            name: "OpenScribe",
            path: "Sources/OpenScribe",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "OpenScribeTests",
            dependencies: ["OpenScribe"],
            path: "Tests/OpenScribeTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
