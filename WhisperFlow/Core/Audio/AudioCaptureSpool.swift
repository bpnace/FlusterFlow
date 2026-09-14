@preconcurrency import AVFoundation
import Darwin
import Foundation
import Synchronization

enum AudioCaptureSpoolError: Error, Equatable, Sendable {
    case invalidConfiguration
    case formatChanged
    case cannotCreateFile
    case writeFailed
    case readFailed
    case corruptFile
    case queueOverflow
}

/// A single-producer/single-consumer queue for the audio tap.
///
/// The queue owns all of its storage before the tap is installed. `append` only
/// validates the buffer, selects a channel, and copies into that fixed storage;
/// it never waits for the consumer or allocates. If the consumer cannot keep up,
/// the queue fails closed and the capture reports the loss instead of silently
/// dropping a prefix or suffix.
final class RealtimeAudioFrameQueue: @unchecked Sendable {
    enum AppendResult: Equatable, Sendable {
        case accepted
        case sealed
        case formatChanged
        case unsupportedBuffer
        case overflow
    }

    enum Failure: Int, Equatable, Sendable {
        case formatChanged = 1
        case unsupportedBuffer = 2
        case overflow = 3
        case storageFailed = 4
    }

    static let maximumSupportedSampleRate: Double = 192_000
    static let maximumSupportedChannelCount = 32
    static let maximumChannelSelectionSamples = 64
    static let defaultCapacitySeconds: TimeInterval = 2

    let sampleRate: Double
    let channelCount: Int
    let capacityFrames: Int

    private let storage: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    private let acceptingWrites = Atomic<Bool>(true)
    private let activeProducerCount = Atomic<Int>(0)
    private let failureCode = Atomic<Int>(0)
    private let dataAvailable = DispatchSemaphore(value: 0)

    init?(
        sampleRate: Double,
        channelCount: Int,
        capacitySeconds: TimeInterval = RealtimeAudioFrameQueue.defaultCapacitySeconds
    ) {
        guard sampleRate.isFinite,
              sampleRate > 0,
              sampleRate <= Self.maximumSupportedSampleRate,
              channelCount > 0,
              channelCount <= Self.maximumSupportedChannelCount,
              capacitySeconds.isFinite,
              capacitySeconds > 0 else {
            return nil
        }
        let frameCapacity = (sampleRate * capacitySeconds).rounded(.up)
        guard frameCapacity >= 1,
              frameCapacity <= Double(Int.max) else {
            return nil
        }

        self.sampleRate = sampleRate
        self.channelCount = channelCount
        capacityFrames = Int(frameCapacity)
        storage = UnsafeMutablePointer<Float>.allocate(capacity: capacityFrames)
        storage.initialize(repeating: 0, count: capacityFrames)
    }

    deinit {
        storage.deinitialize(count: capacityFrames)
        storage.deallocate()
    }

    var failure: Failure? {
        Failure(rawValue: failureCode.load(ordering: .acquiring))
    }

    var isSealed: Bool {
        !acceptingWrites.load(ordering: .acquiring)
    }

    var hasActiveProducer: Bool {
        activeProducerCount.load(ordering: .acquiring) != 0
    }

    var bufferedFrameCount: Int {
        let write = writeIndex.load(ordering: .acquiring)
        let read = readIndex.load(ordering: .acquiring)
        return max(0, write - read)
    }

