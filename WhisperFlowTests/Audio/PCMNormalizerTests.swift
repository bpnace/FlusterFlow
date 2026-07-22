import XCTest
@testable import WhisperFlow

final class PCMNormalizerTests: XCTestCase {
    func testDCOffsetIsRemovedBeforeSpeechIsStored() throws {
        let speech = sineWave(sampleRate: 16_000, durationSeconds: 0.4, amplitude: 0.08)
            .map { $0 + 0.2 }

        let result = try PCMNormalizer.normalize([
            CapturedAudioChunk(monoSamples: speech, sampleRate: 16_000)
        ])

        XCTAssertFalse(result.timing.isSilent)
        XCTAssertEqual(result.timing.removedDCOffset, 0.2, accuracy: 0.005)
        XCTAssertEqual(mean(result.values), 0, accuracy: 0.005)
    }

    func testLeadingAndTrailingSilenceAreTrimmedWithoutKeepingAudioContent() throws {
        let input = silence(sampleRate: 16_000, durationSeconds: 0.2)
            + sineWave(sampleRate: 16_000, durationSeconds: 0.4, amplitude: 0.08)
            + silence(sampleRate: 16_000, durationSeconds: 0.3)

        let result = try PCMNormalizer.normalize([
            CapturedAudioChunk(monoSamples: input, sampleRate: 16_000)
        ])

        XCTAssertFalse(result.timing.isSilent)
        XCTAssertEqual(result.timing.leadingSilenceTrimmedSeconds, 0.05, accuracy: 0.021)
        XCTAssertEqual(result.timing.trailingSilenceTrimmedSeconds, 0.15, accuracy: 0.021)
        XCTAssertEqual(result.timing.processedDurationSeconds, 0.7, accuracy: 0.021)
    }

    func testWhisperLevelSpeechIsKeptAndGentlyNormalized() throws {
        let input = silence(sampleRate: 16_000, durationSeconds: 0.1)
            + sineWave(sampleRate: 16_000, durationSeconds: 0.35, amplitude: 0.006)
            + silence(sampleRate: 16_000, durationSeconds: 0.1)

        let result = try PCMNormalizer.normalize([
            CapturedAudioChunk(monoSamples: input, sampleRate: 16_000)
        ])

        XCTAssertFalse(result.timing.isSilent)
        XCTAssertGreaterThan(result.timing.appliedGain, 1)
        XCTAssertLessThanOrEqual(result.timing.appliedGain, 12)
        XCTAssertGreaterThan(result.values.reduce(Float(0)) { max($0, abs($1)) }, 0.015)
        XCTAssertGreaterThan(result.timing.normalizedRMS, result.timing.inputRMS)
        XCTAssertEqual(
            result.timing.normalizedPeak,
            result.values.reduce(Float(0)) { max($0, abs($1)) },
            accuracy: 0.000_001
        )
    }

    func testContinuousLowLevelSpeechWithoutSilenceIsKept() throws {
        let amplitudes: [Float] = [
            0.004, 0.006, 0.008, 0.005,
            0.007, 0.004, 0.008, 0.006,
            0.005, 0.007, 0.004, 0.008
        ]
        let input = amplitudes.flatMap { amplitude in
            sineWave(
                sampleRate: 16_000,
                durationSeconds: 0.1,
                amplitude: amplitude
            )
        }

        let result = try PCMNormalizer.normalize([
            CapturedAudioChunk(monoSamples: input, sampleRate: 16_000)
        ])

        XCTAssertFalse(result.timing.isSilent)
        XCTAssertGreaterThanOrEqual(result.timing.detectedSpeechDurationSeconds, 0.25)
        XCTAssertFalse(result.values.isEmpty)
    }

    func testContinuousStationaryLowLevelNoiseIsStillRejected() throws {
        let input = sineWave(
            sampleRate: 16_000,
            durationSeconds: 1.2,
            amplitude: 0.004
        )

        let result = try PCMNormalizer.normalize([
            CapturedAudioChunk(monoSamples: input, sampleRate: 16_000)
        ])

        XCTAssertTrue(result.timing.isSilent)
        XCTAssertTrue(result.values.isEmpty)
        XCTAssertGreaterThan(result.timing.inputRMS, 0)
        XCTAssertGreaterThan(result.timing.inputPeak, 0)
    }

