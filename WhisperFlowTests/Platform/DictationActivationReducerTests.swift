import XCTest
@testable import WhisperFlow

final class DictationActivationReducerTests: XCTestCase {
    func testDisabledModePreservesSingleHold() {
        var reducer = DictationActivationReducer(mode: .disabled)
        XCTAssertEqual(reducer.consume(.pressed, at: 0), .beginPushToTalk)
        XCTAssertEqual(reducer.consume(.released, at: 0.1), .endPushToTalk)
    }

    func testDoubleTapStartsHandsFreeAndIgnoresItsRelease() {
        var reducer = DictationActivationReducer(mode: .doubleTap)
        XCTAssertEqual(reducer.consume(.pressed, at: 0), .beginPushToTalk)
        XCTAssertEqual(reducer.consume(.released, at: 0.1), .endPushToTalk)
        XCTAssertEqual(reducer.consume(.pressed, at: 0.3), .beginHandsFree)
        XCTAssertEqual(reducer.consume(.released, at: 0.31), .none)
    }

    func testDoubleTapOutsideThresholdRemainsTwoIndependentPTTTaps() {
        var reducer = DictationActivationReducer(mode: .doubleTap)
        XCTAssertEqual(reducer.consume(.pressed, at: 0), .beginPushToTalk)
        XCTAssertEqual(reducer.consume(.released, at: 0.1), .endPushToTalk)
        XCTAssertEqual(reducer.consume(.pressed, at: 0.400_001), .beginPushToTalk)
        XCTAssertEqual(reducer.consume(.released, at: 0.5), .endPushToTalk)
    }

    func testHandsFreeNextPressEndsAndReleaseIsIgnored() {
        var reducer = DictationActivationReducer(mode: .doubleTap)
        _ = reducer.consume(.pressed, at: 0)
        _ = reducer.consume(.released, at: 0.1)
        XCTAssertEqual(reducer.consume(.pressed, at: 0.2), .beginHandsFree)
        XCTAssertEqual(reducer.consume(.released, at: 0.21), .none)
        XCTAssertEqual(reducer.consume(.pressed, at: 4), .endHandsFree)
        XCTAssertEqual(reducer.consume(.released, at: 4.01), .none)
    }

    func testDuplicateRawEdgesAreIdempotent() {
        var reducer = DictationActivationReducer(mode: .doubleTap)
        XCTAssertEqual(reducer.consume(.pressed, at: 0), .beginPushToTalk)
        XCTAssertEqual(reducer.consume(.pressed, at: 0.01), .none)
        XCTAssertEqual(reducer.consume(.released, at: 0.1), .endPushToTalk)
        XCTAssertEqual(reducer.consume(.released, at: 0.11), .none)
    }

    func testTripleTapDoesNotCreateAnotherStart() {
        var reducer = DictationActivationReducer(mode: .doubleTap)
        _ = reducer.consume(.pressed, at: 0)
        _ = reducer.consume(.released, at: 0.05)
        XCTAssertEqual(reducer.consume(.pressed, at: 0.2), .beginHandsFree)
        XCTAssertEqual(reducer.consume(.released, at: 0.21), .none)
        XCTAssertEqual(reducer.consume(.pressed, at: 0.25), .endHandsFree)
        XCTAssertEqual(reducer.consume(.pressed, at: 0.26), .none)
        XCTAssertEqual(reducer.consume(.released, at: 0.27), .none)
    }

    func testPendingPrimingStopIsRepresentedByEndAction() {
        var reducer = DictationActivationReducer(mode: .doubleTap)
        XCTAssertEqual(reducer.consume(.pressed, at: 0), .beginPushToTalk)
        XCTAssertEqual(reducer.consume(.released, at: 0.05), .endPushToTalk)
    }

    func testTerminalResetDoesNotSwallowNextPressAfterHandsFree() {
        var reducer = DictationActivationReducer(mode: .doubleTap)
        _ = reducer.consume(.pressed, at: 0)
        _ = reducer.consume(.released, at: 0.05)
        XCTAssertEqual(reducer.consume(.pressed, at: 0.2), .beginHandsFree)

        reducer.reset()

        XCTAssertEqual(reducer.consume(.pressed, at: 120.5), .beginPushToTalk)
    }
}