    @inline(__always)
    func append(_ buffer: AVAudioPCMBuffer) -> AppendResult {
        guard acceptingWrites.load(ordering: .acquiring) else {
            return .sealed
        }

        // A tap callback may already have passed the first accepting check
        // when stop seals the queue. Keep the consumer alive until that
        // producer has either published its frames or observed the seal.
        activeProducerCount.wrappingAdd(1, ordering: .acquiringAndReleasing)
        defer {
            activeProducerCount.wrappingSubtract(1, ordering: .releasing)
            dataAvailable.signal()
        }
        guard acceptingWrites.load(ordering: .acquiring) else {
            return .sealed
        }

        let frameCount = Int(buffer.frameLength)
        let format = buffer.format
        guard frameCount > 0,
              format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved,
              abs(format.sampleRate - sampleRate) < 0.5,
              Int(format.channelCount) == channelCount else {
            recordFailureAndSeal(.formatChanged)
            return .formatChanged
        }
        guard let channelData = buffer.floatChannelData else {
            recordFailureAndSeal(.unsupportedBuffer)
            return .unsupportedBuffer
        }

        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        let buffered = write - read
        guard frameCount <= capacityFrames - buffered else {
            recordFailureAndSeal(.overflow)
            return .overflow
        }

        var selectedChannel = 0
        if channelCount > 1 {
            let sampleStep = max(1, frameCount / Self.maximumChannelSelectionSamples)
            var selectedEnergy = -Float.infinity
            for channel in 0..<channelCount {
                var energy = Float(0)
                var frame = 0
                while frame < frameCount {
                    let sample = channelData[channel][frame]
                    if sample.isFinite {
                        energy += sample * sample
                    }
                    frame += sampleStep
                }
                if energy > selectedEnergy {
                    selectedEnergy = energy
                    selectedChannel = channel
                }
            }
        }

        for frame in 0..<frameCount {
            let sample = channelData[selectedChannel][frame]
            let monoSample = sample.isFinite ? sample : 0
            let slot = (write + frame) % capacityFrames
            storage.advanced(by: slot).pointee = monoSample
        }
        writeIndex.store(write + frameCount, ordering: .releasing)
        dataAvailable.signal()
        return .accepted
    }

    func seal() {
        acceptingWrites.store(false, ordering: .releasing)
        dataAvailable.signal()
    }

    /// Marks the queue failed and wakes the consumer. This is used by the
    /// sequential writer when disk IO fails after a prefix was committed.
    func fail(_ failure: Failure) {
        _ = failureCode.compareExchange(
            expected: 0,
            desired: failure.rawValue,
            ordering: .acquiringAndReleasing
        )
        seal()
    }

    /// Copies available frames into preallocated consumer storage. Only the
    /// single writer task calls this method.
    @inline(__always)
    func dequeue(into destination: UnsafeMutableBufferPointer<Float>) -> Int {
        guard !destination.isEmpty else { return 0 }
        let read = readIndex.load(ordering: .relaxed)
        let write = writeIndex.load(ordering: .acquiring)
        let available = write - read
        guard available > 0 else { return 0 }

        let count = min(available, destination.count)
        for index in 0..<count {
            destination[index] = storage[(read + index) % capacityFrames]
        }
        readIndex.store(read + count, ordering: .releasing)
        return count
    }

    func waitForData() {
        dataAvailable.wait()
    }

    @inline(__always)
    private func recordFailureAndSeal(_ failure: Failure) {
        _ = failureCode.compareExchange(
            expected: 0,
            desired: failure.rawValue,
            ordering: .acquiringAndReleasing
        )
        acceptingWrites.store(false, ordering: .releasing)
        dataAvailable.signal()
    }
}

struct AudioSpoolBatch: Sendable {
    let chunks: [CapturedAudioChunk]
    let nextFrameOffset: Int

    var frameCount: Int {
        chunks.reduce(0) { $0 + $1.monoSamples.count }
    }
}

/// A private, append-only capture file. The file is intentionally separate
/// from the final history asset: it is a crash-safe live source that can span
/// device format changes without keeping the recording in RAM.
final class AudioCaptureSpool: @unchecked Sendable {
    private static let privateDirectoryName = "FlusterFlowCaptureSpools"
    private static let magic = Data([0x46, 0x46, 0x53, 0x31, 0x01, 0x00, 0x00, 0x00])
    private static let recordMarker: UInt32 = 0x314B4843 // "CHK1" in little endian
    private static let recordHeaderSize = 4 + 8 + 8
    private static let maximumRecordFrames = 1_048_576
    private static let writerDispatchQueue = DispatchQueue(
        label: "com.flusterflow.audio-capture-spool-writer",
        qos: .utility,
        attributes: .concurrent
    )

