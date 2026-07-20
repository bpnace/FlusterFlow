import Foundation

enum TargetSecurityDisposition: Equatable, Sendable {
    case standard
    case deniedSensitive
}

struct RegisteredTargetCapture: Equatable, Sendable {
    let snapshot: TargetSnapshot
    let targetKind: TargetKind
    let security: TargetSecurityDisposition
    let localCategory: LocalContextCategory
    let safeDecoderHints: [String]

    init(
        snapshot: TargetSnapshot,
        targetKind: TargetKind,
        security: TargetSecurityDisposition,
        localCategory: LocalContextCategory = .other,
        safeDecoderHints: [String] = []
    ) {
        self.snapshot = snapshot
        self.targetKind = targetKind
        self.security = security
        self.localCategory = localCategory
        self.safeDecoderHints = safeDecoderHints
    }
}

enum RegisteredTargetCaptureResult: Equatable, Sendable {
    case captured(RegisteredTargetCapture)
    case unavailable(processIdentifier: Int32)
}

enum DirectInsertionAttempt: Equatable, Sendable {
    case confirmed
    case unsupported
    case unconfirmedMutation
    case denied
}

extension TargetSnapshot {
    static func unavailable(
        processIdentifier: Int32,
        sessionID: DictationSessionID
    ) -> Self {
        Self(
            processIdentifier: processIdentifier,
            token: TargetToken(rawValue: 0),
            selectionFingerprint: SelectionFingerprint(rawValue: 0),
            sessionID: sessionID
        )
    }
}

protocol AccessibilityTargetAccessing: Sendable {
    func captureTarget(for sessionID: DictationSessionID) async -> RegisteredTargetCaptureResult
    func boundedContext(for target: TargetSnapshot, maximumCharacters: Int) async -> String?
    func insertSelectedText(
        _ text: String,
        into target: TargetSnapshot,
        sessionID: DictationSessionID,
        permit: InsertionCommitPermit
    ) async -> DirectInsertionAttempt
    func observeRecentCorrection(
        of insertedText: String,
        in target: TargetSnapshot,
        sessionID: DictationSessionID
    ) async
    func releaseTargets(for sessionID: DictationSessionID) async
}

extension AccessibilityTargetAccessing {
    func observeRecentCorrection(
        of insertedText: String,
        in target: TargetSnapshot,
        sessionID: DictationSessionID
    ) async {}
}
