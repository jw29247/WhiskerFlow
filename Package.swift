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
    dependencies: [
        // v0.13.0 is the last lightweight release (only swift-transformers);
        // v0.18.0+ pull in Vapor and a web-server monorepo we don't want.
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "0.13.0")
    ],
    targets: [
        .target(name: "WhiskerFlowCore"),
        .executableTarget(
            name: "WhiskerFlow",
            dependencies: [
                "WhiskerFlowCore",
                .product(name: "WhisperKit", package: "WhisperKit")
            ]
        ),
        .testTarget(
            name: "WhiskerFlowCoreTests",
            dependencies: ["WhiskerFlowCore"]
        )
    ]
)
