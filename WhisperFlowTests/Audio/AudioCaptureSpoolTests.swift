@preconcurrency import AVFoundation
import Foundation
import XCTest
@testable import WhisperFlow

final class AudioCaptureSpoolTests: XCTestCase {
    func testCaptureLongerThanLegacyLimitDrainsEveryFrameWithBoundedQueue() async throws {
        let url = temporaryURL()
        let spool = try AudioCaptureSpool(fileURL: url)
        defer { try? spool.discard() }
        try spool.startSegment(sampleRate: 100)
        let queue = try XCTUnwrap(
            RealtimeAudioFrameQueue(
                sampleRate: 100,
                channelCount: 1,
                capacitySeconds: 2
            )
        )
        let writer = spool.startWriter(for: queue, writerFrameCapacity: 64)

        let totalFrames = 12_100 // 121 seconds at this synthetic sample rate.
        for offset in stride(from: 0, to: totalFrames, by: 25) {
            let count = min(25, totalFrames - offset)
            let values = (0..<count).map { Float(offset + $0) }
            try await waitForQueueCapacity(queue, additionalFrames: count)
            let buffer = try makeBuffer(sampleRate: 100, channels: [values])
            XCTAssertEqual(queue.append(buffer), .accepted)
            await Task.yield()
        }

        try await spool.drain(queue: queue, writer: writer)
        let chunks = try spool.readAllChunks()
        let values = chunks.flatMap(\.monoSamples)

        XCTAssertEqual(queue.capacityFrames, 200)
        XCTAssertEqual(values.count, totalFrames)
        XCTAssertEqual(values, (0..<totalFrames).map(Float.init))
        XCTAssertGreaterThan(Double(values.count) / 100, 120)
    }

    func testIncrementalBatchesUseMonotonicOffsetsWithoutDuplication() async throws {
        let url = temporaryURL()
        let spool = try AudioCaptureSpool(fileURL: url)
        defer { try? spool.discard() }
        try spool.startSegment(sampleRate: 100)
        let queue = try XCTUnwrap(
            RealtimeAudioFrameQueue(sampleRate: 100, channelCount: 1, capacitySeconds: 5)
        )
        let writer = spool.startWriter(for: queue, writerFrameCapacity: 64)
        let values = (0..<450).map(Float.init)
        XCTAssertEqual(
            queue.append(try makeBuffer(sampleRate: 100, channels: [values])),
            .accepted
        )
        try await spool.drain(queue: queue, writer: writer)

        var offset = 0
        var collected: [Float] = []
        while let batch = try spool.readBatch(
            afterFrameOffset: offset,
            minimumDurationSeconds: 0,
            maximumDurationSeconds: 2
        ) {
            XCTAssertGreaterThan(batch.nextFrameOffset, offset)
            collected.append(contentsOf: batch.chunks.flatMap(\.monoSamples))
            offset = batch.nextFrameOffset
        }

        XCTAssertEqual(offset, values.count)
        XCTAssertEqual(collected, values)
    }

    func testIncrementalCursorRejectsBackwardOffsets() async throws {
        let url = temporaryURL()
        let spool = try AudioCaptureSpool(fileURL: url)
        defer { try? spool.discard() }
        try spool.startSegment(sampleRate: 100)
        let queue = try XCTUnwrap(
            RealtimeAudioFrameQueue(sampleRate: 100, channelCount: 1, capacitySeconds: 1)
        )
        let writer = spool.startWriter(for: queue, writerFrameCapacity: 64)
        XCTAssertEqual(
            queue.append(try makeBuffer(sampleRate: 100, channels: [[1, 2, 3, 4]])),
            .accepted
        )
        try await spool.drain(queue: queue, writer: writer)
        _ = try spool.readBatch(
            afterFrameOffset: 0,
            minimumDurationSeconds: 0,
            maximumDurationSeconds: 2
        )

        XCTAssertThrowsError(
            try spool.readBatch(
                afterFrameOffset: 0,
                minimumDurationSeconds: 0,
                maximumDurationSeconds: 2
            )
        ) { error in
            XCTAssertEqual(error as? AudioCaptureSpoolError, .invalidConfiguration)
        }
    }

