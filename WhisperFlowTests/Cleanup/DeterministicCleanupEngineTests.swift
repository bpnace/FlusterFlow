import Foundation
import XCTest
@testable import WhisperFlow

final class DeterministicCleanupEngineTests: XCTestCase {
    func testGermanGoldenCorpus() throws {
        try assertCorpus(named: "wf-clean-1-de.json", language: .german)
    }

    func testEnglishGoldenCorpus() throws {
        try assertCorpus(named: "wf-clean-1-en.json", language: .english)
    }

    func testAlreadyNFCInputDoesNotReportUnicodeNormalization() {
        let input = "the fa\u{00E7}ade remains visible"

        let result = DeterministicCleanupEngine().clean(input, language: .english)

        XCTAssertEqual(result.text, "The fa\u{00E7}ade remains visible.")
        XCTAssertFalse(result.appliedRules.contains("unicode.nfc"))
    }

    func testDecomposedUnicodeReportsUnicodeNormalization() {
        let input = "the fac\u{0327}ade remains visible"

        let result = DeterministicCleanupEngine().clean(input, language: .english)

        XCTAssertEqual(result.text, "The fa\u{00E7}ade remains visible.")
        XCTAssertTrue(result.appliedRules.contains("unicode.nfc"))
    }

    func testShortGermanExplicitCorrectionReplacesTheOriginalToken() {
        let result = DeterministicCleanupEngine().clean(
            "rot NEIN ICH MEINE blau",
            language: .german
        )

        XCTAssertEqual(result.text, "Blau.")
        XCTAssertTrue(result.appliedRules.contains("correction.explicit"))
    }

    func testShortEnglishExplicitCorrectionReplacesTheOriginalToken() {
        let result = DeterministicCleanupEngine().clean(
            "red NO I MEAN blue",
            language: .english
        )

        XCTAssertEqual(result.text, "Blue.")
        XCTAssertTrue(result.appliedRules.contains("correction.explicit"))
    }

    func testAmbiguousExplicitCorrectionPreservesTheOriginalText() {
        let input = "please send the report NO I MEAN tomorrow"

        let result = DeterministicCleanupEngine().clean(input, language: .english)

        XCTAssertEqual(result.text, "Please send the report NO I MEAN tomorrow.")
        XCTAssertFalse(result.appliedRules.contains("correction.explicit"))
    }

    func testExplicitCorrectionHandlesLengthChangingUnicodeCaseMappingBeforeMarker() {
        let result = DeterministicCleanupEngine().clean(
            "İstanbul on Monday NO I MEAN on Tuesday",
            language: .english
        )

        XCTAssertEqual(result.text, "İstanbul on Tuesday.")
        XCTAssertTrue(result.appliedRules.contains("correction.explicit"))
    }

    func testClearFillersAreRemovedBeyondInitialPosition() {
        let result = DeterministicCleanupEngine().clean(
            "please uh send um the report",
            language: .english
        )

        XCTAssertEqual(result.text, "Please send the report.")
        XCTAssertTrue(result.appliedRules.contains("filler.remove.safe"))
    }

    func testGermanAmbiguousFillersOnlyUseSafePunctuatedPattern() {
        let unsafe = DeterministicCleanupEngine().clean(
            "das ist quasi fertig",
            language: .german
        )
        let safe = DeterministicCleanupEngine().clean(
            "also, wir starten",
            language: .german
        )

        XCTAssertEqual(unsafe.text, "Das ist quasi fertig.")
        XCTAssertFalse(unsafe.appliedRules.contains("filler.remove.safe"))
        XCTAssertEqual(safe.text, "Wir starten.")
        XCTAssertTrue(safe.appliedRules.contains("filler.remove.safe"))
    }

    func testExplicitCorrectionMarkerVariantsCrossLineSegments() {
        let english = DeterministicCleanupEngine().clean(
            "we meet on Monday\nactually, no I mean on Tuesday",
            language: .english
        )
        let german = DeterministicCleanupEngine().clean(
            "wir treffen uns am Montag\nbesser gesagt am Dienstag",
            language: .german
        )

        XCTAssertEqual(english.text, "We meet on Tuesday.")
        XCTAssertEqual(german.text, "Wir treffen uns am Dienstag.")
        XCTAssertTrue(english.appliedRules.contains("correction.explicit"))
        XCTAssertTrue(german.appliedRules.contains("correction.explicit"))
    }

    func testExplicitCorrectionDoesNotDropProtectedAnchors() {
        let result = DeterministicCleanupEngine().clean(
            "https://example.com no I mean later",
            language: .english
        )

        XCTAssertEqual(result.text, "Https://example.com no I mean later.")
        XCTAssertFalse(result.appliedRules.contains("correction.explicit"))
    }

    func testAdditionalAnchorClassesAreReportedWhenPreserved() {
        let result = DeterministicCleanupEngine().clean(
            "email Lena Fischer on August 18, 2026 \"ready\"",
            language: .english
        )

        XCTAssertTrue(result.appliedRules.contains("anchor.preserve.date"))
        XCTAssertTrue(result.appliedRules.contains("anchor.preserve.propername"))
        XCTAssertTrue(result.appliedRules.contains("anchor.preserve.quote"))
    }

