# Lokale ASR-Modell-Supply-Chain

## Gepinnter Stand: Parakeet

| Bestandteil | Pin |
| --- | --- |
| Runtime | FluidAudio `0.15.5` |
| Runtime-Revision | `19600a485baa4998812e4654b70d2bab8f2c9949` |
| Modell-Repository | `FluidInference/parakeet-tdt-0.6b-v3-coreml` |
| Modell-Revision | `aed02740059203c4a87495924f685de3722ae9ce` |
| FluidAudio-Cacheordner | `parakeet-tdt-0.6b-v3` |
| Präzision | `int8` |
| Artefakte | 21 Dateien |
| Gesamtgröße | `483105645` Bytes |
| Deterministischer Tree-SHA-256 | `5295efba3d7f2fc7ba2ffd883ca0c3326eef33425bf6e029a69dd8ac0c58a79d` |

Die kanonische, maschinenlesbare Liste aller relativen Pfade, Einzelgrößen und SHA-256-Werte liegt in `WhisperFlow/Integrations/ModelProvisioning/ModelManifest.swift`. Eine zweite manuell gepflegte Hashliste in der Dokumentation wird absichtlich vermieden.

## Gepinnter Stand: Qwen3-ASR

| Bestandteil | Pin |
| --- | --- |
| Runtime | MLXAudioSTT / `mlx-audio-swift` `0.1.3` |
| Runtime-Revision | `d302a5c6080d2bb97bae38c7418f82abb76013b6` |
| Direkte MLX-Version | `mlx-swift` `0.31.4` |
| Direkte MLX-Revision | `dc43e62d7055353c7f99fa071a4e71d29dfddc44` |
| Modell-Repository | `mlx-community/Qwen3-ASR-0.6B-8bit` |
| Modell-Revision | `89e96d92ba34aca20b3e29fb10cc284097d1219f` |
| Präzision | `8-bit MLX` |
| Remote-Artefakte | 9 Dateien |
| Lokal abgeleitetes Artefakt | `tokenizer.json` |
| Gesamtgröße | `1015531573` Bytes |
| Deterministischer Tree-SHA-256 | `b6695aef111b3eb009887f39d4c373dd147b7799b01d27e9051106faffc911a3` |

Die MLX-Konvertierung enthält keinen fertigen Fast-Tokenizer. Provisioning erzeugt deshalb `tokenizer.json` deterministisch aus den ebenfalls gepinnten Dateien `vocab.json`, `merges.txt` und `tokenizer_config.json`. Erst danach prüft derselbe strikte Store auch dieses abgeleitete Artefakt gegen Größe, Einzelhash und Tree-Hash. Der Runtime-Pfad verwendet ausschließlich `Qwen3ASRModel.fromModelDirectory`; der netzwerkfähige `fromPretrained`-Pfad ist nicht Teil der App. Der Xcode-Build kompiliert zusätzlich `default.metallib` ausschließlich aus der oben gepinnten `mlx-swift`-Revision und bettet sie im signierbaren Paket-Ressourcenbundle `mlx-swift_Cmlx.bundle` ein.

## Gepinnter Stand: WhisperKit

| Bestandteil | Pin |
| --- | --- |
| Runtime | Argmax OSS / WhisperKit `1.0.0` |
| Runtime-Revision | `25c62997041c134b03ca82731ce2f6fd2cae1eb9` |
| Modell-Repository | `argmaxinc/whisperkit-coreml` |
| Modell-Revision | `97a5bf9bbc74c7d9c12c755d04dea59e672e3808` |
| Large-Ordner | `openai_whisper-large-v3-v20240930_626MB` |
| Large-Artefakte / Größe | 17 Dateien / `626718238` Bytes |
| Large Tree-SHA-256 | `13d1ce901ca6bb5084a2a48db1d1a0c4fbd13687ce78f845fa89c8016e677287` |
| Turbo-Ordner | `openai_whisper-large-v3-v20240930_turbo_632MB` |
| Turbo-Artefakte / Größe | 22 Dateien / `645668913` Bytes |
| Turbo Tree-SHA-256 | `20106c1584f2c63c6ee8f51fabd562fe85b29e2116ae6facbf7ca826c1f21c05` |
| Tokenizer-Repository | `openai/whisper-large-v3` |
| Tokenizer-Revision | `06f233fe06e710322aca913c1bc4249a0d71fce1` |
| Tokenizer-Artefakte / Größe | 3 Dateien / `2764732` Bytes |
| Tokenizer Tree-SHA-256 | `6e9e4fdf297e47536de698f87dd7e037561212cdce927e37826f5064c9e45052` |

