import CryptoKit
import Foundation

actor RequiredLocalModelStore: LocalModelChecking {
    private let modelStore: any LocalModelChecking
    private let dependencyStore: (any LocalModelChecking)?

    init(
        modelStore: any LocalModelChecking,
        dependencyStore: (any LocalModelChecking)? = nil
    ) {
        self.modelStore = modelStore
        self.dependencyStore = dependencyStore
    }

    func status() async -> LocalModelStatus {
        let modelStatus = await modelStore.status()
        guard case .ready = modelStatus else { return modelStatus }
        guard let dependencyStore else { return modelStatus }
        return await dependencyStore.status()
    }

    func validatedDirectory() async throws -> URL {
        let directory = try await modelStore.validatedDirectory()
        if let dependencyStore {
            _ = try await dependencyStore.validatedDirectory()
        }
        return directory
    }
}

actor LocalModelProvisioningCatalog {
    private let services: [LocalModelChoice: ModelProvisioningService]
    private let whisperTokenizerService: ModelProvisioningService
    private var operationInProgress = false

    init(
        services: [LocalModelChoice: ModelProvisioningService],
        whisperTokenizerService: ModelProvisioningService
    ) {
        self.services = services
        self.whisperTokenizerService = whisperTokenizerService
    }

    func status(for choice: LocalModelChoice) async -> LocalModelStatus {
        if choice == .adaptive {
            return await adaptiveStatus()
        }
        guard let service = services[choice] else {
            return .invalid(problem: .invalidManifest, action: .replaceCorruptModel)
        }
        let modelStatus = await service.status()
        guard case .ready = modelStatus, choice.requiresWhisperTokenizer else {
            return modelStatus
        }
        return await whisperTokenizerService.status()
    }

    func importLocalModel(
        from directory: URL,
        choice: LocalModelChoice
    ) async throws -> LocalModelStatus {
        guard choice != .adaptive else {
            throw ModelProvisioningError.invalidManifest
        }
        try beginOperation()
        defer { operationInProgress = false }
        guard let service = services[choice] else {
            throw ModelProvisioningError.invalidManifest
        }
        _ = try await service.importLocalModel(from: directory)
        return await status(for: choice)
    }

    func downloadPinnedModel(choice: LocalModelChoice) async throws -> LocalModelStatus {
        try beginOperation()
        defer { operationInProgress = false }
        if choice == .adaptive {
            try await ensureWhisperTokenizerReady()
            try await downloadPinnedModelIfNeeded(choice: .whisperKitLargeV3Turbo)
            try await downloadPinnedModelIfNeeded(choice: .whisperKitLargeV3)
            return await adaptiveStatus()
        }
        guard let service = services[choice] else {
            throw ModelProvisioningError.invalidManifest
        }

        if choice.requiresWhisperTokenizer {
            try await ensureWhisperTokenizerReady()
        }

        let request = await service.authorizeUserInitiatedDownload()
        _ = try await service.downloadModel(using: request)
        return await status(for: choice)
    }

    private func adaptiveStatus() async -> LocalModelStatus {
        let requiredChoices: [LocalModelChoice] = [
            .whisperKitLargeV3Turbo,
            .whisperKitLargeV3
        ]
        var readiness: [LocalModelReadiness] = []

        for choice in requiredChoices {
            guard let service = services[choice] else {
                return .invalid(problem: .invalidManifest, action: .replaceCorruptModel)
            }
            let status = await service.status()
            guard case .ready(let ready) = status else { return status }
            readiness.append(ready)
        }

        let tokenizerStatus = await whisperTokenizerService.status()
        guard case .ready(let tokenizerReadiness) = tokenizerStatus else {
            return tokenizerStatus
        }
        readiness.append(tokenizerReadiness)

        return .ready(Self.adaptiveReadiness(from: readiness))
    }

    private func ensureWhisperTokenizerReady() async throws {
        guard case .ready = await whisperTokenizerService.status() else {
            let request = await whisperTokenizerService.authorizeUserInitiatedDownload()
            _ = try await whisperTokenizerService.downloadModel(using: request)
            return
        }
    }

    private func downloadPinnedModelIfNeeded(choice: LocalModelChoice) async throws {
        guard let service = services[choice] else {
            throw ModelProvisioningError.invalidManifest
        }
        guard case .ready = await service.status() else {
            let request = await service.authorizeUserInitiatedDownload()
            _ = try await service.downloadModel(using: request)
            return
        }
    }

    private static func adaptiveReadiness(
        from readiness: [LocalModelReadiness]
    ) -> LocalModelReadiness {
        let hashInput = readiness
            .map { "\($0.manifestIdentifier):\($0.modelRevision):\($0.treeSHA256.rawValue)" }
            .joined(separator: "|")
        let digest = SHA256.hash(data: Data(hashInput.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return LocalModelReadiness(
            manifestIdentifier: "adaptive-whisperkit-large-v3-turbo-large-v3",
            modelRevision: readiness.map(\.modelRevision).joined(separator: "+"),
            byteCount: readiness.reduce(0) { $0 + $1.byteCount },
            treeSHA256: ModelSHA256(digest)!
        )
    }

    private func beginOperation() throws {
        guard !operationInProgress else {
            throw ModelProvisioningError.operationInProgress
        }
        operationInProgress = true
    }
}
