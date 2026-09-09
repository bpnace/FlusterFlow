import AppKit
import SwiftUI

enum FlowBarPresentation: Equatable, Sendable {
    case priming
    case listening
    case processing
    case cloudProcessing
    case inserted
    case textFieldRequired
    case noSpeech
    case cancelled
    case error

    var title: String {
        switch self {
        case .priming: "Bereitmachen"
        case .listening: "Hört lokal zu"
        case .processing: "Wird lokal verarbeitet"
        case .cloudProcessing: "Optionale Cloud-Überarbeitung"
        case .inserted: "Eingefügt"
        case .textFieldRequired: "Textfeld auswählen"
        case .noSpeech: "Keine Sprache erkannt"
        case .cancelled: "Abgebrochen"
        case .error: "Nicht verfügbar"
        }
    }

    var symbolName: String {
        switch self {
        case .priming: "waveform.badge.mic"
        case .listening: "waveform"
        case .processing, .cloudProcessing: "ellipsis"
        case .inserted: "checkmark"
        case .textFieldRequired: "character.cursor.ibeam"
        case .noSpeech: "mic.slash"
        case .cancelled: "xmark"
        case .error: "exclamationmark.triangle"
        }
    }

    var accent: Color {
        switch self {
        case .listening: .mint
        case .inserted: .green
        case .textFieldRequired: .orange
        case .noSpeech: .orange
        case .cancelled: .secondary
        case .error: .red
        case .priming, .processing, .cloudProcessing: .cyan
        }
    }

    var supportsCancellation: Bool {
        switch self {
        case .priming, .listening, .processing, .cloudProcessing:
            true
        case .inserted, .textFieldRequired, .noSpeech, .cancelled, .error:
            false
        }
    }

    var compactTitle: String {
        switch self {
        case .priming: "START"
        case .listening: "LOKAL"
        case .processing: "PRÜFT"
        case .cloudProcessing: "CLOUD"
        case .inserted: "Eingefügt"
        case .textFieldRequired: "Textfeld fehlt"
        case .noSpeech: "Keine Sprache"
        case .cancelled: "Abgebrochen"
        case .error: "Nicht verfügbar"
        }
    }

    var displaysWaveform: Bool {
        switch self {
        case .priming, .listening, .processing, .cloudProcessing:
            true
        case .inserted, .textFieldRequired, .noSpeech, .cancelled, .error:
            false
        }
    }

    var waveformTempo: Double {
        switch self {
        case .listening: 1
        case .priming: 0.72
        case .processing, .cloudProcessing: 0.5
        case .inserted, .textFieldRequired, .noSpeech, .cancelled, .error: 0
        }
    }
}

enum FlowBarLayout {
    static let shadowRadius: CGFloat = 7
    static let shadowYOffset: CGFloat = 3
    static let shadowInset: CGFloat = 12
    static let visibleHeight: CGFloat = 44

    static func visibleWidth(for presentation: FlowBarPresentation) -> CGFloat {
        switch presentation {
        case .priming, .processing:
            194
        case .listening:
            262
        case .cloudProcessing:
            202
        case .inserted:
            128
        case .cancelled:
            148
        case .textFieldRequired, .noSpeech, .error:
            178
        }
    }

    static func windowSize(for presentation: FlowBarPresentation) -> NSSize {
        NSSize(
            width: visibleWidth(for: presentation) + (shadowInset * 2),
            height: visibleHeight + (shadowInset * 2)
        )
    }

    static var shadowFitsInsideWindow: Bool {
        shadowInset >= shadowRadius + abs(shadowYOffset)
    }
}

enum FlowBarWaveformGeometry {
    static let barCount = 13
    static let minimumNormalizedHeight: CGFloat = 0.2

