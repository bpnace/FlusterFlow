import Foundation

struct TextRewriterIdentifier: Hashable, Sendable, CustomStringConvertible {
    static let appleFoundationModels = Self("apple-foundation-models")

    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    var description: String { rawValue }
}

enum TextRewriteLanguage: String, Equatable, Sendable {
    case automatic
    case german
    case english
}

enum TextRewriteContextCategory: String, Equatable, Sendable {
    case email
    case workMessaging
    case personalMessaging
    case other
}

enum TextRewriteContextAvailability: Equatable, Sendable {
    case available
    case unavailable
    case deniedSensitive
}

enum TextRewriteReconstructionPolicy: String, Equatable, Sendable {
    case contextSupportedReconstruction
}

enum TextRewriteTargetFormat: String, Equatable, Sendable {
    case email
    case message
    case prose
}

struct TextRewriteContext: Equatable, Sendable {
    static let maximumContextCharacters = 1_500

    let category: TextRewriteContextCategory
    let availability: TextRewriteContextAvailability
    let boundedText: String?
    let protectedTerms: [String]

    init(
        category: TextRewriteContextCategory,
        availability: TextRewriteContextAvailability,
        boundedText: String?,
        protectedTerms: [String]
    ) {
        self.category = category
        self.availability = availability
        self.boundedText = boundedText.map {
            String($0.prefix(Self.maximumContextCharacters))
        }
        self.protectedTerms = protectedTerms
    }
}

struct TextRewriteRequest: Equatable, Sendable {
    let sessionID: DictationSessionID
    let localCandidate: LocalCandidate
    let language: TextRewriteLanguage
    let context: TextRewriteContext
    let reconstructionPolicy: TextRewriteReconstructionPolicy
    let targetFormat: TextRewriteTargetFormat

    init(
        sessionID: DictationSessionID,
        localCandidate: LocalCandidate,
        language: TextRewriteLanguage,
        context: TextRewriteContext,
        reconstructionPolicy: TextRewriteReconstructionPolicy = .contextSupportedReconstruction,
        targetFormat: TextRewriteTargetFormat? = nil
    ) {
        self.sessionID = sessionID
        self.localCandidate = localCandidate
        self.language = language
        self.context = context
        self.reconstructionPolicy = reconstructionPolicy
        self.targetFormat = targetFormat ?? Self.defaultTargetFormat(for: context.category)
    }

    private static func defaultTargetFormat(
        for category: TextRewriteContextCategory
    ) -> TextRewriteTargetFormat {
        switch category {
        case .email: .email
        case .workMessaging, .personalMessaging: .message
        case .other: .prose
        }
    }
}

struct TextRewritePrewarmRequest: Equatable, Sendable {
    let sessionID: DictationSessionID
    let language: TextRewriteLanguage
    let context: TextRewriteContext
    let promptPrefix: String

    init(
        sessionID: DictationSessionID,
        language: TextRewriteLanguage,
        context: TextRewriteContext,
        promptPrefix: String = ""
    ) {
        self.sessionID = sessionID
        self.language = language
        self.context = context
        self.promptPrefix = promptPrefix
    }
}

enum TextRewriteUnavailableReason: Equatable, Sendable {
    case frameworkUnavailable
    case operatingSystemUnsupported
    case modelUnavailable
    case unsupportedLanguage
    case sensitiveContextDenied
}

enum TextRewriteFailureReason: Equatable, Sendable {
    case invalidModelOutput
    case generationFailed
}

enum TextRewriteValidationIssue: Equatable, Sendable {
    case lostProtectedAnchor
    case lostProtectedContextTerm
    case inventedClaim
    case excessiveDeviation
    case unknownMeaningChange
}

struct TextRewritePrewarmResult: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case warmed
        case unavailable
        case failed
    }

    let outcome: Outcome
    let unavailableReason: TextRewriteUnavailableReason?
    let failureReason: TextRewriteFailureReason?

    static let warmed = Self(
        outcome: .warmed,
        unavailableReason: nil,
        failureReason: nil
    )

    static func unavailable(_ reason: TextRewriteUnavailableReason) -> Self {
        Self(
            outcome: .unavailable,
            unavailableReason: reason,
            failureReason: nil
        )
    }

    static func failed(_ reason: TextRewriteFailureReason) -> Self {
        Self(
            outcome: .failed,
            unavailableReason: nil,
            failureReason: reason
        )
    }
}

