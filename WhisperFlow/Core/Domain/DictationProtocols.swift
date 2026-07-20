import Foundation

protocol TargetContextProviding: Sendable {
    func capture(for sessionID: DictationSessionID) async throws -> CapturedTargetContext
    func cancel(sessionID: DictationSessionID) async
}

protocol AudioCapturing: Sendable {
    func startCapture(for sessionID: DictationSessionID) async throws
    func finishCapture(for sessionID: DictationSessionID) async throws -> AudioInput
    func cancelCapture(for sessionID: DictationSessionID) async
    func release(_ input: AudioInput) async
}

struct IncrementalAudioBatch: Equatable, Sendable {
    let chunk: RecognitionAudioChunk
    let nextFrameOffset: Int
}

protocol IncrementalAudioProviding: Sendable {
    func incrementalAudioBatch(
        for sessionID: DictationSessionID,
        afterFrameOffset frameOffset: Int
    ) async throws -> IncrementalAudioBatch?
}

protocol SpeechRecognizing: Sendable {
    func transcribe(
        _ audio: AudioInput,
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws -> RawTranscript
    func cancel(sessionID: DictationSessionID) async
}

protocol SpeechRecognitionFailureClassifying: Error {
    var indicatesNoSpeech: Bool { get }
}

struct RecognitionAudioChunk: Equatable, Sendable {
    let samples: [Float]
    let sampleRate: Int
    let channelCount: Int
    let isFinal: Bool

    init(
        samples: [Float],
        sampleRate: Int = AudioSamples.recognizerSampleRate,
        channelCount: Int = 1,
        isFinal: Bool = false
    ) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.isFinal = isFinal
    }
}

enum RecognitionChunkDisposition: Equatable, Sendable {
    case accepted
    case ignoredBatchRecognizer
}

protocol SpeechRecognitionLifecycle: Sendable {
    func prepareForRecording(
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws
    func startRecognitionSession(
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws
    func updateRecognitionSession(
        with chunk: RecognitionAudioChunk,
        sessionID: DictationSessionID
    ) async throws -> RecognitionChunkDisposition
    func stopRecognitionSession(sessionID: DictationSessionID) async
    func finalizeRecognitionSession(
        _ audio: AudioInput,
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws -> RawTranscript
}

extension SpeechRecognitionLifecycle {
    func stopRecognitionSession(sessionID: DictationSessionID) async {
        _ = sessionID
    }
}

protocol TextCleaning: Sendable {
    func clean(
        _ transcript: RawTranscript,
        context: ContextSnapshot,
        sessionID: DictationSessionID
    ) async throws -> LocalCandidate
}

protocol TextEnriching: Sendable {
    func enrich(
        _ candidate: LocalCandidate,
        context: ContextSnapshot,
        consent: ConsentSnapshot,
        sessionID: DictationSessionID
    ) async throws -> EnrichedCandidate
    func cancel(sessionID: DictationSessionID) async
}

enum InsertionCancellationDisposition: Equatable, Sendable {
    case cancelledBeforeCommit
    case tooLateCommitted
}

protocol TextInserting: Sendable {
    func insert(
        _ candidate: FinalCandidate,
        sessionID: DictationSessionID
    ) async throws -> InsertionOutcome
    func requestCancellation(
        sessionID: DictationSessionID
    ) async -> InsertionCancellationDisposition
    func releaseInsertionSession(sessionID: DictationSessionID) async
}

protocol EphemeralTextPreserving: Sendable {
    func preserveRawTranscript(_ text: String, for sessionID: DictationSessionID) async
    func preserveCandidate(_ text: String, for sessionID: DictationSessionID) async
    func confirmInsertion(sessionID: DictationSessionID) async
    func discardEphemeralText(sessionID: DictationSessionID) async
}
