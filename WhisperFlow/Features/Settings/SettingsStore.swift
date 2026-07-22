@preconcurrency import Carbon
import Foundation
import ServiceManagement

struct PushToTalkShortcut: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case keyCode
        case carbonModifiers
        case keyLabel
    }

    private static let commandModifier = UInt32(cmdKey)
    private static let controlModifier = UInt32(controlKey)
    private static let optionModifier = UInt32(optionKey)
    private static let shiftModifier = UInt32(shiftKey)
    private static let allowedModifiers = commandModifier
        | controlModifier
        | optionModifier
        | shiftModifier

    static let controlOptionSpace = Self(
        keyCode: UInt32(kVK_Space),
        carbonModifiers: controlModifier | optionModifier,
        keyLabel: "Leertaste"
    )!
    static let controlShiftSpace = Self(
        keyCode: UInt32(kVK_Space),
        carbonModifiers: controlModifier | shiftModifier,
        keyLabel: "Leertaste"
    )!
    static let optionShiftSpace = Self(
        keyCode: UInt32(kVK_Space),
        carbonModifiers: optionModifier | shiftModifier,
        keyLabel: "Leertaste"
    )!

    let keyCode: UInt32
    let carbonModifiers: UInt32
    let keyLabel: String

    init?(keyCode: UInt32, carbonModifiers: UInt32, keyLabel: String) {
        let normalizedLabel = keyLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard keyCode <= UInt32(UInt16.max),
              carbonModifiers != 0,
              carbonModifiers & ~Self.allowedModifiers == 0,
              !normalizedLabel.isEmpty,
              normalizedLabel.count <= 20,
              normalizedLabel.rangeOfCharacter(from: .controlCharacters) == nil else {
            return nil
        }
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.keyLabel = normalizedLabel
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let keyCode = try values.decode(UInt32.self, forKey: .keyCode)
        let carbonModifiers = try values.decode(UInt32.self, forKey: .carbonModifiers)
        let keyLabel = try values.decode(String.self, forKey: .keyLabel)
        guard let shortcut = Self(
            keyCode: keyCode,
            carbonModifiers: carbonModifiers,
            keyLabel: keyLabel
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .keyCode,
                in: values,
                debugDescription: "Invalid push-to-talk shortcut"
            )
        }
        self = shortcut
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(keyCode, forKey: .keyCode)
        try values.encode(carbonModifiers, forKey: .carbonModifiers)
        try values.encode(keyLabel, forKey: .keyLabel)
    }

    var title: String {
        var symbols = ""
        if carbonModifiers & Self.controlModifier != 0 { symbols += "⌃" }
        if carbonModifiers & Self.optionModifier != 0 { symbols += "⌥" }
        if carbonModifiers & Self.shiftModifier != 0 { symbols += "⇧" }
        if carbonModifiers & Self.commandModifier != 0 { symbols += "⌘" }
        return symbols + keyLabel
    }

    var configuration: PushToTalkHotKeyConfiguration {
        PushToTalkHotKeyConfiguration(
            keyCode: keyCode,
            carbonModifiers: carbonModifiers
        )
    }

    static func legacyValue(_ rawValue: String?) -> Self? {
        switch rawValue {
        case "controlOptionSpace": .controlOptionSpace
        case "controlShiftSpace": .controlShiftSpace
        case "optionShiftSpace": .optionShiftSpace
        default: nil
        }
    }
}

enum LocalModelChoice: String, CaseIterable, Identifiable, Sendable {
    case adaptive
    case parakeetV3Int8
    case qwen3ASR06B8Bit
    case whisperKitLargeV3
    case whisperKitLargeV3Turbo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .adaptive:
            "Adaptiv · empfohlen"
        case .parakeetV3Int8:
            "Parakeet"
        case .qwen3ASR06B8Bit:
            "Qwen"
        case .whisperKitLargeV3:
            "Large v3"
        case .whisperKitLargeV3Turbo:
            "Turbo"
        }
    }

    var detail: String {
        switch self {
        case .adaptive:
            "Empfohlener Normalmodus: startet mit Turbo und prüft Qualitätsrisiken lokal mit Large v3 nach."
        case .parakeetV3Int8:
            "FluidAudio 0.15.5 · ca. 483 MB · lokal"
        case .qwen3ASR06B8Bit:
            "MLXAudioSTT 0.1.3 · ca. 1,01 GB · multilingual · lokal"
        case .whisperKitLargeV3:
            "WhisperKit 1.0.0 · ca. 627 MB · multilingual · lokal"
        case .whisperKitLargeV3Turbo:
            "WhisperKit 1.0.0 · ca. 646 MB · multilingual · lokal"
        }
    }

    var manifest: ModelManifest {
        switch self {
        case .adaptive: .whisperLargeV3Turbo
        case .parakeetV3Int8: .parakeetV3Int8
        case .qwen3ASR06B8Bit: .qwen3ASR06B8Bit
        case .whisperKitLargeV3: .whisperLargeV3
        case .whisperKitLargeV3Turbo: .whisperLargeV3Turbo
        }
    }

    var requiresWhisperTokenizer: Bool {
        switch self {
        case .adaptive, .whisperKitLargeV3, .whisperKitLargeV3Turbo:
            true
        case .parakeetV3Int8, .qwen3ASR06B8Bit:
            false
        }
    }
}

