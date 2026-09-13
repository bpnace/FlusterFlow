// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WhisperFlow",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "FlusterFlow", targets: ["WhisperFlow"]),
        .executable(name: "TextTargetHarness", targets: ["TextTargetHarness"]),
        .executable(name: "PrivacyHarness", targets: ["PrivacyHarness"]),
        .executable(name: "asr-benchmark", targets: ["ASRBenchmarkCLI"])
    ],
    dependencies: [
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
    ],
    targets: [
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
            name: "WhisperFlowTests",
            dependencies: ["WhisperFlow"],
            path: "WhisperFlowTests",
            resources: [
                .copy("../Tests/Fixtures")
            ]
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
    ]
)
