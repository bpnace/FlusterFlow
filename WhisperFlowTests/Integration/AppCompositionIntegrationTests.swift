import Foundation
import XCTest
@testable import WhisperFlow

final class AppCompositionIntegrationTests: XCTestCase, @unchecked Sendable {
    func testLiveAppPathsUseApplicationSupportWithoutTemporaryFallback() throws {
        let expectedBase = try XCTUnwrap(
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        )
        let paths = AppPaths.live()

        XCTAssertEqual(
            paths.applicationSupportDirectory,
            expectedBase.appendingPathComponent("FlusterFlow", isDirectory: true)
        )

        let source = try repositorySource("WhisperFlow/App/RuntimeComposition.swift")
        XCTAssertFalse(source.contains("first ?? fileManager.temporaryDirectory"))
        XCTAssertTrue(
            source.contains(
                "preconditionFailure(\"Application Support directory unavailable\")"
            )
        )
    }

    func testDebugBuildCannotCollideWithInstalledReleaseTCCIdentity() {
        #if !SWIFT_PACKAGE
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.flusterflow.private.debug")
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            "FlusterFlow Debug"
        )
        XCTAssertEqual(Bundle.main.bundleURL.lastPathComponent, "FlusterFlow Debug.app")
        #endif
    }

    func testHostedTestRuntimeIsDetectedWithoutClassifyingNormalLaunchAsTest() {
        XCTAssertTrue(
            ApplicationRuntime.isRunningTests(
                environment: ["XCTestConfigurationFilePath": "/tmp/WhisperFlow.xctestconfiguration"]
            )
        )
        XCTAssertTrue(
            ApplicationRuntime.isRunningTests(
                environment: ["XCInjectBundleInto": "/tmp/FlusterFlow"]
            )
        )
        XCTAssertFalse(ApplicationRuntime.isRunningTests(environment: [:]))
    }

    func testStandardAppSettingsCommandRoutesToUnifiedAppWindow() throws {
        let appSource = try repositorySource("WhisperFlow/App/WhisperFlowApp.swift")
        let delegateSource = try repositorySource("WhisperFlow/App/AppDelegate.swift")
        let environmentSource = try repositorySource("WhisperFlow/App/AppEnvironment.swift")

        XCTAssertTrue(appSource.contains("CommandGroup(replacing: .appSettings)"))
        XCTAssertTrue(appSource.contains("appDelegate.presentSettings()"))
        XCTAssertTrue(delegateSource.contains("func presentSettings()"))
        XCTAssertTrue(delegateSource.contains("environment.presentSettings()"))
        XCTAssertTrue(environmentSource.contains("appWindow.presentSettings()"))
        XCTAssertTrue(environmentSource.contains("appWindow.present(.recordings)"))
    }

    func testApplicationReopenRoutesToOverviewInsteadOfSettings() throws {
        let delegateSource = try repositorySource("WhisperFlow/App/AppDelegate.swift")
        let functionStart = try XCTUnwrap(
            delegateSource.range(of: "func applicationShouldHandleReopen(")
        )
        let functionEnd = try XCTUnwrap(
            delegateSource.range(
                of: "func applicationWillTerminate(",
                range: functionStart.upperBound..<delegateSource.endIndex
            )
        )
        let function = String(
            delegateSource[functionStart.lowerBound..<functionEnd.lowerBound]
        )

        XCTAssertTrue(function.contains("environment.presentApp()"))
        XCTAssertFalse(function.contains("presentSettings()"))
    }

    func testProductionCompositionOwnsOnlyTheUnifiedPrimaryWindowController() throws {
        let sourceRoot = try TestResourceLoader.url("WhisperFlow")
        let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        )
        let combined = try (enumerator?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")

        XCTAssertTrue(combined.contains("final class AppWindowController"))
        XCTAssertFalse(combined.contains("final class SettingsWindowController"))
        XCTAssertFalse(combined.contains("final class RecordingHistoryWindowController"))
        XCTAssertFalse(combined.contains("final class OnboardingWindowController"))
    }

    func testOverviewIsCompactAndDoesNotDuplicateItsSidebarTitle() throws {
        let source = try repositorySource(
            "WhisperFlow/Features/Onboarding/AppOverviewView.swift"
        )

        XCTAssertFalse(source.contains("Text(\"Übersicht\")"))
        XCTAssertFalse(
            source.contains("Bereitschaft und lokale Verarbeitung auf einen Blick")
        )
        XCTAssertTrue(source.contains("ViewThatFits(in: .vertical)"))
        XCTAssertTrue(source.contains("ScrollView"))
        XCTAssertTrue(source.contains(".padding(.vertical, 20)"))
    }

    func testLocalPipelineExtractsTermsCorrectsCleanupAndPreservesSafeFallback() async throws {
        let recognizer = RecordingRecognizer(text: "flusterflov arbeitet lokal")
        let fallback = EphemeralResultStore()
        let insertion = TestInsertion(outcome: .safeFallback)
        let coordinator = DictationCoordinator(
            contextProvider: ExtractingTargetContextProvider(
                provider: TestContextProvider(
                    context: ContextSnapshot(
                        availability: .available,
                        targetKind: .document,
                        boundedText: "FlusterFlow bleibt lokal. FlusterFlow verwendet ContextTermExtractor.",
                        termHints: []
                    )
                )
            ),
            audioCapture: TestAudioCapture(),
            recognizer: recognizer,
            cleanup: ContextCorrectingCleanupPipeline(),
            enrichment: TestEnrichment(),
            insertion: insertion,
            fallbackText: fallback
        )

        let sessionID = try await start(coordinator, language: .german)
        let outcome = await coordinator.stop(sessionID: sessionID)
        let result = await fallback.oldest()
        let hints = await recognizer.lastHints()
        let fallbackCount = await fallback.count()

        XCTAssertEqual(outcome, .completed(sessionID, .safeFallback))
        XCTAssertTrue(hints.terms.contains("FlusterFlow"))
        XCTAssertEqual(result?.text, "FlusterFlow arbeitet lokal.")
        XCTAssertEqual(result?.rawTranscript, "flusterflov arbeitet lokal")
        XCTAssertEqual(result?.candidateText, "FlusterFlow arbeitet lokal.")
        XCTAssertEqual(fallbackCount, 1)
    }

    func testAccessibilityDenialBlocksDirectDictation() {
        let readiness = DictationCapabilityStatus(
            microphone: .authorized,
            accessibility: .denied,
            model: readyModelStatus()
        )

        XCTAssertFalse(readiness.canStartLocalDictation)
        XCTAssertFalse(readiness.hasAutomaticInsertion)
        XCTAssertEqual(
            readiness.statusTitle(shortcut: "⌃⌥Space"),
            "Bedienungshilfen für direktes Einfügen fehlen"
        )
    }

    func testNormalDictationFlowNeverPresentsAFallbackResultWindow() throws {
        let source = try repositorySource("WhisperFlow/App/AppEnvironment.swift")

        XCTAssertFalse(source.contains("FallbackResultController"))
        XCTAssertFalse(source.contains("fallbackWindow"))
        XCTAssertFalse(source.contains("presentOldest"))
    }

    func testCloudOffNeverReachesTransportEvenWhenKeyExists() async throws {
        let transport = RecordingCloudTransport(result: .failure(TestError.expected))
        let enrichment = SessionAwareOpenAIEnrichment(
            gate: CloudGate(keyStore: TestKeyStore(hasKey: true)),
            transport: transport,
            validator: MeaningPreservationPolicy()
        )
        let insertion = TestInsertion(outcome: .confirmedDirect)
        let coordinator = makeCoordinator(enrichment: enrichment, insertion: insertion)
        let sessionID = try await start(coordinator, language: .english)
        await enrichment.register(language: .english, for: sessionID)

        let outcome = await coordinator.stop(
            sessionID: sessionID,
            consent: .localOnly
        )
        let transportCalls = await transport.callCount()
        let insertedTexts = await insertion.insertedTexts()

        XCTAssertEqual(outcome, .completed(sessionID, .confirmedDirect))
        XCTAssertEqual(transportCalls, 0)
        XCTAssertEqual(insertedTexts, ["Hello world."])
    }

    func testCloudTransportFailureFallsBackWithoutLosingLocalCandidate() async throws {
        let transport = RecordingCloudTransport(result: .failure(TestError.expected))
        let enrichment = SessionAwareOpenAIEnrichment(
            gate: CloudGate(keyStore: TestKeyStore(hasKey: true)),
            transport: transport,
            validator: MeaningPreservationPolicy()
        )
        let insertion = TestInsertion(outcome: .confirmedDirect)
        let coordinator = makeCoordinator(enrichment: enrichment, insertion: insertion)
        let sessionID = try await start(coordinator, language: .english)
        await enrichment.register(language: .english, for: sessionID)

        let outcome = await coordinator.stop(
            sessionID: sessionID,
            consent: ConsentSnapshot(cloudEnabled: true, contextToCloud: true)
        )
        let transportCalls = await transport.callCount()
        let insertedTexts = await insertion.insertedTexts()

        XCTAssertEqual(outcome, .completed(sessionID, .confirmedDirect))
        XCTAssertEqual(transportCalls, 1)
        XCTAssertEqual(insertedTexts, ["Hello world."])
    }

    func testSensitiveTargetStopsBeforeRecordingOrCloud() async {
        let transport = RecordingCloudTransport(result: .success("provider text"))
        let enrichment = SessionAwareOpenAIEnrichment(
            gate: CloudGate(keyStore: TestKeyStore(hasKey: true)),
            transport: transport
        )
        let fallback = EphemeralResultStore()
        let insertion = TestInsertion(outcome: .safeFallback)
        let coordinator = DictationCoordinator(
            contextProvider: TestContextProvider(
                context: ContextSnapshot(
                    availability: .deniedSensitive,
                    targetKind: .unknown,
                    boundedText: nil,
                    termHints: []
                )
            ),
            audioCapture: TestAudioCapture(),
            recognizer: RecordingRecognizer(text: "secret words"),
            cleanup: ContextCorrectingCleanupPipeline(),
            enrichment: enrichment,
            insertion: insertion,
            fallbackText: fallback
        )
        let outcome = await coordinator.start(language: .english)
        let sessionID = outcome.sessionID
        let transportCalls = await transport.callCount()
        let fallbackText = await fallback.oldest()?.text

        XCTAssertEqual(
            outcome,
            .failed(sessionID, DictationFailure(stage: .context))
        )
        XCTAssertEqual(transportCalls, 0)
        XCTAssertNil(fallbackText)
    }

    func testCleanupFailurePreservesRawTranscriptAndReleasesEverySessionResource() async throws {
        let lifecycle = LifecycleProbe()
        let fallback = EphemeralResultStore()
        let coordinator = DictationCoordinator(
            contextProvider: ProbedContextProvider(probe: lifecycle),
            audioCapture: ProbedAudioCapture(probe: lifecycle),
            recognizer: ProbedRecognizer(probe: lifecycle, text: "raw transcript canary"),
            cleanup: FailingCleanup(),
            enrichment: ProbedEnrichment(probe: lifecycle),
            insertion: ProbedInsertion(probe: lifecycle),
            fallbackText: fallback
        )
        let sessionID = try await start(coordinator, language: .english)

        let outcome = await coordinator.stop(sessionID: sessionID)
        let fallbackText = await fallback.oldest()?.text
        let cancellationCounts = await lifecycle.cancellationCounts()

        XCTAssertEqual(outcome, .failed(sessionID, DictationFailure(stage: .cleanup)))
        XCTAssertEqual(fallbackText, "raw transcript canary")
        XCTAssertEqual(cancellationCounts, [1, 1, 1, 1, 1])
    }

    func testEphemeralFallbackIsSingleSlotUntilExplicitDiscard() async {
        let store = EphemeralResultStore()
        let first = DictationSessionID(rawValue: 1)
        let second = DictationSessionID(rawValue: 2)

        await store.preserveRawTranscript("first raw", for: first)
        await store.preserveCandidate("first", for: first)
        await store.preserveRawTranscript("second", for: second)
        let count = await store.count()
        let stored = await store.oldest()
        let discarded = await store.discard(sessionID: first)
        await store.preserveCandidate("late candidate", for: first)
        let afterDiscard = await store.oldest()

        XCTAssertEqual(count, 1)
        XCTAssertEqual(
            stored,
            EphemeralFallbackResult(
                sessionID: first,
                rawTranscript: "first raw",
                candidateText: "first"
            )
        )
        XCTAssertTrue(discarded)
        XCTAssertNil(afterDiscard)
    }

    func testConfirmedInsertionClearsRawAndCandidateAndRejectsLateWrites() async {
        let store = EphemeralResultStore()
        let sessionID = DictationSessionID(rawValue: 41)

        await store.preserveRawTranscript("raw", for: sessionID)
        await store.preserveCandidate("Final.", for: sessionID)
        await store.confirmInsertion(sessionID: sessionID)
        await store.preserveCandidate("late", for: sessionID)
        let stored = await store.oldest()

        XCTAssertNil(stored)
    }

    @MainActor
    func testSettingsDefaultToLocalOnlyAndStopConsentSnapshotIsImmutable() {
        let suiteName = "AppCompositionIntegrationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)

        let localSnapshot = settings.consentSnapshot()
        settings.cloudEnabled = true
        settings.cloudContextEnabled = true

        XCTAssertEqual(localSnapshot, .localOnly)
        XCTAssertEqual(
            settings.consentSnapshot(),
            ConsentSnapshot(cloudEnabled: true, contextToCloud: true)
        )
        XCTAssertNil(defaults.string(forKey: "OPENAI_API_KEY"))
    }

    func testRuntimeSourcesContainNoBootstrapOrCredentialEnvironmentPath() throws {
        let sourceRoot = try TestResourceLoader.url("WhisperFlow")
        let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        )
        let swiftFiles = (enumerator?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" }
        let combined = try swiftFiles
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")

        XCTAssertFalse(combined.contains("Bootstrap"))
        XCTAssertFalse(combined.contains("OPENAI_API_KEY"))
        let composition = try TestResourceLoader.string("WhisperFlow/App/RuntimeComposition.swift")
        XCTAssertFalse(composition.contains("ModelProvisioningTransport"))
        XCTAssertFalse(composition.contains("ModelProvisioningService"))
    }

    func testOverviewDisclosesLocalRecordingHistory() throws {
        let privacyCopy = AppOverviewPrivacyCopy.localHistory(cloudEnabled: false)
        XCTAssertTrue(privacyCopy.contains("Lokal löschbare Aufnahmehistorie"))
        XCTAssertFalse(privacyCopy.contains("Keine Aufnahmehistorie"))
    }

    func testProtectedContentIsCheckedAtCaptureAndRevalidatedBeforeInsertion() throws {
        let source = try TestResourceLoader.string(
            "WhisperFlow/Core/Accessibility/AccessibilityTargetRegistry.swift"
        )
        let protectedContentChecks = source.components(
            separatedBy: "NSAccessibility.Attribute.containsProtectedContent.rawValue"
        ).count - 1

        XCTAssertGreaterThanOrEqual(protectedContentChecks, 2)
        XCTAssertTrue(source.contains("private func validatedEntry(for target: TargetSnapshot)"))
    }

    func testDiagnosticsExposeP50AndP95WithoutFreeText() async throws {
        let recorder = StageMetricRecorder(maximumSamplesPerStage: 8)
        let sessionID = DictationSessionID(rawValue: 91)
        for (index, value) in [10, 20, 30, 40].enumerated() {
            let startedAt = Duration.milliseconds(Int64(index * 100))
            await recorder.record(
                stage: .asr,
                sessionID: sessionID,
                startedAt: startedAt,
                endedAt: startedAt + .milliseconds(Int64(value))
            )
        }

        let aggregates = await recorder.aggregates()
        let aggregate = try XCTUnwrap(aggregates.first)
        XCTAssertEqual(aggregate.p50Milliseconds, 25)
        XCTAssertEqual(aggregate.p95Milliseconds, 40)
    }

    func testRuntimeMetricCallSitesUseOnlyO04StageNames() throws {
        let sources = try [
            "WhisperFlow/App/RuntimeComposition.swift",
            "WhisperFlow/App/AppEnvironment.swift"
        ]
        .map(repositorySource)
        .joined(separator: "\n")

        for stage in DiagnosticStage.requiredPipelineStages {
            XCTAssertTrue(sources.contains("stage: .\(stage.rawValue)"), stage.rawValue)
        }
        XCTAssertFalse(sources.contains("stage: .audioCapture"))
        XCTAssertFalse(sources.contains("stage: .recognition"))
        XCTAssertFalse(sources.contains("stage: .enrichment"))
    }

    func testCancelUIWaitsForCoordinatorOutcomeBeforeShowingCancelled() throws {
        let source = try repositorySource("WhisperFlow/App/AppEnvironment.swift")
        let functionStart = try XCTUnwrap(source.range(of: "func cancelActiveSession()"))
        let functionEnd = try XCTUnwrap(
            source.range(
                of: "@discardableResult",
                range: functionStart.upperBound..<source.endIndex
            )
        )
        let function = String(source[functionStart.lowerBound..<functionEnd.lowerBound])
        let coordinatorAwait = try XCTUnwrap(
            function.range(of: "outcome = await coordinator.cancel")
        )
        let beforeCoordinatorOutcome = function[..<coordinatorAwait.lowerBound]
        let normalizedFunction = function
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")

        XCTAssertFalse(beforeCoordinatorOutcome.contains("showFlow(.cancelled)"))
        XCTAssertTrue(
            normalizedFunction.contains(
                "applyCancellationOutcome( outcome, "
                    + "cancelledBeforeSessionStart: cancelledBeforeSessionStart )"
            )
        )
    }

    func testUnifiedLogDiagnosticsContainNoSessionIdentifierSurface() throws {
        let source = try repositorySource(
            "WhisperFlow/Core/Diagnostics/ContentFreeDiagnostics.swift"
        )

        XCTAssertFalse(source.contains("sessionID.rawValue"))
        XCTAssertFalse(source.contains("session=\\("))
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        try TestResourceLoader.string(relativePath)
    }

    private func makeCoordinator(
        enrichment: any TextEnriching,
        insertion: any TextInserting
    ) -> DictationCoordinator {
        DictationCoordinator(
            contextProvider: TestContextProvider(context: .unavailable(targetKind: .unknown)),
            audioCapture: TestAudioCapture(),
            recognizer: RecordingRecognizer(text: "hello world"),
            cleanup: ContextCorrectingCleanupPipeline(),
            enrichment: enrichment,
            insertion: insertion
        )
    }

    private func start(
        _ coordinator: DictationCoordinator,
        language: DictationLanguage
    ) async throws -> DictationSessionID {
        let outcome = await coordinator.start(language: language)
        guard case .started(let sessionID) = outcome else {
            throw TestError.unexpectedStart
        }
        return sessionID
    }
}

