import Foundation
import XCTest
@testable import ASRBenchmarkCore

final class ASRBenchmarkCoreTests: XCTestCase {
    func testGateConstantsMatchApprovedTestSpecificationExactly() {
        XCTAssertEqual(ASRGateEvaluator.cleanMacroWERMaximum, 0.15)
        XCTAssertEqual(ASRGateEvaluator.noisyMixedMacroWERMaximum, 0.22)
        XCTAssertEqual(ASRGateEvaluator.warmASRP50MaximumMilliseconds, 1_500)
        XCTAssertEqual(ASRGateEvaluator.warmASRP95MaximumMilliseconds, 3_250)
        XCTAssertEqual(ASRGateEvaluator.warmEndToInsertP50MaximumMilliseconds, 2_000)
        XCTAssertEqual(ASRGateEvaluator.warmEndToInsertP95MaximumMilliseconds, 4_000)
        XCTAssertEqual(ASRGateEvaluator.warmPeakRSSMaximumBytes, 4_500_000_000)
        XCTAssertEqual(ASRGateEvaluator.coldPeakRSSMaximumBytes, 6_000_000_000)
        XCTAssertEqual(ASRGateEvaluator.fluidWERNonInferiorityMargin, 0.01)
        XCTAssertEqual(ASRGateEvaluator.fluidPerformanceRatioMaximum, 1.20)
    }

    func testCanonicalWFASR1ContractFixtureMatchesCodeContract() throws {
        let fixture = try fixtureData("wf-asr-1.contract.json")
        let decoded = try BenchmarkJSON.decode(CorpusContract.self, from: fixture)

        XCTAssertEqual(decoded, WFASR1.contract)
        XCTAssertTrue(CorpusValidator.validateContract(decoded).isEmpty)
        XCTAssertEqual(decoded.speechClipCount, 120)
        XCTAssertEqual(decoded.silenceClipCount, 20)
        XCTAssertEqual(decoded.speechCountByLanguage, CountByLanguage(de: 60, en: 60))
        XCTAssertEqual(decoded.performanceSample.countByLanguage, CountByLanguage(de: 30, en: 30))
        XCTAssertEqual(decoded.performanceSample.warmupRunsPerCandidate, 5)
        XCTAssertEqual(decoded.performanceSample.coldStartsPerCandidate, 10)
    }

    func testSyntheticManifestIsValidButCannotBecomeReleaseEvidence() throws {
        let contract: CorpusContract = try decodeFixture("synthetic-small.contract.json")
        let manifest: CorpusManifest = try decodeFixture("synthetic-small.manifest.json")

        let result = CorpusValidator.validateManifest(manifest, against: contract)

        XCTAssertTrue(result.valid, result.issues.description)
        XCTAssertFalse(result.releaseEligible)
        XCTAssertFalse(result.corpusAssetsVerified)
    }

    func testScheduleIsSeededReproducibleAndEqualAcrossCandidates() throws {
        let contract: CorpusContract = try decodeFixture("synthetic-small.contract.json")
        let manifest: CorpusManifest = try decodeFixture("synthetic-small.manifest.json")
        let first = RunScheduler.make(
            manifest: manifest,
            candidateIDs: ["fluid-audio", "argmax"],
            seed: 4_242,
            warmupRunsPerCandidate: contract.performanceSample.warmupRunsPerCandidate
        )
        let second = RunScheduler.make(
            manifest: manifest,
            candidateIDs: ["argmax", "fluid-audio"],
            seed: 4_242,
            warmupRunsPerCandidate: contract.performanceSample.warmupRunsPerCandidate
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.algorithm, "splitmix64-fisher-yates-v1")
        for candidate in ["fluid-audio", "argmax"] {
            let measured = first.trials
                .filter { $0.candidateID == candidate && $0.phase == .measured }
                .map(\.clipID)
            XCTAssertEqual(Set(measured), Set(manifest.clips.map(\.id)))
            XCTAssertEqual(measured.count, manifest.clips.count)
            XCTAssertEqual(
                first.trials.filter { $0.candidateID == candidate && $0.phase == .warmup }.count,
                1
            )
        }
    }

