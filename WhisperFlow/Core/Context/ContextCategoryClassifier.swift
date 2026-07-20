import Foundation

enum LocalContextCategory: String, CaseIterable, Equatable, Sendable {
    case email
    case workMessaging
    case personalMessaging
    case other

    var title: String {
        switch self {
        case .email: "Email"
        case .workMessaging: "Work Messaging"
        case .personalMessaging: "Personal Messaging"
        case .other: "Other"
        }
    }
}

struct ContextIdentityHints: Equatable, Sendable {
    let bundleIdentifier: String?
    let websiteHost: String?
    let visibleName: String?
    let visibleTerms: [String]
    let role: String?
    let subrole: String?
    let containsProtectedContent: Bool

    init(
        bundleIdentifier: String? = nil,
        websiteHost: String? = nil,
        visibleName: String? = nil,
        visibleTerms: [String] = [],
        role: String? = nil,
        subrole: String? = nil,
        containsProtectedContent: Bool = false
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.websiteHost = websiteHost
        self.visibleName = visibleName
        self.visibleTerms = visibleTerms
        self.role = role
        self.subrole = subrole
        self.containsProtectedContent = containsProtectedContent
    }
}

struct ContextClassification: Equatable, Sendable {
    let category: LocalContextCategory
    let safeHints: [String]
    let isContextAllowed: Bool

    var safeDecoderHints: [String] { safeHints }
}

struct ContextSurfaceIdentity: Equatable, Sendable {
    let canonicalName: String
    let category: LocalContextCategory
}

struct ContextSurfaceDetector: Sendable {
    func detect(
        bundleIdentifier: String?,
        websiteHost: String?,
        windowTitle: String?
    ) -> ContextSurfaceIdentity? {
        let identity = [bundleIdentifier, websiteHost, windowTitle]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        for surface in Self.knownSurfaces where surface.needles.contains(where: identity.contains) {
            return ContextSurfaceIdentity(
                canonicalName: surface.name,
                category: surface.category
            )
        }
        return nil
    }

    private static let knownSurfaces: [(
        name: String,
        category: LocalContextCategory,
        needles: [String]
    )] = [
        ("Codex", .workMessaging, ["com.openai.codex", "codex"]),
        ("ChatGPT", .workMessaging, ["chatgpt", "chat.openai.com", "com.openai.chat"]),
        ("Claude", .workMessaging, ["claude", "anthropic"]),
        ("Gemini", .workMessaging, ["gemini", "bard.google"]),
        ("Perplexity", .workMessaging, ["perplexity"]),
        ("Slack", .workMessaging, ["slack", "tinyspeck"]),
        ("Microsoft Teams", .workMessaging, ["msteams", "microsoft.teams", "teams.microsoft"]),
        ("Notion", .workMessaging, ["notion"]),
        ("Linear", .workMessaging, ["linear.app", "linear-linear"]),
        ("Jira", .workMessaging, ["jira", "atlassian"]),
        ("Messages", .personalMessaging, ["com.apple.messages", "imessage"]),
        ("WhatsApp", .personalMessaging, ["whatsapp"]),
        ("Telegram", .personalMessaging, ["telegram"]),
        ("Signal", .personalMessaging, ["signal"]),
        ("Discord", .personalMessaging, ["discord"]),
        ("Apple Mail", .email, ["com.apple.mail"]),
        ("Outlook", .email, ["outlook", "office.com/mail"]),
        ("Gmail", .email, ["mail.google.com", "gmail"]),
        ("Fastmail", .email, ["fastmail"]),
        ("HEY", .email, ["hey.com"])
    ]
}

