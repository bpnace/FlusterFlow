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
    private var lastPushToTalkRelease: TimeInterval?
    private var ignoreNextRelease = false

    init(mode: DictationActivationMode) {
        self.mode = mode
    }

    mutating func reset(mode: DictationActivationMode? = nil) {
        if let mode { self.mode = mode }
        isPushToTalkPressed = false
        isHandsFreeActive = false
        lastPushToTalkRelease = nil
        ignoreNextRelease = false
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
                ignoreNextRelease = true
                lastPushToTalkRelease = nil
                return .endHandsFree
            }
            isPushToTalkPressed = true
            if mode == .doubleTap,
               let lastPushToTalkRelease,
               time >= lastPushToTalkRelease,
               time - lastPushToTalkRelease <= Self.doubleTapThreshold {
                isPushToTalkPressed = false
                isHandsFreeActive = true
                return .beginHandsFree
            }
            return .beginPushToTalk

        case .released:
            guard isPushToTalkPressed else { return .none }
            isPushToTalkPressed = false
            if ignoreNextRelease {
                ignoreNextRelease = false
                return .none
            }
            lastPushToTalkRelease = time
            return .endPushToTalk
        }
    }
}
