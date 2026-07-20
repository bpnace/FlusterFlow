import Foundation

public enum ASRBenchmarkBackendID: String, Codable, CaseIterable, Sendable {
    case qwen = "qwen"
    case turbo = "turbo"
    case largeV3 = "large-v3"
    case parakeet = "parakeet"
    case adaptive = "adaptive"
}

public enum RuntimeTemperatureClass: String, Codable, Sendable {
    case cold
    case warm
}

public enum RuntimeDurationClass: String, Codable, Sendable {
    case short
    case medium
    case long

    public static func classify(seconds: Double) -> Self {
        if seconds < 5 { return .short }
        if seconds <= 15 { return .medium }
        return .long
    }
}

public enum RuntimeConfidenceClass: String, Codable, Sendable {
    case high
    case medium
    case low
    case unknown
}

public struct BackendCommandConfiguration: Codable, Equatable, Sendable {
    public let backendID: ASRBenchmarkBackendID
    public let executable: String
    public let fixedArguments: [String]

    public init(
        backendID: ASRBenchmarkBackendID,
        executable: String,
        fixedArguments: [String] = []
    ) {
        self.backendID = backendID
        self.executable = executable
        self.fixedArguments = fixedArguments
    }
}

public struct BackendRunRequest: Equatable, Sendable {
    public let backendID: ASRBenchmarkBackendID
    public let executable: String
    public let arguments: [String]
    public let clipAssetPath: String
    public let scheduleOrdinal: Int
    public let phase: TrialPhase

    public init(
        backendID: ASRBenchmarkBackendID,
        executable: String,
        arguments: [String],
        clipAssetPath: String,
        scheduleOrdinal: Int,
        phase: TrialPhase
    ) {
        self.backendID = backendID
        self.executable = executable
        self.arguments = arguments
        self.clipAssetPath = clipAssetPath
        self.scheduleOrdinal = scheduleOrdinal
        self.phase = phase
    }
}

public struct BackendRunResult: Codable, Equatable, Sendable {
    public let confidenceClass: RuntimeConfidenceClass
    public let usedAdaptiveFallback: Bool
    public let prewarmSucceeded: Bool?
    public let vadSpeechDetected: Bool?
    public let quality: PersonalQualityCounts
    public let asrLatencyMilliseconds: Double
    public let endToInsertMilliseconds: Double?
    public let peakRSSBytes: Int64
    public let exitStatus: Int32

    public init(
        confidenceClass: RuntimeConfidenceClass,
        usedAdaptiveFallback: Bool,
        prewarmSucceeded: Bool?,
        vadSpeechDetected: Bool?,
        quality: PersonalQualityCounts = .empty,
        asrLatencyMilliseconds: Double,
        endToInsertMilliseconds: Double?,
        peakRSSBytes: Int64,
        exitStatus: Int32
    ) {
        self.confidenceClass = confidenceClass
        self.usedAdaptiveFallback = usedAdaptiveFallback
        self.prewarmSucceeded = prewarmSucceeded
        self.vadSpeechDetected = vadSpeechDetected
        self.quality = quality
        self.asrLatencyMilliseconds = asrLatencyMilliseconds
        self.endToInsertMilliseconds = endToInsertMilliseconds
        self.peakRSSBytes = peakRSSBytes
        self.exitStatus = exitStatus
    }
}

public struct PersonalQualityCounts: Codable, Equatable, Sendable {
    public static let empty = PersonalQualityCounts(
        referenceWordCount: 0,
        werSubstitutionCount: 0,
        werDeletionCount: 0,
        werInsertionCount: 0,
        fillerTruePositiveCount: 0,
        fillerFalsePositiveCount: 0,
        fillerFalseNegativeCount: 0,
        selfCorrectionPassedCount: 0,
        selfCorrectionExpectedCount: 0,
        contextTermCorrectCount: 0,
        contextTermExpectedCount: 0,
        protectedAnchorPreservedCount: 0,
        protectedAnchorExpectedCount: 0
    )

    public let referenceWordCount: Int
    public let werSubstitutionCount: Int
    public let werDeletionCount: Int
    public let werInsertionCount: Int
    public let fillerTruePositiveCount: Int
    public let fillerFalsePositiveCount: Int
    public let fillerFalseNegativeCount: Int
    public let selfCorrectionPassedCount: Int
    public let selfCorrectionExpectedCount: Int
    public let contextTermCorrectCount: Int
    public let contextTermExpectedCount: Int
    public let protectedAnchorPreservedCount: Int
    public let protectedAnchorExpectedCount: Int

