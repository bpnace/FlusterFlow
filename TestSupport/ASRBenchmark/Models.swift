import Foundation

public enum EvidenceProfile: String, Codable, Sendable {
    case release
    case syntheticSmoke
}

public enum BenchmarkPhase: String, Codable, Sendable {
    case asrOnly
    case fullPipeline
}

public enum ClipKind: String, Codable, Sendable {
    case speech
    case silence
}

public enum BenchmarkLanguage: String, Codable, CaseIterable, Sendable {
    case german = "de"
    case english = "en"

    public var locale: Locale {
        switch self {
        case .german: Locale(identifier: "de_DE_POSIX")
        case .english: Locale(identifier: "en_US_POSIX")
        }
    }
}

public enum SpeechStratum: String, Codable, CaseIterable, Sendable {
    case cleanStandard
    case roomNoise
    case accents
    case namedTerms
    case spokenLists
    case selfCorrection
}

public enum QualityBand: String, Codable, CaseIterable, Sendable {
    case clean
    case noisyMixed
}

public enum SourceKind: String, Codable, Sendable {
    case synthetic
    case publicLicensed
    case consented
}

public enum PersonalClipCategory: String, Codable, CaseIterable, Sendable {
    case standard
    case domainTerms
    case fillerCorrection
    case noise
    case whisper
}

public struct PersonalClipRequirement: Codable, Equatable, Sendable {
    public let category: PersonalClipCategory
    public let count: Int

    public init(category: PersonalClipCategory, count: Int) {
        self.category = category
        self.count = count
    }
}

public struct PersonalCorpusContract: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let corpusID: String
    public let corpusVersion: String
    public let language: BenchmarkLanguage
    public let clipCount: Int
    public let minimumDurationSeconds: Double
    public let maximumDurationSeconds: Double
    public let categories: [PersonalClipRequirement]
    public let assetPolicy: String
    public let deletionPolicy: String

    public init(
        schemaVersion: Int,
        corpusID: String,
        corpusVersion: String,
        language: BenchmarkLanguage,
        clipCount: Int,
        minimumDurationSeconds: Double,
        maximumDurationSeconds: Double,
        categories: [PersonalClipRequirement],
        assetPolicy: String,
        deletionPolicy: String
    ) {
        self.schemaVersion = schemaVersion
        self.corpusID = corpusID
        self.corpusVersion = corpusVersion
        self.language = language
        self.clipCount = clipCount
        self.minimumDurationSeconds = minimumDurationSeconds
        self.maximumDurationSeconds = maximumDurationSeconds
        self.categories = categories
        self.assetPolicy = assetPolicy
        self.deletionPolicy = deletionPolicy
    }
}

public enum AssetState: String, Codable, Sendable {
    case provisioned
    case unprovisioned
}

public struct CountByLanguage: Codable, Equatable, Sendable {
    public let de: Int
    public let en: Int

    public init(de: Int, en: Int) {
        self.de = de
        self.en = en
    }

    public subscript(language: BenchmarkLanguage) -> Int {
        switch language {
        case .german: de
        case .english: en
        }
    }
}

public struct StratumRequirement: Codable, Equatable, Sendable {
    public let stratum: SpeechStratum
    public let perLanguage: Int

    public init(stratum: SpeechStratum, perLanguage: Int) {
        self.stratum = stratum
        self.perLanguage = perLanguage
    }
}

public struct PerformanceSampleContract: Codable, Equatable, Sendable {
    public let countByLanguage: CountByLanguage
    public let minimumDurationSeconds: Double
    public let maximumDurationSeconds: Double
    public let warmupRunsPerCandidate: Int
    public let coldStartsPerCandidate: Int

    public init(
        countByLanguage: CountByLanguage,
        minimumDurationSeconds: Double,
        maximumDurationSeconds: Double,
        warmupRunsPerCandidate: Int,
        coldStartsPerCandidate: Int
    ) {
        self.countByLanguage = countByLanguage
        self.minimumDurationSeconds = minimumDurationSeconds
        self.maximumDurationSeconds = maximumDurationSeconds
        self.warmupRunsPerCandidate = warmupRunsPerCandidate
        self.coldStartsPerCandidate = coldStartsPerCandidate
    }
}

