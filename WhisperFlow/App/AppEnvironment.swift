import Combine
import Dispatch
import Foundation
import SwiftUI

enum RecordingDeadline {
    static func remainingDuration(
        recordingStartedAt: Date,
        now: Date = Date()
    ) -> TimeInterval {
        max(
            0,
            AVAudioEngineCapture.maximumCaptureDurationSeconds
                - max(0, now.timeIntervalSince(recordingStartedAt))
        )
    }
}

struct DictationCapabilityStatus: Equatable, Sendable {
    let microphone: PermissionState
    let accessibility: PermissionState
    let model: LocalModelStatus

    var canStartLocalDictation: Bool {
        microphone == .authorized && accessibility == .authorized && modelIsReady
    }

    var hasAutomaticInsertion: Bool {
        accessibility == .authorized
    }

    func statusTitle(shortcut: String) -> String {
        guard microphone == .authorized else {
            return "Mikrofonzugriff fehlt"
        }
        guard modelIsReady else {
            return "Lokales Modell fehlt"
        }
        guard hasAutomaticInsertion else {
            return "Bedienungshilfen für direktes Einfügen fehlen"
        }
        return "Bereit · \(shortcut) halten"
    }

    private var modelIsReady: Bool {
        if case .ready = model { return true }
        return false
    }
}

struct DictationOperationalStatus: Equatable, Sendable {
    let capability: DictationCapabilityStatus
    let pushToTalkEnabled: Bool
    let pushToTalkRegistrationStatus: PushToTalkRegistrationStatus

    var canStartDictation: Bool {
        capability.canStartLocalDictation
            && pushToTalkEnabled
            && pushToTalkRegistrationStatus == .registered
    }

    func statusTitle(shortcut: String) -> String {
        guard pushToTalkEnabled else {
            return "Push-to-talk deaktiviert"
        }
        guard pushToTalkRegistrationStatus == .registered else {
            return pushToTalkRegistrationStatus.title
        }
        guard capability.canStartLocalDictation else {
            return capability.statusTitle(shortcut: shortcut)
        }
        return "Bereit · \(shortcut) halten"
    }
}

enum CancellationPresentationDecision: Equatable, Sendable {
    case showCancelled
    case showError
    case deferToOperationCompletion
    case unchanged
}

extension CancelOutcome {
    var presentationDecision: CancellationPresentationDecision {
        switch self {
        case .cancelled:
            .showCancelled
        case .failed:
            .showError
        case .tooLateCommitted:
            .deferToOperationCompletion
        case .ignoredStale, .noActiveSession:
            .unchanged
        }
    }

    var terminatedSessionID: DictationSessionID? {
        switch self {
        case .cancelled(let sessionID), .failed(let sessionID, _):
            sessionID
        case .tooLateCommitted, .ignoredStale, .noActiveSession:
            nil
        }
    }

    func presentationDecision(
        errorTerminalSessionID: DictationSessionID?,
        cancelledBeforeSessionStart: Bool = false
    ) -> CancellationPresentationDecision {
        if case .noActiveSession = self, cancelledBeforeSessionStart {
            return .showCancelled
        }
        if let terminatedSessionID,
           let errorTerminalSessionID,
           terminatedSessionID == errorTerminalSessionID {
            return .showError
        }
        return presentationDecision
    }
}

@MainActor
final class AppEnvironment {
    let coordinator: DictationCoordinator
    let settings: SettingsStore
    let audioSamples: AudioBufferStore
    let permissions: PermissionCenter
    let apiKeySettings: APIKeySettingsModel
    let modelProvisioning: ModelProvisioningViewModel
    let personalLexicon: PersonalLexiconStore
    let recordingHistory: RecordingHistoryStore

    private let hotKey: any PushToTalkHotKeyControlling
    private let diagnostics: ContentFreeDiagnostics
    private let diagnosticsStore: DiagnosticsV2AggregateStore
    private let diagnosticsBaseline: DiagnosticsV2Report?
    private let speechRecognizer: SessionModelSpeechRecognizer
    private let historyModelReadiness: RecordingHistoryModelReadinessProvider
    private let adaptiveRecognizer: AdaptiveWhisperKitRecognizer
    private let enrichment: SessionAwareOpenAIEnrichment
    private let localRewriter: FoundationModelsTextRewriter
    private let sessionDiagnostics: ContentFreeSessionDiagnostics
    private let fallbackResults: EphemeralResultStore
    private let flowBar = FlowBarController()
    private let diagnosticsViewModel: DiagnosticsViewModel

