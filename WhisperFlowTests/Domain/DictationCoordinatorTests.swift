import XCTest
@testable import WhisperFlow

final class DictationCoordinatorTests: XCTestCase, @unchecked Sendable {
    func testStartsIdle() async {
        let coordinator = makeCoordinator()

        let snapshot = await coordinator.snapshot()

        XCTAssertEqual(snapshot, DictationSnapshot(phase: .idle, activeSessionID: nil))
    }

    func testStartRequiresARegisteredEditableTextTarget() async {
        let audio = CountingAudioCapture()
        let coordinator = makeCoordinator(
            contextProvider: UnavailableTargetContextProvider(),
            audioCapture: audio
        )

        let outcome = await coordinator.start()
        let sessionID = outcome.sessionID
        let audioStartCount = await audio.startCount()

        XCTAssertEqual(
            outcome,
            .failed(sessionID, DictationFailure(stage: .context))
        )
        XCTAssertEqual(audioStartCount, 0)
    }

    func testStartRejectsProtectedTextTargetsBeforeRecording() async {
        let audio = CountingAudioCapture()
        let coordinator = makeCoordinator(
            contextProvider: SensitiveTargetContextProvider(),
            audioCapture: audio
        )

        let outcome = await coordinator.start()
        let sessionID = outcome.sessionID
        let audioStartCount = await audio.startCount()

        XCTAssertEqual(
            outcome,
            .failed(sessionID, DictationFailure(stage: .context))
        )
        XCTAssertEqual(audioStartCount, 0)
    }

    func testAudioWaitsForInitialTargetCaptureBeforeRecording() async {
        let captureStarted = AsyncGate()
        let releaseCapture = AsyncGate()
        let context = GatedContextProvider(started: captureStarted, release: releaseCapture)
        let audio = CountingAudioCapture()
        let coordinator = makeCoordinator(
            contextProvider: context,
            audioCapture: audio
        )

        let startTask = Task { await coordinator.start(language: .german) }
        await captureStarted.wait()
        let audioStartCount = await audio.startCount()
        let primingSnapshot = await coordinator.snapshot()

        XCTAssertEqual(audioStartCount, 0)
        XCTAssertEqual(primingSnapshot.phase, .priming)
        XCTAssertNotNil(primingSnapshot.activeSessionID)

        await releaseCapture.open()
        let sessionID = startedSessionID(await startTask.value)
        let listeningSnapshot = await coordinator.snapshot()
        let finalAudioStartCount = await audio.startCount()

        XCTAssertEqual(
            listeningSnapshot,
            DictationSnapshot(phase: .listening, activeSessionID: sessionID)
        )
        XCTAssertEqual(finalAudioStartCount, 1)
        _ = await coordinator.cancel(sessionID: sessionID)
    }

    func testAudioStartsBeforeSlowContextEnrichmentAndQuickDictationStillCompletes() async {
        let enrichmentStarted = AsyncGate()
        let releaseEnrichment = AsyncGate()
        let context = SplitGatedContextProvider(
            enrichmentStarted: enrichmentStarted,
            releaseEnrichment: releaseEnrichment
        )
        let audio = CountingAudioCapture()
        let coordinator = makeCoordinator(
            contextProvider: context,
            audioCapture: audio
        )

        let sessionID = startedSessionID(await coordinator.start(language: .german))
        await enrichmentStarted.wait()
        let startCount = await audio.startCount()
        let snapshot = await coordinator.snapshot()
        let recordingStartDate = await coordinator.recordingStartDate(for: sessionID)

        XCTAssertEqual(startCount, 1)
        XCTAssertNotNil(recordingStartDate)
        XCTAssertEqual(
            snapshot,
            DictationSnapshot(phase: .listening, activeSessionID: sessionID)
        )

        let stopTask = Task { await coordinator.stop(sessionID: sessionID) }
        await releaseEnrichment.open()
        let outcome = await stopTask.value

        XCTAssertEqual(outcome, .completed(sessionID, .confirmedDirect))
    }

    func testLocalPipelineCompletesWithConfirmedInsertion() async {
        let insertion = RecordingInsertion()
        let coordinator = makeCoordinator(insertion: insertion)
        let sessionID = startedSessionID(await coordinator.start(language: .german))
        let listeningSnapshot = await coordinator.snapshot()

        XCTAssertEqual(
            listeningSnapshot,
            DictationSnapshot(phase: .listening, activeSessionID: sessionID)
        )

        let outcome = await coordinator.stop(sessionID: sessionID)
        let successSnapshot = await coordinator.snapshot()
        let insertionCount = await insertion.count()
        let candidates = await insertion.candidates()

        XCTAssertEqual(outcome, .completed(sessionID, .confirmedDirect))
        XCTAssertEqual(
            successSnapshot,
            DictationSnapshot(phase: .success, activeSessionID: nil)
        )
        XCTAssertEqual(insertionCount, 1)
        XCTAssertEqual(candidates, [.local(LocalCandidate(text: "hello"))])
    }

    func testFinalizedAudioIsPersistedBeforeTranscriptVersion() async {
        let history = RecordingHistorySpy()
        let coordinator = makeCoordinator(recordingHistory: history)
        let sessionID = startedSessionID(await coordinator.start(language: .german))

        _ = await coordinator.stop(sessionID: sessionID)
        let events = await history.events()

        XCTAssertEqual(
            events,
            ["begin:german", "audio", "raw:hello", "final:hello", "complete"]
        )
    }

    func testCorrectedCandidatePersistsFinalTextAfterRawTranscript() async {
        let history = RecordingHistorySpy()
        let coordinator = makeCoordinator(
            cleanup: CorrectingCleanup(text: "corrected"),
            recordingHistory: history
        )
        let sessionID = startedSessionID(await coordinator.start(language: .german))

        let outcome = await coordinator.stop(sessionID: sessionID)
        let events = await history.events()

        XCTAssertEqual(outcome, .completed(sessionID, .confirmedDirect))
        XCTAssertEqual(
            events,
            ["begin:german", "audio", "raw:hello", "final:corrected", "complete"]
        )
    }

    func testInsertionFailureRetainsFinalTextBeforeMarkingHistoryFailed() async {
        let history = RecordingHistorySpy()
        let coordinator = makeCoordinator(
            cleanup: CorrectingCleanup(text: "corrected"),
            insertion: FailingInsertion(),
            recordingHistory: history
        )
        let sessionID = startedSessionID(await coordinator.start(language: .german))

        let outcome = await coordinator.stop(sessionID: sessionID)
        let events = await history.events()

        XCTAssertEqual(outcome, .failed(sessionID, DictationFailure(stage: .insertion)))
        XCTAssertEqual(
            events,
            ["begin:german", "audio", "raw:hello", "final:corrected", "failed"]
        )
    }

    func testRecognitionFailureKeepsPersistedAudioMarkedFailed() async {
        let history = RecordingHistorySpy()
        let coordinator = makeCoordinator(
            recognizer: FailingRecognizer(),
            recordingHistory: history
        )
        let sessionID = startedSessionID(await coordinator.start())

        _ = await coordinator.stop(sessionID: sessionID)
        let events = await history.events()

        XCTAssertEqual(events, ["begin:automatic", "audio", "failed"])
    }

    func testProductASRDeadlineFailsCurrentSessionAndPreservesHistoryAudio() async {
        let large = NeverCompletingCoordinatorRecognizer()
        let adaptive = AdaptiveWhisperKitRecognizer(
            turbo: LowQualityCoordinatorRecognizer(),
            large: large
        )
        let router = SessionModelSpeechRecognizer(
            recognizers: [.adaptive: adaptive],
            productASRDeadline: .milliseconds(30),
            productASRCancellationGrace: .milliseconds(10)
        )
        let history = RecordingHistorySpy()
        let coordinator = makeCoordinator(
            recognizer: router,
            recordingHistory: history
        )
        let sessionID = startedSessionID(await coordinator.start())
        await router.register(.adaptive, for: sessionID)

        let outcome = await coordinator.stop(sessionID: sessionID)
        let snapshot = await coordinator.snapshot()
        let events = await history.events()
        let largeInvocationCount = await large.transcriptionCount()
        let largeCancellationCount = await large.cancellationCount()

        XCTAssertEqual(
            outcome,
            .failed(
                sessionID,
                DictationFailure(stage: .recognition, reason: .recognitionTimedOut)
            )
        )
        XCTAssertEqual(
            snapshot,
            DictationSnapshot(
                phase: .error(
                    DictationFailure(stage: .recognition, reason: .recognitionTimedOut)
                ),
                activeSessionID: nil
            )
        )
        XCTAssertEqual(events, ["begin:automatic", "audio", "failed"])
        XCTAssertEqual(largeInvocationCount, 1)
        XCTAssertGreaterThanOrEqual(largeCancellationCount, 1)
    }

    func testEmptyFinalizedRecordingReturnsNoSpeechAndLeavesNoHistoryEntry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let historyStore = RecordingHistoryStore(rootURL: root)
        let sampleStore = AudioBufferStore()
        let audio = EmptyStoredAudioCapture(store: sampleStore)
        let recognizer = CountingBorrowingRecognizer()
        let history = RecordingHistoryRecorder(store: historyStore, sampleAccess: sampleStore)
        let coordinator = makeCoordinator(
            audioCapture: audio,
            recognizer: recognizer,
            recordingHistory: history
        )
        let sessionID = startedSessionID(await coordinator.start())

        let outcome = await coordinator.stop(sessionID: sessionID)
        let entries = try await historyStore.list()
        let transcriptionCount = await recognizer.transcriptionCount()

