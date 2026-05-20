// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "WhiskerFlow",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "WhiskerFlow", targets: ["WhiskerFlow"]),
        .library(name: "WhiskerFlowCore", targets: ["WhiskerFlowCore"])
    ],
    targets: [
        .target(name: "WhiskerFlowCore"),
        .executableTarget(
            name: "WhiskerFlow",
            dependencies: ["WhiskerFlowCore"]
        ),
        .testTarget(
            name: "WhiskerFlowCoreTests",
            dependencies: ["WhiskerFlowCore"]
        )
    ]
)
