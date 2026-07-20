import XCTest
@testable import WhisperFlow

final class PersonalLexiconTests: XCTestCase {
    func testRecentCorrectionDetectorExtractsOnlyTheChangedWord() throws {
        let correction = try XCTUnwrap(
            RecentCorrectionDetector.correction(
                from: "Bitte an Nebelstarn senden.",
                to: "Bitte an Nebelstern senden.",
                language: .german,
                secondsSinceInsertion: 4
            )
        )

        XCTAssertEqual(correction.heard, "Nebelstarn")
        XCTAssertEqual(correction.corrected, "Nebelstern")
        XCTAssertEqual(correction.language, .german)
        XCTAssertEqual(correction.secondsSinceInsertion, 4)
    }

    func testRecentCorrectionDetectorReturnsOnlyTheChangedPhraseForSuggestions() throws {
        let correction = try XCTUnwrap(
            RecentCorrectionDetector.correction(
                from: "Bitte an Neural Engin senden.",
                to: "Bitte an Neural Engine senden.",
                language: .english,
                secondsSinceInsertion: 3
            )
        )

        XCTAssertEqual(correction.heard, "Engin")
        XCTAssertEqual(correction.corrected, "Engine")
        XCTAssertFalse(correction.heard.contains("Bitte"))
        XCTAssertFalse(correction.corrected.contains("senden"))
    }

    func testRecentCorrectionDetectorRejectsProtectedAnchorsAndPureInsertions() {
        XCTAssertNil(
            RecentCorrectionDetector.correction(
                from: "Der Termin ist nicht morgen.",
                to: "Der Termin ist morgen.",
                language: .german,
                secondsSinceInsertion: 2
            )
        )
        XCTAssertNil(
            RecentCorrectionDetector.correction(
                from: "Bitte senden.",
                to: "Bitte jetzt senden.",
                language: .german,
                secondsSinceInsertion: 2
            )
        )
        XCTAssertNil(
            RecentCorrectionDetector.correction(
                from: "Version 15 verwenden.",
                to: "Version 16 verwenden.",
                language: .german,
                secondsSinceInsertion: 2
            )
        )
    }

    func testCapitalizationOnlyCorrectionCanBeLearned() async {
        let store = LocalPersonalLexiconStore()
        let result = await store.learn(
            from: PersonalLexiconCorrection(
                heard: "whisperflow",
                corrected: "WhisperFlow",
                language: .english,
                secondsSinceInsertion: 2
            )
        )

        guard case .learned(let entry) = result else {
            return XCTFail("Expected capitalization correction to be learned")
        }
        XCTAssertEqual(entry.canonical, "WhisperFlow")
        XCTAssertEqual(entry.misspellings, ["whisperflow"])
    }

    func testOneWordCorrectionWithinTenSecondsLearnsAutomatically() async {
        let store = LocalPersonalLexiconStore()

        let result = await store.learn(
            from: PersonalLexiconCorrection(
                heard: "Nebelstarn",
                corrected: "Nebelstern",
                language: .german,
                secondsSinceInsertion: 4
            ),
            now: Date(timeIntervalSince1970: 10)
        )

        guard case .learned(let entry) = result else {
            return XCTFail("Expected automatic learning")
        }
        XCTAssertEqual(entry.canonical, "Nebelstern")
        XCTAssertEqual(entry.misspellings, ["Nebelstarn"])
        XCTAssertEqual(entry.language, .german)
        XCTAssertEqual(entry.priority, 1)
        XCTAssertEqual(entry.source, .oneWordCorrection)
    }

    func testLongerCorrectionBecomesSuggestionOnly() async {
        let store = LocalPersonalLexiconStore()

        let result = await store.learn(
            from: PersonalLexiconCorrection(
                heard: "Nebel Stern",
                corrected: "Nebelstern",
                language: .german,
                secondsSinceInsertion: 3
            )
        )

        guard case .suggested(let suggestion) = result else {
            return XCTFail("Expected suggestion for multi-token correction")
        }
        let entries = await store.entries()
        let suggestions = await store.suggestions()
        XCTAssertEqual(suggestion.reason, .multiTokenCorrection)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(suggestions, [suggestion])
    }

