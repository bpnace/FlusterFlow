import Foundation
import OSLog

enum DiagnosticStage: String, CaseIterable, Codable, Sendable {
    case audioFinalize
    case asr
    case cleanup
    case cloud
    case insertion
    case total

    static let requiredPipelineStages: [Self] = allCases
}

enum DiagnosticState: String, Codable, Sendable {
    case started
    case completed
    case cancelled
    case failed
}

enum DiagnosticErrorCode: String, Codable, Sendable {
    case permissionDenied
    case unavailable
    case staleSession
    case deviceChanged
    case serviceFailure
    case unconfirmedMutation
}

struct StageMetricAggregate: Equatable, Codable, Sendable {
    let stage: DiagnosticStage
    let sampleCount: Int
    let averageMilliseconds: Double
    let maximumMilliseconds: Double
    let p50Milliseconds: Double
    let p95Milliseconds: Double

    init(
        stage: DiagnosticStage,
        sampleCount: Int,
        averageMilliseconds: Double,
        maximumMilliseconds: Double,
        p50Milliseconds: Double? = nil,
        p95Milliseconds: Double? = nil
    ) {
        self.stage = stage
        self.sampleCount = sampleCount
        self.averageMilliseconds = averageMilliseconds
        self.maximumMilliseconds = maximumMilliseconds
        self.p50Milliseconds = p50Milliseconds ?? averageMilliseconds
        self.p95Milliseconds = p95Milliseconds ?? maximumMilliseconds
    }
}

enum DiagnosticASRModel: String, Codable, Sendable {
    case parakeetV3Int8
    case qwen3ASR06B8Bit
    case whisperKitLargeV3
    case whisperKitLargeV3Turbo
    case adaptiveWhisperKit
}

enum DiagnosticASRDurationClass: String, Codable, Sendable {
    case short
    case medium
    case long
}

enum DiagnosticProcessedAudioClass: String, Sendable {
    case subsecond
    case oneToThreeSeconds
    case threeToTenSeconds
    case overTenSeconds
}

enum DiagnosticSpeechRatioClass: String, Sendable {
    case low
    case medium
    case high
}

enum DiagnosticGainClass: String, Sendable {
    case none
    case moderate
    case high
}

enum DiagnosticSignalLevelClass: String, Sendable {
    case silent
    case veryLow
    case low
    case usable
    case high
}

enum DiagnosticPeakClass: String, Sendable {
    case low
    case usable
    case nearClipping
    case clipped
}

enum DiagnosticASRTemperatureClass: String, Codable, Sendable {
    case cold
    case warm
}

enum DiagnosticASRConfidenceClass: String, Codable, CaseIterable, Sendable {
    case high
    case medium
    case low
    case unknown
}

struct DiagnosticLatencyAggregate: Equatable, Codable, Sendable {
    let sampleCount: Int
    let p50Milliseconds: Double?
    let p95Milliseconds: Double?
    let maximumMilliseconds: Double?
}

struct ASRRuntimeAggregateKey: Equatable, Hashable, Codable, Sendable {
    let model: DiagnosticASRModel
    let durationClass: DiagnosticASRDurationClass
    let temperatureClass: DiagnosticASRTemperatureClass
}

struct ASRRuntimeAggregate: Equatable, Codable, Sendable {
    let key: ASRRuntimeAggregateKey
    let sampleCount: Int
    let confidenceClassCounts: [String: Int]
    let adaptiveFallbackCount: Int
    let adaptiveFallbackRate: Double
    let prewarmAttemptCount: Int
    let prewarmSuccessRate: Double?
    let vadSpeechDetectedCount: Int
    let vadSpeechDetectedRate: Double?
    let prewarmLatency: DiagnosticLatencyAggregate
    let vadLatency: DiagnosticLatencyAggregate
    let asrLatency: DiagnosticLatencyAggregate
    let endToInsertLatency: DiagnosticLatencyAggregate
    let peakRSSBytes: Int64

