# FlusterFlow

FlusterFlow ist eine private, native macOS-Diktier-App nach dem Bedienprinzip von Wispr Flow. `WhisperFlow` bleibt der interne Projekt- und Modulname.

## MVP-Stand

Der MVP ist als Swift-6-Menüleisten-App für macOS 15 oder neuer integriert. Er umfasst:

- globales Push-to-talk mit konfigurierbarer Tastenkombination und nicht aktivierender Flow Bar;
- optionales Handsfree-Diktat per Doppeltipp auf dasselbe Kürzel; der nächste Tastendruck beendet die Aufnahme;
- echte Mikrofonwahl und eine auf 120 Sekunden begrenzte Aufnahme; beim Erreichen der Grenze wird der bis dahin erfasste Inhalt automatisch finalisiert statt verworfen;
- lokale Aufnahmehistorie mit Audio, Status und versionierten Transkripten, einschließlich erneutem Transkribieren mit einem auswählbaren lokalen Modell;
- frei wählbares lokales ASR: Parakeet TDT 0.6B v3 über FluidAudio `0.15.5`, Qwen3-ASR 0.6B 8-bit über MLXAudioSTT `0.1.3` sowie Whisper Large v3 und Large v3 Turbo über WhisperKit `1.0.0`;
- Deutsch, Englisch und automatische Spracherkennung;
- deterministisches lokales Cleanup sowie begrenzte Context Awareness;
- strikte, bestätigte Einfügung an der unmittelbar vor dem Commit neu erfassten Cursorposition: native Felder über Accessibility-Mutationen, webbasierte Chatfelder über direkte Unicode-Tastaturereignisse und immer ohne automatische Zwischenablage;
- optionale OpenAI-Überarbeitung mit eigenem API-Key aus dem macOS-Schlüsselbund;
- explizites Onboarding für Mikrofon, Bedienungshilfen und das lokale Modell;
- inhaltsfreie Diagnosemetriken mit p50/p95-Export.

## Datenschutzvertrag

Die Standardeinstellung ist vollständig lokal. Nach einmaliger Modellbereitstellung benötigt der Diktatpfad kein Netzwerk, kein Konto und keine laufenden Kosten. Aufnahmen, Statusdaten und Transkriptversionen der Historie liegen ausschließlich im FlusterFlow-Ordner unter `~/Library/Application Support` und bleiben dort, bis sie einzeln oder vollständig ausdrücklich gelöscht werden. Die Historie erzeugt keine Telemetrie und nutzt die allgemeine Zwischenablage nicht automatisch.

Ein erneuter Transkriptionslauf aus der Historie verarbeitet das gespeicherte Audio ausschließlich mit dem ausgewählten lokalen Modell. Dabei werden weder Audio noch Text an OpenAI gesendet, kein Kontext aus der aktuell fokussierten App gelesen und kein Ergebnis automatisch in ein Textfeld eingefügt. Die optionale Cloud-Überarbeitung bleibt ein separater, bewusst aktivierter Pfad für ein neu ausgeführtes Diktat.

Cloud-Überarbeitung ist standardmäßig aus. Sie wird nur genutzt, wenn sie in den Einstellungen aktiviert ist und ein eigener API-Key im Schlüsselbund liegt. Audio wird nie an OpenAI gesendet. Übertragen wird höchstens der fertige lokale Textkandidat; bis zu 1.500 Zeichen Kontext benötigen einen zweiten, unabhängigen Schalter. Die Anfrage ist text-only und stateless mit `store:false`, ohne Tools, Dateien, Background-Modus oder Konversation. `store:false` ist kein Zero-Data-Retention-Versprechen; Kosten und Aufbewahrung richten sich nach dem eigenen API-Projekt.

Secure Fields und als geschützt markierte Accessibility-Ziele werden fail-closed behandelt: kein Kontext, keine Cloud und keine automatische Einfügung.

Details stehen in [docs/privacy-data-flow.md](docs/privacy-data-flow.md) und [docs/threat-model.md](docs/threat-model.md).

## Erste Einrichtung

Der Qwen-Build benötigt Apples optionale Xcode-Metal-Toolchain. Falls `xcrun metal --version` noch fehlschlägt, wird sie einmalig mit `xcodebuild -downloadComponent metalToolchain` installiert.

1. Einmalig `bash Scripts/setup-private-signing.sh` ausführen. Dadurch entsteht ein ausschließlich lokal verwendeter FlusterFlow-Schlüsselbund mit stabiler Code-Signing-Identität. Sein zufälliges Kennwort liegt nur im geschützten FlusterFlow-Supportordner des aktuellen Benutzers.
2. Für die normale private Einrichtung mit `bash Scripts/build-install-private.sh` eine signierte Release-App unter `~/Applications/FlusterFlow.app` installieren und starten. Für Release- oder TCC-Evidenz muss stattdessen die in `docs/verification-harnesses.md` dokumentierte verifizierte Artefaktkette verwendet werden; der Standard-Installer baut dafür ausdrücklich nicht dasselbe Artefakt.
3. Im Onboarding Mikrofon und Bedienungshilfen ausdrücklich erlauben. Beides ist für den direkten Diktierpfad erforderlich.
4. Das gepinnte lokale Modell in den Einstellungen importieren oder den einmaligen Download bewusst bestätigen. Es erfolgt kein automatischer Modelldownload.
5. Sprache, Mikrofon und Push-to-talk-Kürzel auswählen. Standard ist `⌃⌥Leertaste`. Handsfree kann separat aktiviert werden und startet dann per Doppeltipp auf dieses Kürzel.
6. Optional später unter „Cloud“ den eigenen OpenAI-API-Key hinterlegen und Cloud-Überarbeitung aktivieren. Für den lokalen Betrieb ist kein Key nötig.

