import CryptoKit
import Foundation

enum ModelProvisioningError: Error, Equatable, Sendable {
    case operationInProgress
    case invalidManifest
    case invalidDestinationDirectory(expectedLastPathComponent: String)
    case invalidAuthorization
    case sourceArtifactMissing(String)
    case sourceArtifactUnsafe(String)
    case downloadFailed(String)
    case derivedArtifactFailed(String)
    case verificationFailed(LocalModelStatus)
    case installFailed
    case rollbackFailed
    case recoveryFailed
}

struct ModelProvisioningOutcome: Equatable, Sendable {
    let installedDirectory: URL
    let readiness: LocalModelReadiness
}

protocol ModelProvisioningFileSystem: Sendable {
    func itemExists(at url: URL) -> Bool
    func createDirectory(at url: URL, permissions: Int?) throws
    func copyItem(at source: URL, to destination: URL) throws
    func moveItem(at source: URL, to destination: URL) throws
    func removeItemIfExists(at url: URL) throws
    func setPermissions(_ permissions: Int, at url: URL) throws
    func contentsOfDirectory(at url: URL) throws -> [URL]
}

struct FoundationModelProvisioningFileSystem: ModelProvisioningFileSystem, @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func itemExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func createDirectory(at url: URL, permissions: Int?) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        if let permissions {
            try setPermissions(permissions, at: url)
        }
    }

    func copyItem(at source: URL, to destination: URL) throws {
        try fileManager.copyItem(at: source, to: destination)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try fileManager.moveItem(at: source, to: destination)
    }

    func removeItemIfExists(at url: URL) throws {
        guard itemExists(at: url) else { return }
        try fileManager.removeItem(at: url)
    }

    func setPermissions(_ permissions: Int, at url: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: url.path
        )
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        guard itemExists(at: url) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        )
    }
}

