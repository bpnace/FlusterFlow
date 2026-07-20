# MVP Fixture Manifest

## Zweck und Geltungsbereich

Dieses Manifest beschreibt die deterministischen, synthetischen Testdaten für den lokalen MVP. Die Dateien sind ausführbare Verträge für Cleanup, Context Awareness, Cloud Meaning Preservation und die kontrollierten Einfügungsziele des `E-TARGET-HARNESS`.

Alle Inhalte sind künstlich erzeugt. Es gibt keine Audioaufnahmen, echten API-Schlüssel, privaten Diktate, vertraulichen Dokumente oder Gerätekennungen. E-Mail- und URL-Beispiele verwenden ausschließlich die reservierte Domain `example.com`.

Die Context-Term-Textstimuli prüfen Scoring, Hint-/Correction-Entscheidungen und die gepaarte Metrikberechnung. Sie ersetzen nicht den in der Testspezifikation geforderten realen Audio-ASR-Benchmark auf dem M5-Testgerät.

## Bestandsübersicht

| Corpus / Harness | Datei | Anzahl | Verbindlicher Inhalt |
|---|---|---:|---|
| `WF-ASR-1` | `Tests/Fixtures/ASR/wf-asr-1.contract.json` | 120 + 20 | Kanonischer Audio-Korpusvertrag; echte Audioassets werden nicht eingecheckt |
| `WF-ASR-SMOKE-1` | `Tests/Fixtures/ASR/synthetic-small.*.json` | 4 + 1 | Text-only Schema-, Scheduler-, Metrik- und Gate-Smoke; nie Release-Evidenz |
| `WF-CLEAN-1-DE` | `Tests/Fixtures/Cleanup/wf-clean-1-de.json` | 50 | Deutsche Cleanup-Fälle |
| `WF-CLEAN-1-EN` | `Tests/Fixtures/Cleanup/wf-clean-1-en.json` | 50 | Englische Cleanup-Fälle |
| `WF-CTX-TERMS-1` | `Tests/Fixtures/Context/wf-ctx-terms-1.json` | 50 | 40 Metrik-Paare und 10 Ambiguitäts-Negativfälle |
| `WF-CLOUD-1` | `Tests/Fixtures/Cloud/wf-cloud-1.json` | 36 | 14 High-risk-, 10 Benign- und 12 Consent-/Fehlerfälle |
| `E-TARGET-HARNESS` | `TestSupport/TextTargetHarness/scenarios.json` | 28 | Native-, Web-, Secure-, Race-, Bounding- und Clipboard-Szenarien |

Alle JSON-Dateien verwenden `schemaVersion: 1`. IDs sind innerhalb jeder Datei eindeutig und stabil. Testcode darf IDs in Fehlermeldungen und Reports verwenden, darf aber keine Fixture-Inhalte loggen.

## `WF-ASR-1`

Der kanonische Vertrag legt 120 Sprachclips, 20 Stilleclips, die DE-/EN- und Stratum-Verteilung, Dauergrenzen, 60 Performance-Clips, fünf Warm-ups sowie zehn Cold Starts je Kandidat fest. Ein später extern bereitgestelltes Manifest muss für jeden Clip relativen Pfad, SHA-256, Goldtext, substanzielle Span-Annotationen und rechtmäßige Provenienz enthalten. Mit `--asset-root` prüft die CLI die echten Bytes. Ohne vollständige Assets, beide Kandidaten und M5-Messungen bleibt das Release-Gate ineligible.

Die synthetischen Small-Fixtures enthalten kein Audio. Sie beweisen nur, dass `validate`, `report` und `evaluate` ausführbar und fail-closed sind. Details und spätere M5-Kommandos stehen in `docs/benchmarks/asr/README.md`.

## `WF-CLEAN-1`

Jede Cleanup-Fixture enthält:

- `id`: stabile ID;
- `targetKind`: `email`, `chat`, `document` oder `unknown`;
- `raw`: synthetischer Eingabetext;
- `context`: expliziter lokaler Kontextzustand;
- `expected`: deterministischer Solltext;
- `mustPreserveSpans`: substanzielle, im Ergebnis zu erhaltende Anker;
- `ruleTrace`: geordnete IDs der erwarteten Transformationen.

Die beiden Sprachdateien enthalten jeweils exakt 50 Fälle. Abgedeckt sind Interpunktion, Großschreibung, Whitespace, sichere und unsichere Füllwörter, gesprochene Listen, explizite Selbstkorrektur, E-Mail-/Chat-/Dokumentton, Unicode, Umlaute, `ß`, Apostrophe, Bindestriche, Zahlen, Beträge, Datumswerte, Negationen, URLs, E-Mails, Mentions, Hashtags, Identifier, Zitate und No-op-Fälle.