    func testWFPersonalDE1ContractLocksLocalGitignoredCorpusShape() {
        let contract = WFPersonalDE1.contract
        let issues = PersonalCorpusValidator.validateContract(contract)

        XCTAssertTrue(issues.isEmpty, issues.description)
        XCTAssertEqual(contract.corpusID, "WF-PERSONAL-DE-1")
        XCTAssertEqual(contract.language, .german)
        XCTAssertEqual(contract.clipCount, 40)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: contract.categories.map { ($0.category, $0.count) }),
            [
                .standard: 10,
                .domainTerms: 10,
                .fillerCorrection: 10,
                .noise: 5,
                .whisper: 5
            ]
        )
        XCTAssertEqual(contract.assetPolicy, "local-gitignored-audio-and-transcripts")
        XCTAssertTrue(contract.deletionPolicy.contains("WF-PERSONAL-DE-1/private"))
    }

    func testOfflineRunnerInvokesBackendCommandsAndPersistsContentFreeRuntimeReport() throws {
        let contract: CorpusContract = try decodeFixture("synthetic-small.contract.json")
        let manifest: CorpusManifest = try decodeFixture("synthetic-small.manifest.json")
        let invoker = RecordingASRCommandInvoker()
        let runner = OfflineASRBenchmarkRunner(invoker: invoker)

        let report = try runner.run(
            manifest: manifest,
            backendCommands: [
                BackendCommandConfiguration(
                    backendID: .qwen,
                    executable: "/usr/local/bin/qwen-asr",
                    fixedArguments: ["--json"]
                )
            ],
            seed: 4_242,
            warmupRunsPerCandidate: contract.performanceSample.warmupRunsPerCandidate
        )

        XCTAssertEqual(report.schemaVersion, 2)
        XCTAssertEqual(report.corpusID, manifest.corpusID)
        XCTAssertEqual(report.observations.count, report.schedule.trials.count)
        XCTAssertEqual(Set(report.observations.map(\.backendID)), [.qwen])
        XCTAssertTrue(report.observations.contains { $0.temperatureClass == .cold })
        XCTAssertTrue(report.observations.contains { $0.temperatureClass == .warm })
        XCTAssertEqual(invoker.requests.count, report.schedule.trials.count)
        XCTAssertTrue(invoker.requests.allSatisfy { $0.executable == "/usr/local/bin/qwen-asr" })
        XCTAssertTrue(invoker.requests.allSatisfy { $0.arguments.starts(with: ["--json", "--backend", "qwen", "--clip"]) })

        let encoded = try String(decoding: BenchmarkJSON.encode(report), as: UTF8.self)
        XCTAssertFalse(encoded.contains("hypothesis"))
        XCTAssertFalse(encoded.contains("insertedText"))
        XCTAssertFalse(encoded.contains("FlusterFlow arbeitet vollständig lokal"))
        XCTAssertFalse(encoded.contains("The private model stays offline"))
    }

    func testPersonalGateComparesAdaptiveAgainstLargeV3UsingContentFreeCounts() throws {
        let adaptive = RuntimeTrialObservation(
            scheduleOrdinal: 0,
            backendID: .adaptive,
            clipID: "personal-001",
            phase: .measured,
            durationClass: .medium,
            temperatureClass: .warm,
            confidenceClass: .high,
            usedAdaptiveFallback: true,
            prewarmSucceeded: nil,
            vadSpeechDetected: true,
            quality: PersonalQualityCounts(
                referenceWordCount: 100,
                werSubstitutionCount: 3,
                werDeletionCount: 1,
                werInsertionCount: 1,
                fillerTruePositiveCount: 9,
                fillerFalsePositiveCount: 0,
                fillerFalseNegativeCount: 1,
                selfCorrectionPassedCount: 10,
                selfCorrectionExpectedCount: 10,
                contextTermCorrectCount: 18,
                contextTermExpectedCount: 20,
                protectedAnchorPreservedCount: 5,
                protectedAnchorExpectedCount: 5
            ),
            asrLatencyMilliseconds: 900,
            endToInsertMilliseconds: nil,
            peakRSSBytes: 700_000_000
        )
        let large = RuntimeTrialObservation(
            scheduleOrdinal: 1,
            backendID: .largeV3,
            clipID: "personal-001",
            phase: .measured,
            durationClass: .medium,
            temperatureClass: .warm,
            confidenceClass: .high,
            usedAdaptiveFallback: false,
            prewarmSucceeded: nil,
            vadSpeechDetected: true,
            quality: PersonalQualityCounts(
                referenceWordCount: 100,
                werSubstitutionCount: 4,
                werDeletionCount: 1,
                werInsertionCount: 0,
                fillerTruePositiveCount: 9,
                fillerFalsePositiveCount: 0,
                fillerFalseNegativeCount: 1,
                selfCorrectionPassedCount: 10,
                selfCorrectionExpectedCount: 10,
                contextTermCorrectCount: 19,
                contextTermExpectedCount: 20,
                protectedAnchorPreservedCount: 5,
                protectedAnchorExpectedCount: 5
            ),
            asrLatencyMilliseconds: 1_000,
            endToInsertMilliseconds: nil,
            peakRSSBytes: 900_000_000
        )
        let report = RuntimeBenchmarkReport(
            corpusID: "WF-PERSONAL-DE-1",
            corpusVersion: "1",
            schedule: RandomizedSchedule(
                algorithm: RunScheduler.algorithm,
                seed: 1,
                warmupRunsPerCandidate: 0,
                trials: []
            ),
            observations: [large, adaptive]
        )

        let evaluation = PersonalBenchmarkGateEvaluator.evaluate(report)

        XCTAssertEqual(evaluation.status, .pass)
        XCTAssertEqual(evaluation.failedChecks, [])
        let adaptiveMetrics = try XCTUnwrap(evaluation.metrics.first { $0.backendID == .adaptive })
        XCTAssertEqual(adaptiveMetrics.wer, 0.05)
        XCTAssertEqual(adaptiveMetrics.adaptiveFallbackRate, 1)
        XCTAssertEqual(adaptiveMetrics.fillerPrecision, 1)
        XCTAssertEqual(adaptiveMetrics.fillerRecall, 0.9)

        let encoded = try String(decoding: BenchmarkJSON.encode(evaluation), as: UTF8.self)
        XCTAssertFalse(encoded.contains("hypothesis"))
        XCTAssertFalse(encoded.contains("transcript"))
        XCTAssertFalse(encoded.contains("insertedText"))
        XCTAssertFalse(encoded.contains("personal-001 text"))
    }

    func testWERAndCERUseUnicodeAwareCaseAndPunctuationNormalization() {
        XCTAssertEqual(
            ASRTextMetrics.wordErrorRate(
                reference: "Grüße, Straße!",
                hypothesis: "GRÜSSE Straße",
                language: .german
            ),
            0.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            ASRTextMetrics.wordErrorRate(
                reference: "Hello, local world.",
                hypothesis: "hello local world",
                language: .english
            ),
            0,
            accuracy: 0.000_001
        )
        XCTAssertGreaterThan(
            ASRTextMetrics.characterErrorRate(
                reference: "fully local",
                hypothesis: "fully vocal",
                language: .english
            ),
            0
        )
    }

    func testReporterComputesQualityLatencyRSSAndThermalWithoutPersistingHypotheses() throws {
        let contract: CorpusContract = try decodeFixture("synthetic-small.contract.json")
        let manifestData = try fixtureData("synthetic-small.manifest.json")
        let manifest = try BenchmarkJSON.decode(CorpusManifest.self, from: manifestData)
        let evidence = makeEvidence(
            contract: contract,
            manifest: manifest,
            manifestData: manifestData,
            phase: .asrOnly
        )

        let report = try BenchmarkReporter.makeReport(
            contract: contract,
            manifest: manifest,
            manifestData: manifestData,
            evidence: evidence,
            corpusAssetsVerified: false
        )

        XCTAssertEqual(report.candidates.count, 2)
        let fluid = try XCTUnwrap(report.candidates.first { $0.candidateID == "fluid-audio" })
        XCTAssertEqual(fluid.metrics.macroWERByLanguage["de"], 0)
        XCTAssertEqual(fluid.metrics.macroWERByLanguage["en"], 0)
        XCTAssertEqual(fluid.metrics.severeOmissions, 0)
        XCTAssertEqual(fluid.metrics.silenceSampleCount, 1)
        XCTAssertEqual(fluid.metrics.silenceHallucinations, 0)
        XCTAssertEqual(fluid.metrics.asrLatency.sampleCount, 2)
        XCTAssertEqual(fluid.metrics.asrLatency.p50Milliseconds, 220)
        XCTAssertEqual(fluid.metrics.asrLatency.p95Milliseconds, 220)
        XCTAssertEqual(fluid.metrics.warmPeakRSSBytes, 400_000_000)
        XCTAssertEqual(fluid.metrics.coldPeakRSSBytes, 500_000_000)
        XCTAssertEqual(fluid.metrics.worstThermalState, .fair)
        XCTAssertFalse(report.corpusAssetsVerified)
        XCTAssertTrue(report.randomizedEqualConditionsVerified)

        let encoded = try String(decoding: BenchmarkJSON.encode(report), as: UTF8.self)
        XCTAssertFalse(encoded.contains("FlusterFlow arbeitet vollständig lokal"))
        XCTAssertFalse(encoded.contains("The private model stays offline"))
    }

    func testEvidenceFailsWhenScheduleDoesNotMatchSeededOrder() throws {
        let contract: CorpusContract = try decodeFixture("synthetic-small.contract.json")
        let manifestData = try fixtureData("synthetic-small.manifest.json")
        let manifest = try BenchmarkJSON.decode(CorpusManifest.self, from: manifestData)
        let evidence = makeEvidence(
            contract: contract,
            manifest: manifest,
            manifestData: manifestData,
            phase: .asrOnly
        )
        let tampered = BenchmarkEvidence(
            schemaVersion: evidence.schemaVersion,
            benchmarkID: evidence.benchmarkID,
            phase: evidence.phase,
            profile: evidence.profile,
            corpusID: evidence.corpusID,
            corpusManifestSHA256: evidence.corpusManifestSHA256,
            schedule: RandomizedSchedule(
                algorithm: evidence.schedule.algorithm,
                seed: evidence.schedule.seed + 1,
                warmupRunsPerCandidate: evidence.schedule.warmupRunsPerCandidate,
                trials: evidence.schedule.trials
            ),
            candidates: evidence.candidates
        )

        let issues = EvidenceValidator.validate(
            tampered,
            manifest: manifest,
            contract: contract,
            manifestData: manifestData
        )

        XCTAssertTrue(issues.contains { $0.code == "schedule_not_reproducible" })
    }

    func testSyntheticReportIsExplicitlyIneligibleForASRA() throws {
        let contract: CorpusContract = try decodeFixture("synthetic-small.contract.json")
        let manifestData = try fixtureData("synthetic-small.manifest.json")
        let manifest = try BenchmarkJSON.decode(CorpusManifest.self, from: manifestData)
        let report = try BenchmarkReporter.makeReport(
            contract: contract,
            manifest: manifest,
            manifestData: manifestData,
            evidence: makeEvidence(
                contract: contract,
                manifest: manifest,
                manifestData: manifestData,
                phase: .asrOnly
            ),
            corpusAssetsVerified: false
        )

        let evaluation = ASRGateEvaluator.evaluateASRA(report)

        XCTAssertNil(evaluation.selectedCandidateID)
        XCTAssertTrue(evaluation.stopBeforeLocalAlpha)
        XCTAssertTrue(evaluation.decisions.allSatisfy { $0.status == .ineligible })
    }

    func testASRASelectsFluidOnlyWithinWERLatencyAndRSSNonInferiorityMargins() {
        let argmax = candidateReport(id: "argmax", overallWER: 0.10, asrP50: 1_000, warmRSS: 1_000)
        let fluid = candidateReport(id: "fluid-audio", overallWER: 0.11, asrP50: 1_200, warmRSS: 1_200)
        let report = releaseReport(phase: .asrOnly, candidates: [fluid, argmax])

        let boundary = ASRGateEvaluator.evaluateASRA(report)
        XCTAssertEqual(boundary.selectedCandidateID, "fluid-audio")

        let slowerFluid = candidateReport(id: "fluid-audio", overallWER: 0.11, asrP50: 1_201, warmRSS: 1_200)
        let comparison = ASRGateEvaluator.evaluateASRA(
            releaseReport(phase: .asrOnly, candidates: [slowerFluid, argmax])
        )
        XCTAssertEqual(comparison.selectedCandidateID, "argmax")
    }

    func testASRAThresholdFailuresCannotSelectCandidate() {
        let argmax = candidateReport(id: "argmax", overallWER: 0.10, noisyWER: 0.221)
        let fluid = candidateReport(id: "fluid-audio", overallWER: 0.10, severeOmissions: 1)

        let evaluation = ASRGateEvaluator.evaluateASRA(
            releaseReport(phase: .asrOnly, candidates: [fluid, argmax])
        )

        XCTAssertNil(evaluation.selectedCandidateID)
        XCTAssertTrue(evaluation.stopBeforeLocalAlpha)
        XCTAssertEqual(evaluation.decisions.first { $0.candidateID == "argmax" }?.status, .fail)
        XCTAssertEqual(evaluation.decisions.first { $0.candidateID == "fluid-audio" }?.status, .fail)
    }

    func testDuplicateCandidateReportFailsClosedWithoutTrapping() {
        let fluid = candidateReport(id: "fluid-audio", overallWER: 0.10)
        let argmax = candidateReport(id: "argmax", overallWER: 0.10)

        let evaluation = ASRGateEvaluator.evaluateASRA(
            releaseReport(phase: .asrOnly, candidates: [fluid, fluid, argmax])
        )

        XCTAssertNil(evaluation.selectedCandidateID)
        XCTAssertEqual(
            evaluation.decisions.first { $0.candidateID == "fluid-audio" },
            CandidateGateDecision(
                candidateID: "fluid-audio",
                status: .ineligible,
                failedChecks: ["duplicate_candidate_id"]
            )
        )
    }

    func testASRBRequiresPriorASRAAndExactlySixtyConfirmedInsertions() {
        let candidate = candidateReport(
            id: "fluid-audio",
            overallWER: 0.10,
            endToInsert: LatencySummary(
                sampleCount: 60,
                p50Milliseconds: 2_000,
                p95Milliseconds: 4_000,
                maximumMilliseconds: 4_500
            ),
            confirmedInsertionCount: 60
        )
        let prior = GateEvaluation(
            schemaVersion: 1,
            gate: .asrA,
            benchmarkID: "asr-a-release",
            decisions: [CandidateGateDecision(candidateID: "fluid-audio", status: .pass, failedChecks: [])],
            selectedCandidateID: "fluid-audio",
            stopBeforeLocalAlpha: false
        )

        let passing = ASRGateEvaluator.evaluateASRB(
            releaseReport(phase: .fullPipeline, candidates: [candidate]),
            priorASRA: prior
        )
        XCTAssertEqual(passing.selectedCandidateID, "fluid-audio")

        let fallback = candidateReport(
            id: "fluid-audio",
            overallWER: 0.10,
            endToInsert: LatencySummary(
                sampleCount: 59,
                p50Milliseconds: 1_900,
                p95Milliseconds: 3_900,
                maximumMilliseconds: 4_200
            ),
            confirmedInsertionCount: 59
        )
        let failing = ASRGateEvaluator.evaluateASRB(
            releaseReport(phase: .fullPipeline, candidates: [fallback]),
            priorASRA: prior
        )
        XCTAssertNil(failing.selectedCandidateID)
        XCTAssertNotEqual(failing.decisions.first?.status, .pass)
    }
}

