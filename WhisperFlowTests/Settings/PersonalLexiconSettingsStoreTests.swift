import Foundation
import XCTest
@testable import WhisperFlow

final class PersonalLexiconSettingsStoreTests: XCTestCase, @unchecked Sendable {
    @MainActor
    func testOpeningExistingPreferencesPreservesSettingsAndPersonalDictionary() throws {
        XCTAssertEqual(FlusterFlowPreferences.domain, "com.flusterflow.private")
        let suiteName = "FlusterFlowUpdateTests-\(UUID().uuidString)"
        let previousDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { previousDefaults.removePersistentDomain(forName: suiteName) }

        let dictionary = Data("""
        [{
          "id": "13A5333C-4C50-4D7C-8DFB-2F98A997AB75",
          "canonical": "München",
          "misspellings": ["Munchen"],
          "language": "german",
          "priority": 7,
          "source": "manual",
          "createdAt": 0,
          "updatedAt": 0
        }]
        """.utf8)
        let saved: [String: Any] = [
            "flusterflow.personal-lexicon.entries": dictionary,
            "flusterflow.language": "german",
            "flusterflow.shortcut": "controlShiftSpace",
            "flusterflow.local-model": "whisperKitLargeV3Turbo",
            "flusterflow.context-awareness": false,
            "flusterflow.local-learning-enabled": false,
            "flusterflow.push-to-talk-enabled": false,
            "flusterflow.hands-free-enabled": true,
            "flusterflow.cloud-enabled": true,
            "flusterflow.cloud-context": false,
            "flusterflow.onboarding-completed": true,
            "flusterflow.future-setting": "preserve"
        ]
        previousDefaults.setPersistentDomain(saved, forName: suiteName)

        let updatedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let settings = SettingsStore(defaults: updatedDefaults)
        let lexicon = PersonalLexiconStore(defaults: updatedDefaults)

        XCTAssertEqual(settings.language, .german)
        XCTAssertEqual(settings.shortcut, .controlShiftSpace)
        XCTAssertEqual(settings.localModel, .whisperKitLargeV3Turbo)
        XCTAssertFalse(settings.contextAwarenessEnabled)
        XCTAssertFalse(settings.localLearningEnabled)
        XCTAssertFalse(settings.pushToTalkEnabled)
        XCTAssertTrue(settings.handsFreeEnabled)
        XCTAssertTrue(settings.cloudEnabled)
        XCTAssertFalse(settings.cloudContextEnabled)
        XCTAssertTrue(settings.onboardingCompleted)
        XCTAssertEqual(lexicon.entries.count, 1)
        XCTAssertEqual(lexicon.entries.first?.canonical, "München")
        XCTAssertEqual(lexicon.entries.first?.misspellings, ["Munchen"])
        XCTAssertEqual(lexicon.entries.first?.priority, 7)
        let afterOpening = try XCTUnwrap(updatedDefaults.persistentDomain(forName: suiteName))
        XCTAssertEqual(NSDictionary(dictionary: afterOpening), NSDictionary(dictionary: saved))
    }

    @MainActor
    func testManualEntriesCanBeAddedEditedPrioritizedUndoneDeletedAndReset() throws {
        try withIsolatedDefaults { defaults in
            let store = PersonalLexiconStore(defaults: defaults)

            let first = try XCTUnwrap(store.add(
                canonical: "WhisperFlow",
                misspellings: ["whisper flow"],
                language: .english
            ))
            let second = try XCTUnwrap(store.add(canonical: "Project Orbit", language: .automatic))

            XCTAssertEqual(store.entries.map(\.canonical), ["Project Orbit", "WhisperFlow"])

            XCTAssertTrue(store.prioritize(id: first.id))
            XCTAssertEqual(store.entries.first?.id, first.id)

            XCTAssertTrue(store.update(
                id: second.id,
                canonical: "PROJECT-ORBIT",
                misspellings: ["project-orbt"],
                language: .german,
                priority: 10
            ))
            XCTAssertEqual(store.entries.first?.canonical, "PROJECT-ORBIT")
            XCTAssertEqual(store.entries.first?.misspellings, ["project-orbt"])

            XCTAssertTrue(store.undoLastChange())
            XCTAssertEqual(store.entries.map(\.canonical).sorted(), ["Project Orbit", "WhisperFlow"])

            XCTAssertTrue(store.delete(id: first.id))
            XCTAssertEqual(store.entries.map(\.id), [second.id])

            XCTAssertTrue(store.reset())
            XCTAssertTrue(store.entries.isEmpty)
        }
    }

    @MainActor
    func testManualEntriesPersistUsingCorePersonalLexiconEntryShape() throws {
        try withIsolatedDefaults { defaults in
            let store = PersonalLexiconStore(defaults: defaults)
            let entry = try XCTUnwrap(store.add(
                canonical: "Parakeet",
                misspellings: ["parakit"],
                language: .english,
                priority: 7
            ))

            let restarted = PersonalLexiconStore(defaults: defaults)

            XCTAssertEqual(restarted.entries.count, 1)
            XCTAssertEqual(restarted.entries.first?.id, entry.id)
            XCTAssertEqual(restarted.entries.first?.canonical, "Parakeet")
            XCTAssertEqual(restarted.entries.first?.misspellings, ["parakit"])
            XCTAssertEqual(restarted.entries.first?.language, .english)
            XCTAssertEqual(restarted.entries.first?.priority, 7)
            XCTAssertEqual(restarted.entries.first?.source, .manual)
        }
    }

    @MainActor
    func testLearningResultsPersistOnlyWordPairsAndKeepSuggestionsEphemeral() {
        withIsolatedDefaults { defaults in
            let store = PersonalLexiconStore(defaults: defaults)
            let learned = PersonalLexiconEntry(
                id: UUID(),
                canonical: "WhisperFlow",
                misspellings: ["whisperflow"],
                language: .english,
                priority: 1,
                source: .oneWordCorrection,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 1)
            )
            let suggestion = PersonalLexiconSuggestion(
                id: UUID(),
                canonical: "Neural Engine",
                misspellings: ["Neural Engin"],
                language: .english,
                reason: .multiTokenCorrection
            )

            store.applyLearningResult(.learned(learned))
            store.applyLearningResult(.suggested(suggestion))

            let restarted = PersonalLexiconStore(defaults: defaults)
            XCTAssertEqual(restarted.entries, [learned])
            XCTAssertTrue(restarted.suggestions.isEmpty)
            XCTAssertEqual(store.suggestions, [suggestion])
            XCTAssertNotNil(store.acceptSuggestion(id: suggestion.id))
            XCTAssertTrue(store.suggestions.isEmpty)
            XCTAssertEqual(store.entries.count, 2)
        }
    }

    @MainActor
    private func withIsolatedDefaults(
        _ operation: (UserDefaults) throws -> Void
    ) rethrows {
        let suiteName = "PersonalLexiconSettingsStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try operation(defaults)
    }
}