        XCTAssertEqual(outcome, .noSpeech(sessionID))
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(transcriptionCount, 0)
    }

    func testHistoryBeginFailureDoesNotStopCaptureAndWarnsOnce() async {
        let audio = CountingAudioCapture()
        let warning = HistoryFailureCounter()
        let coordinator = makeCoordinator(
            audioCapture: audio,
            recordingHistory: FailingRecordingHistory(stage: .begin)
        )
        await coordinator.setRecordingHistoryFailureHandler { sessionID in
            await warning.record(sessionID)
        }

        let outcome = await coordinator.start()
        let sessionID = outcome.sessionID

        XCTAssertEqual(outcome, .started(sessionID))
        let cancellationCount = await audio.cancelCount()
        let warningCount = await warning.count()
        XCTAssertEqual(cancellationCount, 0)
        XCTAssertEqual(warningCount, 1)
        _ = await coordinator.cancel(sessionID: sessionID)
    }

    func testAudioPersistenceFailureContinuesRecognitionAndWarnsOnce() async {
        let recognizer = CountingBorrowingRecognizer()
        let warning = HistoryFailureCounter()
        let coordinator = makeCoordinator(
            recognizer: recognizer,
            recordingHistory: FailingRecordingHistory(stage: .audio)
        )
        await coordinator.setRecordingHistoryFailureHandler { sessionID in
            await warning.record(sessionID)
        }
        let sessionID = startedSessionID(await coordinator.start())

        let outcome = await coordinator.stop(sessionID: sessionID)

        XCTAssertEqual(outcome, .completed(sessionID, .confirmedDirect))
        let transcriptionCount = await recognizer.transcriptionCount()
        let warningCount = await warning.count()
        XCTAssertEqual(transcriptionCount, 1)
        XCTAssertEqual(warningCount, 1)
    }

    func testTranscriptPersistenceFailureContinuesInsertionAndWarnsOnce() async {
        let insertion = RecordingInsertion()
        let warning = HistoryFailureCounter()
        let coordinator = makeCoordinator(
            insertion: insertion,
            recordingHistory: FailingRecordingHistory(stage: .transcript)
        )
        await coordinator.setRecordingHistoryFailureHandler { sessionID in
            await warning.record(sessionID)
        }
        let sessionID = startedSessionID(await coordinator.start())

        let outcome = await coordinator.stop(sessionID: sessionID)

        XCTAssertEqual(outcome, .completed(sessionID, .confirmedDirect))
        let insertionCount = await insertion.count()
        let warningCount = await warning.count()
        XCTAssertEqual(insertionCount, 1)
        XCTAssertEqual(warningCount, 1)
    }

    func testFailureStatePersistenceFailureDoesNotReplacePrimaryFailure() async {
        let warning = HistoryFailureCounter()
        let coordinator = makeCoordinator(
            recognizer: FailingRecognizer(),
            recordingHistory: FailingRecordingHistory(stage: .markFailed)
        )
        await coordinator.setRecordingHistoryFailureHandler { sessionID in
            await warning.record(sessionID)
        }
        let sessionID = startedSessionID(await coordinator.start())

        let outcome = await coordinator.stop(sessionID: sessionID)
        let warningCount = await warning.count()

        XCTAssertEqual(outcome, .failed(sessionID, DictationFailure(stage: .recognition)))
        XCTAssertEqual(warningCount, 1)
    }

    func testCancellationPersistenceFailureRemainsCancellation() async {
        let warning = HistoryFailureCounter()
        let coordinator = makeCoordinator(
            recordingHistory: FailingRecordingHistory(stage: .interrupt)
        )
        await coordinator.setRecordingHistoryFailureHandler { sessionID in
            await warning.record(sessionID)
        }
        let sessionID = startedSessionID(await coordinator.start())

        let outcome = await coordinator.cancel(sessionID: sessionID)
        let snapshot = await coordinator.snapshot()
        let warningCount = await warning.count()

        XCTAssertEqual(
            outcome,
            .cancelled(sessionID)
        )
        XCTAssertEqual(
            snapshot,
            DictationSnapshot(
                phase: .cancelled,
                activeSessionID: nil
            )
        )
        XCTAssertEqual(warningCount, 1)
    }

    func testTerminalHistoryWritesRetryBeforeSessionResourcesAreReleased() async {
        let failedHistory = TransientTerminalWriteRecordingHistory(
            terminal: .failed,
            failuresBeforeSuccess: 2
        )
        let failedCoordinator = makeCoordinator(
            recognizer: FailingRecognizer(),
            recordingHistory: failedHistory
        )
        let failedSessionID = startedSessionID(await failedCoordinator.start())

        let failedOutcome = await failedCoordinator.stop(sessionID: failedSessionID)
        let failedAttempts = await failedHistory.terminalAttemptCount()

        XCTAssertEqual(
            failedOutcome,
            .failed(failedSessionID, DictationFailure(stage: .recognition))
        )
        XCTAssertEqual(failedAttempts, 3)

        let interruptedHistory = TransientTerminalWriteRecordingHistory(
            terminal: .interrupted,
            failuresBeforeSuccess: 2
        )
        let interruptedCoordinator = makeCoordinator(recordingHistory: interruptedHistory)
        let interruptedSessionID = startedSessionID(await interruptedCoordinator.start())

        let interruptedOutcome = await interruptedCoordinator.cancel(sessionID: interruptedSessionID)
        let interruptedAttempts = await interruptedHistory.terminalAttemptCount()

        XCTAssertEqual(interruptedOutcome, .cancelled(interruptedSessionID))
        XCTAssertEqual(interruptedAttempts, 3)
    }

    func testPersistentTerminalHistoryFailureWarnsOnceAndReleasesTracking() async {
        let warning = HistoryFailureCounter()
        let history = PersistentTerminalWriteRecordingHistory()
        let coordinator = makeCoordinator(
            recognizer: FailingRecognizer(),
            recordingHistory: history
        )
        await coordinator.setRecordingHistoryFailureHandler { sessionID in
            await warning.record(sessionID)
        }
        let sessionID = startedSessionID(await coordinator.start())

        let outcome = await coordinator.stop(sessionID: sessionID)
        let terminalAttempts = await history.terminalAttempts()
        let releaseAttempts = await history.releaseAttempts()
        let warningCount = await warning.count()

        XCTAssertEqual(outcome, .failed(sessionID, DictationFailure(stage: .recognition)))
        XCTAssertEqual(terminalAttempts, 3)
        XCTAssertEqual(releaseAttempts, 1)
        XCTAssertEqual(warningCount, 1)
    }

    func testIncrementalRecognitionStopsBeforeCanonicalFinalDecode() async {
        let firstUpdate = AsyncGate()
        let audio = StreamingAudioCapture()
        let recognizer = StreamingLifecycleRecognizer(firstUpdate: firstUpdate)
        let coordinator = makeCoordinator(
            audioCapture: audio,
            recognizer: recognizer
        )
        let sessionID = startedSessionID(await coordinator.start(language: .german))

        await coordinator.beginIncrementalRecognition(sessionID: sessionID)
        await firstUpdate.wait()
        let outcome = await coordinator.stop(sessionID: sessionID)
        let events = await recognizer.recordedEvents()

        XCTAssertEqual(outcome, .completed(sessionID, .confirmedDirect))
        XCTAssertEqual(events, ["start", "update", "stop", "finalize", "cancel"])
    }

    func testCancellationDrainsCheckpointProducerBeforeInterruptingHistory() async {
        let checkpointStarted = AsyncGate()
        let releaseCheckpoint = AsyncGate()
        let recognitionStopped = AsyncGate()
        let history = GatedCheckpointRecordingHistory(
            checkpointStarted: checkpointStarted,
            releaseCheckpoint: releaseCheckpoint
        )
        let coordinator = makeCoordinator(
            audioCapture: StreamingAudioCapture(),
            recognizer: StreamingLifecycleRecognizer(
                firstUpdate: AsyncGate(),
                recognitionStopped: recognitionStopped
            ),
            recordingHistory: history
        )
        let sessionID = startedSessionID(await coordinator.start(language: .german))

        await coordinator.beginIncrementalRecognition(sessionID: sessionID)
        await checkpointStarted.wait()
        let cancellation = Task { await coordinator.cancel(sessionID: sessionID) }
        await recognitionStopped.wait()
        let eventsBeforeCheckpointRelease = await history.events()

        XCTAssertEqual(eventsBeforeCheckpointRelease, ["begin", "checkpointStarted"])

        await releaseCheckpoint.open()
        let outcome = await cancellation.value
        let finalEvents = await history.events()

        XCTAssertEqual(outcome, .cancelled(sessionID))
        XCTAssertEqual(
            finalEvents,
            ["begin", "checkpointStarted", "checkpointFinished", "interrupted"]
        )
    }

    func testCheckpointPersistenceFailureInvokesFatalHistoryHandler() async {
        let firstUpdate = AsyncGate()
        let historyFailure = AsyncGate()
        let audio = StreamingAudioCapture()
        let coordinator = makeCoordinator(
            audioCapture: audio,
            recognizer: StreamingLifecycleRecognizer(firstUpdate: firstUpdate),
            recordingHistory: FailingRecordingHistory(stage: .checkpoint)
        )
        await coordinator.setRecordingHistoryFailureHandler { _ in
            await historyFailure.open()
        }
        let sessionID = startedSessionID(await coordinator.start(language: .german))

        await coordinator.beginIncrementalRecognition(sessionID: sessionID)
        await historyFailure.wait()

        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.activeSessionID, sessionID)
        _ = await coordinator.cancel(sessionID: sessionID)
    }

    func testFastSpeechReleaseFinalDecodesWhenStreamingHasNoAudioYet() async {
        let audio = StreamingAudioCapture()
        let recognizer = FastReleaseLifecycleRecognizer()
        let insertion = RecordingInsertion()
        let coordinator = makeCoordinator(
            audioCapture: audio,
            recognizer: recognizer,
            insertion: insertion
        )
        let sessionID = startedSessionID(await coordinator.start(language: .german))

        await coordinator.beginIncrementalRecognition(sessionID: sessionID)
        let outcome = await coordinator.stop(sessionID: sessionID)
        let events = await recognizer.recordedEvents()
        let candidates = await insertion.candidates()

        XCTAssertEqual(outcome, .completed(sessionID, .confirmedDirect))
        XCTAssertTrue(events.contains("stop"))
        XCTAssertTrue(events.contains("transcribe"))
        XCTAssertFalse(events.contains("update"))
        XCTAssertFalse(events.contains("finalize"))
        XCTAssertEqual(candidates, [.local(LocalCandidate(text: "schneller test"))])
    }

    func testSilentCaptureStopsBeforeASROrInsertion() async {
        let audio = SilentAudioCapture()
        let recognizer = CountingBorrowingRecognizer()
        let insertion = RecordingInsertion()
        let coordinator = makeCoordinator(
            audioCapture: audio,
            recognizer: recognizer,
            insertion: insertion
        )
        let sessionID = startedSessionID(await coordinator.start())

        let outcome = await coordinator.stop(sessionID: sessionID)
        let transcriptionCount = await recognizer.transcriptionCount()
        let insertionCount = await insertion.count()
        let releaseCount = await audio.releaseCount()
        let snapshot = await coordinator.snapshot()

        XCTAssertEqual(outcome, .noSpeech(sessionID))
        XCTAssertEqual(transcriptionCount, 0)
        XCTAssertEqual(insertionCount, 0)
        XCTAssertEqual(releaseCount, 1)
        XCTAssertEqual(
            snapshot,
            DictationSnapshot(phase: .success, activeSessionID: nil)
        )
    }

    func testSoftSpeechNotDetectedByVadStillTranscribes() async {
        let audio = BorderlineVADAudioCapture()
        let recognizer = CountingBorrowingRecognizer()
        let insertion = RecordingInsertion()
        let coordinator = makeCoordinator(
            audioCapture: audio,
            recognizer: recognizer,
            insertion: insertion
        )
        let sessionID = startedSessionID(await coordinator.start())

        let outcome = await coordinator.stop(sessionID: sessionID)
        let transcriptionCount = await recognizer.transcriptionCount()
        let insertionCount = await insertion.count()

        XCTAssertEqual(outcome, .completed(sessionID, .confirmedDirect))
        XCTAssertEqual(transcriptionCount, 1)
        XCTAssertEqual(insertionCount, 1)
    }

    func testRecognizerEmptyResultIsPresentedAsNoSpeechInsteadOfUnavailable() async {
        let audio = StoredAudioCapture()
        let insertion = RecordingInsertion()
        let coordinator = makeCoordinator(
            audioCapture: audio,
            recognizer: EmptyResultRecognizer(),
            insertion: insertion
        )
        let sessionID = startedSessionID(await coordinator.start())

        let outcome = await coordinator.stop(sessionID: sessionID)
        let releaseCount = await audio.releaseCount()
        let insertionCount = await insertion.count()

        XCTAssertEqual(outcome, .noSpeech(sessionID))
        XCTAssertEqual(releaseCount, 1)
        XCTAssertEqual(insertionCount, 0)
    }

    func testLocalOnlyUsesValidatedOnDeviceRewriteBeforeInsertion() async {
        let insertion = RecordingInsertion()
        let rewriter = RecordingTextRewriter(output: "Hallo Welt.")
        let coordinator = makeCoordinator(
            localRewriter: rewriter,
            insertion: insertion
        )
        let sessionID = startedSessionID(await coordinator.start(language: .german))

        let outcome = await coordinator.stop(sessionID: sessionID)
        let candidates = await insertion.candidates()
        let rewriteCount = await rewriter.rewriteCount()

        XCTAssertEqual(outcome, .completed(sessionID, .confirmedDirect))
        XCTAssertEqual(
            candidates,
            [.local(LocalCandidate(text: "Hallo Welt."))]
        )
        XCTAssertEqual(rewriteCount, 1)

        let highConfidenceInsertion = RecordingInsertion()
        let highConfidenceRewriter = RecordingTextRewriter(output: "Nicht verwenden.")
        let highConfidenceCoordinator = makeCoordinator(
            recognizer: MetadataRecognizer(
                text: "Hallo Welt.",
                avgLogprob: -0.1,
                minWordProbability: 0.95,
                compressionRatio: 1.0,
                decoderFallback: RecognitionDecoderFallback.none
            ),
            localRewriter: highConfidenceRewriter,
            insertion: highConfidenceInsertion
        )
        let highConfidenceSessionID = startedSessionID(
            await highConfidenceCoordinator.start(language: .german)
        )

        let highConfidenceOutcome = await highConfidenceCoordinator.stop(
            sessionID: highConfidenceSessionID
        )
        let highConfidenceCandidates = await highConfidenceInsertion.candidates()
        let highConfidenceRewriteCount = await highConfidenceRewriter.rewriteCount()

        XCTAssertEqual(
            highConfidenceOutcome,
            .completed(highConfidenceSessionID, .confirmedDirect)
        )
        XCTAssertEqual(
            highConfidenceCandidates,
            [.local(LocalCandidate(text: "Hallo Welt."))]
        )
        XCTAssertEqual(highConfidenceRewriteCount, 0)

        let subordinateInsertion = RecordingInsertion()
        let subordinateRewriter = RecordingTextRewriter(output: "Nicht verwenden.")
        let subordinateCoordinator = makeCoordinator(
            recognizer: MetadataRecognizer(
                text: "Also wenn wir das nochmal testen, kannst du auch gleich gucken, ob die Formatierung stimmt.",
                avgLogprob: -0.1,
                minWordProbability: 0.95,
                compressionRatio: 1.0,
                decoderFallback: RecognitionDecoderFallback.none
            ),
            cleanup: DeterministicCleanupEngine(),
            localRewriter: subordinateRewriter,
            insertion: subordinateInsertion
        )
        let subordinateSessionID = startedSessionID(
            await subordinateCoordinator.start(language: .german)
        )

        let subordinateOutcome = await subordinateCoordinator.stop(
            sessionID: subordinateSessionID
        )
        let subordinateCandidates = await subordinateInsertion.candidates()
        let subordinateRewriteCount = await subordinateRewriter.rewriteCount()

        XCTAssertEqual(
            subordinateOutcome,
            .completed(subordinateSessionID, .confirmedDirect)
        )
        XCTAssertEqual(
            subordinateCandidates,
            [.local(LocalCandidate(
                text: "Wenn wir das noch einmal testen, kannst du auch gleich gucken, ob die Formatierung stimmt."
            ))]
        )
        XCTAssertEqual(subordinateRewriteCount, 0)

        let rewriteRequiredCases: [(String, RawTranscript)] = [
            (
                "low average logprob",
                RawTranscript(
                    text: "Hallo Welt.",
                    language: .german,
                    avgLogprob: -0.6,
                    minWordProbability: 0.95,
                    compressionRatio: 1.0,
                    decoderFallback: RecognitionDecoderFallback.none
                )
            ),
            (
                "unknown confidence",
                RawTranscript(text: "Hallo Welt.", language: .german)
            ),
            (
                "backtracking",
                RawTranscript(
                    text: "Wir testen wir testen das.",
                    language: .german,
                    avgLogprob: -0.1,
                    minWordProbability: 0.95,
                    compressionRatio: 1.0,
                    decoderFallback: RecognitionDecoderFallback.none
                )
            ),
            (
                "fragment",
                RawTranscript(
                    text: "Und dann",
                    language: .german,
                    avgLogprob: -0.1,
                    minWordProbability: 0.95,
                    compressionRatio: 1.0,
                    decoderFallback: RecognitionDecoderFallback.none
                )
            ),
            (
                "raw subordinate fragment",
                RawTranscript(
                    text: "weil der Build",
                    language: .german,
                    avgLogprob: -0.1,
                    minWordProbability: 0.95,
                    compressionRatio: 1.0,
                    decoderFallback: RecognitionDecoderFallback.none
                )
            ),
            (
                "nil decoder metadata",
                RawTranscript(
                    text: "Hallo Welt.",
                    language: .german,
                    avgLogprob: -0.1,
                    minWordProbability: 0.95,
                    compressionRatio: 1.0,
                    decoderFallback: nil
                )
            )
        ]
        for (label, transcript) in rewriteRequiredCases {
            let requiredInsertion = RecordingInsertion()
            let requiredRewriter = RecordingTextRewriter(output: "Rewritten \(label).")
            let requiredCoordinator = makeCoordinator(
                recognizer: MetadataRecognizer(transcript: transcript),
                localRewriter: requiredRewriter,
                insertion: requiredInsertion
            )
            let requiredSessionID = startedSessionID(
                await requiredCoordinator.start(language: .german)
            )

            let requiredOutcome = await requiredCoordinator.stop(sessionID: requiredSessionID)
            let requiredCandidates = await requiredInsertion.candidates()
            let requiredRewriteCount = await requiredRewriter.rewriteCount()

            XCTAssertEqual(
                requiredOutcome,
                .completed(requiredSessionID, .confirmedDirect),
                label
            )
            XCTAssertEqual(
                requiredCandidates,
                [.local(LocalCandidate(text: "Rewritten \(label)."))],
                label
            )
            XCTAssertEqual(requiredRewriteCount, 1, label)
        }

        let contextInsertion = RecordingInsertion()
        let contextRewriter = RecordingTextRewriter(output: "Rewritten context dependent.")
        let contextCoordinator = makeCoordinator(
            contextProvider: StaticContextProvider(
                context: ContextSnapshot(
                    availability: .available,
                    targetKind: .chat,
                    boundedText: "Projekt: Nebelstern",
                    termHints: [],
                    localCategory: .workMessaging
                )
            ),
            recognizer: MetadataRecognizer(
                text: "Prüfe das Projekt erneut.",
                avgLogprob: -0.1,
                minWordProbability: 0.95,
                compressionRatio: 1.0,
                decoderFallback: RecognitionDecoderFallback.none
            ),
            localRewriter: contextRewriter,
            insertion: contextInsertion
        )
        let contextSessionID = startedSessionID(
            await contextCoordinator.start(language: .german)
        )

        let contextOutcome = await contextCoordinator.stop(sessionID: contextSessionID)
        let contextCandidates = await contextInsertion.candidates()
        let contextRewriteCount = await contextRewriter.rewriteCount()

        XCTAssertEqual(
            contextOutcome,
            .completed(contextSessionID, .confirmedDirect)
        )
        XCTAssertEqual(
            contextCandidates,
            [.local(LocalCandidate(text: "Rewritten context dependent."))]
        )
        XCTAssertEqual(contextRewriteCount, 1)
    }

    func testCloudSuccessRunsCloudAsTheOnlyPrimaryRewriter() async {
        let insertion = RecordingInsertion()
        let localRewriter = RecordingTextRewriter(output: "local")
        let coordinator = makeCoordinator(
            localRewriter: localRewriter,
            insertion: insertion
        )
        let sessionID = startedSessionID(await coordinator.start())

        let outcome = await coordinator.stop(
            sessionID: sessionID,
            consent: ConsentSnapshot(cloudEnabled: true, contextToCloud: false)
        )
        let rewriteCount = await localRewriter.rewriteCount()
        let candidates = await insertion.candidates()

        XCTAssertEqual(outcome, .completed(sessionID, .confirmedDirect))
        XCTAssertEqual(rewriteCount, 0)
        XCTAssertEqual(
            candidates,
            [.enriched(
                EnrichedCandidate(text: "hello"),
                localFallback: LocalCandidate(text: "hello")
            )]
        )
    }

    func testDuplicateStartReusesActiveSessionWithoutStartingAudioTwice() async {
        let audio = CountingAudioCapture()
        let coordinator = makeCoordinator(audioCapture: audio)
        let sessionID = startedSessionID(await coordinator.start())

        let duplicateOutcome = await coordinator.start()
        let startCount = await audio.startCount()

        XCTAssertEqual(duplicateOutcome, .alreadyActive(sessionID))
        XCTAssertEqual(startCount, 1)
        _ = await coordinator.cancel(sessionID: sessionID)
    }

    func testStaleStopCannotMutateReplacementSession() async {
        let insertion = RecordingInsertion()
        let coordinator = makeCoordinator(insertion: insertion)
        let oldSessionID = startedSessionID(await coordinator.start())
        let oldCancelOutcome = await coordinator.cancel(sessionID: oldSessionID)
        XCTAssertEqual(oldCancelOutcome, .cancelled(oldSessionID))

        let currentSessionID = startedSessionID(await coordinator.start())
        let staleOutcome = await coordinator.stop(sessionID: oldSessionID)
        let currentSnapshot = await coordinator.snapshot()
        let insertionCount = await insertion.count()

        XCTAssertEqual(staleOutcome, .ignoredStale(oldSessionID))
        XCTAssertEqual(
            currentSnapshot,
            DictationSnapshot(phase: .listening, activeSessionID: currentSessionID)
        )
        XCTAssertEqual(insertionCount, 0)
        _ = await coordinator.cancel(sessionID: currentSessionID)
    }

    func testCancelWinsAgainstLateRecognitionAndPreventsInsertion() async {
        let recognitionStarted = AsyncGate()
        let releaseRecognition = AsyncGate()
        let recognizer = GatedRecognizer(started: recognitionStarted, release: releaseRecognition)
        let insertion = RecordingInsertion()
        let coordinator = makeCoordinator(recognizer: recognizer, insertion: insertion)
        let oldSessionID = startedSessionID(await coordinator.start())

        let oldStop = Task {
            await coordinator.stop(sessionID: oldSessionID)
        }
        await recognitionStarted.wait()
        let transcribingSnapshot = await coordinator.snapshot()

        XCTAssertEqual(
            transcribingSnapshot,
            DictationSnapshot(phase: .transcribing, activeSessionID: oldSessionID)
        )
        let cancelOutcome = await coordinator.cancel(sessionID: oldSessionID)
        XCTAssertEqual(cancelOutcome, .cancelled(oldSessionID))

        let currentSessionID = startedSessionID(await coordinator.start())
        await releaseRecognition.open()
        let oldOutcome = await oldStop.value
        let currentSnapshot = await coordinator.snapshot()
        let insertionCount = await insertion.count()

        XCTAssertEqual(oldOutcome, .ignoredStale(oldSessionID))
        XCTAssertEqual(
            currentSnapshot,
            DictationSnapshot(phase: .listening, activeSessionID: currentSessionID)
        )
        XCTAssertEqual(insertionCount, 0)
        _ = await coordinator.cancel(sessionID: currentSessionID)
    }

    func testCancelDuringBlockedRecognitionPreservesFinalizedHistoryAudio() async throws {
        let recognitionStarted = AsyncGate()
        let releaseRecognition = AsyncGate()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let historyStore = RecordingHistoryStore(rootURL: root)
        let sampleStore = AudioBufferStore()
        let audio = StoredAudioCapture(store: sampleStore)
        let history = RecordingHistoryRecorder(store: historyStore, sampleAccess: sampleStore)
        let coordinator = makeCoordinator(
            audioCapture: audio,
            recognizer: GatedRecognizer(started: recognitionStarted, release: releaseRecognition),
            recordingHistory: history
        )
        let sessionID = startedSessionID(await coordinator.start())
        let stopTask = Task { await coordinator.stop(sessionID: sessionID) }
        await recognitionStarted.wait()

        let cancelOutcome = await coordinator.cancel(sessionID: sessionID)
        await releaseRecognition.open()
        _ = await stopTask.value
        let entries = try await historyStore.list()
        let entry = try XCTUnwrap(entries.first)
        let recoveredAudio = try await historyStore.loadAudio(for: entry.id)

        XCTAssertEqual(cancelOutcome, .cancelled(sessionID))
        XCTAssertEqual(entry.state, .interrupted)
        XCTAssertTrue(entry.hasAudio)
        XCTAssertEqual(recoveredAudio.values, [0.1, -0.1])
    }

    func testCancelAfterAudioFinalizationBeforeRecognitionReleasesOwnedBuffer() async {
        let finalized = AsyncGate()
        let returnFinalizedInput = AsyncGate()
        let audio = StoredAudioCapture(
            finalized: finalized,
            returnFinalizedInput: returnFinalizedInput
        )
        let recognizer = CountingBorrowingRecognizer()
        let coordinator = makeCoordinator(audioCapture: audio, recognizer: recognizer)
        let sessionID = startedSessionID(await coordinator.start())

        let stopTask = Task { await coordinator.stop(sessionID: sessionID) }
        await finalized.wait()
        let countAfterFinalization = await audio.storedBufferCount()
        XCTAssertEqual(countAfterFinalization, 1)

        let cancelOutcome = await coordinator.cancel(sessionID: sessionID)
        await returnFinalizedInput.open()
        let stopOutcome = await stopTask.value
        let transcriptionCount = await recognizer.transcriptionCount()
        let storedBufferCount = await audio.storedBufferCount()
        let releaseCount = await audio.releaseCount()

        XCTAssertEqual(cancelOutcome, .cancelled(sessionID))
        XCTAssertEqual(stopOutcome, .ignoredStale(sessionID))
        XCTAssertEqual(transcriptionCount, 0)
        XCTAssertEqual(storedBufferCount, 0)
        XCTAssertEqual(releaseCount, 1)
    }

    func testSuccessfulRecognitionReleasesFinalizedAudioExactlyOnce() async {
        let audio = StoredAudioCapture()
        let coordinator = makeCoordinator(audioCapture: audio)
        let sessionID = startedSessionID(await coordinator.start())

        let outcome = await coordinator.stop(sessionID: sessionID)
        let storedBufferCount = await audio.storedBufferCount()
        let releaseCount = await audio.releaseCount()

        XCTAssertEqual(outcome, .completed(sessionID, .confirmedDirect))
        XCTAssertEqual(storedBufferCount, 0)
        XCTAssertEqual(releaseCount, 1)
    }

    func testRecognitionFailureReleasesFinalizedAudioExactlyOnce() async {
        let audio = StoredAudioCapture()
        let coordinator = makeCoordinator(
            audioCapture: audio,
            recognizer: FailingRecognizer()
        )
        let sessionID = startedSessionID(await coordinator.start())

        let outcome = await coordinator.stop(sessionID: sessionID)
        let storedBufferCount = await audio.storedBufferCount()
        let releaseCount = await audio.releaseCount()

        XCTAssertEqual(
            outcome,
            .failed(sessionID, DictationFailure(stage: .recognition))
        )
        XCTAssertEqual(storedBufferCount, 0)
        XCTAssertEqual(releaseCount, 1)
    }

    func testCancelDuringPrimingWinsAgainstLateContextCapture() async {
        let captureStarted = AsyncGate()
        let releaseCapture = AsyncGate()
        let context = GatedContextProvider(started: captureStarted, release: releaseCapture)
        let audio = CountingAudioCapture()
        let coordinator = makeCoordinator(contextProvider: context, audioCapture: audio)

        let startTask = Task { await coordinator.start() }
        await captureStarted.wait()
        let snapshot = await coordinator.snapshot()
        let sessionID = try! XCTUnwrap(snapshot.activeSessionID)

        XCTAssertEqual(snapshot.phase, .priming)
        let cancelOutcome = await coordinator.cancel(sessionID: sessionID)
        await releaseCapture.open()
        let startOutcome = await startTask.value
        let audioStartCount = await audio.startCount()
        let audioCancelCount = await audio.cancelCount()

        XCTAssertEqual(cancelOutcome, .cancelled(sessionID))
        XCTAssertEqual(startOutcome, .ignoredStale(sessionID))
        XCTAssertEqual(audioStartCount, 0)
        XCTAssertEqual(audioCancelCount, 1)
    }

    func testCancelDuringBlockedSuccessfulHistoryBeginDoesNotResurrectSession() async {
        let beginStarted = AsyncGate()
        let releaseBegin = AsyncGate()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingHistoryStore(rootURL: root)
        let recorder = RecordingHistoryRecorder(
            store: store,
            sampleAccess: AudioBufferStore()
        )
        let history = GatedBeginRecordingHistory(
            recorder: recorder,
            beginStarted: beginStarted,
            releaseBegin: releaseBegin
        )
        let coordinator = makeCoordinator(recordingHistory: history)

        let startTask = Task { await coordinator.start(language: .german) }
        await beginStarted.wait()
        let primingSnapshot = await coordinator.snapshot()
        let sessionID = try! XCTUnwrap(primingSnapshot.activeSessionID)

        let cancelOutcome = await coordinator.cancel(sessionID: sessionID)
        await releaseBegin.open()
        let startOutcome = await startTask.value
        let finalSnapshot = await coordinator.snapshot()

        XCTAssertEqual(cancelOutcome, .cancelled(sessionID))
        XCTAssertEqual(startOutcome, .ignoredStale(sessionID))
        XCTAssertEqual(finalSnapshot.activeSessionID, nil)
        let hasActiveMapping = await history.hasActiveMapping()
        XCTAssertFalse(hasActiveMapping)
        let entries = try! await store.list()
        XCTAssertTrue(entries.isEmpty)
    }

    func testCancelDuringListeningReleasesAudioCapture() async {
        let audio = CountingAudioCapture()
        let coordinator = makeCoordinator(audioCapture: audio)
        let sessionID = startedSessionID(await coordinator.start())

        let outcome = await coordinator.cancel(sessionID: sessionID)
        let cancelCount = await audio.cancelCount()
        let snapshot = await coordinator.snapshot()

        XCTAssertEqual(outcome, .cancelled(sessionID))
        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(
            snapshot,
            DictationSnapshot(phase: .cancelled, activeSessionID: nil)
        )
    }

    func testCancelWinsAgainstLateCleanupAndDiscardsEphemeralTranscript() async {
        let cleanupStarted = AsyncGate()
        let releaseCleanup = AsyncGate()
        let cleanup = GatedCleanup(started: cleanupStarted, release: releaseCleanup)
        let insertion = RecordingInsertion()
        let fallback = EphemeralResultStore()
        let coordinator = makeCoordinator(
            cleanup: cleanup,
            insertion: insertion,
            fallbackText: fallback
        )
        let sessionID = startedSessionID(await coordinator.start())

        let stopTask = Task { await coordinator.stop(sessionID: sessionID) }
        await cleanupStarted.wait()
        let cleaningSnapshot = await coordinator.snapshot()
        XCTAssertEqual(
            cleaningSnapshot,
            DictationSnapshot(phase: .cleaning, activeSessionID: sessionID)
        )

        let cancelOutcome = await coordinator.cancel(sessionID: sessionID)
        await releaseCleanup.open()
        let outcome = await stopTask.value
        let stored = await fallback.oldest()
        let insertionCount = await insertion.count()

        XCTAssertEqual(cancelOutcome, .cancelled(sessionID))
        XCTAssertEqual(outcome, .ignoredStale(sessionID))
        XCTAssertNil(stored)
        XCTAssertEqual(insertionCount, 0)
    }

    func testCancelWinsWhileRawTranscriptIsBeingPreserved() async {
        let preservationStarted = AsyncGate()
        let releasePreservation = AsyncGate()
        let fallback = GatedEphemeralPersistence(
            gatedStage: .raw,
            started: preservationStarted,
            release: releasePreservation
        )
        let insertion = RecordingInsertion()
        let coordinator = makeCoordinator(
            insertion: insertion,
            fallbackText: fallback
        )
        let sessionID = startedSessionID(await coordinator.start())

        let stopTask = Task { await coordinator.stop(sessionID: sessionID) }
        await preservationStarted.wait()
        let transcribingSnapshot = await coordinator.snapshot()
        let cancelOutcome = await coordinator.cancel(sessionID: sessionID)
        await releasePreservation.open()
        let outcome = await stopTask.value
        let insertionCount = await insertion.count()
        let didDiscard = await fallback.didDiscard()

        XCTAssertEqual(
            transcribingSnapshot,
            DictationSnapshot(phase: .transcribing, activeSessionID: sessionID)
        )
        XCTAssertEqual(cancelOutcome, .cancelled(sessionID))
        XCTAssertEqual(outcome, .ignoredStale(sessionID))
        XCTAssertEqual(insertionCount, 0)
        XCTAssertTrue(didDiscard)
    }

    func testCancelWinsWhileFinalCandidateIsBeingPreserved() async {
        let preservationStarted = AsyncGate()
        let releasePreservation = AsyncGate()
        let fallback = GatedEphemeralPersistence(
            gatedStage: .candidate,
            started: preservationStarted,
            release: releasePreservation
        )
        let insertion = RecordingInsertion()
        let coordinator = makeCoordinator(
            insertion: insertion,
            fallbackText: fallback
        )
        let sessionID = startedSessionID(await coordinator.start())

        let stopTask = Task { await coordinator.stop(sessionID: sessionID) }
        await preservationStarted.wait()
        let cleaningSnapshot = await coordinator.snapshot()
        let cancelOutcome = await coordinator.cancel(sessionID: sessionID)
        await releasePreservation.open()
        let outcome = await stopTask.value
        let insertionCount = await insertion.count()
        let didDiscard = await fallback.didDiscard()

        XCTAssertEqual(
            cleaningSnapshot,
            DictationSnapshot(phase: .cleaning, activeSessionID: sessionID)
        )
        XCTAssertEqual(cancelOutcome, .cancelled(sessionID))
        XCTAssertEqual(outcome, .ignoredStale(sessionID))
        XCTAssertEqual(insertionCount, 0)
        XCTAssertTrue(didDiscard)
    }

    func testCancelWinsAgainstLateCloudEnrichment() async {
        let enrichmentStarted = AsyncGate()
        let releaseEnrichment = AsyncGate()
        let enrichment = GatedEnrichment(
            started: enrichmentStarted,
            release: releaseEnrichment
        )
        let insertion = RecordingInsertion()
        let fallback = EphemeralResultStore()
        let coordinator = makeCoordinator(
            enrichment: enrichment,
            insertion: insertion,
            fallbackText: fallback
        )
        let sessionID = startedSessionID(await coordinator.start())

        let stopTask = Task {
            await coordinator.stop(
                sessionID: sessionID,
                consent: ConsentSnapshot(cloudEnabled: true, contextToCloud: false)
            )
        }
        await enrichmentStarted.wait()
        let enrichingSnapshot = await coordinator.snapshot()
        XCTAssertEqual(
            enrichingSnapshot,
            DictationSnapshot(phase: .enriching, activeSessionID: sessionID)
        )

        let cancelOutcome = await coordinator.cancel(sessionID: sessionID)
        await releaseEnrichment.open()
        let outcome = await stopTask.value
        let stored = await fallback.oldest()
        let insertionCount = await insertion.count()

        XCTAssertEqual(cancelOutcome, .cancelled(sessionID))
        XCTAssertEqual(outcome, .ignoredStale(sessionID))
        XCTAssertNil(stored)
        XCTAssertEqual(insertionCount, 0)
    }

    func testCancelBeforeInsertionCommitPreventsMutationAndReleasesOnce() async {
        let insertion = LinearizedRaceInsertion(mode: .pauseBeforeCommit)
        let fallback = EphemeralResultStore()
        let coordinator = makeCoordinator(
            insertion: insertion,
            fallbackText: fallback
        )
        let sessionID = startedSessionID(await coordinator.start())

        let stopTask = Task { await coordinator.stop(sessionID: sessionID) }
        await insertion.waitUntilPausedBeforeCommit()
        let insertingSnapshot = await coordinator.snapshot()
        XCTAssertEqual(
            insertingSnapshot,
            DictationSnapshot(phase: .inserting, activeSessionID: sessionID)
        )

        let cancelOutcome = await coordinator.cancel(sessionID: sessionID)
        await insertion.resumeCommit()
        let outcome = await stopTask.value
        await fallback.preserveCandidate("late", for: sessionID)
        let stored = await fallback.oldest()
        let writes = await insertion.writeCount()
        let releases = await insertion.releaseCount()

        XCTAssertEqual(cancelOutcome, .cancelled(sessionID))
        XCTAssertEqual(outcome, .ignoredStale(sessionID))
        XCTAssertNil(stored)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(releases, 1)
    }

    func testCommittedInsertionReportsTooLateAndCompletesNormally() async {
        let insertion = LinearizedRaceInsertion(mode: .pauseAfterCommit)
        let coordinator = makeCoordinator(insertion: insertion)
        let sessionID = startedSessionID(await coordinator.start())

        let stopTask = Task { await coordinator.stop(sessionID: sessionID) }
        await insertion.waitUntilCommitted()

        let cancelOutcome = await coordinator.cancel(sessionID: sessionID)
        await insertion.resumeAdapterReturn()
        let stopOutcome = await stopTask.value
        let writes = await insertion.writeCount()
        let releases = await insertion.releaseCount()

        XCTAssertEqual(cancelOutcome, .tooLateCommitted(sessionID))
        XCTAssertEqual(stopOutcome, .completed(sessionID, .confirmedDirect))
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(releases, 1)
    }

    func testStopWaitsForPendingCommitFirstCancellationResolution() async {
        let insertion = LinearizedRaceInsertion(
            mode: .pauseAfterCommit,
            holdCancellationReturn: true
        )
        let coordinator = makeCoordinator(insertion: insertion)
        let sessionID = startedSessionID(await coordinator.start())

        let stopTask = Task { await coordinator.stop(sessionID: sessionID) }
        await insertion.waitUntilCommitted()
        let cancelTask = Task { await coordinator.cancel(sessionID: sessionID) }
        await insertion.waitUntilCancellationRequested()

        await insertion.resumeAdapterReturn()
        await Task.yield()
        await insertion.resumeCancellationReturn()

        let cancelOutcome = await cancelTask.value
        let stopOutcome = await stopTask.value
        let writes = await insertion.writeCount()
        let releases = await insertion.releaseCount()

        XCTAssertEqual(cancelOutcome, .tooLateCommitted(sessionID))
        XCTAssertEqual(stopOutcome, .completed(sessionID, .confirmedDirect))
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(releases, 1)
    }

    func testOneHundredStartCancelStartSequencesRejectStaleSessions() async {
        let insertion = RecordingInsertion()
        let coordinator = makeCoordinator(insertion: insertion)
        var previousSessionID = DictationSessionID(rawValue: 0)

        for _ in 0..<100 {
            let cancelledSessionID = startedSessionID(await coordinator.start())
            XCTAssertGreaterThan(cancelledSessionID, previousSessionID)
            let cancelledOutcome = await coordinator.cancel(sessionID: cancelledSessionID)
            XCTAssertEqual(cancelledOutcome, .cancelled(cancelledSessionID))

            let currentSessionID = startedSessionID(await coordinator.start())
            XCTAssertGreaterThan(currentSessionID, cancelledSessionID)
            let staleOutcome = await coordinator.stop(sessionID: cancelledSessionID)
            XCTAssertEqual(staleOutcome, .ignoredStale(cancelledSessionID))
            let currentSnapshot = await coordinator.snapshot()
            XCTAssertEqual(
                currentSnapshot,
                DictationSnapshot(phase: .listening, activeSessionID: currentSessionID)
            )
            let currentCancelOutcome = await coordinator.cancel(sessionID: currentSessionID)
            XCTAssertEqual(currentCancelOutcome, .cancelled(currentSessionID))
            previousSessionID = currentSessionID
        }

        let insertionCount = await insertion.count()
        XCTAssertEqual(insertionCount, 0)
    }

    func testContextFailureIsContentFreeAndNextSessionCanStart() async {
        let contextProvider = FailOnceContextProvider()
        let coordinator = makeCoordinator(contextProvider: contextProvider)

        let failedOutcome = await coordinator.start()
        let failedSessionID = failedOutcome.sessionID
        let expectedFailure = DictationFailure(stage: .context)
        let failedSnapshot = await coordinator.snapshot()

        XCTAssertEqual(failedOutcome, .failed(failedSessionID, expectedFailure))
        XCTAssertEqual(
            failedSnapshot,
            DictationSnapshot(phase: .error(expectedFailure), activeSessionID: nil)
        )

        let recoveredSessionID = startedSessionID(await coordinator.start())
        let recoveredSnapshot = await coordinator.snapshot()
        XCTAssertGreaterThan(recoveredSessionID, failedSessionID)
        XCTAssertEqual(
            recoveredSnapshot,
            DictationSnapshot(phase: .listening, activeSessionID: recoveredSessionID)
        )
        _ = await coordinator.cancel(sessionID: recoveredSessionID)
    }

    func testCloudFailureFallsBackToLocalCandidate() async {
        let insertion = RecordingInsertion()
        let coordinator = makeCoordinator(
            enrichment: FailingEnrichment(),
            insertion: insertion
        )
        let sessionID = startedSessionID(await coordinator.start())

        let outcome = await coordinator.stop(
            sessionID: sessionID,
            consent: ConsentSnapshot(cloudEnabled: true, contextToCloud: false)
        )
        let candidates = await insertion.candidates()

        XCTAssertEqual(outcome, .completed(sessionID, .confirmedDirect))
        XCTAssertEqual(candidates, [.local(LocalCandidate(text: "hello"))])
    }

    func testCloudFailureFallsBackToValidatedOnDeviceRewrite() async {
        let insertion = RecordingInsertion()
        let localRewriter = RecordingTextRewriter(output: "lokal geglättet")
        let coordinator = makeCoordinator(
            enrichment: FailingEnrichment(),
            localRewriter: localRewriter,
            insertion: insertion
        )
        let sessionID = startedSessionID(await coordinator.start(language: .german))

        let outcome = await coordinator.stop(
            sessionID: sessionID,
            consent: ConsentSnapshot(cloudEnabled: true, contextToCloud: false)
        )
        let candidates = await insertion.candidates()
        let rewriteCount = await localRewriter.rewriteCount()

        XCTAssertEqual(outcome, .completed(sessionID, .confirmedDirect))
        XCTAssertEqual(
            candidates,
            [.local(LocalCandidate(text: "lokal geglättet"))]
        )
        XCTAssertEqual(rewriteCount, 1)
    }

    func testTerminalStateCanResetToIdle() async {
        let coordinator = makeCoordinator()
        let sessionID = startedSessionID(await coordinator.start())
        _ = await coordinator.cancel(sessionID: sessionID)

        await coordinator.resetTerminalState()
        let snapshot = await coordinator.snapshot()

        XCTAssertEqual(
            snapshot,
            DictationSnapshot(phase: .idle, activeSessionID: nil)
        )
    }
}

