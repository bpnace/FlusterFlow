import AppKit
import SwiftUI
import XCTest
@testable import WhisperFlow

@MainActor
final class AppWindowNavigationTests: XCTestCase {
    private var readyCapability: DictationCapabilityStatus {
        DictationCapabilityStatus(
            microphone: .authorized,
            accessibility: .authorized,
            model: .ready(
                LocalModelReadiness(
                    manifestIdentifier: "test-model",
                    modelRevision: "test-revision",
                    byteCount: 1,
                    treeSHA256: ModelSHA256(String(repeating: "0", count: 64))!
                )
            )
        )
    }

    func testNavigationStartsAtOverview() {
        let navigation = AppNavigationModel()

        XCTAssertEqual(navigation.selection, .overview)
    }

    func testSelectRoutesDirectlyToRecordings() {
        let navigation = AppNavigationModel()

        navigation.select(.recordings)

        XCTAssertEqual(navigation.selection, .recordings)
    }

    func testSidebarTagsUseDestinationTypeExpectedByOptionalSelectionBinding() throws {
        let source = try TestResourceLoader.string(
            "WhisperFlow/Features/AppShell/AppWindowController.swift"
        )

        XCTAssertTrue(source.contains(".tag(AppDestination.overview)"))
        XCTAssertTrue(source.contains(".tag(AppDestination.recordings)"))
        XCTAssertTrue(source.contains(".tag(destination)"))
        XCTAssertFalse(source.contains(".tag(Optional("))
    }

    func testSelectRoutesDirectlyToEverySettingsSubpage() {
        let navigation = AppNavigationModel()
        let settingsDestinations: [AppDestination] = [
            .dictation,
            .models,
            .lexicon,
            .privacy,
            .cloud,
            .permissions,
            .general,
        ]

        for destination in settingsDestinations {
            navigation.select(destination)
            XCTAssertEqual(navigation.selection, destination)
        }
    }

    func testSelectSettingsDefaultsToDictationBeforeASettingsPageWasSelected() {
        let navigation = AppNavigationModel()

        navigation.selectSettings()

        XCTAssertEqual(navigation.selection, .dictation)
    }

    func testSelectSettingsRestoresTheMostRecentlySelectedSettingsPage() {
        let navigation = AppNavigationModel()
        navigation.select(.privacy)
        navigation.select(.recordings)

        navigation.selectSettings()

        XCTAssertEqual(navigation.selection, .privacy)
    }

    func testRecordingsMenuUsesCommandTwoInsteadOfStandardCommandHShortcut() throws {
        let menu = AppDelegate().makeMenu()
        let recordingsItem = try XCTUnwrap(
            menu.items.first { $0.title == "Aufnahmen" }
        )

        XCTAssertEqual(recordingsItem.keyEquivalent, "2")
        XCTAssertEqual(recordingsItem.keyEquivalentModifierMask, [.command])
    }

    func testHandsFreeCanBeStartedFromMenuWithoutGlobalShortcut() throws {
        let delegate = AppDelegate()
        let menu = delegate.makeMenu()
        let item = try XCTUnwrap(menu.items.first { $0.title == "Handsfree-Diktat starten" })
        XCTAssertTrue(item.target === delegate)
        XCTAssertNotNil(item.action)
        XCTAssertEqual(item.keyEquivalent, "")
    }

    func testFlowBarPanelCannotBecomeKeyOrMain() {
        let flowBar = FlowBarController()

        XCTAssertTrue(flowBar.preservesFocus)
    }

    func testOperationalReadinessRequiresEnabledPushToTalk() {
        let status = DictationOperationalStatus(
            capability: readyCapability,
            pushToTalkEnabled: false,
            pushToTalkRegistrationStatus: .disabled
        )

        XCTAssertFalse(status.canStartDictation)
        XCTAssertEqual(status.statusTitle(shortcut: "⌃⌥Space"), "Push-to-talk deaktiviert")
    }

    func testOperationalReadinessRequiresRegisteredGlobalShortcut() {
        let status = DictationOperationalStatus(
            capability: readyCapability,
            pushToTalkEnabled: true,
            pushToTalkRegistrationStatus: .failed(nil)
        )

        XCTAssertFalse(status.canStartDictation)
        XCTAssertEqual(
            status.statusTitle(shortcut: "⌃⌥Space"),
            "Globaler Shortcut konnte nicht registriert werden"
        )
    }

