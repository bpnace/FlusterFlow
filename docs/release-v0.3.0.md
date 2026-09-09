# FlusterFlow 0.3.0 (Build 17)

Status: Release candidate. Dieses Dokument behauptet weder bestandene CI noch eine veröffentlichte Version. Ergebnisse werden erst nach den jeweiligen Läufen eingetragen.

## Ziel des Releases

Version 0.3.0 schließt die beiden Produktlücken aus GitHub #1 und #2:

- Aufnahmen gehen bei einem Transkriptionsfehler oder beim Erreichen der Zeitgrenze nicht mehr still verloren.
- Eine lokale Historie bewahrt Audio, Status und versionierte Transkripte bis zum ausdrücklichen Löschen auf.
- Gespeichertes Audio kann mit einem auswählbaren lokalen ASR-Modell erneut transkribiert werden. Der Retry-Pfad verwendet keine Cloud-Überarbeitung, liest keinen aktuellen Zielkontext und fügt nicht automatisch ein.
- Optionales Handsfree startet per Doppeltipp auf das bestehende Diktat-Kürzel. Ein weiterer Tastendruck beendet die Aufnahme; normales Gedrückthalten und Loslassen bleibt Push-to-talk.
- Die Flow Bar zeigt den Aktivierungsmodus und die verstrichene Aufnahmezeit. Bei 120 Sekunden wird die bis dahin erfasste Aufnahme genau einmal automatisch finalisiert.

## Datenschutz- und Persistenzvertrag

- Audio, Statusmetadaten und Transkriptversionen liegen lokal im FlusterFlow-Bereich unter `~/Library/Application Support`.
- Diese Daten bleiben erhalten, bis der Nutzer eine Aufnahme oder die gesamte Historie ausdrücklich löscht.
- History-Retry ist ausschließlich lokal. Er sendet weder Audio noch Transkript an OpenAI.
- History-Retry liest keinen Text aus der aktuell fokussierten App und führt keine automatische Einfügung aus.
- Die optionale OpenAI-Überarbeitung bleibt standardmäßig deaktiviert und ist kein Bestandteil des History-Retry-Pfads.
- Das Release-Entitlement bleibt auf `com.apple.security.device.audio-input` beschränkt.

## Automatische Release-Gates

Die GitHub-CI läuft auf einem macOS-Runner mit dem explizit ausgewählten Xcode 26.0.1/Swift 6.2, ohne Signing-Identität oder API-Key. Sie führt aus:

```bash
bash Scripts/run-capped-tests.sh --verify-only
xcodebuild -project WhisperFlow.xcodeproj -scheme WhisperFlow \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO build
bash Scripts/run-capped-tests.sh
swift test
bash Scripts/test-verified-artifact-chain.sh
bash Scripts/verify-local-network.sh
bash Scripts/verify-target-harness.sh
bash Scripts/verify-local-privacy.sh
```

Zusätzlich muss `verify-private-signing.sh --check-prerequisites` in CI erwartungsgemäß mit Exitcode 77 und `identity_required` enden. Das ist die bestätigte Credential-Grenze, kein bestandener Signing-Test.

| Gate | Erwartung | Ergebnis |
| --- | --- | --- |
| Capped-Testplan | höchstens 180 ausgewählte Tests, keine fehlenden Einträge | Ausstehend |
| Unsigned Xcode-Build | Debug-App kompiliert ohne Signing | Ausstehend |
| Capped App-Tests | ausgewählte Produkt- und Regressionstests bestehen | Ausstehend |
| SwiftPM-Tests | Package- und Harness-Tests bestehen | Ausstehend |
| Verifizierte Artefaktkette | Export, CDHash-Bindung, Prozessprüfung und Rollback-Verträge bestehen | Ausstehend |
| Netzwerk-Boundary | nur freigegebene Netzwerkpfade, `store:false` fest verdrahtet | Ausstehend |
| Target-Harness | Vertrags- und Negativtests bestehen | Ausstehend |
| Local-Privacy-Harness | lokale Smoke- und Negativkontrollen bestehen | Ausstehend |
| Signing-Prerequisite | CI bleibt ohne Identity bei `identity_required` blockiert | Ausstehend |

## Lokale RC-Verifikation am 8./9. September 2026

Geprüft wurde der uncommittete Arbeitsstand auf Branch `feature/recording-history-handsfree` mit Basisrevision `3d36f65cc4119417d2921623751a794fd802ea0b`. Die Ergebnisse belegen genau diesen lokalen Arbeitsstand, sind aber noch keine unveränderliche Commit-, CI- oder Release-Quittung. Nach dem finalen Commit müssen die erforderlichen Gates erneut an dessen Hash gebunden werden.

