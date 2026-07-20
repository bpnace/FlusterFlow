import CryptoKit
import Foundation
import XCTest
@testable import WhisperFlow

final class ModelProvisioningServiceTests: XCTestCase, @unchecked Sendable {
    func testPinnedManifestIsSelfConsistentAndUsesExactRevisionHTTPSURLs() throws {
        let manifest = ModelManifest.parakeetV3Int8
        XCTAssertEqual(manifest.artifacts.count, 21)
        XCTAssertEqual(manifest.runtimeDirectoryName, "parakeet-tdt-0.6b-v3")
        XCTAssertEqual(
            manifest.installationDirectory(in: URL(fileURLWithPath: "/models")).path,
            "/models/parakeet-tdt-0.6b-v3"
        )
        XCTAssertEqual(Set(manifest.artifacts.map(\.relativePath)).count, 21)
        XCTAssertEqual(
            manifest.artifacts.reduce(Int64(0), { $0 + $1.byteCount }),
            manifest.expectedByteCount
        )

        var treeHasher = SHA256()
        for artifact in manifest.artifacts.sorted(by: { $0.relativePath < $1.relativePath }) {
            let record = "\(artifact.relativePath)\t\(artifact.byteCount)\t\(artifact.sha256.rawValue)\n"
            treeHasher.update(data: Data(record.utf8))
            let url = try XCTUnwrap(manifest.downloadURL(for: artifact))
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, "huggingface.co")
            XCTAssertTrue(url.path.contains("/resolve/\(manifest.modelRevision)/"))
        }