    func testExpiredSingleWordCorrectionBecomesSuggestionOnly() async {
        let store = LocalPersonalLexiconStore()

        let result = await store.learn(
            from: PersonalLexiconCorrection(
                heard: "OrbitLedgar",
                corrected: "OrbitLedger",
                language: .english,
                secondsSinceInsertion: 12
            )
        )

        guard case .suggested(let suggestion) = result else {
            return XCTFail("Expected suggestion after learning window")
        }
        let entries = await store.entries()
        XCTAssertEqual(suggestion.reason, .correctionWindowExpired)
        XCTAssertTrue(entries.isEmpty)
    }

    func testAmbiguousMisspellingBecomesSuggestionOnly() async {
        let existing = PersonalLexiconEntry(
            id: UUID(),
            canonical: "Phonix",
            misspellings: ["Foniks"],
            language: .german,
            priority: 1,
            source: .manual,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let store = LocalPersonalLexiconStore(entries: [existing])

        let result = await store.learn(
            from: PersonalLexiconCorrection(
                heard: "Foniks",
                corrected: "Phoenix",
                language: .german,
                secondsSinceInsertion: 2
            )
        )

        guard case .suggested(let suggestion) = result else {
            return XCTFail("Expected ambiguity suggestion")
        }
        let entries = await store.entries()
        XCTAssertEqual(suggestion.reason, .ambiguousMisspelling)
        XCTAssertEqual(entries, [existing])
    }

    func testReplacementRulesPreferHigherPriorityLocalEntry() async {
        let low = PersonalLexiconEntry(
            id: UUID(),
            canonical: "OrbitLedger",
            misspellings: ["OrbitLedgar"],
            language: .english,
            priority: 1,
            source: .manual,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let high = PersonalLexiconEntry(
            id: UUID(),
            canonical: "OrbitLeger",
            misspellings: ["OrbitLedgar"],
            language: .english,
            priority: 4,
            source: .manual,
            createdAt: Date(timeIntervalSince1970: 2),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let store = LocalPersonalLexiconStore(entries: [low, high])

        let rules = await store.replacementRules(for: "OrbitLedgar", language: .english)

        XCTAssertEqual(rules.map(\.canonical), ["OrbitLeger", "OrbitLedger"])
        XCTAssertEqual(rules.map(\.priority), [4, 1])
    }

    func testUndoDeleteAndResetAreRevocable() async {
        let store = LocalPersonalLexiconStore()
        let result = await store.learn(
            from: PersonalLexiconCorrection(
                heard: "Nebelstarn",
                corrected: "Nebelstern",
                language: .german,
                secondsSinceInsertion: 1
            )
        )
        guard case .learned(let entry) = result else {
            return XCTFail("Expected learned entry")
        }

        let didUndoLearn = await store.undoLastChange()
        let entriesAfterUndoLearn = await store.entries()
        XCTAssertTrue(didUndoLearn)
        XCTAssertTrue(entriesAfterUndoLearn.isEmpty)

        _ = await store.learn(
            from: PersonalLexiconCorrection(
                heard: "Nebelstarn",
                corrected: "Nebelstern",
                language: .german,
                secondsSinceInsertion: 1
            )
        )
        let learnedAgain = await store.entries().first
        XCTAssertNotNil(learnedAgain)
        _ = await store.delete(entryID: learnedAgain?.id ?? entry.id)
        let entriesAfterDelete = await store.entries()
        let didUndoDelete = await store.undoLastChange()
        let entriesAfterUndoDelete = await store.entries()
        XCTAssertTrue(entriesAfterDelete.isEmpty)
        XCTAssertTrue(didUndoDelete)
        XCTAssertEqual(entriesAfterUndoDelete.count, 1)

        await store.reset()
        let entriesAfterReset = await store.entries()
        let didUndoReset = await store.undoLastChange()
        let entriesAfterUndoReset = await store.entries()
        XCTAssertTrue(entriesAfterReset.isEmpty)
        XCTAssertTrue(didUndoReset)
        XCTAssertEqual(entriesAfterUndoReset.count, 1)
    }

    func testEntriesAndSuggestionsAreCodableForSettingsPersistence() async throws {
        let store = LocalPersonalLexiconStore()
        let result = await store.learn(
            from: PersonalLexiconCorrection(
                heard: "OrbitLedgar",
                corrected: "OrbitLedger",
                language: .english,
                secondsSinceInsertion: 12
            )
        )
        guard case .suggested(let suggestion) = result else {
            return XCTFail("Expected persisted suggestion")
        }
        let entry = await store.addManualEntry(
            canonical: "Nebelstern",
            misspellings: ["Nebelstarn"],
            language: .german,
            priority: 7,
            now: Date(timeIntervalSince1970: 50)
        )

        let encodedEntry = try JSONEncoder().encode(entry)
        let decodedEntry = try JSONDecoder().decode(PersonalLexiconEntry.self, from: encodedEntry)
        let encodedSuggestion = try JSONEncoder().encode(suggestion)
        let decodedSuggestion = try JSONDecoder().decode(PersonalLexiconSuggestion.self, from: encodedSuggestion)

        XCTAssertEqual(decodedEntry, entry)
        XCTAssertEqual(decodedSuggestion, suggestion)
    }

    func testManualUpdateAndPrioritizeNormalizeWithoutFullText() async {
        let store = LocalPersonalLexiconStore()
        let entry = await store.addManualEntry(
            canonical: " OrbitLedger ",
            misspellings: ["OrbitLedgar.", "orbitledgar", "OrbitLedger"],
            language: .english,
            priority: 2
        )
        XCTAssertEqual(entry?.canonical, "OrbitLedger")
        XCTAssertEqual(entry?.misspellings, ["OrbitLedgar"])

        let updated = await store.updateEntry(
            id: entry?.id ?? UUID(),
            canonical: "OrbitLedger",
            misspellings: ["OrbitLedge"],
            language: .english,
            priority: 3
        )
        let prioritized = await store.prioritize(entryID: entry?.id ?? UUID())
        let entries = await store.entries()

        XCTAssertEqual(updated?.misspellings, ["OrbitLedge"])
        XCTAssertEqual(prioritized?.priority, 4)
        XCTAssertEqual(entries.count, 1)
    }

    func testApplyAndDismissSuggestionDoNotStoreFullText() async {
        let store = LocalPersonalLexiconStore()
        let first = await store.learn(
            from: PersonalLexiconCorrection(
                heard: "Neural Engin",
                corrected: "Neural Engine",
                language: .english,
                secondsSinceInsertion: 2
            )
        )
        let second = await store.learn(
            from: PersonalLexiconCorrection(
                heard: "OrbitLedgar",
                corrected: "OrbitLedger",
                language: .english,
                secondsSinceInsertion: 12
            )
        )
        guard case .suggested(let appliedSuggestion) = first,
              case .suggested(let dismissedSuggestion) = second else {
            return XCTFail("Expected suggestions")
        }

        let applied = await store.applySuggestion(appliedSuggestion.id, priority: 5)
        let dismissed = await store.dismissSuggestion(dismissedSuggestion.id)

        XCTAssertEqual(applied?.canonical, "Neural Engine")
        XCTAssertEqual(applied?.misspellings, ["Neural Engin"])
        XCTAssertEqual(applied?.priority, 5)
        XCTAssertEqual(dismissed, dismissedSuggestion)
        let suggestions = await store.suggestions()
        XCTAssertEqual(suggestions, [])
    }
}
