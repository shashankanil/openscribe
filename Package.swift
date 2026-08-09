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
    ],
    targets: [
        .executableTarget(
            name: "OpenScribe",
            path: "Sources/OpenScribe",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "OpenScribeInstaller",
            path: "Sources/OpenScribeInstaller"
        ),
        .testTarget(
            name: "OpenScribeTests",
            dependencies: ["OpenScribe"],
            path: "Tests/OpenScribeTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
