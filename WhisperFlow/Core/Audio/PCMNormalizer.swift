@preconcurrency import AVFoundation
import Foundation

struct CapturedAudioChunk: Sendable {
    let monoSamples: [Float]
    let sampleRate: Double
}

enum PCMNormalizerError: Error, Equatable, Sendable {
    case invalidSampleRate
    case inconsistentInputRates
    case conversionFailed
}

enum PCMNormalizer {
    // WhisperKit's final decoder needs at least a quarter second of detected
    // speech for a reliable first token. Keeping this gate aligned prevents a
    // short residual fragment from being admitted as speech and then decoded
    // as an empty transcription.
    private static let minimumSpeechDurationSeconds = 0.250
    private static let vadWindowSeconds = 0.020
    private static let vadContextPaddingSeconds = 0.150
    private static let vadMinimumRMS: Float = 0.0008
    private static let vadMinimumAdaptiveMarginRMS: Float = 0.00025
    private static let vadDynamicRangeFraction: Float = 0.35
    private static let vadMaximumAdaptiveRMS: Float = 0.02
    private static let vadMaximumSpeechIslandGapSeconds = 0.180
    private static let vadMinimumSpeechIslandSeconds = 0.100
    private static let vadVoiceLikeFallbackMinimumPeak: Float = 0.002
    private static let vadVoiceLikeFallbackMinimumCrestFactor: Float = 2.5
    private static let normalizationTargetRMS: Float = 0.08
    private static let normalizationTargetPeak: Float = 0.8
    private static let maximumGain: Float = 12

    static func normalize(
        _ chunks: [CapturedAudioChunk],
        outputSampleRate: Int = AudioSamples.recognizerSampleRate
    ) throws -> AudioSamples {
        guard outputSampleRate > 0 else {
            throw PCMNormalizerError.invalidSampleRate
        }
        guard !chunks.isEmpty else {
            return AudioSamples(values: [], sampleRate: outputSampleRate)
        }
        guard chunks.allSatisfy({ $0.sampleRate.isFinite && $0.sampleRate > 0 }) else {
            throw PCMNormalizerError.invalidSampleRate
        }

        let input = chunks.flatMap(\.monoSamples)
        let originalDurationSeconds = chunks.reduce(0) { duration, chunk in
            duration + (Double(chunk.monoSamples.count) / chunk.sampleRate)
        }
        guard !input.isEmpty else {
            return silentSamples(
                outputSampleRate: outputSampleRate,
                originalDurationSeconds: originalDurationSeconds,
                removedDCOffset: 0
            )
        }
        let dcOffset = mean(of: input)
        var resampled: [Float] = []
        resampled.reserveCapacity(
            Int((originalDurationSeconds * Double(outputSampleRate)).rounded(.up))
        )
        // AVAudioConverter is stateful. Coalesce the tiny, contiguous tap
        // buffers that share a sample rate so its filter state spans the
        // recording instead of restarting every 512 frames.
        for chunk in coalescedChunks(chunks) {
            let centered = chunk.monoSamples.map { sample in
                clamp(sample.isFinite ? sample - dcOffset : 0)
            }
            resampled.append(
                contentsOf: try resample(
                    centered,
                    inputSampleRate: chunk.sampleRate,
                    outputSampleRate: outputSampleRate
                )
            )
        }
        let vadClock = ContinuousClock()
        let vadStartedAt = vadClock.now
        let preVADRMS = rms(resampled[...])
        let preVADPeak = resampled.reduce(Float(0)) { max($0, abs($1)) }
        let analysis = analyzeSpeech(in: resampled, sampleRate: outputSampleRate)
        let vadProcessingMilliseconds = milliseconds(
            vadStartedAt.duration(to: vadClock.now)
        )
        guard analysis.detectedSpeechDurationSeconds >= minimumSpeechDurationSeconds,
              analysis.startIndex < analysis.endIndex else {
            return silentSamples(
                outputSampleRate: outputSampleRate,
                originalDurationSeconds: originalDurationSeconds,
                removedDCOffset: dcOffset,
                vadProcessingMilliseconds: vadProcessingMilliseconds,
                inputRMS: preVADRMS,
                inputPeak: preVADPeak
            )
        }

        let contextPadding = Int(
            (Double(outputSampleRate) * vadContextPaddingSeconds).rounded()
        )
        let paddedStartIndex = max(0, analysis.startIndex - contextPadding)
        let paddedEndIndex = min(resampled.count, analysis.endIndex + contextPadding)
        let trimmed = Array(resampled[paddedStartIndex..<paddedEndIndex])
        let inputRMS = rms(trimmed[...])
        let inputPeak = trimmed.reduce(Float(0)) { max($0, abs($1)) }
        let normalization = normalizeLevel(trimmed)
        let processedDurationSeconds = Double(normalization.samples.count) / Double(outputSampleRate)
        let timing = AudioTimingMetadata(
            originalDurationSeconds: originalDurationSeconds,
            processedDurationSeconds: processedDurationSeconds,
            leadingSilenceTrimmedSeconds: Double(paddedStartIndex) / Double(outputSampleRate),
            trailingSilenceTrimmedSeconds: Double(resampled.count - paddedEndIndex) / Double(outputSampleRate),
            detectedSpeechDurationSeconds: analysis.detectedSpeechDurationSeconds,
            isSilent: false,
            removedDCOffset: dcOffset,
            appliedGain: normalization.gain,
            vadProcessingMilliseconds: vadProcessingMilliseconds,
            inputRMS: inputRMS,
            inputPeak: inputPeak,
            normalizedRMS: rms(normalization.samples[...]),
            normalizedPeak: normalization.samples.reduce(Float(0)) {
                max($0, abs($1))
            }
        )

        return AudioSamples(
            values: normalization.samples,
            sampleRate: outputSampleRate,
            timing: timing
        )
    }

