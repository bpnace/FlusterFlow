import CryptoKit
import Foundation
import XCTest
@testable import WhisperFlow

final class FluidAudioRecognizerTests: XCTestCase, @unchecked Sendable {
    func testMissingModelFailsClosedBeforeRuntimeAndLeavesAudioOwnedByCaller() async throws {
        let audioStore = AudioBufferStore()
        let input = await audioStore.store(AudioSamples(values: [0.1, 0.2]))
        let runtime = RecordingFluidRuntime()
        let missingStatus = LocalModelStatus.missing(
            problem: .directoryMissing,
            action: .importPinnedModel
        )
        let recognizer = FluidAudioRecognizer(
            sampleAccess: audioStore,
            modelStore: StubModelStore(result: .failure(LocalModelUnavailableError(status: missingStatus))),
            runtime: runtime
        )

        do {
            _ = try await recognizer.transcribe(
                input,
                hints: RecognitionHints(language: .automatic, terms: []),
                sessionID: DictationSessionID(rawValue: 1)
            )
            XCTFail("Missing models must fail closed")
        } catch {
            XCTAssertEqual(error as? LocalModelUnavailableError, LocalModelUnavailableError(status: missingStatus))
        }

        let prepareCount = await runtime.prepareCount()
        let transcribeCount = await runtime.transcribeCount()
        let storedBufferCount = await audioStore.storedBufferCount()
        XCTAssertEqual(prepareCount, 0)
        XCTAssertEqual(transcribeCount, 0)
        XCTAssertEqual(storedBufferCount, 1)
        await audioStore.release(input)
    }

    func testAutomaticGermanAndEnglishModesReachRuntimeWithoutDownloads() async throws {
        let audioStore = AudioBufferStore()
        let runtime = RecordingFluidRuntime()
        let recognizer = FluidAudioRecognizer(
            sampleAccess: audioStore,
            modelStore: StubModelStore(result: .success(URL(fileURLWithPath: "/synthetic/model"))),
            runtime: runtime
        )

        var ownedInputs: [AudioInput] = []
        for (index, language) in [
            DictationLanguage.automatic,
            .german,
            .english
        ].enumerated() {
            let input = await audioStore.store(AudioSamples(values: [0.1, -0.1]))
            ownedInputs.append(input)
            _ = try await recognizer.transcribe(
                input,
                hints: RecognitionHints(language: language, terms: ["AmberMesh"]),
                sessionID: DictationSessionID(rawValue: UInt64(index + 1))
            )
        }

        let languages = await runtime.languages()
        let prepareCount = await runtime.prepareCount()
        let storedBufferCount = await audioStore.storedBufferCount()
        XCTAssertEqual(languages, [.automatic, .german, .english])
        XCTAssertEqual(prepareCount, 1)
        XCTAssertEqual(storedBufferCount, 3)
        for input in ownedInputs {
            await audioStore.release(input)
        }
    }

    func testLocalModelStoreRejectsSameSizeContentCorruption() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("sample.bin")
        let original = Data("abc".utf8)
        try original.write(to: fileURL)
        let fileDigest = sha256(original)
        let record = "sample.bin\t\(original.count)\t\(fileDigest.rawValue)\n"
        let treeDigest = sha256(Data(record.utf8))
        let manifest = ModelManifest(
            identifier: "test-model",
            runtimeName: "FakeRuntime",
            runtimeVersion: "1.0.0",
            runtimeRevision: "revision",
            repository: "local/test",
            modelRevision: "model-revision",
            precision: "test",
            license: "test-only",
            expectedByteCount: Int64(original.count),
            treeSHA256: treeDigest,
            requiredTopLevelPaths: ["sample.bin"]
        )
        let store = LocalModelStore(directory: root, manifest: manifest)

        guard case .ready = await store.status() else {
            return XCTFail("Expected the exact fixture to validate")
        }

