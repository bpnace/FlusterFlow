# Design

## Source of truth

- Status: Active
- Last refreshed: 2026-09-09
- Primary product surfaces: macOS menu bar, one unified primary app window, nonactivating Flow Bar, and native permission/download dialogs.
- Evidence reviewed:
  - `README.md`
  - `WhisperFlow/App/AppDelegate.swift`
  - `WhisperFlow/App/AppEnvironment.swift`
  - `WhisperFlow/Features/FlowBar/FlowBarController.swift`
  - `WhisperFlow/Features/AppShell/AppWindowController.swift`
  - `WhisperFlow/Features/Onboarding/AppOverviewView.swift`
  - `WhisperFlow/Features/History/RecordingHistoryView.swift`
  - `WhisperFlow/Features/Settings/LocalSettingsView.swift`
  - `docs/privacy-data-flow.md` and `docs/threat-model.md`
  - Flow Bar reference screenshot from 2026-07-17
  - Wispr Flow Help Center, “Navigating the Wispr Flow App” (category reference only)
- Observed state: the app is a German-first, native SwiftUI/AppKit menu-bar utility with system typography, SF Symbols, adaptive system colors/materials, compact rounded surfaces, and explicit local/cloud privacy copy. The Flow Bar uses an original animated rainbow spectrum on a dark indigo glass capsule; no competitor assets are embedded.
- Working assumptions: `FlusterFlow` is the private product name for V1; German is the primary interface language; public distribution and a full localization system remain outside the current release scope. Unknowns are recorded under Open questions instead of blocking implementation.

## Brand

- Personality: calm, trustworthy, precise, private by default, quietly capable. The product should feel like a well-made macOS utility, not a conversational AI persona.
- Trust signals: always name the active processing boundary (`lokal` or `optionale Cloud-Überarbeitung`); distinguish required and optional permissions; explain explicit downloads and copy actions before they happen; retain a recoverable local candidate when automation is unsafe.
- Identity: the original FlusterFlow mark is a single mint flow/wave on a dark indigo field. It represents speech becoming orderly text without using a microphone, lock, letter, or copied competitor motif as the primary mark.
- Avoid: Wispr naming, copy, proprietary assets, or pixel-identical geometry; generic “AI sparkle” branding; neon cyberpunk treatments; dense dashboards; surveillance imagery; anthropomorphic assistant language; claims such as “100% private” when cloud mode is enabled or `store:false` is discussed. The owner-approved compact waveform pattern may share the category convention of a floating audio pill while retaining original color, motion, sizing, and implementation.

## Product goals

- Goals:
  - Make push-to-talk and the optional double-tap Handsfree flow understandable without opening the app.
  - Keep local-only readiness and current processing mode legible at every decision point.
  - Preserve focus in the target app and insert the final text without a secondary result surface.
  - Preserve recordings and transcript versions locally until explicit deletion so failed or alternative local transcriptions remain recoverable.
  - Present permissions, model provisioning, and BYOK cloud controls without requiring developer knowledge.
- Non-goals:
  - A general-purpose persistent text editor, chat interface, command palette, collaboration surface, or account dashboard. The bounded recording history is a recovery and local re-transcription surface, not a document workspace.
  - Pixel-identical imitation of Wispr Flow or a platform-neutral web-app aesthetic.
  - Decorative animation that competes with dictation status or affects target-field focus.
- Success signals:
  - A new user can identify what is required for local dictation and what is optional.
  - During dictation, state and cancel availability are understandable at a glance and through VoiceOver.
  - Handsfree state, elapsed time, and the 120-second automatic finalization boundary are explicit and do not rely on color alone.
  - Every saved recording can be deleted explicitly; re-transcription creates a new local transcript version without replacing older versions.
  - Local-only versus cloud-enabled behavior is never communicated by color alone.
  - Successful dictation ends directly in the focused text field without clipboard or result-window steps.

## Personas and jobs

- Primary personas: one privacy-conscious owner of an Apple-silicon Mac who writes frequently in German and English across native, browser, and Electron text fields.
- User jobs:
  - Dictate a message, note, or draft without leaving the current text field.
  - Receive conservative punctuation and formatting without changing intended meaning.
  - Recover a failed recording and compare locally generated transcript versions without re-recording.
  - Understand and control microphone, Accessibility, local model, context, and optional cloud boundaries.
  - Recover text safely when automatic insertion cannot be confirmed.
- Key contexts of use: short frequent dictations, mixed DE/EN vocabulary, quiet or moderately noisy desktop use, multi-app workflows, offline/local-only operation, and occasional explicit BYOK enrichment.

