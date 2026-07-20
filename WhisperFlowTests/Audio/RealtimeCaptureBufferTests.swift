@preconcurrency import AVFoundation
import Foundation
import XCTest
@testable import WhisperFlow

final class RealtimeCaptureBufferTests: XCTestCase {
    func testCapacityIsExactlyBoundedToOneHundredTwentySeconds() {
        XCTAssertEqual(
            RealtimeCaptureBuffer.requiredCapacity(
                sampleRate: 48_000,
                maximumDurationSeconds: AVAudioEngineCapture.maximumCaptureDurationSeconds
            ),
            5_760_000
        )
        XCTAssertNil(
            RealtimeCaptureBuffer.requiredCapacity(
                sampleRate: RealtimeCaptureBuffer.maximumSupportedSampleRate + 1,
                maximumDurationSeconds: AVAudioEngineCapture.maximumCaptureDurationSeconds
            )
        )
        XCTAssertNil(
            RealtimeCaptureBuffer.requiredCapacity(
                sampleRate: 48_000,
                maximumDurationSeconds: .infinity
            )
        )
    }

    func testTapBufferMixesPlanarChannelsDirectlyIntoPreallocatedMonoStorage() throws {
        let accumulator = try XCTUnwrap(
            RealtimeCaptureBuffer(sampleRate: 4, channelCount: 2, maximumDurationSeconds: 1)
        )
        let buffer = try makeBuffer(
            sampleRate: 4,
            channels: [
                [1, 0, -1, 0.5],
                [-1, 1, 1, 0.5]
            ]
        )

        XCTAssertEqual(accumulator.append(buffer), .accepted)
        let snapshot = accumulator.snapshot()

        XCTAssertNil(snapshot.failure)
        XCTAssertEqual(snapshot.capacity, 4)
        XCTAssertEqual(snapshot.capturedFrameCount, 4)
        XCTAssertEqual(snapshot.chunks.count, 1)
        XCTAssertEqual(snapshot.chunks[0].sampleRate, 4)
        XCTAssertEqual(snapshot.chunks[0].monoSamples, [0, 0.5, 0, 0.5])
    }

    func testIncrementalSnapshotsReturnOnlyNewFramesWithoutSealingCapture() throws {
        let accumulator = try XCTUnwrap(
            RealtimeCaptureBuffer(sampleRate: 4, channelCount: 1, maximumDurationSeconds: 2)
        )
        let first = try makeBuffer(sampleRate: 4, channels: [[0.1, 0.2, 0.3, 0.4]])
        let second = try makeBuffer(sampleRate: 4, channels: [[0.5, 0.6]])

        XCTAssertEqual(accumulator.append(first), .accepted)
        let firstSnapshot = try XCTUnwrap(
            accumulator.incrementalSnapshot(afterFrameOffset: 0, minimumDurationSeconds: 0.5)
        )
        XCTAssertEqual(firstSnapshot.monoSamples, [0.1, 0.2, 0.3, 0.4])
        XCTAssertEqual(firstSnapshot.nextFrameOffset, 4)

        XCTAssertEqual(accumulator.append(second), .accepted)
        let secondSnapshot = try XCTUnwrap(
            accumulator.incrementalSnapshot(
                afterFrameOffset: firstSnapshot.nextFrameOffset,
                minimumDurationSeconds: 0.5
            )
        )
        XCTAssertEqual(secondSnapshot.monoSamples, [0.5, 0.6])
        XCTAssertEqual(secondSnapshot.nextFrameOffset, 6)

        let finalSnapshot = accumulator.snapshot()
        XCTAssertEqual(finalSnapshot.capturedFrameCount, 6)
        XCTAssertEqual(finalSnapshot.chunks[0].monoSamples, [0.1, 0.2, 0.3, 0.4, 0.5, 0.6])
    }

