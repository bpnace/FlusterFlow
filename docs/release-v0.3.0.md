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

Diese lokale Verifikation ersetzt weder die GitHub-CI noch die noch offenen manuellen Negativ- und Langzeittests auf dem Ziel-Mac. Die anschließende Umstellung auf die neutrale Bundle- und Signing-Identität macht insbesondere die Signing-, Installations-, TCC-, Hotkey-, Accessibility- und Mikrofonergebnisse in den Zeilen 74 bis 77 zu historischer Diagnoseevidenz; sie gelten nicht als Release-Nachweis für das neue Artefakt.

Die Identitätsumstellung ist eine bewusste lokale Breaking Change. Bestehende Einstellungen, Onboarding-Status, Kürzel und persönliche Lexikoneinträge aus der vorherigen Preferences-Domain werden nicht migriert, damit die frühere personenbezogene Kennung weder im Quellcode noch in der Repository-Historie fortgeführt wird. Der Nutzer muss diese Einstellungen und die macOS-Berechtigungen einmalig neu setzen. Die lokal gespeicherte Aufnahmehistorie und lokale Modelle bleiben erhalten, weil ihre Speicherorte nicht von der Bundle-ID abhängen.

## Installierter Smoke mit neutraler Identität am 9. September 2026

Die folgenden Laufzeitprüfungen gelten für die lokal installierte App mit Bundle-ID `com.flusterflow.private`, Version 0.3.0, Build 17 und CDHash `1696D67F7056DC422B273B80A03A711A7481E4F8`. Sie enthalten keine Transkriptinhalte, Aufnahme-IDs, Gerätebezeichnungen oder Audio-Hashes. Die Prüfungen belegen dieses installierte Artefakt; die Commit-Bindung und GitHub-CI müssen nach dem finalen Commit erneut hergestellt werden.

| Prüfung | Ergebnis |
| --- | --- |
| Physischer Handsfree-Happy-Path | PASS, 6,5 Sekunden echte Mikrofoneingabe, Status `completed`, gültiges nichtleeres Audio, genau eine Transkriptversion und bestätigte Einfügung in TextEdit |
| Crash-Wiederherstellung | PASS, laufende Aufnahme nach einem erzwungenen Prozessabbruch beim Neustart als `interrupted` wiederhergestellt; checkpoint-gesichertes Audio blieb vorhanden |
| Retry der wiederhergestellten Aufnahme | PASS, dieselbe Aufnahme lokal erneut transkribiert; Status anschließend `completed`, Audio unverändert, Zwischenablage und vorhandenes TextEdit-Dokument unverändert |
| Erneute Transkription mit anderem Modell | PASS, zu einer bereits abgeschlossenen realen Aufnahme wurde mit Parakeet genau Version 2 ergänzt; Version 1 und Audio blieben erhalten, keine automatische Einfügung und keine Zwischenablageänderung |
| 120-Sekunden-Grenze | PASS, echte Audioeingabe wurde nach 119,2 Sekunden automatisch genau einmal finalisiert; genau ein History-Eintrag mit Audio und genau einer Transkriptversion, keine Zwischenablageänderung |
| Countdown-Vertrag | PASS auf dem installierten Artefakt: Der Flow-Bar-Knoten wurde über `flow-bar.recording-timer` gefunden, sein macOS-Wert `AXValueDescription` wechselte nach 105 Sekunden zu `noch MM:SS verbleibend`, und ein eng auf die Flow Bar zugeschnittener Screenshot bestätigte den sichtbaren orangenen Countdown. Der Screenshot wurde nach der Sichtprüfung gelöscht. |
| Failure-zu-Retry-Regression | PASS, Produktionskomponenten für Store, Recorder, Audio-Ownership, Recognizer-Router und History-ViewModel bewahren beim Erkennungsfehler denselben Eintrag und dasselbe Audio; der anschließende Retry endet ohne Buffer- oder Lease-Restzustand in `completed` |
| Vollständige Xcode-Tests des finalen Arbeitsstands | PASS, 395 Tests, 14 erwartete opt-in Smokes übersprungen, 0 Fehler |
| SwiftPM-Tests des finalen Arbeitsstands | PASS, 426 Tests, 14 erwartete opt-in Smokes übersprungen, 0 Fehler |
| Capped App-Tests des finalen Arbeitsstands | PASS, 180 von maximal 180 Tests, 0 Fehler; der neue Version-2-Regressionsfall ist im Capped-Plan enthalten |
| Build und lokale CI-Grenzen des finalen Arbeitsstands | PASS, unsigned Debug-Build, Artefaktketten-Vertrag, Netzwerk-Boundary, Target-Harness und Local-Privacy-Harness; Signing-Prerequisite erwartungsgemäß mit `identity_required` blockiert |

