// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WhisperFlow",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "WhisperFlow", targets: ["WhisperFlow"]),
    ],
    targets: [
        .executableTarget(
            name: "WhisperFlow",
            path: "Sources/WhisperFlow",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "WhisperFlowTests",
            dependencies: ["WhisperFlow"],
            path: "Tests/WhisperFlowTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