    func testCollapsesDirectRepeatedMultiWordFalseStart() {
        let result = DeterministicCleanupEngine().clean(
            "normal und wenn wir wenn wir es normal testen",
            language: .german
        )

        XCTAssertEqual(result.text, "Normal und wenn wir es normal testen.")
        XCTAssertTrue(result.appliedRules.contains("repetition.collapse.exact"))
    }

    func testCollapsesSafeBacktrackingWithoutDroppingFillers() {
        let result = DeterministicCleanupEngine().clean(
            "ähm wir testen wir testen das normal",
            language: .german
        )

        XCTAssertEqual(result.text, "Wir testen das normal.")
        XCTAssertTrue(result.appliedRules.contains("filler.remove.safe"))
        XCTAssertTrue(result.appliedRules.contains("repetition.collapse.exact"))
    }

    func testRepeatedProtectedNumbersNamesAndNegationsArePreserved() {
        let engine = DeterministicCleanupEngine()

        let number = engine.clean("wir brauchen 17 module 17 module", language: .german)
        let name = engine.clean("Lena Fischer Lena Fischer bleibt sichtbar", language: .english)
        let negation = engine.clean("bitte nicht nur nicht nur lokal", language: .german)
        let url = engine.clean(
            "öffne https://example.com https://example.com",
            language: .german
        )

        XCTAssertEqual(number.text, "Wir brauchen 17 Module 17 Module.")
        XCTAssertFalse(number.appliedRules.contains("repetition.collapse.exact"))
        XCTAssertEqual(name.text, "Lena Fischer Lena Fischer bleibt sichtbar.")
        XCTAssertFalse(name.appliedRules.contains("repetition.collapse.exact"))
        XCTAssertEqual(negation.text, "Bitte nicht nur nicht nur lokal.")
        XCTAssertFalse(negation.appliedRules.contains("repetition.collapse.exact"))
        XCTAssertEqual(url.text, "Öffne https://example.com https://example.com.")
        XCTAssertFalse(url.appliedRules.contains("repetition.collapse.exact"))
    }

    func testFixtureTargetKindsMapWithoutCollapsingChatOrUnknown() throws {
        XCTAssertEqual(try targetKind(from: "email"), .email)
        XCTAssertEqual(try targetKind(from: "chat"), .chat)
        XCTAssertEqual(try targetKind(from: "document"), .document)
        XCTAssertEqual(try targetKind(from: "unknown"), .unknown)
        XCTAssertThrowsError(try targetKind(from: "spreadsheet"))
    }

    private func assertCorpus(named name: String, language: DictationLanguage) throws {
        let corpus: CleanupCorpus = try decodeFixture("Cleanup/\(name)")
        let engine = DeterministicCleanupEngine()
        for fixture in corpus.fixtures {
            let targetKind = try targetKind(from: fixture.targetKind)
            XCTAssertEqual(
                fixture.context.contextAvailable,
                !fixture.context.nearbyText.isEmpty,
                "invalid context contract: \(fixture.id)"
            )
            XCTAssertFalse(fixture.ruleTrace.isEmpty, "missing trace: \(fixture.id)")
            XCTAssertTrue(
                fixture.ruleTrace.allSatisfy(isContentFreeRuleCode),
                "content-bearing rule trace: \(fixture.id)"
            )

            let result = engine.clean(fixture.raw, language: language, targetKind: targetKind)
            XCTAssertEqual(result.text, fixture.expected, fixture.id)
            XCTAssertEqual(result.appliedRules, fixture.ruleTrace, "rule trace: \(fixture.id)")
            for span in fixture.mustPreserveSpans {
                XCTAssertTrue(
                    result.text.contains(span),
                    "missing must-preserve span '\(span)': \(fixture.id)"
                )
            }
            XCTAssertEqual(
                engine.clean(result.text, language: language, targetKind: targetKind).text,
                fixture.expected,
                "idempotence: \(fixture.id)"
            )
        }
    }

    private func targetKind(from rawValue: String) throws -> TargetKind {
        switch rawValue {
        case "email": .email
        case "chat": .chat
        case "document": .document
        case "unknown": .unknown
        default: throw FixtureContractError.unsupportedTargetKind(rawValue)
        }
    }

    private func isContentFreeRuleCode(_ code: String) -> Bool {
        code.range(
            of: #"^[a-z]+(?:\.[a-z]+)+$"#,
            options: .regularExpression
        ) != nil
    }
}

private struct CleanupCorpus: Decodable {
    let fixtures: [CleanupFixture]
}

private struct CleanupFixture: Decodable {
    struct Context: Decodable {
        let nearbyText: String
        let contextAvailable: Bool
    }

    let id: String
    let targetKind: String
    let raw: String
    let context: Context
    let expected: String
    let mustPreserveSpans: [String]
    let ruleTrace: [String]
}

private enum FixtureContractError: Error {
    case unsupportedTargetKind(String)
}

private func decodeFixture<T: Decodable>(_ path: String) throws -> T {
    let data = try TestResourceLoader.data("Fixtures/\(path)")
    return try JSONDecoder().decode(T.self, from: data)
}