Die ausschließlich für Crash- und Langzeittest angelegten History-Einträge sowie das dafür erzeugte TextEdit-Testdokument wurden anschließend gezielt in den Papierkorb verschoben. Die bereits vorhandene reale Aufnahme mit der additiv erzeugten zweiten Transkriptversion blieb unangetastet.

## Manuelle Prüfung auf dem Ziel-Mac

- Push-to-talk starten, halten und durch Loslassen beenden; bisheriges Verhalten muss unverändert bleiben.
- Handsfree aktivieren, durch Doppeltipp starten und durch einen weiteren Tastendruck beenden.
- Escape/Abbruch während Handsfree prüfen; es darf keine späte Transkription oder Einfügung folgen.
- [x] 120 Sekunden aufnehmen und bestätigen, dass der Präfix automatisch genau einmal finalisiert und in der Historie erhalten wird.
- [x] Eine laufende Aufnahme durch einen Prozessabbruch unterbrechen und bestätigen, dass checkpoint-gesichertes Audio und Unterbrechungsstatus nach dem Neustart erhalten bleiben und ein lokaler Retry gelingt.
- [x] Dieselbe Aufnahme mit einem anderen lokalen Modell erneut transkribieren; beide Transcript-Versionen müssen erhalten bleiben.
- [ ] Einen echten lokalen ASR-Fehler provozieren und bestätigen, dass Audio und Fehlerstatus erhalten bleiben. Der automatisierte Produktionskomponenten-Durchstich für Fehler, Persistenz und erfolgreichen Retry besteht; der installierte Modellruntime-Negativtest bleibt separat offen.
- Während History-Retry Netzwerkaktivität, Zielkontext und automatische Einfügung ausschließen.
- Einzelnes Löschen und „Alle löschen“ jeweils mit sichtbarer Bestätigung prüfen.
- Lokal signierten Release-Build zweimal prüfen und dabei mit `Scripts/verify-private-signing.sh --identity '<40-hex-fingerprint>' --export-app "$VERIFIED_ROOT/FlusterFlow.app"` genau eines dieser geprüften Artefakte exportieren. Den inhaltsfreien `cdHash` aus der JSON-Ausgabe anschließend unverändert an `Scripts/build-install-private.sh --verified-app "$VERIFIED_ROOT/FlusterFlow.app" --expected-cdhash '<cdHash>'` übergeben. Mikrofon-/Accessibility-TCC-Kontinuität ausschließlich an diesem installierten Artefakt testen; kein erneuter Build zwischen Verifikation und Smoke.
- Nach der Umstellung auf die neutrale App-Identität Einstellungen und persönliche Lexikoneinträge neu setzen, Mikrofon- und Accessibility-Zugriff neu freigeben und den vollständigen installierten Hotkey-/Real-Audio-Smoke erneut ausführen.

## Veröffentlichung

Ein Tag oder GitHub-Release `v0.3.0` darf erst erstellt werden, wenn die automatischen Gates bestanden sind, die manuellen Ziel-Mac-Prüfungen dokumentiert wurden und der Merge-/Release-Schritt separat freigegeben ist. GitHub-Issues #1 und #2 werden erst nach dem Smoke-Test des veröffentlichten Artefakts geschlossen.
