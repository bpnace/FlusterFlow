# Privacy- und Datenfluss

## Grundsatz

FlusterFlow ist standardmäßig eine lokale Anwendung. Mikrofonaufnahme, lokales ASR, Cleanup, begrenzte Context Awareness und Einfügung benötigen nach der Modellbereitstellung keine Netzwerkverbindung. Cloud-Enrichment ist eine separate, standardmäßig deaktivierte BYOK-Funktion.

## Lokaler Diktatpfad

1. Audio wird während gedrücktem Push-to-talk im Arbeitsspeicher aufgenommen.
2. Das Audio wird lokal auf Mono mit 16 kHz normalisiert.
3. ASR und Cleanup erzeugen einen lokalen Kandidaten.
4. Optional werden höchstens 1.500 Zeichen am fokussierten Textfeld lokal verarbeitet. Secure Fields liefern keinen Kontext und erlauben keine automatische Einfügung.
5. Der lokale Kandidat wird über eine bestätigte Accessibility-Mutation oder – bei einem fokussierten webbasierten Textfeld – über bestätigte direkte Unicode-Tastaturereignisse eingefügt.
6. Es gibt keine persistente Diktat-Historie, kein automatisches Ergebnisfenster und keine automatische Nutzung des General Pasteboard.

Der laufende lokale Diktatgraph besitzt keinen `URLSession`-Transport. Netzwerktypen liegen ausschließlich in den isolierten Opt-in-Capabilities für OpenAI und eine ausdrücklich ausgelöste Modellbereitstellung. `Scripts/verify-local-network.sh` prüft diese Dateigrenze statisch.

## Optionaler OpenAI-Pfad

Ein Request ist nur möglich, wenn beide Bedingungen erfüllt sind:

- Cloud-Enrichment ist für die aktuelle Ausführung ausdrücklich aktiviert.
- Ein API-Key ist als Generic Password im macOS Keychain gespeichert.

Kontext besitzt einen zweiten, unabhängigen Opt-in. Ohne diesen zweiten Schalter wird kein nahegelegener Text übertragen.

### Übertragene Daten

| Datenklasse | Standard | Mit separatem Kontext-Opt-in |
| --- | --- | --- |
| finaler lokaler Kandidat | ja | ja |
| Sprache (`de`, `en`, `auto`) | ja | ja |
| generischer Zieltyp (`email`, `chat`, `document`, `unknown`) | ja | ja |
| Kontext nahe Cursor | nein | höchstens 1.500 Zeichen |
| Audio oder Rohtranskript | nie | nie |
| Bundle-ID, Fenstertitel, Dateipfad, Nutzer- oder Gerätekennung | nie | nie |

Die Responses-Anfrage ist einzeln und stateless: `store:false`, keine Tools, Dateien, Conversations, `previous_response_id` oder Background-Ausführung. Fehler, Timeout, ungültige Antwort oder Ablehnung durch die Meaning-Preservation-Policy liefern immer den bereits vorhandenen lokalen Kandidaten.

Der standardmäßige BYOK-Transport verwendet eine ephemere `URLSession` ohne gemeinsamen URL-Cache, Cookie-Speicher oder Credential-Storage. Eine Session kann ausschließlich als Test- oder Integrationsnaht injiziert werden.

`store:false` ist keine Zusage für Zero Data Retention. Verarbeitung und Aufbewahrung beim Provider hängen von den Datenkontrollen des verwendeten API-Projekts ab. API-Kosten fallen direkt beim Provider an; FlusterFlow schätzt oder verbirgt sie nicht.

## API-Key

- Speicherung ausschließlich als nicht synchronisiertes Generic Password im macOS Keychain.
- Keychain-Zugriff verwendet `AfterFirstUnlockThisDeviceOnly`.
- Der Key erscheint nicht in `UserDefaults`, Logs, Fehlerbeschreibungen oder Diagnoseexporten.
- Im Netzwerk wird er ausschließlich als Bearer-Authorization-Header an den konfigurierten HTTPS-Endpunkt verwendet.

## Mikrofon-Gerätekennungen

- `AVCaptureDevice.uniqueID` wird ausschließlich im Arbeitsspeicher für die aktuelle Geräteauswahl und das Audio-Setup gehalten.
- Die Kennung erscheint nicht in `UserDefaults`, Logs, Fehlerbeschreibungen oder Diagnoseexporten.
- Nach einem Neustart verwendet FlusterFlow wieder das Systemmikrofon. Beim Start wird ein eventuell vorhandener Legacy-Eintrag aus älteren Builds gelöscht.

## Netzwerkfähige Capability-Module

- `WhisperFlow/Integrations/OpenAI/OpenAITransport.swift`
- `WhisperFlow/Integrations/ModelProvisioning/` für einen späteren, separat nutzerinitiierten Modelldownload

Core, Audio, ASR, Cleanup, Accessibility, Insertion und Diagnostik dürfen keine Netzwerktypen importieren.
