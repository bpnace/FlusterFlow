<p align="center">
  <img src="Assets/README/flusterflow-header.png" alt="Abstrakte FlusterFlow-Wellenform, die sich in Text verwandelt" width="1400">
</p>

<h1 align="center">FlusterFlow</h1>

<p align="center">
  Private, lokale Spracheingabe für macOS – vom gesprochenen Wort direkt an die aktuelle Cursorposition.
</p>

<p align="center">
  <a href="https://github.com/bpnace/FlusterFlow/actions/workflows/ci.yml"><img src="https://github.com/bpnace/FlusterFlow/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/Swift-6.0%2B-F05138?logo=swift&amp;logoColor=white" alt="Swift 6.0 oder neuer">
  <img src="https://img.shields.io/badge/macOS-15%2B-000000?logo=apple&amp;logoColor=white" alt="macOS 15 oder neuer">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-2D2D2D.svg" alt="MIT-Lizenz"></a>
</p>

FlusterFlow ist eine native macOS-Menüleisten-App für schnelles Diktieren in nativen Apps, Browsern und Electron-Anwendungen. Die Spracherkennung läuft standardmäßig vollständig lokal. Aufnahmen und Transkriptversionen bleiben wiederherstellbar auf dem eigenen Mac; eine textbasierte Cloud-Überarbeitung ist ein getrennt aktivierbarer BYOK-Pfad.

> **Status:** Version 0.4.0 ist derzeit als Release Candidate dokumentiert. Der unterstützte Daily-Driver-Weg ist ein lokal signierter Build aus dem Quellcode; Mikrofon, globaler Hotkey, Accessibility-Einfügung und TCC-Kontinuität bleiben manuelle Release-Gates.

## Highlights

- Globales Push-to-talk mit frei wählbarem Kürzel und nicht aktivierender Flow Bar
- Optionaler Handsfree-Modus per Doppeltipp auf dasselbe Kürzel
- Lokale Spracherkennung mit Parakeet, Qwen3-ASR oder Whisper
- Deutsch, Englisch und automatische Spracherkennung
- Lokale Aufnahmehistorie mit versionierten Transkripten und erneuter Transkription
- Bestätigte Einfügung an der aktuellen Cursorposition ohne automatische Zwischenablage
- Ein gemeinsames App-Fenster für Übersicht, Aufnahmen und Einstellungen
- Optionale OpenAI-Überarbeitung mit eigenem API-Key aus dem macOS-Schlüsselbund

## Voraussetzungen

- macOS 15 oder neuer
- Apple Silicon (`arm64`) für den dokumentierten Build- und Testpfad
- Xcode mit Swift 6; die CI verwendet derzeit Xcode 26.0.1 und Swift 6.2
- Mikrofon- und Bedienungshilfen-Berechtigung für den direkten Diktierpfad
- Optional Apples Xcode-Metal-Toolchain für das Qwen-Modell

Falls `xcrun metal --version` fehlschlägt, lässt sich die optionale Toolchain einmalig installieren:

```bash
xcodebuild -downloadComponent metalToolchain
```

## Schnellstart

```bash
git clone https://github.com/bpnace/FlusterFlow.git
cd FlusterFlow
bash Scripts/setup-private-signing.sh
bash Scripts/build-install-private.sh
```

Der Setup-Schritt erstellt einen ausschließlich lokal verwendeten FlusterFlow-Schlüsselbund mit stabiler Code-Signing-Identität. Das zufällige Kennwort bleibt im geschützten Supportordner des aktuellen Benutzers. Der Installer legt die signierte App unter `~/Applications/FlusterFlow.app` ab und startet sie.

Beim ersten Start:

1. Mikrofon und Bedienungshilfen in der Übersicht erlauben.
2. Ein gepinntes lokales Modell importieren oder dessen einmaligen Download ausdrücklich bestätigen.
3. Unter „Diktat“ Sprache und Kürzel auswählen. Standard ist `⌃⌥Leertaste`.
4. Optional Handsfree oder die getrennte Cloud-Überarbeitung aktivieren.

Für den lokalen Betrieb sind weder Konto noch OpenAI-Key erforderlich. FlusterFlow lädt Modelle nicht unbemerkt herunter.

### Warum eine fest installierte App?

macOS bindet Bedienungshilfen-Berechtigungen an die Code-Identität der App. Builds aus wechselnden `DerivedData`- oder `/tmp`-Pfaden können diese Zuordnung nach einem Neubau verlieren. Der private Installer erzeugt deshalb eine stabil signierte Installation; Debug-Builds verwenden eine separate Bundle-ID.

## Verwendung

Setze den Cursor in ein editierbares Textfeld, halte das ausgewählte Kürzel gedrückt, sprich und lasse es wieder los. FlusterFlow transkribiert und bereinigt den Text und erfasst unmittelbar vor der Einfügung das aktuell fokussierte Ziel erneut.

Ist Handsfree aktiviert, startet ein Doppeltipp auf das Kürzel die Aufnahme; ein weiterer Tastendruck beendet sie. Nach spätestens 120 Sekunden finalisiert FlusterFlow die bis dahin erfasste Aufnahme automatisch.