    init(
        key: ASRRuntimeAggregateKey,
        sampleCount: Int,
        confidenceClassCounts: [String: Int],
        adaptiveFallbackCount: Int,
        adaptiveFallbackRate: Double,
        prewarmAttemptCount: Int,
        prewarmSuccessRate: Double?,
        vadSpeechDetectedCount: Int,
        vadSpeechDetectedRate: Double?,
        prewarmLatency: DiagnosticLatencyAggregate = DiagnosticLatencyAggregate(
            sampleCount: 0,
            p50Milliseconds: nil,
            p95Milliseconds: nil,
            maximumMilliseconds: nil
        ),
        vadLatency: DiagnosticLatencyAggregate = DiagnosticLatencyAggregate(
            sampleCount: 0,
            p50Milliseconds: nil,
            p95Milliseconds: nil,
            maximumMilliseconds: nil
        ),
        asrLatency: DiagnosticLatencyAggregate,
        endToInsertLatency: DiagnosticLatencyAggregate,
        peakRSSBytes: Int64
    ) {
        self.key = key
        self.sampleCount = sampleCount
        self.confidenceClassCounts = confidenceClassCounts
        self.adaptiveFallbackCount = adaptiveFallbackCount
        self.adaptiveFallbackRate = adaptiveFallbackRate
        self.prewarmAttemptCount = prewarmAttemptCount
        self.prewarmSuccessRate = prewarmSuccessRate
        self.vadSpeechDetectedCount = vadSpeechDetectedCount
        self.vadSpeechDetectedRate = vadSpeechDetectedRate
        self.prewarmLatency = prewarmLatency
        self.vadLatency = vadLatency
        self.asrLatency = asrLatency
        self.endToInsertLatency = endToInsertLatency
        self.peakRSSBytes = peakRSSBytes
    }
}

enum DiagnosticRewriteOutcome: String, Codable, Sendable {
    case accepted
    case rejected
    case unavailable
    case failed
    case cancelled
}

enum DiagnosticRewriteReason: String, Codable, Sendable {
    case none
    case frameworkUnavailable
    case operatingSystemUnsupported
    case modelUnavailable
    case unsupportedLanguage
    case sensitiveContextDenied
    case invalidModelOutput
    case generationFailed
    case lostProtectedAnchor
    case lostProtectedContextTerm
    case inventedClaim
    case excessiveDeviation
    case unknownMeaningChange
    case multipleValidationIssues
}

enum DiagnosticRewriteOutputLengthClass: String, Codable, Sendable {
    case empty
    case short
    case medium
    case long
}

struct RewriteRuntimeAggregateKey: Equatable, Hashable, Codable, Sendable {
    let rewriter: String
    let outcome: DiagnosticRewriteOutcome
    let reason: DiagnosticRewriteReason
    let outputLengthClass: DiagnosticRewriteOutputLengthClass
}

struct RewriteRuntimeAggregate: Equatable, Codable, Sendable {
    let key: RewriteRuntimeAggregateKey
    let sampleCount: Int
    let sanitizerActionCount: Int
    let latency: DiagnosticLatencyAggregate
}

struct DiagnosticsV2Report: Equatable, Codable, Sendable {
    let schemaVersion: Int
    let pipelineStages: [StageMetricAggregate]
    let asrRuntime: [ASRRuntimeAggregate]
    let rewriteRuntime: [RewriteRuntimeAggregate]

    init(
        pipelineStages: [StageMetricAggregate],
        asrRuntime: [ASRRuntimeAggregate],
        rewriteRuntime: [RewriteRuntimeAggregate] = []
    ) {
        schemaVersion = 3
        self.pipelineStages = pipelineStages
        self.asrRuntime = asrRuntime
        self.rewriteRuntime = rewriteRuntime
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case pipelineStages
        case asrRuntime
        case rewriteRuntime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 2
        pipelineStages = try container.decodeIfPresent(
            [StageMetricAggregate].self,
            forKey: .pipelineStages
        ) ?? []
        asrRuntime = try container.decodeIfPresent(
            [ASRRuntimeAggregate].self,
            forKey: .asrRuntime
        ) ?? []
        rewriteRuntime = try container.decodeIfPresent(
            [RewriteRuntimeAggregate].self,
            forKey: .rewriteRuntime
        ) ?? []
    }