private func makeCoordinator(
    contextProvider: any TargetContextProviding = TestContextProvider(),
    audioCapture: any AudioCapturing = CountingAudioCapture(),
    recognizer: any SpeechRecognizing = ImmediateRecognizer(),
    cleanup: any TextCleaning = PassthroughCleanup(),
    enrichment: any TextEnriching = PassthroughEnrichment(),
    localRewriter: (any TextRewriting)? = nil,
    insertion: any TextInserting = RecordingInsertion(),
    fallbackText: (any EphemeralTextPreserving)? = nil,
    recordingHistory: (any RecordingHistoryRecording)? = nil
) -> DictationCoordinator {
    DictationCoordinator(
        contextProvider: contextProvider,
        audioCapture: audioCapture,
        recognizer: recognizer,
        cleanup: cleanup,
        enrichment: enrichment,
        localRewriter: localRewriter,
        insertion: insertion,
        fallbackText: fallbackText,
        recordingHistory: recordingHistory
    )
}

private actor RecordingHistorySpy: RecordingHistoryRecording {
    private var recordedEvents: [String] = []

    func begin(sessionID: DictationSessionID, language: DictationLanguage) {
        recordedEvents.append("begin:\(language.storageValue)")
    }

    func persistAudio(_ input: AudioInput, sessionID: DictationSessionID) {
        recordedEvents.append("audio")
    }

    func persistCheckpoint(_ chunk: RecognitionAudioChunk, sessionID: DictationSessionID) {
        recordedEvents.append("checkpoint")
    }

    func persistTranscript(_ transcript: RawTranscript, sessionID: DictationSessionID) {
        recordedEvents.append("raw:\(transcript.text)")
    }

    func persistFinalTranscript(_ text: String, sessionID: DictationSessionID) {
        recordedEvents.append("final:\(text)")
    }

    func complete(sessionID: DictationSessionID) {
        recordedEvents.append("complete")
    }

    func markFailed(sessionID: DictationSessionID) throws {
        recordedEvents.append("failed")
    }

    func interrupt(sessionID: DictationSessionID) throws {
        recordedEvents.append("interrupted")
    }

    func events() -> [String] { recordedEvents }
}

