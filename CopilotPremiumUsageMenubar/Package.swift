// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CopilotPremiumUsageMenubar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        // Core library: reusable logic (GitHub client, models, persistence).
        .library(
            name: "CopilotPremiumUsageMenubarCore",
            targets: ["CopilotPremiumUsageMenubarCore"]
        ),

        // AppKit/SwiftUI library: menubar UI + runner (importable from an Xcode wrapper app).
        .library(
            name: "CopilotPremiumUsageMenubarAppKit",
            targets: ["CopilotPremiumUsageMenubarAppKit"]
        ),

        // Executable: thin entrypoint (main.swift only) that calls MenubarAppRunner.
        .executable(
            name: "CopilotPremiumUsageMenubarApp",
            targets: ["CopilotPremiumUsageMenubarApp"]
        )
    ],
    dependencies: [
        // No external dependencies initially.
        // If you later add Sparkle, OctoKit, etc., declare them here.
    ],
    targets: [
        .target(
            name: "CopilotPremiumUsageMenubarCore",
            dependencies: [],
            path: "Sources/Core"
        ),
        .target(
            name: "CopilotPremiumUsageMenubarAppKit",
            dependencies: ["CopilotPremiumUsageMenubarCore"],
            path: "Sources/AppKit",
            resources: [
                .process("../../Resources")
            ]
        ),
        .executableTarget(
            name: "CopilotPremiumUsageMenubarApp",
            dependencies: ["CopilotPremiumUsageMenubarAppKit"],
            path: "Sources/App",
            sources: ["main.swift"]
        )
    ]
)