    public init(
        referenceWordCount: Int,
        werSubstitutionCount: Int,
        werDeletionCount: Int,
        werInsertionCount: Int,
        fillerTruePositiveCount: Int,
        fillerFalsePositiveCount: Int,
        fillerFalseNegativeCount: Int,
        selfCorrectionPassedCount: Int,
        selfCorrectionExpectedCount: Int,
        contextTermCorrectCount: Int,
        contextTermExpectedCount: Int,
        protectedAnchorPreservedCount: Int,
        protectedAnchorExpectedCount: Int
    ) {
        self.referenceWordCount = referenceWordCount
        self.werSubstitutionCount = werSubstitutionCount
        self.werDeletionCount = werDeletionCount
        self.werInsertionCount = werInsertionCount
        self.fillerTruePositiveCount = fillerTruePositiveCount
        self.fillerFalsePositiveCount = fillerFalsePositiveCount
        self.fillerFalseNegativeCount = fillerFalseNegativeCount
        self.selfCorrectionPassedCount = selfCorrectionPassedCount
        self.selfCorrectionExpectedCount = selfCorrectionExpectedCount
        self.contextTermCorrectCount = contextTermCorrectCount
        self.contextTermExpectedCount = contextTermExpectedCount
        self.protectedAnchorPreservedCount = protectedAnchorPreservedCount
        self.protectedAnchorExpectedCount = protectedAnchorExpectedCount
    }

    public var werErrorCount: Int {
        werSubstitutionCount + werDeletionCount + werInsertionCount
    }

    func adding(_ other: Self) -> Self {
        Self(
            referenceWordCount: referenceWordCount + other.referenceWordCount,
            werSubstitutionCount: werSubstitutionCount + other.werSubstitutionCount,
            werDeletionCount: werDeletionCount + other.werDeletionCount,
            werInsertionCount: werInsertionCount + other.werInsertionCount,
            fillerTruePositiveCount: fillerTruePositiveCount + other.fillerTruePositiveCount,
            fillerFalsePositiveCount: fillerFalsePositiveCount + other.fillerFalsePositiveCount,
            fillerFalseNegativeCount: fillerFalseNegativeCount + other.fillerFalseNegativeCount,
            selfCorrectionPassedCount: selfCorrectionPassedCount + other.selfCorrectionPassedCount,
            selfCorrectionExpectedCount: selfCorrectionExpectedCount + other.selfCorrectionExpectedCount,
            contextTermCorrectCount: contextTermCorrectCount + other.contextTermCorrectCount,
            contextTermExpectedCount: contextTermExpectedCount + other.contextTermExpectedCount,
            protectedAnchorPreservedCount: protectedAnchorPreservedCount + other.protectedAnchorPreservedCount,
            protectedAnchorExpectedCount: protectedAnchorExpectedCount + other.protectedAnchorExpectedCount
        )
    }
}

public protocol ASRBenchmarkCommandInvoking {
    func run(_ request: BackendRunRequest) throws -> BackendRunResult
}

public struct ProcessASRBenchmarkCommandInvoker: ASRBenchmarkCommandInvoking {
    public init() {}

    public func run(_ request: BackendRunRequest) throws -> BackendRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.executable)
        process.arguments = request.arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            throw OfflineRunnerError.backendFailed(
                backendID: request.backendID,
                exitStatus: process.terminationStatus
            )
        }
        let result = try BenchmarkJSON.decode(BackendRunResult.self, from: output)
        guard result.exitStatus == 0 else {
            throw OfflineRunnerError.backendFailed(
                backendID: request.backendID,
                exitStatus: result.exitStatus
            )
        }
        return result
    }
}

public struct RuntimeTrialObservation: Codable, Equatable, Sendable {
    public let scheduleOrdinal: Int
    public let backendID: ASRBenchmarkBackendID
    public let clipID: String
    public let phase: TrialPhase
    public let durationClass: RuntimeDurationClass
    public let temperatureClass: RuntimeTemperatureClass
    public let confidenceClass: RuntimeConfidenceClass
    public let usedAdaptiveFallback: Bool
    public let prewarmSucceeded: Bool?
    public let vadSpeechDetected: Bool?
    public let quality: PersonalQualityCounts
    public let asrLatencyMilliseconds: Double
    public let endToInsertMilliseconds: Double?
    public let peakRSSBytes: Int64
}

