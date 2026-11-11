# FlusterFlow 0.5.0 (Build 21)

- Die Flow Bar zeigt den tatsächlichen Mikrofonpegel. Bei fehlendem oder verlorenem Signal erscheint ein rotes Ausrufezeichen in der Audiowelle.
- Whisper hält vorbereitete Modelle für das erste Diktat im Speicher. Bei längeren Aufnahmen dekodiert Whisper bereits abgeschlossene Abschnitte während der Aufnahme und verwendet passende Ergebnisse beim Stopp wieder.
- App-Updates behalten die vorhandenen Einstellungen und das persönliche Wörterbuch. Der Regressionstest vergleicht die Einstellungsdatei beim App-Austausch und beim Rollback bytegenau.

Im TextEdit-Benchmark für die Vorab-Dekodierung sank die Zeit vom simulierten Stopp bis zur bestätigten Einfügung im Median von 4,97 auf 2,65 Sekunden. Das synthetische deutsche Diktat dauerte 43 Sekunden und hatte 118 Wörter. Kein Lauf hatte Auslassungen oder Dopplungen. In zwei Gegenproben lieferten beide Verfahren auf jeweils identischem aufgenommenem Audio dieselbe Wortfolge. [Aufbau und Messwerte](benchmarks/asr/long-dictation-textedit.md)