    static func normalizedHeight(
        for index: Int,
        at time: TimeInterval,
        tempo: Double
    ) -> CGFloat {
        let boundedIndex = max(0, min(index, barCount - 1))
        let x = Double(boundedIndex)
        let phase = time * max(tempo, 0)
        let primary = sin((phase * 4.1) + (x * 0.91))
        let secondary = sin((phase * 6.7) - (x * 0.47))
        let tertiary = sin((phase * 2.3) + (x * 1.37))
        let mixed = ((primary * 0.52) + (secondary * 0.31) + (tertiary * 0.17) + 1) / 2
        let midpoint = Double(barCount - 1) / 2
        let centerBias = 1 - (abs(x - midpoint) / midpoint)
        let envelope = 0.72 + (centerBias * 0.28)
        let normalized = minimumNormalizedHeight + ((1 - minimumNormalizedHeight) * mixed * envelope)
        return min(1, max(minimumNormalizedHeight, CGFloat(normalized)))
    }
}

enum RecordingTimerText {
    static let accessibilityIdentifier = "flow-bar.recording-timer"

    static func elapsed(seconds: TimeInterval) -> String {
        format(max(0, seconds))
    }

    static func remaining(seconds: TimeInterval) -> String {
        "noch \(format(max(0, seconds)))"
    }

    static func display(elapsed seconds: TimeInterval) -> String {
        seconds >= 105
            ? remaining(seconds: 120 - seconds)
            : elapsed(seconds: seconds)
    }

    static func accessibilityValue(elapsed seconds: TimeInterval, handsFree: Bool) -> String {
        let time = seconds >= 105
            ? "\(display(elapsed: seconds)) verbleibend"
            : "\(display(elapsed: seconds)) aufgenommen"
        return handsFree ? "Handsfree aktiv, \(time)" : time
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

@MainActor
final class FlowBarController {
    private let panel: FocusPreservingPanel
    private let hostingView: NSHostingView<FlowBarView>

    init() {
        let initialSize = FlowBarLayout.windowSize(for: .priming)
        panel = FocusPreservingPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        hostingView = NSHostingView(
            rootView: FlowBarView(presentation: .priming, cancel: nil)
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .none
            : .utilityWindow
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .stationary
        ]
        panel.contentView = hostingView
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false
    }

    func show(
        _ presentation: FlowBarPresentation,
        recordingStartedAt: Date? = nil,
        handsFree: Bool = false,
        cancel: (() -> Void)? = nil
    ) {
        let cancelAction = presentation.supportsCancellation ? cancel : nil
        let windowSize = FlowBarLayout.windowSize(for: presentation)
        panel.setContentSize(windowSize)
        hostingView.rootView = FlowBarView(
            presentation: presentation,
            recordingStartedAt: recordingStartedAt,
            handsFree: handsFree,
            cancel: cancelAction
        )
        positionPanel()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        hostingView.rootView = FlowBarView(
            presentation: .priming,
            cancel: nil,
            animationEnabled: false
        )
    }

    var preservesFocus: Bool {
        !panel.canBecomeKey && !panel.canBecomeMain
    }

    private func positionPanel() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: visibleFrame.midX - (panel.frame.width / 2),
            y: visibleFrame.minY + 64
        )
        panel.setFrameOrigin(origin)
    }
}

