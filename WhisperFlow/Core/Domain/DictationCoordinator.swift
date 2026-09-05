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
    private let recordingHistory: (any RecordingHistoryRecording)?
    private let prioritizedLexiconTerms: @Sendable (DictationLanguage) async -> [String]

    private var nextSessionRawValue: UInt64 = 0
    private var phase: DictationPhase = .idle
    private var session: DictationSession?
    private var insertionCancellationRequest: InsertionCancellationRequest?
    private var incrementalRecognitionTasks: [DictationSessionID: Task<Void, Never>] = [:]
    private var incrementalRecognitionReceivedAudio: Set<DictationSessionID> = []
    private var contextEnrichmentTasks: [
        DictationSessionID: Task<CapturedTargetContext, Never>
    ] = [:]

    init(
        contextProvider: any TargetContextProviding,
        audioCapture: any AudioCapturing,
        recognizer: any SpeechRecognizing,
        cleanup: any TextCleaning,
        enrichment: any TextEnriching,
        localRewriter: (any TextRewriting)? = nil,
        insertion: any TextInserting,
        fallbackText: (any EphemeralTextPreserving)? = nil,
        recordingHistory: (any RecordingHistoryRecording)? = nil,
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
        self.recordingHistory = recordingHistory
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

        let capturedTarget: CapturedTargetContext
        do {
            capturedTarget = try await contextProvider.captureTarget(for: sessionID)
        } catch {
            return await failCurrent(sessionID, at: .context)
        }

        guard isCurrent(sessionID, expected: .priming) else {
            return .ignoredStale(sessionID)
        }
        guard capturedTarget.target.isRegistered,
              capturedTarget.context.availability != .deniedSensitive else {
            return await failCurrent(sessionID, at: .context)
        }
        session?.capturedTargetContext = capturedTarget

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
        do {
            try await recordingHistory?.begin(sessionID: sessionID, language: language)
        } catch {
            return await failCurrent(sessionID, at: .audioStart)
        }
        let contextProvider = contextProvider
        contextEnrichmentTasks[sessionID] = Task {
            do {
                return try await contextProvider.enrichContext(
                    for: capturedTarget,
                    sessionID: sessionID
                )
            } catch {
                return capturedTarget
            }
        }
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
            var recognizerAcceptsStreaming = true
            do {
                try await lifecycle.startRecognitionSession(
                    hints: hints,
                    sessionID: sessionID
                )
            } catch {
                recognizerAcceptsStreaming = false
            }
            do {
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
                    try? await self.recordingHistory?.persistCheckpoint(
                        batch.chunk,
                        sessionID: sessionID
                    )
                    if recognizerAcceptsStreaming {
                        do {
                            let disposition = try await lifecycle.updateRecognitionSession(
                                with: batch.chunk,
                                sessionID: sessionID
                            )
                            if disposition == .ignoredBatchRecognizer {
                                recognizerAcceptsStreaming = false
                            } else {
                                self.recordIncrementalRecognitionAudio(sessionID)
                            }
                        } catch {
                            recognizerAcceptsStreaming = false
                        }
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
        do {
            try await recordingHistory?.persistAudio(audio, sessionID: sessionID)
        } catch {
            return await failStop(sessionID, at: .audioFinalize)
        }

        guard let capturedTargetContext = await resolvedContext(for: sessionID),
              let language = session?.language else {
            return await failStop(sessionID, at: .context)
        }

        guard shouldAttemptTranscription(audio) else {
            return await finishAsNoSpeech(sessionID)
        }

        let hints = await recognitionHints(
            language: language,
            context: capturedTargetContext.context
        )

        let transcript: RawTranscript
        do {
            if let lifecycle = recognizer as? any SpeechRecognitionLifecycle,
               incrementalRecognitionReceivedAudio.remove(sessionID) != nil {
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

        do {
            try await recordingHistory?.persistTranscript(transcript, sessionID: sessionID)
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
                        transcript: transcript,
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
                    transcript: transcript,
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
        await recordingHistory?.discard(sessionID: sessionID)
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
        await recordingHistory?.markFailed(sessionID: sessionID)
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
        await recordingHistory?.discard(sessionID: sessionID)
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
        await recordingHistory?.markFailed(sessionID: sessionID)
        await releaseAudio(audio)
        await releaseSessionResources(sessionID)
        return .failed(sessionID, failure)
    }

    private func releaseSessionResources(_ sessionID: DictationSessionID) async {
        await stopIncrementalRecognition(sessionID)
        incrementalRecognitionReceivedAudio.remove(sessionID)
        contextEnrichmentTasks.removeValue(forKey: sessionID)?.cancel()
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

    private func resolvedContext(
        for sessionID: DictationSessionID
    ) async -> CapturedTargetContext? {
        guard session?.id == sessionID else { return nil }
        let fallback = session?.capturedTargetContext
        guard let task = contextEnrichmentTasks.removeValue(forKey: sessionID) else {
            return fallback
        }
        let enriched = await task.value
        guard session?.id == sessionID else { return nil }
        session?.capturedTargetContext = enriched
        return enriched
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

    private func recordIncrementalRecognitionAudio(_ sessionID: DictationSessionID) {
        guard isCurrent(sessionID, expected: .listening) else { return }
        incrementalRecognitionReceivedAudio.insert(sessionID)
    }

    private func shouldAttemptTranscription(_ audio: AudioInput) -> Bool {
        guard let timing = audio.timing else { return true }
        if !timing.isSilent {
            return true
        }
        if timing.processedDurationSeconds <= 0.05 {
            return false
        }
        if timing.inputPeak <= 0 && timing.normalizedPeak <= 0 {
            return false
        }
        if timing.inputRMS <= 0 && timing.normalizedRMS <= 0 {
            return false
        }
        return true
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
        transcript: RawTranscript,
        language: DictationLanguage,
        context: ContextSnapshot,
        sessionID: DictationSessionID
    ) async -> LocalCandidate {
        guard let localRewriter else { return candidate }
        if shouldUseDeterministicCandidateWithoutRewrite(
            candidate,
            transcript: transcript,
            context: context
        ) {
            return candidate
        }
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

    private func shouldUseDeterministicCandidateWithoutRewrite(
        _ candidate: LocalCandidate,
        transcript: RawTranscript,
        context: ContextSnapshot
    ) -> Bool {
        let hasHighConfidenceSignal = transcript.avgLogprob != nil
            || transcript.minWordProbability != nil
        guard hasHighConfidenceSignal else { return false }
        if let avgLogprob = transcript.avgLogprob, avgLogprob < -0.4 {
            return false
        }
        if let minWordProbability = transcript.minWordProbability,
           minWordProbability < 0.8 {
            return false
        }
        guard let compressionRatio = transcript.compressionRatio,
              compressionRatio <= 2.2 else {
            return false
        }
        guard let decoderFallback = transcript.decoderFallback,
              decoderFallback.occurred == false else {
            return false
        }
        if transcript.adaptive?.fallbackReasons.isEmpty == false { return false }
        if contextReferenceCanAffectRewrite(
            candidate: candidate.text,
            transcript: transcript.text,
            context: context
        ) {
            return false
        }
        return isStructurallyCoherentForFastPath(candidate.text)
            && isStructurallyCoherentForFastPath(transcript.text)
            && !hasSuspiciousRecognitionDamage(transcript.text)
            && !hasSuspiciousRecognitionDamage(candidate.text)
    }

    private func isStructurallyCoherentForFastPath(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8,
              trimmed.last.map({ ".!?".contains($0) }) == true else {
            return false
        }
        let words = recognitionFastPathWords(in: trimmed)
        guard words.count >= 2 else { return false }
        let unfinishedEndings: Set<String> = [
            "and", "or", "but", "because", "if", "then",
            "und", "oder", "aber", "weil", "wenn", "dann"
        ]
        guard let last = words.last, !unfinishedEndings.contains(last) else {
            return false
        }
        let fragmentStarts: Set<String> = [
            "and", "or", "but", "und", "oder", "aber"
        ]
        guard let first = words.first, !fragmentStarts.contains(first) else {
            return false
        }
        if startsWithIncompleteSubordinateClause(trimmed, firstWord: first) {
            return false
        }
        return true
    }

    private func startsWithIncompleteSubordinateClause(
        _ text: String,
        firstWord: String
    ) -> Bool {
        let subordinateStarts: Set<String> = [
            "because", "if", "weil", "wenn", "falls", "obwohl"
        ]
        guard subordinateStarts.contains(firstWord) else { return false }
        return !text.contains(",")
    }

    private func contextReferenceCanAffectRewrite(
        candidate: String,
        transcript: String,
        context: ContextSnapshot
    ) -> Bool {
        guard context.availability == .available,
              let boundedText = context.boundedText,
              !boundedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let text = "\(transcript)\n\(candidate)"
        return hasContextReference(in: text, for: .project)
            && hasContextDefinition(in: boundedText, for: .project)
            || hasContextReference(in: text, for: .task)
                && hasContextDefinition(in: boundedText, for: .task)
    }

    private enum ContextReferenceKind {
        case project
        case task
    }

    private func hasContextReference(
        in text: String,
        for kind: ContextReferenceKind
    ) -> Bool {
        let patterns: [String]
        switch kind {
        case .project:
            patterns = [
                #"(?i)\b(?:das|dieses|dem|diesem|jenes)\s+projekt\b"#,
                #"(?i)\b(?:this|that)\s+project\b"#
            ]
        case .task:
            patterns = [
                #"(?i)\b(?:die|diese|der|dieser|jene)\s+aufgabe\b"#,
                #"(?i)\b(?:this|that)\s+task\b"#
            ]
        }
        return patterns.contains { pattern in
            text.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private func hasContextDefinition(
        in text: String,
        for kind: ContextReferenceKind
    ) -> Bool {
        let patterns: [String]
        switch kind {
        case .project:
            patterns = [
                #"\b(?i:(?:das\s+)?projekt\s+(?:heißt|heisst|ist|namens))\s+([A-ZÄÖÜ][\p{L}\p{M}\p{N}_-]*(?:\s+[A-ZÄÖÜ][\p{L}\p{M}\p{N}_-]*){0,2})"#,
                #"\b(?i:projekt)\s*:\s*([A-ZÄÖÜ][\p{L}\p{M}\p{N}_-]*(?:\s+[A-ZÄÖÜ][\p{L}\p{M}\p{N}_-]*){0,2})"#,
                #"\b(?i:project\s+(?:is|called|named))\s+([A-Z][\p{L}\p{M}\p{N}_-]*(?:\s+[A-Z][\p{L}\p{M}\p{N}_-]*){0,2})"#,
                #"\b(?i:project)\s*:\s*([A-Z][\p{L}\p{M}\p{N}_-]*(?:\s+[A-Z][\p{L}\p{M}\p{N}_-]*){0,2})"#
            ]
        case .task:
            patterns = [
                #"\b(?i:(?:die\s+)?aufgabe\s+(?:heißt|heisst|ist|namens))\s+([A-ZÄÖÜ][\p{L}\p{M}\p{N}_-]*(?:\s+[A-ZÄÖÜ][\p{L}\p{M}\p{N}_-]*){0,2})"#,
                #"\b(?i:aufgabe)\s*:\s*([A-ZÄÖÜ][\p{L}\p{M}\p{N}_-]*(?:\s+[A-ZÄÖÜ][\p{L}\p{M}\p{N}_-]*){0,2})"#,
                #"\b(?i:task\s+(?:is|called|named))\s+([A-Z][\p{L}\p{M}\p{N}_-]*(?:\s+[A-Z][\p{L}\p{M}\p{N}_-]*){0,2})"#,
                #"\b(?i:task)\s*:\s*([A-Z][\p{L}\p{M}\p{N}_-]*(?:\s+[A-Z][\p{L}\p{M}\p{N}_-]*){0,2})"#
            ]
        }
        return patterns.contains { pattern in
            text.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private func hasSuspiciousRecognitionDamage(_ text: String) -> Bool {
        let words = recognitionFastPathWords(in: text)
        guard words.count >= 3 else { return false }
        for index in 0..<(words.count - 1) where words[index] == words[index + 1] {
            return true
        }
        guard words.count >= 4 else { return false }
        for length in 2...min(4, words.count / 2) {
            for index in 0...(words.count - length * 2) {
                let first = words[index..<(index + length)]
                let second = words[(index + length)..<(index + length * 2)]
                if Array(first) == Array(second) { return true }
            }
        }
        return false
    }

    private func recognitionFastPathWords(in text: String) -> [String] {
        let pattern = #"[\p{L}\p{N}][\p{L}\p{N}'_-]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]).lowercased() }
        }
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
