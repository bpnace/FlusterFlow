import AppKit
import SwiftUI

@MainActor
final class RecordingHistoryViewModel: ObservableObject {
    @Published private(set) var entries: [RecordingHistoryEntry] = []
    @Published var selectedID: UUID?
    @Published var selectedModel: LocalModelChoice = .adaptive
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?

    private let store: RecordingHistoryStore
    private let audioSamples: AudioBufferStore
    private let recognizer: SessionModelSpeechRecognizer

    init(
        store: RecordingHistoryStore,
        audioSamples: AudioBufferStore,
        recognizer: SessionModelSpeechRecognizer
    ) {
        self.store = store
        self.audioSamples = audioSamples
        self.recognizer = recognizer
    }

    var selectedEntry: RecordingHistoryEntry? {
        entries.first { $0.id == selectedID }
    }

    func reload() {
        Task { await loadEntries() }
    }

    func retranscribeSelected() {
        guard let entry = selectedEntry, entry.hasAudio, !isWorking else { return }
        let modelChoice = selectedModel
        isWorking = true
        errorMessage = nil
        Task {
            let sessionID = Self.historySessionID()
            var input: AudioInput?
            do {
                _ = try await store.beginRetranscription(entry.id)
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
                        text: transcript.text
                    ),
                    to: entry.id
                )
            } catch {
                try? await store.mark(entry.id, state: .failed)
                errorMessage = "Die lokale Transkription ist fehlgeschlagen. Die Aufnahme bleibt erhalten."
            }
            if let input { await audioSamples.release(input) }
            await recognizer.cancel(sessionID: sessionID)
            await loadEntries()
            isWorking = false
        }
    }

    func deleteSelected() {
        guard let id = selectedID, !isWorking else { return }
        Task {
            do {
                try await store.delete(id)
                selectedID = nil
                await loadEntries()
            } catch {
                errorMessage = "Die Aufnahme konnte nicht gelöscht werden."
            }
        }
    }

    func deleteAll() {
        guard !isWorking else { return }
        Task {
            do {
                try await store.deleteAll()
                selectedID = nil
                await loadEntries()
            } catch {
                errorMessage = "Die Aufnahmehistorie konnte nicht vollständig gelöscht werden."
            }
        }
    }

    private func loadEntries() async {
        do {
            entries = try await store.list()
            if await store.hasRecoveryWarning() {
                errorMessage = "Mindestens ein Historieneintrag ist beschädigt oder konnte nicht vollständig wiederhergestellt werden. Gültige Aufnahmen bleiben sichtbar und können gelöscht werden."
            }
            if selectedID == nil || !entries.contains(where: { $0.id == selectedID }) {
                selectedID = entries.first?.id
            }
        } catch {
            entries = []
            selectedID = nil
            errorMessage = "Die lokale Aufnahmehistorie konnte nicht gelesen werden."
        }
    }

    private static func historySessionID() -> DictationSessionID {
        let micros = UInt64(Date().timeIntervalSinceReferenceDate * 1_000_000)
        return DictationSessionID(rawValue: micros | (1 << 63))
    }
}

@MainActor
final class RecordingHistoryWindowController: NSWindowController {
    private let viewModel: RecordingHistoryViewModel

    init(
        store: RecordingHistoryStore,
        audioSamples: AudioBufferStore,
        recognizer: SessionModelSpeechRecognizer
    ) {
        viewModel = RecordingHistoryViewModel(
            store: store,
            audioSamples: audioSamples,
            recognizer: recognizer
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "FlusterFlow Aufnahmen"
        window.contentView = NSHostingView(rootView: RecordingHistoryView(model: viewModel))
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        viewModel.reload()
        showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct RecordingHistoryView: View {
    @ObservedObject var model: RecordingHistoryViewModel
    @State private var confirmsDeleteSelected = false
    @State private var confirmsDeleteAll = false

    var body: some View {
        NavigationSplitView {
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
            .navigationTitle("Aufnahmen")
        } detail: {
            if let entry = model.selectedEntry {
                detail(entry)
            } else {
                ContentUnavailableView(
                    "Keine Aufnahme ausgewählt",
                    systemImage: "waveform"
                )
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .toolbar {
            Button("Alle löschen", role: .destructive) { confirmsDeleteAll = true }
                .disabled(
                    model.entries.isEmpty
                        || model.entries.contains {
                            $0.state == .recording || $0.state == .transcribing
                        }
                        || model.isWorking
                )
        }
        .confirmationDialog(
            "Gesamte lokale Aufnahmehistorie löschen?",
            isPresented: $confirmsDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Alle Aufnahmen endgültig löschen", role: .destructive) { model.deleteAll() }
        } message: {
            Text("Audio und alle Transkriptversionen werden von diesem Mac entfernt.")
        }
        .confirmationDialog(
            "Diese lokale Aufnahme löschen?",
            isPresented: $confirmsDeleteSelected,
            titleVisibility: .visible
        ) {
            Button("Aufnahme endgültig löschen", role: .destructive) { model.deleteSelected() }
        } message: {
            Text("Audio und alle zugehörigen Transkriptversionen werden entfernt.")
        }
    }

    private func detail(_ entry: RecordingHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 16) {
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
            }

            HStack {
                Picker("Lokales Modell", selection: $model.selectedModel) {
                    ForEach(LocalModelChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .disabled(model.isWorking)
                Button("Neu transkribieren") { model.retranscribeSelected() }
                    .disabled(
                        !entry.hasAudio
                            || entry.state == .recording
                            || entry.state == .transcribing
                            || model.isWorking
                    )
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
                    description: Text("Die Aufnahme bleibt für einen erneuten lokalen Versuch erhalten.")
                )
            } else {
                List(entry.transcripts.reversed(), id: \.version) { version in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Version \(version.version)").font(.headline)
                            Spacer()
                            Text(version.backend).font(.caption).foregroundStyle(.secondary)
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

    private func summary(for entry: RecordingHistoryEntry) -> String {
        let duration = entry.durationSeconds.map { String(format: "%.1f s", $0) } ?? "ohne Audio"
        return "\(entry.state.title) · \(duration) · \(entry.transcripts.count) Version(en)"
    }
}

private extension RecordingHistoryState {
    var title: String {
        switch self {
        case .recording: "Aufnahme läuft"
        case .ready: "Bereit"
        case .transcribing: "Transkribiert"
        case .completed: "Abgeschlossen"
        case .failed: "Erneut versuchen"
        case .interrupted: "Unterbrochen"
        }
    }
}