    func testOverflowRejectsWholeCrossingBufferAndBecomesSticky() throws {
        let accumulator = try XCTUnwrap(
            RealtimeCaptureBuffer(sampleRate: 4, channelCount: 1, maximumDurationSeconds: 1)
        )
        let first = try makeBuffer(sampleRate: 4, channels: [[0.1, 0.2, 0.3]])
        let crossing = try makeBuffer(sampleRate: 4, channels: [[0.4, 0.5]])
        let later = try makeBuffer(sampleRate: 4, channels: [[0.6]])

        XCTAssertEqual(accumulator.append(first), .accepted)
        XCTAssertEqual(accumulator.append(crossing), .maximumDurationExceeded)
        XCTAssertEqual(accumulator.append(later), .maximumDurationExceeded)

        let snapshot = accumulator.snapshot()
        XCTAssertEqual(snapshot.failure, .maximumDurationExceeded)
        XCTAssertTrue(snapshot.maximumDurationExceeded)
        XCTAssertEqual(snapshot.capturedFrameCount, 3)
        XCTAssertEqual(snapshot.capacity, 4)
        XCTAssertEqual(snapshot.chunks[0].monoSamples, [0.1, 0.2, 0.3])
    }

    func testSealRejectsLateBuffersAndPreservesAcceptedPrefix() throws {
        let accumulator = try XCTUnwrap(
            RealtimeCaptureBuffer(sampleRate: 4, channelCount: 1, maximumDurationSeconds: 1)
        )
        let first = try makeBuffer(sampleRate: 4, channels: [[0.1, 0.2]])
        let late = try makeBuffer(sampleRate: 4, channels: [[0.3]])

        XCTAssertEqual(accumulator.append(first), .accepted)
        accumulator.seal()
        XCTAssertEqual(accumulator.append(late), .sealed)

        let snapshot = accumulator.snapshot()
        XCTAssertNil(snapshot.failure)
        XCTAssertEqual(snapshot.capturedFrameCount, 2)
        XCTAssertEqual(snapshot.chunks[0].monoSamples, [0.1, 0.2])
    }

    func testFormatChangeIsFailClosedAndNeverAddsSamples() throws {
        let accumulator = try XCTUnwrap(
            RealtimeCaptureBuffer(sampleRate: 4, channelCount: 2, maximumDurationSeconds: 1)
        )
        let changedRate = try makeBuffer(sampleRate: 8, channels: [[0.1], [0.2]])
        let expectedFormat = try makeBuffer(sampleRate: 4, channels: [[0.1], [0.2]])

        XCTAssertEqual(accumulator.append(changedRate), .formatChanged)
        XCTAssertEqual(accumulator.append(expectedFormat), .formatChanged)

        let snapshot = accumulator.snapshot()
        XCTAssertEqual(snapshot.failure, .formatChanged)
        XCTAssertEqual(snapshot.capturedFrameCount, 0)
        XCTAssertTrue(snapshot.chunks.isEmpty)
    }

    func testInterleavedBufferIsRejectedWithoutUnsafeChannelTraversal() throws {
        let accumulator = try XCTUnwrap(
            RealtimeCaptureBuffer(sampleRate: 4, channelCount: 2, maximumDurationSeconds: 1)
        )
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 4,
                channels: 2,
                interleaved: true
            )
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1

