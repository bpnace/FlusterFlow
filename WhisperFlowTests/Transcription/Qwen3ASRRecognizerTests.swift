import AVFoundation
import CryptoKit
import Foundation
import XCTest
@testable import WhisperFlow

final class Qwen3ASRRecognizerTests: XCTestCase, @unchecked Sendable {
    func testRecognizerUsesValidatedLocalFolderAndMapsLanguages() async throws {
        let samples = AudioBufferStore()
        let modelDirectory = URL(fileURLWithPath: "/private/qwen-model")
        let runtime = RecordingQwen3ASRRuntime(result: "  Hallo Welt  ")
        let recognizer = Qwen3ASRRecognizer(
            sampleAccess: samples,
            modelStore: QwenReadyLocalModelChecker(directory: modelDirectory),
            runtime: runtime
        )

        var inputs: [AudioInput] = []
        for (index, language) in [
            DictationLanguage.automatic,
            .german,
            .english
        ].enumerated() {
            let input = await samples.store(AudioSamples(values: [0.1, -0.1]))
            inputs.append(input)
            let transcript = try await recognizer.transcribe(
                input,
                hints: RecognitionHints(language: language, terms: ["FlusterFlow"]),
                sessionID: DictationSessionID(rawValue: UInt64(index + 1))
            )
            XCTAssertEqual(
                transcript,
                RawTranscript(
                    text: "Hallo Welt",
                    language: language,
                    backend: .qwen3ASR06B8Bit
                )
            )
        }

        let snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.modelDirectory, modelDirectory)
        XCTAssertEqual(snapshot.prepareCount, 1)
        XCTAssertEqual(snapshot.languages, [.automatic, .german, .english])
        for input in inputs {
            await samples.release(input)
        }
    }

    func testProductionManifestPinsRemoteAndDerivedArtifacts() throws {
        let manifest = ModelManifest.qwen3ASR06B8Bit

        XCTAssertEqual(manifest.runtimeVersion, "0.1.3")
        XCTAssertEqual(
            manifest.runtimeRevision,
            "d302a5c6080d2bb97bae38c7418f82abb76013b6"
        )
        XCTAssertEqual(manifest.derivedArtifacts.count, 1)
        XCTAssertEqual(
            manifest.allArtifacts.reduce(Int64(0)) { $0 + $1.byteCount },
            manifest.expectedByteCount
        )
        XCTAssertEqual(
            Set(manifest.allArtifacts.map(\.relativePath)).count,
            manifest.allArtifacts.count
        )
        for artifact in manifest.artifacts {
            let url = try XCTUnwrap(manifest.downloadURL(for: artifact))
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, "huggingface.co")
            XCTAssertTrue(url.path.contains(manifest.modelRevision))
        }
        XCTAssertNil(
            manifest.downloadURL(for: try XCTUnwrap(manifest.derivedArtifacts.first).artifact)
        )

        var treeHasher = SHA256()
        for artifact in manifest.allArtifacts.sorted(by: { $0.relativePath < $1.relativePath }) {
            treeHasher.update(
                data: Data(
                    "\(artifact.relativePath)\t\(artifact.byteCount)\t\(artifact.sha256.rawValue)\n".utf8
                )
            )
        }
        XCTAssertEqual(
            ModelSHA256(treeHasher.finalize().map { String(format: "%02x", $0) }.joined()),
            manifest.treeSHA256
        )
    }

    func testTokenizerGeneratorIsDeterministic() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("{\"a\":0,\"b\":1}".utf8).write(
            to: root.appendingPathComponent("vocab.json")
        )
        try Data("#version: 0.2\na b\n".utf8).write(
            to: root.appendingPathComponent("merges.txt")
        )
        try Data(
            "{\"added_tokens_decoder\":{\"2\":{\"content\":\"<x>\",\"special\":true}}}".utf8
        ).write(to: root.appendingPathComponent("tokenizer_config.json"))

        try QwenTokenizerArtifactGenerator.generate(in: root)
        let outputURL = root.appendingPathComponent("tokenizer.json")
        let first = try Data(contentsOf: outputURL)
        try FileManager.default.removeItem(at: outputURL)
        try QwenTokenizerArtifactGenerator.generate(in: root)
        let second = try Data(contentsOf: outputURL)

        XCTAssertEqual(first, second)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: second))
    }

    func testProductionRuntimeLoadsOnlyFromValidatedLocalDirectory() throws {
        let source = try TestResourceLoader.string(
            "WhisperFlow/Integrations/Qwen3ASR/Qwen3ASRRecognizer.swift"
        )

        XCTAssertTrue(source.contains("Qwen3ASRModel.fromModelDirectory"))
        XCTAssertFalse(source.contains("Qwen3ASRModel.fromPretrained"))
    }

    func testInstalledQwenModelLoadsWhenExplicitlyRequested() async throws {
        guard ProcessInfo.processInfo.environment["FLUSTERFLOW_RUN_QWEN_MODEL_SMOKE"] == "1" else {
            throw XCTSkip("Set FLUSTERFLOW_RUN_QWEN_MODEL_SMOKE=1 for the local MLX smoke test")
        }
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/FlusterFlow/Models")
        let manifest = ModelManifest.qwen3ASR06B8Bit
        let store = LocalModelStore(
            directory: manifest.installationDirectory(in: root),
            manifest: manifest
        )
        let runtime = OfflineQwen3ASRRuntime()

        try await runtime.prepare(modelDirectory: try await store.validatedDirectory())
    }

    func testInstalledQwenModelTranscribesAudioWhenExplicitlyRequested() async throws {
        guard let audioPath = ProcessInfo.processInfo.environment[
            "FLUSTERFLOW_QWEN_SMOKE_AUDIO"
        ] else {
            throw XCTSkip(
                "Set FLUSTERFLOW_QWEN_SMOKE_AUDIO to a local audio file for the MLX transcription smoke test"
            )
        }

        let audio = try Self.normalizedAudio(at: URL(fileURLWithPath: audioPath))
        XCTAssertFalse(audio.values.isEmpty)

        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/FlusterFlow/Models")
        let manifest = ModelManifest.qwen3ASR06B8Bit
        let store = LocalModelStore(
            directory: manifest.installationDirectory(in: root),
            manifest: manifest
        )
        let samples = AudioBufferStore()
        let input = await samples.store(audio)
        let recognizer = Qwen3ASRRecognizer(sampleAccess: samples, modelStore: store)

        let transcript = try await recognizer.transcribe(
            input,
            hints: RecognitionHints(language: .german, terms: ["FlusterFlow", "Qwen"]),
            sessionID: DictationSessionID(rawValue: 9_001)
        )
        await samples.release(input)

        XCTAssertFalse(transcript.text.isEmpty)
        print("QWEN_TRANSCRIPT=\(transcript.text)")
    }

    func testInstallPinnedQwenModelWhenExplicitlyRequested() async throws {
        guard let sourcePath = ProcessInfo.processInfo.environment[
            "FLUSTERFLOW_INSTALL_QWEN_MODEL_SOURCE"
        ] else {
            throw XCTSkip("Set FLUSTERFLOW_INSTALL_QWEN_MODEL_SOURCE for the explicit local install")
        }
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/FlusterFlow/Models")
        let manifest = ModelManifest.qwen3ASR06B8Bit
        let service = ModelProvisioningService(
            destinationDirectory: manifest.installationDirectory(in: root),
            manifest: manifest
        )

        let outcome = try await service.importLocalModel(
            from: URL(fileURLWithPath: sourcePath, isDirectory: true)
        )

        XCTAssertEqual(outcome.readiness.manifestIdentifier, manifest.identifier)
        XCTAssertEqual(outcome.readiness.treeSHA256, manifest.treeSHA256)
    }

    private static func normalizedAudio(at url: URL) throws -> AudioSamples {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let capacity = AVAudioFrameCount(file.length)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)
        )
        try file.read(into: buffer)

        let channelData = try XCTUnwrap(buffer.floatChannelData)
        let channelCount = Int(format.channelCount)
        let frameCount = Int(buffer.frameLength)
        XCTAssertGreaterThan(channelCount, 0)
        XCTAssertGreaterThan(frameCount, 0)

        var mono = [Float](repeating: 0, count: frameCount)
        for channel in 0..<channelCount {
            for frame in 0..<frameCount {
                mono[frame] += channelData[channel][frame] / Float(channelCount)
            }
        }
        return try PCMNormalizer.normalize([
            CapturedAudioChunk(monoSamples: mono, sampleRate: format.sampleRate)
        ])
    }
}

