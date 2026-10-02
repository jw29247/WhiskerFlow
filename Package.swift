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
        // Parakeet TDT v3 provides the fast, high-quality on-device default.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.6"),
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
        .target(name: "WhiskerFlowObjCSupport"),
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
                "WhiskerFlowObjCSupport",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Sentry", package: "sentry-cocoa"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"),
                .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core")
            ],
            resources: [.copy("Resources/shared-vocabulary.json")],
            // The on-device coach model ships with macOS 26. Weak-link it so the
            // app still launches on macOS 14 and 15, where the feature is hidden.
            // Translation is weak-linked for the same reason (macOS 15 and later).
            linkerSettings: [.unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels",
                                           "-Xlinker", "-weak_framework", "-Xlinker", "Translation"])]
        ),
        .testTarget(
            name: "WhiskerFlowCoreTests",
            dependencies: ["WhiskerFlowCore"]
        ),
        .testTarget(
            name: "WhiskerFlowAppSupportTests",
            dependencies: ["WhiskerFlowAppSupport"]
        ),
        .testTarget(
            name: "WhiskerFlowTests",
            dependencies: ["WhiskerFlow", "WhiskerFlowObjCSupport", .product(name: "FluidAudio", package: "FluidAudio")]
        )
    ]
)
