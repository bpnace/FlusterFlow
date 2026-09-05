import Darwin
import Foundation

struct AppPaths: Sendable {
    let applicationSupportDirectory: URL
    let modelsDirectory: URL

    init(applicationSupportDirectory: URL) {
        let root = applicationSupportDirectory
            .appendingPathComponent("FlusterFlow", isDirectory: true)
        self.applicationSupportDirectory = root
        modelsDirectory = root.appendingPathComponent("Models", isDirectory: true)
    }

    var modelDirectory: URL {
        modelDirectory(for: .parakeetV3Int8)
    }

    func modelDirectory(for manifest: ModelManifest) -> URL {
        manifest.installationDirectory(in: modelsDirectory)
    }

    static func live(fileManager: FileManager = .default) -> Self {
        guard let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            preconditionFailure("Application Support directory unavailable")
        }
        return Self(applicationSupportDirectory: base)
    }
}

struct ExtractingTargetContextProvider: TargetContextProviding {
    private let provider: any TargetContextProviding
    private let extractor: ContextTermExtractor

    init(
        provider: any TargetContextProviding,
        extractor: ContextTermExtractor = ContextTermExtractor()
    ) {
        self.provider = provider
        self.extractor = extractor
    }

    func capture(for sessionID: DictationSessionID) async throws -> CapturedTargetContext {
        let target = try await captureTarget(for: sessionID)
        return try await enrichContext(for: target, sessionID: sessionID)
    }

    func captureTarget(for sessionID: DictationSessionID) async throws -> CapturedTargetContext {
        try await provider.captureTarget(for: sessionID)
    }

    func enrichContext(
        for capturedTarget: CapturedTargetContext,
        sessionID: DictationSessionID
    ) async throws -> CapturedTargetContext {
        let captured = try await provider.enrichContext(
            for: capturedTarget,
            sessionID: sessionID
        )
        guard captured.context.availability == .available,
              let boundedText = captured.context.boundedText else {
            return captured
        }
        return CapturedTargetContext(
            target: captured.target,
            context: ContextSnapshot(
                availability: captured.context.availability,
                targetKind: captured.context.targetKind,
                boundedText: boundedText,
                termHints: extractor.extract(from: boundedText),
                localCategory: captured.context.localCategory,
                safeDecoderHints: captured.context.safeDecoderHints
            )
        )
    }

    func cancel(sessionID: DictationSessionID) async {
        await provider.cancel(sessionID: sessionID)
    }
}

private struct TimedAudioCapture: AudioCapturing, IncrementalAudioProviding {
    let capture: any AudioCapturing
    let diagnostics: ContentFreeDiagnostics
    let sessionDiagnostics: ContentFreeSessionDiagnostics

    func startCapture(for sessionID: DictationSessionID) async throws {
        try await capture.startCapture(for: sessionID)
    }

    func finishCapture(for sessionID: DictationSessionID) async throws -> AudioInput {
        let capture = capture
        let input = try await diagnostics.measure(stage: .audioFinalize, sessionID: sessionID) {
            try await capture.finishCapture(for: sessionID)
        }
        await sessionDiagnostics.recordAudio(input, sessionID: sessionID)
        diagnostics.audioCaptureSummary(
            speechDetected: input.hasDetectedSpeech,
            durationClass: DiagnosticASRDurationClass(
                seconds: input.timing?.originalDurationSeconds ?? 0
            ),
            processedClass: DiagnosticProcessedAudioClass(
                seconds: input.timing?.processedDurationSeconds ?? 0
            ),
            speechRatioClass: DiagnosticSpeechRatioClass(
                timing: input.timing
            ),
            gainClass: DiagnosticGainClass(
                gain: input.timing?.appliedGain ?? 1
            ),
            inputSignalClass: DiagnosticSignalLevelClass(
                rms: input.timing?.inputRMS ?? 0
            ),
            normalizedSignalClass: DiagnosticSignalLevelClass(
                rms: input.timing?.normalizedRMS ?? 0
            ),
            normalizedPeakClass: DiagnosticPeakClass(
                peak: input.timing?.normalizedPeak ?? 0
            ),
            sessionID: sessionID
        )
        return input
    }

    func cancelCapture(for sessionID: DictationSessionID) async {
        await capture.cancelCapture(for: sessionID)
    }

    func release(_ input: AudioInput) async {
        await capture.release(input)
    }

