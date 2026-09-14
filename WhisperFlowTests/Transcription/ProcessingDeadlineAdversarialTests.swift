import XCTest
@testable import WhisperFlow

final class ProcessingDeadlineAdversarialTests: XCTestCase, @unchecked Sendable {
    func testProductASRDeadlineReturnsWhenTranscribeAndCancelNeverReturn() async {
        let backend = CancellationIgnoringSpeechRecognizer()
        let router = SessionModelSpeechRecognizer(
            recognizers: [.whisperKitLargeV3Turbo: backend],
            productASRDeadline: .milliseconds(20),
            productASRCancellationGrace: .milliseconds(20)
        )
        let sessionID = DictationSessionID(rawValue: 90_001)
        await router.register(.whisperKitLargeV3Turbo, for: sessionID)
        let completed = expectation(description: "deadline returns to its caller")

        let operation = Task<Result<RawTranscript, Error>, Never> {
            let result: Result<RawTranscript, Error>
            do {
                result = .success(
                    try await router.transcribe(
                        AudioInput(buffer: AudioBufferHandle(rawValue: 90_001)),
                        hints: RecognitionHints(language: .english, terms: []),
                        sessionID: sessionID
                    )
                )
            } catch {
                result = .failure(error)
            }
            completed.fulfill()
            return result
        }

        let waitResult = await XCTWaiter.fulfillment(of: [completed], timeout: 0.25)
        await backend.releaseBlockedOperations()
        let result = await operation.value

        XCTAssertEqual(waitResult, .completed)
        guard case let .failure(error) = result else {
            return XCTFail("Expected the product ASR deadline to fail")
        }
        XCTAssertEqual(error as? ProductASRDeadlineError, .exceeded)
    }

    func testTimedOutBackendRemainsBusyUntilItsBlockedOperationsQuiesce() async throws {
        let backend = CancellationIgnoringSpeechRecognizer()
        let router = SessionModelSpeechRecognizer(
            recognizers: [.whisperKitLargeV3Turbo: backend],
            productASRDeadline: .milliseconds(20),
            productASRCancellationGrace: .milliseconds(20)
        )
        let timedOutSessionID = DictationSessionID(rawValue: 90_002)
        let blockedSessionID = DictationSessionID(rawValue: 90_003)
        let recoveredSessionID = DictationSessionID(rawValue: 90_004)
        await router.register(.whisperKitLargeV3Turbo, for: timedOutSessionID)
        await router.register(.whisperKitLargeV3Turbo, for: blockedSessionID)
        let timedOut = expectation(description: "deadline quarantines the backend")

        let operation = Task<Result<RawTranscript, Error>, Never> {
            let result: Result<RawTranscript, Error>
            do {
                result = .success(
                    try await router.transcribe(
                        AudioInput(buffer: AudioBufferHandle(rawValue: 90_002)),
                        hints: RecognitionHints(language: .english, terms: []),
                        sessionID: timedOutSessionID
                    )
                )
            } catch {
                result = .failure(error)
            }
            timedOut.fulfill()
            return result
        }

        let waitResult = await XCTWaiter.fulfillment(of: [timedOut], timeout: 0.25)
        guard waitResult == .completed else {
            await backend.releaseBlockedOperations()
            _ = await operation.value
            return XCTFail("Deadline did not return while backend cancellation was blocked")
        }

        do {
            _ = try await router.transcribe(
                AudioInput(buffer: AudioBufferHandle(rawValue: 90_003)),
                hints: RecognitionHints(language: .english, terms: []),
                sessionID: blockedSessionID
            )
            XCTFail("Expected the quarantined backend to remain busy")
        } catch {
            XCTAssertEqual(
                error as? SessionModelSpeechRecognizerError,
                .recognizerBusy(activePurpose: .liveDictation)
            )
        }

        await backend.releaseBlockedOperations()
        _ = await operation.value
        try await acquireAfterQuarantineClears(router, sessionID: recoveredSessionID)
        await router.releaseExclusiveAccess(for: recoveredSessionID)
    }