public struct RuntimeBenchmarkReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let corpusID: String
    public let corpusVersion: String
    public let schedule: RandomizedSchedule
    public let observations: [RuntimeTrialObservation]

    public init(
        schemaVersion: Int = 2,
        corpusID: String,
        corpusVersion: String,
        schedule: RandomizedSchedule,
        observations: [RuntimeTrialObservation]
    ) {
        self.schemaVersion = schemaVersion
        self.corpusID = corpusID
        self.corpusVersion = corpusVersion
        self.schedule = schedule
        self.observations = observations
    }
}

public struct PersonalBackendMetrics: Codable, Equatable, Sendable {
    public let backendID: ASRBenchmarkBackendID
    public let sampleCount: Int
    public let wer: Double?
    public let quality: PersonalQualityCounts
    public let asrLatency: LatencySummary
    public let adaptiveFallbackRate: Double?
    public let fillerPrecision: Double?
    public let fillerRecall: Double?
    public let selfCorrectionRate: Double?
    public let contextTermAccuracy: Double?
    public let protectedAnchorPreservationRate: Double?

    public init(
        backendID: ASRBenchmarkBackendID,
        sampleCount: Int,
        wer: Double?,
        quality: PersonalQualityCounts,
        asrLatency: LatencySummary,
        adaptiveFallbackRate: Double?,
        fillerPrecision: Double?,
        fillerRecall: Double?,
        selfCorrectionRate: Double?,
        contextTermAccuracy: Double?,
        protectedAnchorPreservationRate: Double?
    ) {
        self.backendID = backendID
        self.sampleCount = sampleCount
        self.wer = wer
        self.quality = quality
        self.asrLatency = asrLatency
        self.adaptiveFallbackRate = adaptiveFallbackRate
        self.fillerPrecision = fillerPrecision
        self.fillerRecall = fillerRecall
        self.selfCorrectionRate = selfCorrectionRate
        self.contextTermAccuracy = contextTermAccuracy
        self.protectedAnchorPreservationRate = protectedAnchorPreservationRate
    }
}

public struct PersonalBenchmarkEvaluation: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let gate: String
    public let corpusID: String
    public let status: GateStatus
    public let failedChecks: [String]
    public let metrics: [PersonalBackendMetrics]

    public init(
        schemaVersion: Int = 1,
        gate: String = "WF-PERSONAL-DE-1",
        corpusID: String,
        status: GateStatus,
        failedChecks: [String],
        metrics: [PersonalBackendMetrics]
    ) {
        self.schemaVersion = schemaVersion
        self.gate = gate
        self.corpusID = corpusID
        self.status = status
        self.failedChecks = failedChecks
        self.metrics = metrics
    }
}

public enum PersonalBenchmarkGateEvaluator {
    public static let maximumAdaptiveWERRelativeToLarge = 0.01
    public static let maximumAdaptiveLatencyRatioToLarge = 1.20
    public static let minimumFillerPrecision = 0.90
    public static let minimumFillerRecall = 0.90
    public static let minimumSelfCorrectionRate = 0.90
    public static let minimumContextTermAccuracy = 0.90
    public static let minimumProtectedAnchorPreservationRate = 1.0

