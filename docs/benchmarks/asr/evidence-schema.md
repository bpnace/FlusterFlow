# ASR-Evidenzschema

## Dateien

| Datei | Inhalt | Darf Nutztext enthalten? |
|---|---|---|
| `*.contract.json` | Korpus-Sollzahlen und Stichprobengröße | nein |
| `*.manifest.json` | Clip-Metadaten, Goldtext, Span-Annotationen, Hash und Provenienz | ja, nur rechtmäßig verwendbare Benchmarkdaten |
| `*.schedule.json` | Seed und randomisierte Kandidat-/Clipreihenfolge | nein |
| `*.evidence.json` | Kandidatenprovenienz und rohe Beobachtungen | ja, Gold-/Hypothesentext des Benchmarkkorpus |
| `*.report.json` | aggregierte Qualität, Laufzeit, RSS, Thermal und Netzwerkzahl | nein |
| `*.evaluation.json` | einzelne Checks und deterministische Auswahl | nein |

Alle Schemas verwenden `schemaVersion: 1`; unbekannte Versionen werden abgelehnt.

## Beobachtungsinvarianten

Eine `TrialObservation` verweist über `scheduleOrdinal` und `clipID` exakt auf einen Planeintrag. Negative oder nicht-finite Laufzeiten sind ungültig. Eine Beobachtung darf nicht gleichzeitig bestätigte Mutation und sicheren Fallback behaupten. End-to-insert ist nur bei bestätigter Mutation erlaubt; im `fullPipeline`-Profil ist es dann verpflichtend. Time-to-safe-fallback ist bei einem Fallback verpflichtend und wird getrennt aggregiert.

`reviewedSevereOmissionSpanIDs` darf ausschließlich IDs aus den `substantialSpans` des Clips enthalten. Dadurch kann eine manuelle semantische Prüfung widersprüchliche Substitutionen markieren, ohne freie Reviewertexte in das Ergebnis zu übernehmen.

## Messwerterfassung

Der isolierte Kandidatenrunner besitzt die tatsächliche Runtime und füllt pro Trial:

- finalen ASR-Hypothesentext;
- ausschließlich bei bestätigter Zielmutation den eingefügten Text;
- ASR-Latenz ab final geschlossenem Audio bis finalem lokalen Text;
- bei ASR-B End-to-insert oder Time-to-safe-fallback;
- höchsten RSS-Wert des Prozesses während des Trials;
- Thermal State;
- nach manueller Prüfung gegebenenfalls bekannte severe-omission-Span-IDs.

Cold Starts stehen separat und enthalten Model-ready-Latenz, Peak-RSS und Thermal State. Jeder Eintrag muss aus einem frischen Prozess ohne geladenes Modell stammen. Diese Prozessfrische ist eine Runner-/Testprotokollpflicht und wird nicht aus einer JSON-Zahl hergeleitet.

## Keine automatische Freigabe aus Platzhaltern

`synthetic-small.*` verwendet absichtlich `profile: syntheticSmoke`, `assetState: unprovisioned`, Debug-Toolchain und als solche benannte Schema-Platzhalter. Selbst perfekte fiktive Transkripte können damit weder ASR-A noch ASR-B bestehen.
