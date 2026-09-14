import Foundation

enum RecordingHistoryState: String, Codable, Sendable {
    case recording
    case ready
    case transcribing
    case completed
    case failed
    case interrupted
}

enum TranscriptVersionKind: String, Codable, Equatable, Sendable {
    case raw
    case final
    case retranscribed
}

struct TranscriptVersion: Codable, Equatable, Sendable {
    typealias Kind = TranscriptVersionKind

    let version: Int
    let backend: String
    let language: DictationLanguage
    let createdAt: Date
    let text: String
    let kind: TranscriptVersionKind

    init(
        version: Int = 0,
        backend: String,
        language: DictationLanguage,
        createdAt: Date = .now,
        text: String,
        kind: TranscriptVersionKind = .raw
    ) {
        self.version = version
        self.backend = backend
        self.language = language
        self.createdAt = createdAt
        self.text = text
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case backend
        case language
        case createdAt
        case text
        case kind
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        backend = try container.decode(String.self, forKey: .backend)
        language = try container.decode(DictationLanguage.self, forKey: .language)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        text = try container.decode(String.self, forKey: .text)
        kind = try container.decodeIfPresent(TranscriptVersionKind.self, forKey: .kind) ?? .raw
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(backend, forKey: .backend)
        try container.encode(language, forKey: .language)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(text, forKey: .text)
        try container.encode(kind, forKey: .kind)
    }
}

struct RecordingHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let createdAt: Date
    let language: DictationLanguage
    var state: RecordingHistoryState
    var durationSeconds: Double?
    var transcripts: [TranscriptVersion]
    var hasAudio: Bool
    var audioFormatVersion: Int?

    init(
        schemaVersion: Int = 1,
        id: UUID,
        createdAt: Date,
        language: DictationLanguage,
        state: RecordingHistoryState,
        durationSeconds: Double?,
        transcripts: [TranscriptVersion],
        hasAudio: Bool,
        audioFormatVersion: Int?
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.language = language
        self.state = state
        self.durationSeconds = durationSeconds
        self.transcripts = transcripts
        self.hasAudio = hasAudio
        self.audioFormatVersion = audioFormatVersion
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case createdAt
        case language
        case state
        case durationSeconds
        case transcripts
        case hasAudio
        case audioFormatVersion
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        language = try container.decode(DictationLanguage.self, forKey: .language)
        state = try container.decode(RecordingHistoryState.self, forKey: .state)
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
        transcripts = try container.decode([TranscriptVersion].self, forKey: .transcripts)
        hasAudio = try container.decode(Bool.self, forKey: .hasAudio)
        audioFormatVersion = try container.decodeIfPresent(Int.self, forKey: .audioFormatVersion)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(language, forKey: .language)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try container.encode(transcripts, forKey: .transcripts)
        try container.encode(hasAudio, forKey: .hasAudio)
        try container.encodeIfPresent(audioFormatVersion, forKey: .audioFormatVersion)
    }
}

extension RecordingHistoryEntry {
    var preferredTranscript: TranscriptVersion? {
        transcripts.last(where: { $0.kind != .raw }) ?? transcripts.last
    }
}

enum RecordingHistoryError: Error, Equatable, Sendable {
    case missingRecording
    case missingAudio
    case emptyAudio
    case corruptManifest
    case corruptAudio
    case deletionFailed
    case recordingActive
}