private actor HistoryFailureCounter {
    private var sessionIDs: [DictationSessionID] = []

    func record(_ sessionID: DictationSessionID) {
        sessionIDs.append(sessionID)
    }

    func count() -> Int {
        sessionIDs.count
    }
}

private struct CorrectingCleanup: TextCleaning {
    let text: String

    func clean(
        _ transcript: RawTranscript,
        context: ContextSnapshot,
        sessionID: DictationSessionID
    ) async throws -> LocalCandidate {
        LocalCandidate(text: text)
    }
}

private struct FailingInsertion: TextInserting {
    func insert(
        _ candidate: FinalCandidate,
        sessionID: DictationSessionID
    ) async throws -> InsertionOutcome {
        throw TestFailure.expected
    }

    func requestCancellation(
        sessionID: DictationSessionID
    ) async -> InsertionCancellationDisposition {
        .cancelledBeforeCommit
    }

    func releaseInsertionSession(sessionID: DictationSessionID) async {}
}

private actor GatedCheckpointRecordingHistory: RecordingHistoryRecording {
    private let checkpointStarted: AsyncGate
    private let releaseCheckpoint: AsyncGate
    private var recordedEvents: [String] = []

    init(checkpointStarted: AsyncGate, releaseCheckpoint: AsyncGate) {
        self.checkpointStarted = checkpointStarted
        self.releaseCheckpoint = releaseCheckpoint
    }

    func begin(sessionID: DictationSessionID, language: DictationLanguage) {
        recordedEvents.append("begin")
    }

    func persistCheckpoint(
        _ chunk: RecognitionAudioChunk,
        sessionID: DictationSessionID
    ) async {
        recordedEvents.append("checkpointStarted")
        await checkpointStarted.open()
        await releaseCheckpoint.wait()
        recordedEvents.append("checkpointFinished")
    }

    func persistAudio(_ input: AudioInput, sessionID: DictationSessionID) {}
    func persistTranscript(_ transcript: RawTranscript, sessionID: DictationSessionID) {}
    func markFailed(sessionID: DictationSessionID) {}

    func interrupt(sessionID: DictationSessionID) {
        recordedEvents.append("interrupted")
    }

    func events() -> [String] {
        recordedEvents
    }
}

