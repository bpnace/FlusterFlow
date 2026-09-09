import Foundation

struct DictationSessionID: Hashable, Comparable, Sendable {
    let rawValue: UInt64

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct TargetToken: Hashable, Sendable {
    let rawValue: UInt64
}

struct SelectionFingerprint: Hashable, Sendable {
    let rawValue: UInt64
}

enum TargetKind: Equatable, Sendable {
    case email
    case chat
    case document
    case unknown
}

struct TargetSnapshot: Equatable, Sendable {
    let processIdentifier: Int32
    let token: TargetToken
    let selectionFingerprint: SelectionFingerprint
    let sessionID: DictationSessionID

    var isRegistered: Bool {
        token.rawValue != 0
    }
}

struct ContextSnapshot: Equatable, Sendable {
    enum Availability: Equatable, Sendable {
        case available
        case unavailable
        case deniedSensitive
    }

    let availability: Availability
    let targetKind: TargetKind
    let boundedText: String?
    let termHints: [String]
    let localCategory: LocalContextCategory
    let safeDecoderHints: [String]

    init(
        availability: Availability,
        targetKind: TargetKind,
        boundedText: String?,
        termHints: [String],
        localCategory: LocalContextCategory? = nil,
        safeDecoderHints: [String] = []
    ) {
        self.availability = availability
        self.targetKind = targetKind
        self.boundedText = boundedText
        self.termHints = termHints
        self.localCategory = localCategory ?? Self.fallbackCategory(for: targetKind)
        self.safeDecoderHints = safeDecoderHints
    }

    static func unavailable(
        targetKind: TargetKind,
        localCategory: LocalContextCategory = .other,
        safeDecoderHints: [String] = []
    ) -> Self {
        Self(
            availability: .unavailable,
            targetKind: targetKind,
            boundedText: nil,
            termHints: [],
            localCategory: localCategory,
            safeDecoderHints: safeDecoderHints
        )
    }


    private static func fallbackCategory(for targetKind: TargetKind) -> LocalContextCategory {
        switch targetKind {
        case .email: .email
        case .chat, .document, .unknown: .other
        }
    }
}

struct CapturedTargetContext: Equatable, Sendable {
    let target: TargetSnapshot
    let context: ContextSnapshot
}

enum DictationLanguage: Equatable, Sendable {
    case automatic
    case german
    case english
}

struct RecognitionHints: Equatable, Sendable {
    let language: DictationLanguage
    let terms: [String]
    let prioritizedLexiconTerms: [String]

    init(
        language: DictationLanguage,
        terms: [String],
        prioritizedLexiconTerms: [String] = []
    ) {
        self.language = language
        self.terms = terms
        self.prioritizedLexiconTerms = prioritizedLexiconTerms
    }

    var decoderPromptTerms: [String] {
        var seen: Set<String> = []
        return (prioritizedLexiconTerms + terms).filter { term in
            let key = term.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            return !key.isEmpty && seen.insert(key).inserted
        }
    }
}

enum RecognitionBackend: String, Equatable, Sendable {
    case parakeetV3Int8
    case qwen3ASR06B8Bit
    case whisperKitLargeV3
    case whisperKitLargeV3Turbo
    case adaptiveWhisperKit
}

struct AudioBufferHandle: Hashable, Sendable {
    let rawValue: UInt64
}

struct AudioInput: Equatable, Sendable {
    let buffer: AudioBufferHandle
    let timing: AudioTimingMetadata?

    init(
        buffer: AudioBufferHandle,
        timing: AudioTimingMetadata? = nil
    ) {
        self.buffer = buffer
        self.timing = timing
    }

    var hasDetectedSpeech: Bool {
        timing?.isSilent != true
    }
}

struct RawTranscript: Equatable, Sendable {
    let text: String
    let language: DictationLanguage
    let backend: RecognitionBackend?
    let segments: [RecognitionSegmentMetadata]
    let wordProbabilities: [RecognitionWordProbability]
    let avgLogprob: Float?
    let minWordProbability: Float?
    let compressionRatio: Float?
    let decoderFallback: RecognitionDecoderFallback?
    let adaptive: AdaptiveRecognitionMetadata?

    init(
        text: String,
        language: DictationLanguage,
        backend: RecognitionBackend? = nil,
        segments: [RecognitionSegmentMetadata] = [],
        wordProbabilities: [RecognitionWordProbability] = [],
        avgLogprob: Float? = nil,
        minWordProbability: Float? = nil,
        compressionRatio: Float? = nil,
        decoderFallback: RecognitionDecoderFallback? = nil,
        adaptive: AdaptiveRecognitionMetadata? = nil
    ) {
        self.text = text
        self.language = language
        self.backend = backend
        self.segments = segments
        self.wordProbabilities = wordProbabilities
        self.avgLogprob = avgLogprob
        self.minWordProbability = minWordProbability
        self.compressionRatio = compressionRatio
        self.decoderFallback = decoderFallback
        self.adaptive = adaptive
    }
}

typealias RecognitionResult = RawTranscript

struct RecognitionSegmentMetadata: Equatable, Sendable {
    let text: String
    let avgLogprob: Float
    let compressionRatio: Float
    let noSpeechProbability: Float
    let wordProbabilities: [RecognitionWordProbability]
}

struct RecognitionWordProbability: Equatable, Sendable {
    let word: String
    let probability: Float
}

struct RecognitionDecoderFallback: Equatable, Sendable {
    let occurred: Bool
    let count: Int
    let reasons: [String]

    static let none = Self(occurred: false, count: 0, reasons: [])
}

struct AdaptiveRecognitionMetadata: Equatable, Sendable {
    let attemptedBackends: [RecognitionBackend]
    let selectedBackend: RecognitionBackend
    let fallbackReasons: [AdaptiveFallbackReason]
    let largeFallbackAccepted: Bool
}

enum AdaptiveFallbackReason: Equatable, Sendable {
    case backendFailure(RecognitionBackend)
    case lowAverageLogprob(Float)
    case lowWordProbability(Float)
    case highCompressionRatio(Float)
    case decoderFallback([String])
    case unresolvedPrioritizedLexicon([String])
    case suspiciousSentenceStructure
    case emptyTranscript
    case repetition
    case severeOmission
    case largeLowerQuality
}

struct LocalCandidate: Equatable, Sendable {
    let text: String
}

struct EnrichedCandidate: Equatable, Sendable {
    let text: String
}

enum FinalCandidate: Equatable, Sendable {
    case local(LocalCandidate)
    case enriched(EnrichedCandidate, localFallback: LocalCandidate)

    var text: String {
        switch self {
        case .local(let candidate):
            candidate.text
        case .enriched(let candidate, _):
            candidate.text
        }
    }
}

struct ConsentSnapshot: Equatable, Sendable {
    let cloudEnabled: Bool
    let contextToCloud: Bool

    static let localOnly = Self(cloudEnabled: false, contextToCloud: false)
}

enum InsertionOutcome: Equatable, Sendable {
    case confirmedDirect
    case safeFallback
}

struct DictationSession: Sendable {
    let id: DictationSessionID
    let language: DictationLanguage
    var recordingStartedAt: Date?
    var capturedTargetContext: CapturedTargetContext?
    var audioInput: AudioInput?
    var rawTranscript: RawTranscript?
    var localCandidate: LocalCandidate?
}
