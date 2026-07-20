# Reproduzierbares ASR-Auswahlgate

## Zweck

`asr-benchmark` ist ein isoliertes Developer-Werkzeug für die zwei in der freigegebenen Testspezifikation definierten Auswahlgates. Es lädt keine Modelle, lädt keine Audiodaten und öffnet keine Netzwerkverbindung. Die Produktions-App hängt nicht von `ASRBenchmarkCore` oder `ASRBenchmarkCLI` ab.

Die Infrastruktur trennt drei Dinge bewusst:

1. ein versioniertes Korpus- und Provenienzmanifest;
2. rohe, lokal erzeugte Messbeobachtungen mit reproduzierbarem Ablaufplan;
3. einen inhaltsfreien Ergebnisreport und eine deterministische Gate-Entscheidung.

Die kleinen Repository-Fixtures enthalten ausschließlich synthetischen Text und Platzhalter-Hashes. Sie beweisen Parser, Validierung, Randomisierung, Metriken, Report und fail-closed Gate-Logik. Sie sind ausdrücklich keine ASR-Qualitätsevidenz.

## Was heute ausführbar ist

```sh
swift run asr-benchmark validate \
  --contract Tests/Fixtures/ASR/synthetic-small.contract.json \
  --manifest Tests/Fixtures/ASR/synthetic-small.manifest.json \
  --evidence Tests/Fixtures/ASR/synthetic-small.evidence.json

swift run asr-benchmark report \
  --contract Tests/Fixtures/ASR/synthetic-small.contract.json \
  --manifest Tests/Fixtures/ASR/synthetic-small.manifest.json \
  --evidence Tests/Fixtures/ASR/synthetic-small.evidence.json \
  --output /tmp/wf-asr-smoke-report.json

swift run asr-benchmark evaluate \
  --gate asr-a \
  --report /tmp/wf-asr-smoke-report.json \
  --output /tmp/wf-asr-smoke-evaluation.json
```

Die letzte Datei muss `stopBeforeLocalAlpha: true` und für beide Kandidaten `status: ineligible` enthalten. Gründe sind unter anderem das synthetische Profil, nur zwei Performance-Clips je Kandidat, ein Stille-Clip und nicht bereitgestellte Audioartefakte.

## Verbindlicher `WF-ASR-1`-Vertrag

[`Tests/Fixtures/ASR/wf-asr-1.contract.json`](../../../Tests/Fixtures/ASR/wf-asr-1.contract.json) ist die maschinenlesbare kanonische Definition:

- 120 Sprachclips, 60 Deutsch und 60 Englisch;
- pro Sprache je zehn Clips in sechs Strata: ruhige Standardsprache, Raumgeräusche, Akzente, Eigennamen/Fachbegriffe, Listen und Selbstkorrektur;
- 20 Stille-/Nichtsprach-Clips;
- Sprachclipdauer 2 bis 30 Sekunden;
- 60 Performance-Clips von 5 bis 8 Sekunden, 30 je Sprache;
- fünf nicht gewertete Warm-ups und zehn frische Cold Starts je Kandidat;
- ausschließlich synthetische, öffentlich lizenzierte oder ausdrücklich eingewilligte Quellen.

Ein Release-Vertrag, der auch nur einen dieser Werte verändert, wird mit `release_contract_not_canonical_wf_asr_1` abgelehnt. Schwellen können dadurch nicht still abgesenkt werden.

Jeder Manifestclip benötigt eine stabile ID, einen relativen Assetpfad, SHA-256, Dauer, Stratum, Qualitätsband, Goldtext, substanzielle Span-Annotationen und eine nachvollziehbare Provenienz. Öffentliche Quellen brauchen Lizenz plus Attribution; eingewilligte Quellen eine nicht-sensitive Consent-Record-ID; synthetische Quellen Generator plus Version. Absolute Pfade, `..`, Backslashes, doppelte IDs und doppelte Assetpfade werden abgelehnt.

Mit `--asset-root` liest die CLI jedes Audioartefakt und prüft den deklarierten SHA-256. Ohne diese reale Prüfung kann `corpusAssetsVerified` niemals `true` werden.

## Kandidaten- und Binary-Provenienz