    func incrementalAudioBatch(
        for sessionID: DictationSessionID,
        afterFrameOffset frameOffset: Int
    ) async throws -> IncrementalAudioBatch? {
        guard let provider = capture as? any IncrementalAudioProviding else {
            return nil
        }
        return try await provider.incrementalAudioBatch(
            for: sessionID,
            afterFrameOffset: frameOffset
        )
    }
}

private struct TimedSpeechRecognizer: SpeechRecognizing, SpeechRecognitionLifecycle {
    let recognizer: any SpeechRecognizing
    let diagnostics: ContentFreeDiagnostics
    let sessionDiagnostics: ContentFreeSessionDiagnostics

    func transcribe(
        _ audio: AudioInput,
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws -> RawTranscript {
        let recognizer = recognizer
        let clock = ContinuousClock()
        let startedAt = clock.now
        let transcript = try await diagnostics.measure(stage: .asr, sessionID: sessionID) {
            try await recognizer.transcribe(audio, hints: hints, sessionID: sessionID)
        }
        await sessionDiagnostics.recordRecognition(
            transcript,
            latencyMilliseconds: Self.milliseconds(startedAt.duration(to: clock.now)),
            sessionID: sessionID
        )
        return transcript
    }

    func cancel(sessionID: DictationSessionID) async {
        await recognizer.cancel(sessionID: sessionID)
    }

    func prepareForRecording(
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws {
        guard let lifecycle = recognizer as? any SpeechRecognitionLifecycle else { return }
        try await lifecycle.prepareForRecording(hints: hints, sessionID: sessionID)
    }

    func startRecognitionSession(
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws {
        guard let lifecycle = recognizer as? any SpeechRecognitionLifecycle else { return }
        try await lifecycle.startRecognitionSession(hints: hints, sessionID: sessionID)
    }

    func updateRecognitionSession(
        with chunk: RecognitionAudioChunk,
        sessionID: DictationSessionID
    ) async throws -> RecognitionChunkDisposition {
        guard let lifecycle = recognizer as? any SpeechRecognitionLifecycle else {
            return .ignoredBatchRecognizer
        }
        return try await lifecycle.updateRecognitionSession(with: chunk, sessionID: sessionID)
    }

    func stopRecognitionSession(sessionID: DictationSessionID) async {
        guard let lifecycle = recognizer as? any SpeechRecognitionLifecycle else { return }
        await lifecycle.stopRecognitionSession(sessionID: sessionID)
    }

    func finalizeRecognitionSession(
        _ audio: AudioInput,
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws -> RawTranscript {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let transcript: RawTranscript
        if let lifecycle = recognizer as? any SpeechRecognitionLifecycle {
            transcript = try await diagnostics.measure(stage: .asr, sessionID: sessionID) {
                try await lifecycle.finalizeRecognitionSession(
                    audio,
                    hints: hints,
                    sessionID: sessionID
                )
            }
        } else {
            transcript = try await diagnostics.measure(stage: .asr, sessionID: sessionID) {
                try await recognizer.transcribe(audio, hints: hints, sessionID: sessionID)
            }
        }
        await sessionDiagnostics.recordRecognition(
            transcript,
            latencyMilliseconds: Self.milliseconds(startedAt.duration(to: clock.now)),
            sessionID: sessionID
        )
        return transcript
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return (Double(components.seconds) * 1_000)
            + (Double(components.attoseconds) / 1_000_000_000_000_000)
    }
}

actor ContentFreeSessionDiagnostics {
    private struct Observation: Sendable {
        var audioTiming: AudioTimingMetadata? = nil
        var transcript: RawTranscript? = nil
        var asrLatencyMilliseconds: Double? = nil
        var prewarmSucceeded: Bool? = nil
        var prewarmLatencyMilliseconds: Double? = nil
    }

    private var observations: [DictationSessionID: Observation] = [:]
    private var warmedModels: Set<DiagnosticASRModel> = []
    private var finalizedSessions: Set<DictationSessionID> = []
    private var finalizationOrder: [DictationSessionID] = []

    func recordAudio(_ input: AudioInput, sessionID: DictationSessionID) {
        guard !finalizedSessions.contains(sessionID) else { return }
        var observation = observations[sessionID] ?? Observation()
        observation.audioTiming = input.timing
        observations[sessionID] = observation
    }

    func recordRecognition(
        _ transcript: RawTranscript,
        latencyMilliseconds: Double,
        sessionID: DictationSessionID
    ) {
        guard !finalizedSessions.contains(sessionID) else { return }
        var observation = observations[sessionID] ?? Observation()
        observation.transcript = transcript
        observation.asrLatencyMilliseconds = max(0, latencyMilliseconds)
        observations[sessionID] = observation
    }

    func recordPrewarm(
        succeeded: Bool,
        latencyMilliseconds: Double,
        sessionID: DictationSessionID
    ) {
        guard !finalizedSessions.contains(sessionID) else { return }
        var observation = observations[sessionID] ?? Observation()
        observation.prewarmSucceeded = succeeded
        observation.prewarmLatencyMilliseconds = max(0, latencyMilliseconds)
        observations[sessionID] = observation
    }

    func finalize(
        sessionID: DictationSessionID,
        diagnostics: ContentFreeDiagnostics
    ) async {
        let observation = observations.removeValue(forKey: sessionID)
        markFinalized(sessionID)
        guard let observation,
              let transcript = observation.transcript,
              let backend = transcript.backend,
              let asrLatency = observation.asrLatencyMilliseconds else {
            return
        }
        let model: DiagnosticASRModel = transcript.adaptive == nil
            ? DiagnosticASRModel(backend)
            : .adaptiveWhisperKit

        let timing = observation.audioTiming
        let totalLatency = await diagnostics.metrics.samples(for: sessionID)
            .last(where: { $0.stage == .total })?
            .durationMilliseconds
        let temperature: DiagnosticASRTemperatureClass = warmedModels.insert(model).inserted
            ? .cold
            : .warm
        await diagnostics.recordASRRuntime(
            model: model,
            durationClass: DiagnosticASRDurationClass(
                seconds: timing?.originalDurationSeconds ?? 0
            ),
            temperatureClass: temperature,
            confidenceClass: DiagnosticASRConfidenceClass(transcript),
            usedAdaptiveFallback: (transcript.adaptive?.attemptedBackends.count ?? 1) > 1,
            prewarmSucceeded: observation.prewarmSucceeded,
            prewarmLatencyMilliseconds: observation.prewarmLatencyMilliseconds,
            vadSpeechDetected: timing.map { !$0.isSilent },
            vadLatencyMilliseconds: timing?.vadProcessingMilliseconds,
            asrLatencyMilliseconds: asrLatency,
            endToInsertMilliseconds: totalLatency,
            peakRSSBytes: Self.peakResidentBytes()
        )
    }

    func cancel(sessionID: DictationSessionID) {
        observations[sessionID] = nil
        markFinalized(sessionID)
    }

    private func markFinalized(_ sessionID: DictationSessionID) {
        if finalizedSessions.insert(sessionID).inserted {
            finalizationOrder.append(sessionID)
        }
        if finalizationOrder.count > 256 {
            let expiredCount = finalizationOrder.count - 256
            let expired = Array(finalizationOrder.prefix(expiredCount))
            finalizationOrder.removeFirst(expiredCount)
            finalizedSessions.subtract(expired)
        }
    }

    private static func peakResidentBytes() -> Int64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return max(0, Int64(usage.ru_maxrss))
    }
}

private extension DiagnosticASRModel {
    init(_ backend: RecognitionBackend) {
        switch backend {
        case .parakeetV3Int8: self = .parakeetV3Int8
        case .qwen3ASR06B8Bit: self = .qwen3ASR06B8Bit
        case .whisperKitLargeV3: self = .whisperKitLargeV3
        case .whisperKitLargeV3Turbo: self = .whisperKitLargeV3Turbo
        case .adaptiveWhisperKit: self = .adaptiveWhisperKit
        }
    }
}

private extension DiagnosticASRDurationClass {
    init(seconds: Double) {
        switch seconds {
        case ..<10: self = .short
        case ..<30: self = .medium
        default: self = .long
        }
    }
}

private extension DiagnosticProcessedAudioClass {
    init(seconds: Double) {
        switch seconds {
        case ..<1: self = .subsecond
        case ..<3: self = .oneToThreeSeconds
        case ..<10: self = .threeToTenSeconds
        default: self = .overTenSeconds
        }
    }
}

private extension DiagnosticSpeechRatioClass {
    init(timing: AudioTimingMetadata?) {
        guard let timing, timing.originalDurationSeconds > 0 else {
            self = .low
            return
        }
        let ratio = timing.detectedSpeechDurationSeconds / timing.originalDurationSeconds
        switch ratio {
        case ..<0.15: self = .low
        case ..<0.5: self = .medium
        default: self = .high
        }
    }
}

private extension DiagnosticGainClass {
    init(gain: Float) {
        switch gain {
        case ...1.05: self = .none
        case ..<3: self = .moderate
        default: self = .high
        }
    }
}

private extension DiagnosticSignalLevelClass {
    init(rms: Float) {
        switch rms {
        case ...0.000_1: self = .silent
        case ..<0.002: self = .veryLow
        case ..<0.015: self = .low
        case ...0.16: self = .usable
        default: self = .high
        }
    }
}

private extension DiagnosticPeakClass {
    init(peak: Float) {
        switch peak {
        case ..<0.02: self = .low
        case ..<0.9: self = .usable
        case ..<1: self = .nearClipping
        default: self = .clipped
        }
    }
}

private extension DiagnosticASRConfidenceClass {
    init(_ transcript: RawTranscript) {
        let logprob = transcript.avgLogprob
        let wordProbability = transcript.minWordProbability
        guard logprob != nil || wordProbability != nil else {
            self = .unknown
            return
        }
        if logprob.map({ $0 < -0.8 }) == true
            || wordProbability.map({ $0 < 0.65 }) == true {
            self = .low
        } else if logprob.map({ $0 >= -0.4 }) != false
                    && wordProbability.map({ $0 >= 0.8 }) != false {
            self = .high
        } else {
            self = .medium
        }
    }
}

private struct TimedTextCleanup: TextCleaning {
    let cleanup: any TextCleaning
    let diagnostics: ContentFreeDiagnostics

    func clean(
        _ transcript: RawTranscript,
        context: ContextSnapshot,
        sessionID: DictationSessionID
    ) async throws -> LocalCandidate {
        let cleanup = cleanup
        return try await diagnostics.measure(stage: .cleanup, sessionID: sessionID) {
            try await cleanup.clean(transcript, context: context, sessionID: sessionID)
        }
    }
}

private struct TimedTextEnrichment: TextEnriching {
    let enrichment: any TextEnriching
    let diagnostics: ContentFreeDiagnostics

    func enrich(
        _ candidate: LocalCandidate,
        context: ContextSnapshot,
        consent: ConsentSnapshot,
        sessionID: DictationSessionID
    ) async throws -> EnrichedCandidate {
        let enrichment = enrichment
        return try await diagnostics.measure(stage: .cloud, sessionID: sessionID) {
            try await enrichment.enrich(
                candidate,
                context: context,
                consent: consent,
                sessionID: sessionID
            )
        }
    }

    func cancel(sessionID: DictationSessionID) async {
        await enrichment.cancel(sessionID: sessionID)
    }
}

private struct TimedTextRewriter: TextRewriting {
    let rewriter: any TextRewriting
    let diagnostics: ContentFreeDiagnostics

    var identifier: TextRewriterIdentifier {
        rewriter.identifier
    }

    func rewrite(_ request: TextRewriteRequest) async -> TextRewriteResult {
        let rewriter = rewriter
        let clock = ContinuousClock()
        let startedAt = clock.now
        let result = await rewriter.rewrite(request)
        await diagnostics.recordRewriteRuntime(
            rewriter: rewriter.identifier,
            outcome: DiagnosticRewriteOutcome(result.outcome),
            reason: DiagnosticRewriteReason(result),
            outputLengthClass: DiagnosticRewriteOutputLengthClass(result.outputText),
            latencyMilliseconds: Self.milliseconds(startedAt.duration(to: clock.now)),
            sanitizerActionCount: result.sanitizerActionCount
        )
        return result
    }

    func cancel(sessionID: DictationSessionID) async {
        await rewriter.cancel(sessionID: sessionID)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return (Double(components.seconds) * 1_000)
            + (Double(components.attoseconds) / 1_000_000_000_000_000)
    }
}

private struct TimedTextInserter: TextInserting {
    let inserter: any TextInserting
    let diagnostics: ContentFreeDiagnostics

    func insert(
        _ candidate: FinalCandidate,
        sessionID: DictationSessionID
    ) async throws -> InsertionOutcome {
        let inserter = inserter
        return try await diagnostics.measure(stage: .insertion, sessionID: sessionID) {
            try await inserter.insert(candidate, sessionID: sessionID)
        }
    }

    func requestCancellation(
        sessionID: DictationSessionID
    ) async -> InsertionCancellationDisposition {
        await inserter.requestCancellation(sessionID: sessionID)
    }

    func releaseInsertionSession(sessionID: DictationSessionID) async {
        await inserter.releaseInsertionSession(sessionID: sessionID)
    }
}

struct ContextCorrectingCleanupPipeline: TextCleaning {
    private let corrector: ContextualTermCorrector
    private let personalCorrector: PersonalLexiconCorrector
    private let cleanup: DeterministicCleanupEngine
    private let entriesProvider: @Sendable (DictationLanguage) async -> [PersonalLexiconEntry]

    init(
        corrector: ContextualTermCorrector = ContextualTermCorrector(),
        personalCorrector: PersonalLexiconCorrector = PersonalLexiconCorrector(),
        cleanup: DeterministicCleanupEngine = DeterministicCleanupEngine(),
        entriesProvider: @escaping @Sendable (DictationLanguage) async -> [PersonalLexiconEntry] = { _ in [] }
    ) {
        self.corrector = corrector
        self.personalCorrector = personalCorrector
        self.cleanup = cleanup
        self.entriesProvider = entriesProvider
    }

    func clean(
        _ transcript: RawTranscript,
        context: ContextSnapshot,
        sessionID: DictationSessionID
    ) async throws -> LocalCandidate {
        let entries = await entriesProvider(transcript.language)
        let personalText = personalCorrector.correct(
            transcript.text,
            entries: entries,
            language: transcript.language
        )
        let corrected = RawTranscript(
            text: corrector.correct(
                personalText,
                terms: context.safeDecoderHints + context.termHints
            ),
            language: transcript.language,
            backend: transcript.backend,
            segments: transcript.segments,
            wordProbabilities: transcript.wordProbabilities,
            avgLogprob: transcript.avgLogprob,
            minWordProbability: transcript.minWordProbability,
            compressionRatio: transcript.compressionRatio,
            decoderFallback: transcript.decoderFallback,
            adaptive: transcript.adaptive
        )
        return try await cleanup.clean(
            corrected,
            context: context,
            sessionID: sessionID
        )
    }
}

struct EphemeralFallbackResult: Equatable, Sendable, Identifiable {
    let sessionID: DictationSessionID
    let rawTranscript: String
    let candidateText: String?

    var id: UInt64 { sessionID.rawValue }
    var text: String { candidateText ?? rawTranscript }
}

actor EphemeralResultStore: EphemeralTextPreserving {
    private var result: EphemeralFallbackResult?
    private var finalizedSessions: Set<DictationSessionID> = []
    private var finalizationOrder: [DictationSessionID] = []

    func preserveRawTranscript(_ text: String, for sessionID: DictationSessionID) {
        guard !text.isEmpty,
              !finalizedSessions.contains(sessionID),
              result == nil || result?.sessionID == sessionID else {
            return
        }
        result = EphemeralFallbackResult(
            sessionID: sessionID,
            rawTranscript: text,
            candidateText: result?.candidateText
        )
    }

    func preserveCandidate(_ text: String, for sessionID: DictationSessionID) {
        guard !text.isEmpty,
              !finalizedSessions.contains(sessionID),
              let current = result,
              current.sessionID == sessionID else {
            return
        }
        result = EphemeralFallbackResult(
            sessionID: sessionID,
            rawTranscript: current.rawTranscript,
            candidateText: text
        )
    }

    func confirmInsertion(sessionID: DictationSessionID) {
        finalize(sessionID)
    }

    func discardEphemeralText(sessionID: DictationSessionID) {
        finalize(sessionID)
    }

    func oldest() -> EphemeralFallbackResult? {
        result
    }

    @discardableResult
    func discard(sessionID: DictationSessionID) -> Bool {
        let didDiscard = result?.sessionID == sessionID
        finalize(sessionID)
        return didDiscard
    }

    func removeAll() {
        if let sessionID = result?.sessionID {
            finalize(sessionID)
        }
    }

    func count() -> Int {
        result == nil ? 0 : 1
    }

    private func finalize(_ sessionID: DictationSessionID) {
        if result?.sessionID == sessionID {
            result = nil
        }
        if finalizedSessions.insert(sessionID).inserted {
            finalizationOrder.append(sessionID)
        }
        if finalizationOrder.count > 256 {
            let expiredCount = finalizationOrder.count - 256
            let expired = Array(finalizationOrder.prefix(expiredCount))
            finalizationOrder.removeFirst(expiredCount)
            finalizedSessions.subtract(expired)
        }
    }
}

actor SessionAwareOpenAIEnrichment: TextEnriching {
    typealias ModelResolver = @Sendable () async -> CloudModelIdentifier

    private let gate: CloudGate
    private let transport: any CloudTextTransport
    private let validator: any CloudMeaningValidating
    private let modelResolver: ModelResolver
    private var languages: [DictationSessionID: DictationLanguage] = [:]
    private var providers: [DictationSessionID: OpenAIEnrichmentProvider] = [:]

    init(
        gate: CloudGate,
        transport: any CloudTextTransport,
        validator: any CloudMeaningValidating = MeaningPreservationPolicy(),
        modelResolver: @escaping ModelResolver = { .defaultEfficientModel }
    ) {
        self.gate = gate
        self.transport = transport
        self.validator = validator
        self.modelResolver = modelResolver
    }

    func register(language: DictationLanguage, for sessionID: DictationSessionID) {
        languages[sessionID] = language
    }

    func enrich(
        _ candidate: LocalCandidate,
        context: ContextSnapshot,
        consent: ConsentSnapshot,
        sessionID: DictationSessionID
    ) async throws -> EnrichedCandidate {
        let cloudLanguage = CloudLanguage(languages[sessionID] ?? .automatic)
        let model = await modelResolver()
        let provider = OpenAIEnrichmentProvider(
            gate: gate,
            transport: transport,
            validator: validator,
            model: model,
            metadataResolver: { context, _ in
                CloudRequestMetadata(language: cloudLanguage, context: context)
            }
        )
        providers[sessionID] = provider
        defer {
            providers[sessionID] = nil
            languages[sessionID] = nil
        }
        return try await provider.enrich(
            candidate,
            context: context,
            consent: consent,
            sessionID: sessionID
        )
    }

    func cancel(sessionID: DictationSessionID) async {
        languages[sessionID] = nil
        if let provider = providers.removeValue(forKey: sessionID) {
            await provider.cancel(sessionID: sessionID)
        }
    }
}

private extension CloudLanguage {
    init(_ language: DictationLanguage) {
        switch language {
        case .automatic: self = .automatic
        case .german: self = .german
        case .english: self = .english
        }
    }
}

struct DictationComposition {
    let coordinator: DictationCoordinator
    let enrichment: SessionAwareOpenAIEnrichment
    let localRewriter: FoundationModelsTextRewriter
    let fallbackResults: EphemeralResultStore
    let sessionDiagnostics: ContentFreeSessionDiagnostics

    static func live(
        settings: SettingsStore,
        audioSamples: AudioBufferStore,
        recognizer: any SpeechRecognizing,
        personalLexicon: PersonalLexiconStore,
        keyStore: any APIKeyStoring,
        diagnostics: ContentFreeDiagnostics,
        recordingHistory: (any RecordingHistoryRecording)? = nil,
        transport: any CloudTextTransport = OpenAITransport()
    ) -> Self {
        let targets = AccessibilityTargetRegistry(
            isCorrectionLearningEnabled: { @MainActor [weak settings] in
                settings?.localLearningEnabled ?? false
            },
            correctionLanguage: { @MainActor [weak settings] in
                settings?.language ?? .automatic
            },
            correctionSink: { [weak settings, weak personalLexicon] correction in
                let learningEnabled = await settings?.localLearningEnabled ?? false
                guard learningEnabled else { return }
                let entries = await personalLexicon?.entries ?? []
                let learningStore = LocalPersonalLexiconStore(entries: entries)
                let result = await learningStore.learn(from: correction)
                await personalLexicon?.applyLearningResult(result)
            }
        )
        let context = ExtractingTargetContextProvider(
            provider: AccessibilityContextService(
                registry: targets,
                contextEnabled: { @MainActor [weak settings] in
                    settings?.contextAwarenessEnabled ?? false
                }
            )
        )
        let enrichment = SessionAwareOpenAIEnrichment(
            gate: CloudGate(keyStore: keyStore),
            transport: transport,
            validator: MeaningPreservationPolicy(),
            modelResolver: { @MainActor [weak settings] in
                settings?.cloudModel.identifier ?? .defaultEfficientModel
            }
        )
        let localRewriter = FoundationModelsTextRewriter()
        let lexiconEntries: @Sendable (DictationLanguage) async -> [PersonalLexiconEntry] = {
            [weak personalLexicon] language in
            await personalLexicon?.entries(for: language) ?? []
        }
        let prioritizedLexiconTerms: @Sendable (DictationLanguage) async -> [String] = {
            [weak personalLexicon] language in
            await personalLexicon?.prioritizedDecoderTerms(for: language) ?? []
        }
        let fallbackResults = EphemeralResultStore()
        let sessionDiagnostics = ContentFreeSessionDiagnostics()
        let insertion = StrictLocalTextInserter(targets: targets)
        let coordinator = DictationCoordinator(
            contextProvider: context,
            audioCapture: TimedAudioCapture(
                capture: AVAudioEngineCapture(store: audioSamples),
                diagnostics: diagnostics,
                sessionDiagnostics: sessionDiagnostics
            ),
            recognizer: TimedSpeechRecognizer(
                recognizer: recognizer,
                diagnostics: diagnostics,
                sessionDiagnostics: sessionDiagnostics
            ),
            cleanup: TimedTextCleanup(
                cleanup: ContextCorrectingCleanupPipeline(
                    entriesProvider: lexiconEntries
                ),
                diagnostics: diagnostics
            ),
            enrichment: TimedTextEnrichment(
                enrichment: enrichment,
                diagnostics: diagnostics
            ),
            localRewriter: TimedTextRewriter(
                rewriter: localRewriter,
                diagnostics: diagnostics
            ),
            insertion: TimedTextInserter(
                inserter: insertion,
                diagnostics: diagnostics
            ),
            fallbackText: fallbackResults,
            recordingHistory: recordingHistory,
            prioritizedLexiconTerms: prioritizedLexiconTerms
        )
        return Self(
            coordinator: coordinator,
            enrichment: enrichment,
            localRewriter: localRewriter,
            fallbackResults: fallbackResults,
            sessionDiagnostics: sessionDiagnostics
        )
    }
}

private extension DiagnosticRewriteOutcome {
    init(_ outcome: TextRewriteResult.Outcome) {
        switch outcome {
        case .accepted: self = .accepted
        case .rejected: self = .rejected
        case .unavailable: self = .unavailable
        case .failed: self = .failed
        case .cancelled: self = .cancelled
        }
    }
}

private extension DiagnosticRewriteReason {
    init(_ result: TextRewriteResult) {
        if let unavailableReason = result.unavailableReason {
            self.init(unavailableReason)
        } else if let failureReason = result.failureReason {
            self.init(failureReason)
        } else if result.validationIssues.count == 1,
                  let issue = result.validationIssues.first {
            self.init(issue)
        } else if result.validationIssues.count > 1 {
            self = .multipleValidationIssues
        } else {
            self = .none
        }
    }

    init(_ reason: TextRewriteUnavailableReason) {
        switch reason {
        case .frameworkUnavailable: self = .frameworkUnavailable
        case .operatingSystemUnsupported: self = .operatingSystemUnsupported
        case .modelUnavailable: self = .modelUnavailable
        case .unsupportedLanguage: self = .unsupportedLanguage
        case .sensitiveContextDenied: self = .sensitiveContextDenied
        }
    }

    init(_ reason: TextRewriteFailureReason) {
        switch reason {
        case .invalidModelOutput: self = .invalidModelOutput
        case .generationFailed: self = .generationFailed
        }
    }

    init(_ issue: TextRewriteValidationIssue) {
        switch issue {
        case .lostProtectedAnchor: self = .lostProtectedAnchor
        case .lostProtectedContextTerm: self = .lostProtectedContextTerm
        case .inventedClaim: self = .inventedClaim
        case .excessiveDeviation: self = .excessiveDeviation
        case .unknownMeaningChange: self = .unknownMeaningChange
        }
    }
}

private extension DiagnosticRewriteOutputLengthClass {
    init(_ text: String) {
        switch text.count {
        case 0: self = .empty
        case ..<80: self = .short
        case ..<400: self = .medium
        default: self = .long
        }
    }
}