Fixture-Assertions:

1. Das Cleanup-Ergebnis entspricht `expected` exakt.
2. Jeder Eintrag aus `mustPreserveSpans` ist semantisch im Ergebnis vorhanden; für diese synthetischen Fälle kann zunächst exakte Unicode-Substring-Prüfung verwendet werden.
3. Die öffentliche Rule-Trace entspricht `ruleTrace`, enthält aber nie `raw`, `expected` oder Context-Inhalt.
4. Für Regeln, die als idempotent markiert werden, gilt `clean(expected) == expected`.
5. Ein interner Fehler liefert `raw` als flüchtigen Fallback und persistiert keinen Inhalt.

## `WF-CTX-TERMS-1`

### Metrikgruppe

Die 40 Einträge mit `evaluationGroup: "metric"` sind gleichmäßig verteilt:

- 20 Deutsch;
- 20 Englisch;
- pro Sprache 5 bereits korrekte Context-off-Baselines und 15 synthetische Fehlvarianten;
- 40 erwartete korrekte Context-on-Ausgaben.

Jeder Metrikfall enthält:

- `audioAsset: null` als explizite Repository-Grenze;
- `textStimulus` als synthetische Stellvertretung für den gesprochenen Goldtext;
- `boundedContext` mit genau einem relevanten Zielterm;
- `gold.targetTerm`, zulässige Varianten und Nicht-Term-Tokens;
- gepaarte `contextOff`- und `contextOn`-Erwartungen;
- `expectedDecision` als `retain` oder `correctUnique`.

Aus den statischen Kandidaten ergibt sich absichtlich folgende Harness-Selbstprüfung:

- Context-off Named-term accuracy: `10 / 40 = 25 %`;
- Context-on Named-term accuracy: `40 / 40 = 100 %`;
- absolute Verbesserung: `75 Prozentpunkte`;
- erwartete Non-term-Regression: `0 Prozentpunkte`;
- Severe omissions: `0`.

Diese Zahlen validieren die Metrik- und Entscheidungspipeline. Die Release-Schwellen werden zusätzlich mit echten, rechtmäßig verwendbaren Audiofixtures gemessen.

### Ambiguitätsgruppe

Die 10 Einträge mit `evaluationGroup: "ambiguityNegative"` enthalten jeweils zwei ähnlich geschriebene beziehungsweise ähnlich klingende Kontextkandidaten. `expectedDecision` ist immer `unchangedAmbiguous`; Context-on muss exakt den Context-off-Text erhalten und darf keinen Kandidaten erzwingen.

Context Fixture-Assertions:

1. `audioAsset` bleibt in allen Repository-Fixtures `null`.
2. `boundedContext` überschreitet niemals die Produktgrenze von 1.500 Unicode-Zeichen.
3. Metrikfälle besitzen genau einen `gold.targetTerm`; Ambiguitätsfälle besitzen keinen Goldterm und mindestens zwei `ambiguityCandidates`.
4. Nicht-Term-Tokens bleiben zwischen den gepaarten Kandidaten unverändert.
5. Der Term-Extractor liefert höchstens 32 einzigartige, nicht-sensitive Kandidaten.

## `WF-CLOUD-1`

Die Cloud-Fixtures modellieren ausschließlich text-only BYOK-Verhalten. `request` enthält nur:

- `localCandidate`;
- `targetKind`;
- `language`;
- optionalen, bereits begrenzten `context`.

Es gibt typseitig und in den JSON-Fixtures kein Audiofeld und kein Rohtranskriptfeld. `requestGate` enthält nur boolesche Zustände; kein Fixture enthält einen Schlüssel oder Authorization-Header.

### High-risk: 14 Fälle

Je ein deutscher und englischer Fall deckt jede Pflichtklasse ab:

- Negation geändert;
- Zahl geändert;
- Betrag geändert;
- Datum geändert;
- erkannter Name beziehungsweise Context-Term geändert;
- substanzielle Klausel entfernt;
- neue Entität erfunden.

Alle 14 Fälle erwarten `rejectCloudUseLocal` und exakt den unveränderten `request.localCandidate` als Ausgabe.

### Benign: 10 Fälle

Je fünf deutsche und englische Fälle erlauben begrenzte Interpunktions-, Whitespace-, Listen-, Satzstellungs- oder E-Mail-Formatänderungen. Geschützte Anker bleiben erhalten, und die erwartete Entscheidung ist `acceptCloud`.

### Consent, Transport und Schema: 12 Fälle

