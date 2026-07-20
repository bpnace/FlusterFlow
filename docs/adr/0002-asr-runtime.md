# ADR-0002: Gepinnte lokale ASR-Runtime und isoliertes Modell-Provisioning

- Status: Accepted
- Datum: 2026-07-16
- Entscheider: freigegebener Ralplan-Konsens

## Kontext

FlusterFlow benötigt ein lokal nutzbares ASR, das nach einmaliger Modellbereitstellung ohne Netzwerk, Konto oder laufende Kosten arbeitet. Gleichzeitig ist ein Modell von rund 483 MB zu groß für das Quellrepository und soll bei Bedarf importiert oder nach einer ausdrücklichen Nutzeraktion geladen werden können. Ein Downloadpfad darf die lokale Diktatpipeline nicht in eine implizit netzwerkfähige Pipeline verwandeln.

## Entscheidung

1. FluidAudio wird exakt auf Version `0.15.5` und Git-Revision `19600a485baa4998812e4654b70d2bab8f2c9949` gepinnt.
2. Das lokale Modell ist `FluidInference/parakeet-tdt-0.6b-v3-coreml`, Revision `aed02740059203c4a87495924f685de3722ae9ce`, Präzision `int8`.
3. `ModelManifest.parakeetV3Int8` ist die kanonische Allowlist aus 21 relativen Dateien mit exakter Einzelgröße und SHA-256. Zusätzlich bindet es die Gesamtgröße `483105645` Bytes und den Tree-SHA-256 `5295efba3d7f2fc7ba2ffd883ca0c3326eef33425bf6e029a69dd8ac0c58a79d`.
4. Das Manifest pinnt außerdem FluidAudios lokalen Cacheordner `parakeet-tdt-0.6b-v3`. Settings bildet das Installationsziel über `installationDirectory(in:)`; Provisioning lehnt einen abweichenden letzten Pfadbestandteil ab.
5. `LocalModelStore` prüft ausschließlich das lokale Dateisystem. Fehlende, zusätzliche, unlesbare oder symbolisch verlinkte Dateien sowie jede Größen- oder Hashabweichung führen fail-closed zu einem strukturierten Status.
6. `OfflineFluidAudioRuntime` setzt `ModelHub.offlineMode = true`, bevor FluidAudio geladen oder verwendet wird. Der lokale Dictation- und Runtime-Objektgraph kennt weder Provisioning-Request noch Provisioning-Transport.
7. `ModelProvisioningService` ist die einzige Managementgrenze. Settings kann Status abfragen, einen lokalen Ordner importieren, eine einmalige Nutzerautorisierung für Download erzeugen und unterbrochenes Provisioning bereinigen.
8. `HTTPSModelProvisioningTransport` ist das einzige netzwerkfähige Modellmodul. Es akzeptiert initial nur HTTPS auf `huggingface.co`, lehnt jede HTTPS-Downgrade-Weiterleitung ab und akzeptiert den finalen Response nur über HTTPS mit HTTP-Status 2xx.
9. Provisioning schreibt in restriktives Geschwister-Staging, prüft dort das vollständige Manifest und installiert erst danach per Rename auf demselben Volume. Eine vorhandene Installation wird als Geschwister-Backup gehalten und bei Installationsfehler zurückgerollt. Recovery bereinigt partielle Stagings und verwaiste Backups.
10. Automatisierte Tests laden das reale Modell nicht. Kleine Fake-Manifeste und Fake-Transporte beweisen Hash-Fail-Closed, Abbruchbereinigung, Rollback, lokale Bereitschaft und die statische Transportgrenze.

### Abweichung von der Planungsbasis

PRD, Test-Spezifikation und Ralplan nannten FluidAudio `0.12.4` als damalige Evaluationsbasis, nicht als unveränderlichen Produktions-Pin. Vor dem Einbau des realen Adapters wurde die verwendete API gegen den verfügbaren Quellstand aktualisiert. Die Implementierung verwendet deshalb `0.15.5`; `Package.swift` und `WhisperFlow.xcodeproj/project.pbxproj` erzwingen dieselbe exakte Version. Es gibt keinen offenen Versionsbereich und keinen stillen Laufzeit-Download einer neueren Runtime. Ein weiterer Versionswechsel bleibt ein explizites Supply-Chain-, Lizenz- und Regressionstest-Ereignis.

