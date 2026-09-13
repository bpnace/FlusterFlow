@preconcurrency import AVFoundation
import Darwin
import Foundation
import Synchronization

enum AudioCaptureError: Error, Equatable, Sendable {
    case microphonePermissionDenied
    case captureAlreadyActive
    case captureNotActive
    case inputUnavailable
    case deviceConfigurationChanged
    case maximumDurationExceeded
    case normalizationFailed
}

protocol MicrophoneAuthorizing: Sendable {
    func authorizationStatus() async -> AVAuthorizationStatus
    func requestAccess() async -> Bool
}

struct SystemMicrophoneAuthorization: MicrophoneAuthorizing {
    func authorizationStatus() async -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}

actor AVAudioEngineCapture: AudioCapturing, IncrementalAudioProviding {
    static let maximumCaptureDurationSeconds: TimeInterval = 120

    private let store: AudioBufferStore
    private let authorization: any MicrophoneAuthorizing
    private let notificationCenter: NotificationCenter

    private var engine: AVAudioEngine?
    private var accumulator: RealtimeCaptureBuffer?
    private var completedAccumulators: [RealtimeCaptureBuffer] = []
    private var activeSessionID: DictationSessionID?
    private var configurationObserver: (any NSObjectProtocol)?
    private var terminalError: AudioCaptureError?
    private var tapInstalled = false
    private var isRecoveringConfiguration = false

    init(
        store: AudioBufferStore,
        authorization: any MicrophoneAuthorizing = SystemMicrophoneAuthorization(),
        notificationCenter: NotificationCenter = .default
    ) {
        self.store = store
        self.authorization = authorization
        self.notificationCenter = notificationCenter
    }

    func startCapture(for sessionID: DictationSessionID) async throws {
        guard activeSessionID == nil else {
            throw AudioCaptureError.captureAlreadyActive
        }
        guard await authorization.authorizationStatus() == .authorized else {
            throw AudioCaptureError.microphonePermissionDenied
        }
        try activateEngine(for: sessionID)
        activeSessionID = sessionID
        terminalError = nil
    }

    func finishCapture(for sessionID: DictationSessionID) async throws -> AudioInput {
        guard activeSessionID == sessionID else {
            throw AudioCaptureError.captureNotActive
        }

        stopEngine()
        removeConfigurationObserver()
        defer { clearSession() }

        do {
            let snapshot = aggregateSnapshot()
            if let finalizationError = Self.finalizationError(
                for: snapshot,
                terminalError: terminalError
            ) {
                throw finalizationError
            }
            let normalized = try PCMNormalizer.normalize(snapshot.chunks)
            return await store.store(normalized)
        } catch let error as AudioCaptureError {
            throw error
        } catch {
            throw AudioCaptureError.normalizationFailed
        }
    }

    func incrementalAudioBatch(
        for sessionID: DictationSessionID,
        afterFrameOffset frameOffset: Int
    ) async throws -> IncrementalAudioBatch? {
        guard activeSessionID == sessionID, let accumulator else {
            return nil
        }
        let completedFrameOffset = completedCapturedFrameCount()
        let localFrameOffset = max(0, frameOffset - completedFrameOffset)
        guard let snapshot = accumulator.incrementalSnapshot(
            afterFrameOffset: localFrameOffset,
            minimumDurationSeconds: 0.5
        ) else {
            return nil
        }
        let chunk = try PCMNormalizer.prepareStreamingChunk(
            CapturedAudioChunk(
                monoSamples: snapshot.monoSamples,
                sampleRate: snapshot.sampleRate
            )
        )
        guard !chunk.samples.isEmpty else { return nil }
        return IncrementalAudioBatch(
            chunk: chunk,
            nextFrameOffset: completedFrameOffset + snapshot.nextFrameOffset
        )
    }

    func cancelCapture(for sessionID: DictationSessionID) async {
        guard activeSessionID == sessionID else { return }
        stopEngine()
        clearSession()
    }

    func release(_ input: AudioInput) async {
        await store.release(input)
    }

    private func recoverFromConfigurationChange(for sessionID: DictationSessionID) async {
        guard activeSessionID == sessionID, !isRecoveringConfiguration else {
            return
        }
        isRecoveringConfiguration = true
        defer { isRecoveringConfiguration = false }

        preserveCurrentAccumulator()
        stopEngine()
        removeConfigurationObserver()
        engine = nil

        do {
            try activateEngine(for: sessionID)
            terminalError = nil
        } catch let error as AudioCaptureError {
            terminalError = error
        } catch {
            terminalError = .inputUnavailable
        }
    }

    private func activateEngine(for sessionID: DictationSessionID) throws {
        let engine = AVAudioEngine()
        let remainingDuration = remainingCaptureDurationSeconds()
        guard remainingDuration > 0 else {
            throw AudioCaptureError.maximumDurationExceeded
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.inputUnavailable
        }
        guard let accumulator = RealtimeCaptureBuffer(
            sampleRate: inputFormat.sampleRate,
            channelCount: Int(inputFormat.channelCount),
            maximumDurationSeconds: remainingDuration
        ) else {
            throw AudioCaptureError.inputUnavailable
        }

        input.installTap(onBus: 0, bufferSize: 512, format: inputFormat) { buffer, _ in
            _ = accumulator.append(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            accumulator.seal()
            input.removeTap(onBus: 0)
            if engine.isRunning {
                engine.stop()
            }
            throw AudioCaptureError.inputUnavailable
        }

        self.engine = engine
        self.accumulator = accumulator
        tapInstalled = true
        configurationObserver = notificationCenter.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Task {
                try? await Task.sleep(for: .milliseconds(100))
                await self?.recoverFromConfigurationChange(for: sessionID)
            }
        }
    }

    private func stopEngine() {
        guard let engine else { return }
        accumulator?.seal()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
    }

    private func preserveCurrentAccumulator() {
        guard let accumulator else { return }
        accumulator.seal()
        completedAccumulators.append(accumulator)
        self.accumulator = nil
    }

    private func removeConfigurationObserver() {
        if let configurationObserver {
            notificationCenter.removeObserver(configurationObserver)
        }
        configurationObserver = nil
    }

    private func aggregateSnapshot() -> RealtimeCaptureBuffer.Snapshot {
        let snapshots = (completedAccumulators + [accumulator].compactMap { $0 })
            .map { $0.snapshot() }
        let chunks = snapshots.flatMap(\.chunks)
        let failures = snapshots.compactMap(\.failure)
        let failure = failures.first { $0 != .formatChanged }
            ?? (chunks.isEmpty && failures.contains(.formatChanged) ? .formatChanged : nil)
        return RealtimeCaptureBuffer.Snapshot(
            chunks: chunks,
            maximumDurationExceeded: snapshots.contains(where: \.maximumDurationExceeded),
            // A format change is expected when macOS moves the system input.
            // The closed segment stays valid and the new engine continues on
            // the new format, so this must not become a terminal session error.
            failure: failure,
            capturedFrameCount: snapshots.reduce(0) { $0 + $1.capturedFrameCount },
            capacity: snapshots.reduce(0) { $0 + $1.capacity }
        )
    }

    nonisolated static func finalizationError(
        for snapshot: RealtimeCaptureBuffer.Snapshot,
        terminalError: AudioCaptureError?
    ) -> AudioCaptureError? {
        if (snapshot.maximumDurationExceeded
            || snapshot.failure == .maximumDurationExceeded),
           snapshot.chunks.isEmpty {
            return .maximumDurationExceeded
        }
        switch snapshot.failure {
        case .maximumDurationExceeded:
            // The realtime buffer already contains the complete bounded prefix.
            // Finalize it instead of turning a healthy 120-second recording into loss.
            break
        case .unsupportedBuffer, .writerDidNotQuiesce:
            return .normalizationFailed
        case .formatChanged:
            return terminalError ?? (snapshot.chunks.isEmpty ? .deviceConfigurationChanged : nil)
        case nil:
            break
        }
        return terminalError
    }

    private func remainingCaptureDurationSeconds() -> TimeInterval {
        Self.maximumCaptureDurationSeconds - completedCaptureDurationSeconds()
    }

    private func completedCaptureDurationSeconds() -> TimeInterval {
        completedAccumulators
            .map { $0.snapshot() }
            .flatMap(\.chunks)
            .reduce(0) { duration, chunk in
                duration + (Double(chunk.monoSamples.count) / chunk.sampleRate)
            }
    }

    private func completedCapturedFrameCount() -> Int {
        completedAccumulators
            .map { $0.snapshot() }
            .reduce(0) { $0 + $1.capturedFrameCount }
    }

    private func clearSession() {
        removeConfigurationObserver()
        engine = nil
        accumulator = nil
        completedAccumulators.removeAll(keepingCapacity: false)
        activeSessionID = nil
        terminalError = nil
        tapInstalled = false
        isRecoveringConfiguration = false
    }

}

