// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ArducamBridge",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(
            name: "ArducamBridgeViewer",
            targets: ["ArducamBridgeViewer"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "ArducamBridgeViewer",
            path: "Sources/ArducamBridgeViewer"
        ),
    ]
)
