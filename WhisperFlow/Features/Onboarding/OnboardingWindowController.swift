import AppKit
import Combine
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController {
    private let store: SettingsStore
    private let permissions: PermissionCenter
    private let model: ModelProvisioningViewModel
    private var readinessObservation: AnyCancellable?

    init(
        store: SettingsStore,
        permissions: PermissionCenter,
        model: ModelProvisioningViewModel
    ) {
        self.store = store
        self.permissions = permissions
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "FlusterFlow einrichten"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(
            rootView: OnboardingView(
                store: store,
                permissions: permissions,
                model: model,
                finish: { [weak self] in self?.finish() }
            )
        )
    }

    required init?(coder: NSCoder) {
        nil
    }

    func presentIfNeeded() {
        permissions.refresh()
        model.refresh()
        readinessObservation?.cancel()
        guard store.onboardingCompleted else {
            present()
            return
        }

        readinessObservation = model.$activity
            .filter { $0 != .checking }
            .first()
            .sink { [weak self] _ in
                Task { @MainActor in self?.presentIfReadinessMissing() }
            }
    }

    private func presentIfReadinessMissing() {
        guard !currentReadiness.canStartLocalDictation else { return }
        present()
    }

    private func present() {
        showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private var currentReadiness: DictationCapabilityStatus {
        DictationCapabilityStatus(
            microphone: permissions.microphone,
            accessibility: permissions.accessibility,
            model: model.status
        )
    }

    private func finish() {
        guard currentReadiness.canStartLocalDictation else { return }
        readinessObservation?.cancel()
        readinessObservation = nil
        store.onboardingCompleted = true
        close()
    }
}

private struct OnboardingView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var permissions: PermissionCenter
    @ObservedObject var model: ModelProvisioningViewModel
    let finish: () -> Void

    @State private var confirmsDownload = false

    private var readiness: DictationCapabilityStatus {
        DictationCapabilityStatus(
            microphone: permissions.microphone,
            accessibility: permissions.accessibility,
            model: model.status
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.cyan)
                        .accessibilityHidden(true)
                    Text("Diktieren, ohne den Fokus zu verlieren")
                        .font(.largeTitle.bold())
                    Text("FlusterFlow verarbeitet Sprache standardmäßig vollständig lokal auf diesem Mac.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                PermissionRow(
                    symbol: "mic.fill",
                    title: "Mikrofon",
                    detail: "Nur während gedrücktem Push-to-talk.",
                    status: permissions.microphone,
                    isRequired: true,
                    buttonTitle: permissions.microphoneRequestButtonTitle,
                    action: permissions.requestMicrophone
                )
                PermissionRow(
                    symbol: "cursorarrow.and.square.on.square.dashed",
                    title: "Bedienungshilfen",
                    detail: "Optional für Kontext und automatisches Einfügen. Ohne Zugriff bleibt lokale Transkription verfügbar; sichere Inhalte werden immer abgelehnt.",
                    status: permissions.accessibility,
                    isRequired: false,
                    buttonTitle: "Bedienungshilfen öffnen",
                    action: permissions.requestAccessibility
                )

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "cpu")
                            .font(.title2)
                            .frame(width: 32)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Lokales Sprachmodell").font(.headline)
                            Text(model.statusTitle)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Picker("Modell", selection: $store.localModel) {
                        ForEach(LocalModelChoice.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .disabled(model.isBusy)
                    Text(store.localModel.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(model.statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Ordner importieren", action: chooseModelDirectory)
                        Button("Gepinntes Modell laden …") { confirmsDownload = true }
                    }
                    .disabled(model.isBusy)
                    Text("Kein automatischer Download. Beide Wege prüfen die gepinnte Modellrevision und SHA-256-Werte.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .contain)

                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Push-to-talk aktivieren", isOn: $store.pushToTalkEnabled)

                    Toggle("Handsfree per Doppeltipp", isOn: $store.handsFreeEnabled)
                        .disabled(!store.pushToTalkEnabled)
                        .font(.headline)
                    LabeledContent("Tastenkürzel") {
                        ShortcutRecorderField(
                            shortcut: $store.shortcut,
                            onRecordingChanged: store.setShortcutCaptureActive
                        )
                        .frame(width: 250, height: 30)
                        .disabled(!store.pushToTalkEnabled)
                    }
                    Text("Klicken und ein Kürzel mit mindestens einer Sondertaste drücken. Während der Aufnahme ist der bisherige globale Shortcut pausiert.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline) {
                        Label(
                            store.pushToTalkRegistrationStatus.title,
                            systemImage: store.pushToTalkRegistrationStatus.isFailure
                                ? "exclamationmark.triangle.fill"
                                : "keyboard.badge.ellipsis"
                        )
                        .foregroundStyle(
                            store.pushToTalkRegistrationStatus.isFailure ? .orange : .secondary
                        )
                        Spacer()
                        if store.pushToTalkRegistrationStatus.isFailure {
                            Button("Erneut registrieren") {
                                store.retryPushToTalkRegistration()
                            }
                            .controlSize(.small)
                        }
                    }
                    .font(.caption)
                    if let detail = store.pushToTalkRegistrationStatus.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(16)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))

                Label {
                    Text(readiness.canStartLocalDictation
                        ? "Bereit: Das fertige Diktat wird direkt an der aktuellen Einfügemarke eingesetzt."
                        : "Für direktes Diktieren werden Mikrofon, Bedienungshilfen und ein geprüftes lokales Modell benötigt.")
                } icon: {
                    Image(systemName: readiness.canStartLocalDictation ? "checkmark.circle.fill" : "info.circle.fill")
                        .accessibilityHidden(true)
                }
                .font(.callout.weight(.medium))
                .foregroundStyle(readiness.canStartLocalDictation ? .green : .orange)
                .accessibilityLabel(readiness.canStartLocalDictation ? "Diktat bereit" : "Einrichtung unvollständig")

                HStack(spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                    Text("Keine Aufnahmehistorie · keine Telemetrie · keine automatische Zwischenablage · Cloud aus")
                        .font(.callout.weight(.medium))
                }

                HStack {
                    Text(store.pushToTalkEnabled
                        ? "Push-to-talk: \(store.shortcut.title) halten"
                        : "Push-to-talk ist deaktiviert")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Einrichtung abschließen", action: finish)
                        .buttonStyle(.borderedProminent)
                        .disabled(!readiness.canStartLocalDictation)
                        .accessibilityHint(
                            readiness.canStartLocalDictation
                                ? "Schließt die Einrichtung ab"
                                : "Erfordert Mikrofon, Bedienungshilfen und ein geprüftes lokales Modell"
                        )
                }
            }
            .padding(32)
        }
        .frame(minWidth: 610, minHeight: 620)
        .task {
            permissions.refresh()
            model.refresh()
        }
        .confirmationDialog(
            "Gepinntes Sprachmodell laden?",
            isPresented: $confirmsDownload,
            titleVisibility: .visible
        ) {
            Button(model.downloadConfirmationTitle) {
                model.downloadPinnedModelAfterConfirmation()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Dies startet genau jetzt einen einmaligen HTTPS-Download. Diktate selbst laden nie Modelle nach.")
        }
    }

    private func chooseModelDirectory() {
        let panel = NSOpenPanel()
        panel.title = model.importPanelTitle
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        model.importLocalModel(from: directory)
    }
}

private struct PermissionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let status: PermissionState
    let isRequired: Bool
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(status.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(status == .authorized ? .green : .orange)
                Text(isRequired ? "Erforderlich" : "Optional")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if status != .authorized {
                Button(buttonTitle, action: action)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(isRequired ? "erforderlich" : "optional"), \(status.title)")
    }
}