private func makeEvidence(
    contract: CorpusContract,
    manifest: CorpusManifest,
    manifestData: Data,
    phase: BenchmarkPhase
) -> BenchmarkEvidence {
    let candidateIDs = ["fluid-audio", "argmax"]
    let schedule = RunScheduler.make(
        manifest: manifest,
        candidateIDs: candidateIDs,
        seed: 4_242,
        warmupRunsPerCandidate: contract.performanceSample.warmupRunsPerCandidate
    )
    let clips = Dictionary(uniqueKeysWithValues: manifest.clips.map { ($0.id, $0) })
    let candidates = candidateIDs.map { candidateID in
        CandidateEvidence(
            provenance: provenance(id: candidateID),
            runtimeNetworkConnections: 0,
            observations: schedule.trials
                .filter { $0.candidateID == candidateID }
                .map { trial in
                    let clip = clips[trial.clipID]!
                    return TrialObservation(
                        scheduleOrdinal: trial.ordinal,
                        clipID: trial.clipID,
                        phase: trial.phase,
                        hypothesis: clip.goldTranscript,
                        insertedText: clip.kind == .speech ? clip.goldTranscript : nil,
                        confirmedMutation: clip.kind == .speech,
                        usedSafeFallback: false,
                        asrLatencyMilliseconds: trial.phase == .warmup ? 250 : 220,
                        endToInsertMilliseconds: phase == .fullPipeline && clip.kind == .speech ? 400 : nil,
                        timeToSafeFallbackMilliseconds: nil,
                        peakRSSBytes: 400_000_000,
                        thermalState: .nominal,
                        reviewedSevereOmissionSpanIDs: []
                    )
                },
            coldStarts: [
                ColdStartObservation(
                    ordinal: 0,
                    modelReadyMilliseconds: 900,
                    peakRSSBytes: 500_000_000,
                    thermalState: .fair
                )
            ]
        )
    }
    return BenchmarkEvidence(
        schemaVersion: 1,
        benchmarkID: "synthetic-smoke",
        phase: phase,
        profile: .syntheticSmoke,
        corpusID: manifest.corpusID,
        corpusManifestSHA256: SHA256Digest.hex(data: manifestData),
        schedule: schedule,
        candidates: candidates
    )
}