Jeder Kandidat dokumentiert separat:

- Runtime: Name, exakte Version, Revision, primäre Repository-URL, SPDX-Lizenz, Attribution und gehashte Binärartefakte;
- Modell: exakter Modellname, Revision, Lizenz, Attribution und alle gehashten Modellartefakte;
- Adapter: Version/Revision und Hash des tatsächlich ausgeführten Benchmark-Adapters;
- Toolchain: macOS, Xcode, Swift, `release`, Hardwareklasse und RAM, aber keine Seriennummer oder Geräte-ID;
- identische Audio-Vorverarbeitung: Sample Rate, Kanäle, Sampleformat, Normalizer, Sprachmodus und Context-Hint-Policy.

Der App-Pfad bietet FluidAudio `0.15.5` mit dem gepinnten Parakeet-Modell sowie Argmax OSS / WhisperKit `1.0.0` mit gepinntem Whisper Large v3 und Large v3 Turbo. Ein echter Report muss die tatsächlich ausgewählte Runtime-, Modell- und Adapterrevision enthalten.

Der Produktionsadapter für Argmax `argmax-oss-swift` `1.0.0` ist vorhanden und die lokalen Modellartefakte sind vollständig gepinnt. Die bestehende Repository-Fixture bleibt dennoch nur `schema-placeholder`: Sie enthält keine echten Audio- oder Laufzeitevidenzen und kann das ASR-A-Gate nicht bestehen.

## Randomisierte gleiche Bedingungen

`RunScheduler` verwendet `splitmix64-fisher-yates-v1`. Kandidaten-IDs und Clip-IDs werden vor der Randomisierung sortiert, damit Eingabereihenfolge das Ergebnis nicht beeinflusst. Der Zeitplan enthält:

- dieselbe vollständige Clipmenge exakt einmal je Kandidat;
- die vertragliche Anzahl Warm-ups je Kandidat;
- eine kandidatengemischte, deterministisch randomisierte Reihenfolge;
- den Seed und jeden `(ordinal, candidateID, clipID, phase)`-Eintrag im Evidenz-JSON.

Die CLI rekonstruiert den gesamten Plan aus Manifest, Kandidaten und Seed. Schon eine geänderte Ordinalzahl, Clip-ID oder Reihenfolge erzeugt `schedule_not_reproducible`.

Für den späteren Lauf kann vor der Messung ein unveränderlicher Plan erzeugt werden:

```sh
swift run -c release asr-benchmark validate \
  --contract Tests/Fixtures/ASR/wf-asr-1.contract.json \
  --manifest /absolute/path/to/wf-asr-1.manifest.json \
  --asset-root /absolute/path/to/wf-asr-1-assets \
  --schedule-output /absolute/path/to/asr-a.schedule.json \
  --candidate fluid-audio \
  --candidate argmax \
  --seed 20260716
```

Der Seed wird danach nicht mehr verändert. Beide Runner müssen exakt diesen Plan, dieselbe Vorverarbeitung, denselben Sprachmodus und dieselbe Hint-Policy verwenden.

## Metriken

- WER nutzt Levenshtein auf Unicode-normalisierten, kleingeschriebenen Wortfolgen. Interpunktion und mehrfacher Whitespace werden zu Wortgrenzen; Umlaute und `ß` bleiben semantisch unterscheidbar.
- CER verwendet dieselbe Normalisierung auf Zeichenebene.
- Macro-WER ist der arithmetische Mittelwert der Clip-WER, getrennt nach Sprache und `clean`/`noisyMixed`.
- Severe omissions sind die Vereinigung aus automatisch vollständig fehlenden annotierten Spans und expliziten, manuell geprüften semantischen Widerspruchs-Span-IDs. Die automatische Prüfung behauptet keine semantische Interpretation.
- Eine Silence hallucination zählt nur, wenn aus einem Stilleclip tatsächlich nichtleerer Text als bestätigte Zielmutation eingefügt wurde.
- p50 und p95 verwenden die dokumentierte Nearest-Rank-Definition; zusätzlich wird das Maximum ausgegeben.
- ASR-Latenz, End-to-insert und Time-to-safe-fallback bleiben getrennt. Ein Fallback zählt nie als End-to-insert-Erfolg.
- Warmes und kaltes Peak-RSS werden in Bytes gespeichert. Die Gate-Grenzen verwenden dezimale GB: `4_500_000_000` und `6_000_000_000` Bytes.
- Der schlechteste beobachtete Thermal State und die Anzahl ausgehender Runtime-Verbindungen stehen im Ergebnis.

