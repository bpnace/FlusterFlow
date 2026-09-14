import Combine
import Foundation
import XCTest
@testable import WhisperFlow

@MainActor
final class RecordingHistoryViewModelTests: XCTestCase {
    func testSuccessfulRetranscriptionAppendsVersionWithSelectedLocalModel() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let backend = HistorySuccessSpeechRecognizer()
        let recognizer = SessionModelSpeechRecognizer(
            recognizers: [.parakeetV3Int8: backend]
        )
        let viewModel = RecordingHistoryViewModel(
            store: fixture.store,
            audioSamples: AudioBufferStore(),
            recognizer: recognizer,
            modelReadiness: RecordingHistoryModelReadinessProvider {
                $0 == .parakeetV3Int8
            }
        )

        await viewModel.reloadEntries()
        viewModel.selectedModel = .parakeetV3Int8
        await viewModel.performSelectedRetranscription()

        let entries = try await fixture.store.list()
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.state, .completed)
        XCTAssertEqual(entry.transcripts.count, 1)
        XCTAssertEqual(entry.transcripts.first?.version, 1)
        XCTAssertEqual(entry.transcripts.first?.backend, RecognitionBackend.parakeetV3Int8.rawValue)
        XCTAssertEqual(entry.transcripts.first?.text, "Erneut transkribiert")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isWorking)
        let transcriptionCount = await backend.transcriptionCount()
        XCTAssertEqual(transcriptionCount, 1)
    }

    func testRetranscribingCompletedEntryWithDifferentModelAppendsSecondVersion() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let existingEntries = try await fixture.store.list()
        let existingEntry = try XCTUnwrap(existingEntries.first)
        try await fixture.store.appendTranscript(
            TranscriptVersion(
                backend: RecognitionBackend.whisperKitLargeV3Turbo.rawValue,
                language: .german,
                text: "Erste Transkription"
            ),
            to: existingEntry.id
        )
        let backend = HistorySuccessSpeechRecognizer()
        let originalAudio = try await fixture.store.loadAudio(for: existingEntry.id)
        let recognizer = SessionModelSpeechRecognizer(
            recognizers: [.parakeetV3Int8: backend]
        )
        let viewModel = RecordingHistoryViewModel(
            store: fixture.store,
            audioSamples: AudioBufferStore(),
            recognizer: recognizer,
            modelReadiness: RecordingHistoryModelReadinessProvider {
                $0 == .parakeetV3Int8
            }
        )

        await viewModel.reloadEntries()
        viewModel.selectedModel = .parakeetV3Int8
        await viewModel.performSelectedRetranscription()

        let entries = try await fixture.store.list()
        let entry = try XCTUnwrap(entries.first)
        let persistedAudio = try await fixture.store.loadAudio(for: existingEntry.id)
        XCTAssertEqual(entry.state, .completed)
        XCTAssertEqual(persistedAudio, originalAudio)
        XCTAssertEqual(entry.transcripts.map(\.version), [1, 2])
        XCTAssertEqual(
            entry.transcripts.map(\.backend),
            [
                RecognitionBackend.whisperKitLargeV3Turbo.rawValue,
                RecognitionBackend.parakeetV3Int8.rawValue,
            ]
        )
        XCTAssertEqual(
            entry.transcripts.map(\.text),
            ["Erste Transkription", "Erneut transkribiert"]
        )
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isWorking)
        let transcriptionCount = await backend.transcriptionCount()
        XCTAssertEqual(transcriptionCount, 1)
    }

    func testPersistedRecognitionFailureCanRetrySameRecordingWithoutLeakingState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingHistoryStore(rootURL: root)
        let liveAudioSamples = AudioBufferStore()
        let recorder = RecordingHistoryRecorder(
            store: store,
            sampleAccess: liveAudioSamples
        )
        let backend = HistoryFailOnceSpeechRecognizer()
        let recognizer = SessionModelSpeechRecognizer(
            recognizers: [.parakeetV3Int8: backend]
        )
        let liveSessionID = DictationSessionID(rawValue: 700)
        let originalAudio = AudioSamples(
            values: [0.25, -0.25, 0.5, -0.5],
            sampleRate: 16_000
        )
        let liveInput = await liveAudioSamples.store(originalAudio)

        try await recorder.begin(sessionID: liveSessionID, language: .german)
        let initialEntries = try await store.list()
        let originalEntry = try XCTUnwrap(initialEntries.first)
        try await recorder.persistAudio(liveInput, sessionID: liveSessionID)
        await recognizer.register(.parakeetV3Int8, for: liveSessionID)
        do {
            _ = try await recognizer.transcribe(
                liveInput,
                hints: RecognitionHints(
                    language: .german,
                    terms: [],
                    prioritizedLexiconTerms: []
                ),
                sessionID: liveSessionID
            )
            XCTFail("Expected the initial recognition to fail")
        } catch is HistoryForcedRecognitionFailure {
            try await recorder.markFailed(sessionID: liveSessionID)
        }
        await recognizer.cancel(sessionID: liveSessionID)
        await liveAudioSamples.release(liveInput)

        let failedEntries = try await store.list()
        let failedEntry = try XCTUnwrap(failedEntries.first)
        let failedAudio = try await store.loadAudio(for: originalEntry.id)
        let liveBufferCount = await liveAudioSamples.storedBufferCount()
        XCTAssertEqual(failedEntries.count, 1)
        XCTAssertEqual(failedEntry.id, originalEntry.id)
        XCTAssertEqual(failedEntry.state, .failed)
        XCTAssertTrue(failedEntry.transcripts.isEmpty)
        XCTAssertEqual(failedAudio, originalAudio)
        XCTAssertEqual(liveBufferCount, 0)

        let retryAudioSamples = AudioBufferStore()
        let viewModel = RecordingHistoryViewModel(
            store: store,
            audioSamples: retryAudioSamples,
            recognizer: recognizer,
            modelReadiness: RecordingHistoryModelReadinessProvider {
                $0 == .parakeetV3Int8
            }
        )
        await viewModel.reloadEntries()
        viewModel.selectedModel = .parakeetV3Int8

        await viewModel.performSelectedRetranscription()

        let completedEntries = try await store.list()
        let completedEntry = try XCTUnwrap(completedEntries.first)
        let completedAudio = try await store.loadAudio(for: originalEntry.id)
        let retryBufferCount = await retryAudioSamples.storedBufferCount()
        let transcriptionCount = await backend.transcriptionCount()
        XCTAssertEqual(completedEntries.count, 1)
        XCTAssertEqual(completedEntry.id, originalEntry.id)
        XCTAssertEqual(completedEntry.state, .completed)
        XCTAssertEqual(completedAudio, originalAudio)
        XCTAssertEqual(completedEntry.transcripts.map(\.version), [1])
        XCTAssertEqual(
            completedEntry.transcripts.map(\.backend),
            [RecognitionBackend.parakeetV3Int8.rawValue]
        )
        XCTAssertFalse(completedEntry.transcripts[0].text.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isWorking)
        XCTAssertEqual(retryBufferCount, 0)
        XCTAssertEqual(transcriptionCount, 2)

        let leaseProbe = DictationSessionID(rawValue: 701)
        try await recognizer.acquireExclusiveAccess(
            for: leaseProbe,
            purpose: .historyRetranscription
        )
        await recognizer.releaseExclusiveAccess(for: leaseProbe)
    }

    func testUnavailableModelIsRejectedBeforeHistoryEntryChangesState() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = RecordingHistoryViewModel(
            store: fixture.store,
            audioSamples: AudioBufferStore(),
            recognizer: SessionModelSpeechRecognizer(recognizers: [:]),
            modelReadiness: RecordingHistoryModelReadinessProvider { _ in false }
        )

        await viewModel.reloadEntries()
        await viewModel.performSelectedRetranscription()

        let entries = try await fixture.store.list()
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.state, .ready)
        XCTAssertEqual(
            viewModel.errorMessage,
            "Das ausgewählte lokale Modell ist nicht verfügbar."
        )
        XCTAssertFalse(viewModel.isWorking)
    }

    func testBusyRecognizerIsRejectedBeforeHistoryEntryChangesState() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recognizer = SessionModelSpeechRecognizer(recognizers: [:])
        let liveSession = DictationSessionID(rawValue: 900)
        try await recognizer.acquireExclusiveAccess(
            for: liveSession,
            purpose: .liveDictation
        )
        let viewModel = RecordingHistoryViewModel(
            store: fixture.store,
            audioSamples: AudioBufferStore(),
            recognizer: recognizer
        )

        await viewModel.reloadEntries()
        await viewModel.performSelectedRetranscription()

        let entries = try await fixture.store.list()
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.state, .ready)
        XCTAssertEqual(
            viewModel.errorMessage,
            "Die lokale Spracherkennung ist gerade beschäftigt. Bitte versuche es nach dem aktuellen Diktat erneut."
        )
        XCTAssertFalse(viewModel.isWorking)
        await recognizer.releaseExclusiveAccess(for: liveSession)
    }

    func testFailedStatusWriteCanBeRepairedByRefreshingHistory() async throws {
        let fixture = try await makeFixture()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: fixture.root.path
            )
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let backend = PausingHistorySpeechRecognizer()
        let viewModel = RecordingHistoryViewModel(
            store: fixture.store,
            audioSamples: AudioBufferStore(),
            recognizer: SessionModelSpeechRecognizer(
                recognizers: [.parakeetV3Int8: backend]
            ),
            modelReadiness: RecordingHistoryModelReadinessProvider {
                $0 == .parakeetV3Int8
            }
        )
        await viewModel.reloadEntries()
        viewModel.selectedModel = .parakeetV3Int8

        let retranscription = Task {
            await viewModel.performSelectedRetranscription()
        }
        await backend.waitUntilStarted()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: fixture.root.path
        )
        await backend.resume()
        await retranscription.value

        var entries = try await fixture.store.list()
        var entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.state, .transcribing)
        XCTAssertEqual(
            viewModel.errorMessage,
            "Die Transkription ist fehlgeschlagen und ihr Status konnte nicht gespeichert werden. Stelle den Speicherzugriff wieder her und klicke auf Aktualisieren."
        )

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fixture.root.path
        )
        await viewModel.reloadEntries()

        entries = try await fixture.store.list()
        entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.state, .failed)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testRefreshRetriesOnlyCapturedLaunchRecoveryCandidates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let setupStore = RecordingHistoryStore(rootURL: root)
        let orphaned = try await setupStore.create(language: .german)
        let manifestPath = root.appendingPathComponent(orphaned.id.uuidString)
            .appendingPathExtension("json").path
        let writer = ViewModelControllableHistoryWriter(failingPath: manifestPath)
        let store = RecordingHistoryStore(rootURL: root, writeData: writer.write)
        await store.recoverAtLaunch()
        writer.allowWrites()
        let viewModel = RecordingHistoryViewModel(
            store: store,
            audioSamples: AudioBufferStore(),
            recognizer: SessionModelSpeechRecognizer(recognizers: [:])
        )

        await viewModel.reloadEntries()

        XCTAssertEqual(viewModel.entries.first?.id, orphaned.id)
        XCTAssertEqual(viewModel.entries.first?.state, .interrupted)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testRapidRetranscriptionRequestsReserveOneWorkflowSynchronously() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let backend = PausingHistorySpeechRecognizer()
        let viewModel = RecordingHistoryViewModel(
            store: fixture.store,
            audioSamples: AudioBufferStore(),
            recognizer: SessionModelSpeechRecognizer(
                recognizers: [.parakeetV3Int8: backend]
            ),
            modelReadiness: RecordingHistoryModelReadinessProvider {
                $0 == .parakeetV3Int8
            }
        )
        await viewModel.reloadEntries()
        viewModel.selectedModel = .parakeetV3Int8

        viewModel.retranscribeSelected()
        viewModel.retranscribeSelected()
        await backend.waitUntilStarted()

        XCTAssertTrue(viewModel.isWorking)
        let countWhilePaused = await backend.transcriptionCount()
        XCTAssertEqual(countWhilePaused, 1)

        await backend.resume()
        let completionDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while viewModel.isWorking, ContinuousClock.now < completionDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(viewModel.isWorking)
        let finalCount = await backend.transcriptionCount()
        XCTAssertEqual(finalCount, 1)
    }

    func testPartialDeleteAllFailureReloadsRemainingEntriesForRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let setupStore = RecordingHistoryStore(rootURL: root)
        let retained = try await setupStore.create(language: .english, state: .failed)
        try await setupStore.saveAudio(AudioSamples(values: [0.25]), for: retained.id)
        let removed = try await setupStore.create(language: .german, state: .failed)
        try await setupStore.saveAudio(AudioSamples(values: [0.5]), for: removed.id)
        let failingAudioPath = root.appendingPathComponent(retained.id.uuidString)
            .appendingPathExtension("audio").path
        let failingStore = RecordingHistoryStore(rootURL: root) { url in
            if url.path == failingAudioPath {
                throw RecordingHistoryError.deletionFailed
            }
            try FileManager.default.removeItem(at: url)
        }
        let viewModel = RecordingHistoryViewModel(
            store: failingStore,
            audioSamples: AudioBufferStore(),
            recognizer: SessionModelSpeechRecognizer(recognizers: [:])
        )
        await viewModel.reloadEntries()

        let deletionFinished = expectation(description: "partial deletion finishes")
        viewModel.deleteAll()
        XCTAssertTrue(viewModel.isWorking)
        let observation = viewModel.$isWorking
            .dropFirst()
            .filter { !$0 }
            .prefix(1)
            .sink { _ in deletionFinished.fulfill() }
        await fulfillment(of: [deletionFinished], timeout: 2)
        observation.cancel()

        XCTAssertFalse(viewModel.isWorking)
        XCTAssertEqual(viewModel.entries.map(\.id), [retained.id])
        XCTAssertTrue(viewModel.hasManagedArtifacts)
        XCTAssertTrue(viewModel.canDeleteAll)
        XCTAssertEqual(
            viewModel.errorMessage,
            "Die Aufnahmehistorie konnte nicht vollständig gelöscht werden."
        )
    }

    func testManifestDeleteFailureReportsRemovedAudioAndDisablesRetranscription() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let setupStore = RecordingHistoryStore(rootURL: root)
        let entry = try await setupStore.create(language: .german, state: .ready)
        try await setupStore.saveAudio(AudioSamples(values: [0.25]), for: entry.id)
        let manifestPath = root.appendingPathComponent(entry.id.uuidString)
            .appendingPathExtension("json").path
        let store = RecordingHistoryStore(rootURL: root) { url in
            if url.path == manifestPath {
                throw RecordingHistoryError.deletionFailed
            }
            try FileManager.default.removeItem(at: url)
        }
        let viewModel = RecordingHistoryViewModel(
            store: store,
            audioSamples: AudioBufferStore(),
            recognizer: SessionModelSpeechRecognizer(recognizers: [:])
        )
        await viewModel.reloadEntries()
        let deletionFinished = expectation(description: "partial deletion finishes")
        let observation = viewModel.$isWorking
            .dropFirst()
            .filter { !$0 }
            .prefix(1)
            .sink { _ in deletionFinished.fulfill() }

        viewModel.deleteSelected()
        await fulfillment(of: [deletionFinished], timeout: 2)
        observation.cancel()

        XCTAssertEqual(viewModel.selectedEntry?.id, entry.id)
        XCTAssertEqual(viewModel.selectedEntry?.hasAudio, false)
        XCTAssertEqual(
            viewModel.errorMessage,
            "Das Audio wurde gelöscht, aber der Historieneintrag konnte nicht entfernt werden. Du kannst das Löschen erneut versuchen."
        )
        await viewModel.performSelectedRetranscription()
        let stateAfterRejectedRetranscription = try await store.list().first?.state
        XCTAssertEqual(stateAfterRejectedRetranscription, .ready)
    }

    func testZeroFrameHeaderDisablesRetranscriptionAfterReload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingHistoryStore(rootURL: root)
        let entry = try await store.create(language: .german, state: .ready)
        try await store.saveAudio(AudioSamples(values: [0.25]), for: entry.id)
        let audioURL = root.appendingPathComponent(entry.id.uuidString)
            .appendingPathExtension("audio")
        try zeroFrameHistoryAudioHeader().write(to: audioURL, options: .atomic)
        let backend = HistorySuccessSpeechRecognizer()
        let viewModel = RecordingHistoryViewModel(
            store: store,
            audioSamples: AudioBufferStore(),
            recognizer: SessionModelSpeechRecognizer(
                recognizers: [.adaptive: backend]
            )
        )

        await viewModel.reloadEntries()
        await viewModel.performSelectedRetranscription()

        XCTAssertEqual(viewModel.selectedEntry?.id, entry.id)
        XCTAssertEqual(viewModel.selectedEntry?.hasAudio, false)
        XCTAssertNil(viewModel.selectedEntry?.durationSeconds)
        XCTAssertNil(viewModel.selectedEntry?.audioFormatVersion)
        let transcriptionCount = await backend.transcriptionCount()
        let entries = try await store.list()
        XCTAssertEqual(transcriptionCount, 0)
        XCTAssertEqual(entries.first?.state, .ready)
    }

    func testCorruptManifestStillEnablesManagedArtifactCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(
            to: root.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        )
        let viewModel = makeEmptyViewModel(root: root)

        await viewModel.reloadEntries()

        XCTAssertTrue(viewModel.entries.isEmpty)
        XCTAssertTrue(viewModel.hasManagedArtifacts)
        XCTAssertTrue(viewModel.canDeleteAll)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testOrphanAudioStillEnablesManagedArtifactCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("audio".utf8).write(
            to: root.appendingPathComponent(UUID().uuidString).appendingPathExtension("audio")
        )
        let viewModel = makeEmptyViewModel(root: root)

        await viewModel.reloadEntries()

        XCTAssertTrue(viewModel.entries.isEmpty)
        XCTAssertTrue(viewModel.hasManagedArtifacts)
        XCTAssertTrue(viewModel.canDeleteAll)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testEmptyHistoryHasNoManagedArtifactsOrRecoveryWarning() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = makeEmptyViewModel(root: root)

        await viewModel.reloadEntries()

        XCTAssertTrue(viewModel.entries.isEmpty)
        XCTAssertFalse(viewModel.hasManagedArtifacts)
        XCTAssertFalse(viewModel.canDeleteAll)
        XCTAssertNil(viewModel.errorMessage)
    }

    private func makeEmptyViewModel(root: URL) -> RecordingHistoryViewModel {
        RecordingHistoryViewModel(
            store: RecordingHistoryStore(rootURL: root),
            audioSamples: AudioBufferStore(),
            recognizer: SessionModelSpeechRecognizer(recognizers: [:])
        )
    }

    private func makeFixture() async throws -> (
        root: URL,
        store: RecordingHistoryStore
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RecordingHistoryStore(rootURL: root)
        let entry = try await store.create(language: .german)
        try await store.saveAudio(
            AudioSamples(values: [0.1, -0.1], sampleRate: 16_000),
            for: entry.id
        )
        return (root, store)
    }
}

