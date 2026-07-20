import CryptoKit
import Foundation

enum ModelRecoveryAction: Equatable, Sendable {
    case importPinnedModel
    case runUserInitiatedProvisioning
    case replaceCorruptModel
}

enum LocalModelProblem: Equatable, Sendable {
    case invalidManifest
    case directoryMissing
    case requiredArtifactMissing(String)
    case unexpectedArtifact(String)
    case symbolicLinkNotAllowed(String)
    case artifactByteCountMismatch(path: String, expected: Int64, actual: Int64)
    case artifactHashMismatch(path: String, expected: ModelSHA256, actual: ModelSHA256)
    case byteCountMismatch(expected: Int64, actual: Int64)
    case treeHashMismatch(expected: ModelSHA256, actual: ModelSHA256)
    case unreadableArtifact(String)
}

struct LocalModelReadiness: Equatable, Sendable {
    let manifestIdentifier: String
    let modelRevision: String
    let byteCount: Int64
    let treeSHA256: ModelSHA256
}

enum LocalModelStatus: Equatable, Sendable {
    case missing(problem: LocalModelProblem, action: ModelRecoveryAction)
    case invalid(problem: LocalModelProblem, action: ModelRecoveryAction)
    case ready(LocalModelReadiness)
}

struct LocalModelUnavailableError: Error, Equatable, Sendable {
    let status: LocalModelStatus
}

protocol LocalModelChecking: Sendable {
    func status() async -> LocalModelStatus
    func validatedDirectory() async throws -> URL
}

