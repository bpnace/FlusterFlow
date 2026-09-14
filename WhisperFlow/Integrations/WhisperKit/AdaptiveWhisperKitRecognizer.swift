import Foundation
import OSLog

private enum AdaptivePerformanceBackend: String {
    case turbo
    case large
    case none
}

private enum AdaptivePerformanceOutcome: String {
    case turboSelected
    case largeSelected
    case turboRetained
    case deadlineExceeded
    case failure
    case cancelled
}

private enum AdaptivePerformanceFallbackCategory: String, Hashable {
    case backendFailureTurbo = "backend_failure_turbo"
    case backendFailureLarge = "backend_failure_large"
    case backendFailureOther = "backend_failure_other"
    case lowAverageLogprob = "low_average_logprob"
    case lowWordProbability = "low_word_probability"
    case highCompressionRatio = "high_compression_ratio"
    case decoderFallback = "decoder_fallback"
    case unresolvedPrioritizedLexicon = "unresolved_prioritized_lexicon"
    case suspiciousSentenceStructure = "suspicious_sentence_structure"
    case emptyTranscript = "empty_transcript"
    case repetition
    case severeOmission = "severe_omission"
    case largeLowerQuality = "large_lower_quality"
}

struct AdaptiveWhisperKitPolicy: Sendable {
    var lowAverageLogprobThreshold: Float = -0.8
    var lowWordProbabilityThreshold: Float = 0.65
    var highCompressionRatioThreshold: Float = 2.2
    var marginalAverageLogprobThreshold: Float = -0.45
    var marginalWordProbabilityThreshold: Float = 0.85
    var elevatedCompressionRatioThreshold: Float = 1.8
    var severeOmissionRatio: Float = 0.6

    func fallbackReasons(
        for transcript: RawTranscript,
        hints: RecognitionHints
    ) -> [AdaptiveFallbackReason] {
        var reasons: [AdaptiveFallbackReason] = []
        let prioritizedTerms = prioritizedLexiconTerms(in: hints)
        let unresolvedTerms = prioritizedTerms.filter {
            !containsLexiconTerm($0, in: transcript.text)
                && containsNearLexiconTerm($0, in: transcript.text)
        }

        if let avgLogprob = transcript.avgLogprob,
           avgLogprob < lowAverageLogprobThreshold {
            reasons.append(.lowAverageLogprob(avgLogprob))
        }
        if let minWordProbability = transcript.minWordProbability,
           minWordProbability < lowWordProbabilityThreshold {
            reasons.append(.lowWordProbability(minWordProbability))
        }
        if let compressionRatio = transcript.compressionRatio,
           compressionRatio > highCompressionRatioThreshold {
            reasons.append(.highCompressionRatio(compressionRatio))
        }
        if isActionableDecoderFallback(transcript.decoderFallback) {
            reasons.append(.decoderFallback(transcript.decoderFallback?.reasons ?? []))
        }
        if !unresolvedTerms.isEmpty {
            reasons.append(.unresolvedPrioritizedLexicon(unresolvedTerms))
        }
        // A short run of function words also occurs in valid sentences. Require
        // acoustic uncertainty for that weak signal; repeated phrases and
        // overwhelmingly repetitive connector output remain unconditional.
        let words = normalizedWords(in: transcript.text)
        let strongStructureDamage = hasImmediateRepeatedPhrase(words)
            || (words.count >= 8 && Float(Set(words).count) / Float(words.count) <= 0.6
                && Float(words.filter { Self.connectorWords.contains($0) }.count)
                    / Float(words.count) >= 0.75)
        let uncertainStructure = (transcript.avgLogprob.map { $0 < marginalAverageLogprobThreshold } ?? false)
            || (transcript.minWordProbability.map { $0 < marginalWordProbabilityThreshold } ?? false)
            || (transcript.compressionRatio.map { $0 > elevatedCompressionRatioThreshold } ?? false)
            || (transcript.avgLogprob == nil && transcript.minWordProbability == nil)
        if hasSuspiciousSentenceStructure(transcript.text), strongStructureDamage || uncertainStructure {
            reasons.append(.suspiciousSentenceStructure)
        }
        return reasons
    }

