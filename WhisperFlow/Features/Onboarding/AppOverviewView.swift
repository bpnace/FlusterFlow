import AppKit
import SwiftUI

enum AppOverviewPrivacyCopy {
    static func localHistory(cloudEnabled: Bool) -> String {
        let cloudState = cloudEnabled
            ? "Cloud-Überarbeitung aktiv; Audio bleibt lokal"
            : "Cloud aus"
        return "Lokal löschbare Aufnahmehistorie · keine Telemetrie · keine automatische Zwischenablage · \(cloudState)"
    }
}

struct AppOverviewView: View {
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

    private var operationalStatus: DictationOperationalStatus {
        DictationOperationalStatus(
            capability: readiness,
            pushToTalkEnabled: store.pushToTalkEnabled,
            pushToTalkRegistrationStatus: store.pushToTalkRegistrationStatus
        )
    }

    private var modelNeedsAttention: Bool {
        if model.isBusy { return true }
        if case .ready = model.status { return false }
        return true
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            overviewContent

            ScrollView {
                overviewContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CoralEclipseStyle.canvas)
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

    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            readinessBand

            VStack(spacing: 0) {
                PermissionRow(
                    symbol: "mic.fill",
                    title: "Mikrofon",
                    detail: "Nur während einer Aufnahme",
                    status: permissions.microphone,
                    isRequired: true,
                    buttonTitle: permissions.microphoneRequestButtonTitle,
                    action: permissions.requestMicrophone
                )
                Divider()
                PermissionRow(
                    symbol: "cursorarrow.and.square.on.square.dashed",
                    title: "Bedienungshilfen",
                    detail: "Sicheres Einfügen am aktuellen Cursor",
                    status: permissions.accessibility,
                    isRequired: true,
                    buttonTitle: "Systemeinstellungen öffnen",
                    action: permissions.requestAccessibility
                )
                Divider()
                modelRow
                Divider()
                shortcutRow
            }

            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text(AppOverviewPrivacyCopy.localHistory(cloudEnabled: store.cloudEnabled))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !store.onboardingCompleted {
                ViewThatFits(in: .horizontal) {
                    setupCompletion(horizontal: true)
                    setupCompletion(horizontal: false)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: 760, alignment: .topLeading)
    }

    @ViewBuilder
    private func setupCompletion(horizontal: Bool) -> some View {
        if horizontal {
            HStack {
                setupCompletionText
                Spacer()
                setupCompletionButton
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                setupCompletionText
                setupCompletionButton
            }
        }
    }

    private var setupCompletionText: some View {
        Text("Sobald alles bereit ist, Einrichtung abschließen.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var setupCompletionButton: some View {
        Button("Einrichtung abschließen", action: finish)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(CoralEclipseStyle.charcoal)
            .disabled(!operationalStatus.canStartDictation)
            .accessibilityHint(
                operationalStatus.canStartDictation
                    ? "Schließt die Einrichtung ab"
                    : "Erfordert Mikrofon, Bedienungshilfen, ein geprüftes lokales Modell und einen aktiven globalen Shortcut"
            )
    }

    private var readinessBand: some View {
        ViewThatFits(in: .horizontal) {
            readinessContent(horizontal: true)
            readinessContent(horizontal: false)
        }
        .foregroundStyle(CoralEclipseStyle.ink)
        .padding(16)
        .background {
            CoralEclipseBackdrop()
        }
        .overlay {
            RoundedRectangle(cornerRadius: CoralEclipseStyle.panelRadius)
                .stroke(CoralEclipseStyle.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(readinessAccessibilityLabel)
    }

    @ViewBuilder
    private func readinessContent(horizontal: Bool) -> some View {
        if horizontal {
            HStack(spacing: 14) {
                readinessIdentity
                Spacer(minLength: 10)
                readinessMetadata
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                readinessIdentity
                readinessMetadata
            }
        }
    }

    private var readinessIdentity: some View {
        HStack(spacing: 14) {
            Image(systemName: readinessSymbol)
                .font(.system(size: 27, weight: .medium))
                .foregroundStyle(readinessAccentColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(readinessHeadline)
                    .font(.headline)
                Text(operationalStatus.canStartDictation
                    ? "Halte \(store.shortcut.title) zum Diktieren."
                    : operationalStatus.statusTitle(shortcut: store.shortcut.title))
                    .font(.caption)
                    .foregroundStyle(CoralEclipseStyle.secondaryInk)
            }
        }
    }

    private var readinessMetadata: some View {
        HStack(spacing: 8) {
            Text(store.pushToTalkEnabled ? store.shortcut.title : "Deaktiviert")
                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(CoralEclipseStyle.raisedSurface.opacity(0.82), in: Capsule())
            Label(store.cloudEnabled ? "Cloud-Überarbeitung aktiv" : "Nur lokal", systemImage: store.cloudEnabled ? "cloud" : "lock.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(CoralEclipseStyle.ink)
        }
    }

    private var readinessAccessibilityLabel: String {
        let readinessLabel = operationalStatus.canStartDictation
            ? "Diktat bereit"
            : operationalStatus.statusTitle(shortcut: store.shortcut.title)
        let shortcutLabel = store.pushToTalkEnabled ? store.shortcut.title : "Tastenkürzel deaktiviert"
        let processingLabel = store.cloudEnabled
            ? "Cloud-Überarbeitung aktiv, Audio bleibt lokal"
            : "Verarbeitung nur lokal"
        return "\(readinessLabel). \(shortcutLabel). \(processingLabel)."
    }

    private var readinessHeadline: String {
        if operationalStatus.canStartDictation {
            return "Bereit für lokales Diktat"
        }
        if !store.pushToTalkEnabled {
            return "Diktat deaktiviert"
        }
        if store.pushToTalkRegistrationStatus != .registered {
            return "Shortcut nicht verfügbar"
        }
        return "Einrichtung unvollständig"
    }

    private var readinessSymbol: String {
        operationalStatus.canStartDictation
            ? "waveform.badge.mic"
            : "exclamationmark.circle.fill"
    }

    private var readinessAccentColor: Color {
        operationalStatus.canStartDictation
            ? .green
            : .orange
    }

    private var modelRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                Image(systemName: "cpu")
                    .font(.title3)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Lokales Sprachmodell").font(.headline)
                    Text("\(model.statusTitle) · \(model.statusDetail)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Picker("Modell", selection: $store.localModel) {
                    ForEach(LocalModelChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .labelsHidden()
                .frame(width: 185)
                .disabled(model.isBusy)
            }
            if modelNeedsAttention {
                HStack {
                    if model.isBusy { ProgressView().controlSize(.small) }
                    if model.canImportLocalDirectory {
                        Button("Ordner importieren", action: chooseModelDirectory)
                    }
                    Button("Gepinntes Modell laden …") { confirmsDownload = true }
                }
                .padding(.leading, 40)
                .disabled(model.isBusy)
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    private var shortcutRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "keyboard")
                .font(.title3)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Tastenkürzel").font(.headline)
                HStack(spacing: 4) {
                    if store.pushToTalkRegistrationStatus.isFailure {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                    }
                    Text(store.pushToTalkRegistrationStatus.title)
                        .foregroundStyle(
                            store.pushToTalkRegistrationStatus.isFailure ? .primary : .secondary
                        )
                }
                .font(.caption)
                if let detail = store.pushToTalkRegistrationStatus.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
            }
            Spacer()
            if store.pushToTalkRegistrationStatus.isFailure {
                Button("Erneut registrieren") {
                    store.retryPushToTalkRegistration()
                }
            } else {
                Text(store.pushToTalkEnabled ? store.shortcut.title : "Deaktiviert")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
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
        ViewThatFits(in: .horizontal) {
            permissionContent(horizontal: true)
            permissionContent(horizontal: false)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(isRequired ? "erforderlich" : "optional"), \(status.title)")
    }

    @ViewBuilder
    private func permissionContent(horizontal: Bool) -> some View {
        if horizontal {
            HStack(spacing: 14) {
                permissionIdentity
                Spacer()
                permissionAction
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                permissionIdentity
                permissionAction
            }
        }
    }

    private var permissionIdentity: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var permissionAction: some View {
        VStack(alignment: .trailing, spacing: 1) {
            if status == .authorized {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                    Text(status.title)
                        .foregroundStyle(.primary)
                }
                .font(.caption.weight(.semibold))
            } else {
                Button(buttonTitle, action: action)
            }
            Text(isRequired ? "Erforderlich" : "Optional")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}