struct ContextCategoryClassifier: Sendable {
    func classify(
        targetKind: TargetKind,
        identityHints hints: ContextIdentityHints? = nil
    ) -> ContextClassification {
        let identityClassification = hints.map(classify)
        guard let identityClassification else {
            return ContextClassification(
                category: fallbackCategory(for: targetKind),
                safeHints: [],
                isContextAllowed: true
            )
        }
        guard identityClassification.isContextAllowed else {
            return ContextClassification(
                category: .other,
                safeHints: [],
                isContextAllowed: false
            )
        }

        if identityClassification.category != .other {
            return identityClassification
        }
        return ContextClassification(
            category: fallbackCategory(for: targetKind),
            safeHints: identityClassification.safeHints,
            isContextAllowed: true
        )
    }

    func classify(_ hints: ContextIdentityHints) -> ContextClassification {
        guard !isSensitive(hints) else {
            return ContextClassification(
                category: .other,
                safeHints: [],
                isContextAllowed: false
            )
        }

        let category = category(for: hints)
        return ContextClassification(
            category: category,
            safeHints: safeVisibleHints(from: hints),
            isContextAllowed: true
        )
    }

    private func fallbackCategory(for targetKind: TargetKind) -> LocalContextCategory {
        switch targetKind {
        case .email:
            .email
        case .chat:
            .personalMessaging
        case .document, .unknown:
            .other
        }
    }

    private func category(for hints: ContextIdentityHints) -> LocalContextCategory {
        if let surface = ContextSurfaceDetector().detect(
            bundleIdentifier: hints.bundleIdentifier,
            websiteHost: hints.websiteHost,
            windowTitle: hints.visibleName
        ) {
            return surface.category
        }

        let volatileIdentity = [
            hints.bundleIdentifier,
            hints.websiteHost,
            hints.visibleName
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")

        if containsAny(volatileIdentity, ["mail", "outlook", "gmail", "hey.com", "fastmail"]) {
            return .email
        }
        if containsAny(volatileIdentity, ["slack", "teams", "notion", "linear", "jira"]) {
            return .workMessaging
        }
        if containsAny(volatileIdentity, ["messages", "imessage", "whatsapp", "telegram", "signal", "discord"]) {
            return .personalMessaging
        }

        let visibleTerms = hints.visibleTerms.joined(separator: " ").lowercased()
        if containsAny(visibleTerms, ["thread", "inbox", "subject", "reply"]) {
            return .email
        }
        if containsAny(visibleTerms, ["channel", "standup", "ticket", "sprint", "merge request"]) {
            return .workMessaging
        }
        if containsAny(visibleTerms, ["chat", "dm", "gruppe", "kontakt"]) {
            return .personalMessaging
        }
        return .other
    }

    private func safeVisibleHints(from hints: ContextIdentityHints) -> [String] {
        let surfaceName = ContextSurfaceDetector().detect(
            bundleIdentifier: hints.bundleIdentifier,
            websiteHost: hints.websiteHost,
            windowTitle: hints.visibleName
        )?.canonicalName.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        return ([hints.visibleName] + hints.visibleTerms.map(Optional.some))
            .compactMap { $0.flatMap(Self.safeHint) }
            .filter { hint in
                guard let surfaceName else { return true }
                return hint.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                ) != surfaceName
            }
            .removingDuplicates()
            .prefix(8)
            .map { $0 }
    }

    private func isSensitive(_ hints: ContextIdentityHints) -> Bool {
        if hints.containsProtectedContent { return true }
        let sensitiveSurface = [
            hints.role,
            hints.subrole,
            hints.visibleName
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")
        return containsAny(sensitiveSurface, ["secure", "password", "passwort", "credential", "secret"])
    }

    private func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains { value.contains($0) }
    }

    private static func safeHint(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 60,
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil else {
            return nil
        }
        let lowercased = trimmed.lowercased()
        guard !lowercased.contains("password"),
              !lowercased.contains("passwort"),
              !lowercased.contains("secret"),
              trimmed.range(of: #"\S+@\S+\.\S+"#, options: .regularExpression) == nil else {
            return nil
        }
        return trimmed
    }
}

private extension Array where Element: Hashable {
    func removingDuplicates() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
