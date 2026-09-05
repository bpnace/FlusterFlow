import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    init(
        store: SettingsStore,
        permissions: PermissionCenter,
        apiKey: APIKeySettingsModel,
        model: ModelProvisioningViewModel,
        diagnostics: DiagnosticsViewModel,
        lexicon: PersonalLexiconStore
    ) {
        let view = LocalSettingsView(
            store: store,
            permissions: permissions,
            apiKey: apiKey,
            model: model,
            diagnostics: diagnostics,
            lexicon: lexicon
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "FlusterFlow Einstellungen"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func present() {
        showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct LocalSettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var permissions: PermissionCenter
    @ObservedObject var apiKey: APIKeySettingsModel
    @ObservedObject var model: ModelProvisioningViewModel
    @ObservedObject var diagnostics: DiagnosticsViewModel

    @ObservedObject var lexicon: PersonalLexiconStore
    @State private var apiKeyEntry = ""
    @State private var confirmsModelDownload = false
    @State private var lexiconCanonical = ""
    @State private var lexiconMisspellings = ""
    @State private var editingLexiconEntryID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("FlusterFlow")
                        .font(.largeTitle.bold())
                    Text("Privates Push-to-talk-Diktat für diesen Mac")
                        .foregroundStyle(.secondary)
                }

                SettingsSection(title: "Diktat") {
                    Picker("Sprache", selection: $store.language) {
                        Text("Automatisch").tag(DictationLanguage.automatic)
                        Text("Deutsch").tag(DictationLanguage.german)
                        Text("Englisch").tag(DictationLanguage.english)
                    }
                    .pickerStyle(.segmented)

                    Toggle("Push-to-talk aktivieren", isOn: $store.pushToTalkEnabled)

                    Toggle("Handsfree per Doppeltipp", isOn: $store.handsFreeEnabled)
                        .disabled(!store.pushToTalkEnabled)
                    Text("Zweimal kurz drücken, um die Aufnahme ohne Halten fortzusetzen. Ein weiterer Druck beendet sie.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LabeledContent("Tastenkürzel") {
                        ShortcutRecorderField(
                            shortcut: $store.shortcut,
                            onRecordingChanged: store.setShortcutCaptureActive
                        )
                        .frame(width: 250, height: 30)
                        .disabled(!store.pushToTalkEnabled)
                    }
                    Text("In das Feld klicken und das gewünschte Kürzel drücken. Mindestens ⌃, ⌥, ⇧ oder ⌘ ist erforderlich; Escape bricht ab.")
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

                    LabeledContent("Mikrofon") {
                        Text("macOS-Systemeingabe")
                            .foregroundStyle(.secondary)
                    }
                }

                SettingsSection(title: "Lokales Modell") {
                    Picker("Modell", selection: $store.localModel) {
                        ForEach(LocalModelChoice.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .disabled(model.isBusy)
                    Text(store.localModel.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LabeledContent("Status") {
                        Text(model.statusTitle)
                            .foregroundStyle(modelStatusColor)
                    }
                    Text(model.statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button("Lokalen Ordner importieren", action: chooseModelDirectory)
                            .disabled(!model.canImportLocalDirectory)
                        Button("Gepinntes Modell laden …") {
                            confirmsModelDownload = true
                        }
                    }
                    .disabled(model.isBusy)
                    if model.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Ein Download startet niemals automatisch. Import und Download prüfen Größe und SHA-256 jedes Artefakts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SettingsSection(title: "Lokale Privatsphäre") {
                    Toggle(
                        "Begrenzten Kontext am Cursor lokal verwenden",
                        isOn: $store.contextAwarenessEnabled
                    )
                    Text("Maximal 1.500 Zeichen aus dem fokussierten editierbaren Feld. Keine Screenshots, keine Telemetrie und keine automatische Zwischenablage. Aufnahmen und Transkripte verbleiben in der separat löschbaren lokalen Historie.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LabeledContent("Standardpfad") {
                        Label("Nur lokal", systemImage: "lock.fill")
                            .foregroundStyle(.green)
                    }
                }

                SettingsSection(title: "Persönliches Lexikon") {
                    Toggle(
                        "Korrekturen im gerade eingefügten Text lokal lernen",
                        isOn: $store.localLearningEnabled
                    )
                    Text("Ein-Wort-Korrekturen werden bis zu zehn Sekunden nach der Einfügung als Wortpaar gelernt. Längere Änderungen bleiben Vorschläge; vollständige Texte werden nicht gespeichert.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Korrekte Schreibweise", text: $lexiconCanonical)
                        .textFieldStyle(.roundedBorder)
                    TextField("Erkannte Varianten, durch Komma getrennt", text: $lexiconMisspellings)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button(editingLexiconEntryID == nil ? "Hinzufügen" : "Aktualisieren") {
                            saveLexiconEntry()
                        }
                        .disabled(lexiconCanonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if editingLexiconEntryID != nil {
                            Button("Abbrechen", action: clearLexiconForm)
                        }
                        Spacer()
                        Button {
                            _ = lexicon.undoLastChange()
                        } label: {
                            Label("Rückgängig", systemImage: "arrow.uturn.backward")
                        }
                        .disabled(!lexicon.canUndo)
                        Button(role: .destructive) {
                            _ = lexicon.reset()
                            clearLexiconForm()
                        } label: {
                            Label("Reset", systemImage: "trash")
                        }
                        .disabled(!lexicon.canReset)
                    }

                    if !lexicon.suggestions.isEmpty {
                        Text("Vorschläge")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(lexicon.suggestions) { suggestion in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(suggestion.canonical)
                                        .font(.callout.weight(.medium))
                                    Text("Statt: \(suggestion.misspellings.joined(separator: ", "))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Übernehmen") {
                                    _ = lexicon.acceptSuggestion(id: suggestion.id)
                                }
                                Button("Verwerfen") {
                                    _ = lexicon.dismissSuggestion(id: suggestion.id)
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    if lexicon.entries.isEmpty {
                        Text("Keine Einträge")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(lexicon.entries) { entry in
                            Divider()
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.canonical)
                                        .font(.callout.weight(.medium))
                                    Text(lexiconDetail(for: entry))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(entry.priority)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 24, alignment: .trailing)
                                Button {
                                    editLexiconEntry(entry)
                                } label: {
                                    Label("Bearbeiten", systemImage: "pencil")
                                }
                                .labelStyle(.iconOnly)
                                Button {
                                    _ = lexicon.prioritize(id: entry.id)
                                } label: {
                                    Label("Priorisieren", systemImage: "arrow.up")
                                }
                                .labelStyle(.iconOnly)
                                Button(role: .destructive) {
                                    _ = lexicon.delete(id: entry.id)
                                    if editingLexiconEntryID == entry.id {
                                        clearLexiconForm()
                                    }
                                } label: {
                                    Label("Löschen", systemImage: "trash")
                                }
                                .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                SettingsSection(title: "Optionale OpenAI-Überarbeitung") {
                    LabeledContent("API-Schlüssel") {
                        Text(apiKey.state.title)
                            .foregroundStyle(apiKey.hasStoredKey ? .green : .secondary)
                    }
                    SecureField("Eigenen API-Key einfügen", text: $apiKeyEntry)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button(apiKey.hasStoredKey ? "Schlüssel rotieren" : "Schlüssel speichern") {
                            saveAPIKey()
                        }
                        .disabled(apiKeyEntry.isEmpty)
                        if apiKey.hasStoredKey {
                            Button("Löschen", role: .destructive) {
                                deleteAPIKey()
                            }
                        }
                    }

                    Toggle("Text in der Cloud überarbeiten", isOn: $store.cloudEnabled)
                        .disabled(!apiKey.hasStoredKey)
                    Toggle(
                        "Begrenzten Cursor-Kontext zusätzlich senden",
                        isOn: $store.cloudContextEnabled
                    )
                    .disabled(!store.cloudEnabled || !apiKey.hasStoredKey)

                    Picker("Cloud-Modell", selection: $store.cloudModel) {
                        ForEach(CloudModelChoice.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Label("Audio wird in V1 nie gesendet.", systemImage: "waveform.slash")
                        Text("Gesendet wird genau ein lokal bereinigter Textkandidat; Kontext nur mit dem separaten Schalter. Der Request ist stateless und nutzt store:false.")
                        Text("API-Kosten fallen direkt beim Provider an. store:false ist keine Zusage für Zero Data Retention: Verarbeitung und Aufbewahrung richten sich nach deinem OpenAI-API-Projekt und dessen Datenkontrollen.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                SettingsSection(title: "Berechtigungen") {
                    PermissionSettingRow(
                        title: "Mikrofon",
                        state: permissions.microphone,
                        buttonTitle: permissions.microphoneRequestButtonTitle,
                        action: permissions.requestMicrophone
                    )
                    PermissionSettingRow(
                        title: "Bedienungshilfen",
                        state: permissions.accessibility,
                        buttonTitle: "Öffnen",
                        action: permissions.requestAccessibility
                    )
                    Button("Status aktualisieren", action: permissions.refresh)
                        .controlSize(.small)
                }

                SettingsSection(title: "System und Diagnose") {
                    Toggle(
                        "Beim Anmelden starten",
                        isOn: Binding(
                            get: { store.launchAtLoginEnabled },
                            set: { store.setLaunchAtLogin($0) }
                        )
                    )
                    if store.launchAtLoginUpdateFailed {
                        Text("Die Systemeinstellung konnte nicht aktualisiert werden.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Button("Inhaltsfreien Diagnosebericht exportieren …", action: exportDiagnostics)
                    if diagnostics.exportFailed {
                        Text("Der Bericht konnte nicht gespeichert werden.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text("Der Bericht enthält nur Versionen, Berechtigungs-/Modellstatus und aggregierte Laufzeiten – niemals Audio, Text, Kontext, Pfade, Fenstertitel oder Schlüssel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(ApplicationVersion.current.displayText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityLabel(
                        "FlusterFlow \(ApplicationVersion.current.displayText)"
                    )
            }
            .padding(28)
        }
        .frame(minWidth: 590, minHeight: 620)
        .task {
            permissions.refresh()
            apiKey.refresh()
            model.refresh()
        }
        .confirmationDialog(
            "Gepinntes Sprachmodell laden?",
            isPresented: $confirmsModelDownload,
            titleVisibility: .visible
        ) {
            Button(model.downloadConfirmationTitle) {
                model.downloadPinnedModelAfterConfirmation()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Ein einmaliger HTTPS-Download von Hugging Face wird gestartet. Danach bleibt der Diktatpfad offline.")
        }
    }

    private var modelStatusColor: Color {
        if case .ready = model.status { return .green }
        if case .invalid = model.status { return .orange }
        return .secondary
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

    private func saveAPIKey() {
        let candidate = apiKeyEntry
        Task { @MainActor in
            if await apiKey.save(candidate) {
                apiKeyEntry = ""
            }
        }
    }

    private func deleteAPIKey() {
        Task { @MainActor in
            if await apiKey.delete() {
                store.disableCloud()
                apiKeyEntry = ""
            }
        }
    }

    private func saveLexiconEntry() {
        let misspellings = lexiconMisspellings
            .split(separator: ",")
            .map(String.init)
        if let editingLexiconEntryID {
            _ = lexicon.update(
                id: editingLexiconEntryID,
                canonical: lexiconCanonical,
                misspellings: misspellings,
                language: store.language
            )
        } else {
            _ = lexicon.add(
                canonical: lexiconCanonical,
                misspellings: misspellings,
                language: store.language
            )
        }
        clearLexiconForm()
    }

    private func editLexiconEntry(_ entry: PersonalLexiconEntry) {
        editingLexiconEntryID = entry.id
        lexiconCanonical = entry.canonical
        lexiconMisspellings = entry.misspellings.joined(separator: ", ")
    }

    private func clearLexiconForm() {
        editingLexiconEntryID = nil
        lexiconCanonical = ""
        lexiconMisspellings = ""
    }

    private func lexiconDetail(for entry: PersonalLexiconEntry) -> String {
        let variants = entry.misspellings.isEmpty
            ? "keine Varianten"
            : entry.misspellings.joined(separator: ", ")
        return "\(entry.language.title) · \(variants)"
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.title = "Inhaltsfreien Diagnosebericht speichern"
        panel.nameFieldStringValue = "FlusterFlow-Diagnose.json"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task { @MainActor in
            await diagnostics.export(to: destination)
        }
    }
}

private struct PermissionSettingRow: View {
    let title: String
    let state: PermissionState
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(state.title)
                .foregroundStyle(state == .authorized ? .green : .secondary)
            if state != .authorized {
                Button(buttonTitle, action: action)
                    .controlSize(.small)
            }
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
