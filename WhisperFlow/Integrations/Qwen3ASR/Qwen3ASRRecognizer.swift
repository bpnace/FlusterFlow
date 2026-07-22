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
        let audioSamples = try await sampleAccess.samples(for: audio)
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
        do {
            try await runtime.prepare(modelDirectory: modelDirectory)
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

    private var runtime: RuntimeBox?
    private var preparedModelDirectory: URL?
    private var activeTasks: [DictationSessionID: Task<String, Error>] = [:]

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

        let task = Task<String, Error> { [runtime, samples, language] in
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
        activeTasks[sessionID] = task
        defer { activeTasks[sessionID] = nil }
        return try await task.value
    }

    func cancel(sessionID: DictationSessionID) {
        activeTasks.removeValue(forKey: sessionID)?.cancel()
    }
}