private actor GatedBeginRecordingHistory: RecordingHistoryRecording {
    private let recorder: RecordingHistoryRecorder
    private let beginStarted: AsyncGate
    private let releaseBegin: AsyncGate
    private var sessionID: DictationSessionID?

    init(
        recorder: RecordingHistoryRecorder,
        beginStarted: AsyncGate,
        releaseBegin: AsyncGate
    ) {
        self.recorder = recorder
        self.beginStarted = beginStarted
        self.releaseBegin = releaseBegin
    }

    func begin(sessionID: DictationSessionID, language: DictationLanguage) async throws {
        await beginStarted.open()
        await releaseBegin.wait()
        try await recorder.begin(sessionID: sessionID, language: language)
        self.sessionID = sessionID
    }

    func persistCheckpoint(
        _ chunk: RecognitionAudioChunk,
        sessionID: DictationSessionID
    ) async throws {
        try await recorder.persistCheckpoint(chunk, sessionID: sessionID)
    }

    func persistAudio(_ input: AudioInput, sessionID: DictationSessionID) async throws {
        try await recorder.persistAudio(input, sessionID: sessionID)
    }

    func persistTranscript(_ transcript: RawTranscript, sessionID: DictationSessionID) async throws {
        try await recorder.persistTranscript(transcript, sessionID: sessionID)
    }

    func persistFinalTranscript(_ text: String, sessionID: DictationSessionID) async throws {
        try await recorder.persistFinalTranscript(text, sessionID: sessionID)
    }

    func complete(sessionID: DictationSessionID) async throws {
        try await recorder.complete(sessionID: sessionID)
    }

    func markFailed(sessionID: DictationSessionID) async throws {
        try await recorder.markFailed(sessionID: sessionID)
    }

    func interrupt(sessionID: DictationSessionID) async throws {
        try await recorder.interrupt(sessionID: sessionID)
    }

    func hasActiveMapping() async -> Bool {
        guard let sessionID else { return false }
        do {
            try await recorder.persistFinalTranscript("probe", sessionID: sessionID)
            return true
        } catch {
            return false
        }
    }
}