public struct CorpusContract: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let corpusID: String
    public let corpusVersion: String
    public let profile: EvidenceProfile
    public let speechClipCount: Int
    public let silenceClipCount: Int
    public let speechCountByLanguage: CountByLanguage
    public let minimumSpeechDurationSeconds: Double
    public let maximumSpeechDurationSeconds: Double
    public let stratumRequirements: [StratumRequirement]
    public let performanceSample: PerformanceSampleContract
    public let allowedSourceKinds: [SourceKind]

    public init(
        schemaVersion: Int,
        corpusID: String,
        corpusVersion: String,
        profile: EvidenceProfile,
        speechClipCount: Int,
        silenceClipCount: Int,
        speechCountByLanguage: CountByLanguage,
        minimumSpeechDurationSeconds: Double,
        maximumSpeechDurationSeconds: Double,
        stratumRequirements: [StratumRequirement],
        performanceSample: PerformanceSampleContract,
        allowedSourceKinds: [SourceKind]
    ) {
        self.schemaVersion = schemaVersion
        self.corpusID = corpusID
        self.corpusVersion = corpusVersion
        self.profile = profile
        self.speechClipCount = speechClipCount
        self.silenceClipCount = silenceClipCount
        self.speechCountByLanguage = speechCountByLanguage
        self.minimumSpeechDurationSeconds = minimumSpeechDurationSeconds
        self.maximumSpeechDurationSeconds = maximumSpeechDurationSeconds
        self.stratumRequirements = stratumRequirements
        self.performanceSample = performanceSample
        self.allowedSourceKinds = allowedSourceKinds
    }
}

public enum WFASR1 {
    public static let contract = CorpusContract(
        schemaVersion: 1,
        corpusID: "WF-ASR-1",
        corpusVersion: "1",
        profile: .release,
        speechClipCount: 120,
        silenceClipCount: 20,
        speechCountByLanguage: CountByLanguage(de: 60, en: 60),
        minimumSpeechDurationSeconds: 2,
        maximumSpeechDurationSeconds: 30,
        stratumRequirements: SpeechStratum.allCases.map {
            StratumRequirement(stratum: $0, perLanguage: 10)
        },
        performanceSample: PerformanceSampleContract(
            countByLanguage: CountByLanguage(de: 30, en: 30),
            minimumDurationSeconds: 5,
            maximumDurationSeconds: 8,
            warmupRunsPerCandidate: 5,
            coldStartsPerCandidate: 10
        ),
        allowedSourceKinds: [.synthetic, .publicLicensed, .consented]
    )
}

public enum WFPersonalDE1 {
    public static let contract = PersonalCorpusContract(
        schemaVersion: 1,
        corpusID: "WF-PERSONAL-DE-1",
        corpusVersion: "1",
        language: .german,
        clipCount: 40,
        minimumDurationSeconds: 2,
        maximumDurationSeconds: 30,
        categories: [
            PersonalClipRequirement(category: .standard, count: 10),
            PersonalClipRequirement(category: .domainTerms, count: 10),
            PersonalClipRequirement(category: .fillerCorrection, count: 10),
            PersonalClipRequirement(category: .noise, count: 5),
            PersonalClipRequirement(category: .whisper, count: 5)
        ],
        assetPolicy: "local-gitignored-audio-and-transcripts",
        deletionPolicy: "remove docs/test-manifests/WF-PERSONAL-DE-1/private"
    )
}

public struct CorpusProvenance: Codable, Equatable, Sendable {
    public let producer: String
    public let description: String
    public let repositoryRevision: String
    public let declaration: String

    public init(
        producer: String,
        description: String,
        repositoryRevision: String,
        declaration: String
    ) {
        self.producer = producer
        self.description = description
        self.repositoryRevision = repositoryRevision
        self.declaration = declaration
    }
}

public struct ClipProvenance: Codable, Equatable, Sendable {
    public let sourceKind: SourceKind
    public let sourceReference: String
    public let licenseSPDX: String?
    public let attribution: String?
    public let consentRecordID: String?
    public let generator: String?
    public let generatorVersion: String?

