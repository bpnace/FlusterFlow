@preconcurrency import AVFoundation
import Foundation
import XCTest
@testable import WhisperFlow

final class WhisperKitRecognizerTests: XCTestCase, @unchecked Sendable {
    func testRecognizerUsesValidatedLocalFoldersAndMapsGerman() async throws {
        let samples = AudioBufferStore()
        let input = await samples.store(AudioSamples(values: [0.1, -0.1]))
        let modelDirectory = URL(fileURLWithPath: "/private/model")
        let tokenizerDirectory = URL(fileURLWithPath: "/private/tokenizer")
        let runtime = RecordingWhisperKitRuntime(result: "  Hallo Welt  ")
        let recognizer = WhisperKitRecognizer(
            sampleAccess: samples,
            modelStore: ReadyLocalModelChecker(directory: modelDirectory),
            tokenizerStore: ReadyLocalModelChecker(directory: tokenizerDirectory),
            runtime: runtime
        )
        let sessionID = DictationSessionID(rawValue: 7)

        let transcript = try await recognizer.transcribe(
            input,
            hints: RecognitionHints(language: .german, terms: []),
            sessionID: sessionID
        )

        XCTAssertEqual(transcript.text, "Hallo Welt")
        XCTAssertEqual(transcript.language, .german)
        XCTAssertEqual(transcript.avgLogprob, -0.1)
        XCTAssertEqual(transcript.minWordProbability, 0.95)
        XCTAssertEqual(transcript.compressionRatio, 1)
        XCTAssertEqual(transcript.decoderFallback, RecognitionDecoderFallback.none)
        let snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.modelDirectory, modelDirectory)
        XCTAssertEqual(snapshot.tokenizerDirectory, tokenizerDirectory)
        XCTAssertEqual(snapshot.language, .german)
        XCTAssertEqual(snapshot.promptTokens, [])
    }

    func testRecognizerDoesNotPassDecoderPromptTermsToWhisperKit() async throws {
        let samples = AudioBufferStore()
        let input = await samples.store(AudioSamples(values: [0.1, -0.1]))
        let runtime = RecordingWhisperKitRuntime(result: "AmberMesh")
        let recognizer = WhisperKitRecognizer(
            sampleAccess: samples,
            modelStore: ReadyLocalModelChecker(directory: URL(fileURLWithPath: "/private/model")),
            tokenizerStore: ReadyLocalModelChecker(directory: URL(fileURLWithPath: "/private/tokenizer")),
            runtime: runtime
        )

        _ = try await recognizer.transcribe(
            input,
            hints: RecognitionHints(
                language: .english,
                terms: ["AmberMesh", "two token", String(repeating: "x", count: 200)]
            ),
            sessionID: DictationSessionID(rawValue: 17)
        )

        let snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.promptTokens, [])
        XCTAssertEqual(snapshot.transcriptionCount, 1)

        let encodedTerms: [String: [Int]] = [
            " AmberMesh": [10, 50_257],
            " two token": [20, 21]
        ]
        let promptTokens = ["AmberMesh", "two token"].flatMap { term in
            OfflineWhisperKitRuntime.promptTokens(
                for: term,
                specialTokenBegin: 50_257,
                encodedBy: { encodedTerms[$0] ?? [] }
            )
        }
        XCTAssertEqual(promptTokens, [10, 20, 21])
    }

    func testRecognizerPreservesExplicitWhisperKitBackendLabel() async throws {
        let samples = AudioBufferStore()
        let input = await samples.store(AudioSamples(values: [0.1, -0.1]))
        let recognizer = WhisperKitRecognizer(
            sampleAccess: samples,
            modelStore: ReadyLocalModelChecker(directory: URL(fileURLWithPath: "/private/model")),
            tokenizerStore: ReadyLocalModelChecker(directory: URL(fileURLWithPath: "/private/tokenizer")),
            backend: .whisperKitLargeV3,
            runtime: RecordingWhisperKitRuntime(result: "large")
        )

        let transcript = try await recognizer.transcribe(
            input,
            hints: RecognitionHints(language: .english, terms: []),
            sessionID: DictationSessionID(rawValue: 18)
        )

        XCTAssertEqual(transcript.backend, .whisperKitLargeV3)
    }

    func testIncrementalSessionAcceptsAudioWithoutModelDecodeBeforeFinalization() async throws {
        let runtime = RecordingWhisperKitRuntime(result: "prefix")
        let recognizer = WhisperKitRecognizer(
            sampleAccess: AudioBufferStore(),
            modelStore: ReadyLocalModelChecker(directory: URL(fileURLWithPath: "/private/model")),
            tokenizerStore: ReadyLocalModelChecker(directory: URL(fileURLWithPath: "/private/tokenizer")),
            backend: .whisperKitLargeV3Turbo,
            runtime: runtime
        )
        let sessionID = DictationSessionID(rawValue: 20)
        let hints = RecognitionHints(
            language: .german,
            terms: [],
            prioritizedLexiconTerms: ["FlusterFlow"]
        )

        try await recognizer.startRecognitionSession(hints: hints, sessionID: sessionID)
        let disposition = try await recognizer.updateRecognitionSession(
            with: RecognitionAudioChunk(samples: Array(repeating: 0.05, count: 24_000)),
            sessionID: sessionID
        )

        XCTAssertEqual(disposition, .accepted)
        let snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.transcriptionCount, 0)
        XCTAssertEqual(snapshot.language, nil)
        XCTAssertEqual(snapshot.promptTokens, [])
        await recognizer.stopRecognitionSession(sessionID: sessionID)
    }

    func testFinalWhisperDecodeDoesNotDiscardSubsecondUtterances() {
        let options = OfflineWhisperKitRuntime.decodingOptions(
            language: .german,
            promptTokens: []
        )

        XCTAssertEqual(
            options.windowClipTime,
            0,
            "Final PTT audio is already complete; clipping WhisperKit's default final second makes valid short utterances decode as empty."
        )
        XCTAssertEqual(options.temperatureFallbackCount, 0)
        XCTAssertEqual(options.sampleLength, 128)
        XCTAssertTrue(options.withoutTimestamps)
        XCTAssertFalse(options.wordTimestamps)
        XCTAssertNil(options.firstTokenLogProbThreshold)
        XCTAssertNil(options.noSpeechThreshold)
        XCTAssertEqual(options.promptTokens, [])
    }

    func testFinalWhisperDecodeIgnoresPromptTokensAndUsesLowLatencyOptions() {
        let options = OfflineWhisperKitRuntime.decodingOptions(
            language: .german,
            promptTokens: [1, 2, 3]
        )

        XCTAssertNil(options.noSpeechThreshold)
        XCTAssertNil(options.firstTokenLogProbThreshold)
        XCTAssertTrue(options.withoutTimestamps)
        XCTAssertFalse(options.wordTimestamps)
        XCTAssertEqual(options.windowClipTime, 0)
        XCTAssertEqual(options.temperatureFallbackCount, 0)
        XCTAssertEqual(options.sampleLength, 128)
        XCTAssertEqual(options.promptTokens, [])
    }

    func testFinalRecognitionRunsOnePromptlessWhisperDecode() async throws {
        let samples = AudioBufferStore()
        let input = await samples.store(AudioSamples(values: [0.1, -0.1]))
        let runtime = PromptSensitiveWhisperKitRuntime(promptlessResult: "Hallo Welt")
        let recognizer = WhisperKitRecognizer(
            sampleAccess: samples,
            modelStore: ReadyLocalModelChecker(directory: URL(fileURLWithPath: "/private/model")),
            tokenizerStore: ReadyLocalModelChecker(directory: URL(fileURLWithPath: "/private/tokenizer")),
            runtime: runtime
        )

        let transcript: RawTranscript
        do {
            transcript = try await recognizer.transcribe(
                input,
                hints: RecognitionHints(
                    language: .german,
                    terms: ["Kontextbegriff"],
                    prioritizedLexiconTerms: ["FlusterFlow"]
                ),
                sessionID: DictationSessionID(rawValue: 31)
            )
        } catch {
            XCTFail("Prompt history before failure: \(await runtime.promptHistory())")
            throw error
        }

        XCTAssertEqual(transcript.text, "Hallo Welt")
        XCTAssertEqual(transcript.decoderFallback, RecognitionDecoderFallback.none)
        let promptHistory = await runtime.promptHistory()
        XCTAssertEqual(promptHistory, [[]])
    }

    func testWhisperFailureClassificationNeverNeedsUserContent() {
        XCTAssertEqual(
            WhisperKitRecognizer.failureCode(for: WhisperKitRecognizerError.runtimeBusy),
            .runtimeBusy
        )
        XCTAssertEqual(
            WhisperKitRecognizer.failureCode(for: WhisperKitRecognizerError.emptyTranscription),
            .emptyTranscription
        )
        XCTAssertFalse(WhisperKitRecognizerError.emptyTranscription.indicatesNoSpeech)
    }

    func testConcurrentPrewarmRequestsAreCoalesced() async throws {
        let runtime = RecordingWhisperKitRuntime(result: "ready")
        let recognizer = WhisperKitRecognizer(
            sampleAccess: AudioBufferStore(),
            modelStore: ReadyLocalModelChecker(directory: URL(fileURLWithPath: "/private/model")),
            tokenizerStore: ReadyLocalModelChecker(directory: URL(fileURLWithPath: "/private/tokenizer")),
            runtime: runtime
        )

        async let first: Void = recognizer.prewarm()
        async let second: Void = recognizer.prewarm()
        _ = try await (first, second)

        let snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.prewarmCount, 1)
    }

    func testSessionRouterKeepsChoiceStableAndCancelsOriginalBackend() async throws {
        let parakeet = RecordingSpeechRecognizer(text: "parakeet")
        let turbo = RecordingSpeechRecognizer(text: "turbo")
        let router = SessionModelSpeechRecognizer(
            recognizers: [
                .parakeetV3Int8: parakeet,
                .whisperKitLargeV3Turbo: turbo
            ]
        )
        let sessionID = DictationSessionID(rawValue: 9)
        await router.register(.whisperKitLargeV3Turbo, for: sessionID)

        let result = try await router.transcribe(
            AudioInput(buffer: AudioBufferHandle(rawValue: 1)),
            hints: RecognitionHints(language: .automatic, terms: []),
            sessionID: sessionID
        )
        await router.cancel(sessionID: sessionID)
        let turboCancellations = await turbo.cancelledSessions()
        let parakeetCancellations = await parakeet.cancelledSessions()

        XCTAssertEqual(result.text, "turbo")
        XCTAssertEqual(turboCancellations, [sessionID])
        XCTAssertEqual(parakeetCancellations, [])
    }

    func testSessionRouterLifecycleFallsBackForBatchRecognizersAndFinalizesViaTranscribe() async throws {
        let recognizer = RecordingSpeechRecognizer(text: "batch")
        let router = SessionModelSpeechRecognizer(recognizers: [.whisperKitLargeV3Turbo: recognizer])
        let sessionID = DictationSessionID(rawValue: 19)
        await router.register(.whisperKitLargeV3Turbo, for: sessionID)

        try await router.prepareForRecording(
            hints: RecognitionHints(language: .automatic, terms: []),
            sessionID: sessionID
        )
        let disposition = try await router.updateRecognitionSession(
            with: RecognitionAudioChunk(samples: [0.1]),
            sessionID: sessionID
        )
        let transcript = try await router.finalizeRecognitionSession(
            AudioInput(buffer: AudioBufferHandle(rawValue: 2)),
            hints: RecognitionHints(language: .automatic, terms: []),
            sessionID: sessionID
        )

        XCTAssertEqual(disposition, .ignoredBatchRecognizer)
        XCTAssertEqual(transcript.text, "batch")
    }

    func testAdaptivePolicyTriggersLargeFallbackForQualityThresholds() {
        let policy = AdaptiveWhisperKitPolicy()
        let transcript = RawTranscript(
            text: "hello AmberMesch",
            language: .english,
            avgLogprob: -0.9,
            minWordProbability: 0.5,
            compressionRatio: 2.3,
            decoderFallback: RecognitionDecoderFallback(
                occurred: true,
                count: 1,
                reasons: ["temperatureFallback"]
            )
        )

        let reasons = policy.fallbackReasons(
            for: transcript,
            hints: RecognitionHints(
                language: .english,
                terms: [],
                prioritizedLexiconTerms: ["AmberMesh"]
            )
        )

        XCTAssertTrue(reasons.contains(.lowAverageLogprob(-0.9)))
        XCTAssertTrue(reasons.contains(.lowWordProbability(0.5)))
        XCTAssertTrue(reasons.contains(.highCompressionRatio(2.3)))
        XCTAssertTrue(reasons.contains(.decoderFallback(["temperatureFallback"])))
        XCTAssertTrue(reasons.contains(.unresolvedPrioritizedLexicon(["AmberMesh"])))

        let recoveryOnly = RawTranscript(
            text: "hello AmberMesh",
            language: .english,
            avgLogprob: -0.1,
            minWordProbability: 0.95,
            compressionRatio: 1.0,
            decoderFallback: RecognitionDecoderFallback(
                occurred: true,
                count: 2,
                reasons: ["noSpeechRecovery", "promptlessRecovery"]
            )
        )
        XCTAssertTrue(
            policy.fallbackReasons(
                for: recoveryOnly,
                hints: RecognitionHints(
                    language: .english,
                    terms: [],
                    prioritizedLexiconTerms: ["AmberMesh"]
                )
            ).isEmpty
        )
    }

    func testAdaptivePolicyFallbacksForSuspiciousSentenceStructureEvenWithHighConfidence() {
        let policy = AdaptiveWhisperKitPolicy()
        let transcript = RawTranscript(
            text: "the to and of in the to and of in",
            language: .english,
            avgLogprob: -0.1,
            minWordProbability: 0.95,
            compressionRatio: 1.0,
            decoderFallback: RecognitionDecoderFallback.none
        )

        let reasons = policy.fallbackReasons(
            for: transcript,
            hints: RecognitionHints(language: .english, terms: [])
        )

        XCTAssertTrue(reasons.contains(.suspiciousSentenceStructure))
    }

    func testAdaptivePolicyFallbacksForSuspiciousSentenceStructureWithQualitySignal() {
        let policy = AdaptiveWhisperKitPolicy()
        let transcript = RawTranscript(
            text: "normal und wenn wir wenn wir es normal testen dann weiter",
            language: .german,
            avgLogprob: -0.1,
            minWordProbability: 0.8,
            compressionRatio: 1.0,
            decoderFallback: RecognitionDecoderFallback.none
        )

        let reasons = policy.fallbackReasons(
            for: transcript,
            hints: RecognitionHints(language: .german, terms: [])
        )

        XCTAssertTrue(reasons.contains(.suspiciousSentenceStructure))
    }

    func testAdaptiveRecognizerUsesLargeAfterTurboQualityFallback() async throws {
        let turbo = RecordingSpeechRecognizer(
            transcript: RawTranscript(
                text: "wrong",
                language: .english,
                backend: .whisperKitLargeV3Turbo,
                avgLogprob: -0.95
            )
        )
        let large = RecordingSpeechRecognizer(
            transcript: RawTranscript(
                text: "AmberMesh correct",
                language: .english,
                backend: .whisperKitLargeV3,
                avgLogprob: -0.1
            )
        )
        let recognizer = AdaptiveWhisperKitRecognizer(turbo: turbo, large: large)

        let transcript = try await recognizer.transcribe(
            AudioInput(buffer: AudioBufferHandle(rawValue: 3)),
            hints: RecognitionHints(language: .english, terms: ["AmberMesh"]),
            sessionID: DictationSessionID(rawValue: 21)
        )

        XCTAssertEqual(transcript.text, "AmberMesh correct")
        XCTAssertEqual(transcript.backend, .whisperKitLargeV3)
        XCTAssertEqual(transcript.adaptive?.attemptedBackends, [.whisperKitLargeV3Turbo, .whisperKitLargeV3])
        XCTAssertEqual(transcript.adaptive?.largeFallbackAccepted, true)
    }

    func testAdaptiveRecognizerUsesLargeWhenTurboFails() async throws {
        let turbo = FailingSpeechRecognizer()
        let large = RecordingSpeechRecognizer(
            transcript: RawTranscript(
                text: "recovered by large",
                language: .english,
                backend: .whisperKitLargeV3,
                avgLogprob: -0.1
            )
        )
        let recognizer = AdaptiveWhisperKitRecognizer(turbo: turbo, large: large)

        let transcript = try await recognizer.transcribe(
            AudioInput(buffer: AudioBufferHandle(rawValue: 25)),
            hints: RecognitionHints(language: .english, terms: []),
            sessionID: DictationSessionID(rawValue: 25)
        )

        XCTAssertEqual(transcript.text, "recovered by large")
        XCTAssertEqual(transcript.backend, .whisperKitLargeV3)
        XCTAssertEqual(
            transcript.adaptive?.attemptedBackends,
            [.whisperKitLargeV3Turbo, .whisperKitLargeV3]
        )
        XCTAssertEqual(transcript.adaptive?.largeFallbackAccepted, true)
        XCTAssertTrue(
            transcript.adaptive?.fallbackReasons.contains(
                .backendFailure(.whisperKitLargeV3Turbo)
            ) == true
        )
    }

    func testAdaptiveRecognizerKeepsTurboWhenLargeFallbackFails() async throws {
        let turbo = RecordingSpeechRecognizer(
            transcript: RawTranscript(
                text: "usable turbo output",
                language: .english,
                backend: .whisperKitLargeV3Turbo,
                avgLogprob: -0.95
            )
        )
        let large = FailingSpeechRecognizer()
        let recognizer = AdaptiveWhisperKitRecognizer(turbo: turbo, large: large)

        let transcript = try await recognizer.transcribe(
            AudioInput(buffer: AudioBufferHandle(rawValue: 26)),
            hints: RecognitionHints(language: .english, terms: []),
            sessionID: DictationSessionID(rawValue: 26)
        )

        XCTAssertEqual(transcript.text, "usable turbo output")
        XCTAssertEqual(transcript.backend, .whisperKitLargeV3Turbo)
        XCTAssertEqual(transcript.adaptive?.largeFallbackAccepted, false)
        XCTAssertTrue(
            transcript.adaptive?.fallbackReasons.contains(
                .backendFailure(.whisperKitLargeV3)
            ) == true
        )
    }

    func testAdaptiveRecognizerKeepsTurboWhenLargeHasWorseQualityAndLexiconMatch() async throws {
        let turbo = RecordingSpeechRecognizer(
            transcript: RawTranscript(
                text: "AmberMesh rollout is ready",
                language: .english,
                backend: .whisperKitLargeV3Turbo,
                avgLogprob: -0.95,
                minWordProbability: 0.6
            )
        )
        let large = RecordingSpeechRecognizer(
            transcript: RawTranscript(
                text: "rollout is ready",
                language: .english,
                backend: .whisperKitLargeV3,
                avgLogprob: -1.2,
                minWordProbability: 0.4
            )
        )
        let recognizer = AdaptiveWhisperKitRecognizer(turbo: turbo, large: large)

        let transcript = try await recognizer.transcribe(
            AudioInput(buffer: AudioBufferHandle(rawValue: 24)),
            hints: RecognitionHints(language: .english, terms: ["AmberMesh"]),
            sessionID: DictationSessionID(rawValue: 24)
        )

        XCTAssertEqual(transcript.text, "AmberMesh rollout is ready")
        XCTAssertEqual(transcript.backend, .whisperKitLargeV3Turbo)
        XCTAssertEqual(transcript.adaptive?.largeFallbackAccepted, false)
        XCTAssertTrue(transcript.adaptive?.fallbackReasons.contains(.largeLowerQuality) == true)
    }

    func testAdaptiveRecognizerKeepsTurboWhenLargeIsRepetitive() async throws {
        let turbo = RecordingSpeechRecognizer(
            transcript: RawTranscript(
                text: "usable turbo output with enough words",
                language: .english,
                backend: .whisperKitLargeV3Turbo,
                avgLogprob: -0.95
            )
        )
        let large = RecordingSpeechRecognizer(
            transcript: RawTranscript(
                text: "loop loop loop loop",
                language: .english,
                backend: .whisperKitLargeV3
            )
        )
        let recognizer = AdaptiveWhisperKitRecognizer(turbo: turbo, large: large)

        let transcript = try await recognizer.transcribe(
            AudioInput(buffer: AudioBufferHandle(rawValue: 4)),
            hints: RecognitionHints(language: .english, terms: []),
            sessionID: DictationSessionID(rawValue: 22)
        )

        XCTAssertEqual(transcript.text, "usable turbo output with enough words")
        XCTAssertEqual(transcript.backend, .whisperKitLargeV3Turbo)
        XCTAssertEqual(transcript.adaptive?.largeFallbackAccepted, false)
        XCTAssertTrue(transcript.adaptive?.fallbackReasons.contains(.repetition) == true)
    }

    func testProductionWhisperManifestsArePinnedAndSelfConsistent() throws {
        for manifest in [
            ModelManifest.whisperLargeV3,
            .whisperLargeV3Turbo,
            .whisperLargeV3Tokenizer
        ] {
            XCTAssertEqual(
                manifest.artifacts.reduce(Int64(0)) { $0 + $1.byteCount },
                manifest.expectedByteCount
            )
            for artifact in manifest.artifacts {
                let url = try XCTUnwrap(manifest.downloadURL(for: artifact))
                XCTAssertEqual(url.scheme, "https")
                XCTAssertEqual(url.host, "huggingface.co")
                XCTAssertTrue(url.path.contains(manifest.modelRevision))
                if let sourcePathPrefix = manifest.sourcePathPrefix {
                    XCTAssertTrue(url.path.contains(sourcePathPrefix))
                }
            }
        }
        XCTAssertNotEqual(
            ModelManifest.whisperLargeV3.runtimeDirectoryName,
            ModelManifest.whisperLargeV3Turbo.runtimeDirectoryName
        )
    }

    func testProductionRuntimeBypassesWhisperKitTokenizerDownloadFallback() throws {
        let source = try TestResourceLoader.string(
            "WhisperFlow/Integrations/WhisperKit/WhisperKitRecognizer.swift"
        )

        XCTAssertTrue(source.contains("download: false"))
        XCTAssertTrue(source.contains("AutoTokenizerWrapper.from("))
        XCTAssertTrue(source.contains("modelFolder: tokenizerDirectory"))
        XCTAssertFalse(source.contains("ModelUtilities.loadTokenizer"))
    }

    func testInstalledWhisperModelsLoadFromValidatedLocalFilesWhenExplicitlyRequested() async throws {
        guard ProcessInfo.processInfo.environment["FLUSTERFLOW_RUN_INSTALLED_MODEL_SMOKE"] == "1" else {
            throw XCTSkip("Set FLUSTERFLOW_RUN_INSTALLED_MODEL_SMOKE=1 for the local Core ML smoke test")
        }
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/FlusterFlow/Models")
        let tokenizerStore = LocalModelStore(
            directory: ModelManifest.whisperLargeV3Tokenizer.installationDirectory(in: root),
            manifest: .whisperLargeV3Tokenizer
        )
        let tokenizerDirectory = try await tokenizerStore.validatedDirectory()
        let runtime = OfflineWhisperKitRuntime()

        for manifest in [ModelManifest.whisperLargeV3, .whisperLargeV3Turbo] {
            let modelStore = LocalModelStore(
                directory: manifest.installationDirectory(in: root),
                manifest: manifest
            )
            let modelDirectory = try await modelStore.validatedDirectory()
            try await runtime.prepare(
                modelDirectory: modelDirectory,
                tokenizerDirectory: tokenizerDirectory
            )
        }
    }

    func testInstalledWhisperTurboStreamsAndFinalizesAudioWhenExplicitlyRequested() async throws {
        guard let audioPath = ProcessInfo.processInfo.environment[
            "FLUSTERFLOW_WHISPER_SMOKE_AUDIO"
        ], !audioPath.isEmpty else {
            throw XCTSkip(
                "Set FLUSTERFLOW_WHISPER_SMOKE_AUDIO to a local audio file for the Core ML transcription smoke test"
            )
        }

        try await Self.assertInstalledWhisperModelTranscribesAudio(
            at: URL(fileURLWithPath: audioPath),
            model: .whisperLargeV3Turbo,
            backend: .whisperKitLargeV3Turbo,
            promptTerm: "Whisper Turbo",
            sessionSeed: 9_002,
            transcriptLabel: "WHISPER_TURBO_TRANSCRIPT"
        )
    }

    func testInstalledWhisperLargeFinalizesAudioWhenExplicitlyRequested() async throws {
        guard let audioPath = ProcessInfo.processInfo.environment[
            "FLUSTERFLOW_WHISPER_SMOKE_AUDIO"
        ], !audioPath.isEmpty else {
            throw XCTSkip(
                "Set FLUSTERFLOW_WHISPER_SMOKE_AUDIO to a local audio file for the Core ML transcription smoke test"
            )
        }

        try await Self.assertInstalledWhisperModelTranscribesAudio(
            at: URL(fileURLWithPath: audioPath),
            model: .whisperLargeV3,
            backend: .whisperKitLargeV3,
            promptTerm: "Whisper Large",
            sessionSeed: 9_004,
            transcriptLabel: "WHISPER_LARGE_TRANSCRIPT"
        )
    }

    func testInstalledAdaptiveWhisperRunsTheProductASRPathWhenExplicitlyRequested() async throws {
        guard let audioPath = ProcessInfo.processInfo.environment[
            "FLUSTERFLOW_WHISPER_SMOKE_AUDIO"
        ], !audioPath.isEmpty else {
            throw XCTSkip(
                "Set FLUSTERFLOW_WHISPER_SMOKE_AUDIO to a local audio file for the adaptive Core ML smoke test"
            )
        }

        let audio = try Self.normalizedAudio(at: URL(fileURLWithPath: audioPath))
        XCTAssertFalse(audio.values.isEmpty)

        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/FlusterFlow/Models")
        let samples = AudioBufferStore()
        let tokenizerStore = LocalModelStore(
            directory: ModelManifest.whisperLargeV3Tokenizer.installationDirectory(in: root),
            manifest: .whisperLargeV3Tokenizer
        )
        let turbo = WhisperKitRecognizer(
            sampleAccess: samples,
            modelStore: LocalModelStore(
                directory: ModelManifest.whisperLargeV3Turbo.installationDirectory(in: root),
                manifest: .whisperLargeV3Turbo
            ),
            tokenizerStore: tokenizerStore,
            backend: .whisperKitLargeV3Turbo
        )
        let large = WhisperKitRecognizer(
            sampleAccess: samples,
            modelStore: LocalModelStore(
                directory: ModelManifest.whisperLargeV3.installationDirectory(in: root),
                manifest: .whisperLargeV3
            ),
            tokenizerStore: tokenizerStore,
            backend: .whisperKitLargeV3
        )
        let recognizer = AdaptiveWhisperKitRecognizer(turbo: turbo, large: large)
        let sessionID = DictationSessionID(rawValue: 9_006)
        let hints = RecognitionHints(
            language: .german,
            terms: [],
            prioritizedLexiconTerms: ["FlusterFlow"]
        )

        try await recognizer.startRecognitionSession(hints: hints, sessionID: sessionID)
        _ = try await recognizer.updateRecognitionSession(
            with: RecognitionAudioChunk(samples: audio.values),
            sessionID: sessionID
        )
        await recognizer.stopRecognitionSession(sessionID: sessionID)

        let input = await samples.store(audio)
        let transcript = try await recognizer.finalizeRecognitionSession(
            input,
            hints: hints,
            sessionID: sessionID
        )
        await samples.release(input)

        XCTAssertFalse(transcript.text.isEmpty)
        XCTAssertNotNil(transcript.adaptive)
        print("ADAPTIVE_WHISPER_TRANSCRIPT=\(transcript.text)")
    }

    private static func assertInstalledWhisperModelTranscribesAudio(
        at audioURL: URL,
        model: ModelManifest,
        backend: RecognitionBackend,
        promptTerm: String,
        sessionSeed: UInt64,
        transcriptLabel: String
    ) async throws {
        let audio = try normalizedAudio(at: audioURL)
        XCTAssertFalse(audio.values.isEmpty)

        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/FlusterFlow/Models")
        let samples = AudioBufferStore()
        let recognizer = WhisperKitRecognizer(
            sampleAccess: samples,
            modelStore: LocalModelStore(
                directory: model.installationDirectory(in: root),
                manifest: model
            ),
            tokenizerStore: LocalModelStore(
                directory: ModelManifest.whisperLargeV3Tokenizer.installationDirectory(in: root),
                manifest: .whisperLargeV3Tokenizer
            ),
            backend: backend
        )
        let hints = RecognitionHints(
            language: .german,
            terms: [],
            prioritizedLexiconTerms: ["FlusterFlow", promptTerm]
        )
        let sessionID = DictationSessionID(rawValue: sessionSeed)

        try await recognizer.startRecognitionSession(hints: hints, sessionID: sessionID)
        let disposition = try await recognizer.updateRecognitionSession(
            with: RecognitionAudioChunk(samples: audio.values),
            sessionID: sessionID
        )
        await recognizer.stopRecognitionSession(sessionID: sessionID)

        let input = await samples.store(audio)
        let transcript = try await recognizer.finalizeRecognitionSession(
            input,
            hints: hints,
            sessionID: sessionID
        )
        await samples.release(input)

        XCTAssertEqual(disposition, .accepted)
        XCTAssertFalse(transcript.text.isEmpty)
        print("\(transcriptLabel)=\(transcript.text)")
    }

    private static func normalizedAudio(at url: URL) throws -> AudioSamples {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(file.length)
            )
        )
        try file.read(into: buffer)

        let channelData = try XCTUnwrap(buffer.floatChannelData)
        let channelCount = Int(format.channelCount)
        let frameCount = Int(buffer.frameLength)
        var mono = [Float](repeating: 0, count: frameCount)
        for channel in 0..<channelCount {
            for frame in 0..<frameCount {
                mono[frame] += channelData[channel][frame] / Float(channelCount)
            }
        }
        let realtimeChunks = stride(from: 0, to: mono.count, by: 512).map { start in
            CapturedAudioChunk(
                monoSamples: Array(mono[start..<min(start + 512, mono.count)]),
                sampleRate: format.sampleRate
            )
        }
        return try PCMNormalizer.normalize(realtimeChunks)
    }
}

