import SwiftUI

@main
struct WhisperFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Einstellungen …") {
                    appDelegate.presentSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