    func testExplicitCancelReturnsAndQuarantinesCancellationIgnoringBackend() async throws {
        let backend = CancellationIgnoringSpeechRecognizer()
        let router = SessionModelSpeechRecognizer(
            recognizers: [.whisperKitLargeV3Turbo: backend],
            productASRDeadline: .seconds(10),
            productASRCancellationGrace: .milliseconds(20)
        )
        let activeSessionID = DictationSessionID(rawValue: 90_005)
        let blockedSessionID = DictationSessionID(rawValue: 90_006)
        let recoveredSessionID = DictationSessionID(rawValue: 90_007)
        await router.register(.whisperKitLargeV3Turbo, for: activeSessionID)
        await router.register(.whisperKitLargeV3Turbo, for: blockedSessionID)

        let recognition = Task {
            try await router.transcribe(
                AudioInput(buffer: AudioBufferHandle(rawValue: 90_005)),
                hints: RecognitionHints(language: .english, terms: []),
                sessionID: activeSessionID
            )
        }
        await backend.waitUntilTranscriptionStarts()

        let completed = expectation(description: "explicit cancellation returns")
        let cancellation = Task {
            await router.cancel(sessionID: activeSessionID)
            completed.fulfill()
        }

        let waitResult = await XCTWaiter.fulfillment(of: [completed], timeout: 0.25)
        XCTAssertEqual(waitResult, .completed)
        do {
            _ = try await router.transcribe(
                AudioInput(buffer: AudioBufferHandle(rawValue: 90_006)),
                hints: RecognitionHints(language: .english, terms: []),
                sessionID: blockedSessionID
            )
            XCTFail("Expected explicit cancellation to quarantine the backend")
        } catch {
            XCTAssertEqual(
                error as? SessionModelSpeechRecognizerError,
                .recognizerBusy(activePurpose: .liveDictation)
            )
        }

        await backend.releaseBlockedOperations()
        await cancellation.value
        _ = try? await recognition.value
        try await acquireAfterQuarantineClears(router, sessionID: recoveredSessionID)
        await router.releaseExclusiveAccess(for: recoveredSessionID)
    }

    func testExplicitCancelWithoutRecognitionReturnsAndQuarantinesBackend() async throws {
        let backend = CancellationIgnoringSpeechRecognizer()
        let router = SessionModelSpeechRecognizer(
            recognizers: [.whisperKitLargeV3Turbo: backend],
            productASRDeadline: .seconds(10),
            productASRCancellationGrace: .milliseconds(20)
        )
        let cancelledSessionID = DictationSessionID(rawValue: 90_008)
        let blockedSessionID = DictationSessionID(rawValue: 90_009)
        let recoveredSessionID = DictationSessionID(rawValue: 90_010)
        await router.register(.whisperKitLargeV3Turbo, for: cancelledSessionID)
        await router.register(.whisperKitLargeV3Turbo, for: blockedSessionID)
        try await router.acquireExclusiveAccess(
            for: cancelledSessionID,
            purpose: .liveDictation
        )

        let completed = expectation(description: "cancel without recognition returns")
        let cancellation = Task {
            await router.cancel(sessionID: cancelledSessionID)
            completed.fulfill()
        }

        let waitResult = await XCTWaiter.fulfillment(of: [completed], timeout: 0.25)
        XCTAssertEqual(waitResult, .completed)
        do {
            try await router.acquireExclusiveAccess(
                for: blockedSessionID,
                purpose: .historyRetranscription
            )
            XCTFail("Expected cancellation-only quarantine to retain the backend lease")
        } catch {
            XCTAssertEqual(
                error as? SessionModelSpeechRecognizerError,
                .recognizerBusy(activePurpose: .liveDictation)
            )
        }

        await backend.releaseBlockedOperations()
        await cancellation.value
        try await acquireAfterQuarantineClears(router, sessionID: recoveredSessionID)
        await router.releaseExclusiveAccess(for: recoveredSessionID)
    }

