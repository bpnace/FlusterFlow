import Foundation

enum InsertionCommitExecution<Value> {
    case cancelled
    case performed(Value)
}

final class InsertionCommitPermit: @unchecked Sendable {
    private enum State {
        case available
        case cancelled
        case committed
    }

    private let lock = NSLock()
    private var state: State = .available

    func performCommit<Value>(
        _ operation: () -> Value
    ) -> InsertionCommitExecution<Value> {
        lock.lock()
        guard state == .available else {
            lock.unlock()
            return .cancelled
        }

        state = .committed
        let value = operation()
        lock.unlock()
        return .performed(value)
    }

    func requestCancellation() -> InsertionCancellationDisposition {
        lock.lock()
        defer { lock.unlock() }

        switch state {
        case .available:
            state = .cancelled
            return .cancelledBeforeCommit
        case .cancelled:
            return .cancelledBeforeCommit
        case .committed:
            return .tooLateCommitted
        }
    }
}