        XCTAssertEqual(ModelSHA256(hex(treeHasher.finalize())), manifest.treeSHA256)
    }

    func testDuplicateArtifactManifestFailsClosedInsteadOfCrashingStatusInspection() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(in: root)
        let duplicateManifest = ModelManifest(
            identifier: fixture.manifest.identifier,
            runtimeName: fixture.manifest.runtimeName,
            runtimeVersion: fixture.manifest.runtimeVersion,
            runtimeRevision: fixture.manifest.runtimeRevision,
            repository: fixture.manifest.repository,
            modelRevision: fixture.manifest.modelRevision,
            precision: fixture.manifest.precision,
            license: fixture.manifest.license,
            expectedByteCount: fixture.manifest.expectedByteCount,
            treeSHA256: fixture.manifest.treeSHA256,
            requiredTopLevelPaths: fixture.manifest.requiredTopLevelPaths,
            artifacts: fixture.manifest.artifacts + [fixture.manifest.artifacts[0]]
        )

        let status = await LocalModelStore(
            directory: fixture.sourceDirectory,
            manifest: duplicateManifest
        ).status()

        XCTAssertEqual(
            status,
            .invalid(problem: .invalidManifest, action: .replaceCorruptModel)
        )
    }

    func testUnexpectedHiddenRegularFileCannotYieldReadyStatus() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(in: root)
        try Data("unmanifested".utf8).write(
            to: fixture.sourceDirectory.appendingPathComponent(".hidden-artifact")
        )

        let status = await LocalModelStore(
            directory: fixture.sourceDirectory,
            manifest: fixture.manifest
        ).status()

        XCTAssertEqual(
            status,
            .invalid(
                problem: .unexpectedArtifact(".hidden-artifact"),
                action: .replaceCorruptModel
            )
        )
    }

    func testHiddenSymbolicLinkCannotYieldReadyStatus() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(in: root)
        try FileManager.default.createSymbolicLink(
            at: fixture.sourceDirectory.appendingPathComponent(".hidden-link"),
            withDestinationURL: fixture.sourceDirectory.appendingPathComponent("vocabulary.json")
        )

        let status = await LocalModelStore(
            directory: fixture.sourceDirectory,
            manifest: fixture.manifest
        ).status()

        XCTAssertEqual(
            status,
            .invalid(
                problem: .symbolicLinkNotAllowed(".hidden-link"),
                action: .replaceCorruptModel
            )
        )
    }

    func testSymbolicLinkModelRootCannotYieldReadyStatus() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(in: root)
        let linkedRoot = root.appendingPathComponent("linked-model")
        try FileManager.default.createSymbolicLink(
            at: linkedRoot,
            withDestinationURL: fixture.sourceDirectory
        )

        let status = await LocalModelStore(
            directory: linkedRoot,
            manifest: fixture.manifest
        ).status()

        XCTAssertEqual(
            status,
            .invalid(
                problem: .symbolicLinkNotAllowed("model-root"),
                action: .replaceCorruptModel
            )
        )
    }

    func testWrongRuntimeDirectoryNameIsRejectedBeforeProvisioning() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(in: root)
        let service = ModelProvisioningService(
            destinationDirectory: root.appendingPathComponent("wrong-runtime-folder"),
            manifest: fixture.manifest,
            transport: NeverModelProvisioningTransport()
        )

        do {
            _ = try await service.importLocalModel(from: fixture.sourceDirectory)
            XCTFail("A runtime-invisible installation directory must be rejected")
        } catch let error as ModelProvisioningError {
            XCTAssertEqual(
                error,
                .invalidDestinationDirectory(expectedLastPathComponent: "installed-model")
            )
        }

        XCTAssertTrue(try recoveryArtifacts(in: root).isEmpty)
    }

    func testLocalImportInstallsOfflineReadyModelWithRestrictivePermissions() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(in: root)
        let destination = root.appendingPathComponent("installed-model", isDirectory: true)
        let transport = NeverModelProvisioningTransport()
        let service = ModelProvisioningService(
            destinationDirectory: destination,
            manifest: fixture.manifest,
            transport: transport
        )

        let outcome = try await service.importLocalModel(from: fixture.sourceDirectory)
        let status = await service.status()
        let transportCalls = await transport.callCount()

        XCTAssertEqual(outcome.installedDirectory, destination)
        XCTAssertEqual(status, .ready(outcome.readiness))
        XCTAssertEqual(transportCalls, 0)
        XCTAssertEqual(try permissions(at: destination), 0o700)
        XCTAssertEqual(
            try permissions(at: destination.appendingPathComponent("Model.mlmodelc/model.bin")),
            0o600
        )
        XCTAssertTrue(try recoveryArtifacts(in: root).isEmpty)
    }

    func testDownloadHashMismatchNeverReplacesDestinationAndCleansStage() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(in: root)
        let destination = root.appendingPathComponent("installed-model", isDirectory: true)
        let transport = FixtureModelProvisioningTransport(
            sourceDirectory: fixture.sourceDirectory,
            corruptPath: "Model.mlmodelc/model.bin"
        )
        let service = ModelProvisioningService(
            destinationDirectory: destination,
            manifest: fixture.manifest,
            transport: transport
        )
        let request = await service.authorizeUserInitiatedDownload()

        do {
            _ = try await service.downloadModel(using: request)
            XCTFail("A same-size hash mismatch must fail closed")
        } catch let error as ModelProvisioningError {
            guard case .verificationFailed(let status) = error,
                  case .invalid(let problem, _) = status,
                  case .artifactHashMismatch(let path, _, _) = problem else {
                return XCTFail("Unexpected provisioning error: \(error)")
            }
            XCTAssertEqual(path, "Model.mlmodelc/model.bin")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(try recoveryArtifacts(in: root).isEmpty)
    }

    func testDownloadAuthorizationIsSingleUse() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(in: root)
        let destination = root.appendingPathComponent("installed-model", isDirectory: true)
        let transport = FixtureModelProvisioningTransport(sourceDirectory: fixture.sourceDirectory)
        let service = ModelProvisioningService(
            destinationDirectory: destination,
            manifest: fixture.manifest,
            transport: transport
        )
        let request = await service.authorizeUserInitiatedDownload()

        _ = try await service.downloadModel(using: request)
        do {
            _ = try await service.downloadModel(using: request)
            XCTFail("A consumed authorization must never trigger another download")
        } catch let error as ModelProvisioningError {
            XCTAssertEqual(error, .invalidAuthorization)
        }

        let transportCalls = await transport.callCount()
        XCTAssertEqual(transportCalls, fixture.manifest.artifacts.count)
    }

    func testInterruptedDownloadRemovesEveryPartialFile() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(in: root)
        let destination = root.appendingPathComponent("installed-model", isDirectory: true)
        let transport = FixtureModelProvisioningTransport(
            sourceDirectory: fixture.sourceDirectory,
            failBeforeDownloadNumber: 2
        )
        let service = ModelProvisioningService(
            destinationDirectory: destination,
            manifest: fixture.manifest,
            transport: transport
        )
        let request = await service.authorizeUserInitiatedDownload()

        do {
            _ = try await service.downloadModel(using: request)
            XCTFail("Interrupted provisioning must fail")
        } catch let error as ModelProvisioningError {
            guard case .downloadFailed = error else {
                return XCTFail("Unexpected provisioning error: \(error)")
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(try recoveryArtifacts(in: root).isEmpty)
        let transportCalls = await transport.callCount()
        XCTAssertEqual(transportCalls, 2)
    }

    func testPromotionFailureRestoresPreviousInstallAndRemovesBackup() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(in: root)
        let destination = root.appendingPathComponent("installed-model", isDirectory: true)
        let initialService = ModelProvisioningService(
            destinationDirectory: destination,
            manifest: fixture.manifest,
            transport: NeverModelProvisioningTransport()
        )
        _ = try await initialService.importLocalModel(from: fixture.sourceDirectory)

        let failingFileSystem = FailingMoveModelProvisioningFileSystem(failOnMoveNumber: 2)
        let replacementService = ModelProvisioningService(
            destinationDirectory: destination,
            manifest: fixture.manifest,
            transport: NeverModelProvisioningTransport(),
            fileSystem: failingFileSystem
        )

        do {
            _ = try await replacementService.importLocalModel(from: fixture.sourceDirectory)
            XCTFail("Injected promotion failure must surface")
        } catch let error as ModelProvisioningError {
            XCTAssertEqual(error, .installFailed)
        }

        let restoredStatus = await LocalModelStore(
            directory: destination,
            manifest: fixture.manifest
        ).status()
        guard case .ready = restoredStatus else {
            return XCTFail("The previous valid install was not restored: \(restoredStatus)")
        }
        XCTAssertEqual(failingFileSystem.moveCount, 3)
        XCTAssertTrue(try recoveryArtifacts(in: root).isEmpty)
    }

    func testProvisioningNetworkTypesStayOutOfLocalRuntimeGraph() throws {
        let sourceRoot = try TestResourceLoader.url("WhisperFlow")
        let provisioningRoot = sourceRoot
            .appendingPathComponent("Integrations/ModelProvisioning", isDirectory: true)
            .standardizedFileURL.path
        let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        var inspected = 0

        for case let fileURL as URL in enumerator ?? FileManager.default.enumerator(atPath: "")! {
            guard fileURL.pathExtension == "swift",
                  !fileURL.standardizedFileURL.path.hasPrefix(provisioningRoot) else {
                continue
            }
            inspected += 1
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            XCTAssertFalse(source.contains("ModelProvisioningTransport"), fileURL.path)
            XCTAssertFalse(source.contains("ModelArtifactDownloadRequest"), fileURL.path)
            XCTAssertFalse(source.contains("HTTPSModelProvisioningTransport"), fileURL.path)
        }

        XCTAssertGreaterThan(inspected, 10)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperFlowProvisioningTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFixture(in root: URL) throws -> ProvisioningFixture {
        let source = root.appendingPathComponent("selected-model", isDirectory: true)
        let files: [(String, Data)] = [
            ("Model.mlmodelc/model.bin", Data("synthetic-model".utf8)),
            ("vocabulary.json", Data("{\"0\":\"test\"}".utf8))
        ]
        var artifacts: [ModelArtifact] = []

        for (path, data) in files {
            let file = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: file)
            artifacts.append(
                ModelArtifact(
                    relativePath: path,
                    byteCount: Int64(data.count),
                    sha256: sha256(data)
                )
            )
        }

        var treeHasher = SHA256()
        for artifact in artifacts.sorted(by: { $0.relativePath < $1.relativePath }) {
            let record = "\(artifact.relativePath)\t\(artifact.byteCount)\t\(artifact.sha256.rawValue)\n"
            treeHasher.update(data: Data(record.utf8))
        }
        let treeDigest = ModelSHA256(hex(treeHasher.finalize()))!
        let manifest = ModelManifest(
            identifier: "synthetic-model",
            runtimeName: "FakeRuntime",
            runtimeVersion: "1.0.0",
            runtimeRevision: "runtime-revision",
            runtimeDirectoryName: "installed-model",
            repository: "example/synthetic-model",
            modelRevision: "model-revision",
            precision: "test",
            license: "test-only",
            expectedByteCount: artifacts.reduce(Int64(0), { $0 + $1.byteCount }),
            treeSHA256: treeDigest,
            requiredTopLevelPaths: ["Model.mlmodelc", "vocabulary.json"],
            artifacts: artifacts
        )
        return ProvisioningFixture(sourceDirectory: source, manifest: manifest)
    }

    private func sha256(_ data: Data) -> ModelSHA256 {
        ModelSHA256(hex(SHA256.hash(data: data)))!
    }

    private func hex<D: Digest>(_ digest: D) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func recoveryArtifacts(in parent: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(".model-staging-")
                || $0.lastPathComponent.hasPrefix(".model-backup-")
        }
    }
}

