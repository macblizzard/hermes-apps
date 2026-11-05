// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HermesApps",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "HermesKit", targets: ["HermesKit"]),
        .library(name: "OpenBotUI", targets: ["OpenBotUI"]),
        .library(name: "HermesRender", targets: ["HermesRender"]),
    ],
    targets: [
        // Wire protocol, transport, stores. No UI, no SwiftUI.
        .target(name: "HermesKit", path: "Sources/HermesKit"),
        // The OpenBot design system: tokens + components.
        .target(name: "OpenBotUI", dependencies: ["HermesKit"], path: "Sources/OpenBotUI"),
        // Incremental markdown / code / tool-output rendering.
        .target(name: "HermesRender", dependencies: ["HermesKit"], path: "Sources/HermesRender"),
        .testTarget(name: "HermesKitTests", dependencies: ["HermesKit"], path: "Tests/HermesKitTests"),
        .testTarget(name: "HermesRenderTests", dependencies: ["HermesRender"], path: "Tests/HermesRenderTests"),
    ]
)