    func testBlockedLifecycleUsesRecognitionDeadlineInsteadOfReportingBusy() async {
        let backend = CancellationIgnoringLifecycleRecognizer()
        let router = SessionModelSpeechRecognizer(
            recognizers: [.whisperKitLargeV3Turbo: backend],
            productASRDeadline: .milliseconds(80),
            productASRCancellationGrace: .milliseconds(20)
        )
        let history = DeadlineRecordingHistorySpy()
        let coordinator = DictationCoordinator(
            contextProvider: DeadlineContextProvider(),
            audioCapture: DeadlineStreamingAudioCapture(),
            recognizer: router,
            cleanup: DeadlineCleanup(),
            enrichment: DeadlineEnrichment(),
            insertion: DeadlineInsertion(),
            recordingHistory: history
        )
        guard case let .started(sessionID) = await coordinator.start() else {
            return XCTFail("Expected the coordinator to start")
        }
        await router.register(.whisperKitLargeV3Turbo, for: sessionID)
        await coordinator.beginIncrementalRecognition(sessionID: sessionID)
        await backend.waitUntilLifecycleStarts()

        let clock = ContinuousClock()
        let startedAt = clock.now
        let outcome = await coordinator.stop(sessionID: sessionID)
        let elapsed = startedAt.duration(to: clock.now)
        let events = await history.events()
        let transcriptionCount = await backend.transcriptionCount()

        XCTAssertEqual(
            outcome,
            .failed(sessionID, DictationFailure(stage: .recognition, reason: .recognitionTimedOut))
        )
        XCTAssertLessThan(elapsed, .seconds(2))
        XCTAssertEqual(events, ["begin", "audio", "failed"])
        XCTAssertEqual(transcriptionCount, 0)

        await backend.releaseBlockedOperations()
    }

    func testEarlyReleaseWaitsForPreparationAndNextSessionCanAcquire() async throws {
        let backend = CancellationIgnoringLifecycleRecognizer()
        let router = SessionModelSpeechRecognizer(
            recognizers: [.whisperKitLargeV3Turbo: backend],
            productASRDeadline: .seconds(2),
            productASRCancellationGrace: .milliseconds(20)
        )
        let session = DictationSessionID(rawValue: 90_020)
        let hints = RecognitionHints(language: .german, terms: [])
        await router.register(.whisperKitLargeV3Turbo, for: session)
        let startup = Task { try await router.startRecognitionSession(hints: hints, sessionID: session) }
        await backend.waitUntilLifecycleStarts()
        await router.stopRecognitionSession(sessionID: session)
        let final = Task {
            try await router.finalizeRecognitionSession(
                AudioInput(buffer: AudioBufferHandle(rawValue: 90_020)),
                hints: hints, sessionID: session
            )
        }
        try await Task.sleep(for: .milliseconds(60))
        let beforeRelease = await backend.transcriptionCount()
        XCTAssertEqual(beforeRelease, 0)
        await backend.releaseBlockedOperations()
        try await startup.value
        let transcript = try await final.value
        XCTAssertFalse(transcript.text.isEmpty)
        await router.cancel(sessionID: session)
        try await router.acquireExclusiveAccess(
            for: DictationSessionID(rawValue: 90_021), purpose: .liveDictation
        )
    }