        XCTAssertEqual(accumulator.append(buffer), .formatChanged)
        XCTAssertEqual(accumulator.snapshot().failure, .formatChanged)
    }

    func testRenderPathSourceContainsNoAllocationLockOrBlockingWork() throws {
        let source = try captureSource()
        let appendStart = try XCTUnwrap(source.range(of: "func append(_ buffer: AVAudioPCMBuffer)"))
        let snapshotStart = try XCTUnwrap(
            source.range(
                of: "func snapshot() -> Snapshot",
                range: appendStart.upperBound..<source.endIndex
            )
        )
        let renderPath = String(source[appendStart.lowerBound..<snapshotStart.lowerBound])

        for forbidden in [
            "NSLock",
            "withLock",
            "[Float]",
            "Array(",
            ".allocate(",
            "Task {",
            "DispatchQueue",
            "await ",
            "async ",
            "sleep(",
            "sched_yield"
        ] {
            XCTAssertFalse(renderPath.contains(forbidden), "render path contains \(forbidden)")
        }
        XCTAssertTrue(renderPath.contains("storage.advanced(by:"))
        XCTAssertTrue(renderPath.contains("Atomic" ) == false)
    }

    func testEveryTerminalLifecyclePathUsesCentralSealBeforeTapRemoval() throws {
        let source = try captureSource()
        let stopStart = try XCTUnwrap(source.range(of: "private func stopEngine()"))
        let clearStart = try XCTUnwrap(
            source.range(
                of: "private func clearSession()",
                range: stopStart.upperBound..<source.endIndex
            )
        )
        let stopBody = String(source[stopStart.lowerBound..<clearStart.lowerBound])
        let seal = try XCTUnwrap(stopBody.range(of: "accumulator?.seal()"))
        let removeTap = try XCTUnwrap(stopBody.range(of: "removeTap"))
        let stop = try XCTUnwrap(stopBody.range(of: "engine.stop()"))

        XCTAssertLessThan(seal.lowerBound, removeTap.lowerBound)
        XCTAssertLessThan(removeTap.lowerBound, stop.lowerBound)
        XCTAssertTrue(source.contains("terminalError = .deviceConfigurationChanged\n        stopEngine()"))
        XCTAssertTrue(source.contains("func cancelCapture(for sessionID: DictationSessionID) async"))
    }

    func testAutomaticModeLeavesInputSelectionToTheMacOSSystemDefault() throws {
        let source = try captureSource()
        let start = try XCTUnwrap(source.range(of: "func startCapture"))
        let finish = try XCTUnwrap(
            source.range(
                of: "func finishCapture",
                range: start.upperBound..<source.endIndex
            )
        )
        let startBody = String(source[start.lowerBound..<finish.lowerBound])

        XCTAssertTrue(startBody.contains("let requestedUID = await selectedInputUID()"))
        XCTAssertTrue(startBody.contains("activateEngine(withUID: requestedUID"))
        XCTAssertFalse(startBody.contains("CoreAudioInputDevices"))
        XCTAssertFalse(source.contains("automaticCandidates"))
        XCTAssertFalse(source.contains("kAudioHardwarePropertyDefaultInputDevice"))
    }

    func testExpectedInputDeviceReconfigurationKeepsCaptureAlive() {
        XCTAssertFalse(
            AVAudioEngineCapture.configurationChangeRequiresTermination(
                engineRunning: true,
                expectedSampleRate: 48_000,
                expectedChannelCount: 1,
                currentSampleRate: 48_000,
                currentChannelCount: 1
            )
        )
    }

    func testStoppedOrIncompatibleInputDeviceTerminatesCapture() {
        XCTAssertTrue(
            AVAudioEngineCapture.configurationChangeRequiresTermination(
                engineRunning: false,
                expectedSampleRate: 48_000,
                expectedChannelCount: 1,
                currentSampleRate: 48_000,
                currentChannelCount: 1
            )
        )
        XCTAssertTrue(
            AVAudioEngineCapture.configurationChangeRequiresTermination(
                engineRunning: true,
                expectedSampleRate: 48_000,
                expectedChannelCount: 1,
                currentSampleRate: 24_000,
                currentChannelCount: 1
            )
        )
        XCTAssertTrue(
            AVAudioEngineCapture.configurationChangeRequiresTermination(
                engineRunning: true,
                expectedSampleRate: 48_000,
                expectedChannelCount: 1,
                currentSampleRate: 48_000,
                currentChannelCount: 2
            )
        )
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

    private func captureSource() throws -> String {
        try TestResourceLoader.string(
            "WhisperFlow/Core/Audio/AVAudioEngineCapture.swift"
        )
    }
}
