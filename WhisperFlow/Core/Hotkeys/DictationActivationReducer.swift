import Foundation

enum DictationActivationMode: Equatable, Sendable {
    case disabled
    case doubleTap
}

enum DictationActivationAction: Equatable, Sendable {
    case beginPushToTalk
    case endPushToTalk
    case beginHandsFree
    case endHandsFree
    case none
}

/// Converts de-bounced global shortcut edges into mutually exclusive activation commands.
/// `at` must come from a monotonic clock (for example, ContinuousClock).
struct DictationActivationReducer: Sendable {
    static let doubleTapThreshold: TimeInterval = 0.30

    private(set) var mode: DictationActivationMode
    private(set) var isPushToTalkPressed = false
    private(set) var isHandsFreeActive = false
    private(set) var secondTapDeadline: TimeInterval?
    private var pushToTalkPressedAt: TimeInterval?
    private var ignoreNextRelease = false

    init(mode: DictationActivationMode) {
        self.mode = mode
    }

    mutating func reset(mode: DictationActivationMode? = nil) {
        if let mode { self.mode = mode }
        isPushToTalkPressed = false
        isHandsFreeActive = false
        secondTapDeadline = nil
        pushToTalkPressedAt = nil
        ignoreNextRelease = false
    }

    /// Explicit UI promotion is independent of the optional double-tap gesture.
    mutating func switchToHandsFree() {
        isHandsFreeActive = true
        secondTapDeadline = nil
        ignoreNextRelease = isPushToTalkPressed
    }

    func isAwaitingSecondTap(at time: TimeInterval) -> Bool {
        guard mode == .doubleTap,
              let secondTapDeadline else { return false }
        let windowStart = secondTapDeadline - Self.doubleTapThreshold
        return time >= windowStart && time <= secondTapDeadline
    }

    mutating func consume(
        _ event: PushToTalkHotKeyEvent,
        at time: TimeInterval
    ) -> DictationActivationAction {
        switch event {
        case .pressed:
            guard !isPushToTalkPressed else { return .none }
            if isHandsFreeActive {
                isHandsFreeActive = false
                isPushToTalkPressed = true
                pushToTalkPressedAt = time
                ignoreNextRelease = true
                secondTapDeadline = nil
                return .endHandsFree
            }
            isPushToTalkPressed = true
            pushToTalkPressedAt = time
            if isAwaitingSecondTap(at: time) {
                isPushToTalkPressed = false
                pushToTalkPressedAt = nil
                isHandsFreeActive = true
                secondTapDeadline = nil
                return .beginHandsFree
            }
            secondTapDeadline = nil
            return .beginPushToTalk

        case .released:
            guard isPushToTalkPressed else { return .none }
            isPushToTalkPressed = false
            let pressedAt = pushToTalkPressedAt
            pushToTalkPressedAt = nil
            if ignoreNextRelease {
                ignoreNextRelease = false
                secondTapDeadline = nil
                return .none
            }
            if mode == .doubleTap,
               let pressedAt,
               time >= pressedAt,
               time - pressedAt <= Self.doubleTapThreshold {
                secondTapDeadline = time + Self.doubleTapThreshold
            } else {
                secondTapDeadline = nil
            }
            return .endPushToTalk
        }
    }
}