    func testContinuousVoiceLikeSignalWithFlatWindowEnergyIsKept() throws {
        let sampleRate = 16_000
        let sampleCount = Int(Double(sampleRate) * 0.6)
        let input = (0..<sampleCount).map { index -> Float in
            index.isMultiple(of: 10) ? 0.004 : 0
        }

        let result = try PCMNormalizer.normalize([
            CapturedAudioChunk(monoSamples: input, sampleRate: Double(sampleRate))
        ])

        XCTAssertFalse(result.timing.isSilent)
        XCTAssertEqual(result.timing.detectedSpeechDurationSeconds, 0.6, accuracy: 0.001)
        XCTAssertFalse(result.values.isEmpty)
    }

    func testIsolatedImpulseIsNotPromotedToSpeechByVoiceLikeFallback() throws {
        var input = Array(repeating: Float(0), count: 16_000)
        input[8_000] = 0.2

        let result = try PCMNormalizer.normalize([
            CapturedAudioChunk(monoSamples: input, sampleRate: 16_000)
        ])

        XCTAssertTrue(result.timing.isSilent)
        XCTAssertTrue(result.values.isEmpty)
    }

    func testIsolatedEdgeNoiseDoesNotStretchFinalASRAudio() throws {
        let sampleRate = 16_000.0
        var input = silence(sampleRate: sampleRate, durationSeconds: 3.0)
        input.overlay(
            sineWave(sampleRate: sampleRate, durationSeconds: 0.02, amplitude: 0.04),
            at: Int(sampleRate * 0.8)
        )
        input += sineWave(sampleRate: sampleRate, durationSeconds: 0.5, amplitude: 0.08)
        input += silence(sampleRate: sampleRate, durationSeconds: 3.0)
        input.overlay(
            sineWave(sampleRate: sampleRate, durationSeconds: 0.02, amplitude: 0.04),
            at: input.count - Int(sampleRate * 0.7)
        )

        let result = try PCMNormalizer.normalize([
            CapturedAudioChunk(monoSamples: input, sampleRate: sampleRate)
        ])

        XCTAssertFalse(result.timing.isSilent)
        XCTAssertGreaterThan(result.timing.leadingSilenceTrimmedSeconds, 2.8)
        XCTAssertGreaterThan(result.timing.trailingSilenceTrimmedSeconds, 2.8)
        XCTAssertLessThan(result.timing.processedDurationSeconds, 0.9)
        XCTAssertEqual(result.timing.detectedSpeechDurationSeconds, 0.5, accuracy: 0.041)
    }

    func testInternalPauseIsPreservedBetweenSpeechEdges() throws {
        let input = silence(sampleRate: 16_000, durationSeconds: 0.1)
            + sineWave(sampleRate: 16_000, durationSeconds: 0.3, amplitude: 0.08)
            + silence(sampleRate: 16_000, durationSeconds: 0.25)
            + sineWave(sampleRate: 16_000, durationSeconds: 0.3, amplitude: 0.08)
            + silence(sampleRate: 16_000, durationSeconds: 0.1)

        let result = try PCMNormalizer.normalize([
            CapturedAudioChunk(monoSamples: input, sampleRate: 16_000)
        ])

        XCTAssertFalse(result.timing.isSilent)
        XCTAssertEqual(result.timing.processedDurationSeconds, 1.05, accuracy: 0.041)
        XCTAssertEqual(result.timing.detectedSpeechDurationSeconds, 0.6, accuracy: 0.041)
    }

    func testLessThanMinimumSpeechIsMarkedSilentAndEmpty() throws {
        let input = silence(sampleRate: 16_000, durationSeconds: 0.1)
            + sineWave(sampleRate: 16_000, durationSeconds: 0.08, amplitude: 0.08)
            + silence(sampleRate: 16_000, durationSeconds: 0.1)

        let result = try PCMNormalizer.normalize([
            CapturedAudioChunk(monoSamples: input, sampleRate: 16_000)
        ])

        XCTAssertTrue(result.values.isEmpty)
        XCTAssertTrue(result.timing.isSilent)
        XCTAssertEqual(result.timing.detectedSpeechDurationSeconds, 0)
        XCTAssertEqual(result.timing.originalDurationSeconds, 0.28, accuracy: 0.001)
    }

