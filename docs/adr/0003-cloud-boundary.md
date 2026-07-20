# ADR 0003: Optionales Cloud-Enrichment als isolierte Capability

- Status: Accepted
- Datum: 2026-07-16

## Kontext

Der lokale Diktatkern muss ohne Konto, Abo oder laufende Verbindung funktionieren. Ein eigener API-Key darf optional bessere Textüberarbeitung ermöglichen. Audio, Rohtranskript und unbeschränkter Anwendungskontext dürfen dadurch nicht Teil einer allgemeinen Cloud-Pipeline werden.

## Entscheidung

Cloud-Enrichment wird als isolierte Capability implementiert:

- `CloudGate` autorisiert nur bei aktiviertem Cloud-Schalter und vorhandenem Keychain-Key.
- Kontext benötigt einen zweiten Consent und wird auf 1.500 Zeichen begrenzt.
- Der transportierbare Core-DTO enthält ausschließlich finalen lokalen Kandidaten, Sprache, generischen Zieltyp und optionalen Kontext. Er besitzt kein Audio- oder Rohtranskriptfeld.
- Der laufende Local-only-Diktatgraph besitzt keinen `URLSession`-Transport. Netzwerkzugriff liegt ausschließlich in zwei isolierten Opt-in-Capabilities: `Integrations/OpenAI/OpenAITransport.swift` für BYOK-Enrichment und `Integrations/ModelProvisioning/HTTPSModelProvisioningTransport.swift` für eine ausdrücklich ausgelöste Modellbereitstellung. Der Provisioning-Transport wird nicht in den Diktatgraph injiziert.
- Der standardmäßige OpenAI-Transport nutzt eine ephemere, cache-, cookie- und Credential-Storage-freie Session. Eine injizierte Session bleibt nur als Test- und Integrationsnaht möglich.
- Der Responses-Aufruf ist text-only, stateless und setzt `store:false`. Tools, Dateien, Background, Conversations und `previous_response_id` sind nicht modelliert.
- Der API-Key liegt als nicht synchronisiertes Generic Password im Keychain.
- Provider- oder Schemafehler, Timeout, Cancel und Meaning-Guard-Ablehnung liefern den lokalen Kandidaten.
- Das Modell ist ein validierter Konfigurationswert; ein Modellwechsel verändert die Architektur nicht.
- Die App behauptet nicht, dass `store:false` Zero Data Retention bietet.

## Erwogene Alternativen

### Provider-SDK im Domain/Core

Abgelehnt. Es würde Netzwerk- und Providerkonzepte in den lokalen Objektgraph tragen und die Zero-Network-Grenze schwächen.

### Audio oder Rohtranskript zusätzlich senden

Abgelehnt. V1 benötigt nur optionale Textüberarbeitung; zusätzliche Daten erhöhen Exposition ohne notwendigen Produktnutzen.

### Kontext zusammen mit dem allgemeinen Cloud-Schalter aktivieren

Abgelehnt. Nahegelegener Text ist eine eigenständige Datenklasse und benötigt eine separate Entscheidung.

### Providerantwort bei Transportfehler als harter Pipelinefehler behandeln

Abgelehnt. Der lokale Kandidat existiert bereits und darf durch eine optionale Capability nicht verloren gehen.

## Konsequenzen

- Local-only bleibt technisch und testbar unabhängig vom Netzwerk.
- Cloud-Komfort erfordert bewusste Konfiguration und verursacht direkte Providerkosten.
- Der Core kennt eine schmale Transportabstraktion, aber keine HTTP- oder Responses-Details.
- Die unabhängige Meaning-Preservation-Policy bleibt ein zwingendes Integrations- und Release-Gate.
- Provider-Retention bleibt eine externe Eigenschaft des API-Projekts und wird transparent als Restrisiko dokumentiert.
