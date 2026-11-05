// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HermesApps",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "HermesKit", targets: ["HermesKit"]),
        .library(name: "OpenBotUI", targets: ["OpenBotUI"]),
        .library(name: "HermesRender", targets: ["HermesRender"]),
        .library(name: "HermesAppKit", targets: ["HermesAppKit"]),
    ],
    targets: [
        // Wire protocol, transport, stores. No UI, no SwiftUI.
        .target(name: "HermesKit", path: "Sources/HermesKit"),
        // The OpenBot design system: tokens + components.
        .target(name: "OpenBotUI", dependencies: ["HermesKit"], path: "Sources/OpenBotUI"),
        // Incremental markdown / code / tool-output rendering.
        .target(name: "HermesRender", dependencies: ["HermesKit"], path: "Sources/HermesRender"),
        // Shared application state consumed by both app shells.
        .target(name: "HermesAppKit", dependencies: ["HermesKit"], path: "Sources/HermesAppKit"),

        .testTarget(name: "HermesKitTests", dependencies: ["HermesKit"], path: "Tests/HermesKitTests"),
        .testTarget(name: "HermesAppKitTests", dependencies: ["HermesAppKit"], path: "Tests/HermesAppKitTests"),
        .testTarget(name: "HermesRenderTests", dependencies: ["HermesRender"], path: "Tests/HermesRenderTests"),
    ]
)