actor RecordingHistoryStore {
    static let audioFormatVersion = 1

    private static let audioMagic = Data("FFL1".utf8)
    private static let checkpointMagic = Data("FFC1".utf8)
    private static let checkpointRecordMarker: UInt32 = 0x314B4843
    private static let checkpointRecordHeaderSize = 4 + 4 + 2 + 2 + 8
    private let rootURL: URL
    private let fileManager: FileManager
    private let writeData: (@Sendable (Data, URL) throws -> Void)?
    private let removeItem: (@Sendable (URL) throws -> Void)?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var corruptManifestDetected = false
    private var missingAudioEntryIDs: Set<UUID> = []
    private var recoveryFailed = false
    private var didCaptureLaunchRecoveryCandidates = false
    private var launchRecoveryCandidateIDs: Set<UUID> = []

    init(
        rootURL: URL,
        fileManager: FileManager = .default,
        removeItem: (@Sendable (URL) throws -> Void)? = nil
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        writeData = nil
        self.removeItem = removeItem
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    init(
        rootURL: URL,
        fileManager: FileManager = .default,
        writeData: @escaping @Sendable (Data, URL) throws -> Void
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.writeData = writeData
        removeItem = nil
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
        let contents = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil
        )
        let manifests = contents.filter { $0.pathExtension == "json" }
        let manifestIDs = Set(manifests.compactMap(managedArtifactID))
        missingAudioEntryIDs.formIntersection(manifestIDs)
        let orphanManagedAssetDetected = contents.contains { url in
            (url.pathExtension == "audio" || url.pathExtension == "checkpoint")
                && managedArtifactID(url).map { !manifestIDs.contains($0) } == true
        }
        var entries: [RecordingHistoryEntry] = []
        var foundCorruptManifest = false
        var foundMissingAudio = false
        for url in manifests {
            do {
                var entry = try decoder.decode(
                    RecordingHistoryEntry.self,
                    from: Data(contentsOf: url)
                )
                if reconcileMissingAudio(in: &entry) {
                    foundMissingAudio = true
                    missingAudioEntryIDs.insert(entry.id)
                    do {
                        try write(entry)
                    } catch {
                        recoveryFailed = true
                    }
                }
                entries.append(entry)
            } catch {
                foundCorruptManifest = true
            }
        }
        corruptManifestDetected = foundCorruptManifest
            || orphanManagedAssetDetected
            || foundMissingAudio
        return entries.sorted { $0.createdAt > $1.createdAt }
    }

    func hasManagedArtifacts() throws -> Bool {
        try ensureRoot()
        return try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil
        ).contains { managedArtifactID($0) != nil }
    }

    func mark(_ id: UUID, state: RecordingHistoryState) throws {
        var entry = try entry(id)
        entry.state = state
        try write(entry)
    }

    func appendCheckpoint(
        _ chunk: RecognitionAudioChunk,
        for id: UUID,
        state: RecordingHistoryState = .recording
    ) throws {
        guard !chunk.samples.isEmpty,
              chunk.sampleRate > 0,
              chunk.sampleRate <= Int(UInt32.max),
              chunk.channelCount > 0,
              chunk.channelCount <= Int(UInt16.max),
              chunk.samples.count <= Int.max / MemoryLayout<UInt32>.size else {
            throw RecordingHistoryError.emptyAudio
        }
        var entry = try entry(id)
        var record = Data(capacity: Self.checkpointRecordHeaderSize + chunk.samples.count * 4)
        append(Self.checkpointRecordMarker, to: &record)
        append(UInt32(chunk.sampleRate), to: &record)
        append(UInt16(chunk.channelCount), to: &record)
        append(UInt16(0), to: &record)
        append(UInt64(chunk.samples.count), to: &record)
        for value in chunk.samples {
            append(value.bitPattern, to: &record)
        }
        try appendCheckpointData(record, for: id)

        entry.hasAudio = true
        entry.audioFormatVersion = Self.audioFormatVersion
        entry.durationSeconds = (entry.durationSeconds ?? 0)
            + Double(chunk.samples.count) / Double(chunk.sampleRate)
        entry.state = state
        try write(entry)
    }

    func discardCheckpoint(for id: UUID) throws {
        let url = checkpointURL(id)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try deleteItem(at: url)
    }

    func saveAudio(
        _ samples: AudioSamples,
        for id: UUID,
        state: RecordingHistoryState = .ready
    ) throws {
        var entry = try entry(id)
        guard !samples.values.isEmpty else {
            throw RecordingHistoryError.emptyAudio
        }
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
        if fileManager.fileExists(atPath: audioURL(id).path) {
            let data: Data
            do {
                data = try Data(contentsOf: audioURL(id))
            } catch {
                throw RecordingHistoryError.missingAudio
            }
            do {
                return try decodeFinalAudio(data)
            } catch {
                if hasUsableCheckpointAsset(for: id) {
                    return try decodeCheckpointAudio(for: id)
                }
                throw error
            }
        }
        return try decodeCheckpointAudio(for: id)
    }

    private func decodeFinalAudio(_ data: Data) throws -> AudioSamples {
        guard data.starts(with: Self.audioMagic) else {
            throw RecordingHistoryError.corruptAudio
        }
        var offset = Self.audioMagic.count
        guard let version = read(UInt16.self, from: data, offset: &offset),
              Int(version) == Self.audioFormatVersion,
              let channels = read(UInt16.self, from: data, offset: &offset),
              channels > 0,
              let sampleRate = read(UInt32.self, from: data, offset: &offset),
              sampleRate > 0,
              let count = read(UInt64.self, from: data, offset: &offset),
              count > 0,
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

    private func decodeCheckpointAudio(for id: UUID) throws -> AudioSamples {
        let data: Data
        do {
            data = try Data(contentsOf: checkpointURL(id))
        } catch {
            throw RecordingHistoryError.missingAudio
        }
        guard data.starts(with: Self.checkpointMagic) else {
            throw RecordingHistoryError.corruptAudio
        }

        var offset = Self.checkpointMagic.count
        var values: [Float] = []
        var sampleRate: Int?
        var channelCount: Int?
        while offset < data.count {
            guard data.count - offset >= Self.checkpointRecordHeaderSize else {
                break
            }
            guard let marker = read(UInt32.self, from: data, offset: &offset),
                  marker == Self.checkpointRecordMarker,
                  let rawSampleRate = read(UInt32.self, from: data, offset: &offset),
                  rawSampleRate > 0,
                  let rawChannelCount = read(UInt16.self, from: data, offset: &offset),
                  rawChannelCount > 0,
                  read(UInt16.self, from: data, offset: &offset) != nil,
                  let rawCount = read(UInt64.self, from: data, offset: &offset),
                  rawCount > 0,
                  rawCount <= UInt64(Int.max) else {
                throw RecordingHistoryError.corruptAudio
            }
            let count = Int(rawCount)
            let byteCount = count.multipliedReportingOverflow(by: MemoryLayout<UInt32>.size)
            guard !byteCount.overflow,
                  byteCount.partialValue <= data.count - offset else {
                // A process crash can leave a partial final record. Keep the
                // complete prefix and let the terminal path persist it.
                break
            }
            let currentSampleRate = Int(rawSampleRate)
            let currentChannelCount = Int(rawChannelCount)
            if sampleRate == nil {
                sampleRate = currentSampleRate
                channelCount = currentChannelCount
            }
            for _ in 0..<count {
                guard let bits = read(UInt32.self, from: data, offset: &offset) else {
                    throw RecordingHistoryError.corruptAudio
                }
                values.append(Float(bitPattern: bits))
            }
        }
        guard let sampleRate, let channelCount, !values.isEmpty else {
            throw RecordingHistoryError.missingAudio
        }
        return AudioSamples(
            values: values,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
    }

    func appendTranscript(
        _ transcript: TranscriptVersion,
        to id: UUID,
        state: RecordingHistoryState? = nil
    ) throws {
        var entry = try entry(id)
        entry.transcripts.append(
            TranscriptVersion(
                version: entry.transcripts.count + 1,
                backend: transcript.backend,
                language: transcript.language,
                createdAt: transcript.createdAt,
                text: transcript.text,
                kind: transcript.kind
            )
        )
        if let state {
            entry.state = state
        } else if transcript.kind != .raw || entry.state != .transcribing {
            entry.state = .completed
        }
        try write(entry)
    }

    func beginRetranscription(_ id: UUID) throws -> RecordingHistoryEntry {
        var entry = try entry(id)
        guard entry.state != .recording, entry.state != .transcribing else {
            throw RecordingHistoryError.recordingActive
        }
        guard entry.hasAudio, hasUsableAudioAsset(for: id) else {
            if reconcileMissingAudio(in: &entry) {
                missingAudioEntryIDs.insert(entry.id)
                do {
                    try write(entry)
                } catch {
                    recoveryFailed = true
                }
            }
            throw RecordingHistoryError.missingAudio
        }
        launchRecoveryCandidateIDs.remove(id)
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
            _ = reconcileAvailableAudio(in: &entry)
            if entry.state == .recording || entry.state == .transcribing {
                entry.state = .interrupted
                recovered.append(entry)
            }
            try write(entry)
        }
        return recovered
    }

    func recoverAtLaunch() {
        guard !didCaptureLaunchRecoveryCandidates else {
            retryLaunchRecovery()
            return
        }
        do {
            launchRecoveryCandidateIDs = Set(
                try list()
                    .filter { $0.state == .recording || $0.state == .transcribing }
                    .map(\.id)
            )
            didCaptureLaunchRecoveryCandidates = true
            retryLaunchRecovery()
        } catch {
            recoveryFailed = true
        }
    }

    func retryLaunchRecovery() {
        guard didCaptureLaunchRecoveryCandidates else { return }
        var failed = false
        for id in Array(launchRecoveryCandidateIDs) {
            do {
                var candidate = try entry(id)
                guard candidate.state == .recording || candidate.state == .transcribing else {
                    launchRecoveryCandidateIDs.remove(id)
                    continue
                }
                _ = reconcileMissingAudio(in: &candidate)
                _ = reconcileAvailableAudio(in: &candidate)
                candidate.state = .interrupted
                try write(candidate)
                launchRecoveryCandidateIDs.remove(id)
            } catch RecordingHistoryError.missingRecording {
                launchRecoveryCandidateIDs.remove(id)
            } catch {
                failed = true
            }
        }
        recoveryFailed = failed
    }

    func hasRecoveryWarning() -> Bool {
        recoveryFailed || corruptManifestDetected || !missingAudioEntryIDs.isEmpty
    }

    func delete(_ id: UUID) throws {
        let urls = [audioURL(id), checkpointURL(id), manifestURL(id)]
        guard urls.contains(where: { fileManager.fileExists(atPath: $0.path) }) else {
            throw RecordingHistoryError.missingRecording
        }
        if let current = try? entry(id),
           current.state == .recording || current.state == .transcribing {
            throw RecordingHistoryError.recordingActive
        }
        if deleteManagedArtifacts(for: id) {
            throw RecordingHistoryError.deletionFailed
        }
        missingAudioEntryIDs.remove(id)
    }

    func discardActive(_ id: UUID) throws {
        let urls = [audioURL(id), checkpointURL(id), manifestURL(id)]
        guard urls.contains(where: { fileManager.fileExists(atPath: $0.path) }) else {
            return
        }
        if deleteManagedArtifacts(for: id) {
            throw RecordingHistoryError.deletionFailed
        }
        missingAudioEntryIDs.remove(id)
    }

    func interruptOrDiscardEmpty(_ id: UUID) throws {
        let current = try entry(id)
        if current.hasAudio {
            try mark(id, state: .interrupted)
        } else {
            try discardActive(id)
        }
    }

    private func deleteManagedArtifacts(for id: UUID) -> Bool {
        var failed = false
        for url in [audioURL(id), checkpointURL(id)] {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try deleteItem(at: url)
            } catch {
                failed = true
            }
        }
        guard !failed,
              !fileManager.fileExists(atPath: audioURL(id).path),
              !fileManager.fileExists(atPath: checkpointURL(id).path) else {
            return true
        }
        let manifest = manifestURL(id)
        if fileManager.fileExists(atPath: manifest.path) {
            do {
                try deleteItem(at: manifest)
            } catch {
                failed = true
            }
        }
        if !fileManager.fileExists(atPath: manifest.path) {
            missingAudioEntryIDs.remove(id)
        }
        return failed
    }

    private func deleteItem(at url: URL) throws {
        if let removeItem {
            try removeItem(url)
        } else {
            try fileManager.removeItem(at: url)
        }
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
        let managedIDs = Set(contents.compactMap(managedArtifactID))
        var failed = false
        for id in managedIDs {
            failed = deleteManagedArtifacts(for: id) || failed
        }
        if failed { throw RecordingHistoryError.deletionFailed }
    }

    private func managedArtifactID(_ url: URL) -> UUID? {
        guard url.pathExtension == "json"
                || url.pathExtension == "audio"
                || url.pathExtension == "checkpoint" else {
            return nil
        }
        return UUID(uuidString: url.deletingPathExtension().lastPathComponent)
    }

    private func reconcileMissingAudio(in entry: inout RecordingHistoryEntry) -> Bool {
        guard entry.hasAudio,
              !hasUsableAudioAsset(for: entry.id) else {
            return false
        }
        entry.hasAudio = false
        entry.audioFormatVersion = nil
        entry.durationSeconds = nil
        return true
    }

    private func reconcileAvailableAudio(in entry: inout RecordingHistoryEntry) -> Bool {
        guard !entry.hasAudio,
              hasUsableAudioAsset(for: entry.id),
              let samples = try? loadAudio(for: entry.id) else {
            return false
        }
        entry.hasAudio = true
        entry.audioFormatVersion = Self.audioFormatVersion
        entry.durationSeconds = samples.timing.originalDurationSeconds
        missingAudioEntryIDs.remove(entry.id)
        return true
    }

    private func hasUsableAudioAsset(for id: UUID) -> Bool {
        hasUsableFinalAudioAsset(for: id) || hasUsableCheckpointAsset(for: id)
    }

    private func hasUsableFinalAudioAsset(for id: UUID) -> Bool {
        let url = audioURL(id)
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let fileSize = (attributes[.size] as? NSNumber)?.uint64Value,
              fileSize >= 20,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 20),
              header.count == 20,
              header.starts(with: Self.audioMagic) else {
            return false
        }
        var offset = Self.audioMagic.count
        guard let version = read(UInt16.self, from: header, offset: &offset),
              Int(version) == Self.audioFormatVersion,
              let channels = read(UInt16.self, from: header, offset: &offset),
              channels > 0,
              let sampleRate = read(UInt32.self, from: header, offset: &offset),
              sampleRate > 0,
              let count = read(UInt64.self, from: header, offset: &offset),
              count > 0,
              count <= (UInt64.max - UInt64(header.count)) / UInt64(MemoryLayout<UInt32>.size) else {
            return false
        }
        let expectedSize = UInt64(header.count)
            + count * UInt64(MemoryLayout<UInt32>.size)
        return fileSize == expectedSize
    }

    private func hasUsableCheckpointAsset(for id: UUID) -> Bool {
        let url = checkpointURL(id)
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let fileSize = (attributes[.size] as? NSNumber)?.uint64Value,
              fileSize >= UInt64(Self.checkpointMagic.count + Self.checkpointRecordHeaderSize + 4),
              let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        guard let header = try? handle.read(
            upToCount: Self.checkpointMagic.count + Self.checkpointRecordHeaderSize
        ),
              header.count == Self.checkpointMagic.count + Self.checkpointRecordHeaderSize,
              header.starts(with: Self.checkpointMagic) else {
            return false
        }
        var offset = Self.checkpointMagic.count
        guard let marker = read(UInt32.self, from: header, offset: &offset),
              marker == Self.checkpointRecordMarker,
              let sampleRate = read(UInt32.self, from: header, offset: &offset),
              sampleRate > 0,
              let channels = read(UInt16.self, from: header, offset: &offset),
              channels > 0,
              read(UInt16.self, from: header, offset: &offset) != nil,
              let count = read(UInt64.self, from: header, offset: &offset),
              count > 0,
              count <= UInt64(Int.max / MemoryLayout<UInt32>.size) else {
            return false
        }
        let payloadBytes = count * UInt64(MemoryLayout<UInt32>.size)
        return payloadBytes <= fileSize - UInt64(header.count)
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

    private func checkpointURL(_ id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString).appendingPathExtension("checkpoint")
    }

    private func appendCheckpointData(_ record: Data, for id: UUID) throws {
        try ensureRoot()
        let url = checkpointURL(id)
        guard !fileManager.fileExists(atPath: url.path) else {
            if writeData != nil {
                let existing = try Data(contentsOf: url)
                guard existing.starts(with: Self.checkpointMagic) else {
                    throw RecordingHistoryError.corruptAudio
                }
                try atomicWrite(existing + record, to: url)
                return
            }

            let headerHandle = try FileHandle(forReadingFrom: url)
            let header = try headerHandle.read(upToCount: Self.checkpointMagic.count)
            try headerHandle.close()
            guard header == Self.checkpointMagic else {
                throw RecordingHistoryError.corruptAudio
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: record)
            handle.synchronizeFile()
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            return
        }
        try atomicWrite(Self.checkpointMagic + record, to: url)
    }

    private func write(_ entry: RecordingHistoryEntry) throws {
        try atomicWrite(encoder.encode(entry), to: manifestURL(entry.id))
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        try ensureRoot()
        if let writeData {
            try writeData(data, url)
        } else {
            try data.write(to: url, options: .atomic)
        }
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
    func persistFinalTranscript(_ text: String, sessionID: DictationSessionID) async throws
    func complete(sessionID: DictationSessionID) async throws
    func markFailed(sessionID: DictationSessionID) async throws
    func interrupt(sessionID: DictationSessionID) async throws
    func releaseTracking(sessionID: DictationSessionID) async
}