    public static func evaluate(_ report: RuntimeBenchmarkReport) -> PersonalBenchmarkEvaluation {
        var failed: [String] = []
        if report.schemaVersion != 2 { failed.append("unsupported_runtime_report_schema") }
        if report.corpusID != WFPersonalDE1.contract.corpusID {
            failed.append("wf_personal_de_1_required")
        }

        let metrics = makeMetrics(report).sorted { $0.backendID.rawValue < $1.backendID.rawValue }
        guard let adaptive = metrics.first(where: { $0.backendID == .adaptive }) else {
            failed.append("adaptive_backend_missing")
            return PersonalBenchmarkEvaluation(
                corpusID: report.corpusID,
                status: .ineligible,
                failedChecks: failed.sorted(),
                metrics: metrics
            )
        }
        guard let large = metrics.first(where: { $0.backendID == .largeV3 }) else {
            failed.append("large_v3_backend_missing")
            return PersonalBenchmarkEvaluation(
                corpusID: report.corpusID,
                status: .ineligible,
                failedChecks: failed.sorted(),
                metrics: metrics
            )
        }

        compareAdaptiveQuality(adaptive, large: large, failed: &failed)
        compareAdaptiveLatency(adaptive, large: large, failed: &failed)
        compareRate(adaptive.fillerPrecision, minimum: minimumFillerPrecision, missing: "filler_precision_missing", failed: "filler_precision_under_90pct", checks: &failed)
        compareRate(adaptive.fillerRecall, minimum: minimumFillerRecall, missing: "filler_recall_missing", failed: "filler_recall_under_90pct", checks: &failed)
        compareRate(adaptive.selfCorrectionRate, minimum: minimumSelfCorrectionRate, missing: "self_correction_missing", failed: "self_correction_under_90pct", checks: &failed)
        compareRate(adaptive.contextTermAccuracy, minimum: minimumContextTermAccuracy, missing: "context_term_accuracy_missing", failed: "context_term_accuracy_under_90pct", checks: &failed)
        compareRate(adaptive.protectedAnchorPreservationRate, minimum: minimumProtectedAnchorPreservationRate, missing: "protected_anchor_preservation_missing", failed: "protected_anchor_preservation_not_complete", checks: &failed)

        return PersonalBenchmarkEvaluation(
            corpusID: report.corpusID,
            status: failed.isEmpty ? .pass : .fail,
            failedChecks: failed.sorted(),
            metrics: metrics
        )
    }

    private static func makeMetrics(_ report: RuntimeBenchmarkReport) -> [PersonalBackendMetrics] {
        Dictionary(grouping: report.observations, by: \.backendID).map { backendID, observations in
            let quality = observations.reduce(PersonalQualityCounts.empty) {
                $0.adding($1.quality)
            }
            let fallbackCount = observations.filter(\.usedAdaptiveFallback).count
            return PersonalBackendMetrics(
                backendID: backendID,
                sampleCount: observations.count,
                wer: rate(numerator: quality.werErrorCount, denominator: quality.referenceWordCount),
                quality: quality,
                asrLatency: DistributionMetrics.summarize(observations.map(\.asrLatencyMilliseconds)),
                adaptiveFallbackRate: observations.isEmpty
                    ? nil
                    : Double(fallbackCount) / Double(observations.count),
                fillerPrecision: rate(
                    numerator: quality.fillerTruePositiveCount,
                    denominator: quality.fillerTruePositiveCount + quality.fillerFalsePositiveCount
                ),
                fillerRecall: rate(
                    numerator: quality.fillerTruePositiveCount,
                    denominator: quality.fillerTruePositiveCount + quality.fillerFalseNegativeCount
                ),
                selfCorrectionRate: rate(
                    numerator: quality.selfCorrectionPassedCount,
                    denominator: quality.selfCorrectionExpectedCount
                ),
                contextTermAccuracy: rate(
                    numerator: quality.contextTermCorrectCount,
                    denominator: quality.contextTermExpectedCount
                ),
                protectedAnchorPreservationRate: rate(
                    numerator: quality.protectedAnchorPreservedCount,
                    denominator: quality.protectedAnchorExpectedCount
                )
            )
        }
    }

    private static func compareAdaptiveQuality(
        _ adaptive: PersonalBackendMetrics,
        large: PersonalBackendMetrics,
        failed: inout [String]
    ) {
        guard let adaptiveWER = adaptive.wer else {
            failed.append("adaptive_wer_missing")
            return
        }
        guard let largeWER = large.wer else {
            failed.append("large_v3_wer_missing")
            return
        }
        if adaptiveWER > largeWER + maximumAdaptiveWERRelativeToLarge {
            failed.append("adaptive_wer_more_than_1pp_over_large_v3")
        }
    }

    private static func compareAdaptiveLatency(
        _ adaptive: PersonalBackendMetrics,
        large: PersonalBackendMetrics,
        failed: inout [String]
    ) {
        guard let adaptiveP95 = adaptive.asrLatency.p95Milliseconds else {
            failed.append("adaptive_latency_p95_missing")
            return
        }
        guard let largeP95 = large.asrLatency.p95Milliseconds else {
            failed.append("large_v3_latency_p95_missing")
            return
        }
        if adaptiveP95 > largeP95 * maximumAdaptiveLatencyRatioToLarge {
            failed.append("adaptive_latency_p95_over_120pct_large_v3")
        }
    }

