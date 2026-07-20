import XCTest
@testable import WhisperFlow

final class ContextualTermCorrectorTests: XCTestCase {
    func testUniqueSplitAndCaseVariantIsCorrected() {
        let corrector = ContextualTermCorrector()
        XCTAssertEqual(
            corrector.correct("The orbit ledger is ready.", terms: ["OrbitLedger"]),
            "The OrbitLedger is ready."
        )
    }

    func testNearbyContextTermsLeaveAmbiguousTranscriptUnchanged() {
        let corrector = ContextualTermCorrector()
        XCTAssertEqual(
            corrector.correct("Bitte öffne Nebelstarn.", terms: ["Nebelstern", "Nebelstirn"]),
            "Bitte öffne Nebelstarn."
        )
    }

    func testUniqueMultiwordEditAndPhoneticMatchesAreCorrected() {
        let corrector = ContextualTermCorrector()
        XCTAssertEqual(
            corrector.correct("Open Neural Engin.", terms: ["Neural Engine"]),
            "Open Neural Engine."
        )
        XCTAssertEqual(
            corrector.correct("Starte Foniks.", terms: ["Phonix"]),
            "Starte Phonix."
        )
    }

    func testPhoneticAmbiguityAndAdjacentCommonWordsRemainUnchanged() {
        let corrector = ContextualTermCorrector()
        XCTAssertEqual(
            corrector.correct("Starte Foniks.", terms: ["Phonix", "Fonix"]),
            "Starte Foniks."
        )
        XCTAssertEqual(
            corrector.correct("Please send to AmberMesh.", terms: ["AmberMesh"]),
            "Please send to AmberMesh."
        )
    }
}
