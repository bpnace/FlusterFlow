# ADR-0005: Lokales Qwen3-ASR über MLX

## Status

Akzeptiert für den privaten MVP.

## Entscheidung

FlusterFlow ergänzt `mlx-community/Qwen3-ASR-0.6B-8bit` als viertes auswählbares lokales ASR. Die 0,6B-8-bit-Variante ist auf dem Zielgerät mit Apple Silicon und 16 GB Arbeitsspeicher der bewusst gewählte Kompromiss aus Modellqualität, ungefähr 1,01 GB Speicherbedarf und lokaler Laufzeit. Sie ersetzt weder Parakeet noch Whisper; alle Backends bleiben für reale Vergleichstests auswählbar.

Die offizielle Qwen-Runtime ist nicht nativ in Swift verfügbar. FlusterFlow verwendet deshalb das MIT-lizenzierte `mlx-audio-swift` exakt in Version `0.1.3` und Revision `d302a5c6080d2bb97bae38c7418f82abb76013b6`. Der direkt verwendete MLX-Typ ist zusätzlich über `mlx-swift` `0.31.4` und Revision `dc43e62d7055353c7f99fa071a4e71d29dfddc44` gepinnt. Das Modell wird ausschließlich über `Qwen3ASRModel.fromModelDirectory` aus einem zuvor vollständig validierten lokalen Ordner geladen.

Das konvertierte Modell liefert keinen `tokenizer.json`. Provisioning erzeugt diese Datei deterministisch aus drei gepinnten Quelldateien und nimmt sie vor Installation in dieselbe Größen-, SHA-256- und Tree-Hash-Prüfung auf. Der Runtime-Loader findet dadurch einen vollständigen unveränderlichen Ordner vor und muss weder schreiben noch herunterladen.

## Konsequenzen

- Der Qwen-Download benötigt ungefähr 1,01 GB zusätzlichen Speicher.
- Der erste Modellaufbau kann länger dauern; das Modell wird erst bei tatsächlicher Auswahl lazy geladen.
- Der Xcode-Build kompiliert die Metal-Shader der gepinnten MLX-Revision in das signierbare Ressourcenbundle `mlx-swift_Cmlx.bundle`; dafür muss Apples optionale Metal-Toolchain installiert sein.
- Deutsch, Englisch und automatische Erkennung werden auf Qwens native Sprachbezeichnungen abgebildet.
- Diktat-Cancellation verwendet den Streaming-Generator, damit die laufende MLX-Aufgabe abgebrochen werden kann.
- Ein Runtime- oder Modellupdate bleibt eine explizite Supply-Chain-Änderung mit neuen Hashes, Lizenzprüfung und realem Smoke-Test.
