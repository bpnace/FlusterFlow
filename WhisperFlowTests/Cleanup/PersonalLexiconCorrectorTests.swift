import Foundation
import XCTest
@testable import WhisperFlow

final class PersonalLexiconCorrectorTests: XCTestCase {
    func testCorrectsKnownMisspellingsAndRespectsLanguage() {
        let entries = [
            entry(
                canonical: "FlusterFlow",
                misspellings: ["Flüster Flo"],
                language: .german
            )
        ]

        XCTAssertEqual(
            PersonalLexiconCorrector().correct(
                "Bitte starte Flüster Flo jetzt.",
                entries: entries,
                language: .german
            ),
            "Bitte starte FlusterFlow jetzt."
        )
        XCTAssertEqual(
            PersonalLexiconCorrector().correct(
                "Flüster Flo",
                entries: entries,
                language: .english
            ),
            "Flüster Flo"
        )
    }

    func testNeverMutatesProtectedURLMailOrCodeAnchors() {
        let entries = [
            entry(
                canonical: "PROJECT-ORBIT",
                misspellings: ["projectorbit"],
                language: .automatic
            )
        ]
        let source = "projectorbit https://example.invalid name@example.invalid `projectorbit` project_orbit_value"

        XCTAssertEqual(
            PersonalLexiconCorrector().correct(
                source,
                entries: entries,
                language: .german
            ),
            "PROJECT-ORBIT https://example.invalid name@example.invalid `projectorbit` project_orbit_value"
        )
    }

    private func entry(
        canonical: String,
        misspellings: [String],
        language: DictationLanguage
    ) -> PersonalLexiconEntry {
        PersonalLexiconEntry(
            id: UUID(),
            canonical: canonical,
            misspellings: misspellings,
            language: language,
            priority: 10,
            source: .manual,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }
}
