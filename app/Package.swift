// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BrrrnBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "BrrrnBar", targets: ["BrrrnBar"]),
        .library(name: "BrrrnCore", targets: ["BrrrnCore"]),
    ],
    targets: [
        .target(name: "BrrrnCore"),
        .executableTarget(
            name: "BrrrnBar",
            dependencies: ["BrrrnCore"]
        ),
        .testTarget(
            name: "BrrrnCoreTests",
            dependencies: ["BrrrnCore"]
        ),
        .testTarget(
            name: "BrrrnBarTests",
            dependencies: ["BrrrnBar", "BrrrnCore"]
        ),
    ]
)