Abgedeckt sind fehlender Key, deaktivierte Cloud, Context-Consent aus/an, Timeout, HTTP 401/429/500, malformed JSON, leere Antwort, DNS- und TLS-Fehler. Fehlende Freigaben erzeugen keinen Request; alle Providerfehler liefern den lokalen Kandidaten.

Cloud Fixture-Assertions:

1. `expected.requestCount` wird exakt eingehalten.
2. Context wird genau dann serialisiert, wenn `contextToCloudEnabled` wahr ist.
3. Das Adapter-Request-Schema besitzt keine Felder für Audio, Rohtranskript, Bundle-ID, Fenstertitel, Pfad oder Gerätekennung.
4. Jede High-risk-Fixture wird verworfen; jede Benign-Fixture wird innerhalb der festgelegten Token-/Längenratio akzeptiert.
5. Providerfehler und Providerkörper werden nicht als freie Strings in Logs oder Diagnoseexporte übernommen.

## `E-TARGET-HARNESS`

Die 28 Szenarien definieren kontrollierte Zielzustände und erwartete Resultate für:

- `NSTextField`, `NSTextView` und `NSSecureTextField`;
- `WKWebView` mit Text-Input, Textarea, Contenteditable und Passwortfeld;
- Fokus-, Selection-, Target-Lifecycle- und Session-ID-Races;
- verweigerte Accessibility und fail-closed unbekannte Sensitivität;
- Context-Master-Off und 1.500-Zeichen-Bounding am Anfang, in der Mitte, am Ende und um eine Auswahl;
- strict Local-only ohne General-Pasteboard-Schreibzugriff;
- optionalen Compatibility-Paste mit bestätigter Mutation, vollständigem Roundtrip, Fremdänderung und Timeout;
- direkte, bestätigte Unicode-CGEvent-Einfügung für webbasierte Textfelder;
- vollständig validierte AX-Value-Ersetzung sowie Ablehnung bei Snapshot- oder Klassenverletzung.

Zulässige Ergebniswerte sind `directAX`, `validatedAXValue`, `guardedCGEvent`, `guardedPaste`, `safeFallback`, `insertionDenied`, `ignoredStaleSession` und `contextOnly`. `guardedCGEvent` ist für fokussierte Textfelder innerhalb eines `AXWebArea` produktiv aktiv; `guardedPaste` bleibt deaktiviert. Nur Ergebnisse mit `confirmedMutation: true` dürfen als erfolgreiche Einfügung gezählt werden. `safeFallback` darf nie in die End-to-insert-Latenz einfließen.

Das ausführbare AppKit-/WKWebView-Harness, der JSON-Ergebnisvertrag und die separat manuell auszuführenden Safari-/Chromium-/Electron-Szenarien liegen vollständig unter `TestSupport/TextTargetHarness/`. Ausführung und TCC-Grenzen sind in `docs/verification-harnesses.md` beschrieben.

Generierte Bounding-Szenarien verwenden `generatedText.unit` und `generatedText.count`, damit große Eingaben klein, deterministisch und ohne eingebettete Inhalte bleiben.

## Validierung

JSON-Syntax für alle Fixture-Dateien:

```sh
for file in Tests/Fixtures/ASR/*.json Tests/Fixtures/Cleanup/wf-clean-1-de.json Tests/Fixtures/Cleanup/wf-clean-1-en.json Tests/Fixtures/Context/wf-ctx-terms-1.json Tests/Fixtures/Cloud/wf-cloud-1.json TestSupport/TextTargetHarness/scenarios.json; do jq -e . "$file" >/dev/null; done
```

Verbindliche Datenschutzprüfungen:

```sh
jq -e '([.fixtures[].id] | length) == ([.fixtures[].id] | unique | length) and ([.fixtures[] | select(.audioAsset != null)] | length) == 0' Tests/Fixtures/Context/wf-ctx-terms-1.json
jq -e '([.fixtures[].id] | length) == ([.fixtures[].id] | unique | length) and ([.fixtures[] | select(.request | has("audio") or has("rawTranscript"))] | length) == 0' Tests/Fixtures/Cloud/wf-cloud-1.json
jq -e '([.scenarios[].id] | length) == ([.scenarios[].id] | unique | length)' TestSupport/TextTargetHarness/scenarios.json
swift run asr-benchmark validate --contract Tests/Fixtures/ASR/synthetic-small.contract.json --manifest Tests/Fixtures/ASR/synthetic-small.manifest.json --evidence Tests/Fixtures/ASR/synthetic-small.evidence.json
```

Die CI soll zusätzlich alle deklarierten Sollzahlen aus der Bestandsübersicht prüfen und bei unbekannten `schemaVersion`-Werten fail-closed abbrechen.