Large und Turbo teilen sich ausschließlich den separat geprüften Tokenizer. WhisperKit wird mit lokalem Modellpfad, `download: false` und `load: false` erzeugt. Danach baut FlusterFlow den Tokenizer direkt aus dem validierten lokalen Ordner und lädt erst dann die Core-ML-Modelle. Dadurch wird WhisperKits eigener netzwerkfähiger Tokenizer-Fallback nicht erreicht.

## Bezugsweg und URL-Grenze

Die gepinnten Hugging-Face-Revisionen bieten kein einzelnes, stabiles Archiv für diese Installationsformate. Provisioning lädt deshalb ausschließlich die im gewählten Manifest erlaubten Artefakte über URLs dieser Schemata:

```text
https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve/aed02740059203c4a87495924f685de3722ae9ce/<relativer-pfad>
https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-8bit/resolve/89e96d92ba34aca20b3e29fb10cc284097d1219f/<relativer-pfad>
https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/97a5bf9bbc74c7d9c12c755d04dea59e672e3808/<modellordner>/<relativer-pfad>
https://huggingface.co/openai/whisper-large-v3/resolve/06f233fe06e710322aca913c1bc4249a0d71fce1/<tokenizer-datei>
```

Große LFS-Dateien werden von Hugging Face auf zeitlich begrenzte CDN-URLs umgeleitet. Deren Host und Signatur sind kein stabiler Pin. Der Produktions-Transport akzeptiert deshalb nur einen initialen HTTPS-Request an `huggingface.co`, ausschließlich HTTPS-Weiterleitungen und einen finalen HTTPS-Response. Die eigentliche Inhaltsvertrauensgrenze bilden die im Quellcode gepinnten Einzelgrößen und SHA-256-Werte sowie der daraus berechnete Tree-Hash.

Es gibt deshalb bewusst keine behauptete einzelne „Manifest-Download-URL“ und keine Host-Pin-Liste für wechselnde signierte CDN-Endpunkte.

## Installationsvertrag

1. Der normale Diktatpfad validiert ausschließlich lokale Dateien. FluidAudio läuft im Offline-Modus; MLXAudioSTT und WhisperKit erhalten nur validierte lokale Modell- und Tokenizerordner und keinen Runtime-Downloadpfad.
2. Lokaler Import und Download laufen außerhalb des Runtime-Objektgraphen über `ModelProvisioningService`.
3. Jedes Modell und der gemeinsame Whisper-Tokenizer besitzen einen eigenen, im Manifest festgelegten Zielordner. Ein abweichender letzter Pfadbestandteil wird vor Provisioning abgelehnt.
4. Download benötigt eine einmalige, explizit erzeugte Nutzerautorisierung. Import benötigt einen bewusst ausgewählten lokalen Ordner.
5. Alle Dateien landen zuerst in einem Geschwister-Stagingordner mit Modus `0700`; Dateien und Unterordner erhalten `0600` beziehungsweise `0700`.
6. Vor Installation werden Artefaktmenge, Einzelgröße, Einzelhash, Gesamtgröße und Tree-Hash geprüft. Zusätzliche Dateien und Symlinks werden abgelehnt.
7. Erst ein vollständig valides Staging wird auf demselben Volume per Rename installiert. Eine vorhandene Installation wird zuvor in ein Geschwister-Backup verschoben und bei einem Fehler wiederhergestellt.
8. Staging- und Backupnamen sind pro Modell namespaced. Ein Recovery-Lauf darf deshalb niemals partielle Installationen eines anderen Modells entfernen.

## Update-Verfahren

Ein Runtime- oder Modellupdate ist eine Supply-Chain-Änderung und darf nicht nur durch Austausch einer URL erfolgen:

1. Neue Runtime-Version und exakte Git-Revision prüfen und gemeinsam pinnen.
2. Modell-Revision und Model Card prüfen; Lizenz und Attribution erneut bewerten.
3. Alle Artefakte in einer isolierten Arbeitskopie erfassen, Größe und SHA-256 je Datei neu berechnen und den deterministischen Tree-Hash aktualisieren.
4. Manifesttests, vollständige Swift-Tests und den Offline-/Architekturcheck ausführen.
5. `THIRD_PARTY_NOTICES.md`, diese Supply-Chain-Notiz und die betroffene ADR im selben Review aktualisieren.

Ein echter Modelldownload gehört nicht zur regulären automatisierten Testsuite. Tests verwenden kleine Fake-Artefakte und Fake-Transporte für Hashfehler, Abbruch, Rollback und Offline-Bereitschaft. Separat aktivierte Smoke-Tests können bereits installierte Qwen-, Large- und Turbo-Verzeichnisse vollständig hashen und ihre lokalen Runtimes laden.
