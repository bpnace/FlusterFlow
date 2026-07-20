import Foundation

enum SessionModelSpeechRecognizerError: Error, Equatable, Sendable {
    case sessionNotRegistered
    case recognizerUnavailable
}

actor SessionModelSpeechRecognizer: SpeechRecognizing, SpeechRecognitionLifecycle {
    private let recognizers: [LocalModelChoice: any SpeechRecognizing]
    private var choices: [DictationSessionID: LocalModelChoice] = [:]

    init(recognizers: [LocalModelChoice: any SpeechRecognizing]) {
        self.recognizers = recognizers
    }

    func register(_ choice: LocalModelChoice, for sessionID: DictationSessionID) {
        choices[sessionID] = choice
    }

    func transcribe(
        _ audio: AudioInput,
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws -> RawTranscript {
        guard let choice = choices[sessionID] else {
            throw SessionModelSpeechRecognizerError.sessionNotRegistered
        }
        guard let recognizer = recognizers[choice] else {
            throw SessionModelSpeechRecognizerError.recognizerUnavailable
        }
        return try await recognizer.transcribe(
            audio,
            hints: hints,
            sessionID: sessionID
        )
    }

    func cancel(sessionID: DictationSessionID) async {
        guard let choice = choices.removeValue(forKey: sessionID),
              let recognizer = recognizers[choice] else {
            return
        }
        await recognizer.cancel(sessionID: sessionID)
    }

    func prepareForRecording(
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws {
        let recognizer = try recognizer(for: sessionID)
        if let lifecycle = recognizer as? any SpeechRecognitionLifecycle {
            try await lifecycle.prepareForRecording(
                hints: hints,
                sessionID: sessionID
            )
        }
    }

    func startRecognitionSession(
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws {
        let recognizer = try recognizer(for: sessionID)
        if let lifecycle = recognizer as? any SpeechRecognitionLifecycle {
            try await lifecycle.startRecognitionSession(
                hints: hints,
                sessionID: sessionID
            )
        }
    }

    func updateRecognitionSession(
        with chunk: RecognitionAudioChunk,
        sessionID: DictationSessionID
    ) async throws -> RecognitionChunkDisposition {
        let recognizer = try recognizer(for: sessionID)
        guard let lifecycle = recognizer as? any SpeechRecognitionLifecycle else {
            return .ignoredBatchRecognizer
        }
        return try await lifecycle.updateRecognitionSession(
            with: chunk,
            sessionID: sessionID
        )
    }

    func stopRecognitionSession(sessionID: DictationSessionID) async {
        guard let recognizer = try? recognizer(for: sessionID),
              let lifecycle = recognizer as? any SpeechRecognitionLifecycle else {
            return
        }
        await lifecycle.stopRecognitionSession(sessionID: sessionID)
    }

    func finalizeRecognitionSession(
        _ audio: AudioInput,
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws -> RawTranscript {
        let recognizer = try recognizer(for: sessionID)
        if let lifecycle = recognizer as? any SpeechRecognitionLifecycle {
            return try await lifecycle.finalizeRecognitionSession(
                audio,
                hints: hints,
                sessionID: sessionID
            )
        }
        return try await recognizer.transcribe(
            audio,
            hints: hints,
            sessionID: sessionID
        )
    }

    private func recognizer(
        for sessionID: DictationSessionID
    ) throws -> any SpeechRecognizing {
        guard let choice = choices[sessionID] else {
            throw SessionModelSpeechRecognizerError.sessionNotRegistered
        }
        guard let recognizer = recognizers[choice] else {
            throw SessionModelSpeechRecognizerError.recognizerUnavailable
        }
        return recognizer
    }
}
