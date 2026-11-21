// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Monitoring",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MonitoringApp", targets: ["MonitoringApp"]),
        .library(name: "MonitorCore", targets: ["MonitorCore"]),
        .library(name: "MonitorUI", targets: ["MonitorUI"]),
    ],
    targets: [
        // System sampling, models, store, actions. Owned by Claude.
        .target(
            name: "MonitorCore",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        // SwiftUI views and preview fixtures. Owned by Codex.
        .target(
            name: "MonitorUI",
            dependencies: ["MonitorCore"]
        ),
        // App entry point (@main). Owned by Codex.
        .executableTarget(
            name: "MonitoringApp",
            dependencies: ["MonitorCore", "MonitorUI"]
        ),
        .testTarget(
            name: "MonitorCoreTests",
            dependencies: ["MonitorCore"]
        ),
    ]
)
