import Foundation
import XCTest
@testable import WhisperFlow

final class RecordingHistoryStoreTests: XCTestCase {
    func testTranscriptVersionKindRoundTripsAndLegacyManifestsDecodeAsRaw() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let raw = TranscriptVersion(
            backend: "whisper",
            language: .german,
            createdAt: Date(timeIntervalSince1970: 10),
            text: "Roh",
            kind: .raw
        )
        let final = TranscriptVersion(
            backend: "rewriter",
            language: .german,
            createdAt: Date(timeIntervalSince1970: 11),
            text: "Final",
            kind: .final
        )
        let encoded = try JSONEncoder.iso8601.encode([raw, final])
        let decoded = try decoder.decode(
            [TranscriptVersion].self,
            from: encoded
        )

        XCTAssertEqual(decoded.map(\.kind), [.raw, .final])

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder.iso8601.encode(raw))
                as? [String: Any]
        )
        legacyObject.removeValue(forKey: "kind")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacy = try decoder.decode(
            TranscriptVersion.self,
            from: legacyData
        )

        XCTAssertEqual(legacy.kind, .raw)
    }

    func testRoundTripAndNewestFirst() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingHistoryStore(rootURL: root)
        let old = try await store.create(language: .german)
        _ = try await store.create(language: .english, state: .failed)
        let samples = AudioSamples(values: [0.5, -1, 0], sampleRate: 16_000)
        try await store.saveAudio(samples, for: old.id)
        try await store.appendTranscript(TranscriptVersion(backend: "whisper", language: .german, createdAt: Date(timeIntervalSince1970: 10), text: "Hallo"), to: old.id)
        let loaded = try await store.loadAudio(for: old.id)
        let entries = try await store.list()
        let versions = try await store.versions(for: old.id)
        XCTAssertEqual(loaded, samples)
        XCTAssertEqual(entries.map(\.id).count, 2)
        XCTAssertEqual(versions.count, 1)
        try await store.deleteAll()
    }

    func testRecoveryMarksInFlightAsInterrupted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingHistoryStore(rootURL: root)
        let recording = try await store.create(language: .automatic)
        try await store.mark(recording.id, state: .transcribing)
        let recovered = try await store.recover()
        XCTAssertEqual(recovered.first?.state, .interrupted)
    }

    func testRecoveryKeepsRecordingCheckpointAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingHistoryStore(rootURL: root)
        let recording = try await store.create(language: .german)
        let checkpoint = AudioSamples(values: [0.1, -0.2, 0.3], sampleRate: 16_000)
        try await store.saveAudio(checkpoint, for: recording.id, state: .recording)

        _ = try await store.recover()

        let loaded = try await store.loadAudio(for: recording.id)
        XCTAssertEqual(loaded, checkpoint)
        let recovered = try await store.list()
        XCTAssertEqual(recovered.first?.state, .interrupted)
    }

    func testLaunchRecoveryCanBeRetriedWithoutInterruptingSessionsStartedAfterLaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let setupStore = RecordingHistoryStore(rootURL: root)
        let orphaned = try await setupStore.create(language: .german)
        let recoveredSamples = AudioSamples(
            values: Array(repeating: 0.2, count: 16_000),
            sampleRate: 16_000
        )
        try await setupStore.saveAudio(
            recoveredSamples,
            for: orphaned.id,
            state: .recording
        )
        let ready = try await setupStore.create(language: .english, state: .ready)
        try await setupStore.saveAudio(AudioSamples(values: [0.2]), for: ready.id)
        let orphanedManifest = root.appendingPathComponent(orphaned.id.uuidString)
            .appendingPathExtension("json")
        try JSONEncoder.iso8601.encode(orphaned).write(
            to: orphanedManifest,
            options: .atomic
        )
        let writer = ControllableHistoryWriter(failingPath: orphanedManifest.path)
        let store = RecordingHistoryStore(rootURL: root, writeData: writer.write)

        await store.recoverAtLaunch()

        let warningAfterFailure = await store.hasRecoveryWarning()
        XCTAssertTrue(warningAfterFailure)
        let live = try await store.create(language: .automatic)
        _ = try await store.beginRetranscription(ready.id)
        writer.allowWrites()

        await store.retryLaunchRecovery()

        let entries = try await store.list()
        let recovered = try XCTUnwrap(entries.first(where: { $0.id == orphaned.id }))
        XCTAssertEqual(recovered.state, .interrupted)
        XCTAssertTrue(recovered.hasAudio)
        XCTAssertEqual(recovered.audioFormatVersion, RecordingHistoryStore.audioFormatVersion)
        XCTAssertEqual(recovered.durationSeconds ?? 0, 1, accuracy: 0.001)
        let loadedRecoveredSamples = try await store.loadAudio(for: orphaned.id)
        XCTAssertEqual(loadedRecoveredSamples, recoveredSamples)
        XCTAssertEqual(entries.first(where: { $0.id == live.id })?.state, .recording)
        XCTAssertEqual(entries.first(where: { $0.id == ready.id })?.state, .transcribing)
        let warningAfterRetry = await store.hasRecoveryWarning()
        XCTAssertFalse(warningAfterRetry)
    }

    func testRecorderPersistsFirstCrashCheckpointImmediatelyThenEveryFiveSeconds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingHistoryStore(rootURL: root)
        let recorder = RecordingHistoryRecorder(
            store: store,
            sampleAccess: AudioBufferStore()
        )
        let sessionID = DictationSessionID(rawValue: 42)
        try await recorder.begin(sessionID: sessionID, language: .english)

        try await recorder.persistCheckpoint(
            RecognitionAudioChunk(samples: Array(repeating: 0.1, count: 8_000)),
            sessionID: sessionID
        )

        var entries = try await store.list()
        XCTAssertEqual(entries.first?.durationSeconds ?? 0, 0.5, accuracy: 0.001)

        try await recorder.persistCheckpoint(
            RecognitionAudioChunk(samples: Array(repeating: 0.1, count: 8_000)),
            sessionID: sessionID
        )
        entries = try await store.list()
        XCTAssertEqual(entries.first?.durationSeconds ?? 0, 1.0, accuracy: 0.001)

        try await recorder.persistCheckpoint(
            RecognitionAudioChunk(samples: Array(repeating: 0.1, count: 72_000)),
            sessionID: sessionID
        )
        entries = try await store.list()
        XCTAssertEqual(entries.first?.state, .recording)
        XCTAssertEqual(entries.first?.hasAudio, true)
        XCTAssertEqual(entries.first?.durationSeconds ?? 0, 5.5, accuracy: 0.001)
    }

    func testRecorderKeepsSessionMappingUntilCompleteAndPersistsRawAndFinalVersions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingHistoryStore(rootURL: root)
        let sampleStore = AudioBufferStore()
        let recorder = RecordingHistoryRecorder(store: store, sampleAccess: sampleStore)
        let sessionID = DictationSessionID(rawValue: 43)
        let input = await sampleStore.store(AudioSamples(values: [0.1, -0.1]))
        try await recorder.begin(sessionID: sessionID, language: .german)
        try await recorder.persistAudio(input, sessionID: sessionID)
        try await recorder.persistTranscript(
            RawTranscript(
                text: "Roh",
                language: .german,
                backend: .whisperKitLargeV3
            ),
            sessionID: sessionID
        )
        try await recorder.persistFinalTranscript("Final", sessionID: sessionID)

        let entriesAfterTranscript = try await store.list()
        let entry = try XCTUnwrap(entriesAfterTranscript.first)
        XCTAssertEqual(entry.state, .transcribing)
        XCTAssertEqual(entry.transcripts.map(\.kind), [.raw, .final])
        XCTAssertEqual(entry.transcripts.map(\.text), ["Roh", "Final"])

        try await recorder.complete(sessionID: sessionID)
        let entriesAfterComplete = try await store.list()
        let completedEntry = try XCTUnwrap(entriesAfterComplete.first)
        XCTAssertEqual(completedEntry.state, .completed)
        do {
            try await recorder.persistFinalTranscript("Nachlauf", sessionID: sessionID)
            XCTFail("Expected the completed recorder session mapping to be released")
        } catch let error as RecordingHistoryError {
            XCTAssertEqual(error, .missingRecording)
        }
    }

    func testDeleteRemovesAudioAndManifest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingHistoryStore(rootURL: root)
        let recording = try await store.create(language: .english)
        try await store.saveAudio(AudioSamples(values: [1]), for: recording.id)
        try await store.delete(recording.id)
        let entries = try await store.list()
        XCTAssertTrue(entries.isEmpty)
        await XCTAssertHistoryThrowsErrorAsync(try await store.loadAudio(for: recording.id))
    }

    func testSaveAudioRejectsEmptySamplesWithoutCreatingRetryableAsset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingHistoryStore(rootURL: root)
        let recording = try await store.create(language: .english)

        await XCTAssertHistoryThrowsErrorAsync(
            try await store.saveAudio(
                AudioSamples(values: [], sampleRate: 16_000),
                for: recording.id,
                state: .failed
            )
        )

        let entries = try await store.list()
        let entry = try XCTUnwrap(entries.first)
        XCTAssertFalse(entry.hasAudio)
        XCTAssertNil(entry.audioFormatVersion)
        XCTAssertNil(entry.durationSeconds)
        await XCTAssertHistoryThrowsErrorAsync(try await store.loadAudio(for: recording.id))
    }

    func testZeroFrameHeaderIsReconciledAndCannotBeginRetranscription() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingHistoryStore(rootURL: root)
        let recording = try await store.create(language: .english)
        try await store.saveAudio(
            AudioSamples(values: [0.25], sampleRate: 16_000),
            for: recording.id
        )
        let audioURL = root.appendingPathComponent(recording.id.uuidString)
            .appendingPathExtension("audio")
        let zeroFrameHeader = zeroFrameFFL1Header()
        XCTAssertEqual(zeroFrameHeader.count, 20)
        try zeroFrameHeader.write(to: audioURL, options: .atomic)

        await XCTAssertHistoryThrowsErrorAsync(try await store.loadAudio(for: recording.id))
        await XCTAssertHistoryThrowsErrorAsync(
            try await store.beginRetranscription(recording.id)
        )

        let entries = try await store.list()
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.state, .ready)
        XCTAssertFalse(entry.hasAudio)
        XCTAssertNil(entry.durationSeconds)
        XCTAssertNil(entry.audioFormatVersion)
    }

    func testRecoveryDoesNotRestoreZeroFrameHeaderAsAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingHistoryStore(rootURL: root)
        let recording = try await store.create(language: .german, state: .recording)
        let audioURL = root.appendingPathComponent(recording.id.uuidString)
            .appendingPathExtension("audio")
        try zeroFrameFFL1Header().write(to: audioURL, options: .atomic)

        _ = try await store.recover()

        let entries = try await store.list()
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.state, .interrupted)
        XCTAssertFalse(entry.hasAudio)
        XCTAssertNil(entry.durationSeconds)
        XCTAssertNil(entry.audioFormatVersion)
    }

    func testDeleteKeepsManifestVisibleWhenAudioRemovalFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingHistoryStore(rootURL: root)
        let recording = try await store.create(language: .english)
        try await store.saveAudio(AudioSamples(values: [1]), for: recording.id)
        let audioURL = root.appendingPathComponent(recording.id.uuidString)
            .appendingPathExtension("audio")
        let manifestURL = root.appendingPathComponent(recording.id.uuidString)
            .appendingPathExtension("json")
        let failingAudioPath = audioURL.path
        let failingStore = RecordingHistoryStore(rootURL: root) { url in
            if url.path == failingAudioPath {
                throw RecordingHistoryError.deletionFailed
            }
            try FileManager.default.removeItem(at: url)
        }

        await XCTAssertHistoryThrowsErrorAsync(try await failingStore.delete(recording.id))

        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
        let remainingEntries = try await failingStore.list()
        XCTAssertEqual(remainingEntries.map(\.id), [recording.id])

        try await store.delete(recording.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL.path))
    }

    func testDeleteKeepsManifestVisibleWhenManifestRemovalFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingHistoryStore(rootURL: root)
        let recording = try await store.create(language: .english)
        try await store.saveAudio(AudioSamples(values: [1]), for: recording.id)
        let audioURL = root.appendingPathComponent(recording.id.uuidString)
            .appendingPathExtension("audio")
        let manifestURL = root.appendingPathComponent(recording.id.uuidString)
            .appendingPathExtension("json")
        let failingManifestPath = manifestURL.path
        let failingStore = RecordingHistoryStore(rootURL: root) { url in
            if url.path == failingManifestPath {
                throw RecordingHistoryError.deletionFailed
            }
            try FileManager.default.removeItem(at: url)
        }

        await XCTAssertHistoryThrowsErrorAsync(try await failingStore.delete(recording.id))

        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
        await XCTAssertHistoryThrowsErrorAsync(
            try await failingStore.beginRetranscription(recording.id)
        )
        let remainingEntries = try await failingStore.list()
        XCTAssertEqual(remainingEntries.map(\.id), [recording.id])
        XCTAssertEqual(remainingEntries.first?.hasAudio, false)
        XCTAssertNil(remainingEntries.first?.durationSeconds)
        XCTAssertNil(remainingEntries.first?.audioFormatVersion)
        let hasRecoveryWarning = await failingStore.hasRecoveryWarning()
        XCTAssertTrue(hasRecoveryWarning)
        let stateAfterRejectedRetranscription = try await failingStore.list().first?.state
        XCTAssertEqual(stateAfterRejectedRetranscription, .ready)

        try await store.delete(recording.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL.path))
    }

    func testDeleteAllRemovesManagedFilesEvenWithCorruptManifest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingHistoryStore(rootURL: root)
        let valid = try await store.create(language: .english)
        try await store.saveAudio(AudioSamples(values: [0.25]), for: valid.id)

        let corruptID = UUID()
        try Data("not-json".utf8).write(
            to: root.appendingPathComponent(corruptID.uuidString).appendingPathExtension("json")
        )
        try Data("audio".utf8).write(
            to: root.appendingPathComponent(corruptID.uuidString).appendingPathExtension("audio")
        )
        let unrelated = root.appendingPathComponent("keep-me.txt")
        try Data("unrelated".utf8).write(to: unrelated)

        try await store.deleteAll()

        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(remaining, ["keep-me.txt"])
    }

    func testDeleteAllContinuesAndKeepsFailedAudioManifestVisibleForRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingHistoryStore(rootURL: root)
        let retained = try await store.create(language: .english)
        try await store.saveAudio(AudioSamples(values: [0.25]), for: retained.id)
        let removed = try await store.create(language: .german, state: .failed)
        try await store.saveAudio(AudioSamples(values: [0.5]), for: removed.id)
        let retainedAudioURL = root.appendingPathComponent(retained.id.uuidString)
            .appendingPathExtension("audio")
        let retainedManifestURL = root.appendingPathComponent(retained.id.uuidString)
            .appendingPathExtension("json")
        let removedAudioURL = root.appendingPathComponent(removed.id.uuidString)
            .appendingPathExtension("audio")
        let removedManifestURL = root.appendingPathComponent(removed.id.uuidString)
            .appendingPathExtension("json")
        let failingAudioPath = retainedAudioURL.path
        let failingStore = RecordingHistoryStore(rootURL: root) { url in
            if url.path == failingAudioPath {
                throw RecordingHistoryError.deletionFailed
            }
            try FileManager.default.removeItem(at: url)
        }

        await XCTAssertHistoryThrowsErrorAsync(try await failingStore.deleteAll())

        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedAudioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedManifestURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: removedAudioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: removedManifestURL.path))
        let remainingEntries = try await failingStore.list()
        XCTAssertEqual(remainingEntries.map(\.id), [retained.id])

        try await store.deleteAll()
        let hasManagedArtifacts = try await store.hasManagedArtifacts()
        XCTAssertFalse(hasManagedArtifacts)
    }

    func testActiveRecordingCannotBeDeletedOrRetranscribed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingHistoryStore(rootURL: root)
        let active = try await store.create(language: .german)

        await XCTAssertHistoryThrowsErrorAsync(try await store.delete(active.id))
        await XCTAssertHistoryThrowsErrorAsync(try await store.deleteAll())
        await XCTAssertHistoryThrowsErrorAsync(try await store.beginRetranscription(active.id))

        let remaining = try await store.list()
        XCTAssertEqual(remaining.map(\.id), [active.id])
    }

    func testRecoveryReconcilesAudioWrittenBeforeManifestUpdate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingHistoryStore(rootURL: root)
        let recording = try await store.create(language: .english)
        let samples = AudioSamples(values: Array(repeating: 0.2, count: 16_000))
        try await store.saveAudio(samples, for: recording.id, state: .recording)

        let manifestURL = root.appendingPathComponent(recording.id.uuidString).appendingPathExtension("json")
        let staleData = try JSONEncoder.iso8601.encode(recording)
        try staleData.write(to: manifestURL, options: .atomic)

        _ = try await store.recover()

        let entries = try await store.list()
        let recovered = try XCTUnwrap(entries.first)
        XCTAssertEqual(recovered.state, .interrupted)
        XCTAssertTrue(recovered.hasAudio)
        XCTAssertEqual(recovered.durationSeconds ?? 0, 1, accuracy: 0.001)
    }

    func testHistoryDirectoryAndFilesUseRestrictivePermissions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingHistoryStore(rootURL: root)
        let recording = try await store.create(language: .german)
        try await store.saveAudio(AudioSamples(values: [0.1]), for: recording.id)

        let manifest = root.appendingPathComponent(recording.id.uuidString).appendingPathExtension("json")
        let audio = root.appendingPathComponent(recording.id.uuidString).appendingPathExtension("audio")
        XCTAssertEqual(permissions(at: root), 0o700)
        XCTAssertEqual(permissions(at: manifest), 0o600)
        XCTAssertEqual(permissions(at: audio), 0o600)
    }

    func testRecorderCancellationDiscardsEmptyActiveEntry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingHistoryStore(rootURL: root)
        let recorder = RecordingHistoryRecorder(
            store: store,
            sampleAccess: AudioBufferStore()
        )
        let sessionID = DictationSessionID(rawValue: 99)
        try await recorder.begin(sessionID: sessionID, language: .automatic)

        try await recorder.interrupt(sessionID: sessionID)

        let entries = try await store.list()
        XCTAssertTrue(entries.isEmpty)
    }

    func testRecorderFinalizationDiscardsEmptyAudioInsteadOfCreatingRetryableEntry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingHistoryStore(rootURL: root)
        let sampleStore = AudioBufferStore()
        let recorder = RecordingHistoryRecorder(store: store, sampleAccess: sampleStore)
        let sessionID = DictationSessionID(rawValue: 102)
        let input = await sampleStore.store(
            AudioSamples(values: [], sampleRate: 16_000, channelCount: 1)
        )
        try await recorder.begin(sessionID: sessionID, language: .automatic)

        try await recorder.persistAudio(input, sessionID: sessionID)
        try await recorder.markFailed(sessionID: sessionID)

        let entries = try await store.list()
        XCTAssertTrue(entries.isEmpty)
        let managedArtifacts = try await store.hasManagedArtifacts()
        XCTAssertFalse(managedArtifacts)
    }

    func testRecorderFinalizationKeepsCheckpointWhenFinalAudioIsEmpty() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingHistoryStore(rootURL: root)
        let sampleStore = AudioBufferStore()
        let recorder = RecordingHistoryRecorder(store: store, sampleAccess: sampleStore)
        let sessionID = DictationSessionID(rawValue: 103)
        let checkpoint = RecognitionAudioChunk(
            samples: [0.25, -0.25],
            sampleRate: 16_000,
            channelCount: 1
        )
        let input = await sampleStore.store(
            AudioSamples(values: [], sampleRate: 16_000, channelCount: 1)
        )
        try await recorder.begin(sessionID: sessionID, language: .automatic)
        try await recorder.persistCheckpoint(checkpoint, sessionID: sessionID)

        try await recorder.persistAudio(input, sessionID: sessionID)
        try await recorder.markFailed(sessionID: sessionID)

        let entries = try await store.list()
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.state, .failed)
        XCTAssertTrue(entry.hasAudio)
        let preserved = try await store.loadAudio(for: entry.id)
        XCTAssertEqual(preserved.values, checkpoint.samples)
    }

    func testRecorderCancellationPersistsBufferedCheckpointAsInterrupted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingHistoryStore(rootURL: root)
        let recorder = RecordingHistoryRecorder(
            store: store,
            sampleAccess: AudioBufferStore()
        )
        let sessionID = DictationSessionID(rawValue: 101)
        try await recorder.begin(sessionID: sessionID, language: .german)
        let chunk = RecognitionAudioChunk(
            samples: Array(repeating: 0.25, count: 16_000),
            sampleRate: 16_000,
            channelCount: 1
        )

        try await recorder.persistCheckpoint(chunk, sessionID: sessionID)
        try await recorder.interrupt(sessionID: sessionID)

        let entries = try await store.list()
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.state, .interrupted)
        XCTAssertTrue(entry.hasAudio)
        let loaded = try await store.loadAudio(for: entry.id)
        XCTAssertEqual(loaded.values, chunk.samples)
    }

    func testRecorderRetriesFinalAudioWhenInitialPersistenceFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: root.path
            )
            try? FileManager.default.removeItem(at: root)
        }
        let store = RecordingHistoryStore(rootURL: root)
        let sampleStore = AudioBufferStore()
        let recorder = RecordingHistoryRecorder(store: store, sampleAccess: sampleStore)
        let sessionID = DictationSessionID(rawValue: 100)
        let samples = AudioSamples(values: [0.1, -0.2, 0.3], sampleRate: 16_000)
        let input = await sampleStore.store(samples)
        try await recorder.begin(sessionID: sessionID, language: .german)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: root.path
        )
        await XCTAssertHistoryThrowsErrorAsync(
            try await recorder.persistAudio(input, sessionID: sessionID)
        )

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )
        try await recorder.markFailed(sessionID: sessionID)

        let entries = try await store.list()
        let entry = try XCTUnwrap(entries.first)
        let recovered = try await store.loadAudio(for: entry.id)
        XCTAssertEqual(entry.state, .failed)
        XCTAssertEqual(recovered, samples)
    }

    func testRecorderRetainsFinalAudioUntilTerminalPersistenceCanBeRetried() async throws {
        for (index, terminalState) in [RecordingHistoryState.failed, .interrupted].enumerated() {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: root.path
                )
                try? FileManager.default.removeItem(at: root)
            }
            let store = RecordingHistoryStore(rootURL: root)
            let sampleStore = AudioBufferStore()
            let recorder = RecordingHistoryRecorder(store: store, sampleAccess: sampleStore)
            let sessionID = DictationSessionID(rawValue: UInt64(200 + index))
            let samples = AudioSamples(values: [0.2, -0.4, 0.6], sampleRate: 16_000)
            let input = await sampleStore.store(samples)
            try await recorder.begin(sessionID: sessionID, language: .german)

            try FileManager.default.setAttributes(
                [.posixPermissions: 0o500],
                ofItemAtPath: root.path
            )
            await XCTAssertHistoryThrowsErrorAsync(
                try await recorder.persistAudio(input, sessionID: sessionID)
            )
            switch terminalState {
            case .failed:
                await XCTAssertHistoryThrowsErrorAsync(
                    try await recorder.markFailed(sessionID: sessionID)
                )
            case .interrupted:
                await XCTAssertHistoryThrowsErrorAsync(
                    try await recorder.interrupt(sessionID: sessionID)
                )
            case .recording, .ready, .transcribing, .completed:
                XCTFail("Unexpected terminal state")
            }

            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: root.path
            )
            switch terminalState {
            case .failed:
                try await recorder.markFailed(sessionID: sessionID)
            case .interrupted:
                try await recorder.interrupt(sessionID: sessionID)
            case .recording, .ready, .transcribing, .completed:
                XCTFail("Unexpected terminal state")
            }

            let entries = try await store.list()
            let entry = try XCTUnwrap(entries.first)
            let recoveredSamples = try await store.loadAudio(for: entry.id)
            XCTAssertEqual(entry.state, terminalState)
            XCTAssertEqual(recoveredSamples, samples)
        }
    }

    func testLegacyManifestWithoutSchemaVersionDecodesAsVersionOne() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID()
        let manifest = """
        {"id":"\(id.uuidString)","createdAt":"2026-09-05T00:00:00Z","language":"automatic","state":"interrupted","transcripts":[],"hasAudio":false}
        """
        try Data(manifest.utf8).write(
            to: root.appendingPathComponent(id.uuidString).appendingPathExtension("json")
        )

        let store = RecordingHistoryStore(rootURL: root)
        let entries = try await store.list()
        let entry = try XCTUnwrap(entries.first)

        XCTAssertEqual(entry.schemaVersion, 1)
    }

    private func permissions(at url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue
    }
}

private func zeroFrameFFL1Header() -> Data {
    var data = Data("FFL1".utf8)
    appendLittleEndian(UInt16(RecordingHistoryStore.audioFormatVersion), to: &data)
    appendLittleEndian(UInt16(1), to: &data)
    appendLittleEndian(UInt32(16_000), to: &data)
    appendLittleEndian(UInt64(0), to: &data)
    return data
}

private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
}

private final class ControllableHistoryWriter: @unchecked Sendable {
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

private extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private func XCTAssertHistoryThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T
) async {
    do { _ = try await expression(); XCTFail("expected error") } catch { }
}
