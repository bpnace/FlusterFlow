import Foundation
import XCTest
@testable import WhisperFlow

final class RecordingHistoryStoreTests: XCTestCase {
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

    func testRecorderPersistsFiveSecondCrashCheckpoint() async throws {
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
            RecognitionAudioChunk(samples: Array(repeating: 0.1, count: 80_000)),
            sessionID: sessionID
        )

        let entries = try await store.list()
        XCTAssertEqual(entries.first?.state, .recording)
        XCTAssertEqual(entries.first?.hasAudio, true)
        let duration = try XCTUnwrap(entries.first?.durationSeconds)
        XCTAssertEqual(duration, 5, accuracy: 0.001)
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
        await XCTAssertThrowsErrorAsync(try await store.loadAudio(for: recording.id))
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

    func testActiveRecordingCannotBeDeletedOrRetranscribed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingHistoryStore(rootURL: root)
        let active = try await store.create(language: .german)

        await XCTAssertThrowsErrorAsync(try await store.delete(active.id))
        await XCTAssertThrowsErrorAsync(try await store.deleteAll())
        await XCTAssertThrowsErrorAsync(try await store.beginRetranscription(active.id))

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

    func testRecorderCancellationDiscardsItsActiveEntry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingHistoryStore(rootURL: root)
        let recorder = RecordingHistoryRecorder(
            store: store,
            sampleAccess: AudioBufferStore()
        )
        let sessionID = DictationSessionID(rawValue: 99)
        try await recorder.begin(sessionID: sessionID, language: .automatic)

        await recorder.discard(sessionID: sessionID)

        let entries = try await store.list()
        XCTAssertTrue(entries.isEmpty)
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
        await XCTAssertThrowsErrorAsync(
            try await recorder.persistAudio(input, sessionID: sessionID)
        )

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )
        await recorder.markFailed(sessionID: sessionID)

        let entries = try await store.list()
        let entry = try XCTUnwrap(entries.first)
        let recovered = try await store.loadAudio(for: entry.id)
        XCTAssertEqual(entry.state, .failed)
        XCTAssertEqual(recovered, samples)
    }

    private func permissions(at url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue
    }
}

private extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T) async {
    do { _ = try await expression(); XCTFail("expected error") } catch { }
}