Die Aufnahmehistorie speichert Audio, Status und Transkriptversionen lokal bis zur ausdrücklichen Löschung. Eine Aufnahme kann dort mit einem anderen lokalen Modell erneut transkribiert werden – ohne Cloud-Aufruf, Kontextlesung oder automatische Einfügung.

## Datenschutz

Local-first ist der Standard und eine technische Grenze, kein bloßes Versprechen.

| Daten | Lokaler Standard | Optionale Cloud-Überarbeitung |
| --- | --- | --- |
| Audio | Aufnahme und Verarbeitung auf diesem Mac | Wird nie an OpenAI gesendet |
| Lokaler Textkandidat | Lokal erkannt und bereinigt | Nur bei aktivierter Überarbeitung übertragen |
| Cursor-Kontext | Keine Cloud-Übertragung | Bis zu 1.500 Zeichen mit zweitem, unabhängigem Opt-in |
| API-Key | Nicht erforderlich | Im macOS-Schlüsselbund gespeichert |
| History-Retry | Ausschließlich lokal | Ruft die Cloud nie auf |

Cloud-Überarbeitung ist standardmäßig aus. Wenn sie aktiviert wird, bleibt die Anfrage text-only und stateless mit `store:false`, ohne Tools, Dateien, Background-Modus oder Konversation. `store:false` ist kein Zero-Data-Retention-Versprechen; Kosten und Aufbewahrung richten sich nach dem eigenen API-Projekt.

Secure Fields und als geschützt markierte Accessibility-Ziele werden fail-closed behandelt: kein Kontext, keine Cloud und keine automatische Einfügung.

Mehr dazu: [Datenschutz-Datenfluss](docs/privacy-data-flow.md) · [Threat Model](docs/threat-model.md)

## Lokale Sprachmodelle

| Backend | Modell | Runtime |
| --- | --- | --- |
| Parakeet | Parakeet TDT 0.6B v3 | FluidAudio 0.15.5 |
| Qwen | Qwen3-ASR 0.6B 8-bit | MLXAudioSTT 0.1.3 / MLX Swift 0.31.4 |
| Whisper | Whisper Large v3 | WhisperKit 1.0.0 |
| Whisper | Whisper Large v3 Turbo | WhisperKit 1.0.0 |

Alle Runtime-Versionen sind exakt gepinnt. Modellordner und Tokenizer sind zusätzlich an unveränderliche Revisionen, Dateigrößen und SHA-256-Prüfsummen gebunden. Modellgewichte werden nicht in diesem Repository gespeichert.

Details: [Model Supply Chain](docs/model-supply-chain.md) · [Third-Party Notices](THIRD_PARTY_NOTICES.md)

## Entwicklung

Ein unsignierter Debug-Build:

```bash
xcodebuild -project WhisperFlow.xcodeproj -scheme WhisperFlow \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO build
```

Der normale lokale Testlauf ist auf höchstens 180 produktnahe Tests begrenzt:

```bash
bash Scripts/run-capped-tests.sh
bash Scripts/run-capped-tests.sh --verify-only
```

### Erweiterte Verifikation

```bash
bash Scripts/run-capped-tests.sh --full
swift build
swift test
bash Scripts/test-verified-artifact-chain.sh
bash Scripts/verify-local-network.sh
bash Scripts/verify-target-harness.sh
bash Scripts/verify-local-privacy.sh
```

Die regulären Tests verwenden weder einen echten OpenAI-Key noch Live-Requests oder reale Modelldownloads. Mikrofon-, Hotkey-, TCC- und Ziel-App-Verhalten müssen für einen Release-Build zusätzlich manuell auf dem Ziel-Mac geprüft werden.

Ein echtes lokales Qwen-Diktat mit vorhandener Audiodatei:

```bash
bash Scripts/run-qwen-smoke-test.sh /pfad/zur/aufnahme.aiff
```

Die isolierten AppKit-, WKWebView-, Accessibility- und Privacy-Harnesses sind unter [Verification Harnesses](docs/verification-harnesses.md) beschrieben.

## Dokumentation

- [Produktdefinition](PRODUCT.md)
- [Datenschutz-Datenfluss](docs/privacy-data-flow.md)
- [Threat Model](docs/threat-model.md)
- [Model Supply Chain](docs/model-supply-chain.md)
- [Verification Harnesses](docs/verification-harnesses.md)
- [Architecture Decision Records](docs/adr)
- [Release Notes 0.4.0](docs/release-v0.4.0.md)

## Beiträge

Änderungen müssen die lokalen, fail-closed Datenschutz- und Einfügungsgrenzen erhalten und die jeweils betroffenen Prüfungen bestehen. Bitte halte Pull Requests fokussiert, dokumentiere neue Daten- oder Netzwerkpfade ausdrücklich und füge Regressionstests für geändertes Verhalten hinzu.

## Lizenz

Der FlusterFlow-Quellcode steht unter der [MIT-Lizenz](LICENSE). Abhängigkeiten und Modellartefakte unterliegen ihren jeweiligen Lizenzen und Bedingungen; maßgeblich sind die [Third-Party Notices](THIRD_PARTY_NOTICES.md) und die verlinkten Upstream-Lizenztexte.