// AVAudioEngine invokes a tap serially. This is therefore a single-producer buffer:
// allocation happens before the tap is installed, and snapshot allocation happens
// only after seal/removeTap/stop has quiesced the producer.
final class RealtimeCaptureBuffer: @unchecked Sendable {
    enum AppendResult: Equatable, Sendable {
        case accepted
        case sealed
        case maximumDurationExceeded
        case formatChanged
        case unsupportedBuffer
    }

    enum Failure: Int, Equatable, Sendable {
        case maximumDurationExceeded = 1
        case formatChanged = 2
        case unsupportedBuffer = 3
        case writerDidNotQuiesce = 4
    }

    struct Snapshot {
        let chunks: [CapturedAudioChunk]
        let maximumDurationExceeded: Bool
        let failure: Failure?
        let capturedFrameCount: Int
        let capacity: Int
    }

    struct IncrementalSnapshot: Equatable, Sendable {
        let monoSamples: [Float]
        let sampleRate: Double
        let nextFrameOffset: Int
    }

    static let maximumSupportedSampleRate: Double = 192_000
    static let maximumSupportedChannelCount = 32
    static let maximumChannelSelectionSamples = 64

    private let sampleRate: Double
    private let channelCount: Int
    private let frameCapacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let acceptingWrites = Atomic<Bool>(true)
    private let activeWriterCount = Atomic<Int>(0)
    private let writtenFrameCount = Atomic<Int>(0)
    private let failureCode = Atomic<Int>(0)

