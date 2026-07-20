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
        self == .emptyTranscription
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

actor WhisperKitRecognizer: SpeechRecognizing, SpeechRecognitionLifecycle {
    static let promptTokenBudget = 128
    private static let incrementalInitialSampleCount = Int(1.5 * 16_000)
    private static let incrementalAdditionalSampleCount = Int(2.0 * 16_000)

    private struct IncrementalSession: Sendable {
        var samples: [Float]
        let language: WhisperKitLanguageMode
        let promptTokens: [Int]
        var lastDecodedSampleCount: Int
    }

    private struct PrewarmOperation: Sendable {
        let id: UInt64
        let task: Task<Void, Error>
    }

    private let sampleAccess: any AudioSampleAccessing
    private let modelStore: any LocalModelChecking
    private let tokenizerStore: any LocalModelChecking
    private let runtime: any WhisperKitRuntimeServing
    private let backend: RecognitionBackend?
    private let logger = Logger(subsystem: "local.flusterflow", category: "asr")
    private var runtimePrepared = false
    private var runtimePrewarmed = false
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
            try await prepareIfNeeded()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logFailure(Self.failureCode(for: error))
            throw error
        }
        let audioSamples = try await sampleAccess.samples(for: audio)
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

        let promptTokens = try await runtime.prioritizedPromptTokens(
            for: hints.decoderPromptTerms,
            maxTokens: Self.promptTokenBudget
        )
        let result: WhisperKitRecognitionResult
        do {
            result = try await runtime.transcribe(
                samples: audioSamples.values,
                language: Self.languageMode(for: hints.language),
                promptTokens: promptTokens,
                sessionID: sessionID
            )
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
        try await prewarm()
        let promptTokens = try await runtime.prioritizedPromptTokens(
            for: hints.decoderPromptTerms,
            maxTokens: Self.promptTokenBudget
        )
        incrementalSessions[sessionID] = IncrementalSession(
            samples: [],
            language: Self.languageMode(for: hints.language),
            promptTokens: promptTokens,
            lastDecodedSampleCount: 0
        )
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

        incremental.samples.append(contentsOf: chunk.samples)
        let requiredSampleCount = incremental.lastDecodedSampleCount == 0
            ? Self.incrementalInitialSampleCount
            : incremental.lastDecodedSampleCount + Self.incrementalAdditionalSampleCount
        guard incremental.samples.count >= requiredSampleCount else {
            incrementalSessions[sessionID] = incremental
            return .accepted
        }

        incremental.lastDecodedSampleCount = incremental.samples.count
        incrementalSessions[sessionID] = incremental
        do {
            _ = try await runtime.transcribe(
                samples: incremental.samples,
                language: incremental.language,
                promptTokens: incremental.promptTokens,
                sessionID: sessionID
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Incremental decoding is an in-memory latency optimization. A
            // preview failure must never prevent the canonical final decode.
        }
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
        if runtimePrewarmed { return }
        if let operation = prewarmOperation {
            try await awaitPrewarm(operation)
            return
        }

        let modelDirectory = try await modelStore.validatedDirectory()
        let tokenizerDirectory = try await tokenizerStore.validatedDirectory()
        if runtimePrewarmed { return }
        if let operation = prewarmOperation {
            try await awaitPrewarm(operation)
            return
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

    func unload() async {
        incrementalSessions.removeAll()
        runtimePrepared = false
        runtimePrewarmed = false
        let operation = prewarmOperation
        prewarmOperation = nil
        operation?.task.cancel()
        if let operation {
            _ = await operation.task.result
        }
        await runtime.unload()
    }

    private func prepareIfNeeded() async throws {
        guard !runtimePrepared else { return }
        if let operation = prewarmOperation {
            try await awaitPrewarm(operation)
            return
        }
        let modelDirectory = try await modelStore.validatedDirectory()
        let tokenizerDirectory = try await tokenizerStore.validatedDirectory()
        guard !runtimePrepared else { return }
        if let operation = prewarmOperation {
            try await awaitPrewarm(operation)
            return
        }
        do {
            try await runtime.prepare(
                modelDirectory: modelDirectory,
                tokenizerDirectory: tokenizerDirectory
            )
            runtimePrepared = true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WhisperKitRecognizerError.runtimePreparationFailed
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

    private var runtime: RuntimeBox?
    private var preparedModelDirectory: URL?
    private var preparedTokenizerDirectory: URL?
    private var activeTasks: [DictationSessionID: Task<WhisperKitRecognitionResult, Error>] = [:]

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
        tasks.forEach { $0.cancel() }
        for task in tasks {
            _ = await task.result
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
            let candidate = tokenizer.encode(text: normalized)
            guard !candidate.isEmpty,
                  promptTokens.count + candidate.count <= maxTokens else {
                continue
            }
            promptTokens.append(contentsOf: candidate)
        }
        return promptTokens
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

        let task = Task<WhisperKitRecognitionResult, Error> {
            let initialResults = try await runtime.whisperKit.transcribe(
                audioArray: samples,
                decodeOptions: options
            )
            try Task.checkCancellation()
            let initialResult = Self.recognitionResult(
                from: initialResults,
                recoveredFromNoSpeech: false
            )
            guard initialResult.text.isEmpty else {
                return initialResult
            }

            // Local VAD has already established at least 250 ms of speech.
            // If Whisper's no-speech token still suppresses the entire result,
            // retry once without that gate and with the simpler untimestamped
            // decode. This is bounded to the empty-result path only.
            let recoveryResults = try await runtime.whisperKit.transcribe(
                audioArray: samples,
                decodeOptions: Self.decodingOptions(
                    language: language,
                    promptTokens: promptTokens,
                    recoveringFromEmptyTranscription: true
                )
            )
            try Task.checkCancellation()
            return Self.recognitionResult(
                from: recoveryResults,
                recoveredFromNoSpeech: true
            )
        }
        activeTasks[sessionID] = task
        defer { activeTasks[sessionID] = nil }
        return try await task.value
    }

    func cancel(sessionID: DictationSessionID) async {
        guard let task = activeTasks[sessionID] else { return }
        task.cancel()
        _ = await task.result
        activeTasks[sessionID] = nil
    }

    nonisolated static func decodingOptions(
        language: WhisperKitLanguageMode,
        promptTokens: [Int],
        recoveringFromEmptyTranscription: Bool = false
    ) -> DecodingOptions {
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
            detectLanguage: detectLanguage,
            withoutTimestamps: recoveringFromEmptyTranscription,
            wordTimestamps: !recoveringFromEmptyTranscription,
            windowClipTime: 0,
            promptTokens: promptTokens,
            noSpeechThreshold: recoveringFromEmptyTranscription ? nil : 0.6
        )
    }

    private nonisolated static func recognitionResult(
        from results: [TranscriptionResult],
        recoveredFromNoSpeech: Bool
    ) -> WhisperKitRecognitionResult {
        let text = results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = results.flatMap(\.segments).map(Self.segmentMetadata)
        let temperatureFallbackCount = results.reduce(0) {
            $0 + Int($1.timings.totalDecodingFallbacks.rounded(.towardZero))
        }
        let totalFallbackCount = temperatureFallbackCount + (recoveredFromNoSpeech ? 1 : 0)
        var fallbackReasons: [String] = []
        if temperatureFallbackCount > 0 {
            fallbackReasons.append("temperatureFallback")
        }
        if recoveredFromNoSpeech {
            fallbackReasons.append("noSpeechRecovery")
        }
        return WhisperKitRecognitionResult(
            text: text,
            segments: segments,
            avgLogprob: Self.averageLogprob(segments),
            minWordProbability: Self.minimumWordProbability(segments),
            compressionRatio: segments.map(\.compressionRatio).max(),
            decoderFallback: RecognitionDecoderFallback(
                occurred: totalFallbackCount > 0,
                count: totalFallbackCount,
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
