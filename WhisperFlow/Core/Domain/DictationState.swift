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

enum DictationFailureReason: Equatable, Sendable {
    case serviceFailure
    case recognitionTimedOut
    case recognizerBusy
}

struct DictationFailure: Equatable, Sendable {
    let stage: DictationFailureStage
    var reason: DictationFailureReason = .serviceFailure

    var compactTitle: String {
        switch reason {
        case .recognitionTimedOut: return "Erkennung dauert zu lange"
        case .recognizerBusy: return "Erkennung beschäftigt"
        case .serviceFailure: break
        }
        switch stage {
        case .context: return "Textfeld auswählen"
        case .audioStart: return "Mikrofonfehler"
        case .audioFinalize: return "Audiofehler"
        case .recognition: return "Erkennung fehlgeschlagen"
        case .cleanup: return "Korrektur fehlgeschlagen"
        case .insertion: return "Einfügen fehlgeschlagen"
        }
    }

    var title: String {
        switch reason {
        case .recognitionTimedOut: return "Spracherkennung dauert zu lange"
        case .recognizerBusy: return "Spracherkennung noch beschäftigt"
        case .serviceFailure: break
        }
        switch stage {
        case .context: return "Textfeld auswählen"
        case .audioStart: return "Mikrofonaufnahme fehlgeschlagen"
        case .audioFinalize: return "Audio konnte nicht verarbeitet werden"
        case .recognition: return "Spracherkennung fehlgeschlagen"
        case .cleanup: return "Textkorrektur fehlgeschlagen"
        case .insertion: return "Einfügen fehlgeschlagen"
        }
    }
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
    case failed(DictationSessionID, DictationFailure)
    case tooLateCommitted(DictationSessionID)
    case ignoredStale(DictationSessionID)
    case noActiveSession
}