## Information architecture

- Primary navigation: the menu-bar item is the persistent entry point. Every durable surface opens the same primary app window. A native sidebar switches between `Übersicht`, `Aufnahmen`, `Diktat`, `Modelle`, `Lexikon`, `Privatsphäre`, `Cloud`, `Berechtigungen` und `Allgemein`; menu commands deep-link into those destinations without creating another window. There is no Dock-centric navigation.
- Core routes/screens:
  1. Overview: readiness, shortcut, required permissions, local model, and first-run completion. Onboarding is a state of this route, not a separate window.
  2. Flow Bar: transient `priming`, push-to-talk or Handsfree listening with elapsed time, local/cloud processing, inserted, cancelled, and error states.
  3. Recording history: saved local recordings, processing status, transcript versions, local model selection, retry, and explicit single/all deletion.
  4. Settings: Diktat → Modelle → Lexikon → Privatsphäre → Cloud → Berechtigungen → Allgemein.
- Content hierarchy: current state/action first; privacy consequence second; implementation detail only where it helps a decision. Required local setup appears before optional cloud configuration. The sidebar is the only top-level navigation; recording selection is the only justified secondary list.

## Design principles

- Principle 1 — Local is the baseline, not a badge: the interface states local readiness directly and treats cloud as a separately enabled enhancement.
- Principle 2 — Preserve the user’s focus: the Flow Bar never activates the app, stays compact, and provides only status plus cancellation while dictation is active.
- Principle 3 — Fail safe and leave a path forward: denied permissions, unsupported targets, cloud errors, and unconfirmed insertion provide actionable recovery without losing the local candidate.
- Principle 4 — Native restraint builds trust: prefer macOS controls, SF Symbols, typography, focus behavior, and semantic status colors. The durable app window adds a restrained warm canvas and one Coral Eclipse motif without replacing native control behavior.
- Principle 5 — Disclosure precedes side effects: model downloads, cloud transfer, Keychain changes, pasteboard writes, recording deletion, and other destructive discard actions require visible user intent.
- Principle 6 — History remains a local recovery boundary: saved audio and transcript versions persist until explicit deletion. History retry never invokes cloud enrichment, reads current target context, or inserts automatically.
- Tradeoffs: clarity and safety outrank visual novelty; compactness outranks showing every pipeline stage; the branded canvas must remain adaptive in Light and Dark appearances; conservative copy may be longer where privacy consequences must be explicit.

## Visual language

- Color:
  - The durable app window uses adaptive warm ivory/cocoa canvases and raised surfaces defined by `CoralEclipseStyle`; native labels and controls retain their semantic behavior.
  - `Coral` `#C43D34`, `Coral Soft` `#F5A89E`, and `Coral Mist` `#FAD1C9` form the single durable-window accent family. Coral denotes brand and interaction, never success, warning, or failure by itself.
  - `Warm Charcoal` `#181716` is reserved for the primary setup action and high-contrast editorial anchors.
  - `Brand Indigo 950` `#0A1530`, `Brand Indigo 800` `#1B3262`, `Flow Mint 300` `#9AF0C8`, and `Flow Mint 500` `#42D1B0` remain part of the current app-icon and transient Flow Bar identity until those surfaces receive a separate reviewed redesign.
  - Use macOS semantic green for confirmed success, orange for recoverable attention/fallback, red for destructive/error states, and secondary label color for neutral/cancelled states.
  - Do not place body text directly on Coral. Maintain at least WCAG AA contrast for text and essential glyphs in both appearances.
- Typography: use the system/SF family exclusively. Title 2 for compact destination headings, Headline for section/card titles, Callout for primary explanatory copy, Caption for provenance and privacy detail. Use monospaced system text only for hashes, versions, paths, or diagnostic identifiers.
- Spacing/layout rhythm: 4 pt base rhythm; preferred steps are 8, 12, 16, 24, and 32 pt. Overview uses one decorative readiness surface followed by flat divider-based rows. Each settings destination uses one raised content surface rather than a card grid. Keep one strong alignment edge per surface.
- Shape/radius/elevation: 18 pt destination/readiness surfaces, 11 pt compact controls, 10 pt result containers, and a continuous capsule for the Flow Bar. Durable app surfaces use a fine warm hairline instead of an outer glow. The Flow Bar shadow must fully fade inside the transparent panel bounds so no rectangular clipping edge is visible.
- Motion: brief system-standard presentation/hide transitions, approximately 120–180 ms where controllable. Active dictation states use a low-amplitude, 30 fps rainbow spectrum animation; terminal states are static. Respect Reduce Motion by freezing the spectrum; never animate window activation, focus, or text insertion.
- Imagery/iconography: use SF Symbols for interface actions and states. The app icon is an original, text-free mint flow/wave on indigo, generated deterministically by `Scripts/generate-app-icon.swift`. It must retain a simple silhouette at 16 px and must not be reused as a busy in-content illustration.