    func merging(_ newer: DiagnosticsV2Report) -> DiagnosticsV2Report {
        let mergedStages = Dictionary(grouping: pipelineStages + newer.pipelineStages, by: \.stage)
            .map { stage, values in
                let total = values.reduce(0) { $0 + $1.sampleCount }
                return StageMetricAggregate(
                    stage: stage,
                    sampleCount: total,
                    averageMilliseconds: Self.weighted(
                        values.map { ($0.averageMilliseconds, $0.sampleCount) }
                    ) ?? 0,
                    maximumMilliseconds: values.map(\.maximumMilliseconds).max() ?? 0,
                    p50Milliseconds: Self.weighted(
                        values.map { ($0.p50Milliseconds, $0.sampleCount) }
                    ),
                    p95Milliseconds: Self.weighted(
                        values.map { ($0.p95Milliseconds, $0.sampleCount) }
                    )
                )
            }
            .sorted { $0.stage.rawValue < $1.stage.rawValue }

        let mergedASR = Dictionary(grouping: asrRuntime + newer.asrRuntime, by: \.key)
            .map { key, values in
                let sampleCount = values.reduce(0) { $0 + $1.sampleCount }
                let fallbackCount = values.reduce(0) { $0 + $1.adaptiveFallbackCount }
                let prewarmAttempts = values.reduce(0) { $0 + $1.prewarmAttemptCount }
                let prewarmSuccesses = values.reduce(Double(0)) { partial, value in
                    partial + (value.prewarmSuccessRate ?? 0) * Double(value.prewarmAttemptCount)
                }
                let vadKnownCount = values.reduce(0) { partial, value in
                    partial + (value.vadSpeechDetectedRate == nil ? 0 : value.sampleCount)
                }
                let vadDetected = values.reduce(0) { $0 + $1.vadSpeechDetectedCount }
                var confidenceCounts: [String: Int] = [:]
                for value in values {
                    for (confidence, count) in value.confidenceClassCounts {
                        confidenceCounts[confidence, default: 0] += count
                    }
                }
                return ASRRuntimeAggregate(
                    key: key,
                    sampleCount: sampleCount,
                    confidenceClassCounts: confidenceCounts,
                    adaptiveFallbackCount: fallbackCount,
                    adaptiveFallbackRate: sampleCount == 0
                        ? 0
                        : Double(fallbackCount) / Double(sampleCount),
                    prewarmAttemptCount: prewarmAttempts,
                    prewarmSuccessRate: prewarmAttempts == 0
                        ? nil
                        : prewarmSuccesses / Double(prewarmAttempts),
                    vadSpeechDetectedCount: vadDetected,
                    vadSpeechDetectedRate: vadKnownCount == 0
                        ? nil
                        : Double(vadDetected) / Double(vadKnownCount),
                    prewarmLatency: Self.mergeLatency(values.map(\.prewarmLatency)),
                    vadLatency: Self.mergeLatency(values.map(\.vadLatency)),
                    asrLatency: Self.mergeLatency(values.map(\.asrLatency)),
                    endToInsertLatency: Self.mergeLatency(values.map(\.endToInsertLatency)),
                    peakRSSBytes: values.map(\.peakRSSBytes).max() ?? 0
                )
            }
            .sorted {
                if $0.key.model != $1.key.model {
                    return $0.key.model.rawValue < $1.key.model.rawValue
                }
                if $0.key.durationClass != $1.key.durationClass {
                    return $0.key.durationClass.rawValue < $1.key.durationClass.rawValue
                }
                return $0.key.temperatureClass.rawValue < $1.key.temperatureClass.rawValue
            }
        let mergedRewrite = Dictionary(grouping: rewriteRuntime + newer.rewriteRuntime, by: \.key)
            .map { key, values in
                RewriteRuntimeAggregate(
                    key: key,
                    sampleCount: values.reduce(0) { $0 + $1.sampleCount },
                    sanitizerActionCount: values.reduce(0) { $0 + $1.sanitizerActionCount },
                    latency: Self.mergeLatency(values.map(\.latency))
                )
            }
            .sorted {
                if $0.key.rewriter != $1.key.rewriter {
                    return $0.key.rewriter < $1.key.rewriter
                }
                if $0.key.outcome != $1.key.outcome {
                    return $0.key.outcome.rawValue < $1.key.outcome.rawValue
                }
                if $0.key.reason != $1.key.reason {
                    return $0.key.reason.rawValue < $1.key.reason.rawValue
                }
                return $0.key.outputLengthClass.rawValue < $1.key.outputLengthClass.rawValue
            }
        return DiagnosticsV2Report(
            pipelineStages: mergedStages,
            asrRuntime: mergedASR,
            rewriteRuntime: mergedRewrite
        )
    }