    init?(
        sampleRate: Double,
        channelCount: Int,
        maximumDurationSeconds: TimeInterval
    ) {
        guard let capacity = Self.requiredCapacity(
            sampleRate: sampleRate,
            maximumDurationSeconds: maximumDurationSeconds
        ),
        channelCount > 0,
        channelCount <= Self.maximumSupportedChannelCount else {
            return nil
        }
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        frameCapacity = capacity
        storage = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
    }

    deinit {
        let initializedCount = writtenFrameCount.load(ordering: .relaxed)
        storage.deinitialize(count: initializedCount)
        storage.deallocate()
    }

    static func requiredCapacity(
        sampleRate: Double,
        maximumDurationSeconds: TimeInterval
    ) -> Int? {
        guard sampleRate.isFinite,
              sampleRate > 0,
              sampleRate <= maximumSupportedSampleRate,
              maximumDurationSeconds.isFinite,
              maximumDurationSeconds > 0 else {
            return nil
        }
        let frameCount = (sampleRate * maximumDurationSeconds).rounded(.down)
        guard frameCount >= 1, frameCount <= Double(Int.max) else {
            return nil
        }
        return Int(frameCount)
    }

    @inline(__always)
    func append(_ buffer: AVAudioPCMBuffer) -> AppendResult {
        guard acceptingWrites.load(ordering: .acquiring) else {
            return .sealed
        }
        activeWriterCount.wrappingAdd(1, ordering: .acquiringAndReleasing)
        guard acceptingWrites.load(ordering: .acquiring) else {
            activeWriterCount.wrappingSubtract(1, ordering: .releasing)
            return .sealed
        }

        let result = appendWhileActive(buffer)
        activeWriterCount.wrappingSubtract(1, ordering: .releasing)
        return result
    }

