import Foundation

actor DictationCoordinator {
    private struct InsertionCancellationRequest: Sendable {
        let sessionID: DictationSessionID
        let task: Task<InsertionCancellationDisposition, Never>
    }

    private let contextProvider: any TargetContextProviding
    private let audioCapture: any AudioCapturing
    private let recognizer: any SpeechRecognizing
    private let cleanup: any TextCleaning
    private let enrichment: any TextEnriching
    private let localRewriter: (any TextRewriting)?
    private let insertion: any TextInserting
    private let fallbackText: (any EphemeralTextPreserving)?
    private let prioritizedLexiconTerms: @Sendable (DictationLanguage) async -> [String]

    private var nextSessionRawValue: UInt64 = 0
    private var phase: DictationPhase = .idle
    private var session: DictationSession?
    private var insertionCancellationRequest: InsertionCancellationRequest?
    private var incrementalRecognitionTasks: [DictationSessionID: Task<Void, Never>] = [:]

    init(
        contextProvider: any TargetContextProviding,
        audioCapture: any AudioCapturing,
        recognizer: any SpeechRecognizing,
        cleanup: any TextCleaning,
        enrichment: any TextEnriching,
        localRewriter: (any TextRewriting)? = nil,
        insertion: any TextInserting,
        fallbackText: (any EphemeralTextPreserving)? = nil,
        prioritizedLexiconTerms: @escaping @Sendable (DictationLanguage) async -> [String] = { _ in [] }
    ) {
        self.contextProvider = contextProvider
        self.audioCapture = audioCapture
        self.recognizer = recognizer
        self.cleanup = cleanup
        self.enrichment = enrichment
        self.localRewriter = localRewriter
        self.insertion = insertion
        self.fallbackText = fallbackText
        self.prioritizedLexiconTerms = prioritizedLexiconTerms
    }

    func snapshot() -> DictationSnapshot {
        DictationSnapshot(phase: phase, activeSessionID: session?.id)
    }

    func start(language: DictationLanguage = .automatic) async -> StartOutcome {
        if !phase.canStart, let activeID = session?.id {
            return .alreadyActive(activeID)
        }

        nextSessionRawValue &+= 1
        let sessionID = DictationSessionID(rawValue: nextSessionRawValue)
        insertionCancellationRequest = nil
        session = DictationSession(
            id: sessionID,
            language: language,
            capturedTargetContext: nil,
            audioInput: nil,
            rawTranscript: nil,
            localCandidate: nil
        )
        phase = .priming

        let capturedTargetContext: CapturedTargetContext
        do {
            capturedTargetContext = try await contextProvider.capture(for: sessionID)
        } catch {
            return await failCurrent(sessionID, at: .context)
        }

        guard isCurrent(sessionID, expected: .priming) else {
            return .ignoredStale(sessionID)
        }
        guard capturedTargetContext.target.isRegistered,
              capturedTargetContext.context.availability != .deniedSensitive else {
            return await failCurrent(sessionID, at: .context)
        }
        session?.capturedTargetContext = capturedTargetContext

        do {
            try await audioCapture.startCapture(for: sessionID)
        } catch {
            return await failCurrent(sessionID, at: .audioStart)
        }

        guard isCurrent(sessionID, expected: .priming) else {
            await audioCapture.cancelCapture(for: sessionID)
            return .ignoredStale(sessionID)
        }

        phase = .listening
        return .started(sessionID)
    }

    func beginIncrementalRecognition(sessionID: DictationSessionID) async {
        guard isCurrent(sessionID, expected: .listening),
              incrementalRecognitionTasks[sessionID] == nil,
              let provider = audioCapture as? any IncrementalAudioProviding,
              let lifecycle = recognizer as? any SpeechRecognitionLifecycle,
              let language = session?.language,
              let context = session?.capturedTargetContext?.context else {
            return
        }

        let hints = await recognitionHints(language: language, context: context)
        guard isCurrent(sessionID, expected: .listening) else { return }

        incrementalRecognitionTasks[sessionID] = Task {
            do {
                try await lifecycle.startRecognitionSession(
                    hints: hints,
                    sessionID: sessionID
                )
                var frameOffset = 0
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(500))
                    guard let batch = try await provider.incrementalAudioBatch(
                        for: sessionID,
                        afterFrameOffset: frameOffset
                    ) else {
                        continue
                    }
                    frameOffset = batch.nextFrameOffset
                    let disposition = try await lifecycle.updateRecognitionSession(
                        with: batch.chunk,
                        sessionID: sessionID
                    )
                    if disposition == .ignoredBatchRecognizer {
                        return
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                // Streaming is best effort. Final recognition still receives
                // the canonical, VAD-normalized recording.
                return
            }
        }
    }

    func stop(
        sessionID: DictationSessionID,
        consent: ConsentSnapshot = .localOnly
    ) async -> StopOutcome {
        guard session?.id == sessionID else {
            return .ignoredStale(sessionID)
        }
        guard phase == .listening else {
            return .ignoredDuplicate(sessionID)
        }

        phase = .transcribing
        await stopIncrementalRecognition(sessionID)

        let audio: AudioInput
        do {
            audio = try await audioCapture.finishCapture(for: sessionID)
        } catch {
            return await failStop(sessionID, at: .audioFinalize)
        }

        guard isCurrent(sessionID, expected: .transcribing) else {
            await audioCapture.release(audio)
            return .ignoredStale(sessionID)
        }
        session?.audioInput = audio

        guard let capturedTargetContext = session?.capturedTargetContext,
              let language = session?.language else {
            return await failStop(sessionID, at: .context)
        }

        guard audio.hasDetectedSpeech else {
            return await finishAsNoSpeech(sessionID)
        }

        let hints = await recognitionHints(
            language: language,
            context: capturedTargetContext.context
        )

        let transcript: RawTranscript
        do {
            if let lifecycle = recognizer as? any SpeechRecognitionLifecycle {
                transcript = try await lifecycle.finalizeRecognitionSession(
                    audio,
                    hints: hints,
                    sessionID: sessionID
                )
            } else {
                transcript = try await recognizer.transcribe(
                    audio,
                    hints: hints,
                    sessionID: sessionID
                )
            }
        } catch let failure as any SpeechRecognitionFailureClassifying
            where failure.indicatesNoSpeech {
            return await finishAsNoSpeech(sessionID)
        } catch {
            return await failStop(sessionID, at: .recognition)
        }

        await releaseOwnedAudio(for: sessionID)

        guard isCurrent(sessionID, expected: .transcribing) else {
            return .ignoredStale(sessionID)
        }
        session?.rawTranscript = transcript
        await fallbackText?.preserveRawTranscript(transcript.text, for: sessionID)
        guard isCurrent(sessionID, expected: .transcribing) else {
            return .ignoredStale(sessionID)
        }
        phase = .cleaning

        let localCandidate: LocalCandidate
        do {
            localCandidate = try await cleanup.clean(
                transcript,
                context: capturedTargetContext.context,
                sessionID: sessionID
            )
        } catch {
            return await failStop(sessionID, at: .cleanup)
        }

        guard isCurrent(sessionID, expected: .cleaning) else {
            return .ignoredStale(sessionID)
        }
        session?.localCandidate = localCandidate

        let finalCandidate: FinalCandidate
        if consent.cloudEnabled,
           capturedTargetContext.context.availability != .deniedSensitive {
            phase = .enriching
            do {
                let enriched = try await enrichment.enrich(
                    localCandidate,
                    context: capturedTargetContext.context,
                    consent: consent,
                    sessionID: sessionID
                )
                guard isCurrent(sessionID, expected: .enriching) else {
                    return .ignoredStale(sessionID)
                }
                finalCandidate = .enriched(enriched, localFallback: localCandidate)
            } catch {
                guard isCurrent(sessionID, expected: .enriching) else {
                    return .ignoredStale(sessionID)
                }
                finalCandidate = .local(
                    await locallyRewritten(
                        localCandidate,
                        language: language,
                        context: capturedTargetContext.context,
                        sessionID: sessionID
                    )
                )
            }
        } else {
            if localRewriter != nil {
                phase = .enriching
            }
            finalCandidate = .local(
                await locallyRewritten(
                    localCandidate,
                    language: language,
                    context: capturedTargetContext.context,
                    sessionID: sessionID
                )
            )
        }
        await fallbackText?.preserveCandidate(finalCandidate.text, for: sessionID)
        guard session?.id == sessionID else {
            return .ignoredStale(sessionID)
        }

        phase = .inserting

        let insertionOutcome: InsertionOutcome
        do {
            insertionOutcome = try await insertion.insert(
                finalCandidate,
                sessionID: sessionID
            )
        } catch {
            if await pendingInsertionCancellationDisposition(for: sessionID)
                == .cancelledBeforeCommit {
                await finalizeCancellationIfActive(sessionID)
                return .ignoredStale(sessionID)
            }
            return await failStop(sessionID, at: .insertion)
        }

        if await pendingInsertionCancellationDisposition(for: sessionID)
            == .cancelledBeforeCommit {
            await finalizeCancellationIfActive(sessionID)
            return .ignoredStale(sessionID)
        }

        guard isCurrent(sessionID, expected: .inserting) else {
            return .ignoredStale(sessionID)
        }

        phase = .success
        session = nil
        if insertionOutcome == .confirmedDirect {
            await fallbackText?.confirmInsertion(sessionID: sessionID)
        }
        await releaseSessionResources(sessionID)
        if insertionCancellationRequest?.sessionID == sessionID {
            insertionCancellationRequest = nil
        }
        return .completed(sessionID, insertionOutcome)
    }

    func cancel(sessionID: DictationSessionID) async -> CancelOutcome {
        guard let activeSession = session else {
            return .noActiveSession
        }
        guard activeSession.id == sessionID else {
            return .ignoredStale(sessionID)
        }

        if phase == .inserting {
            let cancellationRequest: InsertionCancellationRequest
            if let existing = insertionCancellationRequest,
               existing.sessionID == sessionID {
                cancellationRequest = existing
            } else {
                let insertion = insertion
                cancellationRequest = InsertionCancellationRequest(
                    sessionID: sessionID,
                    task: Task {
                        await insertion.requestCancellation(sessionID: sessionID)
                    }
                )
                insertionCancellationRequest = cancellationRequest
            }

            switch await cancellationRequest.task.value {
            case .cancelledBeforeCommit:
                await finalizeCancellationIfActive(sessionID)
                return .cancelled(sessionID)
            case .tooLateCommitted:
                return .tooLateCommitted(sessionID)
            }
        }

        let audio = takeOwnedAudio(for: sessionID)
        session = nil
        phase = .cancelled
        _ = await insertion.requestCancellation(sessionID: sessionID)
        await fallbackText?.discardEphemeralText(sessionID: sessionID)
        await releaseAudio(audio)
        await releaseSessionResources(sessionID)

        return .cancelled(sessionID)
    }

    func resetTerminalState() {
        guard phase.isTerminal else { return }
        phase = .idle
        session = nil
    }

    private func isCurrent(_ sessionID: DictationSessionID, expected: DictationPhase) -> Bool {
        session?.id == sessionID && phase == expected
    }

    private func failCurrent(
        _ sessionID: DictationSessionID,
        at stage: DictationFailureStage
    ) async -> StartOutcome {
        guard session?.id == sessionID else {
            return .ignoredStale(sessionID)
        }

        let failure = DictationFailure(stage: stage)
        let audio = takeOwnedAudio(for: sessionID)
        session = nil
        phase = .error(failure)
        await releaseAudio(audio)
        await releaseSessionResources(sessionID)
        return .failed(sessionID, failure)
    }

    private func takeOwnedAudio(for sessionID: DictationSessionID) -> AudioInput? {
        guard session?.id == sessionID else { return nil }
        let audio = session?.audioInput
        session?.audioInput = nil
        return audio
    }

    private func releaseOwnedAudio(for sessionID: DictationSessionID) async {
        await releaseAudio(takeOwnedAudio(for: sessionID))
    }

    private func finishAsNoSpeech(_ sessionID: DictationSessionID) async -> StopOutcome {
        guard session?.id == sessionID else {
            return .ignoredStale(sessionID)
        }
        await releaseOwnedAudio(for: sessionID)
        phase = .success
        session = nil
        await fallbackText?.discardEphemeralText(sessionID: sessionID)
        await releaseSessionResources(sessionID)
        return .noSpeech(sessionID)
    }

    private func releaseAudio(_ audio: AudioInput?) async {
        guard let audio else { return }
        await audioCapture.release(audio)
    }

    private func finalizeCancellationIfActive(
        _ sessionID: DictationSessionID
    ) async {
        guard session?.id == sessionID else { return }

        let audio = takeOwnedAudio(for: sessionID)
        session = nil
        phase = .cancelled
        await fallbackText?.discardEphemeralText(sessionID: sessionID)
        await releaseAudio(audio)
        await releaseSessionResources(sessionID)
    }

    private func pendingInsertionCancellationDisposition(
        for sessionID: DictationSessionID
    ) async -> InsertionCancellationDisposition? {
        guard let request = insertionCancellationRequest,
              request.sessionID == sessionID else {
            return nil
        }
        return await request.task.value
    }

    private func failStop(
        _ sessionID: DictationSessionID,
        at stage: DictationFailureStage
    ) async -> StopOutcome {
        guard session?.id == sessionID else {
            return .ignoredStale(sessionID)
        }

        let failure = DictationFailure(stage: stage)
        let audio = takeOwnedAudio(for: sessionID)
        session = nil
        phase = .error(failure)
        await releaseAudio(audio)
        await releaseSessionResources(sessionID)
        return .failed(sessionID, failure)
    }

    private func releaseSessionResources(_ sessionID: DictationSessionID) async {
        await stopIncrementalRecognition(sessionID)
        async let cancelContext: Void = contextProvider.cancel(sessionID: sessionID)
        async let cancelAudio: Void = audioCapture.cancelCapture(for: sessionID)
        async let cancelRecognition: Void = recognizer.cancel(sessionID: sessionID)
        async let cancelEnrichment: Void = enrichment.cancel(sessionID: sessionID)
        async let cancelLocalRewrite: Void = localRewriter?.cancel(sessionID: sessionID) ?? ()
        async let releaseInsertion: Void = insertion.releaseInsertionSession(
            sessionID: sessionID
        )
        _ = await (
            cancelContext,
            cancelAudio,
            cancelRecognition,
            cancelEnrichment,
            cancelLocalRewrite,
            releaseInsertion
        )
    }

    private func stopIncrementalRecognition(_ sessionID: DictationSessionID) async {
        guard let task = incrementalRecognitionTasks.removeValue(forKey: sessionID) else {
            return
        }
        task.cancel()
        if let lifecycle = recognizer as? any SpeechRecognitionLifecycle {
            await lifecycle.stopRecognitionSession(sessionID: sessionID)
        }
        await task.value
    }

    private func recognitionHints(
        language: DictationLanguage,
        context: ContextSnapshot
    ) async -> RecognitionHints {
        let lexiconTerms = await prioritizedLexiconTerms(language)
        let decoderTerms = (
            context.safeDecoderHints + context.termHints
        ).removingDuplicateRecognitionHints()
        return RecognitionHints(
            language: language,
            terms: decoderTerms,
            prioritizedLexiconTerms: lexiconTerms
        )
    }

    private func locallyRewritten(
        _ candidate: LocalCandidate,
        language: DictationLanguage,
        context: ContextSnapshot,
        sessionID: DictationSessionID
    ) async -> LocalCandidate {
        guard let localRewriter else { return candidate }
        let result = await localRewriter.rewrite(
            TextRewriteRequest(
                sessionID: sessionID,
                localCandidate: candidate,
                language: TextRewriteLanguage(language),
                context: TextRewriteContext(context)
            )
        )
        guard result.outcome == .accepted else { return candidate }
        return LocalCandidate(text: result.outputText)
    }
}

private extension Array where Element == String {
    func removingDuplicateRecognitionHints() -> [String] {
        var seen: Set<String> = []
        return filter { value in
            let normalized = value.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            return !normalized.isEmpty && seen.insert(normalized).inserted
        }
    }
}