    private static func mergeLatency(
        _ values: [DiagnosticLatencyAggregate]
    ) -> DiagnosticLatencyAggregate {
        DiagnosticLatencyAggregate(
            sampleCount: values.reduce(0) { $0 + $1.sampleCount },
            p50Milliseconds: weighted(
                values.compactMap { value in
                    value.p50Milliseconds.map { ($0, value.sampleCount) }
                }
            ),
            p95Milliseconds: weighted(
                values.compactMap { value in
                    value.p95Milliseconds.map { ($0, value.sampleCount) }
                }
            ),
            maximumMilliseconds: values.compactMap(\.maximumMilliseconds).max()
        )
    }

    private static func weighted(_ values: [(Double, Int)]) -> Double? {
        let totalWeight = values.reduce(0) { $0 + max(0, $1.1) }
        guard totalWeight > 0 else { return nil }
        let total = values.reduce(Double(0)) {
            $0 + ($1.0 * Double(max(0, $1.1)))
        }
        return total / Double(totalWeight)
    }
}

struct DiagnosticsV2AggregateStore: Sendable {
    enum StoreError: Error, Equatable, Sendable {
        case unsafeFileName
        case encodedReportTooLarge
    }

    let directory: URL
    let fileName: String
    let maximumEncodedBytes: Int

    init(
        directory: URL,
        fileName: String = "diagnostics-v2-aggregates.json",
        maximumEncodedBytes: Int = 256 * 1024
    ) {
        self.directory = directory
        self.fileName = fileName
        self.maximumEncodedBytes = maximumEncodedBytes
    }

    func load() throws -> DiagnosticsV2Report? {
        let url = try reportURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(DiagnosticsV2Report.self, from: Data(contentsOf: url))
    }

    func save(_ report: DiagnosticsV2Report) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(report)
        guard data.count <= maximumEncodedBytes else {
            throw StoreError.encodedReportTooLarge
        }
        try data.write(to: try reportURL(), options: .atomic)
    }

    func remove() throws {
        let url = try reportURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func reportURL() throws -> URL {
        guard isSafeDiagnosticFileName(fileName) else { throw StoreError.unsafeFileName }
        return directory.appendingPathComponent(fileName, isDirectory: false)
    }
}

private func isSafeDiagnosticFileName(_ name: String) -> Bool {
    !name.isEmpty
        && !name.contains("/")
        && !name.contains("\\")
        && name != "."
        && name != ".."
}

private struct ASRRuntimeSample: Sendable {
    let key: ASRRuntimeAggregateKey
    let confidenceClass: DiagnosticASRConfidenceClass
    let usedAdaptiveFallback: Bool
    let prewarmSucceeded: Bool?
    let prewarmLatencyMilliseconds: Double?
    let vadSpeechDetected: Bool?
    let vadLatencyMilliseconds: Double?
    let asrLatencyMilliseconds: Double
    let endToInsertMilliseconds: Double?
    let peakRSSBytes: Int64
}