    func testBatchDurationBoundsAreValidatedBeforeReading() throws {
        let spool = try AudioCaptureSpool(fileURL: temporaryURL())
        defer { try? spool.discard() }

        XCTAssertThrowsError(
            try spool.readBatch(
                afterFrameOffset: 0,
                minimumDurationSeconds: 2,
                maximumDurationSeconds: 1
            )
        ) { error in
            XCTAssertEqual(error as? AudioCaptureSpoolError, .invalidConfiguration)
        }
    }

    func testFormatReconfigurationAppendsASecondSegmentWithoutLosingFrames() async throws {
        let url = temporaryURL()
        let spool = try AudioCaptureSpool(fileURL: url)
        defer { try? spool.discard() }

        try spool.startSegment(sampleRate: 100)
        let firstQueue = try XCTUnwrap(
            RealtimeAudioFrameQueue(sampleRate: 100, channelCount: 1, capacitySeconds: 1)
        )
        let firstWriter = spool.startWriter(for: firstQueue, writerFrameCapacity: 64)
        XCTAssertEqual(
            firstQueue.append(try makeBuffer(sampleRate: 100, channels: [[1, 2, 3]])),
            .accepted
        )
        try await spool.drain(queue: firstQueue, writer: firstWriter)
        spool.endSegment()

        try spool.startSegment(sampleRate: 200)
        let secondQueue = try XCTUnwrap(
            RealtimeAudioFrameQueue(sampleRate: 200, channelCount: 1, capacitySeconds: 1)
        )
        let secondWriter = spool.startWriter(for: secondQueue, writerFrameCapacity: 64)
        XCTAssertEqual(
            secondQueue.append(try makeBuffer(sampleRate: 200, channels: [[4, 5, 6, 7]])),
            .accepted
        )
        try await spool.drain(queue: secondQueue, writer: secondWriter)

        let chunks = try spool.readAllChunks()
        XCTAssertEqual(chunks.map(\.sampleRate), [100, 200])
        XCTAssertEqual(chunks.flatMap(\.monoSamples), [1, 2, 3, 4, 5, 6, 7])
    }

    func testQueueOverflowIsStickyAndFailsClosedWithoutBlockingProducer() throws {
        let queue = try XCTUnwrap(
            RealtimeAudioFrameQueue(sampleRate: 100, channelCount: 1, capacitySeconds: 0.04)
        )
        let buffer = try makeBuffer(sampleRate: 100, channels: [[1, 2, 3, 4, 5]])

        XCTAssertEqual(queue.append(buffer), .overflow)
        XCTAssertEqual(queue.failure, .overflow)
        XCTAssertTrue(queue.isSealed)
        XCTAssertEqual(queue.append(buffer), .sealed)
    }

    func testWriterFailureIsReportedAfterCommittedPrefix() async throws {
        let url = temporaryURL()
        let writerFailure = FailingSpoolWriter(failAfterWriteCount: 1)
        let spool = try AudioCaptureSpool(fileURL: url, writeData: writerFailure.write)
        defer { try? spool.discard() }
        try spool.startSegment(sampleRate: 100)
        let queue = try XCTUnwrap(
            RealtimeAudioFrameQueue(sampleRate: 100, channelCount: 1, capacitySeconds: 1)
        )
        let writer = spool.startWriter(for: queue, writerFrameCapacity: 64)
        XCTAssertEqual(
            queue.append(try makeBuffer(sampleRate: 100, channels: [[1, 2, 3]])),
            .accepted
        )
        XCTAssertEqual(
            queue.append(try makeBuffer(sampleRate: 100, channels: [[4, 5, 6]])),
            .accepted
        )

        do {
            try await spool.drain(queue: queue, writer: writer)
            XCTFail("A writer error must be surfaced to the capture")
        } catch {
            XCTAssertEqual(error as? AudioCaptureSpoolError, .writeFailed)
        }
        XCTAssertEqual(spool.failure, .writeFailed)
    }