private func provenance(id: String) -> CandidateProvenance {
    let artifact = HashedArtifact(
        path: "synthetic/placeholder.bin",
        byteCount: 1,
        sha256: String(repeating: "a", count: 64)
    )
    func component(_ name: String) -> ComponentProvenance {
        ComponentProvenance(
            name: name,
            version: "1.0.0-smoke",
            revision: "synthetic",
            repositoryURL: "https://example.com/synthetic",
            licenseSPDX: "LicenseRef-Synthetic-Test-Only",
            attribution: "Synthetic benchmark fixture",
            artifacts: [artifact]
        )
    }
    return CandidateProvenance(
        candidateID: id,
        runtime: component("\(id)-runtime"),
        model: component("\(id)-model"),
        adapter: component("\(id)-adapter"),
        toolchain: ToolchainProvenance(
            macOSVersion: "synthetic",
            xcodeVersion: "synthetic",
            swiftVersion: "synthetic",
            buildConfiguration: "debug",
            hardwareClass: "synthetic-no-device",
            memoryBytes: 1
        ),
        audioPreprocessing: AudioPreprocessingContract(
            sampleRateHz: 16_000,
            channelCount: 1,
            sampleFormat: "float32",
            normalizerID: "wf-pcm-v1",
            languageMode: "explicit-per-clip",
            contextHintPolicy: "off"
        )
    )
}