    public init(
        sourceKind: SourceKind,
        sourceReference: String,
        licenseSPDX: String? = nil,
        attribution: String? = nil,
        consentRecordID: String? = nil,
        generator: String? = nil,
        generatorVersion: String? = nil
    ) {
        self.sourceKind = sourceKind
        self.sourceReference = sourceReference
        self.licenseSPDX = licenseSPDX
        self.attribution = attribution
        self.consentRecordID = consentRecordID
        self.generator = generator
        self.generatorVersion = generatorVersion
    }
}

public struct AnnotatedSpan: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

public struct ASRClip: Codable, Equatable, Sendable {
    public let id: String
    public let kind: ClipKind
    public let language: BenchmarkLanguage?
    public let stratum: SpeechStratum?
    public let qualityBand: QualityBand?
    public let durationSeconds: Double
    public let isPerformanceSample: Bool
    public let assetPath: String
    public let assetSHA256: String
    public let assetState: AssetState
    public let goldTranscript: String
    public let substantialSpans: [AnnotatedSpan]
    public let provenance: ClipProvenance

    public init(
        id: String,
        kind: ClipKind,
        language: BenchmarkLanguage?,
        stratum: SpeechStratum?,
        qualityBand: QualityBand?,
        durationSeconds: Double,
        isPerformanceSample: Bool,
        assetPath: String,
        assetSHA256: String,
        assetState: AssetState,
        goldTranscript: String,
        substantialSpans: [AnnotatedSpan],
        provenance: ClipProvenance
    ) {
        self.id = id
        self.kind = kind
        self.language = language
        self.stratum = stratum
        self.qualityBand = qualityBand
        self.durationSeconds = durationSeconds
        self.isPerformanceSample = isPerformanceSample
        self.assetPath = assetPath
        self.assetSHA256 = assetSHA256
        self.assetState = assetState
        self.goldTranscript = goldTranscript
        self.substantialSpans = substantialSpans
        self.provenance = provenance
    }
}

public struct CorpusManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let corpusID: String
    public let corpusVersion: String
    public let profile: EvidenceProfile
    public let provenance: CorpusProvenance
    public let clips: [ASRClip]

    public init(
        schemaVersion: Int,
        corpusID: String,
        corpusVersion: String,
        profile: EvidenceProfile,
        provenance: CorpusProvenance,
        clips: [ASRClip]
    ) {
        self.schemaVersion = schemaVersion
        self.corpusID = corpusID
        self.corpusVersion = corpusVersion
        self.profile = profile
        self.provenance = provenance
        self.clips = clips
    }
}

public struct HashedArtifact: Codable, Equatable, Sendable {
    public let path: String
    public let byteCount: Int64
    public let sha256: String