    static func prepareStreamingChunk(
        _ chunk: CapturedAudioChunk,
        outputSampleRate: Int = AudioSamples.recognizerSampleRate
    ) throws -> RecognitionAudioChunk {
        guard outputSampleRate > 0,
              chunk.sampleRate.isFinite,
              chunk.sampleRate > 0 else {
            throw PCMNormalizerError.invalidSampleRate
        }
        guard !chunk.monoSamples.isEmpty else {
            return RecognitionAudioChunk(
                samples: [],
                sampleRate: outputSampleRate,
                channelCount: 1
            )
        }

        let dcOffset = mean(of: chunk.monoSamples)
        let centered = chunk.monoSamples.map { sample in
            clamp(sample.isFinite ? sample - dcOffset : 0)
        }
        let resampled = try resample(
            centered,
            inputSampleRate: chunk.sampleRate,
            outputSampleRate: outputSampleRate
        )
        return RecognitionAudioChunk(
            samples: resampled,
            sampleRate: outputSampleRate,
            channelCount: 1
        )
    }

    private static func coalescedChunks(
        _ chunks: [CapturedAudioChunk]
    ) -> [CapturedAudioChunk] {
        guard let first = chunks.first else { return [] }

        var result: [CapturedAudioChunk] = []
        var currentSampleRate = first.sampleRate
        var currentSamples: [Float] = []
        currentSamples.reserveCapacity(first.monoSamples.count)

        for chunk in chunks {
            if abs(chunk.sampleRate - currentSampleRate) >= 0.5 {
                result.append(
                    CapturedAudioChunk(
                        monoSamples: currentSamples,
                        sampleRate: currentSampleRate
                    )
                )
                currentSampleRate = chunk.sampleRate
                currentSamples = []
                currentSamples.reserveCapacity(chunk.monoSamples.count)
            }
            currentSamples.append(contentsOf: chunk.monoSamples)
        }

        result.append(
            CapturedAudioChunk(
                monoSamples: currentSamples,
                sampleRate: currentSampleRate
            )
        )
        return result
    }

