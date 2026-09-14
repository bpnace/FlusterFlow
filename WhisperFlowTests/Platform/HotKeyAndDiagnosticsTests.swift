@preconcurrency import Carbon
import AppKit
import AVFoundation
import Foundation
import SwiftUI
import XCTest
@testable import WhisperFlow

final class HotKeyAndDiagnosticsTests: XCTestCase, @unchecked Sendable {
    func testShortcutCaptureBuildsAValidatedCarbonConfiguration() throws {
        let shortcut = try XCTUnwrap(
            ShortcutCaptureInput(
                keyCode: UInt16(kVK_ANSI_K),
                modifierFlags: [.control, .option],
                charactersIgnoringModifiers: "k"
            ).makeShortcut()
        )

        XCTAssertEqual(shortcut.title, "⌃⌥K")
        XCTAssertEqual(shortcut.configuration.keyCode, UInt32(kVK_ANSI_K))
        XCTAssertEqual(
            shortcut.configuration.carbonModifiers,
            UInt32(controlKey | optionKey)
        )
    }

    func testShortcutCaptureRejectsUnmodifiedKeys() {
        XCTAssertNil(
            ShortcutCaptureInput(
                keyCode: UInt16(kVK_ANSI_K),
                modifierFlags: [],
                charactersIgnoringModifiers: "k"
            ).makeShortcut()
        )
    }

    func testShortcutCaptureLabelsFunctionKeysWithoutDependingOnKeyboardLayout() throws {
        let shortcut = try XCTUnwrap(
            ShortcutCaptureInput(
                keyCode: UInt16(kVK_F13),
                modifierFlags: [.shift],
                charactersIgnoringModifiers: nil
            ).makeShortcut()
        )

        XCTAssertEqual(shortcut.title, "⇧F13")
    }

