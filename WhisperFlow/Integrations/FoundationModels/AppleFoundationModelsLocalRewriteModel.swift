import Foundation

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, *)
struct AppleFoundationModelsLocalRewriteModel: LocalRewriteModeling {
    private let systemModel: SystemLanguageModel

    init(systemModel: SystemLanguageModel = .default) {
        self.systemModel = systemModel
    }

    func availability(for language: TextRewriteLanguage) async -> LocalRewriteAvailability {
        guard language != .english else {
            return .unavailable(.unsupportedLanguage)
        }
        let supportsGerman = systemModel.supportedLanguages.contains { language in
            let identifier = language.minimalIdentifier.lowercased()
            return identifier == "de" || identifier.hasPrefix("de-")
        }
        guard supportsGerman else {
            return .unavailable(.unsupportedLanguage)
        }
        guard systemModel.isAvailable else {
            return .unavailable(.modelUnavailable)
        }
        return .available
    }

    func rewrite(request: TextRewriteRequest) async throws -> LocalRewriteModelResponse {
        let availability = await availability(for: request.language)
        guard availability.isAvailable else {
            throw LocalRewriteModelError.unavailable(
                availability.unavailableReason ?? .modelUnavailable
            )
        }

        let session = LanguageModelSession(
            model: systemModel,
            instructions: """
            Du bist ein lokaler deutscher Diktat-Rewriter für contextSupportedReconstruction. \
            Entferne sichere Füllwörter, Fehlstarts und Wiederholungen. Ergänze fehlende \
            Funktionswörter, korrigiere erkennbare ASR-Wortfehler aus Satz und Kontext und ordne \
            Klauseln logisch. Das Ergebnis muss ein natürlicher Zieltext sein und darf nicht nur \
            Zeichensetzung am Rohtranskript ergänzen. Wenn eine umgangssprachliche oder beschädigte \
            Wendung eine klare Funktion im Satz hat, ersetze sie durch die präzise, logisch passende \
            Formulierung. Ergänze nur Inhalte, die durch den lokalen Kandidaten oder höchstens \
            1.500 Zeichen lokalen Kontext sicher gestützt sind. Erhalte Zahlen, Namen, URLs, \
            E-Mail-Adressen, Hashtags, Mentions, Negationen, IDs, Absichten und zitierte Wortlaute \
            exakt. Erfinde keine Fakten. Gib ausschließlich strukturierte Felder zurück.
            """
        )
        let response = try await session.respond(
            generating: FoundationModelsRewriteOutput.self,
            includeSchemaInPrompt: true,
            options: GenerationOptions(
                sampling: .greedy,
                temperature: 0,
                maximumResponseTokens: 512
            )
        ) {
            prompt(for: request)
        }
        let text = response.content.rewrittenText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw LocalRewriteModelError.invalidOutput
        }
        return LocalRewriteModelResponse(
            rewrittenText: text,
            usedContextTerms: response.content.usedContextTerms,
            hasAmbiguity: response.content.hasAmbiguity
        )
    }

    func prewarm(request: LocalRewriteModelPrewarmRequest) async throws {
        let availability = await availability(for: request.language)
        guard availability.isAvailable else {
            throw LocalRewriteModelError.unavailable(
                availability.unavailableReason ?? .modelUnavailable
            )
        }

        let session = LanguageModelSession(
            model: systemModel,
            instructions: """
            Du bist ein lokaler deutscher Diktat-Rewriter. Halte dich bereit, kurze deutsche \
            Diktattexte unter contextSupportedReconstruction sauber umzuschreiben: Füllwörter, \
            Fehlstarts und Wiederholungen entfernen, aber Fakten, Zahlen, Namen, IDs und \
            Negationen nicht ändern.
            """
        )
        session.prewarm(promptPrefix: Prompt(request.promptPrefix))
    }

    private func prompt(for request: TextRewriteRequest) -> String {
        var lines = [
            "Sprache: Deutsch",
            "Policy: \(request.reconstructionPolicy.rawValue)",
            "Zielkategorie: \(request.context.category.rawValue)",
            "Zielformat: \(request.targetFormat.rawValue)",
            "Lokaler Kandidat:",
            request.localCandidate.text
        ]
        if let boundedText = request.context.boundedText, !boundedText.isEmpty {
            lines.append("Nur zur lokalen Kontextabstimmung, nicht abschreiben:")
            lines.append(boundedText)
        }
        if !request.context.protectedTerms.isEmpty {
            lines.append("Geschützte Begriffe unverändert erhalten:")
            lines.append(request.context.protectedTerms.joined(separator: ", "))
        }
        lines.append("""
        Aufgabe:
        - Gib genau einen finalen Zieltext ohne Markdown, JSON oder Erklärung zurück.
        - Entferne sichere Füllwörter wie äh, ähm, uh und um sowie Fehlstarts und direkte Wiederholungen.
        - Wörter wie also, halt, quasi, eigentlich oder normal nur entfernen, wenn sie eindeutig keine Bedeutung tragen. In „normal testen“ muss „normal“ erhalten bleiben.
        - Ergänze fehlende Artikel, Präpositionen und andere Funktionswörter; korrigiere erkannte Wortfehler nur aus Satz oder freigegebenem Kontext.
        - Ordne Satzteile logisch, ohne neue Fakten, Zahlen, Negationen, Termine, URLs, Identifier, Namen oder Absichten einzuführen.
        - Bleibe nicht bei Kommasetzung stehen: Wenn „gucken“ erkennbar „prüfen“ bedeutet, formuliere präzise. Wenn „alles, was komisch ist, rausgerufen“ erkennbar das Melden von Problemen meint, formuliere natürlich als „auf alle Auffälligkeiten hinweisen“.
        - Erhalte jede inhaltliche Teilaufgabe. Kürze weder die Prüfung der Formatierung noch den Hinweis auf Auffälligkeiten weg.
        - Vollständiges Reparaturbeispiel: „Normal und wenn wir wenn wir es normal testen dann kannst du auch gleich gucken ob die Formatierung korrekt aussieht und alles was irgendwie komisch ist rausgerufen wird.“ wird zu „Wenn wir es normal testen, kannst du gleichzeitig prüfen, ob die Formatierung korrekt ist, und auf alle Auffälligkeiten hinweisen.“
        - Nutze Kontextbegriffe nur für sichere Korrekturen nahe am lokalen Kandidaten. Wenn der Kandidat in einer Nachricht eindeutig auf „das Projekt“, „diese Aufgabe“ oder ein ähnliches Objekt verweist und der letzte sichtbare Verlauf dafür genau einen Namen nennt, ersetze den Rückbezug durch diesen exakten Namen. Beispiel: Kontext „Das Projekt heißt Nebelstern“, Kandidat „prüf das Projekt noch mal“ → „Prüfe Nebelstern erneut.“ Bei zwei möglichen Projekten bleibt es mehrdeutig.
        - usedContextTerms enthält ausschließlich Kontextbegriffe, die im Kandidaten noch nicht vorkamen und tatsächlich zur Ergänzung oder Korrektur verwendet wurden. Melde keine bereits gesprochenen Wörter wie „Projekt“ oder „Browser“. Ohne Kontextblock muss usedContextTerms leer sein.
        - Email: klare Absätze, aber keine erfundene Anrede oder Signatur.
        - Message: kurze natürliche Sätze ohne Überschrift. Nutze den letzten sichtbaren Gesprächskontext, um Pronomen, Rückbezüge oder unvollständige Satzteile nur dann zu ergänzen, wenn genau eine Deutung sicher gestützt ist. Eine eindeutig benannte Referenz soll dann ausdrücklich in den Zieltext übernommen werden.
        - Prose: flüssige Absätze; Listen nur bei einer im Diktat erkennbaren Aufzählung.
        - Wenn mehrere inhaltlich verschiedene Deutungen übrig bleiben, setze hasAmbiguity auf true und erfinde nichts. Eine durch das Reparaturbeispiel eindeutig gestützte Glättung ist nicht mehrdeutig und setzt hasAmbiguity auf false.
        """)
        return lines.joined(separator: "\n")
    }
}

@available(macOS 26.0, *)
@Generable
private struct FoundationModelsRewriteOutput {
    @Guide(description: "Der umgeschriebene deutsche Text ohne neue Fakten.")
    let rewrittenText: String

    @Guide(description: "Kontextbegriffe, die zur sicheren Rekonstruktion verwendet wurden.")
    let usedContextTerms: [String]

    @Guide(description: "True, wenn der lokale Kandidat mehrdeutig bleibt und nicht sicher ergänzt wurde.")
    let hasAmbiguity: Bool
}
#endif