        try Data("abd".utf8).write(to: fileURL)
        guard case .invalid(let problem, let action) = await store.status() else {
            return XCTFail("Expected same-size corruption to fail the hash gate")
        }
        guard case .treeHashMismatch = problem else {
            return XCTFail("Expected a tree hash mismatch, got \(problem)")
        }
        XCTAssertEqual(action, .replaceCorruptModel)
    }

    func testInstalledParakeetModelLoadsWhenExplicitlyRequested() async throws {
        guard ProcessInfo.processInfo.environment["FLUSTERFLOW_RUN_PARAKEET_MODEL_SMOKE"] == "1" else {
            throw XCTSkip("Set FLUSTERFLOW_RUN_PARAKEET_MODEL_SMOKE=1 for the local FluidAudio smoke test")
        }
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/FlusterFlow/Models")
        let manifest = ModelManifest.parakeetV3Int8
        let store = LocalModelStore(
            directory: manifest.installationDirectory(in: root),
            manifest: manifest
        )
        let runtime = OfflineFluidAudioRuntime()

        try await runtime.prepare(modelDirectory: try await store.validatedDirectory())
    }

    func testRuntimeCancellationWaitsForTrackedTaskTermination() async {
        let runtime = OfflineFluidAudioRuntime()
        let sessionID = DictationSessionID(rawValue: 7_001)
        let started = AsyncTestGate()
        let cancellationObserved = AsyncTestGate()
        let allowTermination = AsyncTestGate()
        let cancellationReturned = AsyncTestFlag()

        let transcription = Task {
            try await runtime.runTrackedTranscription(sessionID: sessionID) {
                try await withTaskCancellationHandler {
                    await started.open()
                    await allowTermination.wait()
                    try Task.checkCancellation()
                    return "unreachable"
                } onCancel: {
                    Task { await cancellationObserved.open() }
                }
            }
        }
        await started.wait()

        let cancellation = Task {
            await runtime.cancel(sessionID: sessionID)
            await cancellationReturned.set()
        }
        await cancellationObserved.wait()

        let returnedBeforeTermination = await cancellationReturned.value
        XCTAssertFalse(returnedBeforeTermination)
        await allowTermination.open()
        await cancellation.value
        let returnedAfterTermination = await cancellationReturned.value
        XCTAssertTrue(returnedAfterTermination)
        _ = try? await transcription.value
    }

    func testRouterCancellationDuringPrepareKeepsLeaseUntilOperationTerminates() async throws {
        let audioStore = AudioBufferStore()
        let input = await audioStore.store(AudioSamples(values: [0.1, -0.1]))
        let runtime = BlockingPrepareFluidRuntime()
        let recognizer = FluidAudioRecognizer(
            sampleAccess: audioStore,
            modelStore: StubModelStore(result: .success(URL(fileURLWithPath: "/private/model"))),
            runtime: runtime
        )
        let router = SessionModelSpeechRecognizer(recognizers: [.parakeetV3Int8: recognizer])
        let firstSession = DictationSessionID(rawValue: 7_011)
        let secondSession = DictationSessionID(rawValue: 7_012)
        await router.register(.parakeetV3Int8, for: firstSession)
        await router.register(.parakeetV3Int8, for: secondSession)

        let transcription = Task {
            try await router.transcribe(
                input,
                hints: RecognitionHints(language: .automatic, terms: []),
                sessionID: firstSession
            )
        }
        await runtime.waitUntilPrepareStarts()

        let cancellationReturned = AsyncTestFlag()
        let cancellation = Task {
            await router.cancel(sessionID: firstSession)
            await cancellationReturned.set()
        }
        await runtime.waitUntilCancellationIsObserved()

        do {
            try await router.acquireExclusiveAccess(
                for: secondSession,
                purpose: .historyRetranscription
            )
            XCTFail("The lease must stay held while cancelled preparation is still terminating")
        } catch {
            XCTAssertEqual(
                error as? SessionModelSpeechRecognizerError,
                .recognizerBusy(activePurpose: .liveDictation)
            )
        }
        do {
            _ = try await router.transcribe(
                input,
                hints: RecognitionHints(language: .automatic, terms: []),
                sessionID: secondSession
            )
            XCTFail("A second session must not execute while preparation is still terminating")
        } catch {
            XCTAssertEqual(
                error as? SessionModelSpeechRecognizerError,
                .recognizerBusy(activePurpose: .liveDictation)
            )
        }
        let countWhileTerminating = await runtime.transcriptionCount
        XCTAssertEqual(countWhileTerminating, 0)
        let returnedBeforeTermination = await cancellationReturned.value
        XCTAssertFalse(returnedBeforeTermination)

        await runtime.allowPrepareToTerminate()
        await cancellation.value
        _ = try? await transcription.value

        try await router.acquireExclusiveAccess(
            for: secondSession,
            purpose: .historyRetranscription
        )
        let secondTranscript = try await router.transcribe(
            input,
            hints: RecognitionHints(language: .automatic, terms: []),
            sessionID: secondSession
        )
        await router.releaseExclusiveAccess(for: secondSession)
        let transcriptionCount = await runtime.transcriptionCount
        XCTAssertEqual(secondTranscript.text, "unexpected")
        XCTAssertEqual(transcriptionCount, 1)
        await audioStore.release(input)
    }

    private func sha256(_ data: Data) -> ModelSHA256 {
        let digest = SHA256.hash(data: data)
        let value = digest.map { String(format: "%02x", $0) }.joined()
        return ModelSHA256(value)!
    }
}