    @MainActor
    func testPushToTalkToggleAndRecorderSuspendGlobalRegistration() throws {
        let suiteName = "HotKeyAndDiagnosticsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(false, forKey: "flusterflow.push-to-talk-enabled")
        let settings = SettingsStore(defaults: defaults)
        let hotKey = RecordingPushToTalkHotKeyController()
        let environment = AppEnvironment(hotKey: hotKey, settings: settings)
        defer {
            environment.shutdown()
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertEqual(environment.serviceStatusTitle, "Push-to-talk deaktiviert")
        XCTAssertEqual(hotKey.registrationCount, 0)

        settings.pushToTalkEnabled = true
        XCTAssertEqual(hotKey.registrationCount, 1)
        XCTAssertEqual(hotKey.lastConfiguration, settings.shortcut.configuration)
        XCTAssertEqual(settings.pushToTalkRegistrationStatus, .registered)

        settings.setShortcutCaptureActive(true)
        XCTAssertEqual(environment.serviceStatusTitle, "Tastenkürzel wird aufgenommen …")
        XCTAssertFalse(hotKey.isRegistered)
        XCTAssertEqual(settings.pushToTalkRegistrationStatus, .suspended)

        settings.setShortcutCaptureActive(false)
        XCTAssertEqual(hotKey.registrationCount, 2)
        XCTAssertTrue(hotKey.isRegistered)

        settings.pushToTalkEnabled = false
        XCTAssertEqual(environment.serviceStatusTitle, "Push-to-talk deaktiviert")
        XCTAssertFalse(hotKey.isRegistered)
        XCTAssertEqual(settings.pushToTalkRegistrationStatus, .disabled)
    }

    @MainActor
    func testFailedHotKeyRegistrationIsVisibleAndCanBeRetried() throws {
        let suiteName = "HotKeyAndDiagnosticsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: "flusterflow.push-to-talk-enabled")
        let settings = SettingsStore(defaults: defaults)
        let hotKey = RecordingPushToTalkHotKeyController()
        hotKey.registrationError = .hotKeyRegistrationFailed(OSStatus(eventHotKeyExistsErr))
        let environment = AppEnvironment(hotKey: hotKey, settings: settings)
        defer {
            environment.shutdown()
            defaults.removePersistentDomain(forName: suiteName)
        }

        settings.retryPushToTalkRegistration()
        XCTAssertEqual(
            settings.pushToTalkRegistrationStatus,
            .failed(OSStatus(eventHotKeyExistsErr))
        )
        XCTAssertEqual(
            environment.serviceStatusTitle,
            "Tastenkürzel wird bereits von einer anderen App verwendet"
        )

        hotKey.registrationError = nil
        settings.retryPushToTalkRegistration()

        XCTAssertEqual(settings.pushToTalkRegistrationStatus, .registered)
        XCTAssertTrue(hotKey.isRegistered)
    }

    @MainActor
    func testAccessibilityRequestOpensSettingsAndPollsUntilTrusted() async {
        let probe = RecordingAccessibilityPermissionActions()
        let center = PermissionCenter(
            accessibilityActions: probe.actions,
            accessibilityPollingInterval: .milliseconds(1)
        )

        XCTAssertEqual(center.accessibility, .denied)
        center.requestAccessibility()
        XCTAssertEqual(probe.promptCount, 1)
        XCTAssertEqual(probe.openSettingsCount, 1)

        probe.isTrusted = true
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(center.accessibility, .authorized)
    }

    @MainActor
    func testDeniedMicrophoneOpensSystemSettingsAndPollsUntilAuthorized() async {
        let microphone = RecordingMicrophonePermissionActions(status: .denied)
        let accessibility = RecordingAccessibilityPermissionActions()
        let center = PermissionCenter(
            microphoneActions: microphone.actions,
            accessibilityActions: accessibility.actions,
            microphonePollingInterval: .milliseconds(1)
        )

        XCTAssertEqual(center.microphone, .denied)
        XCTAssertEqual(
            center.microphoneRequestButtonTitle,
            "Mikrofon-Einstellungen öffnen"
        )

        center.requestMicrophone()

        XCTAssertEqual(microphone.requestCount, 0)
        XCTAssertEqual(microphone.openSettingsCount, 1)

        microphone.status = .authorized
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(center.microphone, .authorized)
    }

    func testPushToTalkReducerDebouncesPressAndReleaseEdges() {
        var reducer = PushToTalkEventReducer()

        XCTAssertEqual(reducer.consume(.pressed), .pressed)
        XCTAssertNil(reducer.consume(.pressed))
        XCTAssertEqual(reducer.consume(.released), .released)
        XCTAssertNil(reducer.consume(.released))
    }

    func testFlowBarExposesCancelOnlyForActivePhases() {
        XCTAssertTrue(FlowBarPresentation.priming.supportsCancellation)
        XCTAssertTrue(FlowBarPresentation.listening.supportsCancellation)
        XCTAssertTrue(FlowBarPresentation.processing.supportsCancellation)
        XCTAssertTrue(FlowBarPresentation.cloudProcessing.supportsCancellation)
        XCTAssertFalse(FlowBarPresentation.inserted.supportsCancellation)
        XCTAssertFalse(FlowBarPresentation.textFieldRequired.supportsCancellation)
        XCTAssertFalse(FlowBarPresentation.noSpeech.supportsCancellation)
        XCTAssertFalse(FlowBarPresentation.cancelled.supportsCancellation)
        XCTAssertFalse(FlowBarPresentation.error.supportsCancellation)
    }

    func testDiagnosticsV2PersistsOnlyContentFreeASRRuntimeAggregates() async throws {
        let diagnostics = ContentFreeDiagnostics()
        await diagnostics.recordASRRuntime(
            model: .adaptiveWhisperKit,
            durationClass: .medium,
            temperatureClass: .warm,
            confidenceClass: .low,
            usedAdaptiveFallback: true,
            prewarmSucceeded: true,
            prewarmLatencyMilliseconds: 45,
            vadSpeechDetected: true,
            vadLatencyMilliseconds: 4,
            asrLatencyMilliseconds: 320,
            endToInsertMilliseconds: 510,
            peakRSSBytes: 123_000_000
        )
        await diagnostics.recordASRRuntime(
            model: .adaptiveWhisperKit,
            durationClass: .medium,
            temperatureClass: .warm,
            confidenceClass: .high,
            usedAdaptiveFallback: false,
            prewarmSucceeded: false,
            prewarmLatencyMilliseconds: 35,
            vadSpeechDetected: true,
            vadLatencyMilliseconds: 2,
            asrLatencyMilliseconds: 280,
            endToInsertMilliseconds: 470,
            peakRSSBytes: 125_000_000
        )

        let report = await diagnostics.reportV2()
        let aggregate = try XCTUnwrap(report.asrRuntime.first)

        XCTAssertEqual(report.schemaVersion, 3)
        XCTAssertEqual(aggregate.sampleCount, 2)
        XCTAssertEqual(aggregate.adaptiveFallbackRate, 0.5)
        XCTAssertEqual(aggregate.prewarmSuccessRate, 0.5)
        XCTAssertEqual(aggregate.vadSpeechDetectedRate, 1)
        XCTAssertEqual(aggregate.prewarmLatency.p50Milliseconds, 35)
        XCTAssertEqual(aggregate.prewarmLatency.p95Milliseconds, 45)
        XCTAssertEqual(aggregate.vadLatency.p50Milliseconds, 2)
        XCTAssertEqual(aggregate.vadLatency.p95Milliseconds, 4)
        XCTAssertEqual(aggregate.asrLatency.p50Milliseconds, 280)
        XCTAssertEqual(aggregate.asrLatency.p95Milliseconds, 320)
        XCTAssertEqual(aggregate.endToInsertLatency.p50Milliseconds, 470)
        XCTAssertEqual(aggregate.peakRSSBytes, 125_000_000)

        let encoded = try String(
            decoding: JSONEncoder().encode(report),
            as: UTF8.self
        )
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("transcript"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("insertedText"))
        XCTAssertFalse(encoded.contains("https://"))
        XCTAssertFalse(encoded.contains("Fenstertitel"))
        XCTAssertFalse(encoded.contains("FlusterFlow arbeitet vollständig lokal"))
    }

    func testDiagnosticsV2PersistsOnlyContentFreeRewriteAggregates() async throws {
        let diagnostics = ContentFreeDiagnostics()
        await diagnostics.recordRewriteRuntime(
            rewriter: TextRewriterIdentifier("apple-foundation-models"),
            outcome: .accepted,
            reason: .none,
            outputLengthClass: .short,
            latencyMilliseconds: 90,
            sanitizerActionCount: 2
        )
        await diagnostics.recordRewriteRuntime(
            rewriter: TextRewriterIdentifier("apple-foundation-models"),
            outcome: .accepted,
            reason: .none,
            outputLengthClass: .short,
            latencyMilliseconds: 120,
            sanitizerActionCount: 1
        )
        await diagnostics.recordRewriteRuntime(
            rewriter: TextRewriterIdentifier("apple-foundation-models"),
            outcome: .rejected,
            reason: .lostProtectedAnchor,
            outputLengthClass: .medium,
            latencyMilliseconds: 40
        )

        let report = await diagnostics.reportV2()
        let accepted = try XCTUnwrap(
            report.rewriteRuntime.first { $0.key.outcome == .accepted }
        )
        let rejected = try XCTUnwrap(
            report.rewriteRuntime.first { $0.key.outcome == .rejected }
        )
        let encoded = try String(
            decoding: JSONEncoder().encode(report),
            as: UTF8.self
        )

        XCTAssertEqual(accepted.sampleCount, 2)
        XCTAssertEqual(accepted.key.rewriter, "apple-foundation-models")
        XCTAssertEqual(accepted.key.reason, .none)
        XCTAssertEqual(accepted.key.outputLengthClass, .short)
        XCTAssertEqual(accepted.sanitizerActionCount, 3)
        XCTAssertEqual(accepted.latency.p50Milliseconds, 90)
        XCTAssertEqual(accepted.latency.p95Milliseconds, 120)
        XCTAssertEqual(rejected.sampleCount, 1)
        XCTAssertEqual(rejected.key.reason, .lostProtectedAnchor)
        XCTAssertEqual(rejected.key.outputLengthClass, .medium)
        XCTAssertFalse(encoded.contains("Bitte sende den geheimen Bericht"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("context"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("window"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("title"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("url"))
        XCTAssertFalse(encoded.contains("https://"))
    }

    func testDiagnosticsV3DecodesPreviousReportWithoutRewriteRuntime() throws {
        let legacy = Data(#"{"schemaVersion":2,"pipelineStages":[],"asrRuntime":[]}"#.utf8)

        let report = try JSONDecoder().decode(DiagnosticsV2Report.self, from: legacy)

        XCTAssertEqual(report.schemaVersion, 2)
        XCTAssertTrue(report.pipelineStages.isEmpty)
        XCTAssertTrue(report.asrRuntime.isEmpty)
        XCTAssertTrue(report.rewriteRuntime.isEmpty)
    }

    func testDiagnosticsV2AggregateStoreWritesAtomicallyWithinBoundedContentFreeSchema() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diagnostics-v2-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DiagnosticsV2AggregateStore(directory: root, maximumEncodedBytes: 8 * 1024)
        let report = DiagnosticsV2Report(
            pipelineStages: [
                StageMetricAggregate(
                    stage: .asr,
                    sampleCount: 2,
                    averageMilliseconds: 20,
                    maximumMilliseconds: 30,
                    p50Milliseconds: 10,
                    p95Milliseconds: 30
                )
            ],
            asrRuntime: [
                ASRRuntimeAggregate(
                    key: ASRRuntimeAggregateKey(
                        model: .qwen3ASR06B8Bit,
                        durationClass: .short,
                        temperatureClass: .warm
                    ),
                    sampleCount: 1,
                    confidenceClassCounts: ["high": 1],
                    adaptiveFallbackCount: 0,
                    adaptiveFallbackRate: 0,
                    prewarmAttemptCount: 1,
                    prewarmSuccessRate: 1,
                    vadSpeechDetectedCount: 1,
                    vadSpeechDetectedRate: 1,
                    asrLatency: DiagnosticLatencyAggregate(
                        sampleCount: 1,
                        p50Milliseconds: 120,
                        p95Milliseconds: 120,
                        maximumMilliseconds: 120
                    ),
                    endToInsertLatency: DiagnosticLatencyAggregate(
                        sampleCount: 0,
                        p50Milliseconds: nil,
                        p95Milliseconds: nil,
                        maximumMilliseconds: nil
                    ),
                    peakRSSBytes: 42
                )
            ],
            rewriteRuntime: [
                RewriteRuntimeAggregate(
                    key: RewriteRuntimeAggregateKey(
                        rewriter: "apple-foundation-models",
                        outcome: .unavailable,
                        reason: .sensitiveContextDenied,
                        outputLengthClass: .short
                    ),
                    sampleCount: 1,
                    sanitizerActionCount: 0,
                    latency: DiagnosticLatencyAggregate(
                        sampleCount: 1,
                        p50Milliseconds: 5,
                        p95Milliseconds: 5,
                        maximumMilliseconds: 5
                    )
                )
            ]
        )

        try store.save(report)

        XCTAssertEqual(try store.load(), report)
        let data = try Data(contentsOf: root.appendingPathComponent("diagnostics-v2-aggregates.json"))
        XCTAssertLessThanOrEqual(data.count, 8 * 1024)
        let encoded = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("session"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("transcript"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("path"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("window"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("title"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("url"))
        XCTAssertFalse(encoded.contains("https://"))
    }

    func testSessionDiagnosticsClassifiesAdaptiveRuntimeWithoutPersistingContent() async throws {
        let diagnostics = ContentFreeDiagnostics()
        let sessions = ContentFreeSessionDiagnostics()
        let sessionID = DictationSessionID(rawValue: 91)
        let timing = AudioTimingMetadata(
            originalDurationSeconds: 7,
            processedDurationSeconds: 5,
            leadingSilenceTrimmedSeconds: 1,
            trailingSilenceTrimmedSeconds: 1,
            detectedSpeechDurationSeconds: 5,
            isSilent: false,
            removedDCOffset: 0.001,
            appliedGain: 1.2,
            vadProcessingMilliseconds: 3
        )
        await sessions.recordAudio(
            AudioInput(
                buffer: AudioBufferHandle(rawValue: 1),
                timing: timing
            ),
            sessionID: sessionID
        )
        await sessions.recordPrewarm(
            succeeded: true,
            latencyMilliseconds: 40,
            sessionID: sessionID
        )
        await sessions.recordRecognition(
            RawTranscript(
                text: "content must not survive aggregation",
                language: .german,
                backend: .whisperKitLargeV3,
                avgLogprob: -0.3,
                minWordProbability: 0.9,
                adaptive: AdaptiveRecognitionMetadata(
                    attemptedBackends: [.whisperKitLargeV3Turbo, .whisperKitLargeV3],
                    selectedBackend: .whisperKitLargeV3,
                    fallbackReasons: [.lowAverageLogprob(-0.9)],
                    largeFallbackAccepted: true
                )
            ),
            latencyMilliseconds: 300,
            sessionID: sessionID
        )
        _ = await diagnostics.metrics.record(
            stage: .total,
            sessionID: sessionID,
            startedAt: .zero,
            endedAt: .milliseconds(600)
        )

        await sessions.finalize(sessionID: sessionID, diagnostics: diagnostics)
        let report = await diagnostics.reportV2()
        let aggregate = try XCTUnwrap(report.asrRuntime.first)
        let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)

        XCTAssertEqual(aggregate.key.model, .adaptiveWhisperKit)
        XCTAssertEqual(aggregate.key.durationClass, .short)
        XCTAssertEqual(aggregate.confidenceClassCounts["high"], 1)
        XCTAssertEqual(aggregate.adaptiveFallbackRate, 1)
        XCTAssertEqual(aggregate.prewarmLatency.p50Milliseconds, 40)
        XCTAssertEqual(aggregate.vadLatency.p50Milliseconds, 3)
        XCTAssertEqual(aggregate.endToInsertLatency.p50Milliseconds, 600)
        XCTAssertFalse(encoded.contains("content must not survive aggregation"))
    }

    func testFlowBarWaveformAppearsOnlyDuringActiveWork() {
        XCTAssertTrue(FlowBarPresentation.priming.displaysWaveform)
        XCTAssertTrue(FlowBarPresentation.listening.displaysWaveform)
        XCTAssertTrue(FlowBarPresentation.processing.displaysWaveform)
        XCTAssertTrue(FlowBarPresentation.cloudProcessing.displaysWaveform)
        XCTAssertFalse(FlowBarPresentation.inserted.displaysWaveform)
        XCTAssertFalse(FlowBarPresentation.textFieldRequired.displaysWaveform)
        XCTAssertFalse(FlowBarPresentation.noSpeech.displaysWaveform)
        XCTAssertFalse(FlowBarPresentation.cancelled.displaysWaveform)
        XCTAssertFalse(FlowBarPresentation.error.displaysWaveform)
    }

    func testNoSpeechIsNotPresentedAsUserCancellation() {
        XCTAssertEqual(FlowBarPresentation.noSpeech.title, "Keine Sprache erkannt")
        XCTAssertEqual(FlowBarPresentation.cancelled.title, "Abgebrochen")
        XCTAssertNotEqual(
            FlowBarPresentation.noSpeech.compactTitle,
            FlowBarPresentation.cancelled.compactTitle
        )
    }

    func testFlowBarShadowHasEnoughTransparentInsetToFadeBeforeWindowEdge() {
        XCTAssertTrue(FlowBarLayout.shadowFitsInsideWindow)
        XCTAssertGreaterThanOrEqual(
            FlowBarLayout.shadowInset,
            FlowBarLayout.shadowRadius + abs(FlowBarLayout.shadowYOffset)
        )
    }

    func testFlowBarUsesACompactVisibleSurface() {
        for presentation in [
            FlowBarPresentation.priming,
            .listening,
            .processing,
            .cloudProcessing,
            .inserted,
            .textFieldRequired,
            .noSpeech,
            .cancelled,
            .error,
            .failure(DictationFailure(stage: .audioFinalize)),
            .failure(DictationFailure(stage: .recognition, reason: .recognitionTimedOut)),
            .failure(DictationFailure(stage: .insertion)),
            .historyWarning
        ] {
            XCTAssertLessThanOrEqual(FlowBarLayout.visibleWidth(for: presentation), 262)
            XCTAssertEqual(FlowBarLayout.visibleHeight, 44)
        }
    }

    func testRecordingTimerFormatsElapsedAndRemainingTime() {
        XCTAssertEqual(RecordingTimerText.elapsed(seconds: 0), "00:00")
        XCTAssertEqual(RecordingTimerText.elapsed(seconds: 65), "01:05")
        XCTAssertEqual(RecordingTimerText.remaining(seconds: 15), "noch 00:15")
        XCTAssertEqual(RecordingTimerText.remaining(seconds: -1), "noch 00:00")
        XCTAssertEqual(RecordingTimerText.display(elapsed: 104.999), "01:44")
        XCTAssertEqual(RecordingTimerText.display(elapsed: 105), "01:45")
        XCTAssertEqual(RecordingTimerText.display(elapsed: 120), "02:00")
        XCTAssertEqual(RecordingTimerText.display(elapsed: 121), "02:01")
        XCTAssertEqual(
            RecordingTimerText.accessibilityIdentifier,
            "flow-bar.recording-timer"
        )
        XCTAssertEqual(
            RecordingTimerText.accessibilityValue(elapsed: 65, handsFree: false),
            "01:05 aufgenommen"
        )
        XCTAssertEqual(
            RecordingTimerText.accessibilityValue(elapsed: 110, handsFree: true),
            "Handsfree aktiv, 01:50 aufgenommen"
        )

    }

    func testRainbowWaveformGeometryIsBoundedAndChangesOverTime() {
        let initial = (0 ..< FlowBarWaveformGeometry.barCount).map {
            FlowBarWaveformGeometry.normalizedHeight(for: $0, at: 0, tempo: 1)
        }
        let advanced = (0 ..< FlowBarWaveformGeometry.barCount).map {
            FlowBarWaveformGeometry.normalizedHeight(for: $0, at: 0.4, tempo: 1)
        }

        XCTAssertTrue(initial.allSatisfy {
            $0 >= FlowBarWaveformGeometry.minimumNormalizedHeight && $0 <= 1
        })
        XCTAssertNotEqual(initial, advanced)
    }

    @MainActor
    func testFlowBarPreviewsKeepTheirWindowCornersTransparent() throws {
        let previews: [(FlowBarPresentation, (() -> Void)?, ColorScheme, String)] = [
            (.listening, {}, .light, "flusterflow-flowbar-listening-light.png"),
            (.listening, {}, .dark, "flusterflow-flowbar-listening-dark.png"),
            (.inserted, nil, .dark, "flusterflow-flowbar-inserted.png")
        ]

        for (presentation, cancel, colorScheme, fileName) in previews {
            let size = FlowBarLayout.windowSize(for: presentation)
            let renderer = ImageRenderer(
                content: FlowBarView(
                    presentation: presentation,
                    recordingStartedAt: presentation == .listening ? Date().addingTimeInterval(-65) : nil,
                    handsFree: colorScheme == .dark,
                    recordingAction: presentation == .listening ? {} : nil,
                    cancel: cancel,
                    animationEnabled: false
                )
                .environment(\.colorScheme, colorScheme)
            )
            renderer.proposedSize = ProposedViewSize(
                width: size.width,
                height: size.height
            )
            renderer.scale = 2
            renderer.isOpaque = false

            let image = try XCTUnwrap(renderer.nsImage)
            let representation = try XCTUnwrap(
                image.representations.compactMap { $0 as? NSBitmapImageRep }.first
                    ?? image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
            )
            let maximumX = representation.pixelsWide - 1
            let maximumY = representation.pixelsHigh - 1
            let corners = [
                NSPoint(x: 0, y: 0),
                NSPoint(x: maximumX, y: 0),
                NSPoint(x: 0, y: maximumY),
                NSPoint(x: maximumX, y: maximumY)
            ]

            for corner in corners {
                XCTAssertLessThanOrEqual(
                    representation.colorAt(x: Int(corner.x), y: Int(corner.y))?.alphaComponent ?? 0,
                    0.01
                )
            }

            let previewURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(fileName)
            let png = try XCTUnwrap(
                representation.representation(using: .png, properties: [:])
            )
            try png.write(to: previewURL, options: .atomic)
            print("FLOWBAR_PREVIEW_PATH=\(previewURL.path)")
        }
    }

    func testUnconfirmedInsertionDoesNotClaimDefiniteFailure() {
        let failure = DictationFailure(stage: .insertion, reason: .insertionUnconfirmed)
        XCTAssertEqual(failure.compactTitle, "Einfügung unbestätigt")
        XCTAssertEqual(failure.title, "Einfügung nicht bestätigt – Textfeld prüfen")
        XCTAssertNotEqual(failure.title, DictationFailure(stage: .insertion).title)
    }

    func testCancellationPresentationWaitsWhenInsertionCommitAlreadyWon() {
        let sessionID = DictationSessionID(rawValue: 17)

        XCTAssertEqual(
            CancelOutcome.cancelled(sessionID).presentationDecision,
            .showCancelled
        )
        XCTAssertEqual(
            CancelOutcome.failed(
                sessionID,
                DictationFailure(stage: .audioFinalize)
            ).presentationDecision,
            .showError
        )
        XCTAssertEqual(CancelOutcome.cancelled(sessionID).terminatedSessionID, sessionID)
        XCTAssertEqual(
            CancelOutcome.failed(
                sessionID,
                DictationFailure(stage: .audioFinalize)
            ).terminatedSessionID,
            sessionID
        )
        XCTAssertEqual(
            CancelOutcome.tooLateCommitted(sessionID).presentationDecision,
            .deferToOperationCompletion
        )
        XCTAssertNil(CancelOutcome.tooLateCommitted(sessionID).terminatedSessionID)
        XCTAssertEqual(
            CancelOutcome.ignoredStale(sessionID).presentationDecision,
            .unchanged
        )
        XCTAssertEqual(
            CancelOutcome.noActiveSession.presentationDecision,
            .unchanged
        )

        XCTAssertEqual(
            CancelOutcome.cancelled(sessionID).presentationDecision(
                errorTerminalSessionID: nil
            ),
            .showCancelled
        )
        XCTAssertEqual(
            CancelOutcome.cancelled(sessionID).presentationDecision(
                errorTerminalSessionID: sessionID
            ),
            .showError
        )
        XCTAssertEqual(
            CancelOutcome.failed(
                sessionID,
                DictationFailure(stage: .audioFinalize)
            ).presentationDecision(errorTerminalSessionID: nil),
            .showError
        )
        XCTAssertEqual(
            CancelOutcome.tooLateCommitted(sessionID).presentationDecision(
                errorTerminalSessionID: nil
            ),
            .deferToOperationCompletion
        )
        XCTAssertEqual(
            CancelOutcome.ignoredStale(sessionID).presentationDecision(
                errorTerminalSessionID: nil
            ),
            .unchanged
        )
        XCTAssertEqual(
            CancelOutcome.noActiveSession.presentationDecision(
                errorTerminalSessionID: nil
            ),
            .unchanged
        )
    }

    func testEarlyPrimingCancellationTerminatesWhenNoSessionExistsYet() {
        XCTAssertEqual(
            CancelOutcome.noActiveSession.presentationDecision(
                errorTerminalSessionID: nil,
                cancelledBeforeSessionStart: true
            ),
            .showCancelled
        )
    }

    func testRequiredDiagnosticStagesMatchO04Exactly() {
        XCTAssertEqual(
            DiagnosticStage.requiredPipelineStages,
            [.audioFinalize, .asr, .cleanup, .cloud, .insertion, .total]
        )
        XCTAssertEqual(
            DiagnosticStage.requiredPipelineStages.map(\.rawValue),
            ["audioFinalize", "asr", "cleanup", "cloud", "insertion", "total"]
        )
    }

    func testStageMetricsAreBoundedMonotonicAndSessionScoped() async throws {
        let recorder = StageMetricRecorder(maximumSamplesPerStage: 2)
        let primarySession = DictationSessionID(rawValue: 7)
        let otherSession = DictationSessionID(rawValue: 8)

        await recorder.record(
            stage: .asr,
            sessionID: primarySession,
            startedAt: .milliseconds(0),
            endedAt: .milliseconds(10)
        )
        await recorder.record(
            stage: .asr,
            sessionID: primarySession,
            startedAt: .milliseconds(20),
            endedAt: .milliseconds(40)
        )
        await recorder.record(
            stage: .asr,
            sessionID: primarySession,
            startedAt: .milliseconds(50),
            endedAt: .milliseconds(80)
        )
        await recorder.record(
            stage: .cleanup,
            sessionID: otherSession,
            startedAt: .milliseconds(5),
            endedAt: .milliseconds(6)
        )

        let primaryTrace = await recorder.samples(for: primarySession)
        XCTAssertEqual(primaryTrace.count, 2)
        XCTAssertEqual(primaryTrace.map(\.sessionID), [primarySession, primarySession])
        XCTAssertEqual(primaryTrace.map(\.durationMilliseconds), [20, 30])
        XCTAssertTrue(primaryTrace.allSatisfy { $0.startedAt <= $0.endedAt })
        XCTAssertTrue(zip(primaryTrace, primaryTrace.dropFirst()).allSatisfy {
            $0.startedAt <= $1.startedAt
        })

        let otherTrace = await recorder.samples(for: otherSession)
        XCTAssertEqual(otherTrace.map(\.stage), [.cleanup])
        XCTAssertEqual(otherTrace.map(\.sessionID), [otherSession])

        let aggregates = await recorder.aggregates()
        let asr = try XCTUnwrap(aggregates.first { $0.stage == .asr })

        XCTAssertEqual(
            asr,
            StageMetricAggregate(
                stage: .asr,
                sampleCount: 2,
                averageMilliseconds: 25,
                maximumMilliseconds: 30
            )
        )
    }

    func testEveryRequiredStageKeepsMonotonicTimestampsForOneSession() async {
        let recorder = StageMetricRecorder()
        let sessionID = DictationSessionID(rawValue: UInt64.max - 1)

        for (index, stage) in DiagnosticStage.requiredPipelineStages.enumerated() {
            let startedAt = Duration.milliseconds(Int64(index * 10))
            await recorder.record(
                stage: stage,
                sessionID: sessionID,
                startedAt: startedAt,
                endedAt: startedAt + .milliseconds(5)
            )
        }

        let trace = await recorder.samples(for: sessionID)
        XCTAssertEqual(trace.map(\.stage), DiagnosticStage.requiredPipelineStages)
        XCTAssertEqual(Set(trace.map(\.sessionID)), [sessionID])
        XCTAssertTrue(trace.allSatisfy { $0.startedAt <= $0.endedAt })
        XCTAssertTrue(zip(trace, trace.dropFirst()).allSatisfy {
            $0.startedAt <= $1.startedAt
        })
    }

    func testRecorderRemainsBoundedUnderConcurrentSessions() async {
        let recorder = StageMetricRecorder(maximumSamplesPerStage: 8)

        await withTaskGroup(of: Void.self) { group in
            for rawValue in 1 ... 64 {
                group.addTask {
                    let startedAt = Duration.milliseconds(Int64(rawValue))
                    await recorder.record(
                        stage: .asr,
                        sessionID: DictationSessionID(rawValue: UInt64(rawValue)),
                        startedAt: startedAt,
                        endedAt: startedAt + .milliseconds(1)
                    )
                }
            }
        }

        let samples = await recorder.samples()
        XCTAssertEqual(samples.count, 8)
        XCTAssertTrue(samples.allSatisfy { $0.stage == .asr })
        XCTAssertTrue(samples.allSatisfy { $0.startedAt <= $0.endedAt })
    }

    func testMeasuredFailureStillRecordsTheCorrectEphemeralSession() async {
        enum ProbeFailure: Error { case expected }

        let recorder = StageMetricRecorder()
        let diagnostics = ContentFreeDiagnostics(metrics: recorder)
        let sessionID = DictationSessionID(rawValue: UInt64.max)
        let operation: @Sendable () async throws -> Int = {
            throw ProbeFailure.expected
        }

        do {
            _ = try await diagnostics.measure(
                stage: .cleanup,
                sessionID: sessionID,
                operation: operation
            )
            XCTFail("Expected the measured operation to fail")
        } catch ProbeFailure.expected {
            // Expected: failures still close their content-free measurement.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let trace = await recorder.samples(for: sessionID)
        XCTAssertEqual(trace.count, 1)
        XCTAssertEqual(trace.first?.sessionID, sessionID)
        XCTAssertEqual(trace.first?.stage, .cleanup)
        XCTAssertTrue(trace.allSatisfy { $0.startedAt <= $0.endedAt })
    }

    func testDiagnosticsExportContainsAggregatesButNoSessionOrUserData() throws {
        let report = DiagnosticsReport(
            schemaVersion: 1,
            appVersion: "test",
            runtimeName: "local-runtime",
            runtimeVersion: "1",
            microphonePermission: .authorized,
            accessibilityPermission: .authorized,
            modelStatus: "ready",
            stageDurations: [
                StageMetricAggregate(
                    stage: .asr,
                    sampleCount: 1,
                    averageMilliseconds: 12,
                    maximumMilliseconds: 12
                )
            ],
            rewriteRuntime: [
                RewriteRuntimeAggregate(
                    key: RewriteRuntimeAggregateKey(
                        rewriter: "apple-foundation-models",
                        outcome: .accepted,
                        reason: .none,
                        outputLengthClass: .short
                    ),
                    sampleCount: 1,
                    sanitizerActionCount: 1,
                    latency: DiagnosticLatencyAggregate(
                        sampleCount: 1,
                        p50Milliseconds: 20,
                        p95Milliseconds: 20,
                        maximumMilliseconds: 20
                    )
                )
            ]
        )
        let artifact = try XCTUnwrap(
            String(data: JSONEncoder().encode(report), encoding: .utf8)
        )

        for forbidden in [
            "sessionID",
            "startedAt",
            "endedAt",
            "transcript-canary",
            "context-canary",
            "device-uid-canary"
        ] {
            XCTAssertFalse(artifact.contains(forbidden), forbidden)
        }
        XCTAssertTrue(artifact.contains("asr"))
        XCTAssertTrue(artifact.contains("apple-foundation-models"))
    }
}

@MainActor
private final class RecordingPushToTalkHotKeyController: PushToTalkHotKeyControlling {
    private(set) var registrationCount = 0
    private(set) var unregisterCount = 0
    private(set) var lastConfiguration: PushToTalkHotKeyConfiguration?
    private(set) var isRegistered = false
    private var handler: (@MainActor @Sendable (PushToTalkHotKeyEvent) -> Void)?
    var registrationError: GlobalHotKeyError?

    func register(
        configuration: PushToTalkHotKeyConfiguration,
        handler: @escaping @MainActor @Sendable (PushToTalkHotKeyEvent) -> Void
    ) throws {
        registrationCount += 1
        if let registrationError { throw registrationError }
        lastConfiguration = configuration
        isRegistered = true
        self.handler = handler
    }

    func unregister() {
        unregisterCount += 1
        isRegistered = false
        handler = nil
    }
}

@MainActor
private final class RecordingAccessibilityPermissionActions {
    var isTrusted = false
    private(set) var promptCount = 0
    private(set) var openSettingsCount = 0

    var actions: AccessibilityPermissionActions {
        AccessibilityPermissionActions(
            isTrusted: { [weak self] in self?.isTrusted ?? false },
            requestPrompt: { [weak self] in self?.promptCount += 1 },
            openSystemSettings: { [weak self] in self?.openSettingsCount += 1 }
        )
    }
}

@MainActor
private final class RecordingMicrophonePermissionActions {
    var status: AVAuthorizationStatus
    private(set) var requestCount = 0
    private(set) var openSettingsCount = 0

    init(status: AVAuthorizationStatus) {
        self.status = status
    }

    var actions: MicrophonePermissionActions {
        MicrophonePermissionActions(
            authorizationStatus: { [weak self] in self?.status ?? .restricted },
            requestAccess: { [weak self] in
                self?.requestCount += 1
                return self?.status == .authorized
            },
            openSystemSettings: { [weak self] in self?.openSettingsCount += 1 }
        )
    }
}