private struct ProvisioningFixture {
    let sourceDirectory: URL
    let manifest: ModelManifest
}

private enum SyntheticProvisioningFailure: Error {
    case expected
}

private actor NeverModelProvisioningTransport: ModelProvisioningTransport {
    private var calls = 0

    func download(_ request: ModelArtifactDownloadRequest) throws {
        calls += 1
        throw SyntheticProvisioningFailure.expected
    }

    func callCount() -> Int { calls }
}

private actor FixtureModelProvisioningTransport: ModelProvisioningTransport {
    private let sourceDirectory: URL
    private let corruptPath: String?
    private let failBeforeDownloadNumber: Int?
    private var calls = 0

    init(
        sourceDirectory: URL,
        corruptPath: String? = nil,
        failBeforeDownloadNumber: Int? = nil
    ) {
        self.sourceDirectory = sourceDirectory
        self.corruptPath = corruptPath
        self.failBeforeDownloadNumber = failBeforeDownloadNumber
    }

    func download(_ request: ModelArtifactDownloadRequest) throws {
        calls += 1
        if calls == failBeforeDownloadNumber {
            throw SyntheticProvisioningFailure.expected
        }

        var data = try Data(
            contentsOf: sourceDirectory.appendingPathComponent(request.artifact.relativePath)
        )
        if request.artifact.relativePath == corruptPath, !data.isEmpty {
            data[0] ^= 0xff
        }
        try data.write(to: request.destinationURL)
    }

    func callCount() -> Int { calls }
}

