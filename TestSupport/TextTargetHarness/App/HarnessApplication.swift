@preconcurrency import AppKit
import Foundation
@preconcurrency import WebKit
import TextTargetHarnessCore

@MainActor
enum HarnessApplication {
    static func run(automationMode: Bool) {
        let application = NSApplication.shared
        let delegate = HarnessApplicationDelegate(automationMode: automationMode)
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        application.run()
        _ = delegate
    }
}

@MainActor
private final class HarnessApplicationDelegate: NSObject, NSApplicationDelegate {
    private let automationMode: Bool
    private var windowController: HarnessWindowController?

    init(automationMode: Bool) {
        self.automationMode = automationMode
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = HarnessWindowController()
        windowController = controller
        controller.showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)

        if automationMode {
            let pid = ProcessInfo.processInfo.processIdentifier
            FileHandle.standardOutput.write(Data("READY \(pid)\n".utf8))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@MainActor
private final class HarnessWindowController: NSWindowController, WKNavigationDelegate {
    private let textField = NSTextField(string: "Alpha Gamma")
    private let secureField = NSSecureTextField(string: "synthetic-secret")
    private let textView = NSTextView(frame: .zero)
    private let webView = WKWebView(frame: .zero)
    private let stateView = NSTextView(frame: .zero)
    private let clipboardLabel = NSTextField(labelWithString: "")
    private var sequence = 0
    private var initialPasteboardChangeCount = NSPasteboard.general.changeCount

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_080, height: 820),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "E-TARGET-HARNESS — native and web text targets"
        window.minSize = NSSize(width: 900, height: 680)
        super.init(window: window)
        configureUI()
        resetTargets(nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func configureUI() {
        guard let window else { return }

        textField.setAccessibilityIdentifier("harness.textField")
        textField.placeholderString = "NSTextField"
        secureField.setAccessibilityIdentifier("harness.secureField")
        secureField.placeholderString = "NSSecureTextField"
        textView.setAccessibilityIdentifier("harness.textView")
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        stateView.isEditable = false
        stateView.isSelectable = true
        stateView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        webView.navigationDelegate = self
        webView.setAccessibilityIdentifier("harness.webView")

        let nativeForm = NSStackView(views: [
            labeled("NSTextField", control: textField),
            labeled("NSSecureTextField", control: secureField),
            labeled("NSTextView", control: scrollView(for: textView, height: 110))
        ])
        nativeForm.orientation = .vertical
        nativeForm.spacing = 10
        nativeForm.alignment = .leading
        nativeForm.distribution = .fill

        let focusButtons = NSStackView(views: [
            button("Focus TextField", #selector(focusTextField)),
            button("Focus TextView", #selector(focusTextView)),
            button("Focus Secure", #selector(focusSecureField)),
            button("Focus Web input", #selector(focusWebInput)),
            button("Focus Web textarea", #selector(focusWebTextarea)),
            button("Focus contenteditable", #selector(focusWebEditable))
        ])
        focusButtons.orientation = .horizontal
        focusButtons.spacing = 6

        let mutationButtons = NSStackView(views: [
            button("Set range 6:0", #selector(setKnownRange)),
            button("Mutate range", #selector(mutateRange)),
            button("Move focus", #selector(moveFocus)),
            button("Run safe assertions", #selector(runSafeAssertions)),
            button("Explicit copy", #selector(explicitCopy)),
            button("Reset", #selector(resetTargets))
        ])
        mutationButtons.orientation = .horizontal
        mutationButtons.spacing = 6

        let webLabel = NSTextField(labelWithString: "WKWebView: input, textarea, contenteditable, password")
        webLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        webView.heightAnchor.constraint(equalToConstant: 210).isActive = true

        let stateLabel = NSTextField(labelWithString: "Deterministic observations / clipboard assertions")
        stateLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        clipboardLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)

        let root = NSStackView(views: [
            nativeForm,
            focusButtons,
            mutationButtons,
            webLabel,
            webView,
            stateLabel,
            clipboardLabel,
            scrollView(for: stateView, height: 170)
        ])
        root.orientation = .vertical
        root.spacing = 10
        root.alignment = .leading
        root.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(root)
        window.contentView = container
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            root.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            root.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -18),
            nativeForm.widthAnchor.constraint(equalTo: root.widthAnchor),
            webView.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])
    }

    private func labeled(_ title: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.widthAnchor.constraint(equalToConstant: 150).isActive = true
        control.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 640).isActive = true
        return row
    }

    private func scrollView(for textView: NSTextView, height: CGFloat) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = textView
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        textView.minSize = NSSize(width: 0, height: height)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        return scroll
    }

    private func button(_ title: String, _ selector: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: selector)
        button.bezelStyle = .rounded
        return button
    }

    @objc private func focusTextField() {
        window?.makeFirstResponder(textField)
        record("focus", detail: "NSTextField")
    }

    @objc private func focusTextView() {
        window?.makeFirstResponder(textView)
        record("focus", detail: "NSTextView")
    }

    @objc private func focusSecureField() {
        window?.makeFirstResponder(secureField)
        record("focus", detail: "NSSecureTextField; value intentionally not observed")
    }

    @objc private func focusWebInput() {
        focusWebElement("web-input")
    }

    @objc private func focusWebTextarea() {
        focusWebElement("web-textarea")
    }

    @objc private func focusWebEditable() {
        focusWebElement("web-editable")
    }

    private func focusWebElement(_ identifier: String) {
        webView.evaluateJavaScript("document.getElementById('\(identifier)').focus()")
        record("focus", detail: identifier)
    }

    @objc private func setKnownRange() {
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 6, length: 0))
        record("selection", detail: "NSTextView=6:0")
    }

    @objc private func mutateRange() {
        let range = textView.selectedRange()
        let next = min(textView.string.utf16.count, range.location + 1)
        textView.setSelectedRange(NSRange(location: next, length: 0))
        record("selectionMutation", detail: "NSTextView=\(next):0")
    }

    @objc private func moveFocus() {
        window?.makeFirstResponder(textField)
        record("focusMutation", detail: "focus moved away from prior target")
    }

    @objc private func runSafeAssertions() {
        let beforePasteboard = NSPasteboard.general.changeCount
        let original = textView.string
        let originalSelection = HarnessSelection(location: 6, length: 0)
        textView.setSelectedRange(NSRange(location: 6, length: 0))
        textView.insertText("Beta ", replacementRange: textView.selectedRange())
        let currentSelection = HarnessSelection(
            location: textView.selectedRange().location,
            length: textView.selectedRange().length
        )
        let confirmed = ConfirmedTextMutation.confirms(
            original: original,
            originalSelection: originalSelection,
            replacement: "Beta ",
            currentText: textView.string,
            currentSelection: currentSelection
        )

        let secureState = HarnessTargetState(
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            targetIdentifier: "secure",
            sessionIdentifier: "ui",
            selection: HarnessSelection(location: 0, length: 0),
            isFocused: true,
            isProtected: true,
            supportsSelectedText: true,
            supportsUnicodeFallback: false
        )
        let secureDecision = TargetMutationPolicy().decision(
            captured: secureState,
            current: secureState,
            activeSessionIdentifier: "ui"
        )
        let clipboardUnchanged = beforePasteboard == NSPasteboard.general.changeCount
        record(
            "safeAssertions",
            detail: "confirmedMutation=\(confirmed), protectedRejected=\(secureDecision == .reject(reason: .secureField)), pasteboardUnchanged=\(clipboardUnchanged)"
        )
    }

    @objc private func explicitCopy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = pasteboard.setString("synthetic explicit-copy fixture", forType: .string)
        record("explicitCopy", detail: "general pasteboard write requested by button")
    }

    @objc private func resetTargets(_ sender: Any?) {
        textField.stringValue = "Alpha Gamma"
        secureField.stringValue = "synthetic-secret"
        textView.string = "Alpha Gamma\nFirst old line"
        textView.setSelectedRange(NSRange(location: 6, length: 0))
        stateView.string = ""
        sequence = 0
        initialPasteboardChangeCount = NSPasteboard.general.changeCount
        loadWebFixture()
        record("reset", detail: "synthetic target state restored")
    }

    private func loadWebFixture() {
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <style>body{font:14px -apple-system;padding:12px;display:grid;gap:9px}input,textarea,[contenteditable]{font:inherit;padding:6px;border:1px solid #888;border-radius:4px}textarea{height:45px}</style>
        </head><body>
        <input id="web-input" aria-label="Harness web input" value="Hello world">
        <textarea id="web-textarea" aria-label="Harness web textarea">Items:</textarea>
        <div id="web-editable" role="textbox" aria-label="Harness contenteditable" contenteditable="true">Draft text</div>
        <input id="web-password" aria-label="Harness password" type="password" value="synthetic-password">
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func record(_ event: String, detail: String) {
        sequence += 1
        let line = "{\"sequence\":\(sequence),\"event\":\"\(escape(event))\",\"detail\":\"\(escape(detail))\"}"
        if stateView.string.isEmpty {
            stateView.string = line
        } else {
            stateView.string += "\n" + line
        }
        let current = NSPasteboard.general.changeCount
        clipboardLabel.stringValue = "pasteboard baseline=\(initialPasteboardChangeCount), current=\(current), changed=\(current != initialPasteboardChangeCount)"
    }

    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
