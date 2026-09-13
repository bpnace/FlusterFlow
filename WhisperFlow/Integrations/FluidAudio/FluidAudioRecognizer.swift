import FluidAudio
import Foundation

enum FluidAudioLanguageMode: Equatable, Sendable {
    case automatic
    case german
    case english
}

protocol FluidAudioRuntimeServing: Sendable {
    func prepare(modelDirectory: URL) async throws
    func transcribe(
        samples: [Float],
        language: FluidAudioLanguageMode,
        terms: [String],
        sessionID: DictationSessionID
    ) async throws -> String
    func cancel(sessionID: DictationSessionID) async
}

enum FluidAudioRecognizerError: Error, Equatable, Sendable {
    case unsupportedAudioFormat(sampleRate: Int, channelCount: Int)
    case emptyAudio
    case runtimePreparationFailed
    case runtimeTranscriptionFailed
}

actor FluidAudioRecognizer: SpeechRecognizing {
    private let sampleAccess: any AudioSampleAccessing
    private let modelStore: any LocalModelChecking
    private let runtime: any FluidAudioRuntimeServing
    private var runtimePrepared = false

    init(
        sampleAccess: any AudioSampleAccessing,
        modelStore: any LocalModelChecking,
        runtime: any FluidAudioRuntimeServing = OfflineFluidAudioRuntime()
    ) {
        self.sampleAccess = sampleAccess
        self.modelStore = modelStore
        self.runtime = runtime
    }

    func modelStatus() async -> LocalModelStatus {
        await modelStore.status()
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
            throw FluidAudioRecognizerError.unsupportedAudioFormat(
                sampleRate: audioSamples.sampleRate,
                channelCount: audioSamples.channelCount
            )
        }
        guard !audioSamples.values.isEmpty else {
            throw FluidAudioRecognizerError.emptyAudio
        }

        let languageMode = Self.languageMode(for: hints.language)
        let text: String
        do {
            try Task.checkCancellation()
            text = try await runtime.transcribe(
                samples: audioSamples.values,
                language: languageMode,
                terms: hints.terms,
                sessionID: sessionID
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FluidAudioRecognizerError.runtimeTranscriptionFailed
        }

        return RawTranscript(
            text: text,
            language: hints.language,
            backend: .parakeetV3Int8
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
            throw FluidAudioRecognizerError.runtimePreparationFailed
        }
    }

    private static func languageMode(for language: DictationLanguage) -> FluidAudioLanguageMode {
        switch language {
        case .automatic:
            return .automatic
        case .german:
            return .german
        case .english:
            return .english
        }
    }
}

actor OfflineFluidAudioRuntime: FluidAudioRuntimeServing {
    private struct ActiveTranscription: Sendable {
        let token: UUID
        let task: Task<String, Error>
    }

    private var manager: AsrManager?
    private var preparedDirectory: URL?
    private var activeTasks: [DictationSessionID: ActiveTranscription] = [:]

    init() {
        // This is set before any FluidAudio model/runtime call. FluidAudio's
        // loader then fails instead of attempting a repair download.
        ModelHub.offlineMode = true
    }

    func prepare(modelDirectory: URL) async throws {
        ModelHub.offlineMode = true
        let standardizedDirectory = modelDirectory.standardizedFileURL
        guard preparedDirectory != standardizedDirectory else { return }

        let models = try await AsrModels.load(
            from: standardizedDirectory,
            version: .v3,
            encoderPrecision: .int8
        )
        manager = AsrManager(
            config: ASRConfig(melChunkContext: false),
            models: models
        )
        preparedDirectory = standardizedDirectory
    }

    func transcribe(
        samples: [Float],
        language: FluidAudioLanguageMode,
        terms: [String],
        sessionID: DictationSessionID
    ) async throws -> String {
        ModelHub.offlineMode = true
        guard let manager else {
            throw FluidAudioRecognizerError.runtimePreparationFailed
        }

        // FluidAudio 0.15.5 exposes script filtering, not semantic language
        // detection. German and English therefore both select the Latin
        // script; automatic mode disables the filter. Runtime term hints are
        // not supported by this Parakeet API and remain available to later
        // deterministic context correction.
        _ = terms
        let fluidLanguage: Language?
        switch language {
        case .automatic:
            fluidLanguage = nil
        case .german:
            fluidLanguage = .german
        case .english:
            fluidLanguage = .english
        }

        let decoderLayers = await manager.decoderLayerCount
        return try await runTrackedTranscription(sessionID: sessionID) {
            var decoderState = try TdtDecoderState(decoderLayers: decoderLayers)
            let result = try await manager.transcribe(
                samples,
                decoderState: &decoderState,
                language: fluidLanguage
            )
            return result.text
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