| Prüfung | Ergebnis |
| --- | --- |
| Capped-Testplan | PASS, 180 von maximal 180 Tests ausgewählt |
| Vollständige Xcode-Tests | PASS, 393 Tests, 14 erwartete opt-in Smokes übersprungen, 0 Fehler |
| SwiftPM-Tests | PASS, 424 Tests, 14 erwartete opt-in Smokes übersprungen, 0 Fehler |
| Source-Contract-Frische | PASS, Produktionsquellen werden direkt aus dem Live-Checkout gelesen; Frischetest in SwiftPM und Xcode bestanden |
| Verifizierte Artefaktkette | PASS, einschließlich verhaltensbasiertem Signal-/Rollback-Test nach dem Backup-Rename |
| Unsigned Xcode-Build | PASS |
| Netzwerk-Boundary | PASS |
| Target-Harness | PASS, 28 Vertragsdefinitionen validiert; kein installierter Produkt-E2E-Lauf |
| Local-Privacy-Harness | PASS, synthetischer Harness-Selbsttest mit 0 Leaks und unverändertem Pasteboard |
| Echte Audioeingabe, Whisper | PASS, physische MacBook-Mikrofonaufnahme; Turbo, Large und Adaptive separat ausgeführt, 3 Tests, 0 Fehler |
| Echte Audioeingabe, Qwen | PASS, dieselbe physische Mikrofonaufnahme mit installiertem lokalen Modell, 1 Test, 0 Fehler |
| Smoke-Datenschutz | PASS, kein Transkripttext in der Testausgabe; temporäres `xcresult` nach dem Lauf entfernt |
| Signing-Prerequisite | Erwarteter Exitcode 77 mit `identity_required`; kein signiertes Artefakt erzeugt |
| Doppelte Release-Signaturprüfung | Erwartete lokale Self-Signed-Grenze mit Exitcode 77; zwei Builds, alle Signaturverträge identisch, Export erzeugt und an CDHash `7B4156055C64C14C0D72A16EB727ED7AB8CE21C8` gebunden |
| Installation des verifizierten Exports | PASS, kein Neubau; installierter CDHash und Prozesspfad stimmen mit dem Export überein |
| Signing-Keychain-Hygiene | PASS, die temporär erweiterte Benutzer-Suchliste wird nach Erfolg und Fehler auf den ursprünglichen Login-Schlüsselbund zurückgesetzt |
| Installierter TCC-/Hotkey-Smoke | PASS, physischer Doppeltipp auf `Option-Leertaste`, 8,7 Sekunden echte Mikrofoneingabe, einzelner Stopp-Tastendruck, History-Status `completed`, gültiges Audio und bestätigte Einfügung in TextEdit |

Der erste installierte Handsfree-Lauf reproduzierte einen unbeschränkten Verarbeitungszustand und endete nach Nutzerabbruch mit `staleSession`. Nach Einführung der absoluten ASR-Zeitgrenze, begrenzter Cancellation-Grace, Backend-Quarantäne und fail-bounded Lifecycle-Aufräumung bestand der oben dokumentierte Wiederholungslauf. Die drei ausschließlich für diese Untersuchung erzeugten History-Einträge wurden danach entfernt und Handsfree auf den ursprünglichen Aus-Zustand zurückgesetzt. Kein Transkriptinhalt wurde in die Testprotokolle oder diese Quittung übernommen.

Diese lokale Verifikation ersetzt weder die GitHub-CI noch die noch offenen manuellen Negativ- und Langzeittests auf dem Ziel-Mac.

## Manuelle Prüfung auf dem Ziel-Mac

- Push-to-talk starten, halten und durch Loslassen beenden; bisheriges Verhalten muss unverändert bleiben.
- Handsfree aktivieren, durch Doppeltipp starten und durch einen weiteren Tastendruck beenden.
- Escape/Abbruch während Handsfree prüfen; es darf keine späte Transkription oder Einfügung folgen.
- 120 Sekunden aufnehmen und bestätigen, dass der Präfix automatisch genau einmal finalisiert und in der Historie erhalten wird.
- Einen lokalen ASR-Fehler provozieren und bestätigen, dass Audio und Fehlerstatus erhalten bleiben.
- Dieselbe Aufnahme mit einem anderen lokalen Modell erneut transkribieren; beide Transcript-Versionen müssen erhalten bleiben.
- Während History-Retry Netzwerkaktivität, Zielkontext und automatische Einfügung ausschließen.
- Einzelnes Löschen und „Alle löschen“ jeweils mit sichtbarer Bestätigung prüfen.
- Lokal signierten Release-Build zweimal prüfen und dabei mit `Scripts/verify-private-signing.sh --identity '<40-hex-fingerprint>' --export-app "$VERIFIED_ROOT/FlusterFlow.app"` genau eines dieser geprüften Artefakte exportieren. Den inhaltsfreien `cdHash` aus der JSON-Ausgabe anschließend unverändert an `Scripts/build-install-private.sh --verified-app "$VERIFIED_ROOT/FlusterFlow.app" --expected-cdhash '<cdHash>'` übergeben. Mikrofon-/Accessibility-TCC-Kontinuität ausschließlich an diesem installierten Artefakt testen; kein erneuter Build zwischen Verifikation und Smoke.

## Veröffentlichung

Ein Tag oder GitHub-Release `v0.3.0` darf erst erstellt werden, wenn die automatischen Gates bestanden sind, die manuellen Ziel-Mac-Prüfungen dokumentiert wurden und der Merge-/Release-Schritt separat freigegeben ist. GitHub-Issues #1 und #2 werden erst nach dem Smoke-Test des veröffentlichten Artefakts geschlossen.
