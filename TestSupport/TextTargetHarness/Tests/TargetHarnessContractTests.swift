@preconcurrency import AppKit
import Foundation
import XCTest
@testable import TextTargetHarnessCore

final class TargetHarnessContractTests: XCTestCase {
    func testScenarioContractIsExecutableAndUnique() throws {
        let url = try scenarioResourceURL()
        let contract = try TargetHarnessContractLoader.load(from: url)

        XCTAssertEqual(contract.schemaVersion, 1)
        XCTAssertEqual(contract.harnessId, "E-TARGET-HARNESS")
        XCTAssertEqual(contract.scenarios.count, 28)
        XCTAssertEqual(Set(contract.scenarios.map(\.id)).count, 28)
    }

    func testConfirmedMutationUsesUTF16SelectionAndCaretContract() {
        XCTAssertTrue(
            ConfirmedTextMutation.confirms(
                original: "Grüße ",
                originalSelection: HarnessSelection(location: 6, length: 0),
                replacement: "aus Köln",
                currentText: "Grüße aus Köln",
                currentSelection: HarnessSelection(location: 14, length: 0)
            )
        )
        XCTAssertFalse(
            ConfirmedTextMutation.confirms(
                original: "Alpha Gamma",
                originalSelection: HarnessSelection(location: 6, length: 0),
                replacement: "Beta ",
                currentText: "Alpha Beta Gamma",
                currentSelection: HarnessSelection(location: 6, length: 0)
            )
        )
    }

    func testFocusChangeIsRejectedBeforeMutation() {
        let captured = state(target: "field-a", selection: .init(location: 3, length: 0))
        let current = state(target: "field-b", selection: .init(location: 3, length: 0))

        XCTAssertEqual(
            TargetMutationPolicy().decision(
                captured: captured,
                current: current,
                activeSessionIdentifier: "current"
            ),
            .reject(reason: .focusFingerprintMismatch)
        )
    }

    func testRangeChangeIsRejectedBeforeMutation() {
        let captured = state(target: "field-a", selection: .init(location: 3, length: 0))
        let current = state(target: "field-a", selection: .init(location: 4, length: 0))

        XCTAssertEqual(
            TargetMutationPolicy().decision(
                captured: captured,
                current: current,
                activeSessionIdentifier: "current"
            ),
            .reject(reason: .selectionFingerprintMismatch)
        )
    }

    func testProtectedTargetIsRejectedBeforeCapabilityChoice() {
        let protected = state(
            target: "secure",
            selection: .init(location: 0, length: 0),
            protected: true,
            selectedText: true,
            unicode: true
        )

        XCTAssertEqual(
            TargetMutationPolicy().decision(
                captured: protected,
                current: protected,
                activeSessionIdentifier: "current"
            ),
            .reject(reason: .secureField)
        )
    }

    func testUnicodeFallbackRequiresAllowlistAndNeverNeedsPasteboard() {
        let baseline = state(
            target: "unicode",
            selection: .init(location: 6, length: 0),
            selectedText: false,
            unicode: true
        )
        XCTAssertEqual(
            TargetMutationPolicy().decision(
                captured: baseline,
                current: baseline,
                activeSessionIdentifier: "current"
            ),
            .guardedUnicode
        )

        let denied = state(
            target: "unknown",
            selection: .init(location: 6, length: 0),
            selectedText: false,
            unicode: false
        )
        XCTAssertEqual(
            TargetMutationPolicy().decision(
                captured: denied,
                current: denied,
                activeSessionIdentifier: "current"
            ),
            .reject(reason: .noConfirmableMutationPath)
        )
    }

    @MainActor
    func testRealNSTextViewMutationConfirmsWithoutGeneralPasteboardWrite() {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        view.string = "Alpha Gamma"
        view.setSelectedRange(NSRange(location: 6, length: 0))
        let before = NSPasteboard.general.changeCount

        view.insertText("Beta ", replacementRange: view.selectedRange())

        let confirmed = ConfirmedTextMutation.confirms(
            original: "Alpha Gamma",
            originalSelection: HarnessSelection(location: 6, length: 0),
            replacement: "Beta ",
            currentText: view.string,
            currentSelection: HarnessSelection(
                location: view.selectedRange().location,
                length: view.selectedRange().length
            )
        )
        XCTAssertTrue(confirmed)
        XCTAssertEqual(NSPasteboard.general.changeCount, before)
    }

    func testPasteboardPolicyRequiresExplicitUserAction() {
        let policy = ExplicitCopyPolicy()
        XCTAssertFalse(policy.shouldWriteGeneralPasteboard(explicitUserAction: false))
        XCTAssertTrue(policy.shouldWriteGeneralPasteboard(explicitUserAction: true))
    }

    private func state(
        target: String,
        selection: HarnessSelection,
        protected: Bool = false,
        selectedText: Bool = true,
        unicode: Bool = false
    ) -> HarnessTargetState {
        HarnessTargetState(
            processIdentifier: 42,
            targetIdentifier: target,
            sessionIdentifier: "current",
            selection: selection,
            isFocused: true,
            isProtected: protected,
            supportsSelectedText: selectedText,
            supportsUnicodeFallback: unicode
        )
    }

    private func scenarioResourceURL() throws -> URL {
        guard let url = Bundle.module.url(forResource: "scenarios", withExtension: "json") else {
            throw HarnessResourceError.missingScenarios
        }
        return url
    }
}

private enum HarnessResourceError: Error {
    case missingScenarios
}