    func shouldKeepTurboAfterLargeFallback(
        turbo: RawTranscript,
        large: RawTranscript,
        hints: RecognitionHints
    ) -> AdaptiveFallbackReason? {
        if large.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .emptyTranscript
        }
        if isRepetitive(large.text) {
            return .repetition
        }
        let turboWords = wordCount(turbo.text)
        let largeWords = wordCount(large.text)
        // Repeated decoder output inflates the reference length. It is not
        // evidence that the shorter, non-repetitive alternative omitted speech.
        let turboTokens = normalizedWords(in: turbo.text)
        let hasInflatedReference = turboTokens.count >= 8 && (
            hasImmediateRepeatedPhrase(turboTokens)
                || Float(Set(turboTokens).count) / Float(turboTokens.count) < 0.45
        )
        if !hasInflatedReference, turboWords > 0,
           Float(largeWords) < Float(turboWords) * severeOmissionRatio {
            return .severeOmission
        }
        if qualityScore(for: large, hints: hints) + 1 < qualityScore(for: turbo, hints: hints) {
            return .largeLowerQuality
        }
        return nil
    }

    func prioritizedLexiconTerms(in hints: RecognitionHints) -> [String] {
        var budget = WhisperKitRecognizer.promptTokenBudget
        var selected: [String] = []
        for term in hints.prioritizedLexiconTerms {
            let normalized = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            let approximateCost = max(1, normalized.split(whereSeparator: \.isWhitespace).count)
            guard approximateCost <= budget else { continue }
            selected.append(normalized)
            budget -= approximateCost
        }
        return selected
    }

    private func containsLexiconTerm(_ term: String, in text: String) -> Bool {
        text.range(
            of: term,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
    }

    private func containsNearLexiconTerm(_ term: String, in text: String) -> Bool {
        let targetWords = normalizedWords(in: term)
        let transcriptWords = normalizedWords(in: text)
        guard !targetWords.isEmpty, !transcriptWords.isEmpty else { return false }

        if targetWords.count == 1, let target = targetWords.first, target.count >= 4 {
            return transcriptWords.contains { candidate in
                candidate != target
                    && editDistance(candidate, target) <= max(1, target.count / 4)
            }
        }

        guard transcriptWords.count >= targetWords.count else { return false }
        let target = targetWords.joined(separator: " ")
        for start in 0...(transcriptWords.count - targetWords.count) {
            let candidate = transcriptWords[start..<(start + targetWords.count)]
                .joined(separator: " ")
            if candidate != target,
               editDistance(candidate, target) <= max(1, target.count / 5) {
                return true
            }
        }
        return false
    }

    private func hasSuspiciousSentenceStructure(_ text: String) -> Bool {
        let words = normalizedWords(in: text)
        guard words.count >= 8 else { return false }

        if hasImmediateRepeatedPhrase(words) {
            return true
        }

        var connectorRun = 0
        var longestConnectorRun = 0
        var connectorCount = 0
        for word in words {
            if Self.connectorWords.contains(word) {
                connectorRun += 1
                connectorCount += 1
                longestConnectorRun = max(longestConnectorRun, connectorRun)
            } else {
                connectorRun = 0
            }
        }

        let connectorRatio = Float(connectorCount) / Float(words.count)
        let uniqueRatio = Float(Set(words).count) / Float(words.count)
        return longestConnectorRun >= 5 || (connectorRatio >= 0.75 && uniqueRatio <= 0.6)
    }

    private func qualityScore(for transcript: RawTranscript, hints: RecognitionHints) -> Int {
        var score = 0
        let trimmedText = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedText.isEmpty {
            score -= 12
        }
        if isRepetitive(transcript.text) {
            score -= 5
        }
        if hasSuspiciousSentenceStructure(transcript.text) {
            score -= 2
        }
        if let avgLogprob = transcript.avgLogprob {
            if avgLogprob >= marginalAverageLogprobThreshold {
                score += 2
            } else if avgLogprob < lowAverageLogprobThreshold {
                score -= 2
            } else {
                score -= 1
            }
        }
        if let minWordProbability = transcript.minWordProbability {
            if minWordProbability >= marginalWordProbabilityThreshold {
                score += 2
            } else if minWordProbability < lowWordProbabilityThreshold {
                score -= 2
            } else {
                score -= 1
            }
        }
        if let compressionRatio = transcript.compressionRatio {
            if compressionRatio <= elevatedCompressionRatioThreshold {
                score += 1
            } else if compressionRatio > highCompressionRatioThreshold {
                score -= 2
            } else {
                score -= 1
            }
        }
        if isActionableDecoderFallback(transcript.decoderFallback) {
            score -= 2
        }
        score += matchedLexiconTermCount(in: transcript.text, hints: hints) * 2
        return score
    }

    private func matchedLexiconTermCount(in text: String, hints: RecognitionHints) -> Int {
        hints.decoderPromptTerms.reduce(into: 0) { count, term in
            if containsLexiconTerm(term, in: text) {
                count += 1
            }
        }
    }

    private func editDistance(_ left: String, _ right: String) -> Int {
        let lhs = Array(left)
        let rhs = Array(right)
        guard !lhs.isEmpty else { return rhs.count }
        guard !rhs.isEmpty else { return lhs.count }

        var previous = Array(0...rhs.count)
        for (leftIndex, leftCharacter) in lhs.enumerated() {
            var current = [leftIndex + 1]
            current.reserveCapacity(rhs.count + 1)
            for (rightIndex, rightCharacter) in rhs.enumerated() {
                current.append(min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                ))
            }
            previous = current
        }
        return previous[rhs.count]
    }

    private func isRepetitive(_ text: String) -> Bool {
        let words = normalizedWords(in: text)
        guard words.count >= 4 else { return false }
        for index in 1..<words.count where words[index] == words[index - 1] {
            return true
        }
        if hasImmediateRepeatedPhrase(words) {
            return true
        }
        let uniqueRatio = Float(Set(words).count) / Float(words.count)
        return uniqueRatio < 0.45
    }

    private func isActionableDecoderFallback(
        _ decoderFallback: RecognitionDecoderFallback?
    ) -> Bool {
        guard decoderFallback?.occurred == true else { return false }
        let reasons = decoderFallback?.reasons ?? []
        guard !reasons.isEmpty else { return true }
        let recoveryOnlyReasons: Set<String> = ["noSpeechRecovery", "promptlessRecovery"]
        return reasons.contains { !recoveryOnlyReasons.contains($0) }
    }

    private func hasImmediateRepeatedPhrase(_ words: [String]) -> Bool {
        guard words.count >= 4 else { return false }
        for start in words.indices {
            let remaining = words.count - start
            guard remaining >= 4 else { break }
            let maximumLength = min(4, remaining / 2)
            for length in stride(from: maximumLength, through: 2, by: -1) {
                let first = words[start..<(start + length)]
                let second = words[(start + length)..<(start + length * 2)]
                if first.elementsEqual(second) {
                    return true
                }
            }
        }
        return false
    }

    private func wordCount(_ text: String) -> Int {
        normalizedWords(in: text).count
    }

    private func normalizedWords(in text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    private static let connectorWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "but", "by", "for", "from", "if", "in",
        "is", "it", "of", "on", "or", "that", "the", "then", "to", "was", "were",
        "with",
        "aber", "als", "am", "an", "auf", "aus", "bei", "bis", "da", "dann", "das",
        "dass", "dem", "den", "der", "des", "die", "ein", "eine", "einem", "einen",
        "einer", "es", "im", "in", "ist", "mit", "oder", "und", "von", "wenn",
        "zu"
    ]
}