    private lazy var appWindow: AppWindowController = {
        let historyViewModel = RecordingHistoryViewModel(
            store: recordingHistory,
            audioSamples: audioSamples,
            recognizer: speechRecognizer,
            modelReadiness: historyModelReadiness
        )
        return AppWindowController(
            overview: AnyView(
                AppOverviewView(
                    store: settings,
                    permissions: permissions,
                    model: modelProvisioning,
                    finish: { [weak self] in self?.completeOnboarding() }
                )
            ),
            recordingHistoryViewModel: historyViewModel,
            settingsView: { [
                settings,
                permissions,
                apiKeySettings,
                modelProvisioning,
                diagnosticsViewModel,
                personalLexicon
            ] destination in
                AnyView(
                    LocalSettingsView(
                        destination: destination,
                        store: settings,
                        permissions: permissions,
                        apiKey: apiKeySettings,
                        model: modelProvisioning,
                        diagnostics: diagnosticsViewModel,
                        lexicon: personalLexicon
                    )
                )
            }
        )
    }()

    private var activeSessionID: DictationSessionID?
    private var operationTask: Task<Void, Never>?
    private var cancellationTask: Task<Void, Never>?
    private var pendingReleaseConsent: ConsentSnapshot?
    private var activationReducer: DictationActivationReducer
    private var pendingPushToTalkStopTask: Task<Void, Never>?
    private var automaticFinalizationTask: Task<Void, Never>?
    private var recordingStartedAt: Date?
    private var isHandsFreeActive = false
    private var isCancellationRequested = false
    private var cancellationAvailable = false
    private var flowGeneration: UInt64 = 0
    private var isHotKeyRegistered = false
    private var errorTerminalSessionID: DictationSessionID?
    private var capabilitySubscriptions: Set<AnyCancellable> = []
    private var onboardingReadinessObservation: AnyCancellable?
    private var largeIdleUnloadTask: Task<Void, Never>?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var nextMaintenanceSessionRawValue = UInt64.max
    private let recordingHistoryRecoveryTask: Task<Void, Never>
    private var recordingHistorySetupTask: Task<Void, Never>?
    private var recordingHistoryPresentationTask: Task<Void, Never>?

    var onCancellationAvailabilityChanged: ((Bool) -> Void)?
    var onCapabilityStatusChanged: (() -> Void)?

