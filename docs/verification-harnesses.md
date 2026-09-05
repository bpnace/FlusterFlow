# Target- und Privacy-Verifikationsharnesses

## Zweck und Graphgrenze

Die Harnesses sind separate SwiftPM-Produkte und besitzen keine Abhängigkeit vom Produktziel `WhisperFlow`:

- `TextTargetHarnessCore` + `TextTargetHarness` testen Zielzustände, Mutation und Bestätigung;
- `PrivacyHarnessCore` + `PrivacyHarness` beobachten einen bereits gebauten lokalen Prozess;
- die zugehörigen Testtargets hängen nur an ihrem jeweiligen Harness-Core.

Damit gelangen AppKit-/WebKit-Fixtures, Socket-Fixtures und Prüfcode nicht in den ausgelieferten App-Graph. Wird `Package.swift` in Xcode geöffnet, erscheinen die Harnesses als eigene Schemes. Das bestehende App-Scheme bleibt unverändert.

Für reproduzierbare Xcode-CLI-Builds referenziert `TestSupport/VerificationHarnesses.xcworkspace` das Swift-Package, ohne die Harness-Targets in `WhisperFlow.xcodeproj` aufzunehmen:

```bash
RUN_XCODE_HARNESS=1 bash Scripts/verify-target-harness.sh
```

Die Workspace-Schemes `TextTargetHarness` und `PrivacyHarness` bauen nur ihre jeweiligen Core-Targets. `CODE_SIGNING_ALLOWED=NO` verhindert eine Verwechslung dieses Prüfbuilds mit dem später stabil signierten privaten App-Artefakt.

## TextTargetHarness

### Bauen und Verträge prüfen

```bash
bash Scripts/verify-target-harness.sh
```

Der Befehl baut das eigenständige Produkt und Testmodul und validiert:

- die 28 deterministischen Szenarien in `TestSupport/TextTargetHarness/scenarios.json`;
- eindeutige IDs und fail-closed `schemaVersion: 1`;
- die externen manuellen Browser-/Electron-Szenarien;
- den maschinenlesbaren Ergebnisvertrag in `result.schema.json`.

### Interaktive kontrollierte Targets

```bash
swift run TextTargetHarness
```

Das Fenster enthält echte `NSTextField`-, `NSTextView`- und `NSSecureTextField`-Controls sowie eine `WKWebView` mit Text-Input, Textarea, Contenteditable und Passwortfeld. Schaltflächen ändern Fokus und Auswahlbereich absichtlich. Die Ansicht zeigt geordnete, inhaltsfreie JSON-Beobachtungen und den Ausgangs-/aktuellen `changeCount` des General Pasteboard. Nur die Schaltfläche `Explicit copy` schreibt bewusst eine synthetische Fixture in die Zwischenablage.

`Run safe assertions` prüft sichtbar eine bestätigte AppKit-Mutation, fail-closed Secure-Target-Policy und unverändertes General Pasteboard. Die automatisierten Core-Tests decken zusätzlich die erneute Erfassung des aktuell fokussierten Textfelds unmittelbar vor dem Commit, Fokus-Fingerprint-, Range-Fingerprint-, Session-, UTF-16- und Protected-Target-Entscheidungen ab. Direkte Unicode-Ereignisse sind der produktive, bestätigungspflichtige Pfad für fokussierte Textfelder innerhalb eines `AXWebArea`.

### Reale Cross-Process-AX-Prüfung

```bash
bash Scripts/run-target-ax-smoke.sh
```

Das Script startet das kontrollierte Fenster und greift anschließend aus einem zweiten Prozess darauf zu. Es bestätigt eine native `AXSelectedText`-Mutation sowie direkte Unicode-Einfügung in ein echtes `WKWebView.contenteditable`, klassifiziert das Secure Field ohne dessen Wert zu lesen und prüft das General Pasteboard. Die produktive App verwendet für kompatible native Textfelder zusätzlich eine validierte direkte `AXValue`-Ersetzung, falls `AXSelectedText` nicht setzbar ist. Keiner dieser Pfade schreibt automatisch in die Zwischenablage. Das Ergebnis folgt `result.schema.json`.