    @inline(__always)
    private func appendWhileActive(_ buffer: AVAudioPCMBuffer) -> AppendResult {
        if let failure = currentFailure() {
            return Self.appendResult(for: failure)
        }

        let frameCount = Int(buffer.frameLength)
        let format = buffer.format
        guard frameCount > 0,
              format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved,
              abs(format.sampleRate - sampleRate) < 0.5,
              Int(format.channelCount) == channelCount else {
            setFailure(.formatChanged)
            return .formatChanged
        }
        guard let channelData = buffer.floatChannelData else {
            setFailure(.unsupportedBuffer)
            return .unsupportedBuffer
        }

        let writeOffset = writtenFrameCount.load(ordering: .relaxed)
        guard frameCount <= frameCapacity - writeOffset else {
            setFailure(.maximumDurationExceeded)
            return .maximumDurationExceeded
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
            storage.advanced(by: writeOffset + frame).initialize(to: monoSample)
        }
        writtenFrameCount.store(writeOffset + frameCount, ordering: .releasing)
        return .accepted
    }

    func seal() {
        acceptingWrites.store(false, ordering: .releasing)
    }

    func snapshot() -> Snapshot {
        seal()
        var yieldCount = 0
        while activeWriterCount.load(ordering: .acquiring) != 0, yieldCount < 10_000 {
            sched_yield()
            yieldCount += 1
        }
        guard activeWriterCount.load(ordering: .acquiring) == 0 else {
            setFailure(.writerDidNotQuiesce)
            return Snapshot(
                chunks: [],
                maximumDurationExceeded: false,
                failure: .writerDidNotQuiesce,
                capturedFrameCount: 0,
                capacity: frameCapacity
            )
        }

        let count = writtenFrameCount.load(ordering: .acquiring)
        let failure = currentFailure()
        let samples = Array(UnsafeBufferPointer(start: storage, count: count))
        let chunks: [CapturedAudioChunk]
        if samples.isEmpty {
            chunks = []
        } else {
            chunks = [CapturedAudioChunk(monoSamples: samples, sampleRate: sampleRate)]
        }
        return Snapshot(
            chunks: chunks,
            maximumDurationExceeded: failure == .maximumDurationExceeded,
            failure: failure,
            capturedFrameCount: count,
            capacity: frameCapacity
        )
    }

    func incrementalSnapshot(
        afterFrameOffset frameOffset: Int,
        minimumDurationSeconds: TimeInterval = 0
    ) -> IncrementalSnapshot? {
        guard frameOffset >= 0,
              minimumDurationSeconds.isFinite,
              minimumDurationSeconds >= 0,
              currentFailure() == nil else {
            return nil
        }
        let count = writtenFrameCount.load(ordering: .acquiring)
        guard frameOffset <= count else { return nil }
        let availableFrameCount = count - frameOffset
        let minimumFrameCount = Int((sampleRate * minimumDurationSeconds).rounded(.up))
        guard availableFrameCount >= max(1, minimumFrameCount) else { return nil }

        let samples = Array(
            UnsafeBufferPointer(
                start: storage.advanced(by: frameOffset),
                count: availableFrameCount
            )
        )
        return IncrementalSnapshot(
            monoSamples: samples,
            sampleRate: sampleRate,
            nextFrameOffset: count
        )
    }

    @inline(__always)
    private func setFailure(_ failure: Failure) {
        _ = failureCode.compareExchange(
            expected: 0,
            desired: failure.rawValue,
            ordering: .acquiringAndReleasing
        )
    }

    @inline(__always)
    private func currentFailure() -> Failure? {
        Failure(rawValue: failureCode.load(ordering: .acquiring))
    }

    @inline(__always)
    private static func appendResult(for failure: Failure) -> AppendResult {
        switch failure {
        case .maximumDurationExceeded:
            return .maximumDurationExceeded
        case .formatChanged, .writerDidNotQuiesce:
            return .formatChanged
        case .unsupportedBuffer:
            return .unsupportedBuffer
        }
    }
}