    init(
        hotKey: any PushToTalkHotKeyControlling = CarbonPushToTalkHotKeyController(),
        settings suppliedSettings: SettingsStore? = nil
    ) {
        let settings = suppliedSettings ?? SettingsStore()
        activationReducer = DictationActivationReducer(
            mode: settings.handsFreeEnabled ? .doubleTap : .disabled
        )
        let samples = AudioBufferStore()
        let permissions = PermissionCenter()
        let keyStore = KeychainAPIKeyStore()
        let apiKeySettings = APIKeySettingsModel(keyStore: keyStore)
        let personalLexicon = PersonalLexiconStore()
        let paths = AppPaths.live()
        let recordingHistory = RecordingHistoryStore(
            rootURL: paths.applicationSupportDirectory
                .appendingPathComponent("RecordingHistory", isDirectory: true)
        )
        let recordingHistoryRecorder = RecordingHistoryRecorder(
            store: recordingHistory,
            sampleAccess: samples
        )
        let recordingHistoryRecoveryTask = Task {
            await recordingHistory.recoverAtLaunch()
        }
        let diagnosticsStore = DiagnosticsV2AggregateStore(
            directory: paths.applicationSupportDirectory
                .appendingPathComponent("Diagnostics", isDirectory: true)
        )
        let diagnosticsBaseline = try? diagnosticsStore.load()
        let tokenizerStore = LocalModelStore(
            directory: paths.modelDirectory(for: .whisperLargeV3Tokenizer),
            manifest: .whisperLargeV3Tokenizer
        )
        let parakeetStore = LocalModelStore(
            directory: paths.modelDirectory(for: .parakeetV3Int8),
            manifest: .parakeetV3Int8
        )
        let qwenStore = LocalModelStore(
            directory: paths.modelDirectory(for: .qwen3ASR06B8Bit),
            manifest: .qwen3ASR06B8Bit
        )
        let whisperLargeStore = LocalModelStore(
            directory: paths.modelDirectory(for: .whisperLargeV3),
            manifest: .whisperLargeV3
        )
        let whisperTurboStore = LocalModelStore(
            directory: paths.modelDirectory(for: .whisperLargeV3Turbo),
            manifest: .whisperLargeV3Turbo
        )
        let provisioningServices: [LocalModelChoice: ModelProvisioningService] = [
            .parakeetV3Int8: ModelProvisioningService(
                destinationDirectory: paths.modelDirectory(for: .parakeetV3Int8),
                manifest: .parakeetV3Int8
            ),
            .qwen3ASR06B8Bit: ModelProvisioningService(
                destinationDirectory: paths.modelDirectory(for: .qwen3ASR06B8Bit),
                manifest: .qwen3ASR06B8Bit
            ),
            .whisperKitLargeV3: ModelProvisioningService(
                destinationDirectory: paths.modelDirectory(for: .whisperLargeV3),
                manifest: .whisperLargeV3
            ),
            .whisperKitLargeV3Turbo: ModelProvisioningService(
                destinationDirectory: paths.modelDirectory(for: .whisperLargeV3Turbo),
                manifest: .whisperLargeV3Turbo
            )
        ]
        let tokenizerProvisioningService = ModelProvisioningService(
            destinationDirectory: paths.modelDirectory(for: .whisperLargeV3Tokenizer),
            manifest: .whisperLargeV3Tokenizer
        )
        let provisioningCatalog = LocalModelProvisioningCatalog(
            services: provisioningServices,
            whisperTokenizerService: tokenizerProvisioningService
        )
        let historyModelReadiness = RecordingHistoryModelReadinessProvider {
            [provisioningCatalog] choice in
            if case .ready = await provisioningCatalog.status(for: choice) {
                return true
            }
            return false
        }
        let modelProvisioning = ModelProvisioningViewModel(
            catalog: provisioningCatalog,
            selectedChoice: settings.localModel
        )
        let whisperLargeRecognizer = WhisperKitRecognizer(
            sampleAccess: samples,
            modelStore: whisperLargeStore,
            tokenizerStore: tokenizerStore,
            backend: .whisperKitLargeV3
        )
        let whisperTurboRecognizer = WhisperKitRecognizer(
            sampleAccess: samples,
            modelStore: whisperTurboStore,
            tokenizerStore: tokenizerStore,
            backend: .whisperKitLargeV3Turbo
        )
        let adaptiveRecognizer = AdaptiveWhisperKitRecognizer(
            turbo: whisperTurboRecognizer,
            large: whisperLargeRecognizer
        )
        let speechRecognizer = SessionModelSpeechRecognizer(
            recognizers: [
                .adaptive: adaptiveRecognizer,
                .parakeetV3Int8: FluidAudioRecognizer(
                    sampleAccess: samples,
                    modelStore: parakeetStore
                ),
                .qwen3ASR06B8Bit: Qwen3ASRRecognizer(
                    sampleAccess: samples,
                    modelStore: qwenStore
                ),
                .whisperKitLargeV3: whisperLargeRecognizer,
                .whisperKitLargeV3Turbo: whisperTurboRecognizer
            ],
            productASRDeadline: .seconds(30)
        )
        let diagnostics = ContentFreeDiagnostics()
        let composition = DictationComposition.live(
            settings: settings,
            audioSamples: samples,
            recognizer: speechRecognizer,
            personalLexicon: personalLexicon,
            keyStore: keyStore,
            diagnostics: diagnostics,
            recordingHistory: recordingHistoryRecorder
        )

        self.settings = settings
        audioSamples = samples
        self.permissions = permissions
        self.apiKeySettings = apiKeySettings
        self.modelProvisioning = modelProvisioning
        self.personalLexicon = personalLexicon
        self.recordingHistory = recordingHistory
        self.recordingHistoryRecoveryTask = recordingHistoryRecoveryTask
        self.hotKey = hotKey
        self.speechRecognizer = speechRecognizer
        self.historyModelReadiness = historyModelReadiness
        self.adaptiveRecognizer = adaptiveRecognizer
        self.diagnostics = diagnostics
        self.diagnosticsStore = diagnosticsStore
        self.diagnosticsBaseline = diagnosticsBaseline
        coordinator = composition.coordinator
        enrichment = composition.enrichment
        localRewriter = composition.localRewriter
        sessionDiagnostics = composition.sessionDiagnostics
        fallbackResults = composition.fallbackResults
        diagnosticsViewModel = DiagnosticsViewModel(
            metrics: diagnostics.metrics,
            asrRuntime: diagnostics.asrRuntime,
            rewriteRuntime: diagnostics.rewriteRuntime,
            permissions: permissions,
            model: modelProvisioning
        )

        settings.onPushToTalkConfigurationChanged = { [weak self] in
            guard let self else { return }
            if self.isHandsFreeActive {
                self.finishRecordingNow()
            }
            self.pendingPushToTalkStopTask?.cancel()
            self.pendingPushToTalkStopTask = nil
            self.activationReducer = DictationActivationReducer(
                mode: self.settings.handsFreeEnabled ? .doubleTap : .disabled
            )
            self.isHandsFreeActive = false
            if !self.settings.pushToTalkEnabled || self.settings.isShortcutCaptureActive {
                cancelActiveSession()
            }
            registerConfiguredHotKey()
            onCapabilityStatusChanged?()
        }
        settings.onLocalModelChanged = { [weak self] choice in
            self?.modelProvisioning.select(choice)
            self?.onCapabilityStatusChanged?()
        }
        modelProvisioning.$status
            .sink { [weak self] _ in
                Task { @MainActor in self?.onCapabilityStatusChanged?() }
            }
            .store(in: &capabilitySubscriptions)
        configureMemoryPressureHandling()
        recordingHistorySetupTask = Task { [weak self, coordinator] in
            await coordinator.setRecordingHistoryFailureHandler { [weak self] sessionID in
                await self?.handleRecordingHistoryCheckpointFailure(sessionID)
            }
        }
        permissions.$microphone
            .combineLatest(permissions.$accessibility)
            .sink { [weak self] _ in
                Task { @MainActor in self?.onCapabilityStatusChanged?() }
            }
            .store(in: &capabilitySubscriptions)
    }