extension RecordingHistoryRecording {
    func persistFinalTranscript(_ text: String, sessionID: DictationSessionID) async throws {}
    func complete(sessionID: DictationSessionID) async throws {}
    func releaseTracking(sessionID: DictationSessionID) async {}
}

actor RecordingHistoryRecorder: RecordingHistoryRecording {
    private let store: RecordingHistoryStore
    private let sampleAccess: any AudioSampleAccessing
    private var entries: [DictationSessionID: UUID] = [:]
    private var pendingFinalSamples: [DictationSessionID: AudioSamples] = [:]
    private var transcriptMetadata: [
        DictationSessionID: (backend: String, language: DictationLanguage)
    ] = [:]
    private var beginningSessions: Set<DictationSessionID> = []
    private var invalidatedBeginningSessions: Set<DictationSessionID> = []

    init(store: RecordingHistoryStore, sampleAccess: any AudioSampleAccessing) {
        self.store = store
        self.sampleAccess = sampleAccess
    }

    func begin(sessionID: DictationSessionID, language: DictationLanguage) async throws {
        beginningSessions.insert(sessionID)
        let entry: RecordingHistoryEntry
        do {
            entry = try await store.create(language: language)
        } catch {
            beginningSessions.remove(sessionID)
            invalidatedBeginningSessions.remove(sessionID)
            throw error
        }
        beginningSessions.remove(sessionID)
        if invalidatedBeginningSessions.remove(sessionID) != nil {
            try await store.discardActive(entry.id)
            return
        }
        entries[sessionID] = entry.id
        pendingFinalSamples[sessionID] = nil
        transcriptMetadata[sessionID] = (backend: "unknown", language: language)
    }

    func persistCheckpoint(
        _ chunk: RecognitionAudioChunk,
        sessionID: DictationSessionID
    ) async throws {
        guard let id = entries[sessionID], !chunk.samples.isEmpty else { return }
        try await store.appendCheckpoint(chunk, for: id, state: .recording)
        guard entries[sessionID] == id else { throw RecordingHistoryError.missingRecording }
    }

    func persistAudio(_ input: AudioInput, sessionID: DictationSessionID) async throws {
        guard let id = entries[sessionID] else {
            throw RecordingHistoryError.missingRecording
        }
        let samples = try await sampleAccess.samples(for: input)
        guard entries[sessionID] == id else { throw RecordingHistoryError.missingRecording }
        guard !samples.values.isEmpty else {
            if let recovered = try? await store.loadAudio(for: id) {
                guard entries[sessionID] == id else {
                    throw RecordingHistoryError.missingRecording
                }
                pendingFinalSamples[sessionID] = recovered
                try await store.saveAudio(recovered, for: id, state: .transcribing)
                guard entries[sessionID] == id else {
                    throw RecordingHistoryError.missingRecording
                }
                try await store.discardCheckpoint(for: id)
                guard entries[sessionID] == id else {
                    throw RecordingHistoryError.missingRecording
                }
                clearBufferedAudio(for: sessionID)
                return
            }
            try await store.discardActive(id)
            clearSession(for: sessionID)
            return
        }
        pendingFinalSamples[sessionID] = samples
        try await store.saveAudio(samples, for: id, state: .transcribing)
        guard entries[sessionID] == id else { throw RecordingHistoryError.missingRecording }
        try await store.discardCheckpoint(for: id)
        guard entries[sessionID] == id else { throw RecordingHistoryError.missingRecording }
        clearBufferedAudio(for: sessionID)
    }

    func persistTranscript(_ transcript: RawTranscript, sessionID: DictationSessionID) async throws {
        guard let id = entries[sessionID] else {
            throw RecordingHistoryError.missingRecording
        }
        transcriptMetadata[sessionID] = (
            backend: transcript.backend?.rawValue ?? "unknown",
            language: transcript.language
        )
        try await store.appendTranscript(
            TranscriptVersion(
                backend: transcript.backend?.rawValue ?? "unknown",
                language: transcript.language,
                text: transcript.text,
                kind: .raw
            ),
            to: id,
            state: .transcribing
        )
        guard entries[sessionID] == id else { throw RecordingHistoryError.missingRecording }
    }

    func persistFinalTranscript(_ text: String, sessionID: DictationSessionID) async throws {
        guard let id = entries[sessionID] else {
            throw RecordingHistoryError.missingRecording
        }
        let metadata = transcriptMetadata[sessionID]
            ?? (backend: "unknown", language: .automatic)
        try await store.appendTranscript(
            TranscriptVersion(
                backend: metadata.backend,
                language: metadata.language,
                text: text,
                kind: .final
            ),
            to: id,
            state: .transcribing
        )
        guard entries[sessionID] == id else { throw RecordingHistoryError.missingRecording }
    }

    func complete(sessionID: DictationSessionID) async throws {
        if beginningSessions.contains(sessionID) {
            invalidatedBeginningSessions.insert(sessionID)
            return
        }
        guard let id = entries[sessionID] else { return }
        defer { clearSession(for: sessionID) }
        try await store.mark(id, state: .completed)
        guard entries[sessionID] == id else { throw RecordingHistoryError.missingRecording }
        try await store.discardCheckpoint(for: id)
    }

    func releaseTracking(sessionID: DictationSessionID) async {
        if beginningSessions.contains(sessionID) {
            invalidatedBeginningSessions.insert(sessionID)
            return
        }
        invalidatedBeginningSessions.remove(sessionID)
        clearSession(for: sessionID)
    }

    func markFailed(sessionID: DictationSessionID) async throws {
        if beginningSessions.contains(sessionID) {
            invalidatedBeginningSessions.insert(sessionID)
            return
        }
        guard let id = entries[sessionID] else { return }
        if let samples = pendingFinalSamples[sessionID] {
            try await store.saveAudio(samples, for: id, state: .failed)
        } else if let samples = try? await store.loadAudio(for: id) {
            guard entries[sessionID] == id else {
                throw RecordingHistoryError.missingRecording
            }
            try await store.saveAudio(samples, for: id, state: .failed)
        } else {
            try await store.mark(id, state: .failed)
        }
        guard entries[sessionID] == id else { throw RecordingHistoryError.missingRecording }
        try await store.discardCheckpoint(for: id)
        guard entries[sessionID] == id else { throw RecordingHistoryError.missingRecording }
        clearSession(for: sessionID)
    }

    func interrupt(sessionID: DictationSessionID) async throws {
        if beginningSessions.contains(sessionID) {
            invalidatedBeginningSessions.insert(sessionID)
            return
        }
        guard let id = entries[sessionID] else { return }
        if let samples = pendingFinalSamples[sessionID] {
            try await store.saveAudio(samples, for: id, state: .interrupted)
        } else if let samples = try? await store.loadAudio(for: id) {
            guard entries[sessionID] == id else {
                throw RecordingHistoryError.missingRecording
            }
            try await store.saveAudio(samples, for: id, state: .interrupted)
        } else {
            try await store.interruptOrDiscardEmpty(id)
        }
        guard entries[sessionID] == id else { throw RecordingHistoryError.missingRecording }
        try await store.discardCheckpoint(for: id)
        guard entries[sessionID] == id else { throw RecordingHistoryError.missingRecording }
        clearSession(for: sessionID)
    }

    private func clearBufferedAudio(for sessionID: DictationSessionID) {
        pendingFinalSamples[sessionID] = nil
    }

    private func clearSession(for sessionID: DictationSessionID) {
        entries[sessionID] = nil
        transcriptMetadata[sessionID] = nil
        clearBufferedAudio(for: sessionID)
    }
}
