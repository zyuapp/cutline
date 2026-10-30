// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Cutline",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Cutline", targets: ["Cutline"]),
        .executable(name: "cutline-mcp", targets: ["cutline-mcp"]),
        .library(name: "CutlineCore", targets: ["CutlineCore"]),
        .library(name: "CutlineEngine", targets: ["CutlineEngine"]),
    ],
    targets: [
        .target(name: "CutlineCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "CutlineEngine", dependencies: ["CutlineCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "CutlineMCP", dependencies: ["CutlineCore", "CutlineEngine"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "cutline-mcp", dependencies: ["CutlineMCP"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "Cutline", dependencies: ["CutlineCore", "CutlineEngine"], resources: [.copy("Fonts")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "CutlineCoreTests", dependencies: ["CutlineCore"], resources: [.copy("Fixtures")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "CutlineEngineTests", dependencies: ["CutlineEngine", "CutlineCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "CutlineMCPTests", dependencies: ["CutlineMCP", "CutlineEngine", "CutlineCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
