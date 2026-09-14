import AppKit
import SwiftUI

protocol RecordingHistoryModelReadinessProviding: Sendable {
    func isReady(_ choice: LocalModelChoice) async -> Bool
}

struct RecordingHistoryModelReadinessProvider: RecordingHistoryModelReadinessProviding {
    private let readiness: @Sendable (LocalModelChoice) async -> Bool

    init(readiness: @escaping @Sendable (LocalModelChoice) async -> Bool) {
        self.readiness = readiness
    }

    func isReady(_ choice: LocalModelChoice) async -> Bool {
        await readiness(choice)
    }

    static let allReady = Self { _ in true }
}

@MainActor
final class RecordingHistoryViewModel: ObservableObject {
    private static var nextHistorySessionRawValue: UInt64 = 0

    @Published private(set) var entries: [RecordingHistoryEntry] = []
    @Published private(set) var hasManagedArtifacts = false
    @Published var selectedID: UUID?
    @Published var selectedModel: LocalModelChoice = .adaptive
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var readyModels: Set<LocalModelChoice> = []

    private let store: RecordingHistoryStore
    private let audioSamples: AudioBufferStore
    private let recognizer: SessionModelSpeechRecognizer
    private let modelReadiness: any RecordingHistoryModelReadinessProviding
    private var retranscriptionsNeedingStateRepair: Set<UUID> = []

    init(
        store: RecordingHistoryStore,
        audioSamples: AudioBufferStore,
        recognizer: SessionModelSpeechRecognizer,
        modelReadiness: any RecordingHistoryModelReadinessProviding = RecordingHistoryModelReadinessProvider.allReady
    ) {
        self.store = store
        self.audioSamples = audioSamples
        self.recognizer = recognizer
        self.modelReadiness = modelReadiness
    }

    var selectedEntry: RecordingHistoryEntry? {
        entries.first { $0.id == selectedID }
    }

    var canDeleteAll: Bool {
        hasManagedArtifacts
            && !entries.contains {
                $0.state == .recording || $0.state == .transcribing
            }
            && !isWorking
    }

    func reload() {
        Task { await reloadEntries() }
    }

    func retranscribeSelected() {
        guard let entry = selectedEntry, entry.hasAudio, !isWorking else { return }
        let modelChoice = selectedModel
        isWorking = true
        errorMessage = nil
        Task { await performRetranscription(of: entry, modelChoice: modelChoice) }
    }

    func reloadEntries() async {
        errorMessage = nil
        await repairFailedRetranscriptionStates()
        await store.retryLaunchRecovery()
        await refreshModelReadiness()
        await loadEntries()
    }

    func isModelReady(_ choice: LocalModelChoice) -> Bool {
        readyModels.contains(choice)
    }

    func performSelectedRetranscription() async {
        guard let entry = selectedEntry, entry.hasAudio, !isWorking else { return }
        let modelChoice = selectedModel
        isWorking = true
        errorMessage = nil
        await performRetranscription(of: entry, modelChoice: modelChoice)
    }

