// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentTerminal",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "AgentTerminal",
            dependencies: ["AgentTerminalKit", "AgentTerminalHookKit"],
            path: "Sources/AgentTerminal"
        ),
        .executableTarget(
            name: "AgentTerminalHook",
            dependencies: ["AgentTerminalHookKit"],
            path: "Sources/AgentTerminalHook"
        ),
        .target(
            name: "AgentTerminalHookKit",
            path: "Sources/AgentTerminalHookKit"
        ),
        .target(
            name: "AgentTerminalKit",
            dependencies: [
                "GhosttyKit",
            ],
            path: "Sources/AgentTerminalKit",
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Carbon"),
            ]
        ),
        .binaryTarget(
            name: "GhosttyKit",
            path: "Vendor/GhosttyKit.xcframework"
        ),
        .testTarget(
            name: "AgentTerminalKitTests",
            dependencies: ["AgentTerminalKit"],
            path: "Tests/AgentTerminalKitTests"
        ),
        .testTarget(
            name: "AgentTerminalHookKitTests",
            dependencies: ["AgentTerminalHookKit"],
            path: "Tests/AgentTerminalHookKitTests"
        ),
    ]
)