private struct FailingRecordingHistory: RecordingHistoryRecording {
    enum Stage: Sendable { case begin, checkpoint, audio, transcript, markFailed, interrupt }
    let stage: Stage

    func begin(sessionID: DictationSessionID, language: DictationLanguage) throws {
        if stage == .begin { throw TestFailure.expected }
    }

    func persistCheckpoint(
        _ chunk: RecognitionAudioChunk,
        sessionID: DictationSessionID
    ) throws {
        if stage == .checkpoint { throw TestFailure.expected }
    }

    func persistAudio(_ input: AudioInput, sessionID: DictationSessionID) throws {
        if stage == .audio { throw TestFailure.expected }
    }

    func persistTranscript(_ transcript: RawTranscript, sessionID: DictationSessionID) throws {
        if stage == .transcript { throw TestFailure.expected }
    }

    func markFailed(sessionID: DictationSessionID) throws {
        if stage == .markFailed { throw TestFailure.expected }
    }

    func interrupt(sessionID: DictationSessionID) throws {
        if stage == .interrupt { throw TestFailure.expected }
    }
}

private actor TransientTerminalWriteRecordingHistory: RecordingHistoryRecording {
    enum Terminal: Sendable {
        case failed
        case interrupted
    }

    private let terminal: Terminal
    private let failuresBeforeSuccess: Int
    private var terminalAttempts = 0

    init(terminal: Terminal, failuresBeforeSuccess: Int) {
        self.terminal = terminal
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func begin(sessionID: DictationSessionID, language: DictationLanguage) {}

    func persistCheckpoint(
        _ chunk: RecognitionAudioChunk,
        sessionID: DictationSessionID
    ) {}

    func persistAudio(_ input: AudioInput, sessionID: DictationSessionID) throws {
        if terminal == .failed {
            throw TestFailure.expected
        }
    }

    func persistTranscript(_ transcript: RawTranscript, sessionID: DictationSessionID) {}

    func markFailed(sessionID: DictationSessionID) throws {
        guard terminal == .failed else { return }
        terminalAttempts += 1
        if terminalAttempts <= failuresBeforeSuccess {
            throw TestFailure.expected
        }
    }

    func interrupt(sessionID: DictationSessionID) throws {
        guard terminal == .interrupted else { return }
        terminalAttempts += 1
        if terminalAttempts <= failuresBeforeSuccess {
            throw TestFailure.expected
        }
    }

    func terminalAttemptCount() -> Int {
        terminalAttempts
    }
}

private actor PersistentTerminalWriteRecordingHistory: RecordingHistoryRecording {
    private var attempts = 0
    private var releases = 0

    func begin(sessionID: DictationSessionID, language: DictationLanguage) {}

    func persistCheckpoint(
        _ chunk: RecognitionAudioChunk,
        sessionID: DictationSessionID
    ) {}

    func persistAudio(_ input: AudioInput, sessionID: DictationSessionID) {}

    func persistTranscript(_ transcript: RawTranscript, sessionID: DictationSessionID) {}

    func markFailed(sessionID: DictationSessionID) throws {
        attempts += 1
        throw TestFailure.expected
    }

    func interrupt(sessionID: DictationSessionID) throws {
        attempts += 1
        throw TestFailure.expected
    }

    func releaseTracking(sessionID: DictationSessionID) {
        releases += 1
    }

    func terminalAttempts() -> Int { attempts }

    func releaseAttempts() -> Int { releases }
}

private func startedSessionID(
    _ outcome: StartOutcome,
    file: StaticString = #filePath,
    line: UInt = #line
) -> DictationSessionID {
    guard case .started(let sessionID) = outcome else {
        XCTFail("Expected a newly started session", file: file, line: line)
        return outcome.sessionID
    }
    return sessionID
}

private func capturedContext(for sessionID: DictationSessionID) -> CapturedTargetContext {
    CapturedTargetContext(
        target: TargetSnapshot(
            processIdentifier: 1,
            token: TargetToken(rawValue: sessionID.rawValue),
            selectionFingerprint: SelectionFingerprint(rawValue: 1),
            sessionID: sessionID
        ),
        context: .unavailable(targetKind: .unknown)
    )
}

private struct TestContextProvider: TargetContextProviding {
    func capture(for sessionID: DictationSessionID) async throws -> CapturedTargetContext {
        capturedContext(for: sessionID)
    }

    func cancel(sessionID: DictationSessionID) async {}
}

private struct StaticContextProvider: TargetContextProviding {
    let context: ContextSnapshot

    func capture(for sessionID: DictationSessionID) async throws -> CapturedTargetContext {
        CapturedTargetContext(
            target: capturedContext(for: sessionID).target,
            context: context
        )
    }

    func cancel(sessionID: DictationSessionID) async {}
}

private struct UnavailableTargetContextProvider: TargetContextProviding {
    func capture(for sessionID: DictationSessionID) async throws -> CapturedTargetContext {
        CapturedTargetContext(
            target: .unavailable(processIdentifier: 42, sessionID: sessionID),
            context: .unavailable(targetKind: .unknown)
        )
    }

    func cancel(sessionID: DictationSessionID) async {}
}

private struct SensitiveTargetContextProvider: TargetContextProviding {
    func capture(for sessionID: DictationSessionID) async throws -> CapturedTargetContext {
        CapturedTargetContext(
            target: capturedContext(for: sessionID).target,
            context: ContextSnapshot(
                availability: .deniedSensitive,
                targetKind: .unknown,
                boundedText: nil,
                termHints: []
            )
        )
    }

    func cancel(sessionID: DictationSessionID) async {}
}

private actor SplitGatedContextProvider: TargetContextProviding {
    private let enrichmentStarted: AsyncGate
    private let releaseEnrichment: AsyncGate

    init(
        enrichmentStarted: AsyncGate,
        releaseEnrichment: AsyncGate
    ) {
        self.enrichmentStarted = enrichmentStarted
        self.releaseEnrichment = releaseEnrichment
    }

    func capture(for sessionID: DictationSessionID) async throws -> CapturedTargetContext {
        let target = try await captureTarget(for: sessionID)
        return try await enrichContext(for: target, sessionID: sessionID)
    }

    func captureTarget(for sessionID: DictationSessionID) async throws -> CapturedTargetContext {
        capturedContext(for: sessionID)
    }

    func enrichContext(
        for captured: CapturedTargetContext,
        sessionID _: DictationSessionID
    ) async throws -> CapturedTargetContext {
        await enrichmentStarted.open()
        await releaseEnrichment.wait()
        return captured
    }

    func cancel(sessionID: DictationSessionID) async {}
}

private actor GatedContextProvider: TargetContextProviding {
    private let started: AsyncGate
    private let release: AsyncGate

    init(started: AsyncGate, release: AsyncGate) {
        self.started = started
        self.release = release
    }

    func capture(for sessionID: DictationSessionID) async throws -> CapturedTargetContext {
        await started.open()
        await release.wait()
        return capturedContext(for: sessionID)
    }

    func cancel(sessionID: DictationSessionID) async {}
}

private actor FailOnceContextProvider: TargetContextProviding {
    private var shouldFail = true

    func capture(for sessionID: DictationSessionID) async throws -> CapturedTargetContext {
        if shouldFail {
            shouldFail = false
            throw TestFailure.expected
        }
        return capturedContext(for: sessionID)
    }

    func cancel(sessionID: DictationSessionID) async {}
}

private actor CountingAudioCapture: AudioCapturing {
    private var starts = 0
    private var cancellations = 0

    func startCapture(for sessionID: DictationSessionID) async throws {
        starts += 1
    }

    func finishCapture(for sessionID: DictationSessionID) async throws -> AudioInput {
        AudioInput(buffer: AudioBufferHandle(rawValue: sessionID.rawValue))
    }

    func cancelCapture(for sessionID: DictationSessionID) async {
        cancellations += 1
    }

    func release(_ input: AudioInput) async {}

    func startCount() -> Int {
        starts
    }

    func cancelCount() -> Int {
        cancellations
    }
}

private actor StoredAudioCapture: AudioCapturing {
    private let store: AudioBufferStore
    private let finalized: AsyncGate?
    private let returnFinalizedInput: AsyncGate?
    private var releases = 0

    init(
        store: AudioBufferStore = AudioBufferStore(),
        finalized: AsyncGate? = nil,
        returnFinalizedInput: AsyncGate? = nil
    ) {
        self.store = store
        self.finalized = finalized
        self.returnFinalizedInput = returnFinalizedInput
    }

    func startCapture(for sessionID: DictationSessionID) async throws {}

    func finishCapture(for sessionID: DictationSessionID) async throws -> AudioInput {
        let input = await store.store(AudioSamples(values: [0.1, -0.1]))
        await finalized?.open()
        await returnFinalizedInput?.wait()
        return input
    }

    func cancelCapture(for sessionID: DictationSessionID) async {}

    func release(_ input: AudioInput) async {
        releases += 1
        await store.release(input)
    }

    func storedBufferCount() async -> Int {
        await store.storedBufferCount()
    }

    func releaseCount() -> Int { releases }
}

private actor EmptyStoredAudioCapture: AudioCapturing {
    private let store: AudioBufferStore

    init(store: AudioBufferStore) {
        self.store = store
    }

    func startCapture(for sessionID: DictationSessionID) async throws {}

    func finishCapture(for sessionID: DictationSessionID) async throws -> AudioInput {
        await store.store(AudioSamples(values: []))
    }

    func cancelCapture(for sessionID: DictationSessionID) async {}

    func release(_ input: AudioInput) async {
        await store.release(input)
    }
}

private actor SilentAudioCapture: AudioCapturing {
    private var releases = 0

    func startCapture(for sessionID: DictationSessionID) async throws {}

    func finishCapture(for sessionID: DictationSessionID) async throws -> AudioInput {
        AudioInput(
            buffer: AudioBufferHandle(rawValue: sessionID.rawValue),
            timing: AudioTimingMetadata(
                originalDurationSeconds: 1,
                processedDurationSeconds: 0,
                leadingSilenceTrimmedSeconds: 1,
                trailingSilenceTrimmedSeconds: 0,
                detectedSpeechDurationSeconds: 0,
                isSilent: true,
                removedDCOffset: 0,
                appliedGain: 1
            )
        )
    }

    func cancelCapture(for sessionID: DictationSessionID) async {}

    func release(_ input: AudioInput) async {
        releases += 1
    }

    func releaseCount() -> Int { releases }
}

private actor BorderlineVADAudioCapture: AudioCapturing {
    private var releases = 0

    func startCapture(for sessionID: DictationSessionID) async throws {}

    func finishCapture(for sessionID: DictationSessionID) async throws -> AudioInput {
        AudioInput(
            buffer: AudioBufferHandle(rawValue: sessionID.rawValue),
            timing: AudioTimingMetadata(
                originalDurationSeconds: 1,
                processedDurationSeconds: 0.11,
                leadingSilenceTrimmedSeconds: 0,
                trailingSilenceTrimmedSeconds: 0,
                detectedSpeechDurationSeconds: 0,
                isSilent: true,
                removedDCOffset: 0,
                appliedGain: 1,
                inputRMS: 0.03,
                inputPeak: 0.03,
                normalizedRMS: 0.03,
                normalizedPeak: 0.03
            )
        )
    }

    func cancelCapture(for sessionID: DictationSessionID) async {}

    func release(_ input: AudioInput) async {
        releases += 1
    }

    func releaseCount() -> Int {
        releases
    }
}

private actor StreamingAudioCapture: AudioCapturing, IncrementalAudioProviding {
    private var deliveredPrefix = false

    func startCapture(for sessionID: DictationSessionID) async throws {}

    func finishCapture(for sessionID: DictationSessionID) async throws -> AudioInput {
        AudioInput(buffer: AudioBufferHandle(rawValue: sessionID.rawValue))
    }

    func incrementalAudioBatch(
        for sessionID: DictationSessionID,
        afterFrameOffset frameOffset: Int
    ) async throws -> IncrementalAudioBatch? {
        guard !deliveredPrefix, frameOffset == 0 else { return nil }
        deliveredPrefix = true
        return IncrementalAudioBatch(
            chunk: RecognitionAudioChunk(samples: Array(repeating: 0.05, count: 8_000)),
            nextFrameOffset: 8_000
        )
    }

    func cancelCapture(for sessionID: DictationSessionID) async {}

    func release(_ input: AudioInput) async {}
}

private actor StreamingLifecycleRecognizer: SpeechRecognizing, SpeechRecognitionLifecycle {
    private let firstUpdate: AsyncGate
    private let recognitionStopped: AsyncGate?
    private var events: [String] = []

    init(firstUpdate: AsyncGate, recognitionStopped: AsyncGate? = nil) {
        self.firstUpdate = firstUpdate
        self.recognitionStopped = recognitionStopped
    }

    func transcribe(
        _ audio: AudioInput,
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws -> RawTranscript {
        events.append("transcribe")
        return RawTranscript(text: "hello", language: hints.language)
    }

    func cancel(sessionID: DictationSessionID) async {
        events.append("cancel")
    }

    func prepareForRecording(
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws {}

    func startRecognitionSession(
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws {
        events.append("start")
    }

    func updateRecognitionSession(
        with chunk: RecognitionAudioChunk,
        sessionID: DictationSessionID
    ) async throws -> RecognitionChunkDisposition {
        events.append("update")
        await firstUpdate.open()
        return .accepted
    }

    func stopRecognitionSession(sessionID: DictationSessionID) async {
        events.append("stop")
        await recognitionStopped?.open()
    }

    func finalizeRecognitionSession(
        _ audio: AudioInput,
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws -> RawTranscript {
        events.append("finalize")
        return RawTranscript(text: "hello", language: hints.language)
    }

    func recordedEvents() -> [String] { events }
}

private actor FastReleaseLifecycleRecognizer: SpeechRecognizing, SpeechRecognitionLifecycle {
    private var events: [String] = []

    func transcribe(
        _ audio: AudioInput,
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws -> RawTranscript {
        events.append("transcribe")
        return RawTranscript(text: "schneller test", language: hints.language)
    }

    func cancel(sessionID: DictationSessionID) async {
        events.append("cancel")
    }

    func prepareForRecording(
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws {}

    func startRecognitionSession(
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws {
        events.append("start")
    }

    func updateRecognitionSession(
        with chunk: RecognitionAudioChunk,
        sessionID: DictationSessionID
    ) async throws -> RecognitionChunkDisposition {
        events.append("update")
        return .accepted
    }

    func stopRecognitionSession(sessionID: DictationSessionID) async {
        events.append("stop")
    }

    func finalizeRecognitionSession(
        _ audio: AudioInput,
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws -> RawTranscript {
        events.append("finalize")
        throw TestFailure.expected
    }

    func recordedEvents() -> [String] { events }
}

private actor LowQualityCoordinatorRecognizer: SpeechRecognizing {
    func transcribe(
        _ audio: AudioInput,
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) -> RawTranscript {
        RawTranscript(
            text: "uncertain turbo result",
            language: hints.language,
            backend: .whisperKitLargeV3Turbo,
            avgLogprob: -0.95
        )
    }

    func cancel(sessionID: DictationSessionID) async {}
}

private actor NeverCompletingCoordinatorRecognizer: SpeechRecognizing {
    private var transcriptions = 0
    private var cancellations = 0

    func transcribe(
        _ audio: AudioInput,
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws -> RawTranscript {
        transcriptions += 1
        while true {
            do {
                try await Task.sleep(for: .seconds(3_600))
            } catch {
                // Deliberately ignore structured cancellation to exercise quarantine.
            }
        }
    }

    func cancel(sessionID: DictationSessionID) async {
        cancellations += 1
        while true {
            try? await Task.sleep(for: .seconds(3_600))
        }
    }

    func transcriptionCount() -> Int { transcriptions }
    func cancellationCount() -> Int { cancellations }

}

private struct ImmediateRecognizer: SpeechRecognizing {
    func transcribe(
        _ audio: AudioInput,
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws -> RawTranscript {
        RawTranscript(text: "hello", language: hints.language)
    }

    func cancel(sessionID: DictationSessionID) async {}
}

private struct MetadataRecognizer: SpeechRecognizing {
    private let transcript: RawTranscript

    init(
        text: String,
        avgLogprob: Float? = nil,
        minWordProbability: Float? = nil,
        compressionRatio: Float? = nil,
        decoderFallback: RecognitionDecoderFallback? = RecognitionDecoderFallback.none,
        adaptive: AdaptiveRecognitionMetadata? = nil
    ) {
        self.transcript = RawTranscript(
            text: text,
            language: .german,
            avgLogprob: avgLogprob,
            minWordProbability: minWordProbability,
            compressionRatio: compressionRatio,
            decoderFallback: decoderFallback,
            adaptive: adaptive
        )
    }

    init(transcript: RawTranscript) {
        self.transcript = transcript
    }

    func transcribe(
        _ audio: AudioInput,
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws -> RawTranscript {
        RawTranscript(
            text: transcript.text,
            language: hints.language,
            backend: transcript.backend,
            segments: transcript.segments,
            wordProbabilities: transcript.wordProbabilities,
            avgLogprob: transcript.avgLogprob,
            minWordProbability: transcript.minWordProbability,
            compressionRatio: transcript.compressionRatio,
            decoderFallback: transcript.decoderFallback,
            adaptive: transcript.adaptive
        )
    }

    func cancel(sessionID: DictationSessionID) async {}
}

private actor CountingBorrowingRecognizer: SpeechRecognizing {
    private var transcriptions = 0

    func transcribe(
        _ audio: AudioInput,
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws -> RawTranscript {
        transcriptions += 1
        return RawTranscript(text: "hello", language: hints.language)
    }

    func cancel(sessionID: DictationSessionID) async {}

    func transcriptionCount() -> Int { transcriptions }
}

private struct FailingRecognizer: SpeechRecognizing {
    func transcribe(
        _ audio: AudioInput,
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws -> RawTranscript {
        throw TestFailure.expected
    }

    func cancel(sessionID: DictationSessionID) async {}
}

private struct EmptyResultRecognizer: SpeechRecognizing {
    private enum EmptyResult: Error, SpeechRecognitionFailureClassifying {
        case empty

        var indicatesNoSpeech: Bool { true }
    }

    func transcribe(
        _ audio: AudioInput,
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws -> RawTranscript {
        throw EmptyResult.empty
    }

    func cancel(sessionID: DictationSessionID) async {}
}

private actor GatedRecognizer: SpeechRecognizing {
    private let started: AsyncGate
    private let release: AsyncGate

    init(started: AsyncGate, release: AsyncGate) {
        self.started = started
        self.release = release
    }

    func transcribe(
        _ audio: AudioInput,
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws -> RawTranscript {
        await started.open()
        await release.wait()
        return RawTranscript(text: "late result", language: hints.language)
    }

    func cancel(sessionID: DictationSessionID) async {}
}

private struct PassthroughCleanup: TextCleaning {
    func clean(
        _ transcript: RawTranscript,
        context: ContextSnapshot,
        sessionID: DictationSessionID
    ) async throws -> LocalCandidate {
        LocalCandidate(text: transcript.text)
    }
}

private actor GatedCleanup: TextCleaning {
    private let started: AsyncGate
    private let release: AsyncGate

    init(started: AsyncGate, release: AsyncGate) {
        self.started = started
        self.release = release
    }

    func clean(
        _ transcript: RawTranscript,
        context: ContextSnapshot,
        sessionID: DictationSessionID
    ) async throws -> LocalCandidate {
        await started.open()
        await release.wait()
        return LocalCandidate(text: transcript.text)
    }
}

private struct PassthroughEnrichment: TextEnriching {
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

private struct FailingEnrichment: TextEnriching {
    func enrich(
        _ candidate: LocalCandidate,
        context: ContextSnapshot,
        consent: ConsentSnapshot,
        sessionID: DictationSessionID
    ) async throws -> EnrichedCandidate {
        throw TestFailure.expected
    }

    func cancel(sessionID: DictationSessionID) async {}
}

private actor RecordingTextRewriter: TextRewriting {
    let identifier = TextRewriterIdentifier("test-rewriter")
    private let output: String
    private var rewrites = 0

    init(output: String) {
        self.output = output
    }

    func rewrite(_ request: TextRewriteRequest) async -> TextRewriteResult {
        rewrites += 1
        return .accepted(
            originalText: request.localCandidate.text,
            rewrittenText: output
        )
    }

    func cancel(sessionID: DictationSessionID) async {}

    func rewriteCount() -> Int { rewrites }
}

private actor GatedEnrichment: TextEnriching {
    private let started: AsyncGate
    private let release: AsyncGate

    init(started: AsyncGate, release: AsyncGate) {
        self.started = started
        self.release = release
    }

    func enrich(
        _ candidate: LocalCandidate,
        context: ContextSnapshot,
        consent: ConsentSnapshot,
        sessionID: DictationSessionID
    ) async throws -> EnrichedCandidate {
        await started.open()
        await release.wait()
        return EnrichedCandidate(text: "late cloud")
    }

    func cancel(sessionID: DictationSessionID) async {}
}

private actor RecordingInsertion: TextInserting {
    private var recordedCandidates: [FinalCandidate] = []

    func insert(
        _ candidate: FinalCandidate,
        sessionID: DictationSessionID
    ) async throws -> InsertionOutcome {
        recordedCandidates.append(candidate)
        return .confirmedDirect
    }

    func requestCancellation(
        sessionID: DictationSessionID
    ) async -> InsertionCancellationDisposition {
        .cancelledBeforeCommit
    }

    func releaseInsertionSession(sessionID: DictationSessionID) async {}

    func count() -> Int {
        recordedCandidates.count
    }

    func candidates() -> [FinalCandidate] {
        recordedCandidates
    }
}

private actor LinearizedRaceInsertion: TextInserting {
    enum Mode {
        case pauseBeforeCommit
        case pauseAfterCommit
    }

    private let mode: Mode
    private let holdCancellationReturn: Bool
    private let pausedBeforeCommit = AsyncGate()
    private let resumeCommitGate = AsyncGate()
    private let committed = AsyncGate()
    private let resumeAdapterReturnGate = AsyncGate()
    private let cancellationRequested = AsyncGate()
    private let resumeCancellationReturnGate = AsyncGate()
    private var permit: InsertionCommitPermit?
    private var writes = 0
    private var releases = 0

    init(mode: Mode, holdCancellationReturn: Bool = false) {
        self.mode = mode
        self.holdCancellationReturn = holdCancellationReturn
    }

    func insert(
        _ candidate: FinalCandidate,
        sessionID: DictationSessionID
    ) async throws -> InsertionOutcome {
        let commitPermit = InsertionCommitPermit()
        permit = commitPermit

        if mode == .pauseBeforeCommit {
            await pausedBeforeCommit.open()
            await resumeCommitGate.wait()
        }

        let execution = commitPermit.performCommit {
            writes += 1
            return InsertionOutcome.confirmedDirect
        }
        guard case .performed(let outcome) = execution else {
            return .safeFallback
        }

        await committed.open()
        if mode == .pauseAfterCommit {
            await resumeAdapterReturnGate.wait()
        }
        return outcome
    }

    func requestCancellation(
        sessionID: DictationSessionID
    ) async -> InsertionCancellationDisposition {
        let disposition = permit?.requestCancellation() ?? .cancelledBeforeCommit
        await cancellationRequested.open()
        if holdCancellationReturn {
            await resumeCancellationReturnGate.wait()
        }
        return disposition
    }

    func releaseInsertionSession(sessionID: DictationSessionID) async {
        releases += 1
        permit = nil
    }

    func waitUntilPausedBeforeCommit() async {
        await pausedBeforeCommit.wait()
    }

    func resumeCommit() async {
        await resumeCommitGate.open()
    }

    func waitUntilCommitted() async {
        await committed.wait()
    }

    func resumeAdapterReturn() async {
        await resumeAdapterReturnGate.open()
    }

    func waitUntilCancellationRequested() async {
        await cancellationRequested.wait()
    }

    func resumeCancellationReturn() async {
        await resumeCancellationReturnGate.open()
    }

    func writeCount() -> Int { writes }
    func releaseCount() -> Int { releases }
}

private actor GatedEphemeralPersistence: EphemeralTextPreserving {
    enum Stage {
        case raw
        case candidate
    }

    private let gatedStage: Stage
    private let started: AsyncGate
    private let release: AsyncGate
    private var discarded = false

    init(gatedStage: Stage, started: AsyncGate, release: AsyncGate) {
        self.gatedStage = gatedStage
        self.started = started
        self.release = release
    }

    func preserveRawTranscript(_ text: String, for sessionID: DictationSessionID) async {
        guard gatedStage == .raw else { return }
        await started.open()
        await release.wait()
    }

    func preserveCandidate(_ text: String, for sessionID: DictationSessionID) async {
        guard gatedStage == .candidate else { return }
        await started.open()
        await release.wait()
    }

    func confirmInsertion(sessionID: DictationSessionID) async {}

    func discardEphemeralText(sessionID: DictationSessionID) async {
        discarded = true
    }

    func didDiscard() -> Bool { discarded }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pendingWaiters = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pendingWaiters {
            waiter.resume()
        }
    }
}

private enum TestFailure: Error {
    case expected
}
