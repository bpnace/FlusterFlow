import Combine
import Dispatch
import Foundation

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

enum CancellationPresentationDecision: Equatable, Sendable {
    case showCancelled
    case deferToOperationCompletion
    case unchanged
}

extension CancelOutcome {
    var presentationDecision: CancellationPresentationDecision {
        switch self {
        case .cancelled:
            .showCancelled
        case .tooLateCommitted:
            .deferToOperationCompletion
        case .ignoredStale, .noActiveSession:
            .unchanged
        }
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

    private let hotKey: any PushToTalkHotKeyControlling
    private let diagnostics: ContentFreeDiagnostics
    private let diagnosticsStore: DiagnosticsV2AggregateStore
    private let diagnosticsBaseline: DiagnosticsV2Report?
    private let speechRecognizer: SessionModelSpeechRecognizer
    private let adaptiveRecognizer: AdaptiveWhisperKitRecognizer
    private let enrichment: SessionAwareOpenAIEnrichment
    private let localRewriter: FoundationModelsTextRewriter
    private let sessionDiagnostics: ContentFreeSessionDiagnostics
    private let fallbackResults: EphemeralResultStore
    private let flowBar = FlowBarController()
    private let diagnosticsViewModel: DiagnosticsViewModel

    private lazy var settingsWindow = SettingsWindowController(
        store: settings,
        permissions: permissions,
        apiKey: apiKeySettings,
        model: modelProvisioning,
        diagnostics: diagnosticsViewModel,
        lexicon: personalLexicon
    )
    private lazy var onboardingWindow = OnboardingWindowController(
        store: settings,
        permissions: permissions,
        model: modelProvisioning
    )

    private var activeSessionID: DictationSessionID?
    private var operationTask: Task<Void, Never>?
    private var cancellationTask: Task<Void, Never>?
    private var pendingReleaseConsent: ConsentSnapshot?
    private var isCancellationRequested = false
    private var cancellationAvailable = false
    private var flowGeneration: UInt64 = 0
    private var isHotKeyRegistered = false
    private var capabilitySubscriptions: Set<AnyCancellable> = []
    private var largeIdleUnloadTask: Task<Void, Never>?
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    var onCancellationAvailabilityChanged: ((Bool) -> Void)?
    var onCapabilityStatusChanged: (() -> Void)?

    init(
        hotKey: any PushToTalkHotKeyControlling = CarbonPushToTalkHotKeyController(),
        settings suppliedSettings: SettingsStore? = nil
    ) {
        let settings = suppliedSettings ?? SettingsStore()
        let samples = AudioBufferStore()
        let permissions = PermissionCenter()
        let keyStore = KeychainAPIKeyStore()
        let apiKeySettings = APIKeySettingsModel(keyStore: keyStore)
        let personalLexicon = PersonalLexiconStore()
        let paths = AppPaths.live()
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
            ]
        )
        let diagnostics = ContentFreeDiagnostics()
        let composition = DictationComposition.live(
            settings: settings,
            audioSamples: samples,
            recognizer: speechRecognizer,
            personalLexicon: personalLexicon,
            keyStore: keyStore,
            diagnostics: diagnostics
        )