    private func performRetranscription(
        of entry: RecordingHistoryEntry,
        modelChoice: LocalModelChoice
    ) async {
        let sessionID = Self.historySessionID()
        var input: AudioInput?
        var didBeginRetranscription = false
        do {
            guard await modelReadiness.isReady(modelChoice) else {
                readyModels.remove(modelChoice)
                errorMessage = "Das ausgewählte lokale Modell ist nicht verfügbar."
                isWorking = false
                return
            }
            try await recognizer.acquireExclusiveAccess(
                for: sessionID,
                purpose: .historyRetranscription
            )
            _ = try await store.beginRetranscription(entry.id)
            didBeginRetranscription = true
            let samples = try await store.loadAudio(for: entry.id)
            let storedInput = await audioSamples.store(samples)
            input = storedInput
            await recognizer.register(modelChoice, for: sessionID)
            let transcript = try await recognizer.transcribe(
                storedInput,
                hints: RecognitionHints(
                    language: entry.language,
                    terms: [],
                    prioritizedLexiconTerms: []
                ),
                sessionID: sessionID
            )
            try await store.appendTranscript(
                TranscriptVersion(
                    backend: transcript.backend?.rawValue ?? modelChoice.rawValue,
                    language: transcript.language,
                    text: transcript.text,
                    kind: .retranscribed
                ),
                to: entry.id
            )
        } catch let error as SessionModelSpeechRecognizerError {
            if didBeginRetranscription {
                await markRetranscriptionFailed(entry.id)
            }
            if case .recognizerBusy = error {
                errorMessage = "Die lokale Spracherkennung ist gerade beschäftigt. Bitte versuche es nach dem aktuellen Diktat erneut."
            } else if !retranscriptionsNeedingStateRepair.contains(entry.id) {
                errorMessage = "Die lokale Transkription ist fehlgeschlagen. Die Aufnahme bleibt erhalten."
            }
        } catch {
            if didBeginRetranscription {
                await markRetranscriptionFailed(entry.id)
            }
            if !retranscriptionsNeedingStateRepair.contains(entry.id) {
                errorMessage = "Die lokale Transkription ist fehlgeschlagen. Die Aufnahme bleibt erhalten."
            }
        }
        if let input { await audioSamples.release(input) }
        await recognizer.cancel(sessionID: sessionID)
        await loadEntries()
        isWorking = false
    }

    func deleteSelected() {
        guard let id = selectedID, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                try await store.delete(id)
                selectedID = nil
                await loadEntries()
            } catch {
                await loadEntries()
                if entries.contains(where: { $0.id == id && !$0.hasAudio }) {
                    errorMessage = "Das Audio wurde gelöscht, aber der Historieneintrag konnte nicht entfernt werden. Du kannst das Löschen erneut versuchen."
                } else {
                    errorMessage = "Die Aufnahme konnte nicht gelöscht werden."
                }
            }
        }
    }

    func deleteAll() {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                try await store.deleteAll()
                selectedID = nil
                await loadEntries()
            } catch {
                await loadEntries()
                errorMessage = "Die Aufnahmehistorie konnte nicht vollständig gelöscht werden."
            }
        }
    }

    private func loadEntries() async {
        do {
            entries = try await store.list()
            hasManagedArtifacts = try await store.hasManagedArtifacts()
            if await store.hasRecoveryWarning() {
                errorMessage = "Mindestens ein Historieneintrag ist beschädigt oder konnte nicht vollständig wiederhergestellt werden. Gültige Aufnahmen bleiben sichtbar und können gelöscht werden."
            }
            if selectedID == nil || !entries.contains(where: { $0.id == selectedID }) {
                selectedID = entries.first?.id
            }
        } catch {
            entries = []
            hasManagedArtifacts = false
            selectedID = nil
            errorMessage = "Die lokale Aufnahmehistorie konnte nicht gelesen werden."
        }
    }

    private func refreshModelReadiness() async {
        var ready: Set<LocalModelChoice> = []
        for choice in LocalModelChoice.allCases {
            if await modelReadiness.isReady(choice) {
                ready.insert(choice)
            }
        }
        readyModels = ready
        if !ready.contains(selectedModel), let fallback = LocalModelChoice.allCases.first(where: ready.contains) {
            selectedModel = fallback
        }
    }

    private func markRetranscriptionFailed(_ id: UUID) async {
        do {
            try await store.mark(id, state: .failed)
            retranscriptionsNeedingStateRepair.remove(id)
        } catch {
            retranscriptionsNeedingStateRepair.insert(id)
            errorMessage = "Die Transkription ist fehlgeschlagen und ihr Status konnte nicht gespeichert werden. Stelle den Speicherzugriff wieder her und klicke auf Aktualisieren."
        }
    }

    private func repairFailedRetranscriptionStates() async {
        for id in retranscriptionsNeedingStateRepair {
            do {
                try await store.mark(id, state: .failed)
                retranscriptionsNeedingStateRepair.remove(id)
            } catch {
                errorMessage = "Der fehlgeschlagene Transkriptionsstatus konnte noch nicht gespeichert werden."
            }
        }
    }

    private static func historySessionID() -> DictationSessionID {
        nextHistorySessionRawValue &+= 1
        return DictationSessionID(rawValue: nextHistorySessionRawValue | (1 << 63))
    }
}

