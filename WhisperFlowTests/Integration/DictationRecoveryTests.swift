import XCTest
@testable import WhisperFlow

@MainActor
final class DictationRecoveryTests: XCTestCase {
    func testInsertionFailureRetainsCorrectedTextAcrossNextSession() async {
        let store = EphemeralResultStore()
        let model = DictationRecoveryModel()
        let first = DictationSessionID(rawValue: 1)
        let second = DictationSessionID(rawValue: 2)
        await store.preserveRawTranscript("raw", for: first)
        await store.preserveCandidate("Korrigierter Text.", for: first)
        await model.handle(.failed(first, DictationFailure(stage: .insertion)), store: store)
        await store.preserveRawTranscript("next", for: second)
        await model.handle(.completed(second, .safeFallback), store: store)
        XCTAssertEqual(model.results.map(\.text), ["Korrigierter Text.", "next"])
        await model.dismiss(first, store: store)
        XCTAssertEqual(model.results.map(\.text), ["next"])
    }

    func testSuccessfulInsertionDoesNotPresentRecovery() async {
        let model = DictationRecoveryModel()
        let shouldPresent = await model.handle(.completed(DictationSessionID(rawValue: 1), .confirmedDirect), store: EphemeralResultStore())
        XCTAssertFalse(shouldPresent)
        XCTAssertFalse(model.needsAttention)
    }

    func testPreviousRecoveryDoesNotInterruptTheNextSuccessfulDictation() async {
        let model = DictationRecoveryModel()
        let store = EphemeralResultStore()
        let first = DictationSessionID(rawValue: 1)
        await store.preserveRawTranscript("Text", for: first)
        await model.handle(.completed(first, .safeFallback), store: store)
        let second = DictationSessionID(rawValue: 2)
        for outcome in [StopOutcome.completed(second, .confirmedDirect), .noSpeech(second), .ignoredStale(second)] {
            let shouldPresent = await model.handle(outcome, store: store)
            XCTAssertFalse(shouldPresent)
        }
        XCTAssertEqual(model.results.first?.text, "Text")
    }

    func testHistoryWarningDoesNotBecomeRecognitionFailure() async {
        let model = DictationRecoveryModel()
        model.reportHistoryFailure()
        await model.handle(.completed(DictationSessionID(rawValue: 1), .confirmedDirect), store: EphemeralResultStore())
        XCTAssertNotNil(model.historyWarning)
        XCTAssertNil(model.errorMessage)
    }

    func testFailuresExplainStageAndRecognitionTimeout() {
        XCTAssertEqual(DictationFailure(stage: .insertion).title, "Einfügen fehlgeschlagen")
        XCTAssertEqual(DictationFailure(stage: .recognition, reason: .recognitionTimedOut).title, "Spracherkennung dauert zu lange")
        XCTAssertNotEqual(DictationFailure(stage: .audioFinalize).title, DictationFailure(stage: .recognition).title)
    }
}
