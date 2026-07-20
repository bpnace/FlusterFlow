import XCTest
@testable import WhisperFlow

final class ContextCategoryClassifierTests: XCTestCase {
    func testClassifiesFromTargetKindWhenNoVolatileIdentityIsAvailable() {
        let classifier = ContextCategoryClassifier()

        let email = classifier.classify(targetKind: .email)
        let chat = classifier.classify(targetKind: .chat)

        XCTAssertEqual(email.category, .email)
        XCTAssertEqual(email.safeDecoderHints, [])
        XCTAssertEqual(chat.category, .personalMessaging)
    }

    func testDetectsBrowserAssistantChatFromVolatileHostWithoutLeakingIdentity() {
        let classifier = ContextCategoryClassifier()
        let surface = ContextSurfaceDetector().detect(
            bundleIdentifier: "com.brave.Browser",
            websiteHost: "chatgpt.com",
            windowTitle: "Private project title – ChatGPT"
        )

        let result = classifier.classify(
            targetKind: .unknown,
            identityHints: ContextIdentityHints(
                bundleIdentifier: "com.brave.Browser",
                websiteHost: "chatgpt.com",
                visibleName: surface?.canonicalName
            )
        )

        XCTAssertEqual(surface?.canonicalName, "ChatGPT")
        XCTAssertEqual(result.category, .workMessaging)
        XCTAssertEqual(result.safeDecoderHints, [])
        XCTAssertFalse(result.safeDecoderHints.contains("chatgpt.com"))
        XCTAssertFalse(result.safeDecoderHints.contains("com.brave.Browser"))
        XCTAssertFalse(result.safeDecoderHints.contains { $0.contains("Private project") })
    }

    func testDetectsCommonAssistantChatSurfacesAsMessageContexts() {
        let detector = ContextSurfaceDetector()

        XCTAssertEqual(
            detector.detect(
                bundleIdentifier: "com.openai.codex",
                websiteHost: nil,
                windowTitle: nil
            ),
            ContextSurfaceIdentity(canonicalName: "Codex", category: .workMessaging)
        )
        XCTAssertEqual(
            detector.detect(
                bundleIdentifier: "com.brave.Browser",
                websiteHost: "claude.ai",
                windowTitle: nil
            ),
            ContextSurfaceIdentity(canonicalName: "Claude", category: .workMessaging)
        )
        XCTAssertEqual(
            detector.detect(
                bundleIdentifier: "com.brave.Browser",
                websiteHost: "gemini.google.com",
                windowTitle: nil
            ),
            ContextSurfaceIdentity(canonicalName: "Gemini", category: .workMessaging)
        )
    }

    func testUsesVolatileIdentityWithoutReturningBundleOrHost() {
        let classifier = ContextCategoryClassifier()

        let result = classifier.classify(
            targetKind: .chat,
            identityHints: ContextIdentityHints(
                bundleIdentifier: "com.tinyspeck.slackmacgap",
                websiteHost: "workspace.slack.com",
                visibleName: "Team Engineering",
                visibleTerms: ["release channel", "owner@example.com"]
            )
        )

        XCTAssertEqual(result.category, .workMessaging)
        XCTAssertEqual(result.safeDecoderHints, ["Team Engineering", "release channel"])
        XCTAssertFalse(result.safeDecoderHints.contains("com.tinyspeck.slackmacgap"))
        XCTAssertFalse(result.safeDecoderHints.contains("workspace.slack.com"))
    }

    func testSensitiveFieldsDenyContextAndRemoveHints() {
        let classifier = ContextCategoryClassifier()

        let result = classifier.classify(
            targetKind: .email,
            identityHints: ContextIdentityHints(
                visibleName: "Password",
                visibleTerms: ["secret project"],
                subrole: "AXSecureTextField"
            )
        )

        XCTAssertEqual(result.category, .other)
        XCTAssertFalse(result.isContextAllowed)
        XCTAssertEqual(result.safeDecoderHints, [])
    }

    func testContextSnapshotDefaultsRemainCompatible() {
        let snapshot = ContextSnapshot(
            availability: .available,
            targetKind: .email,
            boundedText: "Hallo",
            termHints: ["Hallo"]
        )

        XCTAssertEqual(snapshot.localCategory, .email)
        XCTAssertEqual(snapshot.safeDecoderHints, [])
    }
}