private final class FailingMoveModelProvisioningFileSystem: ModelProvisioningFileSystem, @unchecked Sendable {
    private let base = FoundationModelProvisioningFileSystem()
    private let failOnMoveNumber: Int
    private let lock = NSLock()
    private var moves = 0

    init(failOnMoveNumber: Int) {
        self.failOnMoveNumber = failOnMoveNumber
    }

    var moveCount: Int {
        lock.withLock { moves }
    }

    func itemExists(at url: URL) -> Bool {
        base.itemExists(at: url)
    }

    func createDirectory(at url: URL, permissions: Int?) throws {
        try base.createDirectory(at: url, permissions: permissions)
    }

    func copyItem(at source: URL, to destination: URL) throws {
        try base.copyItem(at: source, to: destination)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        let shouldFail = lock.withLock {
            moves += 1
            return moves == failOnMoveNumber
        }
        if shouldFail {
            throw SyntheticProvisioningFailure.expected
        }
        try base.moveItem(at: source, to: destination)
    }

    func removeItemIfExists(at url: URL) throws {
        try base.removeItemIfExists(at: url)
    }

    func setPermissions(_ permissions: Int, at url: URL) throws {
        try base.setPermissions(permissions, at: url)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try base.contentsOfDirectory(at: url)
    }
}