    private static func resample(
        _ input: [Float],
        inputSampleRate: Double,
        outputSampleRate: Int
    ) throws -> [Float] {
        guard abs(inputSampleRate - Double(outputSampleRate)) >= 0.5 else {
            return input
        }
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputSampleRate,
            channels: 1,
            interleaved: false
        ),
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(outputSampleRate),
            channels: 1,
            interleaved: false
        ),
        let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(input.count)
        ),
        let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw PCMNormalizerError.conversionFailed
        }

        inputBuffer.frameLength = AVAudioFrameCount(input.count)
        guard let inputChannel = inputBuffer.floatChannelData?[0] else {
            throw PCMNormalizerError.conversionFailed
        }
        for index in input.indices {
            inputChannel[index] = input[index]
        }

        let ratio = Double(outputSampleRate) / inputSampleRate
        let outputCapacity = max(1, Int((Double(input.count) * ratio).rounded(.up)) + 16)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(outputCapacity)
        ) else {
            throw PCMNormalizerError.conversionFailed
        }

        let inputState = ConverterInputState()
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if inputState.didProvideInput {
                outStatus.pointee = .endOfStream
                return nil
            }
            inputState.didProvideInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        guard conversionError == nil,
              status != .error,
              let outputChannel = outputBuffer.floatChannelData?[0] else {
            throw PCMNormalizerError.conversionFailed
        }

        let count = Int(outputBuffer.frameLength)
        return (0..<count).map { clamp(outputChannel[$0]) }
    }

    private struct SpeechAnalysis {
        let startIndex: Int
        let endIndex: Int
        let detectedSpeechDurationSeconds: Double
    }

    private static func analyzeSpeech(in samples: [Float], sampleRate: Int) -> SpeechAnalysis {
        guard !samples.isEmpty else {
            return SpeechAnalysis(startIndex: 0, endIndex: 0, detectedSpeechDurationSeconds: 0)
        }

        let windowSize = max(1, Int((Double(sampleRate) * vadWindowSeconds).rounded()))
        var rmsWindows: [(range: Range<Int>, rms: Float)] = []
        rmsWindows.reserveCapacity((samples.count / windowSize) + 1)
        var index = 0
        while index < samples.count {
            let end = min(index + windowSize, samples.count)
            rmsWindows.append((index..<end, rms(samples[index..<end])))
            index = end
        }

        let sortedRMS = rmsWindows.map(\.rms).sorted()
        let noiseSampleCount = max(1, sortedRMS.count / 5)
        let noiseFloor = sortedRMS.prefix(noiseSampleCount).reduce(Float(0), +) / Float(noiseSampleCount)
        let upperSignalLevel = sortedRMS.suffix(noiseSampleCount).reduce(Float(0), +)
            / Float(noiseSampleCount)
        let dynamicRange = max(0, upperSignalLevel - noiseFloor)
        let adaptiveMargin = max(
            vadMinimumAdaptiveMarginRMS,
            dynamicRange * vadDynamicRangeFraction
        )
        let adaptiveThreshold = min(
            noiseFloor + adaptiveMargin,
            vadMaximumAdaptiveRMS
        )
        let speechThreshold = max(vadMinimumRMS, adaptiveThreshold)
        let speechWindows = rmsWindows.filter { $0.rms >= speechThreshold }
        let speechIslands = significantSpeechIslands(
            from: speechWindows,
            sampleRate: sampleRate
        )
        guard let firstSpeech = speechIslands.first,
              let lastSpeech = speechIslands.last else {
            let voiceLikeWindows = rmsWindows.filter { window in
                guard window.rms >= vadMinimumRMS else { return false }
                let peak = samples[window.range].reduce(Float(0)) { max($0, abs($1)) }
                return peak >= max(
                    vadVoiceLikeFallbackMinimumPeak,
                    window.rms * vadVoiceLikeFallbackMinimumCrestFactor
                )
            }
            let voiceLikeIslands = significantSpeechIslands(
                from: voiceLikeWindows,
                sampleRate: sampleRate
            )
            let voiceLikeFrameCount = voiceLikeIslands.reduce(0) {
                $0 + $1.speechFrameCount
            }
            let voiceLikeDurationSeconds = Double(voiceLikeFrameCount) / Double(sampleRate)
            guard let firstVoiceLikeIsland = voiceLikeIslands.first,
                  let lastVoiceLikeIsland = voiceLikeIslands.last,
                  voiceLikeDurationSeconds >= minimumSpeechDurationSeconds else {
                return SpeechAnalysis(
                    startIndex: 0,
                    endIndex: 0,
                    detectedSpeechDurationSeconds: 0
                )
            }
            // Automatic microphone gain can make every analysis window look
            // equally loud. Requiring repeated speech-like crest windows
            // distinguishes that signal from stationary hum and isolated
            // clicks without needing a leading silence calibration period.
            return SpeechAnalysis(
                startIndex: firstVoiceLikeIsland.range.lowerBound,
                endIndex: lastVoiceLikeIsland.range.upperBound,
                detectedSpeechDurationSeconds: voiceLikeDurationSeconds
            )
        }

        let speechFrameCount = speechIslands.reduce(0) { count, island in
            count + island.speechFrameCount
        }
        return SpeechAnalysis(
            startIndex: firstSpeech.range.lowerBound,
            endIndex: lastSpeech.range.upperBound,
            detectedSpeechDurationSeconds: Double(speechFrameCount) / Double(sampleRate)
        )
    }

    private struct SpeechIsland {
        let range: Range<Int>
        let speechFrameCount: Int
    }

    private static func significantSpeechIslands(
        from windows: [(range: Range<Int>, rms: Float)],
        sampleRate: Int
    ) -> [SpeechIsland] {
        guard !windows.isEmpty else { return [] }

        let maximumGapFrames = Int(
            (Double(sampleRate) * vadMaximumSpeechIslandGapSeconds).rounded()
        )
        let minimumSpeechFrames = Int(
            (Double(sampleRate) * vadMinimumSpeechIslandSeconds).rounded(.up)
        )
        var islands: [SpeechIsland] = []
        var currentStart = windows[0].range.lowerBound
        var currentEnd = windows[0].range.upperBound
        var currentSpeechFrames = windows[0].range.count

        for window in windows.dropFirst() {
            if window.range.lowerBound - currentEnd <= maximumGapFrames {
                currentEnd = window.range.upperBound
                currentSpeechFrames += window.range.count
            } else {
                if currentSpeechFrames >= minimumSpeechFrames {
                    islands.append(
                        SpeechIsland(
                            range: currentStart..<currentEnd,
                            speechFrameCount: currentSpeechFrames
                        )
                    )
                }
                currentStart = window.range.lowerBound
                currentEnd = window.range.upperBound
                currentSpeechFrames = window.range.count
            }
        }

        if currentSpeechFrames >= minimumSpeechFrames {
            islands.append(
                SpeechIsland(
                    range: currentStart..<currentEnd,
                    speechFrameCount: currentSpeechFrames
                )
            )
        }
        return islands
    }

    private static func normalizeLevel(_ samples: [Float]) -> (samples: [Float], gain: Float) {
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 0 else {
            return (samples, 1)
        }

        let currentRMS = rms(samples[...])
        var gain: Float = 1
        if currentRMS > 0, currentRMS < normalizationTargetRMS {
            gain = min(maximumGain, normalizationTargetRMS / currentRMS)
        }
        gain = min(gain, normalizationTargetPeak / peak)

        guard abs(gain - 1) > 0.000_001 else {
            return (samples.map { clamp($0) }, 1)
        }
        return (samples.map { clamp($0 * gain) }, gain)
    }

    private static func silentSamples(
        outputSampleRate: Int,
        originalDurationSeconds: Double,
        removedDCOffset: Float,
        vadProcessingMilliseconds: Double = 0,
        inputRMS: Float = 0,
        inputPeak: Float = 0
    ) -> AudioSamples {
        AudioSamples(
            values: [],
            sampleRate: outputSampleRate,
            timing: AudioTimingMetadata(
                originalDurationSeconds: originalDurationSeconds,
                processedDurationSeconds: 0,
                leadingSilenceTrimmedSeconds: originalDurationSeconds,
                trailingSilenceTrimmedSeconds: 0,
                detectedSpeechDurationSeconds: 0,
                isSilent: true,
                removedDCOffset: removedDCOffset,
                appliedGain: 1,
                vadProcessingMilliseconds: vadProcessingMilliseconds,
                inputRMS: inputRMS,
                inputPeak: inputPeak
            )
        )
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return (Double(components.seconds) * 1_000)
            + (Double(components.attoseconds) / 1_000_000_000_000_000)
    }

    private static func mean(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Double(0)) { $0 + Double($1.isFinite ? $1 : 0) }
        return Float(sum / Double(samples.count))
    }

    private static func rms<Samples: Collection>(_ samples: Samples) -> Float where Samples.Element == Float {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(Double(0)) { partial, sample in
            let value = Double(sample.isFinite ? sample : 0)
            return partial + (value * value)
        }
        return Float((sumSquares / Double(samples.count)).squareRoot())
    }

    private static func clamp(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return max(-1, min(1, value))
    }
}

private final class ConverterInputState: @unchecked Sendable {
    var didProvideInput = false
}
