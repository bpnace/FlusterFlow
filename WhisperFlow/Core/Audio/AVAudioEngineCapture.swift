@preconcurrency import AVFoundation
@preconcurrency import AudioToolbox
@preconcurrency import CoreAudio
import Darwin
import Foundation
import Synchronization

enum AudioCaptureError: Error, Equatable, Sendable {
    case microphonePermissionDenied
    case captureAlreadyActive
    case captureNotActive
    case inputUnavailable
    case selectedInputUnavailable
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
    private let selectedInputUID: @Sendable () async -> String?

    private var engine: AVAudioEngine?
    private var accumulator: RealtimeCaptureBuffer?
    private var activeSessionID: DictationSessionID?
    private var configurationObserver: (any NSObjectProtocol)?
    private var terminalError: AudioCaptureError?
    private var tapInstalled = false
    private var captureFormat: CaptureFormat?

    private struct CaptureFormat: Equatable, Sendable {
        let sampleRate: Double
        let channelCount: Int
    }

    init(
        store: AudioBufferStore,
        authorization: any MicrophoneAuthorizing = SystemMicrophoneAuthorization(),
        notificationCenter: NotificationCenter = .default,
        selectedInputUID: @escaping @Sendable () async -> String? = { nil }
    ) {
        self.store = store
        self.authorization = authorization
        self.notificationCenter = notificationCenter
        self.selectedInputUID = selectedInputUID
    }

    func startCapture(for sessionID: DictationSessionID) async throws {
        guard activeSessionID == nil else {
            throw AudioCaptureError.captureAlreadyActive
        }
        guard await authorization.authorizationStatus() == .authorized else {
            throw AudioCaptureError.microphonePermissionDenied
        }

        // A nil selection intentionally leaves the AVAudioEngine input device
        // untouched. CoreAudio then follows the current macOS system input,
        // including live switches between AirPods and the built-in microphone.
        let requestedUID = await selectedInputUID()
        try activateEngine(withUID: requestedUID, for: sessionID)
        activeSessionID = sessionID
        terminalError = nil
    }

    func finishCapture(for sessionID: DictationSessionID) async throws -> AudioInput {
        guard activeSessionID == sessionID, let accumulator else {
            throw AudioCaptureError.captureNotActive
        }

        stopEngine()
        defer { clearSession() }

        if let terminalError {
            throw terminalError
        }

        do {
            let snapshot = accumulator.snapshot()
            guard snapshot.failure == nil else {
                if snapshot.failure == .maximumDurationExceeded {
                    throw AudioCaptureError.maximumDurationExceeded
                }
                if snapshot.failure == .formatChanged {
                    throw AudioCaptureError.deviceConfigurationChanged
                }
                throw AudioCaptureError.normalizationFailed
            }
            guard !snapshot.maximumDurationExceeded else {
                throw AudioCaptureError.maximumDurationExceeded
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
        guard let snapshot = accumulator.incrementalSnapshot(
            afterFrameOffset: frameOffset,
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
            nextFrameOffset: snapshot.nextFrameOffset
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

    private func revalidateConfiguration(for sessionID: DictationSessionID) {
        guard activeSessionID == sessionID,
              let engine,
              let captureFormat else {
            return
        }
        let currentFormat = engine.inputNode.outputFormat(forBus: 0)
        guard Self.configurationChangeRequiresTermination(
            engineRunning: engine.isRunning,
            expectedSampleRate: captureFormat.sampleRate,
            expectedChannelCount: captureFormat.channelCount,
            currentSampleRate: currentFormat.sampleRate,
            currentChannelCount: Int(currentFormat.channelCount)
        ) else {
            return
        }
        terminalError = .deviceConfigurationChanged
        stopEngine()
    }

    private func activateEngine(
        withUID selectedUID: String?,
        for sessionID: DictationSessionID
    ) throws {
        let engine = AVAudioEngine()
        if let selectedUID {
            try Self.selectInputDevice(withUID: selectedUID, on: engine)
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.inputUnavailable
        }
        guard let accumulator = RealtimeCaptureBuffer(
            sampleRate: inputFormat.sampleRate,
            channelCount: Int(inputFormat.channelCount),
            maximumDurationSeconds: Self.maximumCaptureDurationSeconds
        ) else {
            throw AudioCaptureError.inputUnavailable
        }

        input.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { buffer, _ in
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
        captureFormat = CaptureFormat(
            sampleRate: inputFormat.sampleRate,
            channelCount: Int(inputFormat.channelCount)
        )
        tapInstalled = true
        configurationObserver = notificationCenter.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Task {
                try? await Task.sleep(for: .milliseconds(100))
                await self?.revalidateConfiguration(for: sessionID)
            }
        }
    }

    nonisolated static func configurationChangeRequiresTermination(
        engineRunning: Bool,
        expectedSampleRate: Double,
        expectedChannelCount: Int,
        currentSampleRate: Double,
        currentChannelCount: Int
    ) -> Bool {
        guard engineRunning,
              expectedSampleRate.isFinite,
              expectedSampleRate > 0,
              expectedChannelCount > 0,
              currentSampleRate.isFinite,
              currentSampleRate > 0,
              currentChannelCount > 0 else {
            return true
        }
        return abs(currentSampleRate - expectedSampleRate) >= 0.5
            || currentChannelCount != expectedChannelCount
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

    private func clearSession() {
        if let configurationObserver {
            notificationCenter.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        engine = nil
        accumulator = nil
        activeSessionID = nil
        terminalError = nil
        tapInstalled = false
        captureFormat = nil
    }

    private nonisolated static func selectInputDevice(
        withUID selectedUID: String,
        on engine: AVAudioEngine
    ) throws {
        guard let deviceID = audioDeviceID(withUID: selectedUID),
              let audioUnit = engine.inputNode.audioUnit else {
            throw AudioCaptureError.selectedInputUnavailable
        }
        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AudioCaptureError.selectedInputUnavailable
        }
    }

    private nonisolated static func audioDeviceID(withUID selectedUID: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &byteCount
        ) == noErr else {
            return nil
        }

        let count = Int(byteCount) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &byteCount,
            &devices
        ) == noErr else {
            return nil
        }

        for deviceID in devices {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(
                deviceID,
                &uidAddress,
                0,
                nil,
                &uidSize,
                &uid
            ) == noErr else {
                continue
            }
            if uid?.takeUnretainedValue() as String? == selectedUID {
                return deviceID
            }
        }
        return nil
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

        let divisor = Float(channelCount)
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += channelData[channel][frame]
            }
            let monoSample = sum / divisor
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
