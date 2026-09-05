import AppKit

enum ApplicationRuntime {
    static func isRunningTests(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCInjectBundleInto"] != nil
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private lazy var environment = AppEnvironment()
    private var statusItem: NSStatusItem?
    private var serviceStatusItem: NSMenuItem?
    private var cancelStatusItem: NSMenuItem?
    private var didStartRuntime = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !ApplicationRuntime.isRunningTests() else { return }
        didStartRuntime = true
        NSApplication.shared.setActivationPolicy(.accessory)

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: "FlusterFlow"
        )
        statusItem.button?.toolTip = "FlusterFlow"
        statusItem.menu = makeMenu()
        self.statusItem = statusItem

        environment.onCancellationAvailabilityChanged = { [weak self] available in
            self?.cancelStatusItem?.isHidden = !available
            self?.cancelStatusItem?.isEnabled = available
        }
        environment.onCapabilityStatusChanged = { [weak self] in
            self?.refreshServiceStatus()
        }
        environment.startServices()
        refreshServiceStatus()
        environment.presentOnboardingIfNeeded()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard didStartRuntime else { return }
        environment.refreshSystemStatus()
        refreshServiceStatus()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        guard didStartRuntime else { return false }
        presentSettings()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard didStartRuntime else { return }
        environment.shutdown()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let status = NSMenuItem(title: "Wird eingerichtet …", action: nil, keyEquivalent: "")
        status.isEnabled = false
        serviceStatusItem = status
        menu.addItem(status)

        let cancel = NSMenuItem(
            title: "Aktives Diktat abbrechen",
            action: #selector(cancelActiveDictation),
            keyEquivalent: "."
        )
        cancel.target = self
        cancel.keyEquivalentModifierMask = [.command]
        cancel.isHidden = true
        cancel.isEnabled = false
        cancelStatusItem = cancel
        menu.addItem(cancel)
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Aufnahmen …",
            action: #selector(openRecordingHistory),
            keyEquivalent: "h"
        ).target = self
        menu.addItem(
            withTitle: "Einstellungen …",
            action: #selector(openSettings),
            keyEquivalent: ","
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "FlusterFlow beenden",
            action: #selector(terminate),
            keyEquivalent: "q"
        ).target = self

        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        environment.refreshSystemStatus()
        refreshServiceStatus()
        cancelStatusItem?.isHidden = !environment.canCancelActiveOperation
        cancelStatusItem?.isEnabled = environment.canCancelActiveOperation
    }

    private func refreshServiceStatus() {
        serviceStatusItem?.title = environment.serviceStatusTitle
    }

    @objc
    private func openSettings() {
        presentSettings()
    }

    @objc
    private func openRecordingHistory() {
        environment.presentRecordingHistory()
    }

    func presentSettings() {
        environment.presentSettings()
    }

    @objc
    private func cancelActiveDictation() {
        environment.cancelActiveSession()
    }

    @objc
    private func terminate() {
        NSApplication.shared.terminate(nil)
    }
}
