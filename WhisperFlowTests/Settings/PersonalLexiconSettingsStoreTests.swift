import Foundation
import XCTest
@testable import WhisperFlow

final class PersonalLexiconSettingsStoreTests: XCTestCase, @unchecked Sendable {
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