private actor RecordingWhisperKitRuntime: WhisperKitRuntimeServing {
    struct Snapshot: Sendable {
        let modelDirectory: URL?
        let tokenizerDirectory: URL?
        let language: WhisperKitLanguageMode?
        let promptTokens: [Int]
        let transcriptionCount: Int
        let prewarmCount: Int
    }

    private let result: String
    private var modelDirectory: URL?
    private var tokenizerDirectory: URL?
    private var language: WhisperKitLanguageMode?
    private var promptTokens: [Int] = []
    private var transcriptionCount = 0
    private var prewarmCount = 0

    init(result: String) {
        self.result = result
    }

    func prepare(modelDirectory: URL, tokenizerDirectory: URL) {
        self.modelDirectory = modelDirectory
        self.tokenizerDirectory = tokenizerDirectory
    }

    func prewarm(modelDirectory: URL, tokenizerDirectory: URL) {
        prewarmCount += 1
        prepare(modelDirectory: modelDirectory, tokenizerDirectory: tokenizerDirectory)
    }

    func unload() {
        modelDirectory = nil
        tokenizerDirectory = nil
    }

    func prioritizedPromptTokens(for terms: [String], maxTokens: Int) -> [Int] {
        var tokens: [Int] = []
        for term in terms {
            let count = term.count
            guard tokens.count + count <= maxTokens else { continue }
            tokens.append(count)
        }
        return tokens
    }

    func transcribe(
        samples: [Float],
        language: WhisperKitLanguageMode,
        promptTokens: [Int],
        sessionID: DictationSessionID
    ) -> WhisperKitRecognitionResult {
        _ = samples
        _ = sessionID
        self.language = language
        self.promptTokens = promptTokens
        transcriptionCount += 1
        return WhisperKitRecognitionResult(
            text: result,
            segments: [
                RecognitionSegmentMetadata(
                    text: result,
                    avgLogprob: -0.1,
                    compressionRatio: 1.0,
                    noSpeechProbability: 0,
                    wordProbabilities: [
                        RecognitionWordProbability(word: result, probability: 0.95)
                    ]
                )
            ],
            avgLogprob: -0.1,
            minWordProbability: 0.95,
            compressionRatio: 1.0,
            decoderFallback: .none
        )
    }

    func cancel(sessionID: DictationSessionID) {
        _ = sessionID
    }

    func snapshot() -> Snapshot {
        Snapshot(
            modelDirectory: modelDirectory,
            tokenizerDirectory: tokenizerDirectory,
            language: language,
            promptTokens: promptTokens,
            transcriptionCount: transcriptionCount,
            prewarmCount: prewarmCount
        )
    }
}