    func testOperationalReadinessAcceptsFullyConfiguredLocalDictation() {
        let status = DictationOperationalStatus(
            capability: readyCapability,
            pushToTalkEnabled: true,
            pushToTalkRegistrationStatus: .registered
        )

        XCTAssertTrue(status.canStartDictation)
        XCTAssertEqual(status.statusTitle(shortcut: "⌃⌥Space"), "Bereit · ⌃⌥Space halten")
    }

    func testOverviewPrivacyCopyReflectsCloudStateWithoutClaimingAudioUpload() {
        XCTAssertTrue(AppOverviewPrivacyCopy.localHistory(cloudEnabled: false).contains("Cloud aus"))
        let cloudCopy = AppOverviewPrivacyCopy.localHistory(cloudEnabled: true)
        XCTAssertTrue(cloudCopy.contains("Cloud-Überarbeitung aktiv"))
        XCTAssertTrue(cloudCopy.contains("Audio bleibt lokal"))
    }

    func testHistoryPresentationNavigatesImmediatelyAndOnlyRefreshesAfterRecovery() throws {
        let source = try TestResourceLoader.string("WhisperFlow/App/AppEnvironment.swift")
        let historyFunction = try function(
            named: "presentRecordingHistory",
            in: source,
            endingAt: "func presentOnboardingIfNeeded"
        )
        let presentRange = try XCTUnwrap(historyFunction.range(of: "appWindow.present(.recordings)"))
        let awaitRange = try XCTUnwrap(historyFunction.range(of: "await recordingHistoryRecoveryTask.value"))
        let afterAwait = historyFunction[awaitRange.upperBound...]

        XCTAssertLessThan(presentRange.lowerBound, awaitRange.lowerBound)
        XCTAssertTrue(historyFunction.contains("recordingHistoryPresentationTask?.cancel()"))
        XCTAssertTrue(historyFunction.contains("guard !Task.isCancelled else { return }"))
        XCTAssertTrue(afterAwait.contains("appWindow.refreshRecordingsIfSelected()"))
        XCTAssertFalse(afterAwait.contains("appWindow.present(.recordings)"))
    }

    func testRepeatedRecordingSelectionAlwaysRequestsFreshHistory() {
        let navigation = AppNavigationModel()
        var reloadCount = 0
        navigation.setRecordingsSelectionHandler { reloadCount += 1 }

        navigation.select(.recordings)
        navigation.select(.recordings)

        XCTAssertEqual(reloadCount, 2)
    }

    func testDeferredHistoryRefreshDoesNotOverrideNewerSidebarSelection() {
        let navigation = AppNavigationModel()
        var reloadCount = 0
        navigation.setRecordingsSelectionHandler { reloadCount += 1 }

        navigation.select(.recordings)
        navigation.select(.privacy)
        navigation.refreshSelectedDestination()

        XCTAssertEqual(navigation.selection, .privacy)
        XCTAssertEqual(reloadCount, 1)
    }

    func testAppWindowReusesTheSamePrimaryWindowForEveryDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = RecordingHistoryViewModel(
            store: RecordingHistoryStore(rootURL: root),
            audioSamples: AudioBufferStore(),
            recognizer: SessionModelSpeechRecognizer(recognizers: [:]),
            modelReadiness: RecordingHistoryModelReadinessProvider { _ in false }
        )
        let controller = AppWindowController(
            overview: AnyView(EmptyView()),
            recordingHistoryViewModel: history,
            settingsView: { _ in AnyView(EmptyView()) }
        )
        defer { controller.close() }
        let originalWindow = try XCTUnwrap(controller.window)

        controller.present(.overview)
        controller.present(.recordings)
        controller.presentSettings()

        XCTAssertIdentical(controller.window, originalWindow)
    }

    private func function(
        named name: String,
        in source: String,
        endingAt nextName: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: "func \(name)"))
        let end = try XCTUnwrap(
            source.range(of: nextName, range: start.upperBound..<source.endIndex)
        )
        return String(source[start.lowerBound..<end.lowerBound])
    }
}
