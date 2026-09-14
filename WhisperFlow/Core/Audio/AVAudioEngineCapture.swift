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
    case captureBufferOverflow
    case audioStorageFailed
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
    // Kept for source compatibility with the bounded utility below. Live
    // capture deliberately has no duration cap; its storage is file-backed.
    static let maximumCaptureDurationSeconds: TimeInterval = 120
    static let realtimeQueueCapacitySeconds: TimeInterval = 2
    static let maximumStreamingBatchDurationSeconds: TimeInterval = 2

    private let store: AudioBufferStore
    private let authorization: any MicrophoneAuthorizing
    private let notificationCenter: NotificationCenter

    private var engine: AVAudioEngine?
    private var spool: AudioCaptureSpool?
    private var activeQueue: RealtimeAudioFrameQueue?
    private var activeWriter: Task<Void, Never>?
    private var activeSessionID: DictationSessionID?
    private var nextGeneration: UInt64 = 0
    private var activeGeneration: UInt64?
    private var segmentDrainTask: Task<AudioCaptureSpoolError?, Never>?
    private var segmentDrainGeneration: UInt64?
    private var speechFilterTask: Task<AudioSamples, Never>?
    private var speechFilterGeneration: UInt64?
    private var configurationObserver: (any NSObjectProtocol)?
    private var terminalError: AudioCaptureError?
    private var isFinalizing = false
    private var cancellationRequestedGeneration: UInt64?
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
        guard activeSessionID == nil, segmentDrainTask == nil else {
            throw AudioCaptureError.captureAlreadyActive
        }
        nextGeneration &+= 1
        let generation = nextGeneration
        activeSessionID = sessionID
        activeGeneration = generation
        terminalError = nil
        isFinalizing = false
        cancellationRequestedGeneration = nil
        var sessionSpool: AudioCaptureSpool?
        do {
            let authorized = await authorization.authorizationStatus() == .authorized
            guard isCurrentSession(sessionID, generation: generation) else {
                throw AudioCaptureError.captureNotActive
            }
            guard authorized else {
                throw AudioCaptureError.microphonePermissionDenied
            }
            let createdSpool = try AudioCaptureSpool()
            sessionSpool = createdSpool
            spool = createdSpool
            try await activateEngine(
                for: sessionID,
                generation: generation
            )
            guard isCurrentSession(sessionID, generation: generation) else {
                throw AudioCaptureError.captureNotActive
            }
            terminalError = nil
        } catch let error as AudioCaptureError {
            if isCurrentSession(sessionID, generation: generation) {
                try? sessionSpool?.discard()
                clearSession()
            } else {
                try? sessionSpool?.discard()
            }
            throw error
        } catch {
            if isCurrentSession(sessionID, generation: generation) {
                try? sessionSpool?.discard()
                clearSession()
            } else {
                try? sessionSpool?.discard()
            }
            throw mapSpoolError(error)
        }
    }

    func finishCapture(for sessionID: DictationSessionID) async throws -> AudioInput {
        guard activeSessionID == sessionID else {
            throw AudioCaptureError.captureNotActive
        }

        guard let generation = activeGeneration else {
            throw AudioCaptureError.captureNotActive
        }
        isFinalizing = true
        let sessionSpool = spool
        await stopCurrentSegment()
        guard isCurrentSession(sessionID, generation: generation),
              cancellationRequestedGeneration != generation else {
            try? sessionSpool?.discard()
            throw AudioCaptureError.captureNotActive
        }
        removeConfigurationObserver()
        defer {
            try? sessionSpool?.discard()
            if isCurrentSession(sessionID, generation: generation),
               cancellationRequestedGeneration != generation {
                clearSession()
            }
        }

        do {
            if let terminalError { throw terminalError }
            guard let sessionSpool else {
                throw AudioCaptureError.audioStorageFailed
            }
            let normalized = try PCMNormalizer.normalize(
                sessionSpool.readAllChunks()
            )
            let filterTask = Task.detached(priority: .userInitiated) {
                ShortAudioSpeechFilter.filter(
                    normalized,
                    shouldCancel: { Task.isCancelled }
                )
            }
            speechFilterTask = filterTask
            speechFilterGeneration = generation
            defer { cancelSpeechFilter(for: generation) }
            let filtered = await withTaskCancellationHandler(operation: {
                await filterTask.value
            }, onCancel: {
                filterTask.cancel()
            })
            guard !Task.isCancelled,
                  isCurrentSession(sessionID, generation: generation),
                  cancellationRequestedGeneration != generation else {
                throw AudioCaptureError.captureNotActive
            }
            return await store.store(filtered)
        } catch let error as AudioCaptureError {
            throw error
        } catch let error as AudioCaptureSpoolError {
            throw mapSpoolError(error)
        } catch {
            throw AudioCaptureError.normalizationFailed
        }
    }

    func incrementalAudioBatch(
        for sessionID: DictationSessionID,
        afterFrameOffset frameOffset: Int
    ) async throws -> IncrementalAudioBatch? {
        guard activeSessionID == sessionID, let spool else {
            return nil
        }
        if let terminalError { throw terminalError }
        if let queueFailure = activeQueue?.failure {
            throw mapQueueFailure(queueFailure)
        }
        let batch: AudioSpoolBatch?
        do {
            batch = try spool.readBatch(
                afterFrameOffset: frameOffset,
                minimumDurationSeconds: 0.5,
                maximumDurationSeconds: Self.maximumStreamingBatchDurationSeconds
            )
        } catch let error as AudioCaptureSpoolError {
            throw mapSpoolError(error)
        }
        guard let batch else { return nil }
        var samples: [Float] = []
        samples.reserveCapacity(batch.frameCount)
        var sampleRate = AudioSamples.recognizerSampleRate
        for rawChunk in batch.chunks {
            let chunk = try PCMNormalizer.prepareStreamingChunk(rawChunk)
            sampleRate = chunk.sampleRate
            samples.append(contentsOf: chunk.samples)
        }
        guard !samples.isEmpty else { return nil }
        return IncrementalAudioBatch(
            chunk: RecognitionAudioChunk(
                samples: samples,
                sampleRate: sampleRate,
                channelCount: 1
            ),
            nextFrameOffset: batch.nextFrameOffset
        )
    }

    func cancelCapture(for sessionID: DictationSessionID) async {
        guard activeSessionID == sessionID,
              let generation = activeGeneration else { return }
        cancellationRequestedGeneration = generation
        cancelSpeechFilter(for: generation)
        let sessionSpool = spool
        await stopCurrentSegment()
        guard isCurrentSession(sessionID, generation: generation) else { return }
        removeConfigurationObserver()
        try? sessionSpool?.discard()
        clearSession()
    }

    func release(_ input: AudioInput) async {
        await store.release(input)
    }

    private func recoverFromConfigurationChange(
        for sessionID: DictationSessionID,
        generation: UInt64
    ) async {
        guard isCurrentSession(sessionID, generation: generation),
              !isFinalizing,
              cancellationRequestedGeneration != generation,
              !isRecoveringConfiguration else {
            return
        }
        isRecoveringConfiguration = true
        defer {
            if isCurrentSession(sessionID, generation: generation) {
                isRecoveringConfiguration = false
            }
        }

        await stopCurrentSegment()
        guard isCurrentSession(sessionID, generation: generation),
              !isFinalizing,
              cancellationRequestedGeneration != generation else {
            return
        }
        removeConfigurationObserver()
        engine = nil

        if terminalError == .deviceConfigurationChanged {
            terminalError = nil
        }
        guard terminalError == nil else { return }
        do {
            try await activateEngine(
                for: sessionID,
                generation: generation
            )
            guard isCurrentSession(sessionID, generation: generation),
                  !isFinalizing,
                  cancellationRequestedGeneration != generation else {
                return
            }
            terminalError = nil
        } catch let error as AudioCaptureError {
            if isCurrentSession(sessionID, generation: generation) {
                terminalError = error
            }
        } catch {
            if isCurrentSession(sessionID, generation: generation) {
                terminalError = mapSpoolError(error)
            }
        }
    }

    private func activateEngine(for sessionID: DictationSessionID) async throws {
        guard let generation = activeGeneration else {
            throw AudioCaptureError.captureNotActive
        }
        try await activateEngine(for: sessionID, generation: generation)
    }

    private func activateEngine(
        for sessionID: DictationSessionID,
        generation: UInt64
    ) async throws {
        guard isCurrentSession(sessionID, generation: generation),
              !isFinalizing,
              cancellationRequestedGeneration != generation else {
            throw AudioCaptureError.captureNotActive
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.inputUnavailable
        }
        guard activeQueue == nil,
              activeWriter == nil,
              let spool,
              let queue = RealtimeAudioFrameQueue(
            sampleRate: inputFormat.sampleRate,
            channelCount: Int(inputFormat.channelCount),
            capacitySeconds: Self.realtimeQueueCapacitySeconds
        ) else {
            throw AudioCaptureError.audioStorageFailed
        }
        try spool.startSegment(sampleRate: inputFormat.sampleRate)
        let writer = spool.startWriter(for: queue)

        input.installTap(onBus: 0, bufferSize: 512, format: inputFormat) { buffer, _ in
            _ = queue.append(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            queue.seal()
            await writer.value
            spool.endSegment()
            if engine.isRunning {
                engine.stop()
            }
            throw AudioCaptureError.inputUnavailable
        }

        guard isCurrentSession(sessionID, generation: generation) else {
            input.removeTap(onBus: 0)
            queue.seal()
            await writer.value
            spool.endSegment()
            if engine.isRunning {
                engine.stop()
            }
            throw AudioCaptureError.captureNotActive
        }

        self.engine = engine
        activeQueue = queue
        activeWriter = writer
        tapInstalled = true
        configurationObserver = notificationCenter.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Task {
                try? await Task.sleep(for: .milliseconds(100))
                await self?.recoverFromConfigurationChange(
                    for: sessionID,
                    generation: generation
                )
            }
        }
    }

    private func stopCurrentSegment() async {
        let generation = activeGeneration

        if let drainTask = segmentDrainTask {
            let failure = await drainTask.value
            if let segmentDrainGeneration,
               segmentDrainGeneration == generation,
               isCurrentGeneration(segmentDrainGeneration) {
                if let failure {
                    terminalError = mapSpoolError(failure)
                }
            }
            return
        }

        // Take ownership of the current segment before the first await. A
        // concurrent cancel/finish can then await the same drain task without
        // clearing a newer session's engine or queue on resumption.
        let ownedQueue = activeQueue
        let ownedWriter = activeWriter
        let ownedSpool = spool

        if let engine {
            if tapInstalled {
                // Remove the tap before stopping the engine, then seal the
                // queue to close the race with an already-running callback.
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            activeQueue?.seal()
            if engine.isRunning {
                engine.stop()
            }
        } else {
            activeQueue?.seal()
        }

        // Clear published segment references before awaiting disk drain. Any
        // later segment belongs to a different generation and cannot be
        // overwritten by this stop operation.
        self.engine = nil
        activeQueue = nil
        activeWriter = nil
        tapInstalled = false

        guard let queue = ownedQueue,
              let writer = ownedWriter,
              let ownedSpool else {
            return
        }

        let drainTask: Task<AudioCaptureSpoolError?, Never> = Task.detached(
            priority: .utility
        ) {
            do {
                try await ownedSpool.drain(queue: queue, writer: writer)
                return nil
            } catch let error as AudioCaptureSpoolError {
                return error
            } catch {
                return AudioCaptureSpoolError.writeFailed
            }
        }
        segmentDrainTask = drainTask
        segmentDrainGeneration = generation
        let failure = await drainTask.value
        ownedSpool.endSegment()
        if segmentDrainGeneration == generation {
            segmentDrainTask = nil
            segmentDrainGeneration = nil
        }
        if let generation,
           isCurrentGeneration(generation),
           let failure {
            terminalError = mapSpoolError(failure)
        }
    }

    private func removeConfigurationObserver() {
        if let configurationObserver {
            notificationCenter.removeObserver(configurationObserver)
        }
        configurationObserver = nil
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

    nonisolated static func finalizationError(
        for spoolFailure: AudioCaptureSpoolError?,
        terminalError: AudioCaptureError?
    ) -> AudioCaptureError? {
        if let terminalError { return terminalError }
        switch spoolFailure {
        case .queueOverflow: return .captureBufferOverflow
        case .formatChanged: return .deviceConfigurationChanged
        case .writeFailed, .readFailed, .corruptFile, .invalidConfiguration,
             .cannotCreateFile:
            return .audioStorageFailed
        case nil: return nil
        }
    }

    private func mapSpoolError(_ error: Error) -> AudioCaptureError {
        guard let spoolError = error as? AudioCaptureSpoolError else {
            return .audioStorageFailed
        }
        return Self.finalizationError(for: spoolError, terminalError: nil)
            ?? .audioStorageFailed
    }

    private func mapQueueFailure(
        _ failure: RealtimeAudioFrameQueue.Failure
    ) -> AudioCaptureError {
        switch failure {
        case .overflow: return .captureBufferOverflow
        case .storageFailed, .unsupportedBuffer: return .audioStorageFailed
        case .formatChanged: return .deviceConfigurationChanged
        }
    }

    private func clearSession() {
        if let generation = activeGeneration {
            cancelSpeechFilter(for: generation)
        }
        removeConfigurationObserver()
        engine = nil
        spool = nil
        activeQueue = nil
        activeWriter = nil
        activeSessionID = nil
        activeGeneration = nil
        terminalError = nil
        isFinalizing = false
        cancellationRequestedGeneration = nil
        tapInstalled = false
        isRecoveringConfiguration = false
    }

    private func cancelSpeechFilter(for generation: UInt64) {
        guard speechFilterGeneration == generation else { return }
        speechFilterTask?.cancel()
        speechFilterTask = nil
        speechFilterGeneration = nil
    }

    private func isCurrentSession(
        _ sessionID: DictationSessionID,
        generation: UInt64
    ) -> Bool {
        activeSessionID == sessionID && activeGeneration == generation
    }

    private func isCurrentGeneration(_ generation: UInt64) -> Bool {
        activeGeneration == generation
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
