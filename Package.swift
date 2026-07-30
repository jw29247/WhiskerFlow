// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "WhiskerFlow",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "WhiskerFlow", targets: ["WhiskerFlow"]),
        .library(name: "WhiskerFlowCore", targets: ["WhiskerFlowCore"]),
        .library(name: "WhiskerFlowAppSupport", targets: ["WhiskerFlowAppSupport"])
    ],
    dependencies: [
        // v0.13.0 is the last lightweight release (only swift-transformers);
        // v0.18.0+ pull in Vapor and a web-server monorepo we don't want.
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "0.13.0"),
        // In-app auto-updates (appcast + EdDSA-signed updates). Sparkle ships as a
        // binary XCFramework; `script/bundle_app.sh` embeds & re-signs it.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/getsentry/sentry-cocoa", exact: "9.21.0"),
        // Pin the Swift 5.9-compatible OpenTelemetry release. Declaring the core
        // package explicitly keeps SwiftPM from resolving its 2.x range to a
        // Swift 6-only release.
        .package(
            url: "https://github.com/open-telemetry/opentelemetry-swift.git",
            exact: "2.2.0"
        ),
        .package(
            url: "https://github.com/open-telemetry/opentelemetry-swift-core.git",
            exact: "2.2.0"
        ),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.3")
    ],
    targets: [
        .target(name: "WhiskerFlowCore"),
        .target(
            name: "WhiskerFlowAppSupport",
            dependencies: [
                "WhiskerFlowCore",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"),
                .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
                .product(
                    name: "OpenTelemetryProtocolExporterHTTP",
                    package: "opentelemetry-swift"
                ),
                .product(name: "OTelSwiftLog", package: "opentelemetry-swift")
            ]
        ),
        .executableTarget(
            name: "WhiskerFlow",
            dependencies: [
                "WhiskerFlowCore",
                "WhiskerFlowAppSupport",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Sentry", package: "sentry-cocoa"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"),
                .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core")
            ],
            resources: [.copy("Resources/shared-vocabulary.json")]
        ),
        .testTarget(
            name: "WhiskerFlowCoreTests",
            dependencies: ["WhiskerFlowCore"]
        ),
        .testTarget(
            name: "WhiskerFlowAppSupportTests",
            dependencies: ["WhiskerFlowAppSupport"]
        )
    ]
)