actor ASRRuntimeAggregateRecorder {
    private let maximumSamples: Int
    private var samples: [ASRRuntimeSample] = []

    init(maximumSamples: Int = 512) {
        self.maximumSamples = max(1, maximumSamples)
    }

    func record(
        model: DiagnosticASRModel,
        durationClass: DiagnosticASRDurationClass,
        temperatureClass: DiagnosticASRTemperatureClass,
        confidenceClass: DiagnosticASRConfidenceClass,
        usedAdaptiveFallback: Bool,
        prewarmSucceeded: Bool?,
        prewarmLatencyMilliseconds: Double? = nil,
        vadSpeechDetected: Bool?,
        vadLatencyMilliseconds: Double? = nil,
        asrLatencyMilliseconds: Double,
        endToInsertMilliseconds: Double?,
        peakRSSBytes: Int64
    ) {
        guard asrLatencyMilliseconds.isFinite,
              asrLatencyMilliseconds >= 0,
              peakRSSBytes >= 0 else { return }
        if let endToInsertMilliseconds,
           (!endToInsertMilliseconds.isFinite || endToInsertMilliseconds < 0) {
            return
        }
        if let prewarmLatencyMilliseconds,
           (!prewarmLatencyMilliseconds.isFinite || prewarmLatencyMilliseconds < 0) {
            return
        }
        if let vadLatencyMilliseconds,
           (!vadLatencyMilliseconds.isFinite || vadLatencyMilliseconds < 0) {
            return
        }
        samples.append(
            ASRRuntimeSample(
                key: ASRRuntimeAggregateKey(
                    model: model,
                    durationClass: durationClass,
                    temperatureClass: temperatureClass
                ),
                confidenceClass: confidenceClass,
                usedAdaptiveFallback: usedAdaptiveFallback,
                prewarmSucceeded: prewarmSucceeded,
                prewarmLatencyMilliseconds: prewarmLatencyMilliseconds,
                vadSpeechDetected: vadSpeechDetected,
                vadLatencyMilliseconds: vadLatencyMilliseconds,
                asrLatencyMilliseconds: asrLatencyMilliseconds,
                endToInsertMilliseconds: endToInsertMilliseconds,
                peakRSSBytes: peakRSSBytes
            )
        )
        if samples.count > maximumSamples {
            samples.removeFirst(samples.count - maximumSamples)
        }
    }

    func aggregates() -> [ASRRuntimeAggregate] {
        Dictionary(grouping: samples, by: \.key)
            .map { key, samples in
                let confidenceCounts = Dictionary(
                    grouping: samples,
                    by: \.confidenceClass
                ).reduce(into: [String: Int]()) { result, item in
                    result[item.key.rawValue] = item.value.count
                }
                let prewarm = samples.compactMap(\.prewarmSucceeded)
                let vad = samples.compactMap(\.vadSpeechDetected)
                let adaptiveFallbackCount = samples.filter(\.usedAdaptiveFallback).count
                return ASRRuntimeAggregate(
                    key: key,
                    sampleCount: samples.count,
                    confidenceClassCounts: confidenceCounts,
                    adaptiveFallbackCount: adaptiveFallbackCount,
                    adaptiveFallbackRate: Double(adaptiveFallbackCount) / Double(samples.count),
                    prewarmAttemptCount: prewarm.count,
                    prewarmSuccessRate: rate(prewarm),
                    vadSpeechDetectedCount: vad.filter { $0 }.count,
                    vadSpeechDetectedRate: rate(vad),
                    prewarmLatency: Self.summarize(
                        samples.compactMap(\.prewarmLatencyMilliseconds)
                    ),
                    vadLatency: Self.summarize(
                        samples.compactMap(\.vadLatencyMilliseconds)
                    ),
                    asrLatency: Self.summarize(samples.map(\.asrLatencyMilliseconds)),
                    endToInsertLatency: Self.summarize(samples.compactMap(\.endToInsertMilliseconds)),
                    peakRSSBytes: samples.map(\.peakRSSBytes).max() ?? 0
                )
            }
            .sorted {
                if $0.key.model != $1.key.model { return $0.key.model.rawValue < $1.key.model.rawValue }
                if $0.key.durationClass != $1.key.durationClass {
                    return $0.key.durationClass.rawValue < $1.key.durationClass.rawValue
                }
                return $0.key.temperatureClass.rawValue < $1.key.temperatureClass.rawValue
            }
    }

    func reset() {
        samples.removeAll(keepingCapacity: false)
    }

    private static func summarize(_ values: [Double]) -> DiagnosticLatencyAggregate {
        let sorted = values.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard !sorted.isEmpty else {
            return DiagnosticLatencyAggregate(
                sampleCount: 0,
                p50Milliseconds: nil,
                p95Milliseconds: nil,
                maximumMilliseconds: nil
            )
        }
        return DiagnosticLatencyAggregate(
            sampleCount: sorted.count,
            p50Milliseconds: nearestRank(0.50, values: sorted),
            p95Milliseconds: nearestRank(0.95, values: sorted),
            maximumMilliseconds: sorted.last
        )
    }

    private static func nearestRank(_ percentile: Double, values: [Double]) -> Double {
        let rank = max(1, Int(ceil(percentile * Double(values.count))))
        return values[min(rank - 1, values.count - 1)]
    }
}

private struct RewriteRuntimeSample: Sendable {
    let key: RewriteRuntimeAggregateKey
    let latencyMilliseconds: Double
    let sanitizerActionCount: Int
}

