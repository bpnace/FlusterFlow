# ADR-0001: Native macOS-Plattform und private Sandbox-Strategie

- Status: Accepted
- Datum: 2026-07-16
- Entscheider: freigegebener Ralplan-Konsens

## Kontext

Die App soll globales Push-to-talk, ein nicht aktivierendes Menüleisten-/Panel-Erlebnis und kontrollierte Accessibility-basierte Zieleinfügung auf einem privaten Mac bereitstellen. Gleichzeitig muss der lokale Diktatpfad unabhängig von Konto, Cloud und Netzwerk bleiben. Die Zielplattform ist macOS 15 oder neuer; die primäre Toolchain ist Swift 6 mit Strict Concurrency.

## Entscheidung

1. Die App wird nativ in Swift 6 umgesetzt. SwiftUI besitzt App- und Settings-Szenen, AppKit den Menüleisten-Lebenszyklus und spätere nicht aktivierende Panels.
2. Der Deployment Target ist macOS 15.0.
3. Der App Sandbox Build-Schalter bleibt für den privaten V1-Build deaktiviert. Systemweite Accessibility- und Einfügungsintegration wird ausschließlich über dokumentierte macOS-APIs und explizite TCC-Freigaben umgesetzt.
4. Hardened Runtime bleibt in Debug und Release aktiviert.
5. Der stabile, originale Bundle Identifier lautet `com.flusterflow.private`. `WhisperFlow` ist nur der interne Modul- und Projektname.
6. Der Bootstrap verwendet Ad-hoc-Signierung. Vor dem Daily-Driver-Gate wird auf diesem Mac einmalig eine lokale selbstsignierte Identität im Login-Keychain erstellt. Private Schlüssel, Zertifikatexporte und Credentials werden nie eingecheckt.
7. Zusätzliche Entitlements werden nicht vorsorglich vergeben. Jede neue Berechtigung erfordert eine ADR-Aktualisierung und einen Privacy-/TCC-Review.

## Konsequenzen

### Positiv

- Native APIs halten Fokus-, Permission- und Concurrency-Grenzen nachvollziehbar.
- Der lokale Kern benötigt keine Netzwerk- oder Provider-Abhängigkeit.
- Die stabile Bundle-ID schafft eine Voraussetzung für reproduzierbare TCC- und Designated-Requirement-Prüfungen.

### Negativ

- Ohne App Sandbox trägt die App selbst die Verantwortung für strikte Modul-, Daten- und Logging-Grenzen.
- Accessibility ist eine mächtige Nutzerfreigabe und muss fail-closed behandelt werden.
- Ad-hoc-Signierung beweist noch keine TCC-Kontinuität. Das spätere private Release-Gate benötigt zwei Builds mit derselben lokalen Identität und einen praktischen Permission-Smoke.

## Verifikation

- Xcode-Buildsettings: `MACOSX_DEPLOYMENT_TARGET = 15.0`, `SWIFT_VERSION = 6.0`, `SWIFT_STRICT_CONCURRENCY = complete`, `ENABLE_HARDENED_RUNTIME = YES`, `ENABLE_APP_SANDBOX = NO`.
- Bundle-ID in Debug und Release: `com.flusterflow.private`.
- Keine Entitlements-Datei im Bootstrap; damit existiert keine vorsorgliche Capability-Liste.
- Vor dem privaten Release: `codesign -d --entitlements :-`, `codesign -d -r-` für zwei Release-Builds und dokumentierter Mikrofon-/Accessibility-TCC-Smoke.

## Neuentscheidung erforderlich bei

- öffentlicher Distribution oder App-Store-Ziel;
- zusätzlichen TCC-Berechtigungen;
- Wechsel auf eine Apple-Developer-/Developer-ID-Signatur;
- einer sicheren, getesteten Sandbox-Architektur, die den systemweiten Kern vollständig erhält.