private actor PromptSensitiveWhisperKitRuntime: WhisperKitRuntimeServing {
    private let promptlessResult: String
    private var prompts: [[Int]] = []

    init(promptlessResult: String) {
        self.promptlessResult = promptlessResult
    }

    func prepare(modelDirectory: URL, tokenizerDirectory: URL) {
        _ = modelDirectory
        _ = tokenizerDirectory
    }

    func prewarm(modelDirectory: URL, tokenizerDirectory: URL) {
        prepare(modelDirectory: modelDirectory, tokenizerDirectory: tokenizerDirectory)
    }

    func unload() {}

    func prioritizedPromptTokens(for terms: [String], maxTokens: Int) -> [Int] {
        var tokens: [Int] = []
        for term in terms {
            let count = term.count
            guard tokens.count + count <= maxTokens else { continue }
            tokens.append(count)
        }
        return tokens
    }

    func transcribe(
        samples: [Float],
        language: WhisperKitLanguageMode,
        promptTokens: [Int],
        sessionID: DictationSessionID
    ) -> WhisperKitRecognitionResult {
        _ = samples
        _ = language
        _ = sessionID
        prompts.append(promptTokens)
        let text = promptTokens.isEmpty ? promptlessResult : ""
        return WhisperKitRecognitionResult(
            text: text,
            segments: text.isEmpty ? [] : [
                RecognitionSegmentMetadata(
                    text: text,
                    avgLogprob: -0.1,
                    compressionRatio: 1.0,
                    noSpeechProbability: 0,
                    wordProbabilities: [
                        RecognitionWordProbability(word: text, probability: 0.95)
                    ]
                )
            ],
            avgLogprob: text.isEmpty ? nil : -0.1,
            minWordProbability: text.isEmpty ? nil : 0.95,
            compressionRatio: text.isEmpty ? nil : 1.0,
            decoderFallback: .none
        )
    }

    func cancel(sessionID: DictationSessionID) {
        _ = sessionID
    }

    func promptHistory() -> [[Int]] {
        prompts
    }
}

