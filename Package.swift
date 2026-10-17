// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "app-memory-report",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MemoryCore"),
        .executableTarget(
            name: "app-memory-report",
            dependencies: ["MemoryCore"],
            resources: [.process("Localizable.xcstrings")]
        ),
        .executableTarget(
            name: "AppMemoryReport",
            dependencies: ["MemoryCore"],
            resources: [.process("Localizable.xcstrings")]
        ),
    ]
)
