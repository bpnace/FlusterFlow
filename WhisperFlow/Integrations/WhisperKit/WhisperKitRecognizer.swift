@preconcurrency import WhisperKit
import Foundation
import OSLog

enum WhisperKitLanguageMode: Equatable, Sendable {
    case automatic
    case german
    case english
}

protocol WhisperKitRuntimeServing: Sendable {
    func prepare(modelDirectory: URL, tokenizerDirectory: URL) async throws
    func prewarm(modelDirectory: URL, tokenizerDirectory: URL) async throws
    func unload() async
    func prioritizedPromptTokens(for terms: [String], maxTokens: Int) async throws -> [Int]
    func transcribe(
        samples: [Float],
        language: WhisperKitLanguageMode,
        promptTokens: [Int],
        sessionID: DictationSessionID
    ) async throws -> WhisperKitRecognitionResult
    func cancel(sessionID: DictationSessionID) async
}

struct WhisperKitRecognitionResult: Equatable, Sendable {
    let text: String
    let segments: [RecognitionSegmentMetadata]
    let avgLogprob: Float?
    let minWordProbability: Float?
    let compressionRatio: Float?
    let decoderFallback: RecognitionDecoderFallback
}

enum WhisperKitRecognizerError: Error, Equatable, Sendable {
    case unsupportedAudioFormat(sampleRate: Int, channelCount: Int)
    case emptyAudio
    case tokenizerInvalid
    case runtimePreparationFailed
    case runtimeBusy
    case runtimeTranscriptionFailed
    case emptyTranscription
}

extension WhisperKitRecognizerError: SpeechRecognitionFailureClassifying {
    var indicatesNoSpeech: Bool {
        false
    }
}

enum WhisperKitFailureCode: String, Equatable, Sendable {
    case unsupportedAudioFormat
    case emptyAudio
    case tokenizerInvalid
    case runtimePreparationFailed
    case runtimeBusy
    case modelUnavailable
    case audioProcessingFailed
    case decoderInputFailed
    case decodingFailed
    case transcriptionFailed
    case emptyTranscription
    case unknown
}

private enum WhisperKitPerformanceBackend: String {
    case turbo
    case large
    case unspecified
}

private enum WhisperKitPreparationOperation: String {
    case transcription
    case prewarm
}

private enum WhisperKitPreparationPath: String {
    case ready
    case waiting
    case prepared
    case loading
}

private enum WhisperKitPerformanceOutcome: String {
    case success
    case failure
    case cancelled
}