    private let fileManager: FileManager
    private let writeData: @Sendable (Data, URL) throws -> Void
    private let lock = NSLock()
    private let lockURL: URL
    private var ownsFiles = false
    private var isClosed = false
    private var activeSampleRate: Double?
    private var incrementalCursor: IncrementalReadCursor?
    private let writtenFrameCount = Atomic<Int>(0)
    private let failureCode = Atomic<Int>(0)

    let fileURL: URL

    init(
        fileURL: URL = AudioCaptureSpool.defaultFileURL(),
        fileManager: FileManager = .default,
        writeData: (@Sendable (Data, URL) throws -> Void)? = nil
    ) throws {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.writeData = writeData ?? Self.appendData
        lockURL = fileURL.appendingPathExtension("lock")

        var ownsLock = false
        do {
            try Self.preparePrivateDirectory(fileManager)
            try? Self.removeStaleSpools(
                from: Self.privateDirectoryURL(),
                fileManager: fileManager
            )
            try Self.createExclusiveFile(at: lockURL, permissions: 0o600)
            ownsLock = true
            try Self.writeOwner(to: lockURL)
            try Self.createExclusiveFile(at: fileURL, permissions: 0o600)
            ownsFiles = true
        } catch {
            if ownsLock { try? fileManager.removeItem(at: lockURL) }
            if let error = error as? AudioCaptureSpoolError {
                throw error
            }
            throw AudioCaptureSpoolError.cannotCreateFile
        }

        do {
            try self.writeData(Self.magic, fileURL)
        } catch {
            // Keep the owner marker until the capture file is confirmed gone.
            // If unlink fails, a later launch must not mistake this path for a
            // free spool and truncate another owner's partial capture.
            var captureRemoved = !fileManager.fileExists(atPath: fileURL.path)
            if !captureRemoved {
                try? fileManager.removeItem(at: fileURL)
                captureRemoved = !fileManager.fileExists(atPath: fileURL.path)
            }
            if captureRemoved, fileManager.fileExists(atPath: lockURL.path) {
                try? fileManager.removeItem(at: lockURL)
            }
            throw AudioCaptureSpoolError.writeFailed
        }
    }

    deinit {
        if ownsFiles { try? discard() }
    }

    static func defaultFileURL() -> URL {
        privateDirectoryURL()
            .appendingPathComponent("FlusterFlow-\(UUID().uuidString).capture", isDirectory: false)
    }

    /// Best-effort cleanup for app startup. A false result is a diagnostic
    /// signal only; an inability to inspect stale files must not stop capture
    /// or abort the application.
    @discardableResult
    static func cleanupAbandonedSpools(
        fileManager: FileManager = .default
    ) -> Bool {
        do {
            try preparePrivateDirectory(fileManager)
            try removeStaleSpools(
                from: privateDirectoryURL(),
                fileManager: fileManager
            )
            return true
        } catch {
            return false
        }
    }

