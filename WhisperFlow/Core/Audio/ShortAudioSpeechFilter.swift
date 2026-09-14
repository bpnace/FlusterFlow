@preconcurrency import AVFoundation
@preconcurrency import SoundAnalysis
import Foundation
import Synchronization

/// Rejects noise which energy-based VAD can mistake for speech.
/// Unknown results fail open; sub-window utterances remain unchanged.
enum ShortAudioSpeechFilter {
    private static let analysisChunkDurationSeconds = 1.0
    private static let analysisWindowDurationSeconds = 0.5
    private static let noiseConfidenceThreshold = 0.5

    static func filter(
        _ audio: AudioSamples,
        shouldCancel: @Sendable () -> Bool = { Task.isCancelled }
    ) -> AudioSamples {
        let duration = Double(audio.values.count) / Double(audio.sampleRate)
        guard duration >= 0.5,
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(audio.sampleRate), channels: 1),
              audio.sampleRate > 0 else { return audio }

        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTime(
                seconds: analysisWindowDurationSeconds,
                preferredTimescale: Int32(audio.sampleRate)
            )
            let observer = SpeechObserver()
            let analyzer = SNAudioStreamAnalyzer(format: format)
            try analyzer.add(request, withObserver: observer)
            defer { analyzer.removeAllRequests() }

            let chunkFrameCount = max(
                1,
                Int((Double(audio.sampleRate) * analysisChunkDurationSeconds).rounded())
            )
            var framePosition = 0
            while framePosition < audio.values.count {
                guard !shouldCancel() else { return audio }
                let frameCount = min(chunkFrameCount, audio.values.count - framePosition)
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(frameCount)
                ), let channel = buffer.floatChannelData?[0] else {
                    return audio
                }
                buffer.frameLength = AVAudioFrameCount(frameCount)
                audio.values.withUnsafeBufferPointer { source in
                    if let base = source.baseAddress {
                        channel.update(
                            from: base.advanced(by: framePosition),
                            count: frameCount
                        )
                    }
                }
                analyzer.analyze(
                    buffer,
                    atAudioFramePosition: AVAudioFramePosition(framePosition)
                )
                if observer.hasConfidentSpeech {
                    return audio
                }
                guard !observer.failed else { return audio }
                framePosition += frameCount
            }

            guard !shouldCancel() else { return audio }
            analyzer.completeAnalysis()
            guard observer.completed.wait(timeout: .now() + 2) == .success,
                  !shouldCancel(),
                  observer.rejectsAsNoise(noiseThreshold: noiseConfidenceThreshold) else {
                return audio
            }
            let timing = audio.timing
            return AudioSamples(values: [], sampleRate: audio.sampleRate, timing: AudioTimingMetadata(
                originalDurationSeconds: timing.originalDurationSeconds,
                processedDurationSeconds: 0,
                leadingSilenceTrimmedSeconds: timing.leadingSilenceTrimmedSeconds,
                trailingSilenceTrimmedSeconds: timing.trailingSilenceTrimmedSeconds,
                detectedSpeechDurationSeconds: 0, isSilent: true,
                removedDCOffset: timing.removedDCOffset, appliedGain: timing.appliedGain,
                vadProcessingMilliseconds: timing.vadProcessingMilliseconds,
                inputRMS: timing.inputRMS, inputPeak: timing.inputPeak
            ))
        } catch {
            return audio
        }
    }
}

private final class SpeechObserver: NSObject, SNResultsObserving {
    let completed = DispatchSemaphore(value: 0)
    private let state = Mutex((windows: 0, maximumSpeech: 0.0, failed: false))

    var hasConfidentSpeech: Bool {
        state.withLock { !$0.failed && $0.maximumSpeech >= Self.speechConfidenceThreshold }
    }

    var failed: Bool {
        state.withLock { $0.failed }
    }

    func rejectsAsNoise(noiseThreshold: Double) -> Bool {
        state.withLock {
            !$0.failed && $0.windows >= 2 && $0.maximumSpeech < noiseThreshold
        }
    }

    private static let speechConfidenceThreshold = 0.5

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classification = result as? SNClassificationResult else { return }
        let speech = classification.classifications.filter {
            $0.identifier == "speech" || $0.identifier == "whispering"
        }
        guard speech.count == 2 else {
            state.withLock { $0.failed = true }
            return
        }
        state.withLock { state in
            state.windows += 1
            state.maximumSpeech = max(state.maximumSpeech, speech.map(\.confidence).max() ?? 1)
        }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        state.withLock { $0.failed = true }
        completed.signal()
    }

    func requestDidComplete(_ request: SNRequest) {
        completed.signal()
    }
}