final class FocusPreservingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct FlowBarView: View {
    let presentation: FlowBarPresentation
    var recordingStartedAt: Date? = nil
    var handsFree = false
    let cancel: (() -> Void)?
    var animationEnabled = true

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 10) {
            statusContent

            if let cancel {
                Capsule()
                    .fill(.white.opacity(0.14))
                    .frame(width: 1, height: 18)
                    .accessibilityHidden(true)

                Button(action: cancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.82))
                        .frame(width: 24, height: 24)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
                .accessibilityLabel("Diktat abbrechen")
                .accessibilityHint("Beendet die aktuelle Aufnahme oder Verarbeitung")
            }
        }
        .padding(.horizontal, 12)
        .frame(
            width: FlowBarLayout.visibleWidth(for: presentation),
            height: FlowBarLayout.visibleHeight
        )
        .background { flowBarSurface }
        .overlay { flowBarBorder }
        .shadow(
            color: .black.opacity(colorSchemeContrast == .increased ? 0.32 : 0.2),
            radius: FlowBarLayout.shadowRadius,
            y: FlowBarLayout.shadowYOffset
        )
        .padding(FlowBarLayout.shadowInset)
        .frame(
            width: FlowBarLayout.windowSize(for: presentation).width,
            height: FlowBarLayout.windowSize(for: presentation).height
        )
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var statusContent: some View {
        if presentation == .listening, let recordingStartedAt {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let elapsed = max(0, timeline.date.timeIntervalSince(recordingStartedAt))
                statusContentBody(elapsed: elapsed)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(presentation.title)
                    .accessibilityValue(
                        RecordingTimerText.accessibilityValue(
                            elapsed: elapsed,
                            handsFree: handsFree
                        )
                    )
                    .accessibilityIdentifier(RecordingTimerText.accessibilityIdentifier)
            }
        } else {
            statusContentBody(elapsed: nil)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(presentation.title)
        }
    }

    @ViewBuilder
    private func statusContentBody(elapsed: TimeInterval?) -> some View {
        if presentation.displaysWaveform {
            HStack(spacing: 10) {
                RainbowWaveform(
                    tempo: presentation.waveformTempo,
                    animationEnabled: animationEnabled
                )

                Text(presentation.compactTitle)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.65)
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)

                if let elapsed {
                    Text(RecordingTimerText.display(elapsed: elapsed))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(elapsed >= 105 ? .orange : .white.opacity(0.72))
                        .monospacedDigit()
                }

                if presentation == .listening, handsFree {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.mint)
                        .accessibilityLabel("Handsfree aktiv")
                }
            }
        } else {
            HStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(presentation.accent.opacity(0.18))
                    Image(systemName: presentation.symbolName)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(presentation.accent)
                }
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

                Text(presentation.compactTitle)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
            }
        }
    }

    private var flowBarSurface: some View {
        Capsule(style: .continuous)
            .fill(reduceTransparency ? AnyShapeStyle(opaqueSurface) : AnyShapeStyle(.ultraThinMaterial))
            .overlay {
                Capsule(style: .continuous)
                    .fill(Color(red: 0.035, green: 0.055, blue: 0.1).opacity(reduceTransparency ? 0 : 0.76))
            }
    }

    private var flowBarBorder: some View {
        Capsule(style: .continuous)
            .stroke(
                .white.opacity(colorSchemeContrast == .increased ? 0.42 : 0.16),
                lineWidth: colorSchemeContrast == .increased ? 1.25 : 1
            )
    }

    private var opaqueSurface: Color {
        Color(red: 0.035, green: 0.055, blue: 0.1)
    }
}

private struct RainbowWaveform: View {
    let tempo: Double
    let animationEnabled: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let maximumHeight: CGFloat = 22
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 3

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1 / 30,
                paused: reduceMotion || !animationEnabled
            )
        ) { timeline in
            let time = reduceMotion || !animationEnabled
                ? 0.72
                : timeline.date.timeIntervalSinceReferenceDate

            rainbowGradient
                .mask {
                    HStack(alignment: .center, spacing: barSpacing) {
                        ForEach(0 ..< FlowBarWaveformGeometry.barCount, id: \.self) { index in
                            Capsule(style: .continuous)
                                .frame(
                                    width: barWidth,
                                    height: maximumHeight * FlowBarWaveformGeometry.normalizedHeight(
                                        for: index,
                                        at: time,
                                        tempo: tempo
                                    )
                                )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
        }
        .frame(width: 75, height: maximumHeight)
        .accessibilityHidden(true)
    }

    private var rainbowGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 1, green: 0.2, blue: 0.45),
                Color(red: 1, green: 0.43, blue: 0.18),
                Color(red: 1, green: 0.82, blue: 0.2),
                Color(red: 0.35, green: 0.92, blue: 0.54),
                Color(red: 0.2, green: 0.88, blue: 0.95),
                Color(red: 0.25, green: 0.52, blue: 1),
                Color(red: 0.57, green: 0.31, blue: 1),
                Color(red: 0.95, green: 0.25, blue: 0.83)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
