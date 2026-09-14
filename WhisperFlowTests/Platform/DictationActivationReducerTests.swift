import XCTest
@testable import WhisperFlow

final class DictationActivationReducerTests: XCTestCase {
    func testButtonPromotionIgnoresHeldShortcutReleaseAndAllowsShortcutStop() {
        var reducer = DictationActivationReducer(mode: .disabled)
        XCTAssertEqual(reducer.consume(.pressed, at: 0), .beginPushToTalk)
        reducer.switchToHandsFree()
        XCTAssertEqual(reducer.consume(.released, at: 2), .none)
        XCTAssertTrue(reducer.isHandsFreeActive)
        XCTAssertEqual(reducer.consume(.pressed, at: 3), .endHandsFree)
        XCTAssertEqual(reducer.consume(.released, at: 4), .none)
    }

    func testButtonPromotionClearsPendingDoubleTapAndResetAllowsNextDictation() {
        var reducer = DictationActivationReducer(mode: .doubleTap)
        _ = reducer.consume(.pressed, at: 0)
        _ = reducer.consume(.released, at: 0.1)
        reducer.switchToHandsFree()
        XCTAssertNil(reducer.secondTapDeadline)
        XCTAssertTrue(reducer.isHandsFreeActive)
        reducer.reset()
        XCTAssertEqual(reducer.consume(.released, at: 0.2), .none)
        XCTAssertEqual(reducer.consume(.pressed, at: 1), .beginPushToTalk)
    }

    func testDisabledModePreservesSingleHold() {
        var reducer = DictationActivationReducer(mode: .disabled)
        XCTAssertEqual(reducer.consume(.pressed, at: 0), .beginPushToTalk)
        XCTAssertEqual(reducer.consume(.released, at: 0.1), .endPushToTalk)
    }

    func testDoubleTapStartsHandsFreeAndIgnoresItsRelease() {
        var reducer = DictationActivationReducer(mode: .doubleTap)
        XCTAssertEqual(reducer.consume(.pressed, at: 0), .beginPushToTalk)
        XCTAssertEqual(reducer.consume(.released, at: 0.1), .endPushToTalk)
        XCTAssertNotNil(reducer.secondTapDeadline)
        XCTAssertEqual(reducer.secondTapDeadline!, 0.4, accuracy: 0.000_001)
        XCTAssertTrue(reducer.isAwaitingSecondTap(at: 0.3))
        XCTAssertEqual(reducer.consume(.pressed, at: 0.3), .beginHandsFree)
        XCTAssertNil(reducer.secondTapDeadline)
        XCTAssertEqual(reducer.consume(.released, at: 0.31), .none)
    }

    func testDoubleTapAtExactThresholdStartsHandsFree() {
        var reducer = DictationActivationReducer(mode: .doubleTap)
        XCTAssertEqual(reducer.consume(.pressed, at: 0), .beginPushToTalk)
        XCTAssertEqual(reducer.consume(.released, at: 0.1), .endPushToTalk)

        XCTAssertTrue(reducer.isAwaitingSecondTap(at: 0.4))
        XCTAssertEqual(reducer.consume(.pressed, at: 0.4), .beginHandsFree)
    }

    func testDoubleTapOutsideThresholdRemainsTwoIndependentPTTTaps() {
        var reducer = DictationActivationReducer(mode: .doubleTap)
        XCTAssertEqual(reducer.consume(.pressed, at: 0), .beginPushToTalk)
        XCTAssertEqual(reducer.consume(.released, at: 0.1), .endPushToTalk)
        XCTAssertFalse(reducer.isAwaitingSecondTap(at: 0.400_001))
        XCTAssertEqual(reducer.consume(.pressed, at: 0.400_001), .beginPushToTalk)
        XCTAssertEqual(reducer.consume(.released, at: 0.5), .endPushToTalk)
    }