    private static func privateDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(privateDirectoryName, isDirectory: true)
    }

    private static func preparePrivateDirectory(
        _ fileManager: FileManager
    ) throws {
        let directory = privateDirectoryURL()
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard chmod(directory.path, 0o700) == 0 else {
                throw AudioCaptureSpoolError.cannotCreateFile
            }
        } catch let error as AudioCaptureSpoolError {
            throw error
        } catch {
            throw AudioCaptureSpoolError.cannotCreateFile
        }
    }

    /// Remove only orphaned files whose sidecar proves that their owning
    /// process is gone. Files without a valid owner marker are retained so a
    /// live recording can never be deleted by a later launch.
    private static func removeStaleSpools(
        from directory: URL,
        fileManager: FileManager
    ) throws {
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            throw AudioCaptureSpoolError.cannotCreateFile
        }

        for lockURL in entries where lockURL.pathExtension == "lock" {
            let spoolURL = lockURL.deletingPathExtension()
            guard spoolURL.pathExtension == "capture" else { continue }
            guard let ownerData = try? Data(contentsOf: lockURL),
                  let ownerString = String(data: ownerData, encoding: .utf8),
                  let pid = Int32(ownerString.trimmingCharacters(in: .whitespacesAndNewlines)),
                  pid > 0 else {
                continue
            }
            errno = 0
            _ = kill(pid_t(pid), 0)
            if errno == 0 || errno == EPERM { continue }
            guard errno == ESRCH else { continue }
            try? fileManager.removeItem(at: lockURL)
            try? fileManager.removeItem(at: spoolURL)
        }
    }

    private static func createExclusiveFile(
        at url: URL,
        permissions: Int32
    ) throws {
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL,
            mode_t(permissions)
        )
        guard descriptor >= 0 else {
            throw AudioCaptureSpoolError.cannotCreateFile
        }
        guard Darwin.close(descriptor) == 0 else {
            try? FileManager.default.removeItem(at: url)
            throw AudioCaptureSpoolError.cannotCreateFile
        }
    }

    private static func writeOwner(to url: URL) throws {
        var handle: FileHandle?
        do {
            handle = try FileHandle(forWritingTo: url)
            try handle?.write(contentsOf: Data("\(getpid())\n".utf8))
            try handle?.close()
        } catch {
            try? handle?.close()
            throw AudioCaptureSpoolError.cannotCreateFile
        }
    }

    var writtenFrameCountValue: Int {
        writtenFrameCount.load(ordering: .acquiring)
    }

    var failure: AudioCaptureSpoolError? {
        switch failureCode.load(ordering: .acquiring) {
        case 1: return .writeFailed
        case 2: return .readFailed
        case 3: return .corruptFile
        default: return nil
        }
    }

    func startSegment(sampleRate: Double) throws {
        guard sampleRate.isFinite,
              sampleRate > 0,
              sampleRate <= RealtimeAudioFrameQueue.maximumSupportedSampleRate else {
            throw AudioCaptureSpoolError.invalidConfiguration
        }
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { throw AudioCaptureSpoolError.writeFailed }
        activeSampleRate = sampleRate
    }

    func endSegment() {
        lock.lock()
        activeSampleRate = nil
        lock.unlock()
    }

    func append(
        _ samples: UnsafeBufferPointer<Float>,
        sampleRate: Double
    ) throws {
        guard !samples.isEmpty,
              sampleRate.isFinite,
              sampleRate > 0,
              sampleRate <= RealtimeAudioFrameQueue.maximumSupportedSampleRate,
              samples.count <= Self.maximumRecordFrames else {
            throw AudioCaptureSpoolError.invalidConfiguration
        }

        var data = Data(capacity: Self.recordHeaderSize + samples.count * MemoryLayout<Float>.size)
        append(UInt32(Self.recordMarker), to: &data)
        append(sampleRate.bitPattern, to: &data)
        append(UInt64(samples.count), to: &data)
        let sampleBytes = UnsafeRawBufferPointer(
            start: samples.baseAddress,
            count: samples.count * MemoryLayout<Float>.size
        )
        data.append(contentsOf: sampleBytes)

        lock.lock()
        defer { lock.unlock() }
        guard !isClosed,
              activeSampleRate.map({ abs($0 - sampleRate) < 0.5 }) ?? false else {
            throw AudioCaptureSpoolError.writeFailed
        }
        do {
            try writeData(data, fileURL)
            writtenFrameCount.wrappingAdd(samples.count, ordering: .releasing)
        } catch {
            markFailure(.writeFailed)
            throw AudioCaptureSpoolError.writeFailed
        }
    }

    /// Drains a queue on one utility task. All allocations and file writes are
    /// kept on this side of the realtime boundary.
    func startWriter(
        for queue: RealtimeAudioFrameQueue,
        writerFrameCapacity: Int = 16_384
    ) -> Task<Void, Never> {
        let capacity = max(1, min(writerFrameCapacity, Self.maximumRecordFrames))
        return Task.detached(priority: .utility) { [weak self, queue] in
            guard let spool = self else { return }
            await withCheckedContinuation { continuation in
                Self.writerDispatchQueue.async {
                    spool.consume(queue, writerFrameCapacity: capacity)
                    continuation.resume()
                }
            }
        }
    }

    func drain(
        queue: RealtimeAudioFrameQueue,
        writer: Task<Void, Never>
    ) async throws {
        queue.seal()
        await writer.value
        if let failure = queue.failure {
            switch failure {
            case .overflow:
                throw AudioCaptureSpoolError.queueOverflow
            case .storageFailed:
                throw AudioCaptureSpoolError.writeFailed
            case .formatChanged, .unsupportedBuffer:
                throw AudioCaptureSpoolError.formatChanged
            }
        }
        if let failure {
            throw failure
        }
    }

    func readBatch(
        afterFrameOffset frameOffset: Int,
        minimumDurationSeconds: TimeInterval,
        maximumDurationSeconds: TimeInterval = 2
    ) throws -> AudioSpoolBatch? {
        guard frameOffset >= 0,
              minimumDurationSeconds.isFinite,
              minimumDurationSeconds >= 0,
              maximumDurationSeconds.isFinite,
              maximumDurationSeconds > 0,
              minimumDurationSeconds <= maximumDurationSeconds else {
            throw AudioCaptureSpoolError.invalidConfiguration
        }
        if let failure { throw failure }

        return try withLockedFile { handle in
            if let incrementalCursor,
               frameOffset < incrementalCursor.nextFrameOffset {
                // The live consumer's offset is a forward-only checkpoint. A
                // backwards request would duplicate frames; final processing
                // uses readAllChunks() when it needs a fresh traversal.
                throw AudioCaptureSpoolError.invalidConfiguration
            }
            let savedCursor = incrementalCursor
            do {
                var cursor = try cursor(
                    for: frameOffset,
                    in: handle
                )
                var collectedDuration = 0.0
                var chunks: [CapturedAudioChunk] = []

                while let pending = try pendingRecord(
                    for: &cursor,
                    in: handle
                ) {
                    let remainingDuration = max(
                        0,
                        maximumDurationSeconds - collectedDuration
                    )
                    let durationFrameCount = remainingDuration
                        * pending.header.sampleRate
                    guard durationFrameCount.isFinite,
                          durationFrameCount < Double(Int.max) else {
                        throw AudioCaptureSpoolError.invalidConfiguration
                    }
                    let durationLimitedCount = max(
                        1,
                        Int(durationFrameCount.rounded(.down))
                    )
                    let availableCount = pending.header.frameCount
                        - pending.consumedFrames
                    let targetCount = min(availableCount, durationLimitedCount)
                    guard targetCount > 0 else { break }

                    let sampleOffset = try checkedByteOffset(
                        pending.dataFileOffset,
                        frames: pending.consumedFrames
                    )
                    handle.seek(toFileOffset: sampleOffset)
                    let values = try readSamples(
                        targetCount,
                        from: handle
                    )
                    var consumed = pending
                    consumed.consumedFrames += values.count
                    cursor.nextFrameOffset = try checkedAdd(
                        cursor.nextFrameOffset,
                        values.count
                    )
                    if consumed.consumedFrames == consumed.header.frameCount {
                        cursor.pending = nil
                        cursor.nextHeaderFileOffset = try checkedByteOffset(
                            consumed.dataFileOffset,
                            frames: consumed.header.frameCount
                        )
                    } else {
                        cursor.pending = consumed
                    }

                    if !values.isEmpty {
                        chunks.append(
                            CapturedAudioChunk(
                                monoSamples: values,
                                sampleRate: pending.header.sampleRate
                            )
                        )
                        collectedDuration += Double(values.count)
                            / pending.header.sampleRate
                    }

                    if collectedDuration >= maximumDurationSeconds {
                        break
                    }
                }

                guard !chunks.isEmpty,
                      collectedDuration >= minimumDurationSeconds else {
                    // A caller polls while the writer is between records. Do
                    // not consume a partial batch that cannot yet meet the
                    // minimum; the next poll must retry the same offset.
                    incrementalCursor = savedCursor
                    return nil
                }
                incrementalCursor = cursor
                return AudioSpoolBatch(
                    chunks: chunks,
                    nextFrameOffset: cursor.nextFrameOffset
                )
            } catch {
                incrementalCursor = savedCursor
                throw error
            }
        }
    }

    /// Materializes the raw chunks only at final processing time. Live capture
    /// never calls this method, so the long recording stays file-backed and
    /// bounded in RAM until the recognizer's existing array-based API requires
    /// a final decode input.
    func readAllChunks() throws -> [CapturedAudioChunk] {
        if let failure { throw failure }
        return try withLockedFile { handle in
            try seekPastMagic(in: handle)
            var chunks: [CapturedAudioChunk] = []
            while let record = try readRecordHeader(from: handle) {
                let values = try readSamples(record.frameCount, from: handle)
                chunks.append(
                    CapturedAudioChunk(
                        monoSamples: values,
                        sampleRate: record.sampleRate
                    )
                )
            }
            return chunks
        }
    }

    func closeForWriting() {
        lock.lock()
        isClosed = true
        activeSampleRate = nil
        lock.unlock()
    }

    func discard() throws {
        // Close and unlink under one lock so no reader can open a path between
        // the state transition and removal while a writer is finishing.
        lock.lock()
        guard ownsFiles else {
            lock.unlock()
            return
        }
        isClosed = true
        activeSampleRate = nil
        var firstError: Error?
        var captureRemoved = !fileManager.fileExists(atPath: fileURL.path)
        if !captureRemoved {
            do {
                try fileManager.removeItem(at: fileURL)
                captureRemoved = !fileManager.fileExists(atPath: fileURL.path)
                if !captureRemoved {
                    firstError = AudioCaptureSpoolError.writeFailed
                }
            } catch {
                firstError = error
            }
        }
        // The lock remains the ownership proof while capture removal is
        // unresolved. Removing it first would allow a new spool to claim the
        // same URL while this instance still owns the old inode.
        var lockRemoved = !fileManager.fileExists(atPath: lockURL.path)
        if captureRemoved, !lockRemoved {
            do {
                try fileManager.removeItem(at: lockURL)
                lockRemoved = !fileManager.fileExists(atPath: lockURL.path)
                if !lockRemoved, firstError == nil {
                    firstError = AudioCaptureSpoolError.writeFailed
                }
            } catch where firstError == nil {
                firstError = error
            } catch {
                // Preserve the first cleanup failure for the caller.
            }
        }
        if captureRemoved, lockRemoved {
            ownsFiles = false
        }
        lock.unlock()
        if firstError != nil {
            throw AudioCaptureSpoolError.writeFailed
        }
    }

    private func consume(
        _ queue: RealtimeAudioFrameQueue,
        writerFrameCapacity: Int
    ) {
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: writerFrameCapacity)
        storage.initialize(repeating: 0, count: writerFrameCapacity)
        defer {
            storage.deinitialize(count: writerFrameCapacity)
            storage.deallocate()
        }

        let destination = UnsafeMutableBufferPointer(
            start: storage,
            count: writerFrameCapacity
        )
        while true {
            let count = queue.dequeue(into: destination)
            if count > 0 {
                do {
                    try append(
                        UnsafeBufferPointer(start: storage, count: count),
                        sampleRate: queue.sampleRate
                    )
                } catch {
                    queue.fail(.storageFailed)
                    return
                }
                continue
            }
            if queue.isSealed, !queue.hasActiveProducer { return }
            queue.waitForData()
        }
    }

    private func withLockedFile<T>(
        _ body: (FileHandle) throws -> T
    ) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            markFailure(.readFailed)
            throw AudioCaptureSpoolError.readFailed
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            markFailure(.readFailed)
            throw AudioCaptureSpoolError.readFailed
        }
        defer { try? handle.close() }
        do {
            return try body(handle)
        } catch let error as AudioCaptureSpoolError {
            throw error
        } catch {
            markFailure(.readFailed)
            throw AudioCaptureSpoolError.readFailed
        }
    }

    private struct RecordHeader {
        let sampleRate: Double
        let frameCount: Int
    }

    private struct PendingRecord {
        let header: RecordHeader
        let dataFileOffset: UInt64
        var consumedFrames: Int
    }

    private struct IncrementalReadCursor {
        var nextHeaderFileOffset: UInt64
        var nextFrameOffset: Int
        var pending: PendingRecord?
    }

    private func cursor(
        for requestedFrameOffset: Int,
        in handle: FileHandle
    ) throws -> IncrementalReadCursor {
        if var incrementalCursor,
           requestedFrameOffset >= incrementalCursor.nextFrameOffset {
            try advance(
                &incrementalCursor,
                to: requestedFrameOffset,
                in: handle
            )
            return incrementalCursor
        }

        try seekPastMagic(in: handle)
        var reset = IncrementalReadCursor(
            nextHeaderFileOffset: UInt64(Self.magic.count),
            nextFrameOffset: 0,
            pending: nil
        )
        try advance(&reset, to: requestedFrameOffset, in: handle)
        return reset
    }

    private func advance(
        _ cursor: inout IncrementalReadCursor,
        to targetFrameOffset: Int,
        in handle: FileHandle
    ) throws {
        guard targetFrameOffset >= cursor.nextFrameOffset else { return }
        while cursor.nextFrameOffset < targetFrameOffset {
            guard let pending = try pendingRecord(for: &cursor, in: handle)
            else { return }
            let available = pending.header.frameCount - pending.consumedFrames
            let skipped = min(available, targetFrameOffset - cursor.nextFrameOffset)
            var consumed = pending
            consumed.consumedFrames += skipped
            cursor.nextFrameOffset = try checkedAdd(
                cursor.nextFrameOffset,
                skipped
            )
            if consumed.consumedFrames == consumed.header.frameCount {
                cursor.pending = nil
                cursor.nextHeaderFileOffset = try checkedByteOffset(
                    consumed.dataFileOffset,
                    frames: consumed.header.frameCount
                )
            } else {
                cursor.pending = consumed
            }
        }
    }

    private func pendingRecord(
        for cursor: inout IncrementalReadCursor,
        in handle: FileHandle
    ) throws -> PendingRecord? {
        if let pending = cursor.pending { return pending }
        handle.seek(toFileOffset: cursor.nextHeaderFileOffset)
        guard let header = try readRecordHeader(from: handle) else {
            return nil
        }
        let pending = PendingRecord(
            header: header,
            dataFileOffset: handle.offsetInFile,
            consumedFrames: 0
        )
        cursor.pending = pending
        return pending
    }

    private func seekPastMagic(in handle: FileHandle) throws {
        let header = try readData(Self.magic.count, from: handle)
        guard header == Self.magic else {
            markFailure(.corruptFile)
            throw AudioCaptureSpoolError.corruptFile
        }
    }

    private func readRecordHeader(from handle: FileHandle) throws -> RecordHeader? {
        guard let data = try readOptionalData(Self.recordHeaderSize, from: handle) else {
            return nil
        }
        guard !data.isEmpty else { return nil }
        guard let marker = readLittleEndian(UInt32.self, from: data, offset: 0),
              marker == Self.recordMarker,
              let sampleRateBits = readLittleEndian(UInt64.self, from: data, offset: 4),
              let rawCount = readLittleEndian(UInt64.self, from: data, offset: 12),
              rawCount > 0,
              rawCount <= UInt64(Self.maximumRecordFrames) else {
            markFailure(.corruptFile)
            throw AudioCaptureSpoolError.corruptFile
        }
        let sampleRate = Double(bitPattern: sampleRateBits)
        guard sampleRate.isFinite,
              sampleRate > 0,
              sampleRate <= RealtimeAudioFrameQueue.maximumSupportedSampleRate else {
            markFailure(.corruptFile)
            throw AudioCaptureSpoolError.corruptFile
        }
        return RecordHeader(sampleRate: sampleRate, frameCount: Int(rawCount))
    }

    private func readSamples(_ count: Int, from handle: FileHandle) throws -> [Float] {
        let data = try readData(count * MemoryLayout<Float>.size, from: handle)
        var values: [Float] = []
        values.reserveCapacity(count)
        for index in 0..<count {
            guard let bits = readLittleEndian(
                UInt32.self,
                from: data,
                offset: index * MemoryLayout<Float>.size
            ) else {
                markFailure(.corruptFile)
                throw AudioCaptureSpoolError.corruptFile
            }
            values.append(Float(bitPattern: bits))
        }
        return values
    }

    private func skipSamples(_ count: Int, in handle: FileHandle) throws {
        guard count >= 0,
              count <= Int.max / MemoryLayout<Float>.size else {
            throw AudioCaptureSpoolError.corruptFile
        }
        let offset = handle.offsetInFile
        let bytes = UInt64(count * MemoryLayout<Float>.size)
        guard offset <= UInt64.max - bytes else {
            markFailure(.corruptFile)
            throw AudioCaptureSpoolError.corruptFile
        }
        handle.seek(toFileOffset: offset + bytes)
    }

    private func readData(_ count: Int, from handle: FileHandle) throws -> Data {
        guard let data = try readOptionalData(count, from: handle), data.count == count else {
            markFailure(.corruptFile)
            throw AudioCaptureSpoolError.corruptFile
        }
        return data
    }

    private func readOptionalData(_ count: Int, from handle: FileHandle) throws -> Data? {
        do {
            return try handle.read(upToCount: count)
        } catch {
            markFailure(.readFailed)
            throw AudioCaptureSpoolError.readFailed
        }
    }

    private func checkedAdd(_ lhs: Int, _ rhs: Int) throws -> Int {
        guard lhs <= Int.max - rhs else {
            markFailure(.corruptFile)
            throw AudioCaptureSpoolError.corruptFile
        }
        return lhs + rhs
    }

    private func checkedByteOffset(
        _ base: UInt64,
        frames: Int
    ) throws -> UInt64 {
        guard frames >= 0,
              UInt64(frames) <= UInt64.max / UInt64(MemoryLayout<Float>.size)
        else {
            markFailure(.corruptFile)
            throw AudioCaptureSpoolError.corruptFile
        }
        let bytes = UInt64(frames) * UInt64(MemoryLayout<Float>.size)
        guard base <= UInt64.max - bytes else {
            markFailure(.corruptFile)
            throw AudioCaptureSpoolError.corruptFile
        }
        return base + bytes
    }

    private func markFailure(_ failure: AudioCaptureSpoolError) {
        let code: Int
        switch failure {
        case .writeFailed, .queueOverflow: code = 1
        case .readFailed: code = 2
        case .corruptFile: code = 3
        case .invalidConfiguration, .formatChanged, .cannotCreateFile: return
        }
        _ = failureCode.compareExchange(
            expected: 0,
            desired: code,
            ordering: .acquiringAndReleasing
        )
    }

    private static func appendData(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        handle.synchronizeFile()
    }

    private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndianValue = value.littleEndian
        withUnsafeBytes(of: &littleEndianValue) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private func readLittleEndian<T: FixedWidthInteger>(
        _ type: T.Type,
        from data: Data,
        offset: Int
    ) -> T? {
        guard offset >= 0,
              offset <= data.count - MemoryLayout<T>.size else {
            return nil
        }
        return data.withUnsafeBytes { rawBuffer in
            let value = rawBuffer.loadUnaligned(
                fromByteOffset: offset,
                as: T.self
            )
            return T(littleEndian: value)
        }
    }
}
