// swift-tools-version: 6.0

import Foundation
import PackageDescription

// Xcode builds and tests the app in CI. SwiftPM builds only the independent tools there.
let supportTestsOnly = ProcessInfo.processInfo.environment["FLUSTERFLOW_SUPPORT_TESTS_ONLY"] == "1"

let appDependencies: [Package.Dependency] = [
    .package(
        url: "https://github.com/FluidInference/FluidAudio.git",
        exact: "0.15.5"
    ),
    .package(
        url: "https://github.com/argmaxinc/argmax-oss-swift.git",
        exact: "1.0.0"
    ),
    .package(
        url: "https://github.com/Blaizzy/mlx-audio-swift.git",
        exact: "0.1.3"
    ),
    .package(
        url: "https://github.com/ml-explore/mlx-swift.git",
        exact: "0.31.4"
    )
]

let appTargets: [Target] = [
    .executableTarget(
        name: "WhisperFlow",
        dependencies: [
            .product(name: "FluidAudio", package: "FluidAudio"),
            .product(name: "WhisperKit", package: "argmax-oss-swift"),
            .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
            .product(name: "MLX", package: "mlx-swift")
        ],
        path: "WhisperFlow",
        exclude: ["WhisperFlow.entitlements"]
    ),
    .testTarget(
        name: "WhisperFlowTests",
        dependencies: ["WhisperFlow"],
        path: "WhisperFlowTests",
        resources: [
            .copy("../Tests/Fixtures")
        ]
    )
]

let package = Package(
    name: "WhisperFlow",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "TextTargetHarness", targets: ["TextTargetHarness"]),
        .executable(name: "PrivacyHarness", targets: ["PrivacyHarness"]),
        .executable(name: "asr-benchmark", targets: ["ASRBenchmarkCLI"])
    ] + (supportTestsOnly ? [] : [.executable(name: "FlusterFlow", targets: ["WhisperFlow"])]),
    dependencies: supportTestsOnly ? [] : appDependencies,
    targets: [
        .target(
            name: "TextTargetHarnessCore",
            path: "TestSupport/TextTargetHarness/Core"
        ),
        .executableTarget(
            name: "TextTargetHarness",
            dependencies: ["TextTargetHarnessCore"],
            path: "TestSupport/TextTargetHarness/App"
        ),
        .target(
            name: "PrivacyHarnessCore",
            path: "TestSupport/PrivacyHarness/Core"
        ),
        .executableTarget(
            name: "PrivacyHarness",
            dependencies: ["PrivacyHarnessCore"],
            path: "TestSupport/PrivacyHarness/App"
        ),
        .target(
            name: "ASRBenchmarkCore",
            path: "TestSupport/ASRBenchmark"
        ),
        .executableTarget(
            name: "ASRBenchmarkCLI",
            dependencies: ["ASRBenchmarkCore"],
            path: "Tools/ASRBenchmark"
        ),
        .testTarget(
            name: "TextTargetHarnessTests",
            dependencies: ["TextTargetHarnessCore"],
            path: "TestSupport/TextTargetHarness/Tests",
            resources: [
                .copy("../scenarios.json")
            ]
        ),
        .testTarget(
            name: "PrivacyHarnessTests",
            dependencies: ["PrivacyHarnessCore"],
            path: "TestSupport/PrivacyHarness/Tests"
        ),
        .testTarget(
            name: "ASRBenchmarkTests",
            dependencies: ["ASRBenchmarkCore"],
            path: "Tests/ASRBenchmarkTests",
            resources: [
                .copy("../Fixtures/ASR")
            ]
        )
    ] + (supportTestsOnly ? [] : appTargets)
)