    func testLongHoldFollowedByQuickPressDoesNotStartHandsFree() {
        var reducer = DictationActivationReducer(mode: .doubleTap)
        XCTAssertEqual(reducer.consume(.pressed, at: 0), .beginPushToTalk)
        XCTAssertEqual(
            reducer.consume(.released, at: DictationActivationReducer.doubleTapThreshold + 0.001),
            .endPushToTalk
        )
        XCTAssertNil(reducer.secondTapDeadline)
        XCTAssertFalse(reducer.isAwaitingSecondTap(at: 0.4))

        XCTAssertEqual(reducer.consume(.pressed, at: 0.4), .beginPushToTalk)
        XCTAssertEqual(reducer.consume(.released, at: 0.45), .endPushToTalk)
    }

    func testFirstTapAtMaximumDurationCanPrimeHandsFree() {
        var reducer = DictationActivationReducer(mode: .doubleTap)
        XCTAssertEqual(reducer.consume(.pressed, at: 0), .beginPushToTalk)
        XCTAssertEqual(
            reducer.consume(.released, at: DictationActivationReducer.doubleTapThreshold),
            .endPushToTalk
        )
        XCTAssertNotNil(reducer.secondTapDeadline)
        XCTAssertEqual(
            reducer.secondTapDeadline!,
            DictationActivationReducer.doubleTapThreshold * 2,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            reducer.consume(.pressed, at: DictationActivationReducer.doubleTapThreshold * 2),
            .beginHandsFree
        )
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
        XCTAssertNotNil(reducer.secondTapDeadline)
        XCTAssertEqual(reducer.secondTapDeadline!, 0.4, accuracy: 0.000_001)
        XCTAssertEqual(reducer.consume(.released, at: 0.11), .none)
        XCTAssertNotNil(reducer.secondTapDeadline)
        XCTAssertEqual(reducer.secondTapDeadline!, 0.4, accuracy: 0.000_001)
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

    func testResetClearsPendingSecondTapDeadline() {
        var reducer = DictationActivationReducer(mode: .doubleTap)
        _ = reducer.consume(.pressed, at: 0)
        _ = reducer.consume(.released, at: 0.05)
        XCTAssertTrue(reducer.isAwaitingSecondTap(at: 0.1))

        reducer.reset()

        XCTAssertNil(reducer.secondTapDeadline)
        XCTAssertFalse(reducer.isAwaitingSecondTap(at: 0.1))
        XCTAssertEqual(reducer.consume(.pressed, at: 0.2), .beginPushToTalk)
    }

    func testResetAfterFailedBeginIgnoresStaleReleaseAndDoesNotPrimeHandsFree() {
        var reducer = DictationActivationReducer(mode: .doubleTap)
        XCTAssertEqual(reducer.consume(.pressed, at: 0), .beginPushToTalk)

        reducer.reset()

        XCTAssertEqual(reducer.consume(.released, at: 0.05), .none)
        XCTAssertNil(reducer.secondTapDeadline)
        XCTAssertEqual(reducer.consume(.pressed, at: 0.1), .beginPushToTalk)
    }

    func testResetCanDisableModeAndClearsPendingSecondTapDeadline() {
        var reducer = DictationActivationReducer(mode: .doubleTap)
        _ = reducer.consume(.pressed, at: 0)
        _ = reducer.consume(.released, at: 0.05)

        reducer.reset(mode: .disabled)

        XCTAssertNil(reducer.secondTapDeadline)
        XCTAssertEqual(reducer.consume(.pressed, at: 0.1), .beginPushToTalk)
        XCTAssertEqual(reducer.consume(.released, at: 0.15), .endPushToTalk)
        XCTAssertNil(reducer.secondTapDeadline)
    }

    func testNonMonotonicPressDoesNotConsumePendingSecondTap() {
        var reducer = DictationActivationReducer(mode: .doubleTap)
        _ = reducer.consume(.pressed, at: 1)
        _ = reducer.consume(.released, at: 1.05)

        XCTAssertFalse(reducer.isAwaitingSecondTap(at: 1.04))
        XCTAssertEqual(reducer.consume(.pressed, at: 1.04), .beginPushToTalk)
    }
}