    private static func compareRate(
        _ value: Double?,
        minimum: Double,
        missing: String,
        failed: String,
        checks: inout [String]
    ) {
        guard let value else {
            checks.append(missing)
            return
        }
        if value < minimum { checks.append(failed) }
    }
}

private func rate(numerator: Int, denominator: Int) -> Double? {
    guard denominator > 0 else { return nil }
    return Double(numerator) / Double(denominator)
}

public enum OfflineRunnerError: Error, Equatable, Sendable {
    case missingBackendCommand(ASRBenchmarkBackendID)
    case backendFailed(backendID: ASRBenchmarkBackendID, exitStatus: Int32)
    case invalidBackendResult(ASRBenchmarkBackendID)
}

public struct OfflineASRBenchmarkRunner<Invoker: ASRBenchmarkCommandInvoking> {
    private let invoker: Invoker

    public init(invoker: Invoker) {
        self.invoker = invoker
    }

    public func run(
        manifest: CorpusManifest,
        backendCommands: [BackendCommandConfiguration],
        seed: UInt64,
        warmupRunsPerCandidate: Int
    ) throws -> RuntimeBenchmarkReport {
        let commands = Dictionary(uniqueKeysWithValues: backendCommands.map { ($0.backendID, $0) })
        let backendIDs = backendCommands.map(\.backendID.rawValue)
        let schedule = RunScheduler.make(
            manifest: manifest,
            candidateIDs: backendIDs,
            seed: seed,
            warmupRunsPerCandidate: warmupRunsPerCandidate
        )
        let clips = Dictionary(uniqueKeysWithValues: manifest.clips.map { ($0.id, $0) })
        let observations = try schedule.trials.map { trial in
            guard let backendID = ASRBenchmarkBackendID(rawValue: trial.candidateID),
                  let command = commands[backendID] else {
                throw OfflineRunnerError.missingBackendCommand(
                    ASRBenchmarkBackendID(rawValue: trial.candidateID) ?? .adaptive
                )
            }
            let clip = clips[trial.clipID]!
            let request = BackendRunRequest(
                backendID: backendID,
                executable: command.executable,
                arguments: command.fixedArguments + [
                    "--backend", backendID.rawValue,
                    "--clip", clip.assetPath,
                    "--schedule-ordinal", String(trial.ordinal),
                    "--phase", trial.phase.rawValue
                ],
                clipAssetPath: clip.assetPath,
                scheduleOrdinal: trial.ordinal,
                phase: trial.phase
            )
            let result = try invoker.run(request)
            guard result.asrLatencyMilliseconds.isFinite,
                  result.asrLatencyMilliseconds >= 0,
                  result.peakRSSBytes >= 0,
                  result.exitStatus == 0 else {
                throw OfflineRunnerError.invalidBackendResult(backendID)
            }
            if let endToInsert = result.endToInsertMilliseconds,
               (!endToInsert.isFinite || endToInsert < 0) {
                throw OfflineRunnerError.invalidBackendResult(backendID)
            }
            return RuntimeTrialObservation(
                scheduleOrdinal: trial.ordinal,
                backendID: backendID,
                clipID: trial.clipID,
                phase: trial.phase,
                durationClass: RuntimeDurationClass.classify(seconds: clip.durationSeconds),
                temperatureClass: trial.phase == .warmup ? .cold : .warm,
                confidenceClass: result.confidenceClass,
                usedAdaptiveFallback: result.usedAdaptiveFallback,
                prewarmSucceeded: result.prewarmSucceeded,
                vadSpeechDetected: result.vadSpeechDetected,
                quality: result.quality,
                asrLatencyMilliseconds: result.asrLatencyMilliseconds,
                endToInsertMilliseconds: result.endToInsertMilliseconds,
                peakRSSBytes: result.peakRSSBytes
            )
        }
        return RuntimeBenchmarkReport(
            corpusID: manifest.corpusID,
            corpusVersion: manifest.corpusVersion,
            schedule: schedule,
            observations: observations
        )
    }
}