actor ModelProvisioningService {
    private let destinationDirectory: URL
    private let manifest: ModelManifest
    private let transport: any ModelProvisioningTransport
    private let fileSystem: any ModelProvisioningFileSystem
    private let derivedArtifactMaterializer: any ModelDerivedArtifactMaterializing
    private var activeOperation = false
    private var pendingDownloadAuthorization: UUID?

    init(
        destinationDirectory: URL,
        manifest: ModelManifest = .parakeetV3Int8,
        transport: any ModelProvisioningTransport = HTTPSModelProvisioningTransport(),
        fileSystem: any ModelProvisioningFileSystem = FoundationModelProvisioningFileSystem(),
        derivedArtifactMaterializer: any ModelDerivedArtifactMaterializing = DefaultModelDerivedArtifactMaterializer()
    ) {
        self.destinationDirectory = destinationDirectory.standardizedFileURL
        self.manifest = manifest
        self.transport = transport
        self.fileSystem = fileSystem
        self.derivedArtifactMaterializer = derivedArtifactMaterializer
    }

    func status() async -> LocalModelStatus {
        await LocalModelStore(directory: destinationDirectory, manifest: manifest).status()
    }

    /// Settings calls this only from the explicit Download button/confirmation action.
    /// The returned one-shot authorization cannot be reused after a download attempt.
    func authorizeUserInitiatedDownload(at date: Date = Date()) -> UserInitiatedModelProvisioningRequest {
        let authorizationID = UUID()
        pendingDownloadAuthorization = authorizationID
        return UserInitiatedModelProvisioningRequest(
            manifest: manifest,
            destinationDirectory: destinationDirectory,
            initiatedAt: date,
            authorizationID: authorizationID
        )
    }

    func importLocalModel(from selectedDirectory: URL) async throws -> ModelProvisioningOutcome {
        try beginOperation()
        defer { activeOperation = false }
        try validateManifest()
        try recoverInterruptedProvisioningIfNeeded()

        let stage = try makeRestrictedStage()
        defer { try? fileSystem.removeItemIfExists(at: stage) }

        for artifact in manifest.allArtifacts {
            try Task.checkCancellation()
            let source = selectedDirectory
                .standardizedFileURL
                .appendingPathComponent(artifact.relativePath)
            let destination = stage.appendingPathComponent(artifact.relativePath)
            try validateLocalSource(source, artifact: artifact)
            try createRestrictedParents(for: destination, under: stage)
            do {
                try fileSystem.copyItem(at: source, to: destination)
                try fileSystem.setPermissions(0o600, at: destination)
            } catch {
                throw ModelProvisioningError.sourceArtifactUnsafe(artifact.relativePath)
            }
        }

        let readiness = try await validateStagedModel(at: stage)
        try promote(stage: stage)
        return ModelProvisioningOutcome(
            installedDirectory: destinationDirectory,
            readiness: readiness
        )
    }

    func downloadModel(
        using request: UserInitiatedModelProvisioningRequest
    ) async throws -> ModelProvisioningOutcome {
        guard pendingDownloadAuthorization == request.authorizationID,
              request.manifest == manifest,
              request.destinationDirectory.standardizedFileURL == destinationDirectory else {
            throw ModelProvisioningError.invalidAuthorization
        }
        pendingDownloadAuthorization = nil

        try beginOperation()
        defer { activeOperation = false }
        try validateManifest()
        try recoverInterruptedProvisioningIfNeeded()

        let stage = try makeRestrictedStage()
        defer { try? fileSystem.removeItemIfExists(at: stage) }

        for artifact in manifest.artifacts {
            try Task.checkCancellation()
            guard let sourceURL = manifest.downloadURL(for: artifact) else {
                throw ModelProvisioningError.invalidManifest
            }
            let destination = stage.appendingPathComponent(artifact.relativePath)
            try createRestrictedParents(for: destination, under: stage)
            do {
                try await transport.download(
                    ModelArtifactDownloadRequest(
                        sourceURL: sourceURL,
                        destinationURL: destination,
                        artifact: artifact
                    )
                )
                try fileSystem.setPermissions(0o600, at: destination)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ModelProvisioningError.downloadFailed(artifact.relativePath)
            }
        }

        for derivedArtifact in manifest.derivedArtifacts {
            try Task.checkCancellation()
            let destination = stage.appendingPathComponent(
                derivedArtifact.artifact.relativePath
            )
            try createRestrictedParents(for: destination, under: stage)
            do {
                try derivedArtifactMaterializer.materialize(
                    derivedArtifact,
                    in: stage
                )
                try fileSystem.setPermissions(0o600, at: destination)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ModelProvisioningError.derivedArtifactFailed(
                    derivedArtifact.artifact.relativePath
                )
            }
        }

        let readiness = try await validateStagedModel(at: stage)
        try promote(stage: stage)
        return ModelProvisioningOutcome(
            installedDirectory: destinationDirectory,
            readiness: readiness
        )
    }

    @discardableResult
    func recoverInterruptedProvisioning() async throws -> LocalModelStatus {
        try beginOperation()
        defer { activeOperation = false }
        do {
            try recoverInterruptedProvisioningIfNeeded()
        } catch {
            throw ModelProvisioningError.recoveryFailed
        }
        return await status()
    }

    private func beginOperation() throws {
        guard !activeOperation else {
            throw ModelProvisioningError.operationInProgress
        }
        activeOperation = true
    }

    private func validateManifest() throws {
        guard destinationDirectory.lastPathComponent == manifest.runtimeDirectoryName else {
            throw ModelProvisioningError.invalidDestinationDirectory(
                expectedLastPathComponent: manifest.runtimeDirectoryName
            )
        }
        let allArtifacts = manifest.allArtifacts
        guard !manifest.artifacts.isEmpty,
              manifest.expectedByteCount > 0,
              Set(allArtifacts.map(\.relativePath)).count == allArtifacts.count,
              allArtifacts.allSatisfy({ artifact in
                  artifact.byteCount >= 0
                      && !artifact.relativePath.isEmpty
                      && !artifact.relativePath.hasPrefix("/")
                      && !artifact.relativePath.split(separator: "/").contains("..")
              }),
              !manifest.runtimeDirectoryName.isEmpty,
              !manifest.runtimeDirectoryName.contains("/"),
              manifest.runtimeDirectoryName != ".",
              manifest.runtimeDirectoryName != "..",
              manifest.sourcePathPrefix.map({ prefix in
                  !prefix.isEmpty
                      && !prefix.hasPrefix("/")
                      && !prefix.split(separator: "/").contains("..")
              }) ?? true,
              allArtifacts.reduce(Int64(0), { $0 + $1.byteCount })
                == manifest.expectedByteCount else {
            throw ModelProvisioningError.invalidManifest
        }

        var hasher = SHA256()
        for artifact in allArtifacts.sorted(by: { $0.relativePath < $1.relativePath }) {
            let record = "\(artifact.relativePath)\t\(artifact.byteCount)\t\(artifact.sha256.rawValue)\n"
            hasher.update(data: Data(record.utf8))
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard ModelSHA256(digest) == manifest.treeSHA256 else {
            throw ModelProvisioningError.invalidManifest
        }
    }

    private func validateLocalSource(_ source: URL, artifact: ModelArtifact) throws {
        guard fileSystem.itemExists(at: source) else {
            throw ModelProvisioningError.sourceArtifactMissing(artifact.relativePath)
        }
        do {
            let values = try source.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ModelProvisioningError.sourceArtifactUnsafe(artifact.relativePath)
            }
        } catch let error as ModelProvisioningError {
            throw error
        } catch {
            throw ModelProvisioningError.sourceArtifactUnsafe(artifact.relativePath)
        }
    }

    private func makeRestrictedStage() throws -> URL {
        let parent = destinationDirectory.deletingLastPathComponent()
        try fileSystem.createDirectory(at: parent, permissions: nil)
        let stage = parent.appendingPathComponent(
            stagingMarker + UUID().uuidString,
            isDirectory: true
        )
        try fileSystem.createDirectory(at: stage, permissions: 0o700)
        return stage
    }

    private func createRestrictedParents(for file: URL, under stage: URL) throws {
        let relativeParent = file.deletingLastPathComponent().path
            .dropFirst(stage.path.count)
            .split(separator: "/")
        var current = stage
        for component in relativeParent {
            current.appendPathComponent(String(component), isDirectory: true)
            try fileSystem.createDirectory(at: current, permissions: 0o700)
        }
    }

    private func validateStagedModel(at stage: URL) async throws -> LocalModelReadiness {
        let stagedStatus = await LocalModelStore(directory: stage, manifest: manifest).status()
        guard case .ready(let readiness) = stagedStatus else {
            throw ModelProvisioningError.verificationFailed(stagedStatus)
        }
        return readiness
    }

    private func promote(stage: URL) throws {
        let parent = destinationDirectory.deletingLastPathComponent()
        let backup = parent.appendingPathComponent(
            backupMarker + UUID().uuidString,
            isDirectory: true
        )
        let hadExistingInstall = fileSystem.itemExists(at: destinationDirectory)

        if hadExistingInstall {
            do {
                try fileSystem.moveItem(at: destinationDirectory, to: backup)
            } catch {
                throw ModelProvisioningError.installFailed
            }
        }

        do {
            try fileSystem.moveItem(at: stage, to: destinationDirectory)
            try fileSystem.setPermissions(0o700, at: destinationDirectory)
            if hadExistingInstall {
                try fileSystem.removeItemIfExists(at: backup)
            }
        } catch {
            try? fileSystem.removeItemIfExists(at: destinationDirectory)
            if hadExistingInstall, fileSystem.itemExists(at: backup) {
                do {
                    try fileSystem.moveItem(at: backup, to: destinationDirectory)
                } catch {
                    throw ModelProvisioningError.rollbackFailed
                }
            }
            throw ModelProvisioningError.installFailed
        }
    }

    private func recoverInterruptedProvisioningIfNeeded() throws {
        let parent = destinationDirectory.deletingLastPathComponent()
        try fileSystem.createDirectory(at: parent, permissions: nil)
        let children = try fileSystem.contentsOfDirectory(at: parent)
        let stages = children.filter { $0.lastPathComponent.hasPrefix(stagingMarker) }
        let backups = children
            .filter { $0.lastPathComponent.hasPrefix(backupMarker) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for stage in stages {
            try fileSystem.removeItemIfExists(at: stage)
        }

        if fileSystem.itemExists(at: destinationDirectory) {
            for backup in backups {
                try fileSystem.removeItemIfExists(at: backup)
            }
        } else if let backupToRestore = backups.last {
            try fileSystem.moveItem(at: backupToRestore, to: destinationDirectory)
            for backup in backups.dropLast() {
                try fileSystem.removeItemIfExists(at: backup)
            }
        }
    }

    private var stagingMarker: String {
        ".model-staging-\(manifest.runtimeDirectoryName)-"
    }

    private var backupMarker: String {
        ".model-backup-\(manifest.runtimeDirectoryName)-"
    }
}
