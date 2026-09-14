import AppKit
import Combine
import SwiftUI

enum AppDestination: String, CaseIterable, Hashable, Identifiable {
    case overview
    case recordings
    case dictation
    case models
    case lexicon
    case privacy
    case cloud
    case permissions
    case general

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Übersicht"
        case .recordings: "Aufnahmen"
        case .dictation: "Diktat"
        case .models: "Modelle"
        case .lexicon: "Lexikon"
        case .privacy: "Privatsphäre"
        case .cloud: "Cloud"
        case .permissions: "Berechtigungen"
        case .general: "Allgemein"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "waveform.circle"
        case .recordings: "waveform.badge.magnifyingglass"
        case .dictation: "mic"
        case .models: "cpu"
        case .lexicon: "text.book.closed"
        case .privacy: "lock.shield"
        case .cloud: "cloud"
        case .permissions: "checkmark.shield"
        case .general: "gearshape"
        }
    }

    var settingsSubtitle: String {
        switch self {
        case .overview:
            "Status und schneller Einstieg"
        case .recordings:
            "Lokale Aufnahmen und Transkripte"
        case .dictation:
            "Sprache, Tastenkürzel und Handsfree"
        case .models:
            "Lokale Spracherkennung verwalten"
        case .lexicon:
            "Eigene Begriffe priorisieren"
        case .privacy:
            "Lokale Verarbeitung und Kontext"
        case .cloud:
            "Optionale Textverbesserung"
        case .permissions:
            "Mikrofon und Bedienungshilfen"
        case .general:
            "Diagnose und App-Informationen"
        }
    }

    var isSettingsDestination: Bool {
        switch self {
        case .overview, .recordings:
            false
        case .dictation, .models, .lexicon, .privacy, .cloud, .permissions, .general:
            true
        }
    }

    static let settingsDestinations: [AppDestination] = [
        .dictation,
        .models,
        .lexicon,
        .privacy,
        .cloud,
        .permissions,
        .general
    ]
}

@MainActor
final class AppNavigationModel: ObservableObject {
    @Published private(set) var selection: AppDestination
    private(set) var lastSettingsDestination: AppDestination
    private var recordingsSelectionHandler: (() -> Void)?

    init(
        selection: AppDestination = .overview,
        lastSettingsDestination: AppDestination = .dictation
    ) {
        self.selection = selection
        self.lastSettingsDestination = lastSettingsDestination.isSettingsDestination
            ? lastSettingsDestination
            : .dictation
    }

    func select(_ destination: AppDestination) {
        if destination == .recordings {
            recordingsSelectionHandler?()
        }
        selection = destination
        if destination.isSettingsDestination {
            lastSettingsDestination = destination
        }
    }

    func selectSettings(_ destination: AppDestination? = nil) {
        if let destination, destination.isSettingsDestination {
            select(destination)
        } else {
            select(lastSettingsDestination)
        }
    }

    func refreshSelectedDestination() {
        if selection == .recordings {
            recordingsSelectionHandler?()
        }
    }

    func setRecordingsSelectionHandler(_ handler: @escaping () -> Void) {
        recordingsSelectionHandler = handler
    }
}

@MainActor
final class AppWindowController: NSWindowController {
    let navigation: AppNavigationModel

    init(
        navigation: AppNavigationModel = AppNavigationModel(),
        overview: AnyView,
        recordingHistoryViewModel: RecordingHistoryViewModel,
        recoveryView: AnyView = AnyView(EmptyView()),
        settingsView: @escaping (AppDestination) -> AnyView
    ) {
        self.navigation = navigation
        navigation.setRecordingsSelectionHandler(recordingHistoryViewModel.reload)

        let rootView = AppShellView(
            navigation: navigation,
            overview: overview,
            recordings: AnyView(
                VStack(spacing: 0) {
                    recoveryView
                    RecordingHistoryView(model: recordingHistoryViewModel)
                }
            ),
            settingsView: settingsView
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "FlusterFlow"
        window.minSize = NSSize(width: 820, height: 600)
        window.contentView = NSHostingView(rootView: rootView)
        window.center()
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("FlusterFlowMainWindow")
        window.tabbingMode = .disallowed
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func present(_ destination: AppDestination) {
        navigation.select(destination)
        showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func presentSettings() {
        navigation.selectSettings()
        showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func refreshRecordingsIfSelected() {
        navigation.refreshSelectedDestination()
    }
}

private struct AppShellView: View {
    @ObservedObject var navigation: AppNavigationModel
    let overview: AnyView
    let recordings: AnyView
    let settingsView: (AppDestination) -> AnyView

    private var selection: Binding<AppDestination?> {
        Binding(
            get: { navigation.selection },
            set: { destination in
                if let destination {
                    navigation.select(destination)
                }
            }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                Label(AppDestination.overview.title, systemImage: AppDestination.overview.systemImage)
                    .tag(AppDestination.overview)
                Label(AppDestination.recordings.title, systemImage: AppDestination.recordings.systemImage)
                    .tag(AppDestination.recordings)

                Section("Einstellungen") {
                    ForEach(AppDestination.settingsDestinations) { destination in
                        Label(destination.title, systemImage: destination.systemImage)
                            .tag(destination)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(CoralEclipseStyle.sidebar)
            .tint(CoralEclipseStyle.coral)
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } detail: {
            destinationView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(CoralEclipseStyle.canvas)
        }
        .navigationSplitViewStyle(.balanced)
        .tint(CoralEclipseStyle.coral)
        .background(CoralEclipseStyle.canvas)
    }

    @ViewBuilder
    private var destinationView: some View {
        switch navigation.selection {
        case .overview:
            overview
        case .recordings:
            recordings
        case let destination:
            settingsView(destination)
        }
    }
}