## URL- und Integritätsgrenze

Die Modellrevision besitzt kein einzelnes stabiles Archiv mit dauerhaftem Download-Endpunkt. FlusterFlow bildet stattdessen für jedes Manifest-Artefakt eine exakte Revision-URL unter `huggingface.co/.../resolve/<revision>/<pfad>`. Große Dateien werden auf kurzlebige, signierte CDN-URLs umgeleitet; deren konkrete Hosts und Query-Signaturen können wechseln.

Deshalb ist die initiale Quell-Hostprüfung eine Herkunftsgrenze, während HTTPS auf jedem Redirect und die 21 Inhalts-Hashes die eigentliche Integritätsgrenze bilden. Es wird weder ein wechselnder CDN-Host als dauerhafter Vertrauensanker gespeichert noch eine nicht existierende stabile Archiv-URL behauptet. Details stehen in `docs/model-supply-chain.md`.

## Lizenzentscheidung

FluidAudio steht am gepinnten Stand unter Apache-2.0. Die Metadaten der gepinnten Model Card deklarieren `CC-BY-4.0` und nennen `nvidia/parakeet-tdt-0.6b-v3` als Basismodell. Dieselbe Model Card enthält später widersprüchliche Apache-2.0-Prosa. Für den privaten MVP wird das Modell konservativ als `CC-BY-4.0` geführt. Vor jeder Weitergabe müssen diese Inkonsistenz geklärt, die Attribution vervollständigt und die Notices erneut geprüft werden.

## Erwogene Alternativen

### Automatischer Modelldownload beim ersten Diktat

Abgelehnt. Er würde Nutzerabsicht, Offline-Garantie und die überprüfbare Transportgrenze vermischen.

### Modellgewichte im Repository oder App-Bundle

Abgelehnt. Die Größe belastet Quellhistorie und Builds; außerdem würde jede Redistribution sofort zusätzliche Lizenz- und Updatepflichten auslösen.

### Ungepinnter Hub-Download durch die ASR-Runtime

Abgelehnt. Ein bewegliches Modellziel und versteckte Repair-Downloads sind weder reproduzierbar noch mit vollständiger lokaler Privatsphäre vereinbar.

### Vertrauen nur auf TLS oder Gesamtgröße

Abgelehnt. TLS schützt den Transport, nicht gegen falschen Upstream-Inhalt oder partielle/gleich große Manipulation. Einzelhashes und Tree-Hash bleiben zwingend.

## Konsequenzen

- Nach valider Installation kann Diktat vollständig offline laufen.
- Modellbereitstellung bleibt eine sichtbare, separate Nutzeraktion; der normale Diktatpfad besitzt keinen Zugriff auf den Transport.
- Ein Modellupdate erfordert bewusstes Manifest-, Lizenz-, Test- und ADR-Review.
- Die Upgrade-Installation besteht aus zwei atomaren Rename-Schritten mit einem kurzen, recovery-fähigen Zwischenzustand; sie ist kein plattformübergreifender Single-Swap.
- Signed-CDN-Zielhosts dürfen wechseln. Ihre Identität ersetzt niemals die gepinnten Inhalts-Hashes.

## Verifikation

```bash
swift test
swift build
rg -n 'ModelProvisioningTransport|ModelArtifactDownloadRequest|HTTPSModelProvisioningTransport' WhisperFlow --glob '*.swift'
rg -n 'URLSession' WhisperFlow --glob '*.swift'
git diff --check
```

Erwartung: Alle Tests und der Build sind grün; Provisioning-Typen liegen nur unter `WhisperFlow/Integrations/ModelProvisioning`; `URLSession` liegt nur in den expliziten OpenAI- und Modell-Provisioning-Transporten; der echte 483-MB-Download wird nicht ausgeführt.
