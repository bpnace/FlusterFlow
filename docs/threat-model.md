# Threat Model: lokaler Kern und optionales BYOK-Enrichment

## Schutzgüter

- Audio, Rohtranskript, lokaler Kandidat und begrenzter Kontext
- OpenAI-API-Key
- Fokus- und Auswahlzustand des Zieltextfelds
- Integrität der final eingefügten Aussage
- Zusicherung, dass Local-only keine Verbindung initiiert

## Vertrauensgrenzen

1. Mikrofon und Accessibility APIs zum lokalen Prozess
2. actor-isolierter Dictation Core zu kurzlebigen Inhaltsobjekten
3. App zum macOS Keychain
4. ausschließlich bei Opt-in: `OpenAITransport` über System-TLS zum konfigurierten Responses-Endpunkt
5. ausschließlich nach ausdrücklicher Nutzeraktion: isolierter HTTPS-Transport zur Modellbereitstellung, außerhalb des laufenden Diktatgraphen
6. Providerverarbeitung außerhalb der Kontrolle der lokalen App

## Bedrohungen und Maßnahmen

| Bedrohung | Maßnahme | Restrisiko |
| --- | --- | --- |
| unbeabsichtigter Cloud-Request | `CloudGate` verlangt Enable-Schalter und gespeicherten Key; deaktivierter oder fehlender Key erzeugt null Transportaufrufe | fehlerhafte spätere App-Verdrahtung; statische und Integrationstests bleiben Release-Gate |
| unbeabsichtigte Kontextübertragung | separater Context-to-cloud-Consent, Availability-Prüfung und harte Begrenzung auf 1.500 Zeichen | freigegebener Kontext kann weiterhin sensible Inhalte enthalten; UI muss Datenklassen vor Aktivierung zeigen |
| Secret-Leak in Logs oder Fehlern | redigierender `SecretAPIKey`, inhaltsfreie Fehler-Enums, keine Provider-Bodies in Fehlern | Speicheranalyse eines laufenden autorisierten Requests liegt außerhalb des V1-Schutzes |
| Key-Synchronisierung auf andere Geräte | `kSecAttrSynchronizable=false` und `AfterFirstUnlockThisDeviceOnly` | kompromittiertes lokales Benutzerkonto oder entsperrter Keychain |
| Prompt Injection aus Kandidat oder Kontext | Nutzerpayload wird als Daten-JSON eingebettet, feste Developer-Instruktion und striktes Antwortschema | Modell kann semantisch trotzdem falsch umformulieren; Meaning-Preservation-Policy muss unabhängig freigeben |
| stille Bedeutungsänderung | deterministische Meaning-Preservation-Policy nach Schema-Validierung; konservativer Default akzeptiert nur identischen Text | unerkannte semantische Nuancen; Nutzer behält stets lokalen Kandidaten als Fallback |
| Replay oder serverseitige Konversation | einzelne Responses-Anfrage mit `store:false`; keine Conversation, Tools, Dateien, Background oder `previous_response_id` | `store:false` bedeutet nicht Zero Data Retention beim Provider |
| Provider-/Netzwerkfehler oder 429 | harter lokaler Timeout, kategorisierte Fehler, lokaler Fallback | Cloud-Komfort ist temporär nicht verfügbar |
| manipulierte Providerantwort | HTTPS über System Trust Store, striktes JSON-Schema, exakt ein `text`-Feld, Meaning-Guard | kompromittierter Provider oder System Trust Store |
| stale Ergebnis nach Cancel | Provider hält pro Session einen cancelbaren Task; Coordinator verwirft veraltete Session-IDs | bereits beim Provider eingegangene Anfrage lässt sich nicht garantiert zurückrufen |
| Netzwerkzugriff aus Local Core | Der Local-only-Diktatgraph besitzt keinen `URLSession`-Transport; Netzwerktypen sind auf die isolierten Opt-in-Capabilities für OpenAI und ausdrücklich ausgelöste Modellbereitstellung begrenzt. Das statische Verify-Script prüft diese Dateigrenze. | statische Prüfung ersetzt den vorgesehenen dynamischen Socket-Test nicht |
| geteilte HTTP-Zustände im BYOK-Pfad | Der standardmäßige OpenAI-Transport nutzt eine ephemere Session ohne URL-Cache, Cookies oder Credential-Storage; die Request-Cache-Policy ignoriert lokale Cache-Daten. | Betriebssystem- und Providerverarbeitung außerhalb des Prozesses bleiben bestehen |

## Annahmen

- macOS, Keychain und System-TLS sind nicht kompromittiert.
- Der Nutzer kontrolliert den API-Key und die Provider-Projekteinstellungen.
- Cloud bleibt standardmäßig deaktiviert.
- Eine öffentliche Distribution, Mandantentrennung und Server-Infrastruktur sind nicht Teil von V1.

## Release-Gates

- Custom-URLProtocol-Tests ohne Live-Netzwerk
- Consent-Truth-Table und Keychain-Abstraktionstests
- High-risk-Meaning-Fixtures vollständig abgelehnt
- `Scripts/verify-local-network.sh`
- dynamischer Zero-Network-E2E-Test für den Local-only-Prozess gemäß Testspezifikation
