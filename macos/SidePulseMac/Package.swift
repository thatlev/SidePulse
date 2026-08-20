// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SidePulseMac",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SidePulseMac",
            path: "Sources/SidePulseMac",
            resources: [.process("Resources")]
        )
    ]
)