actor RewriteRuntimeAggregateRecorder {
    private let maximumSamples: Int
    private var samples: [RewriteRuntimeSample] = []

    init(maximumSamples: Int = 512) {
        self.maximumSamples = max(1, maximumSamples)
    }

    func record(
        rewriter: TextRewriterIdentifier,
        outcome: DiagnosticRewriteOutcome,
        reason: DiagnosticRewriteReason,
        outputLengthClass: DiagnosticRewriteOutputLengthClass,
        latencyMilliseconds: Double,
        sanitizerActionCount: Int = 0
    ) {
        guard latencyMilliseconds.isFinite,
              latencyMilliseconds >= 0,
              sanitizerActionCount >= 0 else { return }
        samples.append(
            RewriteRuntimeSample(
                key: RewriteRuntimeAggregateKey(
                    rewriter: rewriter.rawValue,
                    outcome: outcome,
                    reason: reason,
                    outputLengthClass: outputLengthClass
                ),
                latencyMilliseconds: latencyMilliseconds,
                sanitizerActionCount: sanitizerActionCount
            )
        )
        if samples.count > maximumSamples {
            samples.removeFirst(samples.count - maximumSamples)
        }
    }

    func aggregates() -> [RewriteRuntimeAggregate] {
        Dictionary(grouping: samples, by: \.key)
            .map { key, samples in
                RewriteRuntimeAggregate(
                    key: key,
                    sampleCount: samples.count,
                    sanitizerActionCount: samples.reduce(0) { $0 + $1.sanitizerActionCount },
                    latency: Self.summarize(samples.map(\.latencyMilliseconds))
                )
            }
            .sorted {
                if $0.key.rewriter != $1.key.rewriter {
                    return $0.key.rewriter < $1.key.rewriter
                }
                if $0.key.outcome != $1.key.outcome {
                    return $0.key.outcome.rawValue < $1.key.outcome.rawValue
                }
                if $0.key.reason != $1.key.reason {
                    return $0.key.reason.rawValue < $1.key.reason.rawValue
                }
                return $0.key.outputLengthClass.rawValue < $1.key.outputLengthClass.rawValue
            }
    }

    func reset() {
        samples.removeAll(keepingCapacity: false)
    }

    private static func summarize(_ values: [Double]) -> DiagnosticLatencyAggregate {
        let sorted = values.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard !sorted.isEmpty else {
            return DiagnosticLatencyAggregate(
                sampleCount: 0,
                p50Milliseconds: nil,
                p95Milliseconds: nil,
                maximumMilliseconds: nil
            )
        }
        return DiagnosticLatencyAggregate(
            sampleCount: sorted.count,
            p50Milliseconds: nearestRank(0.50, values: sorted),
            p95Milliseconds: nearestRank(0.95, values: sorted),
            maximumMilliseconds: sorted.last
        )
    }

    private static func nearestRank(_ percentile: Double, values: [Double]) -> Double {
        let rank = max(1, Int(ceil(percentile * Double(values.count))))
        return values[min(rank - 1, values.count - 1)]
    }
}

private func rate(_ samples: [Bool]) -> Double? {
    guard !samples.isEmpty else { return nil }
    return Double(samples.filter { $0 }.count) / Double(samples.count)
}

/// Process-local trace data. This deliberately is not `Codable` so session
/// association and monotonic timestamps cannot enter diagnostics exports.
struct StageMetricSample: Equatable, Sendable {
    let sequence: UInt64
    let sessionID: DictationSessionID
    let stage: DiagnosticStage
    let startedAt: Duration
    let endedAt: Duration

    var durationMilliseconds: Double {
        (endedAt - startedAt).diagnosticMilliseconds
    }
}

struct StageMetricMeasurement: Sendable {
    fileprivate let sessionID: DictationSessionID
    fileprivate let stage: DiagnosticStage
    fileprivate let startedAt: Duration
}