private actor ReadyLocalModelChecker: LocalModelChecking {
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func status() -> LocalModelStatus {
        .ready(
            LocalModelReadiness(
                manifestIdentifier: "fixture",
                modelRevision: "fixture",
                byteCount: 1,
                treeSHA256: ModelSHA256(String(repeating: "a", count: 64))!
            )
        )
    }

    func validatedDirectory() -> URL {
        directory
    }
}

private actor RecordingSpeechRecognizer: SpeechRecognizing {
    private let transcript: RawTranscript
    private var cancelled: [DictationSessionID] = []

    init(text: String) {
        self.transcript = RawTranscript(text: text, language: .automatic)
    }

    init(transcript: RawTranscript) {
        self.transcript = transcript
    }

    func transcribe(
        _ audio: AudioInput,
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) -> RawTranscript {
        _ = audio
        _ = sessionID
        return RawTranscript(
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

    func cancel(sessionID: DictationSessionID) {
        cancelled.append(sessionID)
    }

    func cancelledSessions() -> [DictationSessionID] {
        cancelled
    }
}

private actor FailingSpeechRecognizer: SpeechRecognizing {
    private enum Failure: Error {
        case recognitionFailed
    }

    func transcribe(
        _ audio: AudioInput,
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) throws -> RawTranscript {
        _ = audio
        _ = hints
        _ = sessionID
        throw Failure.recognitionFailed
    }

    func cancel(sessionID: DictationSessionID) {
        _ = sessionID
    }
}