actor AdaptiveWhisperKitRecognizer: SpeechRecognizing, SpeechRecognitionLifecycle {
    private let turbo: any SpeechRecognizing
    private let large: any SpeechRecognizing
    private let policy: AdaptiveWhisperKitPolicy
    private let performanceLogger = Logger(
        subsystem: "local.flusterflow",
        category: "performance"
    )

    init(
        turbo: any SpeechRecognizing,
        large: any SpeechRecognizing,
        policy: AdaptiveWhisperKitPolicy = AdaptiveWhisperKitPolicy()
    ) {
        self.turbo = turbo
        self.large = large
        self.policy = policy
    }

    func transcribe(
        _ audio: AudioInput,
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws -> RawTranscript {
        let clock = ContinuousClock()
        let startedAt = clock.now
        var attemptedBackends: [AdaptivePerformanceBackend] = []
        var selectedBackend: AdaptivePerformanceBackend = .none
        var fallbackCategories: [AdaptivePerformanceFallbackCategory] = []
        var outcome: AdaptivePerformanceOutcome = .failure
        var turboAverageLogprob: Float?
        var turboCompressionRatio: Float?
        var largeAverageLogprob: Float?
        var largeCompressionRatio: Float?
        defer {
            let durationMilliseconds = startedAt
                .duration(to: clock.now)
                .adaptivePerformanceMilliseconds
            let attempted = attemptedBackends.isEmpty
                ? AdaptivePerformanceBackend.none.rawValue
                : attemptedBackends.map(\.rawValue).joined(separator: ",")
            let reasons = fallbackCategories.isEmpty
                ? "none"
                : fallbackCategories.map(\.rawValue).joined(separator: ",")
            performanceLogger.info(
                "performance=adaptiveDecision attempted_backends=\(attempted, privacy: .public) selected_backend=\(selectedBackend.rawValue, privacy: .public) outcome=\(outcome.rawValue, privacy: .public) fallback_reasons=\(reasons, privacy: .public) turbo_avg_logprob_present=\(turboAverageLogprob != nil, privacy: .public) turbo_avg_logprob=\(turboAverageLogprob ?? -999, privacy: .public) turbo_compression_ratio_present=\(turboCompressionRatio != nil, privacy: .public) turbo_compression_ratio=\(turboCompressionRatio ?? -1, privacy: .public) large_avg_logprob_present=\(largeAverageLogprob != nil, privacy: .public) large_avg_logprob=\(largeAverageLogprob ?? -999, privacy: .public) large_compression_ratio_present=\(largeCompressionRatio != nil, privacy: .public) large_compression_ratio=\(largeCompressionRatio ?? -1, privacy: .public) duration_ms=\(durationMilliseconds, privacy: .public)"
            )
        }

        let turboResult: RawTranscript
        attemptedBackends.append(.turbo)
        do {
            turboResult = try await turbo.transcribe(
                audio,
                hints: hints,
                sessionID: sessionID
            )
            turboAverageLogprob = turboResult.avgLogprob
            turboCompressionRatio = turboResult.compressionRatio
        } catch is CancellationError {
            outcome = .cancelled
            throw CancellationError()
        } catch let error as ProductASRDeadlineError {
            outcome = .deadlineExceeded
            throw error
        } catch {
            fallbackCategories.append(.backendFailureTurbo)
            do {
                try ProductASRDeadlineContext.requireRemainingBudget()
            } catch is ProductASRDeadlineError {
                outcome = .deadlineExceeded
                throw ProductASRDeadlineError.exceeded
            }
            attemptedBackends.append(.large)
            do {
                let largeResult = try await large.transcribe(
                    audio,
                    hints: hints,
                    sessionID: sessionID
                )
                largeAverageLogprob = largeResult.avgLogprob
                largeCompressionRatio = largeResult.compressionRatio
                selectedBackend = .large
                outcome = .largeSelected
                return annotated(
                    largeResult,
                    selectedBackend: .whisperKitLargeV3,
                    attemptedBackends: [.whisperKitLargeV3Turbo, .whisperKitLargeV3],
                    fallbackReasons: [.backendFailure(.whisperKitLargeV3Turbo)],
                    largeFallbackAccepted: true
                )
            } catch is CancellationError {
                outcome = .cancelled
                throw CancellationError()
            } catch is ProductASRDeadlineError {
                fallbackCategories.append(.backendFailureLarge)
                outcome = .deadlineExceeded
                throw ProductASRDeadlineError.exceeded
            } catch {
                fallbackCategories.append(.backendFailureLarge)
                outcome = .failure
                throw error
            }
        }
        let policyFallbackReasons = policy.fallbackReasons(
            for: turboResult,
            hints: hints
        )
        if policyFallbackReasons.isEmpty {
            selectedBackend = .turbo
            outcome = .turboSelected
            return annotated(
                turboResult,
                selectedBackend: .whisperKitLargeV3Turbo,
                attemptedBackends: [.whisperKitLargeV3Turbo],
                fallbackReasons: [],
                largeFallbackAccepted: false
            )
        }

        fallbackCategories = Self.performanceFallbackCategories(for: policyFallbackReasons)
        do {
            try ProductASRDeadlineContext.requireRemainingBudget()
        } catch is ProductASRDeadlineError {
            outcome = .deadlineExceeded
            throw ProductASRDeadlineError.exceeded
        }
        let largeResult: RawTranscript
        attemptedBackends.append(.large)
        do {
            largeResult = try await large.transcribe(
                audio,
                hints: hints,
                sessionID: sessionID
            )
            largeAverageLogprob = largeResult.avgLogprob
            largeCompressionRatio = largeResult.compressionRatio
        } catch is CancellationError {
            outcome = .cancelled
            throw CancellationError()
        } catch {
            fallbackCategories.append(.backendFailureLarge)
            selectedBackend = .turbo
            outcome = .turboRetained
            return annotated(
                turboResult,
                selectedBackend: .whisperKitLargeV3Turbo,
                attemptedBackends: [.whisperKitLargeV3Turbo, .whisperKitLargeV3],
                fallbackReasons: policyFallbackReasons + [.backendFailure(.whisperKitLargeV3)],
                largeFallbackAccepted: false
            )
        }
        if let turboKeepReason = policy.shouldKeepTurboAfterLargeFallback(
            turbo: turboResult,
            large: largeResult,
            hints: hints
        ) {
            fallbackCategories = Self.performanceFallbackCategories(
                for: policyFallbackReasons + [turboKeepReason]
            )
            selectedBackend = .turbo
            outcome = .turboRetained
            return annotated(
                turboResult,
                selectedBackend: .whisperKitLargeV3Turbo,
                attemptedBackends: [.whisperKitLargeV3Turbo, .whisperKitLargeV3],
                fallbackReasons: policyFallbackReasons + [turboKeepReason],
                largeFallbackAccepted: false
            )
        }
        selectedBackend = .large
        outcome = .largeSelected
        return annotated(
            largeResult,
            selectedBackend: .whisperKitLargeV3,
            attemptedBackends: [.whisperKitLargeV3Turbo, .whisperKitLargeV3],
            fallbackReasons: policyFallbackReasons,
            largeFallbackAccepted: true
        )
    }

    func cancel(sessionID: DictationSessionID) async {
        await turbo.cancel(sessionID: sessionID)
        await large.cancel(sessionID: sessionID)
    }

    func prepareForRecording(
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws {
        async let prepareTurbo: Void = callLifecycle(
            on: turbo,
            sessionID: sessionID
        ) {
            try await $0.prepareForRecording(hints: hints, sessionID: sessionID)
        }
        async let prepareLarge: Void = callLifecycle(
            on: large,
            sessionID: sessionID
        ) {
            try await $0.prepareForRecording(hints: hints, sessionID: sessionID)
        }
        _ = try await (prepareTurbo, prepareLarge)
    }

    func startRecognitionSession(
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws {
        try await callLifecycle(
            on: turbo,
            sessionID: sessionID
        ) {
            try await $0.startRecognitionSession(hints: hints, sessionID: sessionID)
        }
    }

    func updateRecognitionSession(
        with chunk: RecognitionAudioChunk,
        sessionID: DictationSessionID
    ) async throws -> RecognitionChunkDisposition {
        guard let lifecycle = turbo as? any SpeechRecognitionLifecycle else {
            return .ignoredBatchRecognizer
        }
        return try await lifecycle.updateRecognitionSession(
            with: chunk,
            sessionID: sessionID
        )
    }

    func stopRecognitionSession(sessionID: DictationSessionID) async {
        guard let lifecycle = turbo as? any SpeechRecognitionLifecycle else { return }
        await lifecycle.stopRecognitionSession(sessionID: sessionID)
    }

    func finalizeRecognitionSession(
        _ audio: AudioInput,
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws -> RawTranscript {
        try await transcribe(audio, hints: hints, sessionID: sessionID)
    }

    func prewarmTurbo() async throws {
        guard let turbo = turbo as? WhisperKitRecognizer else { return }
        try await turbo.prewarm()
    }

    func unloadLarge() async {
        guard let large = large as? WhisperKitRecognizer else { return }
        await large.unload()
    }

    private func annotated(
        _ transcript: RawTranscript,
        selectedBackend: RecognitionBackend,
        attemptedBackends: [RecognitionBackend],
        fallbackReasons: [AdaptiveFallbackReason],
        largeFallbackAccepted: Bool
    ) -> RawTranscript {
        RawTranscript(
            text: transcript.text,
            language: transcript.language,
            backend: selectedBackend,
            segments: transcript.segments,
            wordProbabilities: transcript.wordProbabilities,
            avgLogprob: transcript.avgLogprob,
            minWordProbability: transcript.minWordProbability,
            compressionRatio: transcript.compressionRatio,
            decoderFallback: transcript.decoderFallback,
            adaptive: AdaptiveRecognitionMetadata(
                attemptedBackends: attemptedBackends,
                selectedBackend: selectedBackend,
                fallbackReasons: fallbackReasons,
                largeFallbackAccepted: largeFallbackAccepted
            )
        )
    }

    private static func performanceFallbackCategories(
        for reasons: [AdaptiveFallbackReason]
    ) -> [AdaptivePerformanceFallbackCategory] {
        var categories: [AdaptivePerformanceFallbackCategory] = []
        for reason in reasons {
            let category: AdaptivePerformanceFallbackCategory
            switch reason {
            case .backendFailure(let backend):
                switch backend {
                case .whisperKitLargeV3Turbo:
                    category = .backendFailureTurbo
                case .whisperKitLargeV3:
                    category = .backendFailureLarge
                default:
                    category = .backendFailureOther
                }
            case .lowAverageLogprob:
                category = .lowAverageLogprob
            case .lowWordProbability:
                category = .lowWordProbability
            case .highCompressionRatio:
                category = .highCompressionRatio
            case .decoderFallback:
                category = .decoderFallback
            case .unresolvedPrioritizedLexicon:
                category = .unresolvedPrioritizedLexicon
            case .suspiciousSentenceStructure:
                category = .suspiciousSentenceStructure
            case .emptyTranscript:
                category = .emptyTranscript
            case .repetition:
                category = .repetition
            case .severeOmission:
                category = .severeOmission
            case .largeLowerQuality:
                category = .largeLowerQuality
            }
            if !categories.contains(category) {
                categories.append(category)
            }
        }
        return categories
    }

    private func callLifecycle(
        on recognizer: any SpeechRecognizing,
        sessionID: DictationSessionID,
        _ operation: (any SpeechRecognitionLifecycle) async throws -> Void
    ) async throws {
        _ = sessionID
        guard let lifecycle = recognizer as? any SpeechRecognitionLifecycle else {
            return
        }
        try await operation(lifecycle)
    }
}

private extension Duration {
    var adaptivePerformanceMilliseconds: Double {
        let components = self.components
        return (Double(components.seconds) * 1_000)
            + (Double(components.attoseconds) / 1_000_000_000_000_000)
    }
}