actor StageMetricRecorder {
    private let maximumSamplesPerStage: Int
    private let clock: ContinuousClock
    private let origin: ContinuousClock.Instant
    private var samplesByStage: [DiagnosticStage: [StageMetricSample]] = [:]
    private var nextSequence: UInt64 = 0

    init(maximumSamplesPerStage: Int = 256) {
        self.maximumSamplesPerStage = max(1, maximumSamplesPerStage)
        let clock = ContinuousClock()
        self.clock = clock
        origin = clock.now
    }

    func begin(
        stage: DiagnosticStage,
        sessionID: DictationSessionID
    ) -> StageMetricMeasurement {
        StageMetricMeasurement(
            sessionID: sessionID,
            stage: stage,
            startedAt: timestamp()
        )
    }

    @discardableResult
    func finish(_ measurement: StageMetricMeasurement) -> StageMetricSample {
        append(
            stage: measurement.stage,
            sessionID: measurement.sessionID,
            startedAt: measurement.startedAt,
            endedAt: max(measurement.startedAt, timestamp())
        )
    }

    @discardableResult
    func record(
        stage: DiagnosticStage,
        sessionID: DictationSessionID,
        startedAt: Duration,
        endedAt: Duration
    ) -> StageMetricSample? {
        guard startedAt >= .zero, endedAt >= startedAt else { return nil }
        return append(
            stage: stage,
            sessionID: sessionID,
            startedAt: startedAt,
            endedAt: endedAt
        )
    }

    func samples(
        for sessionID: DictationSessionID? = nil
    ) -> [StageMetricSample] {
        samplesByStage.values
            .flatMap { $0 }
            .filter { sample in
                sessionID.map { sample.sessionID == $0 } ?? true
            }
            .sorted { lhs, rhs in
                if lhs.startedAt != rhs.startedAt {
                    return lhs.startedAt < rhs.startedAt
                }
                if lhs.endedAt != rhs.endedAt {
                    return lhs.endedAt < rhs.endedAt
                }
                return lhs.sequence < rhs.sequence
            }
    }

    private func append(
        stage: DiagnosticStage,
        sessionID: DictationSessionID,
        startedAt: Duration,
        endedAt: Duration
    ) -> StageMetricSample {
        nextSequence &+= 1
        let sample = StageMetricSample(
            sequence: nextSequence,
            sessionID: sessionID,
            stage: stage,
            startedAt: startedAt,
            endedAt: endedAt
        )
        var stageSamples = samplesByStage[stage, default: []]
        stageSamples.append(sample)
        if stageSamples.count > maximumSamplesPerStage {
            stageSamples.removeFirst(stageSamples.count - maximumSamplesPerStage)
        }
        samplesByStage[stage] = stageSamples
        return sample
    }

    func aggregates() -> [StageMetricAggregate] {
        DiagnosticStage.allCases.compactMap { stage in
            guard let stageSamples = samplesByStage[stage], !stageSamples.isEmpty else {
                return nil
            }
            let durations = stageSamples.map(\.durationMilliseconds)
            return StageMetricAggregate(
                stage: stage,
                sampleCount: durations.count,
                averageMilliseconds: durations.reduce(0, +) / Double(durations.count),
                maximumMilliseconds: durations.max() ?? 0,
                p50Milliseconds: Self.median(durations),
                p95Milliseconds: Self.nearestRankPercentile(durations, percentile: 0.95)
            )
        }
    }

    func reset() {
        samplesByStage.removeAll(keepingCapacity: false)
        nextSequence = 0
    }

    private func timestamp() -> Duration {
        max(.zero, origin.duration(to: clock.now))
    }

    private static func median(_ samples: [Double]) -> Double {
        let sorted = samples.sorted()
        let midpoint = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[midpoint - 1] + sorted[midpoint]) / 2
        }
        return sorted[midpoint]
    }

    private static func nearestRankPercentile(
        _ samples: [Double],
        percentile: Double
    ) -> Double {
        let sorted = samples.sorted()
        let rank = max(1, Int(ceil(percentile * Double(sorted.count))))
        return sorted[min(rank - 1, sorted.count - 1)]
    }
}

struct ContentFreeDiagnostics: Sendable {
    let metrics: StageMetricRecorder
    let asrRuntime: ASRRuntimeAggregateRecorder
    let rewriteRuntime: RewriteRuntimeAggregateRecorder

    private let logger = Logger(
        subsystem: "local.flusterflow",
        category: "dictation"
    )

    init(
        metrics: StageMetricRecorder = StageMetricRecorder(),
        asrRuntime: ASRRuntimeAggregateRecorder = ASRRuntimeAggregateRecorder(),
        rewriteRuntime: RewriteRuntimeAggregateRecorder = RewriteRuntimeAggregateRecorder()
    ) {
        self.metrics = metrics
        self.asrRuntime = asrRuntime
        self.rewriteRuntime = rewriteRuntime
    }

    func state(
        _ state: DiagnosticState,
        stage: DiagnosticStage,
        sessionID _: DictationSessionID
    ) {
        logger.info(
            "stage=\(stage.rawValue, privacy: .public) state=\(state.rawValue, privacy: .public)"
        )
    }

    func failure(
        _ code: DiagnosticErrorCode,
        stage: DiagnosticStage,
        sessionID _: DictationSessionID
    ) {
        logger.error(
            "stage=\(stage.rawValue, privacy: .public) code=\(code.rawValue, privacy: .public)"
        )
    }