        self.settings = settings
        audioSamples = samples
        self.permissions = permissions
        self.apiKeySettings = apiKeySettings
        self.modelProvisioning = modelProvisioning
        self.personalLexicon = personalLexicon
        self.hotKey = hotKey
        self.speechRecognizer = speechRecognizer
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
        permissions.$microphone
            .combineLatest(permissions.$accessibility)
            .sink { [weak self] _ in
                Task { @MainActor in self?.onCapabilityStatusChanged?() }
            }
            .store(in: &capabilitySubscriptions)
    }

    var shortcutTitle: String { settings.shortcut.title }

    var serviceStatusTitle: String {
        guard settings.pushToTalkEnabled else {
            return "Push-to-talk deaktiviert"
        }
        guard !settings.isShortcutCaptureActive else {
            return "Tastenkürzel wird aufgenommen …"
        }
        guard isHotKeyRegistered else {
            return settings.pushToTalkRegistrationStatus.title
        }
        return capabilityStatus.statusTitle(shortcut: shortcutTitle)
    }

    var capabilityStatus: DictationCapabilityStatus {
        DictationCapabilityStatus(
            microphone: permissions.microphone,
            accessibility: permissions.accessibility,
            model: modelProvisioning.status
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
        hotKey.unregister()
        isHotKeyRegistered = false
        operationTask?.cancel()
        cancellationTask?.cancel()
        largeIdleUnloadTask?.cancel()
        operationTask = nil
        cancellationTask = nil
        largeIdleUnloadTask = nil
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

    func presentSettings() {
        settingsWindow.present()
    }

    func presentOnboardingIfNeeded() {
        onboardingWindow.presentIfNeeded()
    }

    func cancelActiveSession() {
        guard canCancelActiveOperation else { return }
        isCancellationRequested = true
        pendingReleaseConsent = nil
        setCancellationAvailability(false)

        let knownSessionID = activeSessionID
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
            applyCancellationOutcome(outcome)
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
        switch event {
        case .pressed:
            if canCancelActiveOperation {
                cancelActiveSession()
            } else if !isCancellationRequested {
                beginPushToTalk()
            }
        case .released:
            endPushToTalk()
        }
    }

    private func beginPushToTalk() {
        guard operationTask == nil,
              cancellationTask == nil,
              activeSessionID == nil,
              !isCancellationRequested else { return }
        permissions.refresh()
        guard capabilityStatus.canStartLocalDictation else {
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
            await fallbackResults.removeAll()
            guard !isCancellationRequested else { return }
            let outcome = await coordinator.start(language: language)
            switch outcome {
            case .started(let sessionID):
                guard !isCancellationRequested else {
                    let cancellationOutcome = await coordinator.cancel(sessionID: sessionID)
                    applyCancellationOutcome(cancellationOutcome)
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
                    applyCancellationOutcome(cancellationOutcome)
                    return
                }
                activeSessionID = sessionID
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
                activeSessionID = sessionID
                showFlow(.listening)
                setCancellationAvailability(true)
            case .ignoredStale:
                setCancellationAvailability(false)
                showFlow(.cancelled)
                scheduleFlowBarHide(after: .seconds(1))
            case .failed(let sessionID, let failure):
                setCancellationAvailability(false)
                diagnostics.failure(.serviceFailure, stage: .audioFinalize, sessionID: sessionID)
                showFlow(failure.stage == .context ? .textFieldRequired : .error)
                scheduleFlowBarHide(after: .seconds(2))
            }
        }
    }

    private func endPushToTalk() {
        guard !isCancellationRequested else { return }
        let consent = settings.consentSnapshot()
        if operationTask != nil, activeSessionID == nil {
            pendingReleaseConsent = consent
            return
        }
        guard operationTask == nil, let sessionID = activeSessionID else { return }
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
            showFlow(.cancelled)
            scheduleFlowBarHide(after: .seconds(1))
        case .failed(let failedSessionID, _):
            diagnostics.failure(.serviceFailure, stage: .total, sessionID: sessionID)
            _ = await fallbackResults.discard(sessionID: failedSessionID)
            showFlow(.error)
            scheduleFlowBarHide(after: .seconds(2))
        }
        scheduleLargeUnloadAfterIdle()
    }

    private func showFlow(_ presentation: FlowBarPresentation) {
        flowBar.show(presentation) { [weak self] in
            self?.cancelActiveSession()
        }
    }

    private func applyCancellationOutcome(_ outcome: CancelOutcome) {
        switch outcome.presentationDecision {
        case .showCancelled:
            if case .cancelled(let sessionID) = outcome,
               activeSessionID == sessionID {
                activeSessionID = nil
                Task { [sessionDiagnostics] in
                    await sessionDiagnostics.cancel(sessionID: sessionID)
                }
            }
            flowGeneration &+= 1
            showFlow(.cancelled)
            scheduleFlowBarHide(after: .seconds(1))
        case .deferToOperationCompletion, .unchanged:
            break
        }
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
        largeIdleUnloadTask = Task { [adaptiveRecognizer] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            await adaptiveRecognizer.unloadLarge()
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
            Task { [adaptiveRecognizer] in
                await adaptiveRecognizer.unloadLarge()
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    private func persistDiagnostics() async {
        let current = await diagnostics.reportV2()
        let report = diagnosticsBaseline?.merging(current) ?? current
        try? diagnosticsStore.save(report)
    }
}