actor WhisperKitRecognizer: SpeechRecognizing, SpeechRecognitionLifecycle {
    static let promptTokenBudget = 128

    private struct IncrementalSession: Sendable {
        var acceptedSampleCount: Int
    }

    private struct PrewarmOperation: Sendable {
        let id: UInt64
        let task: Task<Void, Error>
    }

    private struct PrepareOperation: Sendable {
        let id: UInt64
        let task: Task<Void, Error>
    }

    private let sampleAccess: any AudioSampleAccessing
    private let modelStore: any LocalModelChecking
    private let tokenizerStore: any LocalModelChecking
    private let runtime: any WhisperKitRuntimeServing
    private let backend: RecognitionBackend?
    private let logger = Logger(subsystem: "local.flusterflow", category: "asr")
    private let performanceLogger = Logger(
        subsystem: "local.flusterflow",
        category: "performance"
    )
    private var runtimePrepared = false
    private var runtimePrewarmed = false
    private var nextPrepareOperationID: UInt64 = 0
    private var prepareOperation: PrepareOperation?
    private var nextPrewarmOperationID: UInt64 = 0
    private var prewarmOperation: PrewarmOperation?
    private var incrementalSessions: [DictationSessionID: IncrementalSession] = [:]

    init(
        sampleAccess: any AudioSampleAccessing,
        modelStore: any LocalModelChecking,
        tokenizerStore: any LocalModelChecking,
        backend: RecognitionBackend? = nil,
        runtime: any WhisperKitRuntimeServing = OfflineWhisperKitRuntime()
    ) {
        self.sampleAccess = sampleAccess
        self.modelStore = modelStore
        self.tokenizerStore = tokenizerStore
        self.backend = backend
        self.runtime = runtime
    }

    func transcribe(
        _ audio: AudioInput,
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws -> RawTranscript {
        do {
            try await measurePreparation(
                operation: .transcription,
                path: preparationPathForTranscription()
            ) {
                try await prepareIfNeeded()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logFailure(Self.failureCode(for: error))
            throw error
        }
        try Task.checkCancellation()
        let audioSamples = try await sampleAccess.samples(for: audio)
        try Task.checkCancellation()
        guard audioSamples.sampleRate == AudioSamples.recognizerSampleRate,
              audioSamples.channelCount == 1 else {
            logFailure(.unsupportedAudioFormat)
            throw WhisperKitRecognizerError.unsupportedAudioFormat(
                sampleRate: audioSamples.sampleRate,
                channelCount: audioSamples.channelCount
            )
        }
        guard !audioSamples.values.isEmpty else {
            logFailure(.emptyAudio)
            throw WhisperKitRecognizerError.emptyAudio
        }

        let result: WhisperKitRecognitionResult
        do {
            result = try await measureDecode(sampleCount: audioSamples.values.count) {
                try Task.checkCancellation()
                return try await runtime.transcribe(
                    samples: audioSamples.values,
                    language: Self.languageMode(for: hints.language),
                    promptTokens: [],
                    sessionID: sessionID
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let failureCode = Self.failureCode(for: error)
            logFailure(failureCode)
            if let recognizerError = error as? WhisperKitRecognizerError {
                throw recognizerError
            }
            throw WhisperKitRecognizerError.runtimeTranscriptionFailed
        }
        let normalized = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            logFailure(.emptyTranscription)
            throw WhisperKitRecognizerError.emptyTranscription
        }
        return RawTranscript(
            text: normalized,
            language: hints.language,
            backend: backend,
            segments: result.segments,
            wordProbabilities: result.segments.flatMap(\.wordProbabilities),
            avgLogprob: result.avgLogprob,
            minWordProbability: result.minWordProbability,
            compressionRatio: result.compressionRatio,
            decoderFallback: result.decoderFallback
        )
    }

    func cancel(sessionID: DictationSessionID) async {
        incrementalSessions[sessionID] = nil
        await cancelModelOperations()
        await runtime.cancel(sessionID: sessionID)
    }

    func prepareForRecording(
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws {
        _ = hints
        _ = sessionID
        try await prewarm()
    }

    func startRecognitionSession(
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws {
        _ = hints
        try await prewarm()
        incrementalSessions[sessionID] = IncrementalSession(acceptedSampleCount: 0)
    }

    func updateRecognitionSession(
        with chunk: RecognitionAudioChunk,
        sessionID: DictationSessionID
    ) async throws -> RecognitionChunkDisposition {
        guard chunk.sampleRate == AudioSamples.recognizerSampleRate,
              chunk.channelCount == 1 else {
            throw WhisperKitRecognizerError.unsupportedAudioFormat(
                sampleRate: chunk.sampleRate,
                channelCount: chunk.channelCount
            )
        }
        guard var incremental = incrementalSessions.removeValue(forKey: sessionID) else {
            return .ignoredBatchRecognizer
        }

        incremental.acceptedSampleCount += chunk.samples.count
        incrementalSessions[sessionID] = incremental
        return .accepted
    }

    func stopRecognitionSession(sessionID: DictationSessionID) async {
        incrementalSessions[sessionID] = nil
        await runtime.cancel(sessionID: sessionID)
    }

    func finalizeRecognitionSession(
        _ audio: AudioInput,
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws -> RawTranscript {
        incrementalSessions[sessionID] = nil
        return try await transcribe(audio, hints: hints, sessionID: sessionID)
    }

    func prewarm() async throws {
        try await measurePreparation(
            operation: .prewarm,
            path: preparationPathForPrewarm()
        ) {
            if runtimePrewarmed { return }
            if let operation = prewarmOperation {
                try await awaitPrewarm(operation)
                return
            }
            if let operation = prepareOperation {
                try await awaitPrepare(operation)
            }

            let modelDirectory = try await modelStore.validatedDirectory()
            let tokenizerDirectory = try await tokenizerStore.validatedDirectory()
            if runtimePrewarmed { return }
            if let operation = prewarmOperation {
                try await awaitPrewarm(operation)
                return
            }
            if let operation = prepareOperation {
                try await awaitPrepare(operation)
            }

            nextPrewarmOperationID &+= 1
            let operationID = nextPrewarmOperationID
            let runtime = runtime
            let task = Task<Void, Error> {
                try await runtime.prewarm(
                    modelDirectory: modelDirectory,
                    tokenizerDirectory: tokenizerDirectory
                )
            }
            let operation = PrewarmOperation(id: operationID, task: task)
            prewarmOperation = operation
            try await awaitPrewarm(operation)
        }
    }

    func unload() async {
        incrementalSessions.removeAll()
        await cancelModelOperations()
        runtimePrepared = false
        runtimePrewarmed = false
        await runtime.unload()
    }

    private func prepareIfNeeded() async throws {
        guard !runtimePrepared else { return }
        if let operation = prewarmOperation {
            try await awaitPrewarm(operation)
            return
        }
        if let operation = prepareOperation {
            try await awaitPrepare(operation)
            return
        }
        let modelDirectory = try await modelStore.validatedDirectory()
        let tokenizerDirectory = try await tokenizerStore.validatedDirectory()
        guard !runtimePrepared else { return }
        if let operation = prewarmOperation {
            try await awaitPrewarm(operation)
            return
        }
        if let operation = prepareOperation {
            try await awaitPrepare(operation)
            return
        }

        nextPrepareOperationID &+= 1
        let operationID = nextPrepareOperationID
        let runtime = runtime
        let task = Task<Void, Error> {
            try await runtime.prepare(
                modelDirectory: modelDirectory,
                tokenizerDirectory: tokenizerDirectory
            )
        }
        let operation = PrepareOperation(id: operationID, task: task)
        prepareOperation = operation
        try await awaitPrepare(operation)
    }

    private func preparationPathForTranscription() -> WhisperKitPreparationPath {
        if runtimePrepared { return .ready }
        if prewarmOperation != nil || prepareOperation != nil { return .waiting }
        return .loading
    }

    private func preparationPathForPrewarm() -> WhisperKitPreparationPath {
        if runtimePrewarmed { return .ready }
        if prewarmOperation != nil || prepareOperation != nil { return .waiting }
        if runtimePrepared { return .prepared }
        return .loading
    }

    private func measurePreparation(
        operation: WhisperKitPreparationOperation,
        path: WhisperKitPreparationPath,
        work: () async throws -> Void
    ) async throws {
        let clock = ContinuousClock()
        let startedAt = clock.now
        var outcome: WhisperKitPerformanceOutcome = .failure
        defer {
            let durationMilliseconds = startedAt
                .duration(to: clock.now)
                .whisperKitPerformanceMilliseconds
            performanceLogger.info(
                "performance=asrPreparation operation=\(operation.rawValue, privacy: .public) backend=\(self.performanceBackend.rawValue, privacy: .public) path=\(path.rawValue, privacy: .public) outcome=\(outcome.rawValue, privacy: .public) duration_ms=\(durationMilliseconds, privacy: .public)"
            )
        }

        do {
            try await work()
            outcome = .success
        } catch is CancellationError {
            outcome = .cancelled
            throw CancellationError()
        } catch {
            throw error
        }
    }

    private func measureDecode(
        sampleCount: Int,
        work: () async throws -> WhisperKitRecognitionResult
    ) async throws -> WhisperKitRecognitionResult {
        let clock = ContinuousClock()
        let startedAt = clock.now
        var outcome: WhisperKitPerformanceOutcome = .failure
        defer {
            let durationMilliseconds = startedAt
                .duration(to: clock.now)
                .whisperKitPerformanceMilliseconds
            let audioDurationMilliseconds = Double(sampleCount)
                / Double(AudioSamples.recognizerSampleRate)
                * 1_000
            performanceLogger.info(
                "performance=asrDecode backend=\(self.performanceBackend.rawValue, privacy: .public) outcome=\(outcome.rawValue, privacy: .public) audio_duration_ms=\(audioDurationMilliseconds, privacy: .public) duration_ms=\(durationMilliseconds, privacy: .public)"
            )
        }

        do {
            let result = try await work()
            outcome = .success
            return result
        } catch is CancellationError {
            outcome = .cancelled
            throw CancellationError()
        } catch {
            throw error
        }
    }

    private var performanceBackend: WhisperKitPerformanceBackend {
        switch backend {
        case .whisperKitLargeV3Turbo:
            return .turbo
        case .whisperKitLargeV3:
            return .large
        default:
            return .unspecified
        }
    }

    private func awaitPrepare(_ operation: PrepareOperation) async throws {
        do {
            try await operation.task.value
            if prepareOperation?.id == operation.id {
                runtimePrepared = true
                prepareOperation = nil
                return
            }
            guard runtimePrepared else { throw CancellationError() }
        } catch is CancellationError {
            if prepareOperation?.id == operation.id {
                prepareOperation = nil
            }
            throw CancellationError()
        } catch {
            if prepareOperation?.id == operation.id {
                prepareOperation = nil
            }
            throw WhisperKitRecognizerError.runtimePreparationFailed
        }
    }

    private func cancelModelOperations() async {
        let prepare = prepareOperation
        let prewarm = prewarmOperation
        prepare?.task.cancel()
        prewarm?.task.cancel()
        if let prepare {
            _ = await prepare.task.result
            if prepareOperation?.id == prepare.id {
                prepareOperation = nil
            }
        }
        if let prewarm {
            _ = await prewarm.task.result
            if prewarmOperation?.id == prewarm.id {
                prewarmOperation = nil
            }
        }
    }

    private func awaitPrewarm(_ operation: PrewarmOperation) async throws {
        do {
            try await operation.task.value
            if prewarmOperation?.id == operation.id {
                runtimePrepared = true
                runtimePrewarmed = true
                prewarmOperation = nil
                return
            }
            guard runtimePrewarmed else { throw CancellationError() }
        } catch is CancellationError {
            if prewarmOperation?.id == operation.id {
                prewarmOperation = nil
            }
            throw CancellationError()
        } catch {
            if prewarmOperation?.id == operation.id {
                prewarmOperation = nil
            }
            throw WhisperKitRecognizerError.runtimePreparationFailed
        }
    }

    private static func languageMode(for language: DictationLanguage) -> WhisperKitLanguageMode {
        switch language {
        case .automatic: .automatic
        case .german: .german
        case .english: .english
        }
    }

    private func logFailure(_ code: WhisperKitFailureCode) {
        let backendName = backend?.rawValue ?? "unspecified"
        logger.error(
            "backend=\(backendName, privacy: .public) failure=\(code.rawValue, privacy: .public)"
        )
    }

    nonisolated static func failureCode(for error: Error) -> WhisperKitFailureCode {
        if let recognizerError = error as? WhisperKitRecognizerError {
            switch recognizerError {
            case .unsupportedAudioFormat: return .unsupportedAudioFormat
            case .emptyAudio: return .emptyAudio
            case .tokenizerInvalid: return .tokenizerInvalid
            case .runtimePreparationFailed: return .runtimePreparationFailed
            case .runtimeBusy: return .runtimeBusy
            case .runtimeTranscriptionFailed: return .transcriptionFailed
            case .emptyTranscription: return .emptyTranscription
            }
        }
        if let whisperError = error as? WhisperError {
            switch whisperError {
            case .tokenizerUnavailable: return .tokenizerInvalid
            case .modelsUnavailable, .initializationError: return .modelUnavailable
            case .audioProcessingFailed, .loadAudioFailed: return .audioProcessingFailed
            case .prepareDecoderInputsFailed: return .decoderInputFailed
            case .decodingLogitsFailed, .decodingFailed, .segmentingFailed: return .decodingFailed
            case .transcriptionFailed: return .transcriptionFailed
            case .microphoneUnavailable: return .audioProcessingFailed
            }
        }
        return .unknown
    }
}

actor OfflineWhisperKitRuntime: WhisperKitRuntimeServing {
    private final class RuntimeBox: @unchecked Sendable {
        let whisperKit: WhisperKit

        init(_ whisperKit: WhisperKit) {
            self.whisperKit = whisperKit
        }
    }

    private struct ActiveTranscription: Sendable {
        let token: UUID
        let task: Task<WhisperKitRecognitionResult, Error>
    }

    private var runtime: RuntimeBox?
    private var preparedModelDirectory: URL?
    private var preparedTokenizerDirectory: URL?
    private var activeTasks: [DictationSessionID: ActiveTranscription] = [:]

    func prepare(modelDirectory: URL, tokenizerDirectory: URL) async throws {
        let modelDirectory = modelDirectory.standardizedFileURL
        let tokenizerDirectory = tokenizerDirectory.standardizedFileURL
        guard preparedModelDirectory != modelDirectory
                || preparedTokenizerDirectory != tokenizerDirectory else {
            return
        }

        if let runtime {
            await runtime.whisperKit.unloadModels()
        }

        let configuration = WhisperKitConfig(
            modelFolder: modelDirectory.path,
            tokenizerFolder: tokenizerDirectory,
            verbose: false,
            prewarm: false,
            load: false,
            download: false
        )
        let whisperKit = try await WhisperKit(configuration)

        // Construct the tokenizer strictly from the already hash-validated local
        // folder. This bypasses WhisperKit's otherwise network-capable fallback.
        let tokenizer = try await AutoTokenizerWrapper.from(
            modelFolder: tokenizerDirectory,
            hubApi: HubApiWrapper(
                downloadBase: tokenizerDirectory,
                endpoint: "http://127.0.0.1:9"
            )
        )
        whisperKit.tokenizer = try LocalOnlyWhisperTokenizer(tokenizer: tokenizer)
        try await whisperKit.loadModels()

        runtime = RuntimeBox(whisperKit)
        preparedModelDirectory = modelDirectory
        preparedTokenizerDirectory = tokenizerDirectory
    }

    func prewarm(modelDirectory: URL, tokenizerDirectory: URL) async throws {
        try await prepare(modelDirectory: modelDirectory, tokenizerDirectory: tokenizerDirectory)
        guard let runtime else {
            throw WhisperKitRecognizerError.runtimePreparationFailed
        }
        try await runtime.whisperKit.prewarmModels()
    }

    func unload() async {
        let tasks = Array(activeTasks.values)
        tasks.forEach { $0.task.cancel() }
        for active in tasks {
            _ = await active.task.result
        }
        activeTasks.removeAll()
        if let runtime {
            await runtime.whisperKit.unloadModels()
        }
        runtime = nil
        preparedModelDirectory = nil
        preparedTokenizerDirectory = nil
    }

    func prioritizedPromptTokens(for terms: [String], maxTokens: Int) throws -> [Int] {
        guard let tokenizer = runtime?.whisperKit.tokenizer else {
            throw WhisperKitRecognizerError.runtimePreparationFailed
        }
        guard maxTokens > 0 else { return [] }

        var promptTokens: [Int] = []
        for term in terms {
            let normalized = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            let candidate = Self.promptTokens(
                for: normalized,
                specialTokenBegin: tokenizer.specialTokens.specialTokenBegin,
                encodedBy: tokenizer.encode(text:)
            )
            guard !candidate.isEmpty,
                  promptTokens.count + candidate.count <= maxTokens else {
                continue
            }
            promptTokens.append(contentsOf: candidate)
        }
        return promptTokens
    }

    nonisolated static func promptTokens(
        for normalizedTerm: String,
        specialTokenBegin: Int,
        encodedBy encode: (String) -> [Int]
    ) -> [Int] {
        encode(" " + normalizedTerm).filter { $0 < specialTokenBegin }
    }

    func transcribe(
        samples: [Float],
        language: WhisperKitLanguageMode,
        promptTokens: [Int],
        sessionID: DictationSessionID
    ) async throws -> WhisperKitRecognitionResult {
        guard let runtime else {
            throw WhisperKitRecognizerError.runtimePreparationFailed
        }
        guard activeTasks.isEmpty else {
            throw WhisperKitRecognizerError.runtimeBusy
        }

        let options = Self.decodingOptions(language: language, promptTokens: promptTokens)

        return try await runTrackedTranscription(sessionID: sessionID) {
            // The installed decoder has a 128-token cache. Split long audio
            // at quiet boundaries before decoding to reduce the risk of a full
            // 30-second window exhausting the cache and omitting speech.
            let chunks = try await Self.finalAudioChunks(samples)
            var results: [TranscriptionResult] = []
            for chunk in chunks {
                try Task.checkCancellation()
                results += try await runtime.whisperKit.transcribe(
                    audioArray: chunk.audioSamples,
                    decodeOptions: options
                )
            }
            try Task.checkCancellation()
            return Self.recognitionResult(from: results)
        }
    }

    nonisolated static func finalAudioChunks(_ samples: [Float]) async throws -> [AudioChunk] {
        guard samples.count > 20 * AudioSamples.recognizerSampleRate else {
            return [AudioChunk(seekOffsetIndex: 0, audioSamples: samples)]
        }
        return try await VADAudioChunker(
            windowPadding: 0,
            vad: EnergyVAD(frameLength: 0.02, frameOverlap: 0.01, energyThreshold: 0.005)
        ).chunkAll(
            audioArray: samples,
            maxChunkLength: 20 * AudioSamples.recognizerSampleRate,
            decodeOptions: nil
        )
    }

    func cancel(sessionID: DictationSessionID) async {
        guard let active = activeTasks[sessionID] else { return }
        active.task.cancel()
        _ = await active.task.result
        removeActiveTask(active, for: sessionID)
    }

    func runTrackedTranscription(
        sessionID: DictationSessionID,
        operation: @escaping @Sendable () async throws -> WhisperKitRecognitionResult
    ) async throws -> WhisperKitRecognitionResult {
        let active = ActiveTranscription(
            token: UUID(),
            task: Task(operation: operation)
        )
        activeTasks[sessionID] = active
        defer { removeActiveTask(active, for: sessionID) }
        return try await active.task.value
    }

    private func removeActiveTask(
        _ active: ActiveTranscription,
        for sessionID: DictationSessionID
    ) {
        guard activeTasks[sessionID]?.token == active.token else { return }
        activeTasks[sessionID] = nil
    }

    nonisolated static func decodingOptions(
        language: WhisperKitLanguageMode,
        promptTokens: [Int]
    ) -> DecodingOptions {
        _ = promptTokens
        let languageCode: String?
        let detectLanguage: Bool
        switch language {
        case .automatic:
            languageCode = nil
            detectLanguage = true
        case .german:
            languageCode = "de"
            detectLanguage = false
        case .english:
            languageCode = "en"
            detectLanguage = false
        }
        return DecodingOptions(
            task: .transcribe,
            language: languageCode,
            temperatureFallbackCount: 0,
            sampleLength: 128,
            detectLanguage: detectLanguage,
            withoutTimestamps: true,
            wordTimestamps: false,
            windowClipTime: 0,
            promptTokens: [],
            firstTokenLogProbThreshold: nil,
            noSpeechThreshold: nil
        )
    }

    private nonisolated static func recognitionResult(
        from results: [TranscriptionResult]
    ) -> WhisperKitRecognitionResult {
        let text = results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = results.flatMap(\.segments).map(Self.segmentMetadata)
        let temperatureFallbackCount = results.reduce(0) {
            $0 + Int($1.timings.totalDecodingFallbacks.rounded(.towardZero))
        }
        var fallbackReasons: [String] = []
        if temperatureFallbackCount > 0 {
            fallbackReasons.append("temperatureFallback")
        }
        return WhisperKitRecognitionResult(
            text: text,
            segments: segments,
            avgLogprob: Self.averageLogprob(segments),
            minWordProbability: Self.minimumWordProbability(segments),
            compressionRatio: segments.map(\.compressionRatio).max(),
            decoderFallback: RecognitionDecoderFallback(
                occurred: temperatureFallbackCount > 0,
                count: temperatureFallbackCount,
                reasons: fallbackReasons
            )
        )
    }

    private nonisolated static func segmentMetadata(
        _ segment: TranscriptionSegment
    ) -> RecognitionSegmentMetadata {
        let wordProbabilities = (segment.words ?? []).map {
            RecognitionWordProbability(word: $0.word, probability: $0.probability)
        }
        return RecognitionSegmentMetadata(
            text: segment.text,
            avgLogprob: segment.avgLogprob,
            compressionRatio: segment.compressionRatio,
            noSpeechProbability: segment.noSpeechProb,
            wordProbabilities: wordProbabilities
        )
    }

    private nonisolated static func averageLogprob(
        _ segments: [RecognitionSegmentMetadata]
    ) -> Float? {
        guard !segments.isEmpty else { return nil }
        return segments.reduce(Float(0)) { $0 + $1.avgLogprob } / Float(segments.count)
    }

    private nonisolated static func minimumWordProbability(
        _ segments: [RecognitionSegmentMetadata]
    ) -> Float? {
        segments.flatMap(\.wordProbabilities).map(\.probability).min()
    }
}

private extension Duration {
    var whisperKitPerformanceMilliseconds: Double {
        let components = self.components
        return (Double(components.seconds) * 1_000)
            + (Double(components.attoseconds) / 1_000_000_000_000_000)
    }
}

private struct LocalOnlyWhisperTokenizer: WhisperTokenizer, Sendable {
    let tokenizer: TokenizerWrapper
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>

    init(tokenizer: TokenizerWrapper) throws {
        guard let endToken = tokenizer.convertTokenToId("<|endoftext|>"),
              let englishToken = tokenizer.convertTokenToId("<|en|>"),
              let noSpeechToken = tokenizer.convertTokenToId("<|nospeech|>"),
              let noTimestampsToken = tokenizer.convertTokenToId("<|notimestamps|>"),
              let startOfPreviousToken = tokenizer.convertTokenToId("<|startofprev|>"),
              let startOfTranscriptToken = tokenizer.convertTokenToId("<|startoftranscript|>"),
              let timeTokenBegin = tokenizer.convertTokenToId("<|0.00|>"),
              let transcribeToken = tokenizer.convertTokenToId("<|transcribe|>"),
              let translateToken = tokenizer.convertTokenToId("<|translate|>"),
              let whitespaceToken = tokenizer.convertTokenToId(" ") else {
            throw WhisperKitRecognizerError.tokenizerInvalid
        }

        self.tokenizer = tokenizer
        specialTokens = SpecialTokens(
            endToken: endToken,
            englishToken: englishToken,
            noSpeechToken: noSpeechToken,
            noTimestampsToken: noTimestampsToken,
            specialTokenBegin: endToken,
            startOfPreviousToken: startOfPreviousToken,
            startOfTranscriptToken: startOfTranscriptToken,
            timeTokenBegin: timeTokenBegin,
            transcribeToken: transcribeToken,
            translateToken: translateToken,
            whitespaceToken: whitespaceToken
        )
        allLanguageTokens = Set(
            Constants.languages.values.compactMap {
                tokenizer.convertTokenToId("<|\($0)|>")
            }
        )
    }

    func encode(text: String) -> [Int] {
        tokenizer.encode(text: text)
    }

    func decode(tokens: [Int]) -> String {
        tokenizer.decode(tokens: tokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        tokenizer.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        tokenizer.convertIdToToken(id)
    }

    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        guard !tokenIds.isEmpty else { return ([], []) }
        return (words: [tokenizer.decode(tokens: tokenIds)], wordTokens: [tokenIds])
    }
}
