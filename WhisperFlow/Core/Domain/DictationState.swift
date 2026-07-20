import Foundation

enum DictationPhase: Equatable, Sendable {
    case idle
    case priming
    case listening
    case transcribing
    case cleaning
    case enriching
    case inserting
    case success
    case cancelled
    case error(DictationFailure)

    var canStart: Bool {
        switch self {
        case .idle, .success, .cancelled, .error:
            true
        case .priming, .listening, .transcribing, .cleaning, .enriching, .inserting:
            false
        }
    }

    var isTerminal: Bool {
        switch self {
        case .success, .cancelled, .error:
            true
        case .idle, .priming, .listening, .transcribing, .cleaning, .enriching, .inserting:
            false
        }
    }
}

enum DictationFailureStage: Equatable, Sendable {
    case context
    case audioStart
    case audioFinalize
    case recognition
    case cleanup
    case insertion
}

struct DictationFailure: Equatable, Sendable {
    let stage: DictationFailureStage
}

struct DictationSnapshot: Equatable, Sendable {
    let phase: DictationPhase
    let activeSessionID: DictationSessionID?
}

enum StartOutcome: Equatable, Sendable {
    case started(DictationSessionID)
    case alreadyActive(DictationSessionID)
    case ignoredStale(DictationSessionID)
    case failed(DictationSessionID, DictationFailure)

    var sessionID: DictationSessionID {
        switch self {
        case .started(let id), .alreadyActive(let id), .ignoredStale(let id), .failed(let id, _):
            id
        }
    }
}

enum StopOutcome: Equatable, Sendable {
    case completed(DictationSessionID, InsertionOutcome)
    case noSpeech(DictationSessionID)
    case ignoredDuplicate(DictationSessionID)
    case ignoredStale(DictationSessionID)
    case failed(DictationSessionID, DictationFailure)
}

enum CancelOutcome: Equatable, Sendable {
    case cancelled(DictationSessionID)
    case tooLateCommitted(DictationSessionID)
    case ignoredStale(DictationSessionID)
    case noActiveSession
}