    public init(path: String, byteCount: Int64, sha256: String) {
        self.path = path
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct ComponentProvenance: Codable, Equatable, Sendable {
    public let name: String
    public let version: String
    public let revision: String
    public let repositoryURL: String
    public let licenseSPDX: String
    public let attribution: String
    public let artifacts: [HashedArtifact]

    public init(
        name: String,
        version: String,
        revision: String,
        repositoryURL: String,
        licenseSPDX: String,
        attribution: String,
        artifacts: [HashedArtifact]
    ) {
        self.name = name
        self.version = version
        self.revision = revision
        self.repositoryURL = repositoryURL
        self.licenseSPDX = licenseSPDX
        self.attribution = attribution
        self.artifacts = artifacts
    }
}

public struct ToolchainProvenance: Codable, Equatable, Sendable {
    public let macOSVersion: String
    public let xcodeVersion: String
    public let swiftVersion: String
    public let buildConfiguration: String
    public let hardwareClass: String
    public let memoryBytes: Int64

    public init(
        macOSVersion: String,
        xcodeVersion: String,
        swiftVersion: String,
        buildConfiguration: String,
        hardwareClass: String,
        memoryBytes: Int64
    ) {
        self.macOSVersion = macOSVersion
        self.xcodeVersion = xcodeVersion
        self.swiftVersion = swiftVersion
        self.buildConfiguration = buildConfiguration
        self.hardwareClass = hardwareClass
        self.memoryBytes = memoryBytes
    }
}

public struct AudioPreprocessingContract: Codable, Equatable, Sendable {
    public let sampleRateHz: Int
    public let channelCount: Int
    public let sampleFormat: String
    public let normalizerID: String
    public let languageMode: String
    public let contextHintPolicy: String

    public init(
        sampleRateHz: Int,
        channelCount: Int,
        sampleFormat: String,
        normalizerID: String,
        languageMode: String,
        contextHintPolicy: String
    ) {
        self.sampleRateHz = sampleRateHz
        self.channelCount = channelCount
        self.sampleFormat = sampleFormat
        self.normalizerID = normalizerID
        self.languageMode = languageMode
        self.contextHintPolicy = contextHintPolicy
    }
}

public struct CandidateProvenance: Codable, Equatable, Sendable {
    public let candidateID: String
    public let runtime: ComponentProvenance
    public let model: ComponentProvenance
    public let adapter: ComponentProvenance
    public let toolchain: ToolchainProvenance
    public let audioPreprocessing: AudioPreprocessingContract

    public init(
        candidateID: String,
        runtime: ComponentProvenance,
        model: ComponentProvenance,
        adapter: ComponentProvenance,
        toolchain: ToolchainProvenance,
        audioPreprocessing: AudioPreprocessingContract
    ) {
        self.candidateID = candidateID
        self.runtime = runtime
        self.model = model
        self.adapter = adapter
        self.toolchain = toolchain
        self.audioPreprocessing = audioPreprocessing
    }
}

public enum TrialPhase: String, Codable, Sendable {
    case warmup
    case measured
}

public struct ScheduledTrial: Codable, Equatable, Sendable {
    public let ordinal: Int
    public let candidateID: String
    public let clipID: String
    public let phase: TrialPhase

    public init(ordinal: Int, candidateID: String, clipID: String, phase: TrialPhase) {
        self.ordinal = ordinal
        self.candidateID = candidateID
        self.clipID = clipID
        self.phase = phase
    }
}

public struct RandomizedSchedule: Codable, Equatable, Sendable {
    public let algorithm: String
    public let seed: UInt64
    public let warmupRunsPerCandidate: Int
    public let trials: [ScheduledTrial]

    public init(
        algorithm: String,
        seed: UInt64,
        warmupRunsPerCandidate: Int,
        trials: [ScheduledTrial]
    ) {
        self.algorithm = algorithm
        self.seed = seed
        self.warmupRunsPerCandidate = warmupRunsPerCandidate
        self.trials = trials
    }
}

public enum ThermalState: String, Codable, CaseIterable, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unknown

    public var severity: Int {
        switch self {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        case .unknown: 4
        }
    }
}

public struct TrialObservation: Codable, Equatable, Sendable {
    public let scheduleOrdinal: Int
    public let clipID: String
    public let phase: TrialPhase
    public let hypothesis: String
    public let insertedText: String?
    public let confirmedMutation: Bool
    public let usedSafeFallback: Bool
    public let asrLatencyMilliseconds: Double
    public let endToInsertMilliseconds: Double?
    public let timeToSafeFallbackMilliseconds: Double?
    public let peakRSSBytes: Int64
    public let thermalState: ThermalState
    public let reviewedSevereOmissionSpanIDs: [String]

    public init(
        scheduleOrdinal: Int,
        clipID: String,
        phase: TrialPhase,
        hypothesis: String,
        insertedText: String?,
        confirmedMutation: Bool,
        usedSafeFallback: Bool,
        asrLatencyMilliseconds: Double,
        endToInsertMilliseconds: Double?,
        timeToSafeFallbackMilliseconds: Double?,
        peakRSSBytes: Int64,
        thermalState: ThermalState,
        reviewedSevereOmissionSpanIDs: [String]
    ) {
        self.scheduleOrdinal = scheduleOrdinal
        self.clipID = clipID
        self.phase = phase
        self.hypothesis = hypothesis
        self.insertedText = insertedText
        self.confirmedMutation = confirmedMutation
        self.usedSafeFallback = usedSafeFallback
        self.asrLatencyMilliseconds = asrLatencyMilliseconds
        self.endToInsertMilliseconds = endToInsertMilliseconds
        self.timeToSafeFallbackMilliseconds = timeToSafeFallbackMilliseconds
        self.peakRSSBytes = peakRSSBytes
        self.thermalState = thermalState
        self.reviewedSevereOmissionSpanIDs = reviewedSevereOmissionSpanIDs
    }
}

public struct ColdStartObservation: Codable, Equatable, Sendable {
    public let ordinal: Int
    public let modelReadyMilliseconds: Double
    public let peakRSSBytes: Int64
    public let thermalState: ThermalState

