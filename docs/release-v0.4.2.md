# FlusterFlow 0.4.2 (Build 20)

Dieser Patch verbessert den Abschluss von Handsfree-Diktaten, die lokale Verarbeitung langer Aufnahmen und die Rückmeldung nach der Einfügung.

## Änderungen

- Der Hand-Button im Aufnahme-Popup übernimmt eine laufende Push-to-talk-Aufnahme in Handsfree. Danach beendet derselbe Button als Haken die Aufnahme und fügt den verarbeiteten Text ein. Symbol und Breite wechseln animiert; veraltete Aktionen können keine neue Sitzung bedienen.
- Handsfree lässt sich zusätzlich über das App-Menü starten. Im Verlauf wird ein nicht einsatzbereites Modell für die erneute Transkription nachvollziehbar erklärt.
- Erfolgreiche Einfügungen werden zuverlässiger bestätigt. Nicht bestätigte Einfügungen werden ausdrücklich von nachgewiesenen Fehlern unterschieden.
- Geräusche ohne erkannte Stimme und reine Satzzeichen-Transkripte werden abgefangen. Leisere Sprachanteile am Rand der Aufnahme bleiben bei der Normalisierung besser erhalten.
- Lange Aufnahmen werden in Abschnitte von höchstens 20 Sekunden aufgeteilt, möglichst an Pausen. Eine empfindlichere Pausenerkennung schützt leisere Sprache; kurze Reststücke werden nicht verworfen. Der Decoder bleibt innerhalb seiner unterstützten Tokengrenze.
- Adaptiv verlangt bei einer bloßen Häufung von Funktionswörtern zusätzliche Unsicherheit, bevor Large zugeschaltet wird. Starke Wiederholungen und andere Qualitätswarnungen bleiben berücksichtigt. Ein schlechteres Large-Ergebnis oder ein Large-Timeout verdrängen kein verwendbares Turbo-Ergebnis.
- Ob lokal nachbearbeitet wird, hängt vom ausgewählten Transkript ab. Ein vorheriger Modellwechsel allein löst keine Nachbearbeitung mehr aus.
- Large bleibt bei normalem Betrieb zehn Minuten statt zwei Minuten im Leerlauf geladen; die bestehende Freigabe bei Speicherdruck bleibt erhalten.
- Inhaltsfreie Zeitmessungen trennen Modellvorbereitung, Erkennung, adaptive Auswahl, Nachbearbeitung und Einfügung. Opt-in-Benchmarks vergleichen tatsächlich geladene Modelle und Wortfehlerraten.

## Verifikation

Vier unmittelbar aufeinanderfolgende Live-Diktate mit demselben 110-Wörter-Testtext über Lautsprecher und Mikrofon in TextEdit: jeweils 110 Wörter, keine Wortfehler, bestätigte Einfügung. Gesamtdauer nach Aufnahmeende: 3,45 / 3,10 / 3,04 / 3,09 Sekunden. Adaptiv wählte jeweils Turbo; zusätzliche Nachbearbeitung wurde übersprungen. Der getestete Funktionsstand wurde anschließend nur für diesen Patch versioniert.

Die vollständige Testsuite bestand mit 497 Tests, 17 expliziten Opt-in-Skips und keinen Fehlern. Der lokale Privacy-Harness einschließlich Negativkontrollen bestand ebenfalls.

## Bekannte Grenzen

Die vier erfolgreichen Live-Diktate sind keine allgemeine Genauigkeitsgarantie. Eine ältere gespeicherte Problemaufnahme lieferte im letzten Vergleich weiterhin acht Wortfehler. Ohne erkennbare Pause kann eine Abschnittsgrenze innerhalb von Sprache liegen. Die längere Modellhaltezeit wurde im Code geprüft, nicht durch einen vollständigen zehnminütigen Leerlauftest. Eine systemweite AEC- oder Rauschunterdrückung wird durch diese Änderungen nicht zugesichert.