Nicht aus wechselnden `DerivedData`- oder `/tmp`-Pfaden starten: Ad-hoc-/Test-Builds besitzen nach jedem Neubau eine andere Code-Identität und verlieren deshalb die Zuordnung zu bereits erteilten Bedienungshilfen. Für den privaten Daily Driver ist ausschließlich die fest installierte und lokal signierte App vorgesehen. Debug-Builds verwenden deshalb eine getrennte Bundle-ID, und der Installer hinterlässt keine weiteren `.app`-Kopien. Der Release-Build führt mit aktiviertem Hardened Runtime ausschließlich das von Apple für Audioaufnahme verlangte `com.apple.security.device.audio-input`-Entitlement.

Ein lokaler Import erwartet den Inhalt des jeweils gepinnten Modellordners. Jede Datei wird vor Installation anhand von Größe und SHA-256 geprüft. Die installierten Modelle liegen getrennt unter:

```text
~/Library/Application Support/FlusterFlow/Models/parakeet-tdt-0.6b-v3
~/Library/Application Support/FlusterFlow/Models/qwen3-asr-0.6b-8bit
~/Library/Application Support/FlusterFlow/Models/whisper-large-v3-v20240930-626mb
~/Library/Application Support/FlusterFlow/Models/whisper-large-v3-v20240930-turbo-632mb
~/Library/Application Support/FlusterFlow/Models/whisper-large-v3-tokenizer
```

Modellherkunft, Revisionen und Updatevertrag sind in [docs/model-supply-chain.md](docs/model-supply-chain.md) dokumentiert.

## Verwenden

Den Cursor in ein editierbares Textfeld setzen, das ausgewählte Kürzel gedrückt halten, sprechen und loslassen. Wenn Handsfree aktiviert ist, startet ein Doppeltipp auf das Kürzel die freihändige Aufnahme; ein weiterer Tastendruck beendet sie. Nach spätestens 120 Sekunden finalisiert FlusterFlow die bis dahin erfasste Aufnahme automatisch. FlusterFlow erkennt, bereinigt und überarbeitet den Text und erfasst direkt vor der Einfügung das dann aktuell fokussierte Textfeld samt Auswahl oder Cursorposition neu. Der fertige Text ersetzt die Auswahl beziehungsweise erscheint an der Einfügemarke; die automatische Einfügung verwendet keine allgemeine Zwischenablage. Secure Fields und Nicht-Textfelder werden nicht beschrieben.

Die lokale Historie bewahrt Aufnahme und Transkriptversionen bis zum ausdrücklichen Löschen auf. Von dort kann eine Aufnahme mit einem anderen lokalen Modell erneut transkribiert werden, ohne Cloud-Aufruf, Kontextlesung oder automatische Einfügung.

## Bauen und testen

Der normale Testlauf ist auf höchstens 180 produktnahe Tests begrenzt. Der
vollständige Bestand bleibt als expliziter Extended-Lauf erhalten.

```bash
xcodebuild -project WhisperFlow.xcodeproj -scheme WhisperFlow \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO build

bash Scripts/run-capped-tests.sh
bash Scripts/run-capped-tests.sh --verify-only

# Extended/Release, nicht der normale lokale Lauf:
bash Scripts/run-capped-tests.sh --full
swift build
swift test
bash Scripts/test-verified-artifact-chain.sh
bash Scripts/verify-local-network.sh
bash Scripts/verify-target-harness.sh
bash Scripts/verify-local-privacy.sh
```

Die regulären automatisierten Tests verwenden weder einen echten OpenAI-Key noch einen Live-Request oder einen realen Modelldownload. Explizit aktivierbare lokale Smoke-Tests validieren und laden bereits installierte Whisper- und Qwen-Modelle, bleiben im normalen Testlauf aber übersprungen. Mikrofon-, Accessibility- und Ziel-App-Verhalten müssen für einen Daily-Driver-Build zusätzlich manuell auf dem Ziel-Mac geprüft werden.

Ein echtes lokales Qwen-Diktat lässt sich mit einer vorhandenen Audiodatei prüfen:

```bash
bash Scripts/run-qwen-smoke-test.sh /pfad/zur/aufnahme.aiff
```

Die isolierten AppKit-/WKWebView- und Local-only-Privacy-Harnesses sind in [docs/verification-harnesses.md](docs/verification-harnesses.md) beschrieben. Die echte Cross-Process-AX-Prüfung ist TCC-abhängig; Safari-, Chromium- und Electron-Ergebnisse werden über einen inhaltsfreien JSON-Vertrag manuell erfasst.

## Gepinnte Runtime

FluidAudio ist exakt auf `0.15.5` gepinnt. MLXAudioSTT verwendet `mlx-audio-swift` exakt in Version `0.1.3` und `mlx-swift` exakt in Version `0.31.4`; Xcode erzeugt die Metal-Ressource beim App-Build aus der ebenfalls gepinnten MLX-Revision. WhisperKit verwendet `argmax-oss-swift` exakt in Version `1.0.0`. Alle Modellordner und Tokenizer sind zusätzlich an unveränderliche Hugging-Face-Revisionen sowie vollständige Datei-Hashes gebunden. Details stehen in [docs/model-supply-chain.md](docs/model-supply-chain.md).

## Commit-Konvention

Die erste Commit-Zeile beschreibt die Absicht; optionale Trailer dokumentieren Constraints, verworfene Alternativen, Risiko und tatsächliche Verifikation.