## Components

- Existing components to reuse:
  - `FlowBarView` and `FocusPreservingPanel` for transient pipeline state.
  - `SettingsSection` for grouped settings content.
  - `PermissionRow` and `PermissionSettingRow` for permission state/action pairs.
  - Native `Picker`, `Toggle`, `SecureField`, `ProgressView`, confirmation dialogs, and open/save panels.
- New/changed components:
  - `AppWindowController` owns the single primary `NSWindow`; repeated menu, reopen, overview, history, and settings requests reuse it.
  - `AppNavigationModel` owns the selected top-level destination. It changes content, never window identity.
  - `AppShellView` provides one native sidebar for overview, recordings, and settings subpages plus a quiet detail canvas. It must not resemble a web dashboard or a grid of feature cards.
  - `CoralEclipseStyle` owns the adaptive durable-window palette, the decorative `CoralEclipseBackdrop`, and the shared compact `CoralPageHeader`; it has no navigation or view-model dependency.
  - `AppOverviewView` absorbs first-run onboarding into the shared window and remains useful after setup as a concise readiness surface.
  - `AppIcon.appiconset` is the canonical application icon asset.
  - `RainbowWaveform` is the lightweight, decorative spectrum inside active Flow Bar states. Its geometry is deterministic, bounded, and independent of the audio callback.
  - The recording-history destination uses a secondary native list and detail controls for transcript-version selection, local retry, and explicit deletion inside the shared window.
  - A future reusable `ModeDisclosure` is justified only if the same local/cloud disclosure pattern appears on at least three surfaces; until then, compose native `Label` and `Text` elements locally.
- Variants and states:
  - Flow Bar: priming, push-to-talk listening, Handsfree listening, local processing, cloud processing, inserted, cancelled, error; cancellation only during active work. Listening exposes elapsed time and the 120-second boundary in text.
  - Recording history: recording, ready, transcribing, completed, failed, interrupted, empty, and deletion-confirmation states.
  - Permission rows: not determined, authorized, denied, restricted; required/optional must be written as text.
  - Model controls: checking, missing, importing, downloading, ready, invalid, failed.
  - Cloud controls: no key, key stored, Keychain unavailable, disabled, enabled without context, enabled with separately consented context.
- Token/component ownership: system semantic states remain owned by SwiftUI/AppKit. Durable-window brand values live in `CoralEclipseStyle` and this document. Do not add a theme framework, downloaded font, or dependency.

## Accessibility

- Target standard: macOS Human Interface Guidelines plus WCAG 2.2 AA for text, essential icons, and state communication.
- Keyboard/focus behavior: all settings and dialogs must support standard Tab/Shift-Tab traversal, Space/Return activation, Escape cancellation, and visible system focus rings. The Flow Bar remains non-key and exposes cancellation through the registered shortcut/menu rather than stealing focus.
- Contrast/readability: support Light, Dark, Increase Contrast, and Reduce Transparency system settings. Never rely on coral/green/orange/red without a title, symbol, or status string. Preserve text selection in fallback results.
- Screen-reader semantics: decorative symbols are hidden; combined rows receive concise labels including requirement and state; destructive and explicit-copy actions explain their consequence; transient Flow Bar state is exposed as one understandable element.
- Reduced motion and sensory considerations: honor `accessibilityDisplayShouldReduceMotion`; freeze the decorative spectrum under Reduce Motion and avoid pulsing, strobing, amplitude sampling on the audio callback, and unnecessary sound. State changes remain comprehensible through text and symbols with motion and color removed.

## Responsive behavior

- Supported breakpoints/devices: macOS 15+ on Apple-silicon Macs. There are no mobile, touch, browser, or web breakpoints in V1.
- Layout adaptations:
  - The primary window starts at 960 × 680 pt and remains usable down to 820 × 600 pt. Its sidebar uses a stable 190–220 pt width. The overview keeps its complete readiness summary visible without scrolling at the minimum window size; settings scroll only in the detail column, while recording history uses the remaining width for its list-detail split.
  - The visible Flow Bar capsule is 128–202 × 44 pt by state, with a larger transparent window inset that contains its fully faded shadow. It centers above the visible screen’s lower edge, remains within the active screen’s visible frame, and works across Spaces/full-screen apps.
  - Long privacy explanations wrap; primary action rows may stack vertically if localization or accessibility text sizing makes the horizontal layout ambiguous.
