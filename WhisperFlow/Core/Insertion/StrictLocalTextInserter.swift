import Foundation

actor StrictLocalTextInserter: TextInserting {
    private let targets: any AccessibilityTargetAccessing
    private var permits: [DictationSessionID: InsertionCommitPermit] = [:]
    private var cancelledSessions: Set<DictationSessionID> = []
    private var cancellationOrder: [DictationSessionID] = []

    init(targets: any AccessibilityTargetAccessing) {
        self.targets = targets
    }

    func insert(
        _ candidate: FinalCandidate,
        sessionID: DictationSessionID
    ) async throws -> InsertionOutcome {
        guard !cancelledSessions.contains(sessionID),
              !candidate.text.isEmpty else {
            await targets.releaseTargets(for: sessionID)
            return .safeFallback
        }

        let permit = permits[sessionID] ?? InsertionCommitPermit()
        permits[sessionID] = permit

        let currentCapture = await targets.captureTarget(for: sessionID)
        guard !cancelledSessions.contains(sessionID),
              case .captured(let currentTarget) = currentCapture,
              currentTarget.security == .standard else {
            await targets.releaseTargets(for: sessionID)
            return .safeFallback
        }

        let attempt = await targets.insertSelectedText(
            candidate.text,
            into: currentTarget.snapshot,
            sessionID: sessionID,
            permit: permit
        )
        switch attempt {
        case .confirmed:
            await targets.observeRecentCorrection(
                of: candidate.text,
                in: currentTarget.snapshot,
                sessionID: sessionID
            )
            return .confirmedDirect
        case .unsupported, .unconfirmedMutation, .denied:
            return .safeFallback
        }
    }

    func requestCancellation(
        sessionID: DictationSessionID
    ) async -> InsertionCancellationDisposition {
        let disposition: InsertionCancellationDisposition
        if let permit = permits[sessionID] {
            disposition = permit.requestCancellation()
        } else {
            disposition = .cancelledBeforeCommit
        }

        guard disposition == .cancelledBeforeCommit else {
            return disposition
        }

        if cancelledSessions.insert(sessionID).inserted {
            cancellationOrder.append(sessionID)
        }
        if cancellationOrder.count > 256 {
            let expiredCount = cancellationOrder.count - 256
            let expired = Array(cancellationOrder.prefix(expiredCount))
            cancellationOrder.removeFirst(expiredCount)
            cancelledSessions.subtract(expired)
        }
        await targets.releaseTargets(for: sessionID)
        return disposition
    }

    func releaseInsertionSession(sessionID: DictationSessionID) async {
        permits.removeValue(forKey: sessionID)
        cancelledSessions.remove(sessionID)
        cancellationOrder.removeAll { $0 == sessionID }
        await targets.releaseTargets(for: sessionID)
    }
}
