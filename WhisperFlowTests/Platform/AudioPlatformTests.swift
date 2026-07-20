import XCTest
@testable import WhisperFlow

final class AudioPlatformTests: XCTestCase, @unchecked Sendable {
    func testCaptureHasHardTwoMinuteMemoryBound() {
        XCTAssertEqual(AVAudioEngineCapture.maximumCaptureDurationSeconds, 120)
    }

    func testBufferStoreKeepsRecognizerSamplesInMemoryUntilRelease() async throws {
        let store = AudioBufferStore()
        let expected = AudioSamples(values: [0.25, -0.5, 0.75])

        let input = await store.store(expected)

        let actual = try await store.samples(for: input)
        let countBeforeRelease = await store.storedBufferCount()
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(countBeforeRelease, 1)

        await store.release(input)
        let countAfterRelease = await store.storedBufferCount()
        XCTAssertEqual(countAfterRelease, 0)
        do {
            _ = try await store.samples(for: input)
            XCTFail("Released audio must not remain readable")
        } catch {
            XCTAssertEqual(error as? AudioBufferStoreError, .missingBuffer)
        }
    }

    func testNormalizerResamplesToMonoSixteenKilohertz() throws {
        let source = sineWave(sampleRate: 48_000, durationSeconds: 0.5, amplitude: 0.2)

        let result = try PCMNormalizer.normalize([
            CapturedAudioChunk(monoSamples: source, sampleRate: 48_000)
        ])

        XCTAssertEqual(result.sampleRate, 16_000)
        XCTAssertEqual(result.channelCount, 1)
        XCTAssertEqual(result.values.count, 8_000, accuracy: 2)
        XCTAssertFalse(result.timing.isSilent)
        XCTAssertEqual(result.timing.originalDurationSeconds, 0.5, accuracy: 0.001)
        XCTAssertEqual(result.timing.processedDurationSeconds, 0.5, accuracy: 0.001)
        XCTAssertGreaterThan(result.values.reduce(Float(0)) { max($0, abs($1)) }, 0.1)
    }

    func testNormalizerRejectsMidSessionFormatChanges() {
        XCTAssertThrowsError(
            try PCMNormalizer.normalize([
                CapturedAudioChunk(monoSamples: [0], sampleRate: 48_000),
                CapturedAudioChunk(monoSamples: [0], sampleRate: 44_100)
            ])
        ) { error in
            XCTAssertEqual(error as? PCMNormalizerError, .inconsistentInputRates)
        }
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
}