struct RecordingHistoryView: View {
    @ObservedObject var model: RecordingHistoryViewModel
    @State private var confirmsDeleteSelected = false
    @State private var confirmsDeleteAll = false

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                historyHeader(horizontal: true)
                historyHeader(horizontal: false)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)

            Divider()

            HSplitView {
                List(model.entries, selection: $model.selectedID) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.createdAt, format: .dateTime.day().month().year().hour().minute())
                            .font(.headline)
                        Text(summary(for: entry))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(entry.id)
                }
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 310)
                .scrollContentBackground(.hidden)
                .background(CoralEclipseStyle.sidebar)

                Group {
                    if let entry = model.selectedEntry {
                        detail(entry)
                    } else {
                        VStack(spacing: 16) {
                            ContentUnavailableView(
                                model.entries.isEmpty
                                    ? "Noch keine Aufnahmen"
                                    : "Keine Aufnahme ausgewählt",
                                systemImage: "waveform",
                                description: Text(
                                    model.entries.isEmpty
                                        ? "Neue Diktate erscheinen hier lokal und bleiben bis zum ausdrücklichen Löschen erhalten."
                                        : "Wähle links eine Aufnahme aus, um ihre Transkriptversionen zu sehen."
                                )
                            )
                            if let error = model.errorMessage {
                                Label(error, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(CoralEclipseStyle.canvas)
            }
        }
        .background(CoralEclipseStyle.canvas)
        .confirmationDialog(
            "Gesamte lokale Aufnahmehistorie löschen?",
            isPresented: $confirmsDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Alle Aufnahmen endgültig löschen", role: .destructive) { model.deleteAll() }
                .tint(.red)
        } message: {
            Text("Audio und alle Transkriptversionen werden von diesem Mac entfernt.")
        }
        .confirmationDialog(
            "Diese lokale Aufnahme löschen?",
            isPresented: $confirmsDeleteSelected,
            titleVisibility: .visible
        ) {
            Button("Aufnahme endgültig löschen", role: .destructive) { model.deleteSelected() }
                .tint(.red)
        } message: {
            Text("Audio und alle zugehörigen Transkriptversionen werden entfernt.")
        }
    }

    @ViewBuilder
    private func historyHeader(horizontal: Bool) -> some View {
        if horizontal {
            HStack(alignment: .center, spacing: 16) {
                historyIdentity
                Spacer()
                Button("Aktualisieren", systemImage: "arrow.clockwise") { model.reload() }
                    .disabled(model.isWorking)
                Button("Alle löschen", role: .destructive) { confirmsDeleteAll = true }
                    .disabled(!model.canDeleteAll)
                    .tint(.red)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                historyIdentity
                HStack {
                    Button("Aktualisieren", systemImage: "arrow.clockwise") { model.reload() }
                        .disabled(model.isWorking)
                    Button("Alle löschen", role: .destructive) { confirmsDeleteAll = true }
                        .disabled(!model.canDeleteAll)
                        .tint(.red)
                }
            }
        }
    }

    private var historyIdentity: some View {
        CoralPageHeader(
            title: "Aufnahmen",
            subtitle: "Lokal gespeichert, wiederherstellbar und versioniert",
            systemImage: AppDestination.recordings.systemImage
        )
    }

    private func detail(_ entry: RecordingHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                detailHeader(entry, horizontal: true)
                detailHeader(entry, horizontal: false)
            }

            ViewThatFits(in: .horizontal) {
                retranscriptionControls(horizontal: true)
                retranscriptionControls(horizontal: false)
            }

            if model.isWorking { ProgressView("Wird ausschließlich lokal transkribiert …") }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            if entry.transcripts.isEmpty {
                ContentUnavailableView(
                    "Noch kein Transkript",
                    systemImage: "text.badge.xmark",
                    description: Text(
                        entry.hasAudio
                            ? "Die Aufnahme bleibt für einen erneuten lokalen Versuch erhalten."
                            : "Die Audiodatei ist nicht mehr vorhanden. Der Historieneintrag kann noch gelöscht werden."
                    )
                )
            } else {
                if let preferred = entry.preferredTranscript {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Aktuelles Transkript").font(.headline)
                            Spacer()
                            Button("Kopieren") { copyTranscript(preferred.text) }
                        }
                        Text(preferred.kind.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(preferred.text).textSelection(.enabled)
                    }
                }
                List(entry.transcripts.reversed(), id: \.version) { version in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Version \(version.version)").font(.headline)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(version.kind.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(version.backend)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(version.text).textSelection(.enabled)
                    }
                    .padding(.vertical, 6)
                }
            }
            Text("Audio und Transkripte bleiben nur auf diesem Mac, bis du sie löschst.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    @ViewBuilder
    private func detailHeader(_ entry: RecordingHistoryEntry, horizontal: Bool) -> some View {
        if horizontal {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.createdAt, format: .dateTime.weekday().day().month().year().hour().minute())
                        .font(.title2.bold())
                    Text(summary(for: entry)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Löschen", role: .destructive) { confirmsDeleteSelected = true }
                    .disabled(
                        entry.state == .recording
                            || entry.state == .transcribing
                            || model.isWorking
                    )
                    .tint(.red)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.createdAt, format: .dateTime.weekday().day().month().year().hour().minute())
                        .font(.title2.bold())
                    Text(summary(for: entry)).foregroundStyle(.secondary)
                }
                Button("Löschen", role: .destructive) { confirmsDeleteSelected = true }
                    .disabled(
                        entry.state == .recording
                            || entry.state == .transcribing
                            || model.isWorking
                    )
                    .tint(.red)
            }
        }
    }

    @ViewBuilder
    private func retranscriptionControls(horizontal: Bool) -> some View {
        if horizontal {
            HStack {
                retranscriptionPicker
                retranscriptionButton
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                retranscriptionPicker
                retranscriptionButton
            }
        }
    }

    private var retranscriptionPicker: some View {
        Picker("Lokales Modell", selection: $model.selectedModel) {
            ForEach(LocalModelChoice.allCases) { choice in
                Text(model.isModelReady(choice) ? choice.title : "\(choice.title) – nicht verfügbar").tag(choice)
                    .disabled(!model.isModelReady(choice))
            }
        }
        .disabled(model.isWorking || model.readyModels.isEmpty)
    }

    private var retranscriptionButton: some View {
        Button("Neu transkribieren") { model.retranscribeSelected() }
            .help(model.isModelReady(model.selectedModel)
                ? "Erstellt eine neue Version mit dem ausgewählten Modell."
                : "Dieses Modell ist nicht einsatzbereit. Bitte unter Modelle prüfen und installieren.")
            .disabled(
                model.selectedEntry?.hasAudio != true
                    || model.selectedEntry?.state == .recording
                    || model.selectedEntry?.state == .transcribing
                    || !model.isModelReady(model.selectedModel)
                    || model.isWorking
            )
    }

    private func summary(for entry: RecordingHistoryEntry) -> String {
        let duration = entry.durationSeconds.map { String(format: "%.1f s", $0) } ?? "ohne Audio"
        let versions = entry.transcripts.count == 1 ? "1 Version" : "\(entry.transcripts.count) Versionen"
        return "\(entry.state.title) · \(duration) · \(versions)"
    }

    private func copyTranscript(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private extension RecordingHistoryState {
    var title: String {
        switch self {
        case .recording: "Aufnahme läuft"
        case .ready: "Bereit"
        case .transcribing: "Wird transkribiert"
        case .completed: "Abgeschlossen"
        case .failed: "Erneut versuchen"
        case .interrupted: "Unterbrochen"
        }
    }
}

private extension TranscriptVersionKind {
    var title: String {
        switch self {
        case .raw: "Rohtext"
        case .final: "Korrigierter Text"
        case .retranscribed: "Erneut erkannt"
        }
    }
}
