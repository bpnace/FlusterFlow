@preconcurrency import ApplicationServices
import AppKit
import AVFoundation
import Foundation

struct ApplicationVersion: Equatable, Sendable {
    let marketingVersion: String
    let buildNumber: String?

    init(marketingVersion: String?, buildNumber: String?) {
        let marketingVersion = marketingVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        let buildNumber = buildNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let marketingVersion, !marketingVersion.isEmpty {
            self.marketingVersion = marketingVersion
        } else {
            self.marketingVersion = "Development"
        }
        self.buildNumber = buildNumber?.isEmpty == false ? buildNumber : nil
    }

    var compactText: String {
        guard let buildNumber else { return marketingVersion }
        return "\(marketingVersion) (\(buildNumber))"
    }

    var displayText: String {
        "Version \(compactText)"
    }

    static var current: Self {
        Self(
            marketingVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String,
            buildNumber: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String
        )
    }
}

enum PermissionState: String, Codable, Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted

    var title: String {
        switch self {
        case .notDetermined: "Noch nicht entschieden"
        case .authorized: "Erlaubt"
        case .denied: "Nicht erlaubt"
        case .restricted: "Eingeschränkt"
        }
    }
}

@MainActor
final class PermissionCenter: ObservableObject {
    @Published private(set) var microphone: PermissionState = .notDetermined
    @Published private(set) var accessibility: PermissionState = .notDetermined

    private let microphoneActions: MicrophonePermissionActions
    private let microphonePollingInterval: Duration
    private let accessibilityActions: AccessibilityPermissionActions
    private let accessibilityPollingInterval: Duration
    private var microphoneRefreshTask: Task<Void, Never>?
    private var accessibilityRefreshTask: Task<Void, Never>?

    init(
        microphoneActions: MicrophonePermissionActions = .live,
        accessibilityActions: AccessibilityPermissionActions = .live,
        microphonePollingInterval: Duration = .seconds(1),
        accessibilityPollingInterval: Duration = .seconds(1)
    ) {
        self.microphoneActions = microphoneActions
        self.microphonePollingInterval = microphonePollingInterval
        self.accessibilityActions = accessibilityActions
        self.accessibilityPollingInterval = accessibilityPollingInterval
        refresh()
    }

    func refresh() {
        microphone = PermissionState(microphoneActions.authorizationStatus())
        accessibility = accessibilityActions.isTrusted() ? .authorized : .denied
    }

    var microphoneRequestButtonTitle: String {
        switch microphone {
        case .notDetermined: "Mikrofon erlauben"
        case .denied, .restricted: "Mikrofon-Einstellungen öffnen"
        case .authorized: "Erlaubt"
        }
    }

    func requestMicrophone() {
        switch microphoneActions.authorizationStatus() {
        case .notDetermined:
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await microphoneActions.requestAccess()
                refresh()
            }
        case .denied, .restricted:
            microphoneActions.openSystemSettings()
            monitorMicrophonePermission()
        case .authorized:
            refresh()
        @unknown default:
            microphoneActions.openSystemSettings()
            monitorMicrophonePermission()
        }
    }

    func requestAccessibility() {
        accessibilityActions.requestPrompt()
        refresh()
        guard accessibility != .authorized else { return }
        accessibilityActions.openSystemSettings()
        monitorAccessibilityPermission()
    }

    private func monitorAccessibilityPermission() {
        accessibilityRefreshTask?.cancel()
        accessibilityRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0 ..< 120 {
                do {
                    try await Task.sleep(for: accessibilityPollingInterval)
                } catch {
                    return
                }
                refresh()
                if accessibility == .authorized { return }
            }
        }
    }

    private func monitorMicrophonePermission() {
        microphoneRefreshTask?.cancel()
        microphoneRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0 ..< 120 {
                do {
                    try await Task.sleep(for: microphonePollingInterval)
                } catch {
                    return
                }
                refresh()
                if microphone == .authorized { return }
            }
        }
    }
}

@MainActor
struct MicrophonePermissionActions {
    let authorizationStatus: () -> AVAuthorizationStatus
    let requestAccess: () async -> Bool
    let openSystemSettings: () -> Void

    static let live = Self(
        authorizationStatus: {
            AVCaptureDevice.authorizationStatus(for: .audio)
        },
        requestAccess: {
            await AVCaptureDevice.requestAccess(for: .audio)
        },
        openSystemSettings: {
            guard let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            ) else { return }
            NSWorkspace.shared.open(url)
        }
    )
}

@MainActor
struct AccessibilityPermissionActions {
    let isTrusted: () -> Bool
    let requestPrompt: () -> Void
    let openSystemSettings: () -> Void

    static let live = Self(
        isTrusted: { AXIsProcessTrusted() },
        requestPrompt: {
            let options = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
            ] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        },
        openSystemSettings: {
            guard let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            ) else { return }
            NSWorkspace.shared.open(url)
        }
    )
}