private actor RecordingQwen3ASRRuntime: Qwen3ASRRuntimeServing {
    struct Snapshot: Sendable {
        let modelDirectory: URL?
        let prepareCount: Int
        let languages: [Qwen3ASRLanguageMode]
    }

    private let result: String
    private var modelDirectory: URL?
    private var preparations = 0
    private var transcribedLanguages: [Qwen3ASRLanguageMode] = []

    init(result: String) {
        self.result = result
    }

    func prepare(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
        preparations += 1
    }

    func transcribe(
        samples: [Float],
        language: Qwen3ASRLanguageMode,
        sessionID: DictationSessionID
    ) -> String {
        _ = samples
        _ = sessionID
        transcribedLanguages.append(language)
        return result
    }

    func cancel(sessionID: DictationSessionID) {
        _ = sessionID
    }

    func snapshot() -> Snapshot {
        Snapshot(
            modelDirectory: modelDirectory,
            prepareCount: preparations,
            languages: transcribedLanguages
        )
    }
}

private actor QwenReadyLocalModelChecker: LocalModelChecking {
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func status() -> LocalModelStatus {
        .ready(
            LocalModelReadiness(
                manifestIdentifier: "qwen-fixture",
                modelRevision: "fixture",
                byteCount: 1,
                treeSHA256: ModelSHA256(String(repeating: "a", count: 64))!
            )
        )
    }

    func validatedDirectory() -> URL {
        directory
    }
}
