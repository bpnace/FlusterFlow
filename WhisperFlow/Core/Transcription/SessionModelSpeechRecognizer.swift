import Foundation

enum SessionModelSpeechRecognizerError: Error, Equatable, Sendable {
    case sessionNotRegistered
    case recognizerUnavailable
    case recognizerBusy(activePurpose: LocalRecognitionLeasePurpose)
}

enum ProductASRDeadlineError: Error, Equatable, Sendable {
    case exceeded
}

enum ProductASRDeadlineContext {
    @TaskLocal static var deadline: ContinuousClock.Instant?

    static func requireRemainingBudget(clock: ContinuousClock = ContinuousClock()) throws {
        guard let deadline else { return }
        guard clock.now < deadline else {
            throw ProductASRDeadlineError.exceeded
        }
    }
}

private enum RecognitionRaceResult: Sendable {
    case completed(Result<RawTranscript, Error>)
    case timedOut
}

enum LocalRecognitionLeasePurpose: Equatable, Sendable {
    case liveDictation
    case historyRetranscription
    case modelMaintenance
}

actor SessionModelSpeechRecognizer: SpeechRecognizing, SpeechRecognitionLifecycle {
    private struct RecognitionLease: Equatable, Sendable {
        let sessionID: DictationSessionID
        let purpose: LocalRecognitionLeasePurpose
    }

    private struct CancellationOperation: Sendable {
        let id: UUID
        let task: Task<Void, Never>
        let completion: QuiescenceCompletion
    }

    private struct RecognitionOperation: Sendable {
        let id: UUID
        let task: Task<RawTranscript, Error>
        let completion: RecognitionCompletion
    }

    private struct LifecycleOperation: Sendable {
        let id: UUID
        let cancel: @Sendable () -> Void
        let waitForCompletion: @Sendable () async -> Void
    }

    private let recognizers: [LocalModelChoice: any SpeechRecognizing]
    private let productASRDeadline: Duration
    private let productASRCancellationGrace: Duration
    private var choices: [DictationSessionID: LocalModelChoice] = [:]
    private var recognitionLease: RecognitionLease?
    private var recognitionOperations: [DictationSessionID: RecognitionOperation] = [:]
    private var lifecycleOperations: [DictationSessionID: LifecycleOperation] = [:]
    private var cancellationOperations: [DictationSessionID: CancellationOperation] = [:]
    private var quarantinedSessions: Set<DictationSessionID> = []

    init(
        recognizers: [LocalModelChoice: any SpeechRecognizing],
        productASRDeadline: Duration = .seconds(30),
        productASRCancellationGrace: Duration = .seconds(1)
    ) {
        self.recognizers = recognizers
        self.productASRDeadline = productASRDeadline
        self.productASRCancellationGrace = productASRCancellationGrace
    }

    func register(_ choice: LocalModelChoice, for sessionID: DictationSessionID) {
        choices[sessionID] = choice
    }

    func acquireExclusiveAccess(
        for sessionID: DictationSessionID,
        purpose: LocalRecognitionLeasePurpose
    ) throws {
        _ = try claimExclusiveAccess(for: sessionID, purpose: purpose)
    }

    func releaseExclusiveAccess(for sessionID: DictationSessionID) {
        guard recognitionLease?.sessionID == sessionID else { return }
        recognitionLease = nil
    }

    func transcribe(
        _ audio: AudioInput,
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws -> RawTranscript {
        let acquiredLease = try claimExclusiveAccess(
            for: sessionID,
            purpose: .liveDictation
        )
        defer {
            if acquiredLease { releaseExclusiveAccessUnlessQuarantined(for: sessionID) }
        }
        guard let choice = choices[sessionID] else {
            throw SessionModelSpeechRecognizerError.sessionNotRegistered
        }
        guard let recognizer = recognizers[choice] else {
            throw SessionModelSpeechRecognizerError.recognizerUnavailable
        }
        return try await runRecognitionOperation(
            sessionID: sessionID,
            cancelUnderlyingRecognition: {
                await recognizer.cancel(sessionID: sessionID)
            },
            operation: {
                try await recognizer.transcribe(
                    audio,
                    hints: hints,
                    sessionID: sessionID
                )
            }
        )
    }

    func cancel(sessionID: DictationSessionID) async {
        if let operation = cancellationOperations[sessionID] {
            guard !quarantinedSessions.contains(sessionID) else { return }
            quarantinedSessions.insert(sessionID)
            if await waitForCancellation(
                operation,
                grace: productASRCancellationGrace
            ) {
                finishCancellation(operation, sessionID: sessionID)
            }
            return
        }
        guard let choice = choices.removeValue(forKey: sessionID),
              let recognizer = recognizers[choice] else {
            releaseExclusiveAccess(for: sessionID)
            return
        }
        let recognition = recognitionOperations[sessionID]
        let lifecycle = lifecycleOperations[sessionID]
        if recognitionLease == nil {
            recognitionLease = RecognitionLease(
                sessionID: sessionID,
                purpose: .liveDictation
            )
        }
        let operationID = UUID()
        let completion = QuiescenceCompletion()
        let operation = CancellationOperation(
            id: operationID,
            task: Task { [weak self] in
                recognition?.task.cancel()
                lifecycle?.cancel()
                await recognizer.cancel(sessionID: sessionID)
                if let recognition {
                    _ = await recognition.task.result
                }
                await lifecycle?.waitForCompletion()
                await self?.finishCancellation(id: operationID, sessionID: sessionID)
                await completion.complete()
            },
            completion: completion
        )
        cancellationOperations[sessionID] = operation
        quarantinedSessions.insert(sessionID)
        if await waitForCancellation(
            operation,
            grace: productASRCancellationGrace
        ) {
            finishCancellation(operation, sessionID: sessionID)
        }
    }

    func prepareForRecording(
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws {
        let acquiredLease = try claimExclusiveAccess(
            for: sessionID,
            purpose: .liveDictation
        )
        do {
            let recognizer = try recognizer(for: sessionID)
            if let lifecycle = recognizer as? any SpeechRecognitionLifecycle {
                try await runLifecycleOperation(sessionID: sessionID) {
                    try await lifecycle.prepareForRecording(
                        hints: hints,
                        sessionID: sessionID
                    )
                }
            }
        } catch {
            if acquiredLease { releaseExclusiveAccess(for: sessionID) }
            throw error
        }
    }

    func startRecognitionSession(
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws {
        let acquiredLease = try claimExclusiveAccess(
            for: sessionID,
            purpose: .liveDictation
        )
        do {
            let recognizer = try recognizer(for: sessionID)
            if let lifecycle = recognizer as? any SpeechRecognitionLifecycle {
                try await runLifecycleOperation(sessionID: sessionID) {
                    try await lifecycle.startRecognitionSession(
                        hints: hints,
                        sessionID: sessionID
                    )
                }
            }
        } catch {
            if acquiredLease { releaseExclusiveAccess(for: sessionID) }
            throw error
        }
    }

    func updateRecognitionSession(
        with chunk: RecognitionAudioChunk,
        sessionID: DictationSessionID
    ) async throws -> RecognitionChunkDisposition {
        let acquiredLease = try claimExclusiveAccess(
            for: sessionID,
            purpose: .liveDictation
        )
        do {
            let recognizer = try recognizer(for: sessionID)
            guard let lifecycle = recognizer as? any SpeechRecognitionLifecycle else {
                return .ignoredBatchRecognizer
            }
            return try await runLifecycleOperation(sessionID: sessionID) {
                try await lifecycle.updateRecognitionSession(
                    with: chunk,
                    sessionID: sessionID
                )
            }
        } catch {
            if acquiredLease { releaseExclusiveAccess(for: sessionID) }
            throw error
        }
    }

    func stopRecognitionSession(sessionID: DictationSessionID) async {
        if let existing = cancellationOperations[sessionID] {
            if await waitForCancellation(
                existing,
                grace: productASRCancellationGrace
            ) {
                finishCancellation(existing, sessionID: sessionID)
            }
            return
        }
        guard let recognizer = try? recognizer(for: sessionID),
              let lifecycle = recognizer as? any SpeechRecognitionLifecycle else {
            return
        }
        let activeLifecycle = lifecycleOperations[sessionID]
        let cancellationID = UUID()
        let completion = QuiescenceCompletion()
        let cancellation = CancellationOperation(
            id: cancellationID,
            task: Task { [weak self] in
                activeLifecycle?.cancel()
                await lifecycle.stopRecognitionSession(sessionID: sessionID)
                await activeLifecycle?.waitForCompletion()
                await self?.finishCancellation(id: cancellationID, sessionID: sessionID)
                await completion.complete()
            },
            completion: completion
        )
        cancellationOperations[sessionID] = cancellation
        quarantinedSessions.insert(sessionID)
        if await waitForCancellation(
            cancellation,
            grace: productASRCancellationGrace
        ) {
            finishCancellation(cancellation, sessionID: sessionID)
        } else {
            choices[sessionID] = nil
        }
    }

    func finalizeRecognitionSession(
        _ audio: AudioInput,
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws -> RawTranscript {
        let acquiredLease = try claimExclusiveAccess(
            for: sessionID,
            purpose: .liveDictation
        )
        defer {
            if acquiredLease { releaseExclusiveAccessUnlessQuarantined(for: sessionID) }
        }
        let recognizer = try recognizer(for: sessionID)
        return try await runRecognitionOperation(
            sessionID: sessionID,
            cancelUnderlyingRecognition: {
                await recognizer.cancel(sessionID: sessionID)
            },
            operation: {
                if let lifecycle = recognizer as? any SpeechRecognitionLifecycle {
                    return try await lifecycle.finalizeRecognitionSession(
                        audio,
                        hints: hints,
                        sessionID: sessionID
                    )
                }
                return try await recognizer.transcribe(
                    audio,
                    hints: hints,
                    sessionID: sessionID
                )
            }
        )
    }

    private func recognizer(
        for sessionID: DictationSessionID
    ) throws -> any SpeechRecognizing {
        guard let choice = choices[sessionID] else {
            throw SessionModelSpeechRecognizerError.sessionNotRegistered
        }
        guard let recognizer = recognizers[choice] else {
            throw SessionModelSpeechRecognizerError.recognizerUnavailable
        }
        return recognizer
    }

    private func claimExclusiveAccess(
        for sessionID: DictationSessionID,
        purpose: LocalRecognitionLeasePurpose
    ) throws -> Bool {
        if quarantinedSessions.contains(sessionID), let recognitionLease {
            throw SessionModelSpeechRecognizerError.recognizerBusy(
                activePurpose: recognitionLease.purpose
            )
        }
        if let recognitionLease {
            guard recognitionLease.sessionID == sessionID else {
                throw SessionModelSpeechRecognizerError.recognizerBusy(
                    activePurpose: recognitionLease.purpose
                )
            }
            return false
        }
        recognitionLease = RecognitionLease(sessionID: sessionID, purpose: purpose)
        return true
    }

    private func runLifecycleOperation<Value: Sendable>(
        sessionID: DictationSessionID,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        if let lease = recognitionLease,
           lifecycleOperations[sessionID] != nil {
            throw SessionModelSpeechRecognizerError.recognizerBusy(
                activePurpose: lease.purpose
            )
        }
        let task = Task(operation: operation)
        let lifecycle = LifecycleOperation(
            id: UUID(),
            cancel: { task.cancel() },
            waitForCompletion: { _ = await task.result }
        )
        lifecycleOperations[sessionID] = lifecycle
        defer { finishLifecycle(lifecycle, sessionID: sessionID) }
        return try await task.value
    }

    private func runRecognitionOperation(
        sessionID: DictationSessionID,
        cancelUnderlyingRecognition: @escaping @Sendable () async -> Void,
        operation: @escaping @Sendable () async throws -> RawTranscript
    ) async throws -> RawTranscript {
        if let lease = recognitionLease,
           recognitionOperations[sessionID] != nil {
            throw SessionModelSpeechRecognizerError.recognizerBusy(
                activePurpose: lease.purpose
            )
        }
        let clock = ContinuousClock()
        let deadlineDuration = productASRDeadline
        let cancellationGrace = productASRCancellationGrace
        let deadline = clock.now.advanced(by: deadlineDuration)
        return try await ProductASRDeadlineContext.$deadline.withValue(deadline) {
            let completion = RecognitionCompletion()
            let recognition = RecognitionOperation(
                id: UUID(),
                task: Task {
                    do {
                        let transcript = try await operation()
                        await completion.complete(.success(transcript))
                        return transcript
                    } catch {
                        await completion.complete(.failure(error))
                        throw error
                    }
                },
                completion: completion
            )
            recognitionOperations[sessionID] = recognition
            defer { finishRecognition(recognition, sessionID: sessionID) }

            switch await raceRecognition(
                recognition,
                deadline: deadlineDuration
            ) {
            case .completed(let result):
                return try result.get()
            case .timedOut:
                choices[sessionID] = nil
                quarantinedSessions.insert(sessionID)
                let cancellation = beginCancellation(
                    recognition: recognition,
                    sessionID: sessionID,
                    cancelUnderlyingRecognition: cancelUnderlyingRecognition
                )
                let quiesced = await waitForCancellation(
                    cancellation,
                    grace: cancellationGrace
                )
                if quiesced {
                    finishCancellation(cancellation, sessionID: sessionID)
                }
                throw ProductASRDeadlineError.exceeded
            }
        }
    }

    private func finishRecognition(
        _ operation: RecognitionOperation,
        sessionID: DictationSessionID
    ) {
        guard recognitionOperations[sessionID]?.id == operation.id else { return }
        recognitionOperations[sessionID] = nil
    }

    private func finishLifecycle(
        _ operation: LifecycleOperation,
        sessionID: DictationSessionID
    ) {
        guard lifecycleOperations[sessionID]?.id == operation.id else { return }
        lifecycleOperations[sessionID] = nil
    }

    private func finishCancellation(
        _ operation: CancellationOperation,
        sessionID: DictationSessionID
    ) {
        finishCancellation(id: operation.id, sessionID: sessionID)
    }

    private func finishCancellation(
        id: UUID,
        sessionID: DictationSessionID
    ) {
        guard cancellationOperations[sessionID]?.id == id else { return }
        cancellationOperations[sessionID] = nil
        quarantinedSessions.remove(sessionID)
        releaseExclusiveAccess(for: sessionID)
    }

    private func releaseExclusiveAccessUnlessQuarantined(
        for sessionID: DictationSessionID
    ) {
        guard !quarantinedSessions.contains(sessionID) else { return }
        releaseExclusiveAccess(for: sessionID)
    }

    private func beginCancellation(
        recognition: RecognitionOperation,
        sessionID: DictationSessionID,
        cancelUnderlyingRecognition: @escaping @Sendable () async -> Void
    ) -> CancellationOperation {
        if let existing = cancellationOperations[sessionID] {
            return existing
        }
        let cancellationID = UUID()
        let completion = QuiescenceCompletion()
        let cancellation = CancellationOperation(
            id: cancellationID,
            task: Task { [weak self] in
                recognition.task.cancel()
                await cancelUnderlyingRecognition()
                _ = await recognition.task.result
                await self?.finishCancellation(id: cancellationID, sessionID: sessionID)
                await completion.complete()
            },
            completion: completion
        )
        cancellationOperations[sessionID] = cancellation
        return cancellation
    }

    private func waitForCancellation(
        _ cancellation: CancellationOperation,
        grace: Duration
    ) async -> Bool {
        await cancellation.completion.wait(grace: grace)
    }

    private func raceRecognition(
        _ recognition: RecognitionOperation,
        deadline: Duration
    ) async -> RecognitionRaceResult {
        await recognition.completion.wait(deadline: deadline)
    }
}

private actor RecognitionCompletion {
    private var result: Result<RawTranscript, Error>?
    private var continuation: CheckedContinuation<RecognitionRaceResult, Never>?
    private var timer: Task<Void, Never>?

    func wait(deadline: Duration) async -> RecognitionRaceResult {
        if let result {
            return .completed(result)
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            timer = Task { [weak self] in
                try? await Task.sleep(for: deadline)
                guard !Task.isCancelled else { return }
                await self?.timeout()
            }
        }
    }

    func complete(_ result: Result<RawTranscript, Error>) {
        self.result = result
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        timer = nil
        continuation.resume(returning: .completed(result))
    }

    private func timeout() {
        guard let continuation else { return }
        self.continuation = nil
        timer = nil
        continuation.resume(returning: .timedOut)
    }
}

private actor QuiescenceCompletion {
    private var isComplete = false
    private var continuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var timers: [UUID: Task<Void, Never>] = [:]

    func wait(grace: Duration) async -> Bool {
        if isComplete { return true }
        let waitID = UUID()
        return await withCheckedContinuation { continuation in
            continuations[waitID] = continuation
            timers[waitID] = Task { [weak self] in
                try? await Task.sleep(for: grace)
                guard !Task.isCancelled else { return }
                await self?.timeout(waitID: waitID)
            }
        }
    }

    func complete() {
        isComplete = true
        let pendingContinuations = Array(continuations.values)
        continuations.removeAll()
        timers.values.forEach { $0.cancel() }
        timers.removeAll()
        pendingContinuations.forEach { $0.resume(returning: true) }
    }

    private func timeout(waitID: UUID) {
        guard let continuation = continuations.removeValue(forKey: waitID) else { return }
        timers[waitID] = nil
        continuation.resume(returning: false)
    }
}
