// swift-tools-version: 6.0
import Foundation
import PackageDescription

// `#Preview` needs the PreviewsMacros compiler plugin, which ships only with Xcode.
// With Command Line Tools alone, compile previews out so `swift build` still works.
let xcodeInstalled = ((try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? [])
    .contains { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }
let uiSwiftSettings: [SwiftSetting] = xcodeInstalled ? [] : [.define("MONITORING_SKIP_PREVIEWS")]

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
            dependencies: ["MonitorCore"],
            swiftSettings: uiSwiftSettings
        ),
        // App entry point (@main). Owned by Codex.
        .executableTarget(
            name: "MonitoringApp",
            dependencies: ["MonitorCore", "MonitorUI"],
            swiftSettings: uiSwiftSettings
        ),
        .testTarget(
            name: "MonitorCoreTests",
            dependencies: ["MonitorCore"]
        ),
    ]
)
