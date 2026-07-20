@preconcurrency import Carbon
import AppKit
import SwiftUI

struct ShortcutCaptureInput {
    let keyCode: UInt16
    let modifierFlags: NSEvent.ModifierFlags
    let charactersIgnoringModifiers: String?

    func makeShortcut() -> PushToTalkShortcut? {
        var carbonModifiers: UInt32 = 0
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if flags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }

        guard carbonModifiers != 0, let keyLabel else { return nil }
        return PushToTalkShortcut(
            keyCode: UInt32(keyCode),
            carbonModifiers: carbonModifiers,
            keyLabel: keyLabel
        )
    }

    private var keyLabel: String? {
        switch Int(keyCode) {
        case kVK_Space: "Leertaste"
        case kVK_Return, kVK_ANSI_KeypadEnter: "↩"
        case kVK_Tab: "Tab"
        case kVK_Delete: "⌫"
        case kVK_ForwardDelete: "⌦"
        case kVK_Escape: "Esc"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        case kVK_Home: "Home"
        case kVK_End: "Ende"
        case kVK_PageUp: "Bild↑"
        case kVK_PageDown: "Bild↓"
        case kVK_F1: "F1"
        case kVK_F2: "F2"
        case kVK_F3: "F3"
        case kVK_F4: "F4"
        case kVK_F5: "F5"
        case kVK_F6: "F6"
        case kVK_F7: "F7"
        case kVK_F8: "F8"
        case kVK_F9: "F9"
        case kVK_F10: "F10"
        case kVK_F11: "F11"
        case kVK_F12: "F12"
        case kVK_F13: "F13"
        case kVK_F14: "F14"
        case kVK_F15: "F15"
        case kVK_F16: "F16"
        case kVK_F17: "F17"
        case kVK_F18: "F18"
        case kVK_F19: "F19"
        case kVK_F20: "F20"
        default:
            charactersIgnoringModifiers?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .first
                .map { String($0).uppercased() }
        }
    }
}

@MainActor
struct ShortcutRecorderField: NSViewRepresentable {
    @Binding var shortcut: PushToTalkShortcut
    let onRecordingChanged: (Bool) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        configure(button, context: context)
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        configure(button, context: context)
    }

    static func dismantleNSView(_ button: ShortcutRecorderButton, coordinator: Void) {
        button.cancelRecording()
    }

    private func configure(_ button: ShortcutRecorderButton, context: Context) {
        button.shortcut = shortcut
        button.isEnabled = context.environment.isEnabled
        button.onShortcutChanged = { shortcut = $0 }
        button.onRecordingChanged = onRecordingChanged
        if !context.environment.isEnabled {
            button.cancelRecording()
        }
    }
}

@MainActor
final class ShortcutRecorderButton: NSButton {
    var shortcut = PushToTalkShortcut.controlOptionSpace {
        didSet { refreshPresentation() }
    }
    var onShortcutChanged: ((PushToTalkShortcut) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?

    private var isRecording = false
    private var localKeyMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        alignment = .center
        controlSize = .large
        focusRingType = .exterior
        target = self
        action = #selector(beginRecording)
        refreshPresentation()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    @objc
    private func beginRecording() {
        guard isEnabled, !isRecording else { return }
        isRecording = true
        onRecordingChanged?(true)
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            self.consume(event)
            return nil
        }
        refreshPresentation()
        window?.makeFirstResponder(self)
    }

    func cancelRecording() {
        guard isRecording else { return }
        finishRecording()
        if window?.firstResponder === self {
            window?.makeFirstResponder(nil)
        }
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign {
            finishRecording()
        }
        return didResign
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            finishRecording()
        }
    }

    private func consume(_ event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape {
            cancelRecording()
            return
        }
        let input = ShortcutCaptureInput(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers
        )
        guard let newShortcut = input.makeShortcut() else {
            NSSound.beep()
            return
        }
        shortcut = newShortcut
        onShortcutChanged?(newShortcut)
        finishRecording()
        window?.makeFirstResponder(nil)
    }

    private func finishRecording() {
        guard isRecording else { return }
        isRecording = false
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        refreshPresentation()
        onRecordingChanged?(false)
    }

    private func refreshPresentation() {
        title = isRecording ? "Tastenkürzel drücken …" : shortcut.title
        toolTip = isRecording
            ? "Escape bricht die Aufnahme ab"
            : "Klicken und ein Tastenkürzel mit mindestens einer Sondertaste drücken"
        setAccessibilityLabel("Push-to-talk-Tastenkürzel")
        setAccessibilityValue(isRecording ? "Wird aufgenommen" : shortcut.title)
        setAccessibilityHelp(toolTip)
    }
}
