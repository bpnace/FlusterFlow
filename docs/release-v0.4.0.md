# FlusterFlow 0.4.0 (Build 18)

Status: Release Candidate

## Schwerpunkt

Version 0.4.0 fasst die bisher getrennten dauerhaften Oberflächen in einem einzigen nativen App-Fenster zusammen:

- Übersicht, Aufnahmen und alle Einstellungen verwenden dieselbe `NSWindow`-Instanz und eine gemeinsame Sidebar.
- Die Ersteinrichtung ist Bestandteil der kompakten Übersicht statt eines separaten Fensters.
- Menübefehle und erneutes Öffnen navigieren in das bestehende Fenster, ohne parallele Settings- oder History-Fenster zu erzeugen.
- Das adaptive Coral-Eclipse-System vereinheitlicht Canvas, Seitentitel, Akzent und Oberflächen, während Erfolgs-, Hinweis- und Löschzustände ihre semantischen Systemfarben behalten.
- Die Übersicht bleibt bei der Mindestgröße 820 × 600 pt ohne Scrollen vollständig sichtbar.

Die Diktat-, Handsfree-, Aufnahme-, History-, Retry-, Cloud- und Einfügelogik bleibt gegenüber 0.3.0 unverändert.

## Datenschutz- und Datenvertrag

- Die Standardeinstellung bleibt vollständig lokal.
- Audio, Statusdaten und Transkriptversionen bleiben bis zur ausdrücklichen Löschung auf diesem Mac.
- History-Retry bleibt ausschließlich lokal und führt weder Kontextlesung noch automatische Einfügung aus.
- Optionale Cloud-Überarbeitung bleibt ein gesondert aktivierter textbasierter BYOK-Pfad.
- Die neue Oberfläche führt keine Telemetrie, Benutzerkonten, neuen Netzwerkpfade oder Abhängigkeiten ein.

## Verifikation des Release Candidates

Die folgenden automatischen und visuellen Nachweise müssen an den final gepushten Commit gebunden sein:

| Prüfung | Erwartung |
| --- | --- |
| Repository-Hygiene | Keine lokalen Agenten-, Aufnahme-, Signing-, Build- oder Secret-Artefakte im Index oder in der erreichbaren Historie |
| Unsigned Xcode-Build | Debug-App kompiliert ohne Signing |
| Capped-/Full-Testplan | Alle ausgewählten und erweiterten Tests bestehen |
| SwiftPM | Build und Tests bestehen |
| Privacy-/Network-/Target-Harnesses | Alle fail-closed Verträge bestehen |
| Einheitliches Fenster | Navigation nutzt genau eine wiederverwendete primäre Fensterinstanz |
| Visueller Smoke | Übersicht, Einstellungen und befülltes Archiv passen bei 820 × 600 pt |
| Accessibility-Semantik | Coral ist Interaktionsfarbe; Bereit ist grün, Attention orange und destruktiv rot |

## Noch nicht durch diesen Commit bewiesen

- Der installierte, signierte Build 18 wurde noch nicht mit physischer Mikrofoneingabe, globalem Hotkey, Accessibility-Einfügung und TCC-Kontinuität geprüft.
- Dark Mode, Increase Contrast und VoiceOver benötigen noch einen abschließenden manuellen visuellen Lauf am Release-Artefakt.
- Ein Tag oder GitHub-Release `v0.4.0` darf erst nach erfolgreicher CI und separater Freigabe des verifizierten Artefakts erstellt werden.