Diese Prüfung ist TCC-abhängig. Ohne Bedienungshilfen-Freigabe für `.build/debug/TextTargetHarness` endet sie bewusst mit Exitcode `77` und `status: "tccRequired"`. Die Freigabe kann nicht automatisiert oder umgangen werden. Der produktive Unicode-Pfad sendet ausschließlich Text an das bereits fokussierte, erneut validierte Web-Textfeld und bestätigt Text sowie Cursor danach über Accessibility; er verwendet weder General Pasteboard noch ein Ergebnisfenster.

### Safari, Chromium und Electron

Browser- und Electron-Prozesse werden nicht als Abhängigkeiten installiert oder vom Harness ferngesteuert. Die manuellen, synthetischen Schritte stehen in `TestSupport/TextTargetHarness/external-scenarios.json`. Ein inhaltsfreier Ergebnisdatensatz lässt sich so anlegen:

```bash
Scripts/record-target-result.sh \
  run-local-001 external-chromium-contenteditable Chromium.contenteditable \
  passed directAX true /tmp/flusterflow-target-result.json
```

Der Ergebnisdatensatz enthält weder Zieltext noch Fenstertitel, Bundle-ID oder Clipboard-Inhalt. Ein positiver Einfügeausgang ist nur gültig, wenn `confirmedMutation` wahr und `pasteboardChanged` falsch ist. Browser-Passwortfelder müssen `insertionDenied` liefern.

## Dynamischer Local-only-Privacy-Smoke

```bash
bash Scripts/verify-local-privacy.sh
```

Das Script führt zuerst das statische Netzwerk-Boundary-Gate aus und baut beide Harness-Produkte. Erst danach startet `PrivacyHarness` den bereits gebauten `TextTargetHarness --privacy-smoke` mit fünf zufälligen synthetischen Canaries für Transcript, Kontext, Fenstertitel, Pfad und Key-Material. Während des Child-Laufs werden der Prozessbaum und offene TCP-/UDP-Sockets wiederholt über `/usr/sbin/lsof` geprüft. Anschließend sucht der Scanner jede Canary in:

- dem Unified Log für die Child-PID;
- einem isolierten Child-`TMPDIR`;
- aufgezeichnetem Child-stdout/stderr;
- `~/Library/Logs/FlusterFlow`;
- `~/Library/Application Support/FlusterFlow/Diagnostics`;
- `~/Library/Caches/FlusterFlow`;
- `~/Library/Logs/DiagnosticReports`;
- zusätzlichen, ausdrücklich mit `--scan` angegebenen Verzeichnissen;
- allen String-Repräsentationen des General Pasteboard.

Die Dateisuche schließt versteckte Dateien und Package-Inhalte ein. Symlinks, unlesbare Einträge sowie ein überschrittenes Datei- oder Größenlimit werden nicht übersprungen, sondern machen den Report mit `status: "inconclusive"` fail-closed.

Ein nicht erfolgreicher Child-Prozess, jeder beobachtete Netzwerk-Socket, jede Canary-Fundstelle oder eine nicht erlaubte Pasteboard-Änderung lässt den Lauf scheitern. Zwei ausschließlich lokale Negativkontrollen belegen, dass das Gate tatsächlich rot wird:

1. eine Loopback-TCP-Verbindung;
2. eine absichtlich in das isolierte `TMPDIR` geschriebene Canary.

Weder ein Modell noch OpenAI, ein API-Key oder ein Live-Netzwerkziel werden dabei verwendet.

Die fünf Werte sind ausschließlich synthetische, zufällige Marker. Der Key-Marker wird nicht als echter Schlüssel behandelt und es wird kein Keychain-Item angelegt; ein separater Keychain-Canary-Test des final signierten App-Builds bleibt deshalb Teil des vollständigen O-02-Release-Gates.

### Aussagegrenzen