    func audioCaptureSummary(
        speechDetected: Bool,
        durationClass: DiagnosticASRDurationClass,
        processedClass: DiagnosticProcessedAudioClass,
        speechRatioClass: DiagnosticSpeechRatioClass,
        gainClass: DiagnosticGainClass,
        inputSignalClass: DiagnosticSignalLevelClass,
        normalizedSignalClass: DiagnosticSignalLevelClass,
        normalizedPeakClass: DiagnosticPeakClass,
        sessionID _: DictationSessionID
    ) {
        logger.notice(
            "stage=audioFinalize speech_detected=\(speechDetected, privacy: .public) duration_class=\(durationClass.rawValue, privacy: .public) processed_class=\(processedClass.rawValue, privacy: .public) speech_ratio=\(speechRatioClass.rawValue, privacy: .public) gain_class=\(gainClass.rawValue, privacy: .public) input_signal=\(inputSignalClass.rawValue, privacy: .public) normalized_signal=\(normalizedSignalClass.rawValue, privacy: .public) normalized_peak=\(normalizedPeakClass.rawValue, privacy: .public)"
        )
    }

    func measure<Value: Sendable>(
        stage: DiagnosticStage,
        sessionID: DictationSessionID,
        operation: @Sendable () async throws -> Value
    ) async rethrows -> Value {
        let measurement = await metrics.begin(stage: stage, sessionID: sessionID)
        do {
            let value = try await operation()
            await finish(measurement)
            return value
        } catch {
            await finish(measurement)
            throw error
        }
    }

    func recordASRRuntime(
        model: DiagnosticASRModel,
        durationClass: DiagnosticASRDurationClass,
        temperatureClass: DiagnosticASRTemperatureClass,
        confidenceClass: DiagnosticASRConfidenceClass,
        usedAdaptiveFallback: Bool,
        prewarmSucceeded: Bool?,
        prewarmLatencyMilliseconds: Double? = nil,
        vadSpeechDetected: Bool?,
        vadLatencyMilliseconds: Double? = nil,
        asrLatencyMilliseconds: Double,
        endToInsertMilliseconds: Double?,
        peakRSSBytes: Int64
    ) async {
        await asrRuntime.record(
            model: model,
            durationClass: durationClass,
            temperatureClass: temperatureClass,
            confidenceClass: confidenceClass,
            usedAdaptiveFallback: usedAdaptiveFallback,
            prewarmSucceeded: prewarmSucceeded,
            prewarmLatencyMilliseconds: prewarmLatencyMilliseconds,
            vadSpeechDetected: vadSpeechDetected,
            vadLatencyMilliseconds: vadLatencyMilliseconds,
            asrLatencyMilliseconds: asrLatencyMilliseconds,
            endToInsertMilliseconds: endToInsertMilliseconds,
            peakRSSBytes: peakRSSBytes
        )
    }

    func recordRewriteRuntime(
        rewriter: TextRewriterIdentifier,
        outcome: DiagnosticRewriteOutcome,
        reason: DiagnosticRewriteReason,
        outputLengthClass: DiagnosticRewriteOutputLengthClass,
        latencyMilliseconds: Double,
        sanitizerActionCount: Int = 0
    ) async {
        await rewriteRuntime.record(
            rewriter: rewriter,
            outcome: outcome,
            reason: reason,
            outputLengthClass: outputLengthClass,
            latencyMilliseconds: latencyMilliseconds,
            sanitizerActionCount: sanitizerActionCount
        )
    }

    func reportV2() async -> DiagnosticsV2Report {
        DiagnosticsV2Report(
            pipelineStages: await metrics.aggregates(),
            asrRuntime: await asrRuntime.aggregates(),
            rewriteRuntime: await rewriteRuntime.aggregates()
        )
    }

    private func finish(_ measurement: StageMetricMeasurement) async {
        let sample = await metrics.finish(measurement)
        logger.info(
            "stage=\(sample.stage.rawValue, privacy: .public) duration_ms=\(sample.durationMilliseconds, privacy: .public)"
        )
    }
}

private extension Duration {
    var diagnosticMilliseconds: Double {
        let components = self.components
        return (Double(components.seconds) * 1_000)
            + (Double(components.attoseconds) / 1_000_000_000_000_000)
    }
}
