import Foundation

enum RecordingHistoryState: String, Codable, Sendable {
    case recording
    case ready
    case transcribing
    case completed
    case failed
    case interrupted
}

struct TranscriptVersion: Codable, Equatable, Sendable {
    let version: Int
    let backend: String
    let language: DictationLanguage
    let createdAt: Date
    let text: String

    init(
        version: Int = 0,
        backend: String,
        language: DictationLanguage,
        createdAt: Date = .now,
        text: String
    ) {
        self.version = version
        self.backend = backend
        self.language = language
        self.createdAt = createdAt
        self.text = text
    }
}

struct RecordingHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let language: DictationLanguage
    var state: RecordingHistoryState
    var durationSeconds: Double?
    var transcripts: [TranscriptVersion]
    var hasAudio: Bool
    var audioFormatVersion: Int?
}

enum RecordingHistoryError: Error, Equatable, Sendable {
    case missingRecording
    case missingAudio
    case corruptManifest
    case corruptAudio
    case deletionFailed
    case recordingActive
}

actor RecordingHistoryStore {
    static let audioFormatVersion = 1

    private static let audioMagic = Data("FFL1".utf8)
    private let rootURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var corruptManifestDetected = false
    private var recoveryFailed = false

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func create(
        language: DictationLanguage,
        state: RecordingHistoryState = .recording,
        createdAt: Date = .now
    ) throws -> RecordingHistoryEntry {
        try ensureRoot()
        let entry = RecordingHistoryEntry(
            id: UUID(),
            createdAt: createdAt,
            language: language,
            state: state,
            durationSeconds: nil,
            transcripts: [],
            hasAudio: false,
            audioFormatVersion: nil
        )
        try write(entry)
        return entry
    }

    func list() throws -> [RecordingHistoryEntry] {
        try ensureRoot()
        let manifests = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        var entries: [RecordingHistoryEntry] = []
        var foundCorruptManifest = false
        for url in manifests {
            do {
                entries.append(try decoder.decode(
                    RecordingHistoryEntry.self,
                    from: Data(contentsOf: url)
                ))
            } catch {
                foundCorruptManifest = true
            }
        }
        corruptManifestDetected = foundCorruptManifest
        return entries.sorted { $0.createdAt > $1.createdAt }
    }

    func mark(_ id: UUID, state: RecordingHistoryState) throws {
        var entry = try entry(id)
        entry.state = state
        try write(entry)
    }

    func saveAudio(
        _ samples: AudioSamples,
        for id: UUID,
        state: RecordingHistoryState = .ready
    ) throws {
        var entry = try entry(id)
        var data = Self.audioMagic
        append(UInt16(Self.audioFormatVersion), to: &data)
        append(UInt16(samples.channelCount), to: &data)
        append(UInt32(samples.sampleRate), to: &data)
        append(UInt64(samples.values.count), to: &data)
        for value in samples.values {
            append(value.bitPattern, to: &data)
        }
        try atomicWrite(data, to: audioURL(id))
        entry.hasAudio = true
        entry.audioFormatVersion = Self.audioFormatVersion
        entry.durationSeconds = samples.timing.originalDurationSeconds
        entry.state = state
        try write(entry)
    }

    func loadAudio(for id: UUID) throws -> AudioSamples {
        _ = try entry(id)
        let data: Data
        do {
            data = try Data(contentsOf: audioURL(id))
        } catch {
            throw RecordingHistoryError.missingAudio
        }
        guard data.starts(with: Self.audioMagic) else {
            throw RecordingHistoryError.corruptAudio
        }
        var offset = Self.audioMagic.count
        guard let version = read(UInt16.self, from: data, offset: &offset),
              Int(version) == Self.audioFormatVersion,
              let channels = read(UInt16.self, from: data, offset: &offset),
              let sampleRate = read(UInt32.self, from: data, offset: &offset),
              let count = read(UInt64.self, from: data, offset: &offset),
              count <= UInt64(Int.max),
              count <= UInt64((data.count - offset) / MemoryLayout<UInt32>.size) else {
            throw RecordingHistoryError.corruptAudio
        }
        var values: [Float] = []
        values.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let bits = read(UInt32.self, from: data, offset: &offset) else {
                throw RecordingHistoryError.corruptAudio
            }
            values.append(Float(bitPattern: bits))
        }
        guard offset == data.count else { throw RecordingHistoryError.corruptAudio }
        return AudioSamples(
            values: values,
            sampleRate: Int(sampleRate),
            channelCount: Int(channels)
        )
    }

    func appendTranscript(_ transcript: TranscriptVersion, to id: UUID) throws {
        var entry = try entry(id)
        entry.transcripts.append(
            TranscriptVersion(
                version: entry.transcripts.count + 1,
                backend: transcript.backend,
                language: transcript.language,
                createdAt: transcript.createdAt,
                text: transcript.text
            )
        )
        entry.state = .completed
        try write(entry)
    }

    func beginRetranscription(_ id: UUID) throws -> RecordingHistoryEntry {
        var entry = try entry(id)
        guard entry.state != .recording, entry.state != .transcribing else {
            throw RecordingHistoryError.recordingActive
        }
        guard entry.hasAudio else { throw RecordingHistoryError.missingAudio }
        entry.state = .transcribing
        try write(entry)
        return entry
    }

    func versions(for id: UUID) throws -> [TranscriptVersion] {
        try entry(id).transcripts
    }

    @discardableResult
    func recover() throws -> [RecordingHistoryEntry] {
        var recovered: [RecordingHistoryEntry] = []
        for var entry in try list() {
            if !entry.hasAudio,
               fileManager.fileExists(atPath: audioURL(entry.id).path),
               let samples = try? loadAudio(for: entry.id) {
                entry.hasAudio = true
                entry.audioFormatVersion = Self.audioFormatVersion
                entry.durationSeconds = samples.timing.originalDurationSeconds
            }
            if entry.state == .recording || entry.state == .transcribing {
                entry.state = .interrupted
                recovered.append(entry)
            }
            try write(entry)
        }
        return recovered
    }

    func recoverAtLaunch() {
        do {
            _ = try recover()
        } catch {
            recoveryFailed = true
        }
    }

    func hasRecoveryWarning() -> Bool {
        recoveryFailed || corruptManifestDetected
    }

    func delete(_ id: UUID) throws {
        let urls = [audioURL(id), manifestURL(id)]
        guard urls.contains(where: { fileManager.fileExists(atPath: $0.path) }) else {
            throw RecordingHistoryError.missingRecording
        }
        if let current = try? entry(id),
           current.state == .recording || current.state == .transcribing {
            throw RecordingHistoryError.recordingActive
        }
        try deleteFiles(at: urls)
    }

    func discardActive(_ id: UUID) throws {
        let urls = [audioURL(id), manifestURL(id)]
        guard urls.contains(where: { fileManager.fileExists(atPath: $0.path) }) else {
            return
        }
        try deleteFiles(at: urls)
    }

    private func deleteFiles(at urls: [URL]) throws {
        var failed = false
        for url in urls where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                failed = true
            }
        }
        if failed { throw RecordingHistoryError.deletionFailed }
    }

    func deleteAll() throws {
        try ensureRoot()
        let contents = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil
        )
        for manifest in contents where manifest.pathExtension == "json" {
            guard UUID(uuidString: manifest.deletingPathExtension().lastPathComponent) != nil,
                  let data = try? Data(contentsOf: manifest),
                  let current = try? decoder.decode(RecordingHistoryEntry.self, from: data) else {
                continue
            }
            if current.state == .recording || current.state == .transcribing {
                throw RecordingHistoryError.recordingActive
            }
        }
        let managedFiles = contents.filter { url in
            guard url.pathExtension == "json" || url.pathExtension == "audio" else {
                return false
            }
            return UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
        }
        var failed = false
        for url in managedFiles {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                failed = true
            }
        }
        if failed { throw RecordingHistoryError.deletionFailed }
    }

    private func entry(_ id: UUID) throws -> RecordingHistoryEntry {
        let url = manifestURL(id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw RecordingHistoryError.missingRecording
        }
        do {
            return try decoder.decode(
                RecordingHistoryEntry.self,
                from: Data(contentsOf: url)
            )
        } catch {
            throw RecordingHistoryError.corruptManifest
        }
    }

    private func ensureRoot() throws {
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func manifestURL(_ id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private func audioURL(_ id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString).appendingPathExtension("audio")
    }

    private func write(_ entry: RecordingHistoryEntry) throws {
        try atomicWrite(encoder.encode(entry), to: manifestURL(entry.id))
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        try ensureRoot()
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private func read<T: FixedWidthInteger>(
        _ type: T.Type,
        from data: Data,
        offset: inout Int
    ) -> T? {
        let byteCount = MemoryLayout<T>.size
        guard offset + byteCount <= data.count else { return nil }
        let value = data[offset..<(offset + byteCount)].withUnsafeBytes {
            $0.loadUnaligned(as: T.self)
        }
        offset += byteCount
        return T(littleEndian: value)
    }
}

protocol RecordingHistoryRecording: Sendable {
    func begin(sessionID: DictationSessionID, language: DictationLanguage) async throws
    func persistCheckpoint(_ chunk: RecognitionAudioChunk, sessionID: DictationSessionID) async throws
    func persistAudio(_ input: AudioInput, sessionID: DictationSessionID) async throws
    func persistTranscript(_ transcript: RawTranscript, sessionID: DictationSessionID) async throws
    func markFailed(sessionID: DictationSessionID) async
    func discard(sessionID: DictationSessionID) async
}

actor RecordingHistoryRecorder: RecordingHistoryRecording {
    private let store: RecordingHistoryStore
    private let sampleAccess: any AudioSampleAccessing
    private var entries: [DictationSessionID: UUID] = [:]
    private var checkpointSamples: [DictationSessionID: [Float]] = [:]
    private var lastCheckpointFrameCounts: [DictationSessionID: Int] = [:]
    private var checkpointFormats: [DictationSessionID: (sampleRate: Int, channelCount: Int)] = [:]
    private var pendingFinalSamples: [DictationSessionID: AudioSamples] = [:]

    init(store: RecordingHistoryStore, sampleAccess: any AudioSampleAccessing) {
        self.store = store
        self.sampleAccess = sampleAccess
    }

    func begin(sessionID: DictationSessionID, language: DictationLanguage) async throws {
        let entry = try await store.create(language: language)
        entries[sessionID] = entry.id
        checkpointSamples[sessionID] = []
        lastCheckpointFrameCounts[sessionID] = 0
        checkpointFormats[sessionID] = nil
        pendingFinalSamples[sessionID] = nil
    }

    func persistCheckpoint(
        _ chunk: RecognitionAudioChunk,
        sessionID: DictationSessionID
    ) async throws {
        guard let id = entries[sessionID], !chunk.samples.isEmpty else { return }
        checkpointSamples[sessionID, default: []].append(contentsOf: chunk.samples)
        checkpointFormats[sessionID] = (chunk.sampleRate, chunk.channelCount)
        guard let samples = checkpointSamples[sessionID],
              samples.count - lastCheckpointFrameCounts[sessionID, default: 0]
                >= chunk.sampleRate * 5 else { return }
        try await store.saveAudio(
            AudioSamples(
                values: samples,
                sampleRate: chunk.sampleRate,
                channelCount: chunk.channelCount
            ),
            for: id,
            state: .recording
        )
        lastCheckpointFrameCounts[sessionID] = samples.count
    }

    func persistAudio(_ input: AudioInput, sessionID: DictationSessionID) async throws {
        guard let id = entries[sessionID] else {
            throw RecordingHistoryError.missingRecording
        }
        let samples = try await sampleAccess.samples(for: input)
        pendingFinalSamples[sessionID] = samples
        try await store.saveAudio(samples, for: id, state: .transcribing)
        clearBufferedAudio(for: sessionID)
    }

    func persistTranscript(_ transcript: RawTranscript, sessionID: DictationSessionID) async throws {
        guard let id = entries[sessionID] else {
            throw RecordingHistoryError.missingRecording
        }
        do {
            try await store.appendTranscript(
                TranscriptVersion(
                    backend: transcript.backend?.rawValue ?? "unknown",
                    language: transcript.language,
                    text: transcript.text
                ),
                to: id
            )
            entries[sessionID] = nil
            clearBufferedAudio(for: sessionID)
        } catch {
            try? await store.mark(id, state: .failed)
            throw error
        }
    }

    func markFailed(sessionID: DictationSessionID) async {
        guard let id = entries[sessionID] else { return }
        do {
            if let samples = pendingFinalSamples[sessionID] {
                try await store.saveAudio(samples, for: id, state: .failed)
            } else if let samples = checkpointSamples[sessionID],
                      !samples.isEmpty,
                      let format = checkpointFormats[sessionID] {
                try await store.saveAudio(
                    AudioSamples(
                        values: samples,
                        sampleRate: format.sampleRate,
                        channelCount: format.channelCount
                    ),
                    for: id,
                    state: .failed
                )
            } else {
                try await store.mark(id, state: .failed)
            }
            entries[sessionID] = nil
            clearBufferedAudio(for: sessionID)
        } catch { }
    }

    func discard(sessionID: DictationSessionID) async {
        guard let id = entries[sessionID] else { return }
        do {
            try await store.discardActive(id)
            entries[sessionID] = nil
            clearBufferedAudio(for: sessionID)
        } catch { }
    }

    private func clearBufferedAudio(for sessionID: DictationSessionID) {
        checkpointSamples[sessionID] = nil
        lastCheckpointFrameCounts[sessionID] = nil
        checkpointFormats[sessionID] = nil
        pendingFinalSamples[sessionID] = nil
    }
}