    public init(
        ordinal: Int,
        modelReadyMilliseconds: Double,
        peakRSSBytes: Int64,
        thermalState: ThermalState
    ) {
        self.ordinal = ordinal
        self.modelReadyMilliseconds = modelReadyMilliseconds
        self.peakRSSBytes = peakRSSBytes
        self.thermalState = thermalState
    }
}

public struct CandidateEvidence: Codable, Equatable, Sendable {
    public let provenance: CandidateProvenance
    public let runtimeNetworkConnections: Int
    public let observations: [TrialObservation]
    public let coldStarts: [ColdStartObservation]

    public init(
        provenance: CandidateProvenance,
        runtimeNetworkConnections: Int,
        observations: [TrialObservation],
        coldStarts: [ColdStartObservation]
    ) {
        self.provenance = provenance
        self.runtimeNetworkConnections = runtimeNetworkConnections
        self.observations = observations
        self.coldStarts = coldStarts
    }
}

public struct BenchmarkEvidence: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let benchmarkID: String
    public let phase: BenchmarkPhase
    public let profile: EvidenceProfile
    public let corpusID: String
    public let corpusManifestSHA256: String
    public let schedule: RandomizedSchedule
    public let candidates: [CandidateEvidence]

    public init(
        schemaVersion: Int,
        benchmarkID: String,
        phase: BenchmarkPhase,
        profile: EvidenceProfile,
        corpusID: String,
        corpusManifestSHA256: String,
        schedule: RandomizedSchedule,
        candidates: [CandidateEvidence]
    ) {
        self.schemaVersion = schemaVersion
        self.benchmarkID = benchmarkID
        self.phase = phase
        self.profile = profile
        self.corpusID = corpusID
        self.corpusManifestSHA256 = corpusManifestSHA256
        self.schedule = schedule
        self.candidates = candidates
    }
}

public struct ValidationIssue: Codable, Equatable, Hashable, Sendable {
    public let code: String
    public let path: String

    public init(code: String, path: String) {
        self.code = code
        self.path = path
    }
}

public struct ValidationResult: Codable, Equatable, Sendable {
    public let valid: Bool
    public let releaseEligible: Bool
    public let corpusAssetsVerified: Bool
    public let issues: [ValidationIssue]

    public init(
        valid: Bool,
        releaseEligible: Bool,
        corpusAssetsVerified: Bool,
        issues: [ValidationIssue]
    ) {
        self.valid = valid
        self.releaseEligible = releaseEligible
        self.corpusAssetsVerified = corpusAssetsVerified
        self.issues = issues
    }
}

public struct LatencySummary: Codable, Equatable, Sendable {
    public let sampleCount: Int
    public let p50Milliseconds: Double?
    public let p95Milliseconds: Double?
    public let maximumMilliseconds: Double?

    public init(
        sampleCount: Int,
        p50Milliseconds: Double?,
        p95Milliseconds: Double?,
        maximumMilliseconds: Double?
    ) {
        self.sampleCount = sampleCount
        self.p50Milliseconds = p50Milliseconds
        self.p95Milliseconds = p95Milliseconds
        self.maximumMilliseconds = maximumMilliseconds
    }
}

public struct CandidateMetrics: Codable, Equatable, Sendable {
    public let macroWERByLanguage: [String: Double]
    public let macroCERByLanguage: [String: Double]
    public let macroWERByQualityBand: [String: [String: Double]]
    public let severeOmissions: Int
    public let silenceSampleCount: Int
    public let silenceHallucinations: Int
    public let asrLatency: LatencySummary
    public let endToInsertLatency: LatencySummary
    public let timeToSafeFallback: LatencySummary
    public let confirmedInsertionCount: Int
    public let expectedPerformanceInsertionCount: Int
    public let warmPeakRSSBytes: Int64
    public let coldPeakRSSBytes: Int64
    public let coldModelReady: LatencySummary
    public let worstThermalState: ThermalState
    public let runtimeNetworkConnections: Int