private actor AsyncTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor AsyncTestFlag {
    private(set) var value = false

    func set() {
        value = true
    }
}

private actor BlockingPrepareFluidRuntime: FluidAudioRuntimeServing {
    private let prepareStarted = AsyncTestGate()
    private let cancellationObserved = AsyncTestGate()
    private let allowTermination = AsyncTestGate()
    private(set) var transcriptionCount = 0

    func prepare(modelDirectory: URL) async throws {
        _ = modelDirectory
        try await withTaskCancellationHandler {
            await prepareStarted.open()
            await allowTermination.wait()
            try Task.checkCancellation()
        } onCancel: {
            Task { await cancellationObserved.open() }
        }
    }

    func transcribe(
        samples: [Float],
        language: FluidAudioLanguageMode,
        terms: [String],
        sessionID: DictationSessionID
    ) -> String {
        _ = samples
        _ = language
        _ = terms
        _ = sessionID
        transcriptionCount += 1
        return "unexpected"
    }

    func cancel(sessionID: DictationSessionID) {
        _ = sessionID
    }

    func waitUntilPrepareStarts() async {
        await prepareStarted.wait()
    }

    func waitUntilCancellationIsObserved() async {
        await cancellationObserved.wait()
    }

    func allowPrepareToTerminate() async {
        await allowTermination.open()
    }
}

private struct StubModelStore: LocalModelChecking {
    let result: Result<URL, LocalModelUnavailableError>

    func status() async -> LocalModelStatus {
        switch result {
        case .success:
            return .ready(
                LocalModelReadiness(
                    manifestIdentifier: "test",
                    modelRevision: "test",
                    byteCount: 0,
                    treeSHA256: ModelSHA256(String(repeating: "0", count: 64))!
                )
            )
        case .failure(let error):
            return error.status
        }
    }

    func validatedDirectory() async throws -> URL {
        try result.get()
    }
}

private actor RecordingFluidRuntime: FluidAudioRuntimeServing {
    private var preparations = 0
    private var transcriptions: [FluidAudioLanguageMode] = []

    func prepare(modelDirectory: URL) {
        preparations += 1
    }

    func transcribe(
        samples: [Float],
        language: FluidAudioLanguageMode,
        terms: [String],
        sessionID: DictationSessionID
    ) -> String {
        transcriptions.append(language)
        return "synthetic transcript"
    }

    func cancel(sessionID: DictationSessionID) {}

    func prepareCount() -> Int { preparations }
    func transcribeCount() -> Int { transcriptions.count }
    func languages() -> [FluidAudioLanguageMode] { transcriptions }
}
