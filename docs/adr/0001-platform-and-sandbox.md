# ADR-0001: Native macOS-Plattform und private Sandbox-Strategie

- Status: Accepted
- Datum: 2026-07-16
- Aktualisiert: 2026-09-08
- Entscheider: freigegebener Ralplan-Konsens

## Kontext

Die App soll globales Push-to-talk, ein nicht aktivierendes Menüleisten-/Panel-Erlebnis und kontrollierte Accessibility-basierte Zieleinfügung auf einem privaten Mac bereitstellen. Gleichzeitig muss der lokale Diktatpfad unabhängig von Konto, Cloud und Netzwerk bleiben. Die Zielplattform ist macOS 15 oder neuer; die primäre Toolchain ist Swift 6 mit Strict Concurrency.

## Entscheidung

1. Die App wird nativ in Swift 6 umgesetzt. SwiftUI besitzt App- und Settings-Szenen, AppKit den Menüleisten-Lebenszyklus und spätere nicht aktivierende Panels.
2. Der Deployment Target ist macOS 15.0.
3. Der App Sandbox Build-Schalter bleibt für den privaten V1-Build deaktiviert. Systemweite Accessibility- und Einfügungsintegration wird ausschließlich über dokumentierte macOS-APIs und explizite TCC-Freigaben umgesetzt.
4. Hardened Runtime ist für Release aktiviert. Debug verwendet keine Hardened Runtime und eine getrennte Bundle-ID, damit Entwicklungsfreigaben und die stabile Release-/TCC-Identität nicht vermischt werden.
5. Der stabile Release Bundle Identifier lautet `com.flusterflow.private`; Debug verwendet `com.flusterflow.private.debug`. `WhisperFlow` ist nur der interne Modul- und Projektname.
6. Der private Release-Build verwendet manuelles Code Signing mit der stabilen lokalen Identität `FlusterFlow Private Signing` aus dem dedizierten Keychain `FlusterFlowSigning.keychain-db`. Unsigned oder Ad-hoc-Builds sind ausschließlich lokale Debug-/CI-Overrides und keine Release- oder TCC-Evidenz. Private Schlüssel, Zertifikatexporte und Credentials werden nie eingecheckt.
7. Das Entitlement bleibt auf `com.apple.security.device.audio-input` beschränkt. Jede weitere Berechtigung erfordert eine ADR-Aktualisierung und einen Privacy-/TCC-Review.

## Konsequenzen

### Positiv

- Native APIs halten Fokus-, Permission- und Concurrency-Grenzen nachvollziehbar.
- Der lokale Kern benötigt keine Netzwerk- oder Provider-Abhängigkeit.
- Die stabile Bundle-ID schafft eine Voraussetzung für reproduzierbare TCC- und Designated-Requirement-Prüfungen.

### Negativ

- Ohne App Sandbox trägt die App selbst die Verantwortung für strikte Modul-, Daten- und Logging-Grenzen.
- Accessibility ist eine mächtige Nutzerfreigabe und muss fail-closed behandelt werden.
- Eine gültige statische Signatur beweist noch keine TCC-Kontinuität. Das private Release-Gate benötigt zwei Builds mit derselben lokalen Identität und einen praktischen Permission-Smoke am tatsächlich installierten Artefakt.
- Die einmalige Umstellung auf diese neutrale Bundle-ID migriert keine Einstellungen aus der vorherigen Preferences-Domain. Einstellungen, Onboarding, Kürzel, persönliches Lexikon sowie Mikrofon- und Accessibility-Freigaben müssen neu gesetzt werden; Aufnahmehistorie und lokale Modelle bleiben erhalten.

## Verifikation

- Gemeinsame Xcode-Buildsettings: `MACOSX_DEPLOYMENT_TARGET = 15.0`, `SWIFT_VERSION = 6.0`, `SWIFT_STRICT_CONCURRENCY = complete`, `ENABLE_APP_SANDBOX = NO`.
- Debug: `PRODUCT_BUNDLE_IDENTIFIER = com.flusterflow.private.debug` und `ENABLE_HARDENED_RUNTIME = NO`.
- Release: `PRODUCT_BUNDLE_IDENTIFIER = com.flusterflow.private` und `ENABLE_HARDENED_RUNTIME = YES`.
- `WhisperFlow/WhisperFlow.entitlements` enthält ausschließlich `com.apple.security.device.audio-input`.
- Vor dem privaten Release: zwei manuell signierte Release-Builds aus dem dedizierten Keychain mit `codesign -d --entitlements :-` und `codesign -d -r-` verifizieren; danach genau eines dieser Artefakte atomar exportieren, über seinen CDHash unverändert mit dem Artifact-Modus des Installers installieren und ausschließlich daran den Mikrofon-/Accessibility-TCC-Smoke dokumentieren. Zwischen Verifikation, Installation und Smoke ist kein erneuter Build zulässig.

## Neuentscheidung erforderlich bei

- öffentlicher Distribution oder App-Store-Ziel;
- zusätzlichen TCC-Berechtigungen;
- Wechsel auf eine Apple-Developer-/Developer-ID-Signatur;
- einer sicheren, getesteten Sandbox-Architektur, die den systemweiten Kern vollständig erhält.