Rohe Evidenz enthält notwendigerweise Gold- und Hypothesentext. Der generierte Report enthält diese Inhalte nicht, sondern nur Provenienz und aggregierte Messwerte.

## Gate ASR-A

Ein Kandidat besteht nur mit vollständiger Release-Evidenz:

- clean Macro-WER je Sprache höchstens 15 %;
- noisy/mixed Macro-WER je Sprache höchstens 22 %;
- null severe omissions;
- null Einfügungs-Halluzinationen aus exakt 20 Stilleclips;
- ASR-p50 höchstens 1,5 Sekunden, ASR-p95 höchstens 3,25 Sekunden aus exakt 60 Performance-Läufen;
- warmes Peak-RSS höchstens 4,5 GB, kaltes Peak-RSS höchstens 6,0 GB;
- zehn Cold Starts;
- null Runtime-Netzwerkverbindungen;
- vollständige Runtime-, Modell-, Adapter-, Lizenz-, Attribution-, Toolchain- und Hash-Provenienz.

FluidAudio wird bei zwei bestandenen Kandidaten nur gewählt, wenn seine Gesamt-Macro-WER in Deutsch und Englisch jeweils höchstens einen Prozentpunkt schlechter und sein ASR-p50 sowie Peak-RSS jeweils höchstens 20 % schlechter als Argmax sind. Sonst gewinnt Argmax. Ein nicht gemessener Kandidat ist nicht dasselbe wie ein gemessener Verlierer: solange FluidAudio oder Argmax fehlt, wird niemand ausgewählt.

## Gate ASR-B

ASR-B benötigt die gespeicherte, bestandene ASR-A-Auswertung und neue `fullPipeline`-Evidenz für deren Gewinner:

- End-to-insert-p50 höchstens 2,0 Sekunden;
- End-to-insert-p95 höchstens 4,0 Sekunden;
- exakt 60 von 60 bestätigte Einfügungen im nativen Harness-Ziel;
- unveränderte WER-, Omission- und Silence-Gates;
- unveränderte RSS-Grenzen;
- null ausgehende Verbindungen für die vollständige Local-only-Pipeline.

```sh
swift run -c release asr-benchmark report \
  --contract Tests/Fixtures/ASR/wf-asr-1.contract.json \
  --manifest /absolute/path/to/wf-asr-1.manifest.json \
  --asset-root /absolute/path/to/wf-asr-1-assets \
  --evidence /absolute/path/to/asr-b-full-pipeline.evidence.json \
  --output /absolute/path/to/asr-b.report.json

swift run -c release asr-benchmark evaluate \
  --gate asr-b \
  --report /absolute/path/to/asr-b.report.json \
  --asr-a /absolute/path/to/asr-a.evaluation.json \
  --output /absolute/path/to/asr-b.evaluation.json
```

## Noch externe Blocker

Folgende Evidenz wird absichtlich nicht erfunden:

- 120 rechtmäßig verwendbare Sprachclips, 20 Stilleclips und ihre echten SHA-256-Werte;
- ein bereitgestelltes, lokal geprüftes Parakeet-Modell für den Vergleichslauf;
- echte Ausführungsevidenz für die bereits implementierten und gepinnten WhisperKit-Kandidaten;
- Release-Messungen auf dem vorgesehenen M5/16-GB-Gerät;
- zehn wirklich frische Starts je Kandidat, Peak-RSS und Thermal State aus dem Runner;
- dynamisch beobachtete Null-Netzwerk-Evidenz;
- ASR-B-Messungen gegen das bestätigbar einfügungsfähige native Ziel.

Bis diese Artefakte bewusst bereitgestellt wurden, bleibt das reale Auswahlgate rot. Die CLI verändert keine Schwelle und lädt nichts im Hintergrund nach.