    public init(
        macroWERByLanguage: [String: Double],
        macroCERByLanguage: [String: Double],
        macroWERByQualityBand: [String: [String: Double]],
        severeOmissions: Int,
        silenceSampleCount: Int,
        silenceHallucinations: Int,
        asrLatency: LatencySummary,
        endToInsertLatency: LatencySummary,
        timeToSafeFallback: LatencySummary,
        confirmedInsertionCount: Int,
        expectedPerformanceInsertionCount: Int,
        warmPeakRSSBytes: Int64,
        coldPeakRSSBytes: Int64,
        coldModelReady: LatencySummary,
        worstThermalState: ThermalState,
        runtimeNetworkConnections: Int
    ) {
        self.macroWERByLanguage = macroWERByLanguage
        self.macroCERByLanguage = macroCERByLanguage
        self.macroWERByQualityBand = macroWERByQualityBand
        self.severeOmissions = severeOmissions
        self.silenceSampleCount = silenceSampleCount
        self.silenceHallucinations = silenceHallucinations
        self.asrLatency = asrLatency
        self.endToInsertLatency = endToInsertLatency
        self.timeToSafeFallback = timeToSafeFallback
        self.confirmedInsertionCount = confirmedInsertionCount
        self.expectedPerformanceInsertionCount = expectedPerformanceInsertionCount
        self.warmPeakRSSBytes = warmPeakRSSBytes
        self.coldPeakRSSBytes = coldPeakRSSBytes
        self.coldModelReady = coldModelReady
        self.worstThermalState = worstThermalState
        self.runtimeNetworkConnections = runtimeNetworkConnections
    }
}

public struct CandidateReport: Codable, Equatable, Sendable {
    public let candidateID: String
    public let provenance: CandidateProvenance
    public let provenanceComplete: Bool
    public let metrics: CandidateMetrics

    public init(
        candidateID: String,
        provenance: CandidateProvenance,
        provenanceComplete: Bool,
        metrics: CandidateMetrics
    ) {
        self.candidateID = candidateID
        self.provenance = provenance
        self.provenanceComplete = provenanceComplete
        self.metrics = metrics
    }
}

public struct BenchmarkReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let benchmarkID: String
    public let phase: BenchmarkPhase
    public let profile: EvidenceProfile
    public let corpusID: String
    public let corpusManifestSHA256: String
    public let corpusAssetsVerified: Bool
    public let randomizedEqualConditionsVerified: Bool
    public let candidates: [CandidateReport]

    public init(
        schemaVersion: Int,
        benchmarkID: String,
        phase: BenchmarkPhase,
        profile: EvidenceProfile,
        corpusID: String,
        corpusManifestSHA256: String,
        corpusAssetsVerified: Bool,
        randomizedEqualConditionsVerified: Bool,
        candidates: [CandidateReport]
    ) {
        self.schemaVersion = schemaVersion
        self.benchmarkID = benchmarkID
        self.phase = phase
        self.profile = profile
        self.corpusID = corpusID
        self.corpusManifestSHA256 = corpusManifestSHA256
        self.corpusAssetsVerified = corpusAssetsVerified
        self.randomizedEqualConditionsVerified = randomizedEqualConditionsVerified
        self.candidates = candidates
    }
}

public enum GateName: String, Codable, Sendable {
    case asrA = "ASR-A"
    case asrB = "ASR-B"
}

public enum GateStatus: String, Codable, Sendable {
    case pass
    case fail
    case ineligible
}

public struct CandidateGateDecision: Codable, Equatable, Sendable {
    public let candidateID: String
    public let status: GateStatus
    public let failedChecks: [String]

    public init(candidateID: String, status: GateStatus, failedChecks: [String]) {
        self.candidateID = candidateID
        self.status = status
        self.failedChecks = failedChecks
    }
}

public struct GateEvaluation: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let gate: GateName
    public let benchmarkID: String
    public let decisions: [CandidateGateDecision]
    public let selectedCandidateID: String?
    public let stopBeforeLocalAlpha: Bool

    public init(
        schemaVersion: Int,
        gate: GateName,
        benchmarkID: String,
        decisions: [CandidateGateDecision],
        selectedCandidateID: String?,
        stopBeforeLocalAlpha: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.gate = gate
        self.benchmarkID = benchmarkID
        self.decisions = decisions
        self.selectedCandidateID = selectedCandidateID
        self.stopBeforeLocalAlpha = stopBeforeLocalAlpha
    }
}