private func readyModelStatus() -> LocalModelStatus {
    .ready(
        LocalModelReadiness(
            manifestIdentifier: "test-model",
            modelRevision: "test-revision",
            byteCount: 1,
            treeSHA256: ModelSHA256(String(repeating: "0", count: 64))!
        )
    )
}

private struct TestContextProvider: TargetContextProviding {
    let context: ContextSnapshot

    func capture(for sessionID: DictationSessionID) async throws -> CapturedTargetContext {
        CapturedTargetContext(target: testTarget(sessionID), context: context)
    }

    func cancel(sessionID: DictationSessionID) async {}
}

private struct TestAudioCapture: AudioCapturing {
    func startCapture(for sessionID: DictationSessionID) async throws {}

    func finishCapture(for sessionID: DictationSessionID) async throws -> AudioInput {
        AudioInput(buffer: AudioBufferHandle(rawValue: sessionID.rawValue))
    }

    func cancelCapture(for sessionID: DictationSessionID) async {}

    func release(_ input: AudioInput) async {}
}

private actor RecordingRecognizer: SpeechRecognizing {
    private let text: String
    private var hints = RecognitionHints(language: .automatic, terms: [])

    init(text: String) {
        self.text = text
    }

    func transcribe(
        _ audio: AudioInput,
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws -> RawTranscript {
        self.hints = hints
        return RawTranscript(text: text, language: hints.language)
    }

    func cancel(sessionID: DictationSessionID) async {}

    func lastHints() -> RecognitionHints { hints }
}

private struct TestEnrichment: TextEnriching {
    func enrich(
        _ candidate: LocalCandidate,
        context: ContextSnapshot,
        consent: ConsentSnapshot,
        sessionID: DictationSessionID
    ) async throws -> EnrichedCandidate {
        EnrichedCandidate(text: candidate.text)
    }

    func cancel(sessionID: DictationSessionID) async {}
}

private actor TestInsertion: TextInserting {
    private let outcome: InsertionOutcome
    private var texts: [String] = []

    init(outcome: InsertionOutcome) {
        self.outcome = outcome
    }

    func insert(
        _ candidate: FinalCandidate,
        sessionID: DictationSessionID
    ) async throws -> InsertionOutcome {
        texts.append(candidate.text)
        return outcome
    }

    func requestCancellation(
        sessionID: DictationSessionID
    ) async -> InsertionCancellationDisposition {
        .cancelledBeforeCommit
    }

    func releaseInsertionSession(sessionID: DictationSessionID) async {}

    func insertedTexts() -> [String] { texts }
}

private actor RecordingCloudTransport: CloudTextTransport {
    private let result: Result<String, Error>
    private var calls = 0

    init(result: Result<String, Error>) {
        self.result = result
    }

    func enrich(
        request: CloudEnrichmentRequest,
        apiKey: SecretAPIKey,
        model: CloudModelIdentifier
    ) async throws -> String {
        calls += 1
        return try result.get()
    }

    func callCount() -> Int { calls }
}

private actor TestKeyStore: APIKeyStoring {
    private var key: SecretAPIKey?

    init(hasKey: Bool) {
        key = hasKey ? try! SecretAPIKey("sk-test-redacted-value") : nil
    }

    func save(_ key: SecretAPIKey) async throws { self.key = key }
    func read() async throws -> SecretAPIKey? { key }
    func delete() async throws { key = nil }
}

private struct FailingCleanup: TextCleaning {
    func clean(
        _ transcript: RawTranscript,
        context: ContextSnapshot,
        sessionID: DictationSessionID
    ) async throws -> LocalCandidate {
        throw TestError.expected
    }
}

private actor LifecycleProbe {
    private(set) var contextCancelCount = 0
    private(set) var audioCancelCount = 0
    private(set) var recognizerCancelCount = 0
    private(set) var enrichmentCancelCount = 0
    private(set) var insertionCancelCount = 0

    func contextCancelled() { contextCancelCount += 1 }
    func audioCancelled() { audioCancelCount += 1 }
    func recognizerCancelled() { recognizerCancelCount += 1 }
    func enrichmentCancelled() { enrichmentCancelCount += 1 }
    func insertionCancelled() { insertionCancelCount += 1 }

    func cancellationCounts() -> [Int] {
        [
            contextCancelCount,
            audioCancelCount,
            recognizerCancelCount,
            enrichmentCancelCount,
            insertionCancelCount
        ]
    }
}

private struct ProbedContextProvider: TargetContextProviding {
    let probe: LifecycleProbe
    func capture(for sessionID: DictationSessionID) async throws -> CapturedTargetContext {
        CapturedTargetContext(
            target: testTarget(sessionID),
            context: .unavailable(targetKind: .unknown)
        )
    }
    func cancel(sessionID: DictationSessionID) async { await probe.contextCancelled() }
}

private struct ProbedAudioCapture: AudioCapturing {
    let probe: LifecycleProbe
    func startCapture(for sessionID: DictationSessionID) async throws {}
    func finishCapture(for sessionID: DictationSessionID) async throws -> AudioInput {
        AudioInput(buffer: AudioBufferHandle(rawValue: sessionID.rawValue))
    }
    func cancelCapture(for sessionID: DictationSessionID) async { await probe.audioCancelled() }
    func release(_ input: AudioInput) async {}
}

private struct ProbedRecognizer: SpeechRecognizing {
    let probe: LifecycleProbe
    let text: String
    func transcribe(
        _ audio: AudioInput,
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws -> RawTranscript {
        RawTranscript(text: text, language: hints.language)
    }
    func cancel(sessionID: DictationSessionID) async { await probe.recognizerCancelled() }
}

private struct ProbedEnrichment: TextEnriching {
    let probe: LifecycleProbe
    func enrich(
        _ candidate: LocalCandidate,
        context: ContextSnapshot,
        consent: ConsentSnapshot,
        sessionID: DictationSessionID
    ) async throws -> EnrichedCandidate {
        EnrichedCandidate(text: candidate.text)
    }
    func cancel(sessionID: DictationSessionID) async { await probe.enrichmentCancelled() }
}

private struct ProbedInsertion: TextInserting {
    let probe: LifecycleProbe
    func insert(
        _ candidate: FinalCandidate,
        sessionID: DictationSessionID
    ) async throws -> InsertionOutcome { .confirmedDirect }
    func requestCancellation(
        sessionID: DictationSessionID
    ) async -> InsertionCancellationDisposition {
        .cancelledBeforeCommit
    }
    func releaseInsertionSession(sessionID: DictationSessionID) async {
        await probe.insertionCancelled()
    }
}

private func testTarget(_ sessionID: DictationSessionID) -> TargetSnapshot {
    TargetSnapshot(
        processIdentifier: 1,
        token: TargetToken(rawValue: sessionID.rawValue),
        selectionFingerprint: SelectionFingerprint(rawValue: sessionID.rawValue),
        sessionID: sessionID
    )
}

private enum TestError: Error {
    case expected
    case unexpectedStart
}