private extension PermissionState {
    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .authorized: self = .authorized
        case .denied: self = .denied
        case .restricted: self = .restricted
        @unknown default: self = .restricted
        }
    }
}

struct MicrophoneOption: Identifiable, Equatable, Sendable {
    /// Volatile CoreAudio UID, retained only for the current process.
    let id: String
    let name: String
}

@MainActor
final class MicrophoneCatalog: ObservableObject {
    @Published private(set) var devices: [MicrophoneOption] = []

    init() {
        refresh()
    }

    func refresh() {
        devices = CoreAudioInputDevices.available()
            .filter(\.isAlive)
            .map { MicrophoneOption(id: $0.uid, name: $0.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

enum APIKeySettingsState: Equatable, Sendable {
    case checking
    case missing
    case stored
    case failed

    var title: String {
        switch self {
        case .checking: "Wird geprüft …"
        case .missing: "Kein Schlüssel gespeichert"
        case .stored: "•••••••••••• · im Schlüsselbund"
        case .failed: "Schlüsselbund nicht verfügbar"
        }
    }
}

@MainActor
final class APIKeySettingsModel: ObservableObject {
    @Published private(set) var state: APIKeySettingsState = .checking
    @Published private(set) var lastOperationFailed = false

    let keyStore: any APIKeyStoring

    init(keyStore: any APIKeyStoring) {
        self.keyStore = keyStore
    }

    var hasStoredKey: Bool { state == .stored }

    func refresh() {
        state = .checking
        Task { @MainActor [weak self, keyStore] in
            do {
                self?.state = try await keyStore.read() == nil ? .missing : .stored
                self?.lastOperationFailed = false
            } catch {
                self?.state = .failed
                self?.lastOperationFailed = true
            }
        }
    }

    func save(_ untrustedValue: String) async -> Bool {
        let normalized = untrustedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let key = try SecretAPIKey(normalized)
            try await keyStore.save(key)
            state = .stored
            lastOperationFailed = false
            return true
        } catch {
            state = .failed
            lastOperationFailed = true
            return false
        }
    }

    func delete() async -> Bool {
        do {
            try await keyStore.delete()
            state = .missing
            lastOperationFailed = false
            return true
        } catch {
            state = .failed
            lastOperationFailed = true
            return false
        }
    }
}

enum ModelProvisioningActivity: Equatable, Sendable {
    case idle
    case checking
    case importing
    case downloading
    case failed
}

@MainActor
final class ModelProvisioningViewModel: ObservableObject {
    @Published private(set) var status: LocalModelStatus
    @Published private(set) var activity: ModelProvisioningActivity = .idle
    @Published private(set) var selectedChoice: LocalModelChoice

    private let catalog: LocalModelProvisioningCatalog

    init(
        catalog: LocalModelProvisioningCatalog,
        selectedChoice: LocalModelChoice
    ) {
        self.catalog = catalog
        self.selectedChoice = selectedChoice
        status = .missing(problem: .directoryMissing, action: .importPinnedModel)
    }

    var manifest: ModelManifest { selectedChoice.manifest }

    var downloadConfirmationTitle: String {
        "Ca. \(formattedBytes(downloadByteCount)) jetzt laden"
    }

    var importPanelTitle: String {
        if selectedChoice == .adaptive {
            return "Adaptive nutzt Turbo und Large v3 als getrennte Modellordner"
        }
        return "Gepinntes Modell \(selectedChoice.title) auswählen"
    }

    var canImportLocalDirectory: Bool {
        selectedChoice != .adaptive
    }

    var isBusy: Bool {
        switch activity {
        case .checking, .importing, .downloading: true
        case .idle, .failed: false
        }
    }

    var statusTitle: String {
        switch status {
        case .ready: "Bereit für lokales Diktat"
        case .missing: "Lokales Modell fehlt"
        case .invalid: "Lokales Modell ist beschädigt"
        }
    }

    var statusDetail: String {
        switch status {
        case .ready(let readiness):
            "Revision \(readiness.modelRevision.prefix(10)) · \(formattedBytes(readiness.byteCount))"
        case .missing:
            selectedChoice == .adaptive
                ? "Adaptive benötigt Turbo, Large v3 und den gemeinsamen Whisper-Tokenizer."
                : "Importiere das gepinnte Modell lokal oder starte den Download bewusst."
        case .invalid:
            "Ersetze das Modell per Import oder bewusstem, erneut geprüftem Download."
        }
    }

    func select(_ choice: LocalModelChoice) {
        guard selectedChoice != choice else { return }
        selectedChoice = choice
        status = .missing(problem: .directoryMissing, action: .importPinnedModel)
        refresh()
    }

    func refresh() {
        let choice = selectedChoice
        activity = .checking
        Task { @MainActor [weak self, catalog] in
            let refreshedStatus = await catalog.status(for: choice)
            guard let self, self.selectedChoice == choice else { return }
            self.status = refreshedStatus
            self.activity = .idle
        }
    }

    func importLocalModel(from directory: URL) {
        guard !isBusy else { return }
        let choice = selectedChoice
        activity = .importing
        Task { @MainActor [weak self, catalog] in
            do {
                let importedStatus = try await catalog.importLocalModel(
                    from: directory,
                    choice: choice
                )
                guard let self, self.selectedChoice == choice else { return }
                self.status = importedStatus
                self.activity = .idle
            } catch {
                let refreshedStatus = await catalog.status(for: choice)
                guard let self, self.selectedChoice == choice else { return }
                self.status = refreshedStatus
                self.activity = .failed
            }
        }
    }

    /// This is reached only from the explicit confirmation button in Settings.
    func downloadPinnedModelAfterConfirmation() {
        guard !isBusy else { return }
        let choice = selectedChoice
        activity = .downloading
        Task { @MainActor [weak self, catalog] in
            do {
                let downloadedStatus = try await catalog.downloadPinnedModel(choice: choice)
                guard let self, self.selectedChoice == choice else { return }
                self.status = downloadedStatus
                self.activity = .idle
            } catch {
                let refreshedStatus = await catalog.status(for: choice)
                guard let self, self.selectedChoice == choice else { return }
                self.status = refreshedStatus
                self.activity = .failed
            }
        }
    }

    private var downloadByteCount: Int64 {
        if selectedChoice == .adaptive {
            return ModelManifest.whisperLargeV3Turbo.expectedByteCount
                + ModelManifest.whisperLargeV3.expectedByteCount
                + ModelManifest.whisperLargeV3Tokenizer.expectedByteCount
        }
        return manifest.expectedByteCount
            + (selectedChoice.requiresWhisperTokenizer
                ? ModelManifest.whisperLargeV3Tokenizer.expectedByteCount
                : 0)
    }

    private func formattedBytes(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}

struct DiagnosticsReport: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let appVersion: String
    let runtimeName: String
    let runtimeVersion: String
    let microphonePermission: PermissionState
    let accessibilityPermission: PermissionState
    let modelStatus: String
    let stageDurations: [StageMetricAggregate]
    let asrRuntime: [ASRRuntimeAggregate]
    let rewriteRuntime: [RewriteRuntimeAggregate]

    init(
        schemaVersion: Int,
        appVersion: String,
        runtimeName: String,
        runtimeVersion: String,
        microphonePermission: PermissionState,
        accessibilityPermission: PermissionState,
        modelStatus: String,
        stageDurations: [StageMetricAggregate],
        asrRuntime: [ASRRuntimeAggregate] = [],
        rewriteRuntime: [RewriteRuntimeAggregate] = []
    ) {
        self.schemaVersion = schemaVersion
        self.appVersion = appVersion
        self.runtimeName = runtimeName
        self.runtimeVersion = runtimeVersion
        self.microphonePermission = microphonePermission
        self.accessibilityPermission = accessibilityPermission
        self.modelStatus = modelStatus
        self.stageDurations = stageDurations
        self.asrRuntime = asrRuntime
        self.rewriteRuntime = rewriteRuntime
    }
}

@MainActor
final class DiagnosticsViewModel: ObservableObject {
    @Published private(set) var exportFailed = false

    private let metrics: StageMetricRecorder
    private let asrRuntime: ASRRuntimeAggregateRecorder
    private let rewriteRuntime: RewriteRuntimeAggregateRecorder
    private let permissions: PermissionCenter
    private let model: ModelProvisioningViewModel

    init(
        metrics: StageMetricRecorder,
        asrRuntime: ASRRuntimeAggregateRecorder = ASRRuntimeAggregateRecorder(),
        rewriteRuntime: RewriteRuntimeAggregateRecorder = RewriteRuntimeAggregateRecorder(),
        permissions: PermissionCenter,
        model: ModelProvisioningViewModel
    ) {
        self.metrics = metrics
        self.asrRuntime = asrRuntime
        self.rewriteRuntime = rewriteRuntime
        self.permissions = permissions
        self.model = model
    }

    func report() async -> DiagnosticsReport {
        DiagnosticsReport(
            schemaVersion: 3,
            appVersion: ApplicationVersion.current.compactText,
            runtimeName: model.manifest.runtimeName,
            runtimeVersion: model.manifest.runtimeVersion,
            microphonePermission: permissions.microphone,
            accessibilityPermission: permissions.accessibility,
            modelStatus: model.statusTitle,
            stageDurations: await metrics.aggregates(),
            asrRuntime: await asrRuntime.aggregates(),
            rewriteRuntime: await rewriteRuntime.aggregates()
        )
    }

    func export(to destination: URL) async {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(await report())
            try data.write(to: destination, options: [.atomic])
            exportFailed = false
        } catch {
            exportFailed = true
        }
    }
}