    var shortcutTitle: String { settings.shortcut.title }

    var serviceStatusTitle: String {
        guard !settings.isShortcutCaptureActive else {
            return "Tastenkürzel wird aufgenommen …"
        }
        return operationalStatus.statusTitle(shortcut: shortcutTitle)
    }

    var capabilityStatus: DictationCapabilityStatus {
        DictationCapabilityStatus(
            microphone: permissions.microphone,
            accessibility: permissions.accessibility,
            model: modelProvisioning.status
        )
    }

    var operationalStatus: DictationOperationalStatus {
        DictationOperationalStatus(
            capability: capabilityStatus,
            pushToTalkEnabled: settings.pushToTalkEnabled,
            pushToTalkRegistrationStatus: settings.pushToTalkRegistrationStatus
        )
    }

    var canCancelActiveOperation: Bool {
        cancellationAvailable && !isCancellationRequested
    }

    @discardableResult
    func startServices() -> Bool {
        permissions.refresh()
        apiKeySettings.refresh()
        modelProvisioning.refresh()
        let registered = registerConfiguredHotKey()
        setCancellationAvailability(false)
        Task { [adaptiveRecognizer] in
            try? await adaptiveRecognizer.prewarmTurbo()
        }
        return registered
    }

    func shutdown() {
        onboardingReadinessObservation?.cancel()
        onboardingReadinessObservation = nil
        hotKey.unregister()
        isHotKeyRegistered = false
        operationTask?.cancel()
        cancellationTask?.cancel()
        largeIdleUnloadTask?.cancel()
        pendingPushToTalkStopTask?.cancel()
        automaticFinalizationTask?.cancel()
        recordingHistoryPresentationTask?.cancel()
        operationTask = nil
        cancellationTask = nil
        largeIdleUnloadTask = nil
        pendingPushToTalkStopTask = nil
        automaticFinalizationTask = nil
        recordingHistoryPresentationTask = nil
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        let knownSessionID = activeSessionID
        Task { [coordinator] in
            let sessionID: DictationSessionID?
            if let knownSessionID {
                sessionID = knownSessionID
            } else {
                sessionID = await coordinator.snapshot().activeSessionID
            }
            if let sessionID {
                _ = await coordinator.cancel(sessionID: sessionID)
                await sessionDiagnostics.cancel(sessionID: sessionID)
            }
        }
        activeSessionID = nil
        recordingStartedAt = nil
        isHandsFreeActive = false
        pendingReleaseConsent = nil
        isCancellationRequested = false
        setCancellationAvailability(false)
        flowBar.hide()
        Task { await fallbackResults.removeAll() }
        Task { await audioSamples.removeAll() }
    }

    func refreshSystemStatus() {
        permissions.refresh()
        modelProvisioning.refresh()
    }

    func presentApp() {
        cancelPendingRecordingHistoryPresentation()
        appWindow.present(.overview)
    }

    func presentSettings() {
        cancelPendingRecordingHistoryPresentation()
        appWindow.presentSettings()
    }