- `lsof` wird standardmäßig alle 25 ms abgefragt. Eine kürzere Socket-Lebensdauer kann zwischen zwei Samples liegen; deshalb bleibt das statische Boundary-Gate verbindlich.
- Die Canary-Suche belegt nur die aufgeführten und zusätzlich übergebenen Orte. Sie ist kein systemweiter DLP-Scanner.
- Eine parallele Clipboard-Änderung durch eine andere App führt bewusst zu einem konservativen Fehlalarm.
- Der In-memory-Smoke beweist die Harness- und Privacy-Gate-Verkabelung. Reales ASR, Modellbereitstellung, App-Signing, TCC-Lifecycle und die externe Ziel-App-Matrix bleiben eigene Release-Gates.
- Live-Cloud-Smokes werden erst nach bewusster Key-Eingabe durch den Nutzer ausgeführt und gehören nicht zu diesem Harness.

## Direkte Einzelbefehle

```bash
swift build --product TextTargetHarness
swift build --product PrivacyHarness

.build/debug/TextTargetHarness \
  --validate-contract \
  --scenarios TestSupport/TextTargetHarness/scenarios.json

.build/debug/PrivacyHarness -- \
  .build/debug/TextTargetHarness --privacy-smoke
```

Der Privacy-Report ist JSON mit `schemaVersion`, Status, Child-Exitcode, Sample-/Prozesszahlen, Pasteboard-Zustand, inhaltsfreien Leak-Kategorien und den Aussagegrenzen des Laufs.

## Private Signing und G9

Der reine Prerequisite-Check baut nichts, legt keine Dateien an und verändert weder Keychain noch Truststore:

```bash
bash Scripts/verify-private-signing.sh --check-prerequisites
```

Ohne explizite Identity meldet er maschinenlesbar `status: "blocked"`, `reason: "identity_required"` und beendet sich mit Exitcode `77`. Eine bereits vorhandene gültige Code-Signing-Identity wird ausschließlich als 40-stelliger SHA-1-Fingerprint übergeben; ihr Wert wird nie ausgegeben:

```bash
FLUSTERFLOW_CODE_SIGN_IDENTITY='<40-hex-fingerprint>' \
  bash Scripts/verify-private-signing.sh --check-prerequisites

bash Scripts/verify-private-signing.sh \
  --identity '<40-hex-fingerprint>'
```

Der vollständige Lauf erzeugt zwei voneinander getrennte Release-Builds in frischen temporären DerivedData-Verzeichnissen. Automatische Paketauflösung und Paketupdates sind deaktiviert. Für beide Artefakte werden die feste Bundle-ID `com.flusterflow.private`, `codesign --verify --deep --strict`, eine nicht-ad-hoc Signatur, das Hardened-Runtime-Flag, ausschließlich das erforderliche Entitlement `com.apple.security.device.audio-input` und das Designated Requirement geprüft. Die beiden Designated Requirements und Entitlements müssen exakt übereinstimmen.

`spctl` wird ohne Ausgabe von Pfaden, Zertifikatsnamen oder Identity-Werten ausgeführt. Die inhaltsfreie Klassifikation unterscheidet eine lokale selbstsignierte Identity mit genau einer Authority von einer verketteten Identity. Akzeptiert Gatekeeper beide Builds, liefert das Script `status: "passed"`. Lehnt Gatekeeper beide lokal selbstsignierten Builds ab, obwohl Signatur, Hardened Runtime und Requirement gültig sind, wird dies separat als `gatekeeper_local_self_signed_boundary` mit Exitcode `77` gemeldet und nicht als bestanden umgedeutet. Eine Ablehnung mit verketteter Identity ist stattdessen ein echter Prüffehler. Der anschließende manuelle Launch- sowie Mikrofon-/Accessibility-TCC-Kontinuitätstest bleibt nach automatischem Erfolg oder dokumentierter lokaler Grenze verpflichtend.

Das Script erzeugt, importiert oder vertraut keine Zertifikate, exportiert keine Schlüssel und schreibt weder Identity, Benutzername noch Gerätekennung in seine JSON-Ausgabe. Alle DerivedData- und Prüfartefakte werden über einen Exit-Trap entfernt. Exitcode `0` bedeutet bestandene automatisierbare G9-Prüfung, `1` einen fail-closed Prüffehler und `77` eine externe oder manuelle Grenze.