    func testStopBeforeStartupRejectsLateLifecycleButAllowsFinalDecode() async throws {
        let backend = CancellationIgnoringLifecycleRecognizer()
        let router = SessionModelSpeechRecognizer(recognizers: [.whisperKitLargeV3Turbo: backend])
        let session = DictationSessionID(rawValue: 90_022)
        let hints = RecognitionHints(language: .german, terms: [])
        await router.register(.whisperKitLargeV3Turbo, for: session)
        await backend.releaseBlockedOperations()
        await router.stopRecognitionSession(sessionID: session)
        do {
            try await router.startRecognitionSession(hints: hints, sessionID: session)
            XCTFail("A stopped session must not start a late lifecycle operation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let transcript = try await router.transcribe(
            AudioInput(buffer: AudioBufferHandle(rawValue: 90_022)), hints: hints, sessionID: session
        )
        XCTAssertFalse(transcript.text.isEmpty)
        await router.cancel(sessionID: session)
    }

    func testExplicitCancelAfterEarlyStopReturnsBeforePreparationDrains() async throws {
        let backend = CancellationIgnoringLifecycleRecognizer()
        let router = SessionModelSpeechRecognizer(
            recognizers: [.whisperKitLargeV3Turbo: backend],
            productASRCancellationGrace: .milliseconds(20)
        )
        let session = DictationSessionID(rawValue: 90_023)
        let next = DictationSessionID(rawValue: 90_024)
        await router.register(.whisperKitLargeV3Turbo, for: session)
        let startup = Task {
            try await router.startRecognitionSession(
                hints: RecognitionHints(language: .german, terms: []), sessionID: session
            )
        }
        await backend.waitUntilLifecycleStarts()
        await router.stopRecognitionSession(sessionID: session)
        let returned = expectation(description: "cancel remains bounded during preparation")
        Task { await router.cancel(sessionID: session); returned.fulfill() }
        let result = await XCTWaiter.fulfillment(of: [returned], timeout: 0.5)
        XCTAssertEqual(result, .completed)
        do {
            try await router.acquireExclusiveAccess(for: next, purpose: .liveDictation)
            XCTFail("Cancelled preparation still owns the backend until it drains")
        } catch {
            XCTAssertEqual(error as? SessionModelSpeechRecognizerError,
                           .recognizerBusy(activePurpose: .liveDictation))
        }
        await backend.releaseBlockedOperations()
        _ = try? await startup.value
        try await acquireAfterQuarantineClears(router, sessionID: next)
        let decodeCount = await backend.transcriptionCount()
        XCTAssertEqual(decodeCount, 0)
    }

    private func acquireAfterQuarantineClears(
        _ router: SessionModelSpeechRecognizer,
        sessionID: DictationSessionID
    ) async throws {
        let deadline = ContinuousClock().now.advanced(by: .seconds(1))
        while ContinuousClock().now < deadline {
            do {
                try await router.acquireExclusiveAccess(
                    for: sessionID,
                    purpose: .historyRetranscription
                )
                return
            } catch SessionModelSpeechRecognizerError.recognizerBusy {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        XCTFail("Backend lease stayed quarantined after its operations quiesced")
    }
}

private actor CancellationIgnoringLifecycleRecognizer:
    SpeechRecognizing,
    SpeechRecognitionLifecycle {
    private var lifecycleStarted = false
    private var isReleased = false
    private var lifecycleStartContinuations: [CheckedContinuation<Void, Never>] = []
    private var blockedContinuations: [UnsafeContinuation<Void, Never>] = []
    private var transcriptions = 0

    func transcribe(
        _ audio: AudioInput,
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws -> RawTranscript {
        transcriptions += 1
        return RawTranscript(text: "unexpected", language: hints.language)
    }

    func cancel(sessionID: DictationSessionID) async {}

    func prepareForRecording(
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws {}

    func startRecognitionSession(
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws {
        lifecycleStarted = true
        lifecycleStartContinuations.forEach { $0.resume() }
        lifecycleStartContinuations.removeAll()
        await blockIgnoringCancellation()
    }

    func updateRecognitionSession(
        with chunk: RecognitionAudioChunk,
        sessionID: DictationSessionID
    ) async throws -> RecognitionChunkDisposition {
        await blockIgnoringCancellation()
        return .accepted
    }

    func stopRecognitionSession(sessionID: DictationSessionID) async {
        await blockIgnoringCancellation()
    }

    func finalizeRecognitionSession(
        _ audio: AudioInput,
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws -> RawTranscript {
        transcriptions += 1
        return RawTranscript(text: "unexpected", language: hints.language)
    }

    func waitUntilLifecycleStarts() async {
        guard !lifecycleStarted else { return }
        await withCheckedContinuation { continuation in
            lifecycleStartContinuations.append(continuation)
        }
    }

    func releaseBlockedOperations() {
        isReleased = true
        blockedContinuations.forEach { $0.resume() }
        blockedContinuations.removeAll()
    }

    func transcriptionCount() -> Int { transcriptions }

    private func blockIgnoringCancellation() async {
        guard !isReleased else { return }
        await withUnsafeContinuation { continuation in
            blockedContinuations.append(continuation)
        }
    }
}

private struct DeadlineContextProvider: TargetContextProviding {
    func capture(for sessionID: DictationSessionID) async throws -> CapturedTargetContext {
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

    func cancel(sessionID: DictationSessionID) async {}
}

private actor DeadlineStreamingAudioCapture: AudioCapturing, IncrementalAudioProviding {
    func startCapture(for sessionID: DictationSessionID) async throws {}

    func finishCapture(for sessionID: DictationSessionID) async throws -> AudioInput {
        AudioInput(buffer: AudioBufferHandle(rawValue: sessionID.rawValue))
    }

    func incrementalAudioBatch(
        for sessionID: DictationSessionID,
        afterFrameOffset frameOffset: Int
    ) async throws -> IncrementalAudioBatch? {
        nil
    }

    func cancelCapture(for sessionID: DictationSessionID) async {}
    func release(_ input: AudioInput) async {}
}

private struct DeadlineCleanup: TextCleaning {
    func clean(
        _ transcript: RawTranscript,
        context: ContextSnapshot,
        sessionID: DictationSessionID
    ) async throws -> LocalCandidate {
        LocalCandidate(text: transcript.text)
    }
}

private struct DeadlineEnrichment: TextEnriching {
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

private struct DeadlineInsertion: TextInserting {
    func insert(
        _ candidate: FinalCandidate,
        sessionID: DictationSessionID
    ) async throws -> InsertionOutcome {
        .confirmedDirect
    }

    func requestCancellation(
        sessionID: DictationSessionID
    ) async -> InsertionCancellationDisposition {
        .cancelledBeforeCommit
    }

    func releaseInsertionSession(sessionID: DictationSessionID) async {}
}

private actor DeadlineRecordingHistorySpy: RecordingHistoryRecording {
    private var recordedEvents: [String] = []

    func begin(sessionID: DictationSessionID, language: DictationLanguage) {
        recordedEvents.append("begin")
    }

    func persistCheckpoint(
        _ chunk: RecognitionAudioChunk,
        sessionID: DictationSessionID
    ) {}

    func persistAudio(_ input: AudioInput, sessionID: DictationSessionID) {
        recordedEvents.append("audio")
    }

    func persistTranscript(_ transcript: RawTranscript, sessionID: DictationSessionID) {}

    func markFailed(sessionID: DictationSessionID) {
        recordedEvents.append("failed")
    }

    func interrupt(sessionID: DictationSessionID) {}

    func events() -> [String] { recordedEvents }
}

private actor CancellationIgnoringSpeechRecognizer: SpeechRecognizing {
    private var isReleased = false
    private var transcriptionStarted = false
    private var transcriptionStartContinuations: [CheckedContinuation<Void, Never>] = []
    private var transcriptContinuations: [UnsafeContinuation<RawTranscript, Never>] = []
    private var cancellationContinuations: [UnsafeContinuation<Void, Never>] = []

    func transcribe(
        _ audio: AudioInput,
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws -> RawTranscript {
        transcriptionStarted = true
        transcriptionStartContinuations.forEach { $0.resume() }
        transcriptionStartContinuations.removeAll()
        guard !isReleased else {
            return RawTranscript(text: "released during test cleanup", language: .english)
        }
        return await withUnsafeContinuation { continuation in
            transcriptContinuations.append(continuation)
        }
    }

    func cancel(sessionID: DictationSessionID) async {
        guard !isReleased else { return }
        await withUnsafeContinuation { continuation in
            cancellationContinuations.append(continuation)
        }
    }

    func releaseBlockedOperations() {
        isReleased = true
        transcriptContinuations.forEach {
            $0.resume(
                returning: RawTranscript(text: "released during test cleanup", language: .english)
            )
        }
        transcriptContinuations.removeAll()
        cancellationContinuations.forEach { $0.resume() }
        cancellationContinuations.removeAll()
    }

    func waitUntilTranscriptionStarts() async {
        guard !transcriptionStarted else { return }
        await withCheckedContinuation { continuation in
            transcriptionStartContinuations.append(continuation)
        }
    }
}