    func testShortQuietUtteranceAboveMinimumIsKept() throws {
        let belowMinimumInput = silence(sampleRate: 16_000, durationSeconds: 0.04)
            + sineWave(sampleRate: 16_000, durationSeconds: 0.16, amplitude: 0.002)
            + silence(sampleRate: 16_000, durationSeconds: 0.04)
        let belowMinimumResult = try PCMNormalizer.normalize([
            CapturedAudioChunk(monoSamples: belowMinimumInput, sampleRate: 16_000)
        ])

        XCTAssertTrue(belowMinimumResult.timing.isSilent)
        XCTAssertTrue(belowMinimumResult.values.isEmpty)

        let input = silence(sampleRate: 16_000, durationSeconds: 0.04)
            + sineWave(sampleRate: 16_000, durationSeconds: 0.32, amplitude: 0.002)
            + silence(sampleRate: 16_000, durationSeconds: 0.04)

        let result = try PCMNormalizer.normalize([
            CapturedAudioChunk(monoSamples: input, sampleRate: 16_000)
        ])

        XCTAssertFalse(result.timing.isSilent)
        XCTAssertFalse(result.values.isEmpty)
        XCTAssertGreaterThanOrEqual(result.timing.detectedSpeechDurationSeconds, 0.25)
    }

    func testRouteChangeChunksWithDifferentSampleRatesArePreserved() throws {
        let first = sineWave(sampleRate: 48_000, durationSeconds: 0.18, amplitude: 0.05)
        let second = sineWave(sampleRate: 24_000, durationSeconds: 0.18, amplitude: 0.05)
        let firstRealtimeChunks = stride(from: 0, to: first.count, by: 512).map { start in
            CapturedAudioChunk(
                monoSamples: Array(first[start..<min(start + 512, first.count)]),
                sampleRate: 48_000
            )
        }
        let secondRealtimeChunks = stride(from: 0, to: second.count, by: 512).map { start in
            CapturedAudioChunk(
                monoSamples: Array(second[start..<min(start + 512, second.count)]),
                sampleRate: 24_000
            )
        }

        let result = try PCMNormalizer.normalize(firstRealtimeChunks + secondRealtimeChunks)

        XCTAssertFalse(result.timing.isSilent)
        XCTAssertEqual(result.sampleRate, 16_000)
        XCTAssertEqual(result.timing.originalDurationSeconds, 0.36, accuracy: 0.001)
        XCTAssertEqual(result.values.count, 5_760, accuracy: 4)
    }

    func testStreamingChunkResamplesWithoutApplyingFinalVADCutoff() throws {
        let input = sineWave(
            sampleRate: 48_000,
            durationSeconds: 0.1,
            amplitude: 0.08
        ).map { $0 + 0.2 }

        let result = try PCMNormalizer.prepareStreamingChunk(
            CapturedAudioChunk(monoSamples: input, sampleRate: 48_000)
        )

        XCTAssertEqual(result.sampleRate, 16_000)
        XCTAssertEqual(result.channelCount, 1)
        XCTAssertFalse(result.isFinal)
        XCTAssertGreaterThan(result.samples.count, 1_200)
        XCTAssertLessThan(result.samples.count, 2_000)
        XCTAssertEqual(mean(result.samples), 0, accuracy: 0.01)
    }

    private func silence(sampleRate: Double, durationSeconds: Double) -> [Float] {
        Array(repeating: 0, count: Int((sampleRate * durationSeconds).rounded()))
    }

    private func sineWave(
        sampleRate: Double,
        durationSeconds: Double,
        amplitude: Float,
        frequency: Double = 440
    ) -> [Float] {
        let count = Int((sampleRate * durationSeconds).rounded())
        return (0..<count).map { index in
            amplitude * Float(sin((2 * Double.pi * frequency * Double(index)) / sampleRate))
        }
    }

    private func mean(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return samples.reduce(0, +) / Float(samples.count)
    }
}

private extension Array where Element == Float {
    mutating func overlay(_ samples: [Float], at offset: Int) {
        guard offset >= 0 else { return }
        for index in samples.indices where offset + index < count {
            self[offset + index] += samples[index]
        }
    }
}