    func presentRecordingHistory() {
        recordingHistoryPresentationTask?.cancel()
        appWindow.present(.recordings)
        recordingHistoryPresentationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await recordingHistoryRecoveryTask.value
            guard !Task.isCancelled else { return }
            appWindow.refreshRecordingsIfSelected()
            recordingHistoryPresentationTask = nil
        }
    }

    func presentOnboardingIfNeeded() {
        permissions.refresh()
        modelProvisioning.refresh()
        onboardingReadinessObservation?.cancel()
        guard settings.onboardingCompleted else {
            presentApp()
            return
        }

        onboardingReadinessObservation = modelProvisioning.$activity
            .filter { $0 != .checking }
            .first()
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.operationalStatus.canStartDictation else { return }
                    self.presentApp()
                }
            }
    }

    private func completeOnboarding() {
        guard operationalStatus.canStartDictation else { return }
        onboardingReadinessObservation?.cancel()
        onboardingReadinessObservation = nil
        settings.onboardingCompleted = true
        appWindow.present(.overview)
    }

    private func cancelPendingRecordingHistoryPresentation() {
        recordingHistoryPresentationTask?.cancel()
        recordingHistoryPresentationTask = nil
    }

    func cancelActiveSession() {
        guard canCancelActiveOperation else { return }
        resetActivationState()
        isCancellationRequested = true
        pendingReleaseConsent = nil
        setCancellationAvailability(false)

        let knownSessionID = activeSessionID
        let cancelledBeforeSessionStart = knownSessionID == nil && operationTask != nil
        cancellationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var sessionID = knownSessionID
            if sessionID == nil {
                sessionID = await coordinator.snapshot().activeSessionID
            }
            let outcome: CancelOutcome
            if let sessionID {
                outcome = await coordinator.cancel(sessionID: sessionID)
            } else {
                outcome = .noActiveSession
            }
            applyCancellationOutcome(
                outcome,
                cancelledBeforeSessionStart: cancelledBeforeSessionStart
            )
            cancellationTask = nil
            if operationTask == nil, activeSessionID == nil {
                isCancellationRequested = false
            }
            notifyCancellationAvailability()
        }
    }

    @discardableResult
    private func registerConfiguredHotKey() -> Bool {
        hotKey.unregister()
        isHotKeyRegistered = false
        guard settings.pushToTalkEnabled else {
            settings.updatePushToTalkRegistrationStatus(.disabled)
            return true
        }
        guard !settings.isShortcutCaptureActive else {
            settings.updatePushToTalkRegistrationStatus(.suspended)
            return true
        }
        do {
            try hotKey.register(configuration: settings.shortcut.configuration) { [weak self] event in
                self?.handleHotKey(event)
            }
            isHotKeyRegistered = true
            settings.updatePushToTalkRegistrationStatus(.registered)
            return true
        } catch let error as GlobalHotKeyError {
            settings.updatePushToTalkRegistrationStatus(.failed(error.status))
            flowBar.show(.error)
            scheduleFlowBarHide(after: .seconds(2))
            return false
        } catch {
            settings.updatePushToTalkRegistrationStatus(.failed(nil))
            flowBar.show(.error)
            scheduleFlowBarHide(after: .seconds(2))
            return false
        }
    }

    private func handleHotKey(_ event: PushToTalkHotKeyEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        let action = activationReducer.consume(event, at: now)
        switch action {
        case .beginPushToTalk:
            if pendingPushToTalkStopTask != nil {
                pendingPushToTalkStopTask?.cancel()
                pendingPushToTalkStopTask = nil
                finishRecordingNow()
            } else if canCancelActiveOperation {
                cancelActiveSession()
            } else if !isCancellationRequested {
                beginPushToTalk()
            }
        case .endPushToTalk:
            requestPushToTalkEnd(at: now)
        case .beginHandsFree:
            pendingPushToTalkStopTask?.cancel()
            pendingPushToTalkStopTask = nil
            isHandsFreeActive = true
            if activeSessionID != nil {
                showFlow(.listening)
            } else if operationTask == nil, !isCancellationRequested {
                beginPushToTalk()
            }
        case .endHandsFree:
            pendingPushToTalkStopTask?.cancel()
            pendingPushToTalkStopTask = nil
            isHandsFreeActive = false
            finishRecordingNow()
        case .none:
            break
        }
    }

    private func requestPushToTalkEnd(at time: TimeInterval) {
        guard settings.handsFreeEnabled,
              activationReducer.isAwaitingSecondTap(at: time),
              let deadline = activationReducer.secondTapDeadline else {
            finishRecordingNow()
            return
        }
        pendingPushToTalkStopTask?.cancel()
        pendingPushToTalkStopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline - time)))
            guard !Task.isCancelled else { return }
            self?.pendingPushToTalkStopTask = nil
            self?.finishRecordingNow()
        }
    }

    private func beginPushToTalk() {
        guard operationTask == nil,
              cancellationTask == nil,
              activeSessionID == nil,
              !isCancellationRequested else { return }
        largeIdleUnloadTask?.cancel()
        largeIdleUnloadTask = nil
        errorTerminalSessionID = nil
        permissions.refresh()
        guard capabilityStatus.canStartLocalDictation else {
            resetActivationState()
            flowGeneration &+= 1
            showFlow(.error)
            scheduleFlowBarHide(after: .seconds(2))
            presentSettings()
            return
        }

        pendingReleaseConsent = nil
        flowGeneration &+= 1
        showFlow(.priming)
        let language = settings.language
        let localModel = settings.localModel
        setCancellationAvailability(true)

        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { finishOperationTask() }
            await recordingHistorySetupTask?.value
            await recordingHistoryRecoveryTask.value
            await fallbackResults.removeAll()
            guard !isCancellationRequested else { return }
            let outcome = await coordinator.start(language: language)
            switch outcome {
            case .started(let sessionID):
                let actualRecordingStartedAt = await coordinator.recordingStartDate(for: sessionID)
                    ?? Date()
                guard !isCancellationRequested else {
                    let cancellationOutcome = await coordinator.cancel(sessionID: sessionID)
                    applyCancellationOutcome(cancellationOutcome)
                    return
                }
                do {
                    try await speechRecognizer.acquireExclusiveAccess(
                        for: sessionID,
                        purpose: .liveDictation
                    )
                } catch {
                    _ = await coordinator.cancel(sessionID: sessionID)
                    resetActivationState()
                    setCancellationAvailability(false)
                    diagnostics.failure(.serviceFailure, stage: .audioFinalize, sessionID: sessionID)
                    showFlow(.error)
                    scheduleFlowBarHide(after: .seconds(2))
                    return
                }
                await speechRecognizer.register(localModel, for: sessionID)
                await enrichment.register(language: language, for: sessionID)
                await coordinator.beginIncrementalRecognition(sessionID: sessionID)
                let prioritizedTerms = personalLexicon.prioritizedDecoderTerms(for: language)
                let prewarmHints = RecognitionHints(
                    language: language,
                    terms: [],
                    prioritizedLexiconTerms: prioritizedTerms
                )
                Task { [speechRecognizer, localRewriter, sessionDiagnostics] in
                    async let prepareASR: Void = {
                        let clock = ContinuousClock()
                        let startedAt = clock.now
                        let succeeded: Bool
                        do {
                            try await speechRecognizer.prepareForRecording(
                                hints: prewarmHints,
                                sessionID: sessionID
                            )
                            succeeded = true
                        } catch {
                            succeeded = false
                        }
                        let duration = startedAt.duration(to: clock.now).components
                        let milliseconds = (Double(duration.seconds) * 1_000)
                            + (Double(duration.attoseconds) / 1_000_000_000_000_000)
                        await sessionDiagnostics.recordPrewarm(
                            succeeded: succeeded,
                            latencyMilliseconds: milliseconds,
                            sessionID: sessionID
                        )
                    }()
                    async let prepareRewrite: TextRewritePrewarmResult = localRewriter.prewarm(
                        TextRewritePrewarmRequest(
                            sessionID: sessionID,
                            language: TextRewriteLanguage(language),
                            context: TextRewriteContext(
                                category: .other,
                                availability: .unavailable,
                                boundedText: nil,
                                protectedTerms: prioritizedTerms
                            ),
                            promptPrefix: """
                            Sprache: Deutsch
                            Policy: contextSupportedReconstruction
                            Lokaler Kandidat:
                            """
                        )
                    )
                    _ = await (prepareASR, prepareRewrite)
                }
                guard !isCancellationRequested else {
                    let cancellationOutcome = await coordinator.cancel(sessionID: sessionID)
                    await speechRecognizer.cancel(sessionID: sessionID)
                    applyCancellationOutcome(cancellationOutcome)
                    return
                }
                activeSessionID = sessionID
                recordingStartedAt = actualRecordingStartedAt
                scheduleAutomaticFinalization(
                    for: sessionID,
                    recordingStartedAt: actualRecordingStartedAt
                )
                diagnostics.state(.started, stage: .audioFinalize, sessionID: sessionID)
                showFlow(.listening)
                setCancellationAvailability(true)
                if let consent = pendingReleaseConsent {
                    pendingReleaseConsent = nil
                    await completePushToTalk(sessionID: sessionID, consent: consent)
                }
            case .alreadyActive(let sessionID):
                guard !isCancellationRequested else {
                    let cancellationOutcome = await coordinator.cancel(sessionID: sessionID)
                    applyCancellationOutcome(cancellationOutcome)
                    return
                }
                do {
                    try await speechRecognizer.acquireExclusiveAccess(
                        for: sessionID,
                        purpose: .liveDictation
                    )
                } catch {
                    resetActivationState()
                    setCancellationAvailability(false)
                    showFlow(.error)
                    scheduleFlowBarHide(after: .seconds(2))
                    return
                }
                guard !isCancellationRequested else {
                    let cancellationOutcome = await coordinator.cancel(sessionID: sessionID)
                    await speechRecognizer.cancel(sessionID: sessionID)
                    applyCancellationOutcome(cancellationOutcome)
                    return
                }
                activeSessionID = sessionID
                showFlow(.listening)
                setCancellationAvailability(true)
            case .ignoredStale:
                resetActivationState()
                setCancellationAvailability(false)
                showFlow(.cancelled)
                scheduleFlowBarHide(after: .seconds(1))
            case .failed(let sessionID, let failure):
                resetActivationState()
                setCancellationAvailability(false)
                diagnostics.failure(.serviceFailure, stage: .audioFinalize, sessionID: sessionID)
                showFlow(failure.stage == .context ? .textFieldRequired : .error)
                scheduleFlowBarHide(after: .seconds(2))
            }
        }
    }

    private func finishRecordingNow() {
        guard !isCancellationRequested else { return }
        let consent = settings.consentSnapshot()
        if operationTask != nil, activeSessionID == nil {
            resetActivationState()
            pendingReleaseConsent = consent
            return
        }
        guard operationTask == nil, let sessionID = activeSessionID else { return }
        resetActivationState()
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { finishOperationTask() }
            await completePushToTalk(sessionID: sessionID, consent: consent)
        }
        setCancellationAvailability(true)
    }

    private func completePushToTalk(
        sessionID: DictationSessionID,
        consent: ConsentSnapshot
    ) async {
        pendingPushToTalkStopTask?.cancel()
        pendingPushToTalkStopTask = nil
        automaticFinalizationTask?.cancel()
        automaticFinalizationTask = nil
        showFlow(consent.cloudEnabled ? .cloudProcessing : .processing)
        let coordinator = coordinator
        let outcome = await diagnostics.measure(stage: .total, sessionID: sessionID) {
            await coordinator.stop(sessionID: sessionID, consent: consent)
        }
        await sessionDiagnostics.finalize(
            sessionID: sessionID,
            diagnostics: diagnostics
        )
        await persistDiagnostics()
        if activeSessionID == sessionID {
            activeSessionID = nil
        }
        recordingStartedAt = nil
        isHandsFreeActive = false
        setCancellationAvailability(false)

        switch outcome {
        case .completed(_, .confirmedDirect):
            diagnostics.state(.completed, stage: .insertion, sessionID: sessionID)
            showFlow(.inserted)
            scheduleFlowBarHide(after: .milliseconds(850))
        case .completed(_, .safeFallback):
            diagnostics.failure(.unconfirmedMutation, stage: .insertion, sessionID: sessionID)
            _ = await fallbackResults.discard(sessionID: sessionID)
            showFlow(.error)
            scheduleFlowBarHide(after: .seconds(2))
        case .noSpeech:
            diagnostics.state(.completed, stage: .audioFinalize, sessionID: sessionID)
            showFlow(.noSpeech)
            scheduleFlowBarHide(after: .seconds(1))
        case .ignoredDuplicate, .ignoredStale:
            diagnostics.failure(.staleSession, stage: .total, sessionID: sessionID)
            if errorTerminalSessionID == sessionID {
                errorTerminalSessionID = nil
            } else {
                showFlow(.cancelled)
                scheduleFlowBarHide(after: .seconds(1))
            }
        case .failed(let failedSessionID, _):
            diagnostics.failure(.serviceFailure, stage: .total, sessionID: sessionID)
            _ = await fallbackResults.discard(sessionID: failedSessionID)
            showFlow(.error)
            scheduleFlowBarHide(after: .seconds(2))
        }
        scheduleLargeUnloadAfterIdle()
    }

    private func showFlow(_ presentation: FlowBarPresentation) {
        flowBar.show(
            presentation,
            recordingStartedAt: presentation == .listening ? recordingStartedAt : nil,
            handsFree: presentation == .listening && isHandsFreeActive
        ) { [weak self] in
            self?.cancelActiveSession()
        }
    }

    private func resetActivationState() {
        activationReducer.reset(
            mode: settings.handsFreeEnabled ? .doubleTap : .disabled
        )
        isHandsFreeActive = false
    }

    private func scheduleAutomaticFinalization(
        for sessionID: DictationSessionID,
        recordingStartedAt: Date
    ) {
        automaticFinalizationTask?.cancel()
        automaticFinalizationTask = Task { @MainActor [weak self] in
            let remainingDuration = RecordingDeadline.remainingDuration(
                recordingStartedAt: recordingStartedAt
            )
            try? await Task.sleep(for: .seconds(remainingDuration))
            guard !Task.isCancelled,
                  let self,
                  self.activeSessionID == sessionID else { return }
            self.finishRecordingNow()
        }
    }

    private func applyCancellationOutcome(
        _ outcome: CancelOutcome,
        cancelledBeforeSessionStart: Bool = false
    ) {
        if case .failed(let sessionID, _) = outcome {
            errorTerminalSessionID = sessionID
        }

        if let sessionID = outcome.terminatedSessionID,
           activeSessionID == sessionID {
            activeSessionID = nil
            Task { [sessionDiagnostics] in
                await sessionDiagnostics.cancel(sessionID: sessionID)
            }
        }

        switch outcome.presentationDecision(
            errorTerminalSessionID: errorTerminalSessionID,
            cancelledBeforeSessionStart: cancelledBeforeSessionStart
        ) {
        case .showCancelled:
            automaticFinalizationTask?.cancel()
            automaticFinalizationTask = nil
            pendingPushToTalkStopTask?.cancel()
            pendingPushToTalkStopTask = nil
            recordingStartedAt = nil
            isHandsFreeActive = false
            flowGeneration &+= 1
            showFlow(.cancelled)
            scheduleFlowBarHide(after: .seconds(1))
        case .showError:
            presentCancellationError()
        case .deferToOperationCompletion, .unchanged:
            break
        }
    }

    private func handleRecordingHistoryCheckpointFailure(
        _ sessionID: DictationSessionID
    ) {
        guard activeSessionID == sessionID, !isCancellationRequested else { return }
        errorTerminalSessionID = sessionID
        diagnostics.failure(.serviceFailure, stage: .audioFinalize, sessionID: sessionID)
        cancelActiveSession()
    }

    private func presentCancellationError() {
        automaticFinalizationTask?.cancel()
        automaticFinalizationTask = nil
        pendingPushToTalkStopTask?.cancel()
        pendingPushToTalkStopTask = nil
        recordingStartedAt = nil
        isHandsFreeActive = false
        setCancellationAvailability(false)
        flowGeneration &+= 1
        showFlow(.error)
        scheduleFlowBarHide(after: .seconds(2))
    }

    private func finishOperationTask() {
        operationTask = nil
        if cancellationTask == nil, activeSessionID == nil {
            isCancellationRequested = false
            setCancellationAvailability(false)
        } else {
            notifyCancellationAvailability()
        }
    }

    private func setCancellationAvailability(_ available: Bool) {
        cancellationAvailable = available
        notifyCancellationAvailability()
    }

    private func notifyCancellationAvailability() {
        onCancellationAvailabilityChanged?(canCancelActiveOperation)
    }

    private func scheduleFlowBarHide(after duration: Duration) {
        let generation = flowGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard let self, generation == flowGeneration else { return }
            flowBar.hide()
        }
    }

    private func scheduleLargeUnloadAfterIdle() {
        largeIdleUnloadTask?.cancel()
        largeIdleUnloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled, let self else { return }
            largeIdleUnloadTask = nil
            await unloadLargeIfIdle()
        }
    }

    private func configureMemoryPressureHandling() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            largeIdleUnloadTask?.cancel()
            largeIdleUnloadTask = nil
            Task { @MainActor [weak self] in
                await self?.unloadLargeIfIdle()
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    private func unloadLargeIfIdle() async {
        nextMaintenanceSessionRawValue &-= 1
        let sessionID = DictationSessionID(rawValue: nextMaintenanceSessionRawValue)
        do {
            try await speechRecognizer.acquireExclusiveAccess(
                for: sessionID,
                purpose: .modelMaintenance
            )
        } catch {
            return
        }
        await adaptiveRecognizer.unloadLarge()
        await speechRecognizer.releaseExclusiveAccess(for: sessionID)
    }

    private func persistDiagnostics() async {
        let current = await diagnostics.reportV2()
        let report = diagnosticsBaseline?.merging(current) ?? current
        try? diagnosticsStore.save(report)
    }
}