actor LocalModelStore: LocalModelChecking {
    private let directory: URL
    private let manifest: ModelManifest
    private let fileManager: FileManager

    init(
        directory: URL,
        manifest: ModelManifest = .parakeetV3Int8,
        fileManager: FileManager = .default
    ) {
        self.directory = directory.standardizedFileURL
        self.manifest = manifest
        self.fileManager = fileManager
    }

    func status() -> LocalModelStatus {
        do {
            return try validate()
        } catch let error as LocalModelUnavailableError {
            return error.status
        } catch {
            return .invalid(
                problem: .unreadableArtifact("model-root"),
                action: .replaceCorruptModel
            )
        }
    }

    func validatedDirectory() throws -> URL {
        let currentStatus = try validate()
        guard case .ready = currentStatus else {
            throw LocalModelUnavailableError(status: currentStatus)
        }
        return directory
    }

    private func validate() throws -> LocalModelStatus {
        let rootValues: URLResourceValues
        do {
            rootValues = try directory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
        } catch {
            guard fileManager.fileExists(atPath: directory.path) else {
                return .missing(problem: .directoryMissing, action: .importPinnedModel)
            }
            return .invalid(
                problem: .unreadableArtifact("model-root"),
                action: .replaceCorruptModel
            )
        }

        if rootValues.isSymbolicLink == true {
            return .invalid(
                problem: .symbolicLinkNotAllowed("model-root"),
                action: .replaceCorruptModel
            )
        }
        guard rootValues.isDirectory == true else {
            return .missing(problem: .directoryMissing, action: .importPinnedModel)
        }

        for path in manifest.requiredTopLevelPaths {
            guard fileManager.fileExists(
                atPath: directory.appendingPathComponent(path).path
            ) else {
                return .missing(
                    problem: .requiredArtifactMissing(path),
                    action: .runUserInitiatedProvisioning
                )
            }
        }

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [
                .fileSizeKey,
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ],
            options: []
        ) else {
            return .invalid(
                problem: .unreadableArtifact("model-root"),
                action: .replaceCorruptModel
            )
        }

        var records: [String] = []
        var byteCount: Int64 = 0
        var expectedArtifacts: [String: ModelArtifact] = [:]
        for artifact in manifest.allArtifacts {
            guard expectedArtifacts.updateValue(
                artifact,
                forKey: artifact.relativePath
            ) == nil else {
                return .invalid(
                    problem: .invalidManifest,
                    action: .replaceCorruptModel
                )
            }
        }
        let expectedDirectories = Set(
            expectedArtifacts.keys.flatMap(Self.parentDirectories(for:))
        )
        var observedPaths: Set<String> = []

        for case let fileURL as URL in enumerator {
            let values: URLResourceValues
            do {
                values = try fileURL.resourceValues(
                    forKeys: [
                        .fileSizeKey,
                        .isDirectoryKey,
                        .isRegularFileKey,
                        .isSymbolicLinkKey
                    ]
                )
            } catch {
                return .invalid(
                    problem: .unreadableArtifact(relativePath(for: fileURL)),
                    action: .replaceCorruptModel
                )
            }

            let relativePath = relativePath(for: fileURL)
            if values.isSymbolicLink == true {
                return .invalid(
                    problem: .symbolicLinkNotAllowed(relativePath),
                    action: .replaceCorruptModel
                )
            }
            if values.isDirectory == true {
                let isExpectedDirectory = expectedArtifacts.isEmpty
                    || expectedDirectories.contains(relativePath)
                guard isExpectedDirectory else {
                    return .invalid(
                        problem: .unexpectedArtifact(relativePath),
                        action: .replaceCorruptModel
                    )
                }
                continue
            }
            guard values.isRegularFile == true else {
                return .invalid(
                    problem: .unexpectedArtifact(relativePath),
                    action: .replaceCorruptModel
                )
            }

            let size = Int64(values.fileSize ?? 0)
            let digest: ModelSHA256
            do {
                digest = try fileDigest(at: fileURL)
            } catch {
                return .invalid(
                    problem: .unreadableArtifact(relativePath),
                    action: .replaceCorruptModel
                )
            }
            observedPaths.insert(relativePath)
            if !expectedArtifacts.isEmpty {
                guard let expectedArtifact = expectedArtifacts[relativePath] else {
                    return .invalid(
                        problem: .unexpectedArtifact(relativePath),
                        action: .replaceCorruptModel
                    )
                }
                guard size == expectedArtifact.byteCount else {
                    return .invalid(
                        problem: .artifactByteCountMismatch(
                            path: relativePath,
                            expected: expectedArtifact.byteCount,
                            actual: size
                        ),
                        action: .replaceCorruptModel
                    )
                }
                guard digest == expectedArtifact.sha256 else {
                    return .invalid(
                        problem: .artifactHashMismatch(
                            path: relativePath,
                            expected: expectedArtifact.sha256,
                            actual: digest
                        ),
                        action: .replaceCorruptModel
                    )
                }
            }
            byteCount += size
            records.append("\(relativePath)\t\(size)\t\(digest.rawValue)\n")
        }

        if let missingPath = expectedArtifacts.keys
            .filter({ !observedPaths.contains($0) })
            .sorted()
            .first {
            return .missing(
                problem: .requiredArtifactMissing(missingPath),
                action: .runUserInitiatedProvisioning
            )
        }

        guard byteCount == manifest.expectedByteCount else {
            return .invalid(
                problem: .byteCountMismatch(
                    expected: manifest.expectedByteCount,
                    actual: byteCount
                ),
                action: .replaceCorruptModel
            )
        }

        var treeHasher = SHA256()
        for record in records.sorted() {
            treeHasher.update(data: Data(record.utf8))
        }
        let treeDigest = ModelSHA256(Self.hex(treeHasher.finalize()))!
        guard treeDigest == manifest.treeSHA256 else {
            return .invalid(
                problem: .treeHashMismatch(
                    expected: manifest.treeSHA256,
                    actual: treeDigest
                ),
                action: .replaceCorruptModel
            )
        }

        return .ready(
            LocalModelReadiness(
                manifestIdentifier: manifest.identifier,
                modelRevision: manifest.modelRevision,
                byteCount: byteCount,
                treeSHA256: treeDigest
            )
        )
    }

    private func fileDigest(at url: URL) throws -> ModelSHA256 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return ModelSHA256(Self.hex(hasher.finalize()))!
    }

    private func relativePath(for url: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(directory.path.count + 1))
    }

    private static func parentDirectories(for relativePath: String) -> [String] {
        let components = relativePath.split(separator: "/").map(String.init)
        guard components.count > 1 else { return [] }
        return (1..<components.count).map {
            components.prefix($0).joined(separator: "/")
        }
    }

    private static func hex<D: Digest>(_ digest: D) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
