import AppKit
import Combine
import SwiftUI

@MainActor
final class DictationRecoveryModel: ObservableObject {
    @Published private(set) var results: [EphemeralFallbackResult] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var historyWarning: String?
    private var historyWarningNeedsPresentation = false

    var needsAttention: Bool {
        !results.isEmpty || errorMessage != nil || historyWarning != nil
    }

    func reportHistoryFailure() {
        historyWarning = "Der Verlauf konnte nicht vollständig gespeichert werden."
        historyWarningNeedsPresentation = true
    }

    @discardableResult
    func handle(_ outcome: StopOutcome, store: EphemeralResultStore) async -> Bool {
        var shouldPresent = historyWarningNeedsPresentation
        switch outcome {
        case .failed(_, let failure):
            errorMessage = failure.title
            shouldPresent = true
        case .completed(_, .safeFallback):
            errorMessage = "Der Text konnte nicht sicher eingefügt werden."
            shouldPresent = true
        case .completed(_, .confirmedDirect), .noSpeech: errorMessage = nil
        case .ignoredDuplicate, .ignoredStale: return false
        }
        historyWarningNeedsPresentation = false
        results = await store.all()
        return shouldPresent
    }

    func dismiss(_ sessionID: DictationSessionID, store: EphemeralResultStore) async {
        await store.discard(sessionID: sessionID)
        results = await store.all()
        if results.isEmpty { errorMessage = nil }
    }

    func dismissNotice() {
        errorMessage = nil
        historyWarning = nil
        historyWarningNeedsPresentation = false
    }
}

struct DictationRecoveryView: View {
    @ObservedObject var model: DictationRecoveryModel
    let store: EphemeralResultStore

    var body: some View {
        if model.needsAttention {
            VStack(alignment: .leading, spacing: 10) {
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.headline)
                }
                if let warning = model.historyWarning {
                    Text(warning).font(.callout).foregroundStyle(.secondary)
                }
                if !model.results.isEmpty {
                    Text("Diese Texte bleiben bis zum Verwerfen oder Beenden der App hier verfügbar.")
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(model.results) { result in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(result.candidateText == nil ? "Erkannter Rohtext" : "Fertiger Text")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(result.text).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    HStack {
                                        Button("Kopieren") {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(result.text, forType: .string)
                                        }
                                        Button("Verwerfen", role: .destructive) {
                                            Task { await model.dismiss(result.sessionID, store: store) }
                                        }
                                    }
                                }
                                Divider()
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                } else {
                    Button("Hinweis schließen") { model.dismissNotice() }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08))
        }
    }
}
