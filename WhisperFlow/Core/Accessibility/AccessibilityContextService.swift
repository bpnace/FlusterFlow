import Foundation

struct VisibleContextFragment: Equatable, Sendable {
    let text: String
    let isSensitive: Bool

    init(text: String, isSensitive: Bool = false) {
        self.text = text
        self.isSensitive = isSensitive
    }
}

enum BoundedContextComposer {
    static func compose(
        focusedFieldText: String?,
        visibleFragments: [VisibleContextFragment],
        maximumCharacters: Int
    ) -> String? {
        guard maximumCharacters > 0 else { return nil }

        var seen: Set<String> = []
        var values = visibleFragments.compactMap { fragment -> String? in
            guard !fragment.isSensitive,
                  let normalized = normalized(fragment.text),
                  !isInterfaceChrome(normalized) else {
                return nil
            }
            let key = normalized.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            return seen.insert(key).inserted ? normalized : nil
        }

        if let fieldText = focusedFieldText.flatMap(normalized) {
            let key = fieldText.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            if seen.insert(key).inserted {
                values.append(fieldText)
            }
        }

        guard !values.isEmpty else { return nil }
        let combined = values.joined(separator: "\n")
        return String(combined.suffix(maximumCharacters))
    }

    private static func normalized(_ value: String) -> String? {
        let normalized = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.rangeOfCharacter(from: .controlCharacters) == nil else {
            return nil
        }
        return normalized
    }

    private static func isInterfaceChrome(_ value: String) -> Bool {
        let normalized = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        return [
            "send", "senden", "attach", "anhangen", "copy", "kopieren",
            "edit", "bearbeiten", "share", "teilen", "retry", "regenerate",
            "new chat", "neuer chat", "voice mode", "sprachmodus"
        ].contains(normalized)
    }
}

actor AccessibilityContextService: TargetContextProviding {
    static let maximumContextCharacters = 1_500

    private let registry: any AccessibilityTargetAccessing
    private let contextEnabled: @Sendable () async -> Bool

    init(
        registry: any AccessibilityTargetAccessing,
        contextEnabled: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.registry = registry
        self.contextEnabled = contextEnabled
    }

    func capture(for sessionID: DictationSessionID) async throws -> CapturedTargetContext {
        let captured = try await captureTarget(for: sessionID)
        return try await enrichContext(for: captured, sessionID: sessionID)
    }

    func captureTarget(for sessionID: DictationSessionID) async throws -> CapturedTargetContext {
        let capture = await registry.captureTarget(for: sessionID)
        switch capture {
        case .unavailable(let processIdentifier):
            return CapturedTargetContext(
                target: .unavailable(
                    processIdentifier: processIdentifier,
                    sessionID: sessionID
                ),
                context: .unavailable(targetKind: .unknown)
            )

        case .captured(let captured):
            if captured.security == .deniedSensitive {
                return CapturedTargetContext(
                    target: captured.snapshot,
                    context: ContextSnapshot(
                        availability: .deniedSensitive,
                        targetKind: captured.targetKind,
                        boundedText: nil,
                        termHints: [],
                        localCategory: .other,
                        safeDecoderHints: []
                    )
                )
            }
            return CapturedTargetContext(
                target: captured.snapshot,
                context: .unavailable(
                    targetKind: captured.targetKind,
                    localCategory: captured.localCategory,
                    safeDecoderHints: captured.safeDecoderHints
                )
            )
        }
    }

    func enrichContext(
        for captured: CapturedTargetContext,
        sessionID _: DictationSessionID
    ) async throws -> CapturedTargetContext {
        guard captured.target.isRegistered,
              captured.context.availability != .deniedSensitive,
              await contextEnabled() else {
            return captured
        }

        guard let text = await registry.boundedContext(
            for: captured.target,
            maximumCharacters: Self.maximumContextCharacters
        ) else {
            return captured
        }

        return CapturedTargetContext(
            target: captured.target,
            context: ContextSnapshot(
                availability: .available,
                targetKind: captured.context.targetKind,
                boundedText: String(text.prefix(Self.maximumContextCharacters)),
                termHints: [],
                localCategory: captured.context.localCategory,
                safeDecoderHints: captured.context.safeDecoderHints
            )
        )
    }

    func cancel(sessionID: DictationSessionID) async {
        await registry.releaseTargets(for: sessionID)
    }
}
