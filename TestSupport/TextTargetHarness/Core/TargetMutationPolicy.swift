import Foundation

public struct HarnessSelection: Codable, Equatable, Sendable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

public struct HarnessTargetState: Codable, Equatable, Sendable {
    public let processIdentifier: Int32
    public let targetIdentifier: String
    public let sessionIdentifier: String
    public let selection: HarnessSelection
    public let isFocused: Bool
    public let isProtected: Bool
    public let supportsSelectedText: Bool
    public let supportsUnicodeFallback: Bool

    public init(
        processIdentifier: Int32,
        targetIdentifier: String,
        sessionIdentifier: String,
        selection: HarnessSelection,
        isFocused: Bool,
        isProtected: Bool,
        supportsSelectedText: Bool,
        supportsUnicodeFallback: Bool
    ) {
        self.processIdentifier = processIdentifier
        self.targetIdentifier = targetIdentifier
        self.sessionIdentifier = sessionIdentifier
        self.selection = selection
        self.isFocused = isFocused
        self.isProtected = isProtected
        self.supportsSelectedText = supportsSelectedText
        self.supportsUnicodeFallback = supportsUnicodeFallback
    }
}

public enum HarnessMutationDecision: Equatable, Sendable {
    case directAX
    case guardedUnicode
    case reject(reason: HarnessRejectionReason)
}

public enum HarnessRejectionReason: String, Codable, Equatable, Sendable {
    case sessionMismatch
    case focusFingerprintMismatch
    case selectionFingerprintMismatch
    case secureField
    case noConfirmableMutationPath
}

public struct TargetMutationPolicy: Sendable {
    public init() {}

    public func decision(
        captured: HarnessTargetState,
        current: HarnessTargetState,
        activeSessionIdentifier: String
    ) -> HarnessMutationDecision {
        guard captured.sessionIdentifier == activeSessionIdentifier,
              current.sessionIdentifier == activeSessionIdentifier else {
            return .reject(reason: .sessionMismatch)
        }
        guard !captured.isProtected, !current.isProtected else {
            return .reject(reason: .secureField)
        }
        guard captured.processIdentifier == current.processIdentifier,
              captured.targetIdentifier == current.targetIdentifier,
              current.isFocused else {
            return .reject(reason: .focusFingerprintMismatch)
        }
        guard captured.selection == current.selection else {
            return .reject(reason: .selectionFingerprintMismatch)
        }
        if current.supportsSelectedText {
            return .directAX
        }
        if current.supportsUnicodeFallback {
            return .guardedUnicode
        }
        return .reject(reason: .noConfirmableMutationPath)
    }
}

public enum ConfirmedTextMutation {
    public static func replacingUTF16Range(
        in original: String,
        range: HarnessSelection,
        with replacement: String
    ) -> String? {
        guard range.location >= 0,
              range.length >= 0,
              let swiftRange = Range(
                  NSRange(location: range.location, length: range.length),
                  in: original
              ) else {
            return nil
        }
        return original.replacingCharacters(in: swiftRange, with: replacement)
    }

    public static func confirms(
        original: String,
        originalSelection: HarnessSelection,
        replacement: String,
        currentText: String,
        currentSelection: HarnessSelection
    ) -> Bool {
        guard let expectedText = replacingUTF16Range(
            in: original,
            range: originalSelection,
            with: replacement
        ) else {
            return false
        }
        let expectedSelection = HarnessSelection(
            location: originalSelection.location + replacement.utf16.count,
            length: 0
        )
        return currentText == expectedText && currentSelection == expectedSelection
    }
}

public struct ExplicitCopyPolicy: Sendable {
    public init() {}

    public func shouldWriteGeneralPasteboard(explicitUserAction: Bool) -> Bool {
        explicitUserAction
    }
}