private func candidateReport(
    id: String,
    overallWER: Double,
    cleanWER: Double = 0.10,
    noisyWER: Double = 0.20,
    severeOmissions: Int = 0,
    asrP50: Double = 1_000,
    warmRSS: Int64 = 1_000_000_000,
    endToInsert: LatencySummary = LatencySummary(
        sampleCount: 0,
        p50Milliseconds: nil,
        p95Milliseconds: nil,
        maximumMilliseconds: nil
    ),
    confirmedInsertionCount: Int = 0
) -> CandidateReport {
    CandidateReport(
        candidateID: id,
        provenance: provenance(id: id),
        provenanceComplete: true,
        metrics: CandidateMetrics(
            macroWERByLanguage: ["de": overallWER, "en": overallWER],
            macroCERByLanguage: ["de": overallWER, "en": overallWER],
            macroWERByQualityBand: [
                "clean": ["de": cleanWER, "en": cleanWER],
                "noisyMixed": ["de": noisyWER, "en": noisyWER]
            ],
            severeOmissions: severeOmissions,
            silenceSampleCount: 20,
            silenceHallucinations: 0,
            asrLatency: LatencySummary(
                sampleCount: 60,
                p50Milliseconds: asrP50,
                p95Milliseconds: 3_000,
                maximumMilliseconds: 3_500
            ),
            endToInsertLatency: endToInsert,
            timeToSafeFallback: LatencySummary(
                sampleCount: 0,
                p50Milliseconds: nil,
                p95Milliseconds: nil,
                maximumMilliseconds: nil
            ),
            confirmedInsertionCount: confirmedInsertionCount,
            expectedPerformanceInsertionCount: 60,
            warmPeakRSSBytes: warmRSS,
            coldPeakRSSBytes: 5_000_000_000,
            coldModelReady: LatencySummary(
                sampleCount: 10,
                p50Milliseconds: 5_000,
                p95Milliseconds: 7_000,
                maximumMilliseconds: 8_000
            ),
            worstThermalState: .fair,
            runtimeNetworkConnections: 0
        )
    )
}

