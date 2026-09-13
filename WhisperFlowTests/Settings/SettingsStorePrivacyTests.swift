@preconcurrency import Carbon
import Foundation
import XCTest
@testable import WhisperFlow

final class SettingsStorePrivacyTests: XCTestCase, @unchecked Sendable {
    private static let legacyMicrophoneKey = "flusterflow.selected-microphone"

    func testApplicationVersionFormatsSemanticVersionAndBuildNumber() {
        let version = ApplicationVersion(
            marketingVersion: "0.2.0",
            buildNumber: "2"
        )

        XCTAssertEqual(version.compactText, "0.2.0 (2)")
        XCTAssertEqual(version.displayText, "Version 0.2.0 (2)")
    }

    func testApplicationVersionHasReadableDevelopmentFallback() {
        let version = ApplicationVersion(marketingVersion: nil, buildNumber: nil)

        XCTAssertEqual(version.compactText, "Development")
        XCTAssertEqual(version.displayText, "Version Development")
    }

    @MainActor
    func testInitializationScrubsLegacyMicrophoneIdentifier() {
        withIsolatedDefaults { defaults in
            let legacyUID = "legacy-device-uid-456"
            defaults.set(legacyUID, forKey: Self.legacyMicrophoneKey)

            _ = SettingsStore(defaults: defaults)

            XCTAssertNil(defaults.object(forKey: Self.legacyMicrophoneKey))
            XCTAssertFalse(defaults.dictionaryRepresentation().values.contains {
                $0 as? String == legacyUID
            })
        }
    }

    func testDiagnosticsArtifactContainsNoMicrophoneIdentifierSurface() throws {
        let selectedUID = "forbidden-diagnostics-device-uid-789"
        let report = DiagnosticsReport(
            schemaVersion: 1,
            appVersion: "test",
            runtimeName: "local-runtime",
            runtimeVersion: "1",
            microphonePermission: .authorized,
            accessibilityPermission: .authorized,
            modelStatus: "ready",
            stageDurations: []
        )

        let data = try JSONEncoder().encode(report)
        let artifact = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(artifact.contains(selectedUID))
        XCTAssertFalse(artifact.localizedCaseInsensitiveContains("microphoneUID"))
        XCTAssertFalse(artifact.localizedCaseInsensitiveContains("selectedMicrophone"))
        XCTAssertFalse(artifact.contains(Self.legacyMicrophoneKey))
    }

    @MainActor
    func testEveryLocalModelChoicePersistsWithoutChangingCloudConsent() {
        withIsolatedDefaults { defaults in
            let settings = SettingsStore(defaults: defaults)
            settings.cloudEnabled = false
            settings.cloudContextEnabled = false

            for choice in LocalModelChoice.allCases {
                settings.localModel = choice
                let restarted = SettingsStore(defaults: defaults)
                XCTAssertEqual(restarted.localModel, choice)
                XCTAssertEqual(restarted.consentSnapshot(), .localOnly)
            }
        }
    }

    @MainActor
    func testMissingLocalModelDefaultsToAdaptiveWithoutOverwritingExplicitSelection() {
        withIsolatedDefaults { defaults in
            XCTAssertEqual(SettingsStore(defaults: defaults).localModel, .adaptive)

            defaults.set(LocalModelChoice.parakeetV3Int8.rawValue, forKey: "flusterflow.local-model")

            XCTAssertEqual(SettingsStore(defaults: defaults).localModel, .parakeetV3Int8)
        }
    }

    @MainActor
    func testUnknownLocalModelValueFailsSafelyBackToAdaptive() {
        withIsolatedDefaults { defaults in
            defaults.set("future-unknown-model", forKey: "flusterflow.local-model")
            XCTAssertEqual(SettingsStore(defaults: defaults).localModel, .adaptive)
        }
    }

    @MainActor
    func testPushToTalkDefaultsEnabledAndPersistsExplicitDisable() {
        withIsolatedDefaults { defaults in
            let settings = SettingsStore(defaults: defaults)
            XCTAssertTrue(settings.pushToTalkEnabled)

            settings.pushToTalkEnabled = false

            let restarted = SettingsStore(defaults: defaults)
            XCTAssertFalse(restarted.pushToTalkEnabled)
            XCTAssertFalse(restarted.isShortcutCaptureActive)
        }
    }

    @MainActor
    func testHandsFreeDefaultsDisabledAndPersistsExplicitEnable() {
        withIsolatedDefaults { defaults in
            let settings = SettingsStore(defaults: defaults)
            XCTAssertFalse(settings.handsFreeEnabled)

            settings.handsFreeEnabled = true

            XCTAssertTrue(SettingsStore(defaults: defaults).handsFreeEnabled)
        }
    }

    @MainActor
    func testLocalCorrectionLearningDefaultsEnabledAndPersistsExplicitDisable() {
        withIsolatedDefaults { defaults in
            let settings = SettingsStore(defaults: defaults)
            XCTAssertTrue(settings.localLearningEnabled)

            settings.localLearningEnabled = false

            let restarted = SettingsStore(defaults: defaults)
            XCTAssertFalse(restarted.localLearningEnabled)
        }
    }

    @MainActor
    func testCustomPushToTalkShortcutPersistsValidatedKeyAndModifiers() throws {
        try withIsolatedDefaults { defaults in
            let settings = SettingsStore(defaults: defaults)
            let shortcut = try XCTUnwrap(
                PushToTalkShortcut(
                    keyCode: UInt32(kVK_ANSI_K),
                    carbonModifiers: UInt32(controlKey | shiftKey),
                    keyLabel: "K"
                )
            )

            settings.shortcut = shortcut

            let restarted = SettingsStore(defaults: defaults)
            XCTAssertEqual(restarted.shortcut, shortcut)
            XCTAssertEqual(restarted.shortcut.title, "⌃⇧K")
        }
    }

    @MainActor
    func testLegacyShortcutValueMigratesWithoutChangingTheDefaultBinding() {
        withIsolatedDefaults { defaults in
            defaults.set("optionShiftSpace", forKey: "flusterflow.shortcut")

            let settings = SettingsStore(defaults: defaults)

            XCTAssertEqual(settings.shortcut, .optionShiftSpace)
            XCTAssertEqual(settings.shortcut.title, "⌥⇧Leertaste")
        }
    }

    @MainActor
    private func withIsolatedDefaults(
        _ operation: (UserDefaults) throws -> Void
    ) rethrows {
        let suiteName = "SettingsStorePrivacyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try operation(defaults)
    }
}