struct TextRewriteResult: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case accepted
        case rejected
        case unavailable
        case failed
        case cancelled
    }

    let originalText: String
    let rewrittenText: String?
    let outcome: Outcome
    let unavailableReason: TextRewriteUnavailableReason?
    let failureReason: TextRewriteFailureReason?
    let validationIssues: [TextRewriteValidationIssue]
    let sanitizerActionCount: Int
    let usedContextTermCount: Int
    let hadAmbiguity: Bool

    var outputText: String {
        rewrittenText ?? originalText
    }

    static func accepted(
        originalText: String,
        rewrittenText: String,
        sanitizerActionCount: Int = 0,
        usedContextTermCount: Int = 0,
        hadAmbiguity: Bool = false
    ) -> Self {
        Self(
            originalText: originalText,
            rewrittenText: rewrittenText,
            outcome: .accepted,
            unavailableReason: nil,
            failureReason: nil,
            validationIssues: [],
            sanitizerActionCount: sanitizerActionCount,
            usedContextTermCount: usedContextTermCount,
            hadAmbiguity: hadAmbiguity
        )
    }

    static func rejected(
        originalText: String,
        issues: [TextRewriteValidationIssue],
        sanitizerActionCount: Int = 0,
        usedContextTermCount: Int = 0,
        hadAmbiguity: Bool = false
    ) -> Self {
        Self(
            originalText: originalText,
            rewrittenText: nil,
            outcome: .rejected,
            unavailableReason: nil,
            failureReason: nil,
            validationIssues: issues,
            sanitizerActionCount: sanitizerActionCount,
            usedContextTermCount: usedContextTermCount,
            hadAmbiguity: hadAmbiguity
        )
    }

    static func unavailable(
        originalText: String,
        reason: TextRewriteUnavailableReason
    ) -> Self {
        Self(
            originalText: originalText,
            rewrittenText: nil,
            outcome: .unavailable,
            unavailableReason: reason,
            failureReason: nil,
            validationIssues: [],
            sanitizerActionCount: 0,
            usedContextTermCount: 0,
            hadAmbiguity: false
        )
    }

    static func failed(
        originalText: String,
        reason: TextRewriteFailureReason
    ) -> Self {
        Self(
            originalText: originalText,
            rewrittenText: nil,
            outcome: .failed,
            unavailableReason: nil,
            failureReason: reason,
            validationIssues: [],
            sanitizerActionCount: 0,
            usedContextTermCount: 0,
            hadAmbiguity: false
        )
    }

    static func cancelled(originalText: String) -> Self {
        Self(
            originalText: originalText,
            rewrittenText: nil,
            outcome: .cancelled,
            unavailableReason: nil,
            failureReason: nil,
            validationIssues: [],
            sanitizerActionCount: 0,
            usedContextTermCount: 0,
            hadAmbiguity: false
        )
    }
}

protocol TextRewriting: Sendable {
    var identifier: TextRewriterIdentifier { get }

    func rewrite(_ request: TextRewriteRequest) async -> TextRewriteResult
    func cancel(sessionID: DictationSessionID) async
}

protocol TextRewritePrewarming: Sendable {
    func prewarm(_ request: TextRewritePrewarmRequest) async -> TextRewritePrewarmResult
}

extension TextRewriteLanguage {
    init(_ language: DictationLanguage) {
        switch language {
        case .automatic: self = .automatic
        case .german: self = .german
        case .english: self = .english
        }
    }
}

extension TextRewriteContextCategory {
    init(_ localCategory: LocalContextCategory) {
        switch localCategory {
        case .email: self = .email
        case .workMessaging: self = .workMessaging
        case .personalMessaging: self = .personalMessaging
        case .other: self = .other
        }
    }
}

extension TextRewriteContextAvailability {
    init(_ availability: ContextSnapshot.Availability) {
        switch availability {
        case .available: self = .available
        case .unavailable: self = .unavailable
        case .deniedSensitive: self = .deniedSensitive
        }
    }
}

extension TextRewriteContext {
    init(_ context: ContextSnapshot) {
        let availability = TextRewriteContextAvailability(context.availability)
        self.init(
            category: TextRewriteContextCategory(context.localCategory),
            availability: availability,
            boundedText: availability == .available ? context.boundedText : nil,
            protectedTerms: (context.safeDecoderHints + context.termHints)
        )
    }
}
