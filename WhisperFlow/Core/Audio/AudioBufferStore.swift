import Foundation

struct AudioSamples: Equatable, Sendable {
    static let recognizerSampleRate = 16_000

    let values: [Float]
    let sampleRate: Int
    let channelCount: Int
    let timing: AudioTimingMetadata

    init(
        values: [Float],
        sampleRate: Int = recognizerSampleRate,
        channelCount: Int = 1,
        timing: AudioTimingMetadata? = nil
    ) {
        self.values = values
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.timing = timing ?? AudioTimingMetadata(
            originalDurationSeconds: Double(values.count) / Double(max(sampleRate, 1)),
            processedDurationSeconds: Double(values.count) / Double(max(sampleRate, 1)),
            leadingSilenceTrimmedSeconds: 0,
            trailingSilenceTrimmedSeconds: 0,
            detectedSpeechDurationSeconds: values.isEmpty ? 0 : Double(values.count) / Double(max(sampleRate, 1)),
            isSilent: values.isEmpty,
            removedDCOffset: 0,
            appliedGain: 1,
            inputRMS: Self.rms(values),
            inputPeak: values.reduce(Float(0)) { max($0, abs($1)) },
            normalizedRMS: Self.rms(values),
            normalizedPeak: values.reduce(Float(0)) { max($0, abs($1)) }
        )
    }

    private static func rms(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sumSquares = values.reduce(Double(0)) { partial, sample in
            let finiteSample = sample.isFinite ? sample : 0
            return partial + (Double(finiteSample) * Double(finiteSample))
        }
        return Float((sumSquares / Double(values.count)).squareRoot())
    }
}

struct AudioTimingMetadata: Equatable, Sendable {
    let originalDurationSeconds: Double
    let processedDurationSeconds: Double
    let leadingSilenceTrimmedSeconds: Double
    let trailingSilenceTrimmedSeconds: Double
    let detectedSpeechDurationSeconds: Double
    let isSilent: Bool
    let removedDCOffset: Float
    let appliedGain: Float
    let vadProcessingMilliseconds: Double
    let inputRMS: Float
    let inputPeak: Float
    let normalizedRMS: Float
    let normalizedPeak: Float

    init(
        originalDurationSeconds: Double,
        processedDurationSeconds: Double,
        leadingSilenceTrimmedSeconds: Double,
        trailingSilenceTrimmedSeconds: Double,
        detectedSpeechDurationSeconds: Double,
        isSilent: Bool,
        removedDCOffset: Float,
        appliedGain: Float,
        vadProcessingMilliseconds: Double = 0,
        inputRMS: Float = 0,
        inputPeak: Float = 0,
        normalizedRMS: Float = 0,
        normalizedPeak: Float = 0
    ) {
        self.originalDurationSeconds = originalDurationSeconds
        self.processedDurationSeconds = processedDurationSeconds
        self.leadingSilenceTrimmedSeconds = leadingSilenceTrimmedSeconds
        self.trailingSilenceTrimmedSeconds = trailingSilenceTrimmedSeconds
        self.detectedSpeechDurationSeconds = detectedSpeechDurationSeconds
        self.isSilent = isSilent
        self.removedDCOffset = removedDCOffset
        self.appliedGain = appliedGain
        self.vadProcessingMilliseconds = max(0, vadProcessingMilliseconds)
        self.inputRMS = max(0, inputRMS.isFinite ? inputRMS : 0)
        self.inputPeak = max(0, inputPeak.isFinite ? inputPeak : 0)
        self.normalizedRMS = max(0, normalizedRMS.isFinite ? normalizedRMS : 0)
        self.normalizedPeak = max(0, normalizedPeak.isFinite ? normalizedPeak : 0)
    }
}

enum AudioBufferStoreError: Error, Equatable, Sendable {
    case missingBuffer
}

protocol AudioSampleAccessing: Sendable {
    func samples(for input: AudioInput) async throws -> AudioSamples
    func release(_ input: AudioInput) async
}

actor AudioBufferStore: AudioSampleAccessing {
    private var buffers: [AudioBufferHandle: AudioSamples] = [:]
    private var nextHandleValue: UInt64 = 0

    func store(_ samples: AudioSamples) -> AudioInput {
        nextHandleValue &+= 1
        let handle = AudioBufferHandle(rawValue: nextHandleValue)
        buffers[handle] = samples
        return AudioInput(buffer: handle, timing: samples.timing)
    }

    func samples(for input: AudioInput) throws -> AudioSamples {
        guard let samples = buffers[input.buffer] else {
            throw AudioBufferStoreError.missingBuffer
        }
        return samples
    }

    func release(_ input: AudioInput) {
        buffers[input.buffer] = nil
    }

    func removeAll() {
        buffers.removeAll(keepingCapacity: false)
    }

    func storedBufferCount() -> Int {
        buffers.count
    }
}