    func testDiscardRemovesPrivateSpoolOnCancellation() throws {
        let url = temporaryURL()
        let spool = try AudioCaptureSpool(fileURL: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        try spool.discard()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDiscardRetainsOwnershipMarkerWhenCaptureRemovalFails() throws {
        let url = temporaryURL()
        let fileManager = FailingRemovalFileManager(failingURL: url)
        let spool = try AudioCaptureSpool(fileURL: url, fileManager: fileManager)
        let lockURL = url.appendingPathExtension("lock")

        XCTAssertThrowsError(try spool.discard()) { error in
            XCTAssertEqual(error as? AudioCaptureSpoolError, .writeFailed)
        }
        XCTAssertTrue(fileManager.fileExists(atPath: url.path))
        XCTAssertTrue(fileManager.fileExists(atPath: lockURL.path))

        fileManager.failingURL = nil
        try spool.discard()
        XCTAssertFalse(fileManager.fileExists(atPath: url.path))
        XCTAssertFalse(fileManager.fileExists(atPath: lockURL.path))
    }

    func testMagicWriteFailureRetainsOwnershipMarkerWhenCaptureRemovalFails() throws {
        let url = temporaryURL()
        let fileManager = FailingRemovalFileManager(failingURL: url)
        XCTAssertThrowsError(
            try AudioCaptureSpool(
                fileURL: url,
                fileManager: fileManager,
                writeData: { _, _ in throw AudioCaptureSpoolError.writeFailed }
            )
        ) { error in
            XCTAssertEqual(error as? AudioCaptureSpoolError, .writeFailed)
        }

        let lockURL = url.appendingPathExtension("lock")
        XCTAssertTrue(fileManager.fileExists(atPath: url.path))
        XCTAssertTrue(fileManager.fileExists(atPath: lockURL.path))

        fileManager.failingURL = nil
        try fileManager.removeItem(at: url)
        try fileManager.removeItem(at: lockURL)
    }

    func testExclusiveCreationDoesNotTouchAnExistingOwner() throws {
        let url = temporaryURL()
        let first = try AudioCaptureSpool(fileURL: url)
        defer { try? first.discard() }
        let before = try Data(contentsOf: url)
        let lockURL = url.appendingPathExtension("lock")
        let lockBefore = try Data(contentsOf: lockURL)

        XCTAssertThrowsError(try AudioCaptureSpool(fileURL: url)) { error in
            XCTAssertEqual(error as? AudioCaptureSpoolError, .cannotCreateFile)
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try Data(contentsOf: lockURL), lockBefore)
    }

    func testCleanupRemovesOnlyDeadOwnerSpools() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlusterFlowCaptureSpools", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = directory.appendingPathComponent(
            "FlusterFlow-Stale-(UUID().uuidString).capture"
        )
        let lockURL = url.appendingPathExtension("lock")
        FileManager.default.createFile(atPath: url.path, contents: Data([1]))
        FileManager.default.createFile(
            atPath: lockURL.path,
            contents: Data("2147483647\n".utf8),
            attributes: [.posixPermissions: 0o600]
        )

        XCTAssertTrue(AudioCaptureSpool.cleanupAbandonedSpools())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FlusterFlow-SpoolTests-\(UUID().uuidString).capture")
    }

    private func waitForQueueCapacity(
        _ queue: RealtimeAudioFrameQueue,
        additionalFrames: Int
    ) async throws {
        for _ in 0..<2_000 {
            if queue.bufferedFrameCount + additionalFrames <= queue.capacityFrames {
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("spool writer did not drain the bounded producer queue")
    }

    private func makeBuffer(
        sampleRate: Double,
        channels: [[Float]]
    ) throws -> AVAudioPCMBuffer {
        let frameCount = channels.first?.count ?? 0
        XCTAssertTrue(channels.allSatisfy { $0.count == frameCount })
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: AVAudioChannelCount(channels.count),
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
            )
        )
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let channelData = try XCTUnwrap(buffer.floatChannelData)
        for channel in channels.indices {
            for frame in channels[channel].indices {
                channelData[channel][frame] = channels[channel][frame]
            }
        }
        return buffer
    }
}

private final class FailingSpoolWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let failAfterWriteCount: Int
    private var writeCount = 0

    init(failAfterWriteCount: Int) {
        self.failAfterWriteCount = failAfterWriteCount
    }

    func write(_ data: Data, _ url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        if writeCount >= failAfterWriteCount {
            throw AudioCaptureSpoolError.writeFailed
        }
        writeCount += 1
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}

private final class FailingRemovalFileManager: FileManager {
    var failingURL: URL?

    init(failingURL: URL?) {
        self.failingURL = failingURL
        super.init()
    }

    override func removeItem(at URL: URL) throws {
        if URL == failingURL {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: URL)
    }
}
