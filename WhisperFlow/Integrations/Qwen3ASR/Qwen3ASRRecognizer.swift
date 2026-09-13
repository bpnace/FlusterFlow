@preconcurrency import MLX
@preconcurrency import MLXAudioSTT
import Foundation

enum Qwen3ASRLanguageMode: Equatable, Sendable {
    case automatic
    case german
    case english

    var runtimeName: String? {
        switch self {
        case .automatic: nil
        case .german: "German"
        case .english: "English"
        }
    }
}

protocol Qwen3ASRRuntimeServing: Sendable {
    func prepare(modelDirectory: URL) async throws
    func transcribe(
        samples: [Float],
        language: Qwen3ASRLanguageMode,
        sessionID: DictationSessionID
    ) async throws -> String
    func cancel(sessionID: DictationSessionID) async
}

enum Qwen3ASRRecognizerError: Error, Equatable, Sendable {
    case unsupportedAudioFormat(sampleRate: Int, channelCount: Int)
    case emptyAudio
    case runtimePreparationFailed
    case runtimeTranscriptionFailed
    case emptyTranscription
}

extension Qwen3ASRRecognizerError: SpeechRecognitionFailureClassifying {
    var indicatesNoSpeech: Bool {
        false
    }
}

actor Qwen3ASRRecognizer: SpeechRecognizing {
    private let sampleAccess: any AudioSampleAccessing
    private let modelStore: any LocalModelChecking
    private let runtime: any Qwen3ASRRuntimeServing
    private var runtimePrepared = false

    init(
        sampleAccess: any AudioSampleAccessing,
        modelStore: any LocalModelChecking,
        runtime: any Qwen3ASRRuntimeServing = OfflineQwen3ASRRuntime()
    ) {
        self.sampleAccess = sampleAccess
        self.modelStore = modelStore
        self.runtime = runtime
    }

    func transcribe(
        _ audio: AudioInput,
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws -> RawTranscript {
        try await prepareIfNeeded()
        try Task.checkCancellation()
        let audioSamples = try await sampleAccess.samples(for: audio)
        try Task.checkCancellation()
        guard audioSamples.sampleRate == AudioSamples.recognizerSampleRate,
              audioSamples.channelCount == 1 else {
            throw Qwen3ASRRecognizerError.unsupportedAudioFormat(
                sampleRate: audioSamples.sampleRate,
                channelCount: audioSamples.channelCount
            )
        }
        guard !audioSamples.values.isEmpty else {
            throw Qwen3ASRRecognizerError.emptyAudio
        }

        let text: String
        do {
            try Task.checkCancellation()
            text = try await runtime.transcribe(
                samples: audioSamples.values,
                language: Self.languageMode(for: hints.language),
                sessionID: sessionID
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Qwen3ASRRecognizerError.runtimeTranscriptionFailed
        }

        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw Qwen3ASRRecognizerError.emptyTranscription
        }
        return RawTranscript(
            text: normalized,
            language: hints.language,
            backend: .qwen3ASR06B8Bit
        )
    }

    func cancel(sessionID: DictationSessionID) async {
        await runtime.cancel(sessionID: sessionID)
    }

    private func prepareIfNeeded() async throws {
        guard !runtimePrepared else { return }
        let modelDirectory = try await modelStore.validatedDirectory()
        try Task.checkCancellation()
        do {
            try await runtime.prepare(modelDirectory: modelDirectory)
            try Task.checkCancellation()
            runtimePrepared = true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Qwen3ASRRecognizerError.runtimePreparationFailed
        }
    }

    private static func languageMode(
        for language: DictationLanguage
    ) -> Qwen3ASRLanguageMode {
        switch language {
        case .automatic: .automatic
        case .german: .german
        case .english: .english
        }
    }
}

actor OfflineQwen3ASRRuntime: Qwen3ASRRuntimeServing {
    private final class RuntimeBox: @unchecked Sendable {
        let model: Qwen3ASRModel

        init(_ model: Qwen3ASRModel) {
            self.model = model
        }
    }

    private struct ActiveTranscription: Sendable {
        let token: UUID
        let task: Task<String, Error>
    }

    private var runtime: RuntimeBox?
    private var preparedModelDirectory: URL?
    private var activeTasks: [DictationSessionID: ActiveTranscription] = [:]

    func prepare(modelDirectory: URL) async throws {
        let modelDirectory = modelDirectory.standardizedFileURL
        guard preparedModelDirectory != modelDirectory else { return }
        guard activeTasks.isEmpty else {
            throw Qwen3ASRRecognizerError.runtimePreparationFailed
        }

        let model = try await Qwen3ASRModel.fromModelDirectory(modelDirectory)
        runtime = RuntimeBox(model)
        preparedModelDirectory = modelDirectory
    }

    func transcribe(
        samples: [Float],
        language: Qwen3ASRLanguageMode,
        sessionID: DictationSessionID
    ) async throws -> String {
        guard let runtime else {
            throw Qwen3ASRRecognizerError.runtimePreparationFailed
        }
        guard activeTasks.isEmpty else {
            throw Qwen3ASRRecognizerError.runtimeTranscriptionFailed
        }

        return try await runTrackedTranscription(sessionID: sessionID) { [runtime, samples, language] in
            let audio = MLXArray(samples)
            var finalText: String?
            for try await event in runtime.model.generateStream(
                audio: audio,
                maxTokens: 4_096,
                language: language.runtimeName
            ) {
                try Task.checkCancellation()
                if case .result(let output) = event {
                    finalText = output.text
                }
            }
            try Task.checkCancellation()
            return finalText ?? ""
        }
    }

    func cancel(sessionID: DictationSessionID) async {
        guard let active = activeTasks[sessionID] else { return }
        active.task.cancel()
        _ = await active.task.result
        removeActiveTask(active, for: sessionID)
    }

    func runTrackedTranscription(
        sessionID: DictationSessionID,
        operation: @escaping @Sendable () async throws -> String
    ) async throws -> String {
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
}
