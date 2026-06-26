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
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "0.13.0"),
        // In-app auto-updates (appcast + EdDSA-signed updates). Sparkle ships as a
        // binary XCFramework; `script/bundle_app.sh` embeds & re-signs it.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .target(name: "WhiskerFlowCore"),
        .executableTarget(
            name: "WhiskerFlow",
            dependencies: [
                "WhiskerFlowCore",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "Sparkle", package: "Sparkle")
            ]
        ),
        .testTarget(
            name: "WhiskerFlowCoreTests",
            dependencies: ["WhiskerFlowCore"]
        )
    ]
)