private func zeroFrameHistoryAudioHeader() -> Data {
    var data = Data("FFL1".utf8)
    appendHistoryLittleEndian(UInt16(RecordingHistoryStore.audioFormatVersion), to: &data)
    appendHistoryLittleEndian(UInt16(1), to: &data)
    appendHistoryLittleEndian(UInt32(16_000), to: &data)
    appendHistoryLittleEndian(UInt64(0), to: &data)
    return data
}

private func appendHistoryLittleEndian<T: FixedWidthInteger>(
    _ value: T,
    to data: inout Data
) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
}

private final class ViewModelControllableHistoryWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let failingPath: String
    private var shouldFail = true

    init(failingPath: String) {
        self.failingPath = failingPath
    }

    func write(_ data: Data, to url: URL) throws {
        lock.lock()
        let fails = shouldFail && url.path == failingPath
        lock.unlock()
        if fails { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
    }

    func allowWrites() {
        lock.lock()
        shouldFail = false
        lock.unlock()
    }
}

private actor HistorySuccessSpeechRecognizer: SpeechRecognizing {
    private var count = 0

    func transcribe(
        _ audio: AudioInput,
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async -> RawTranscript {
        _ = audio
        _ = hints
        _ = sessionID
        count += 1
        return RawTranscript(
            text: "Erneut transkribiert",
            language: .german,
            backend: .parakeetV3Int8
        )
    }

    func cancel(sessionID: DictationSessionID) async {
        _ = sessionID
    }

    func transcriptionCount() -> Int { count }
}

private struct HistoryForcedRecognitionFailure: Error {}

private actor HistoryFailOnceSpeechRecognizer: SpeechRecognizing {
    private var count = 0

    func transcribe(
        _ audio: AudioInput,
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async throws -> RawTranscript {
        _ = audio
        _ = hints
        _ = sessionID
        count += 1
        if count == 1 {
            throw HistoryForcedRecognitionFailure()
        }
        return RawTranscript(
            text: "Erfolgreich wiederholt",
            language: .german,
            backend: .parakeetV3Int8
        )
    }

    func cancel(sessionID: DictationSessionID) async {
        _ = sessionID
    }

    func transcriptionCount() -> Int { count }
}

private actor PausingHistorySpeechRecognizer: SpeechRecognizing {
    private var count = 0
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []

    func transcribe(
        _ audio: AudioInput,
        hints: RecognitionHints,
        sessionID: DictationSessionID
    ) async -> RawTranscript {
        _ = audio
        _ = hints
        _ = sessionID
        count += 1
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            resumeWaiters.append(continuation)
        }
        return RawTranscript(
            text: "Nicht speicherbar",
            language: .german,
            backend: .parakeetV3Int8
        )
    }

    func cancel(sessionID: DictationSessionID) async {
        _ = sessionID
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resume() {
        let waiters = resumeWaiters
        resumeWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func transcriptionCount() -> Int { count }
}
