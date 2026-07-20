# ADR-0004: Auswählbare lokale WhisperKit-Modelle

## Status

Akzeptiert für den privaten MVP.

## Entscheidung

FlusterFlow behält Parakeet als kleinen lokalen Standard und ergänzt zwei explizit auswählbare WhisperKit-Backends:

- Whisper Large v3 `openai_whisper-large-v3-v20240930_626MB` für maximale lokale Genauigkeit;
- Whisper Large v3 Turbo `openai_whisper-large-v3-v20240930_turbo_632MB` für geringere Latenz.

Argmax OSS / WhisperKit ist exakt auf Version `1.0.0` und Git-Revision `25c62997041c134b03ca82731ce2f6fd2cae1eb9` gepinnt. Modellordner, gemeinsamer Large-v3-Tokenizer, Einzelgrößen, Datei-SHA-256 und Tree-Hashes sind in `ModelManifest.swift` gebunden.

Die Modellauswahl wird beim Start eines Diktats an dessen Session gebunden. Ein Einstellungswechsel während der Aufnahme kann damit weder Transkription noch Cancellation auf ein anderes Backend umleiten. Ein fehlendes oder beschädigtes ausgewähltes Modell führt fail-closed zu „nicht bereit“; es gibt keinen stillen Fallback auf Parakeet.

WhisperKits `download: false` reicht für vollständige Offline-Sicherheit nicht aus, weil der Upstream-Tokenizer-Loader bei einem lokalen Lesefehler ins Netz ausweichen kann. FlusterFlow validiert deshalb den gemeinsamen Tokenizer separat und erzeugt ihn direkt aus dem lokalen Ordner, bevor Core ML geladen wird. Provisioning bleibt die einzige modellbezogene Netzwerkgrenze und benötigt eine ausdrückliche Nutzeraktion.

## Konsequenzen

- Large und Turbo benötigen zusammen rund 1,27 GB zuzüglich 2,8 MB Tokenizer.
- Der erste Start jeder Variante kann wegen Core-ML-/ANE-Spezialisierung deutlich länger dauern; spätere Starts verwenden Apples lokalen Spezialisierungscache.
- Beide WhisperKit-Runtimes werden lazy geladen. Ein Qualitäts- und Latenzgewinner wird ohne den realen `WF-ASR-1`-Benchmark nicht behauptet.
- Die Lizenz des Argmax-SDKs ist MIT; für die konvertierten Modellartefakte bleibt vor jeder Weitergabe eine gesonderte Lizenzprüfung erforderlich.