- Touch/hover differences: pointer and keyboard are primary. Hover may use native control feedback only; no information may exist exclusively on hover.

## Interaction states

- Loading: use a small native `ProgressView` with a concrete status such as checking, importing, or downloading. Do not use indefinite “magic” language.
- Empty: missing model/key/permission states explain whether the capability is required, what remains available, and the single next action.
- Error: use content-free, actionable categories. Preserve the local recording and available transcript versions when processing or insertion fails; do not expose raw provider/system errors in user-facing copy.
- Success: confirmation is brief and low-interruption (`Eingefügt`, model ready, key stored). Do not keep success panels visible longer than needed.
- Disabled: keep controls visible when they teach dependency order; explain that cloud requires a stored key and cloud context requires cloud enablement.
- Offline/slow network, if applicable: local dictation remains fully operable. Only explicit model provisioning and opted-in cloud enrichment show network progress; timeout/failure returns to the local candidate.

## Content voice

- Tone: direct, calm, concrete, and non-promotional. Explain what happens on this Mac before naming technology.
- Terminology:
  - Prefer `Nur lokal`, `lokales Diktat`, `optionale Cloud-Überarbeitung`, `begrenzter Kontext`, `direkt eingefügt`, and `Bedienungshilfen`.
  - Use `API-Schlüssel` in user copy and `OpenAI` only where provider identity matters.
  - Distinguish `Rohtranskript`, `lokaler Kandidat`, and `fertiger Text` consistently.
- Microcopy rules: lead with consequence, then scope, then technical detail. State defaults explicitly. Never imply that `store:false` equals Zero Data Retention, that Accessibility means whole-screen monitoring, or that a model download happens automatically.
- History copy must state that audio and transcript versions remain on this Mac until explicit deletion. Retry copy must state that it is local-only and does not insert automatically.

## Implementation constraints

- Framework/styling system: Swift 6.3, SwiftUI for content, AppKit for menu-bar/window/panel lifecycle and focus-sensitive UI. No third-party UI framework or icon library.
- Design-token constraints: prefer system semantic state colors and controls. Durable-window brand tokens must match the values in Visual language and use adaptive Light/Dark surfaces.
- Performance constraints: the status UI must not add work to the audio callback or critical dictation path. The Flow Bar is lightweight, nonactivating, and content-bounded.
- Compatibility constraints: macOS 15 deployment target, Hardened Runtime enabled, App Sandbox disabled for the private V1, and `LSUIElement = YES`/accessory activation policy retained. The app icon must compile through the native asset catalog without changing menu-bar-only behavior.
- Asset constraints: no Wispr assets, external images, text, lettermarks, downloaded fonts, or new dependencies. Regenerate all PNGs from the checked-in CoreGraphics script; do not hand-edit generated sizes.
- Test/screenshot expectations:
  - Build the asset catalog with `actool`/Xcode and verify every 1×/2× macOS slot.
  - Inspect the 1024 px preview and the rendered 16, 32, and 128 px assets at native scale.
  - For future UI changes, capture the unified window's overview, recording history, settings, and the Flow Bar active/error states in Light/Dark appearance; include sidebar keyboard navigation, transparent-corner, Increase Contrast, Reduce Transparency, and Reduce Motion checks for release-facing changes.

## Open questions

- [ ] Confirm whether `FlusterFlow` requires a naming/trademark check before any distribution beyond the owner. Owner: product. Impact: packaging only; no private-V1 blocker.
- [ ] Validate mint accent and semantic status colors under Increase Contrast, grayscale, and common color-vision deficiencies on the target Mac. Owner: design/accessibility. Impact: token tuning.
- [ ] Decide whether English UI localization enters V1-D or remains post-V1; current speech-language support does not imply interface localization. Owner: product. Impact: layout and copy QA.
- [ ] Verify Flow Bar placement with multiple displays, vertically positioned Docks, auto-hidden Docks, and full-screen Spaces. Owner: UX QA. Impact: panel positioning.
- [x] Reduce Transparency uses an explicit opaque indigo Flow Bar surface while preserving the same text, symbols, and static waveform fallback. Owner: accessibility. Impact: transient-panel readability.
- [ ] Run a final Finder/Dock visual check of the generated icon on macOS 15 and macOS 26 before packaging. Owner: release. Impact: optical sizing only.