enum CloudModelChoice: String, CaseIterable, Identifiable, Sendable {
    case gpt56Luna

    var id: String { rawValue }

    var title: String { "GPT-5.6 Luna" }

    var identifier: CloudModelIdentifier {
        .defaultEfficientModel
    }
}

enum PushToTalkRegistrationStatus: Equatable, Sendable {
    case initializing
    case disabled
    case suspended
    case registered
    case failed(OSStatus?)

    var title: String {
        switch self {
        case .initializing:
            "Globaler Shortcut wird registriert …"
        case .disabled:
            "Push-to-talk ist deaktiviert"
        case .suspended:
            "Globaler Shortcut ist während der Aufnahme pausiert"
        case .registered:
            "Globaler Shortcut ist aktiv"
        case .failed(let status) where status == OSStatus(eventHotKeyExistsErr):
            "Tastenkürzel wird bereits von einer anderen App verwendet"
        case .failed:
            "Globaler Shortcut konnte nicht registriert werden"
        }
    }

    var detail: String? {
        switch self {
        case .failed(let status) where status == OSStatus(eventHotKeyExistsErr):
            return "Wähle ein anderes Kürzel oder beende die App, die diese Kombination bereits global verwendet."
        case .failed(let status):
            if let status {
                return "Systemfehler \(status). Wähle ein anderes Kürzel oder versuche die Registrierung erneut."
            }
            return "Wähle ein anderes Kürzel oder versuche die Registrierung erneut."
        case .initializing, .disabled, .suspended, .registered:
            return nil
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    private static let applicationPreferencesDomain = "com.flusterflow.private"

    private enum Key {
        static let contextAwareness = "flusterflow.context-awareness"
        static let localLearning = "flusterflow.local-learning-enabled"
        static let language = "flusterflow.language"
        static let pushToTalkEnabled = "flusterflow.push-to-talk-enabled"
        static let shortcut = "flusterflow.shortcut"
        static let legacySelectedMicrophone = "flusterflow.selected-microphone"
        static let localModel = "flusterflow.local-model"
        static let cloudEnabled = "flusterflow.cloud-enabled"
        static let cloudContext = "flusterflow.cloud-context"
        static let cloudModel = "flusterflow.cloud-model"
        static let onboardingCompleted = "flusterflow.onboarding-completed"
    }

    @Published var contextAwarenessEnabled: Bool {
        didSet { defaults.set(contextAwarenessEnabled, forKey: Key.contextAwareness) }
    }

    @Published var localLearningEnabled: Bool {
        didSet { defaults.set(localLearningEnabled, forKey: Key.localLearning) }
    }

    @Published var language: DictationLanguage {
        didSet { defaults.set(language.storageValue, forKey: Key.language) }
    }

    @Published var pushToTalkEnabled: Bool {
        didSet {
            defaults.set(pushToTalkEnabled, forKey: Key.pushToTalkEnabled)
            onPushToTalkConfigurationChanged?()
        }
    }

    @Published var shortcut: PushToTalkShortcut {
        didSet {
            defaults.set(try? JSONEncoder().encode(shortcut), forKey: Key.shortcut)
            onPushToTalkConfigurationChanged?()
        }
    }

    @Published private(set) var isShortcutCaptureActive = false
    @Published private(set) var pushToTalkRegistrationStatus: PushToTalkRegistrationStatus = .initializing

    @Published var localModel: LocalModelChoice {
        didSet {
            defaults.set(localModel.rawValue, forKey: Key.localModel)
            onLocalModelChanged?(localModel)
        }
    }

    @Published var cloudEnabled: Bool {
        didSet { defaults.set(cloudEnabled, forKey: Key.cloudEnabled) }
    }

    @Published var cloudContextEnabled: Bool {
        didSet { defaults.set(cloudContextEnabled, forKey: Key.cloudContext) }
    }

    @Published var cloudModel: CloudModelChoice {
        didSet { defaults.set(cloudModel.rawValue, forKey: Key.cloudModel) }
    }

    @Published private(set) var launchAtLoginEnabled: Bool
    @Published private(set) var launchAtLoginUpdateFailed = false

    var onPushToTalkConfigurationChanged: (() -> Void)?
    var onLocalModelChanged: ((LocalModelChoice) -> Void)?

    private let defaults: UserDefaults

    init(defaults suppliedDefaults: UserDefaults? = nil) {
        let defaults = suppliedDefaults ?? Self.applicationDefaults()
        self.defaults = defaults
        defaults.removeObject(forKey: Key.legacySelectedMicrophone)
        if defaults.object(forKey: Key.contextAwareness) == nil {
            contextAwarenessEnabled = true
        } else {
            contextAwarenessEnabled = defaults.bool(forKey: Key.contextAwareness)
        }
        if defaults.object(forKey: Key.localLearning) == nil {
            localLearningEnabled = true
        } else {
            localLearningEnabled = defaults.bool(forKey: Key.localLearning)
        }
        language = DictationLanguage(storageValue: defaults.string(forKey: Key.language))
        if defaults.object(forKey: Key.pushToTalkEnabled) == nil {
            pushToTalkEnabled = true
        } else {
            pushToTalkEnabled = defaults.bool(forKey: Key.pushToTalkEnabled)
        }
        shortcut = Self.loadShortcut(from: defaults)
        localModel = LocalModelChoice(
            rawValue: defaults.string(forKey: Key.localModel) ?? ""
        ) ?? .adaptive
        cloudEnabled = defaults.bool(forKey: Key.cloudEnabled)
        cloudContextEnabled = defaults.bool(forKey: Key.cloudContext)
        cloudModel = CloudModelChoice(
            rawValue: defaults.string(forKey: Key.cloudModel) ?? ""
        ) ?? .gpt56Luna
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    func setShortcutCaptureActive(_ active: Bool) {
        guard isShortcutCaptureActive != active else { return }
        isShortcutCaptureActive = active
        onPushToTalkConfigurationChanged?()
    }

    func retryPushToTalkRegistration() {
        onPushToTalkConfigurationChanged?()
    }

    func updatePushToTalkRegistrationStatus(_ status: PushToTalkRegistrationStatus) {
        pushToTalkRegistrationStatus = status
    }

    var onboardingCompleted: Bool {
        get { defaults.bool(forKey: Key.onboardingCompleted) }
        set { defaults.set(newValue, forKey: Key.onboardingCompleted) }
    }

    func consentSnapshot() -> ConsentSnapshot {
        ConsentSnapshot(
            cloudEnabled: cloudEnabled,
            contextToCloud: cloudEnabled && cloudContextEnabled
        )
    }

    func disableCloud() {
        cloudEnabled = false
        cloudContextEnabled = false
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            launchAtLoginUpdateFailed = false
        } catch {
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            launchAtLoginUpdateFailed = true
        }
    }

    private static func loadShortcut(from defaults: UserDefaults) -> PushToTalkShortcut {
        if let data = defaults.data(forKey: Key.shortcut),
           let shortcut = try? JSONDecoder().decode(PushToTalkShortcut.self, from: data) {
            return shortcut
        }
        return PushToTalkShortcut.legacyValue(defaults.string(forKey: Key.shortcut))
            ?? .controlOptionSpace
    }

    private static func applicationDefaults() -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: applicationPreferencesDomain) else {
            return .standard
        }
        return defaults
    }
}

extension DictationLanguage {
    var title: String {
        switch self {
        case .automatic: "Automatisch"
        case .german: "Deutsch"
        case .english: "Englisch"
        }
    }

    var storageValue: String {
        switch self {
        case .automatic: "automatic"
        case .german: "german"
        case .english: "english"
        }
    }

    init(storageValue: String?) {
        switch storageValue {
        case "german": self = .german
        case "english": self = .english
        default: self = .automatic
        }
    }
}
