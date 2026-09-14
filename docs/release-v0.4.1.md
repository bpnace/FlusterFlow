# FlusterFlow 0.4.1 (Build 19)

Patch für die Zuverlässigkeit von Aufnahme, Verarbeitung und Textwiederherstellung.

## Korrekturen

- Laufende Aufnahmen werden nicht mehr nach 120 Sekunden beendet. Ein temporärer Audiopuffer auf dem Datenträger ersetzt die feste Aufnahmegrenze; die abschließende Normalisierung lädt die Aufnahme weiterhin in den Arbeitsspeicher.
- Das Loslassen des Hotkeys während der Modellvorbereitung wartet auf deren Abschluss. Ein normaler Aufnahmestopp löst dadurch keinen künstlichen Fehler „Erkennung beschäftigt“ mehr aus. Expliziter Abbruch bleibt möglich und gibt das Modell erst nach abgeschlossener Bereinigung frei.
- Die Spracherkennung erhält statt des starren 30-Sekunden-Limits ein aufnahmelängenabhängiges Zeitbudget von mindestens fünf und höchstens fünfzehn Minuten.
- Der Verlauf speichert auch das fertig überarbeitete Ergebnis vor dem Einfügen. Fehler beim Speichern der Historie brechen das Diktat nicht mehr ab.
- Bei einem Einfügungsfehler bleiben verfügbare Texte zur ausdrücklichen Wiederherstellung und zum Kopieren erhalten.
- Fehleranzeigen unterscheiden die Verarbeitungsstufen; Hinweise zur Wiederherstellung bleiben sichtbar, statt durch ältere Ausblendtimer vorzeitig zu verschwinden.

## Verifikation und Grenzen

- Regressionstests decken Audiopuffer, Verlaufsfehler, Wiederherstellung, Zeitbudgets und das Loslassen während der Modellvorbereitung ab.
- Der Nutzer hat die Diktatfunktion des lokal signierten Reparaturstands bestätigt. Dieser installierte Stand trägt noch die bisherige Versionsnummer; Build 19 bezeichnet die hier versionierte Quellcodeänderung.
- Diese Patch-Dokumentation veröffentlicht kein signiertes Installationspaket. Ein Release-Artefakt benötigt weiterhin die dokumentierten Signing- und Installationsprüfungen.