private func releaseReport(
    phase: BenchmarkPhase,
    candidates: [CandidateReport]
) -> BenchmarkReport {
    BenchmarkReport(
        schemaVersion: 1,
        benchmarkID: phase == .asrOnly ? "asr-a-release" : "asr-b-release",
        phase: phase,
        profile: .release,
        corpusID: "WF-ASR-1",
        corpusManifestSHA256: String(repeating: "f", count: 64),
        corpusAssetsVerified: true,
        randomizedEqualConditionsVerified: true,
        candidates: candidates
    )
}

private func fixtureData(_ name: String) throws -> Data {
    guard let root = Bundle.module.resourceURL else {
        throw ASRFixtureResourceError.missingBundle
    }
    return try Data(contentsOf: root.appendingPathComponent("ASR/\(name)"))
}

private func decodeFixture<T: Decodable>(_ name: String) throws -> T {
    try BenchmarkJSON.decode(T.self, from: fixtureData(name))
}

private enum ASRFixtureResourceError: Error {
    case missingBundle
}

private final class RecordingASRCommandInvoker: ASRBenchmarkCommandInvoking {
    private(set) var requests: [BackendRunRequest] = []

    func run(_ request: BackendRunRequest) throws -> BackendRunResult {
        requests.append(request)
        return BackendRunResult(
            confidenceClass: request.phase == .warmup ? .unknown : .high,
            usedAdaptiveFallback: false,
            prewarmSucceeded: request.phase == .warmup ? true : nil,
            vadSpeechDetected: true,
            quality: PersonalQualityCounts(
                referenceWordCount: request.phase == .warmup ? 0 : 10,
                werSubstitutionCount: 0,
                werDeletionCount: 0,
                werInsertionCount: 0,
                fillerTruePositiveCount: 1,
                fillerFalsePositiveCount: 0,
                fillerFalseNegativeCount: 0,
                selfCorrectionPassedCount: 1,
                selfCorrectionExpectedCount: 1,
                contextTermCorrectCount: 1,
                contextTermExpectedCount: 1,
                protectedAnchorPreservedCount: 1,
                protectedAnchorExpectedCount: 1
            ),
            asrLatencyMilliseconds: request.phase == .warmup ? 410 : 300,
            endToInsertMilliseconds: nil,
            peakRSSBytes: 300_000_000,
            exitStatus: 0
        )
    }
}
