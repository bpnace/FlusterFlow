import XCTest
@testable import WhisperFlow

final class TextRewriteCoreTests: XCTestCase {
    func testContextSnapshotMappingUsesContentSafeCategoryAndDropsSensitiveText() {
        let context = ContextSnapshot(
            availability: .deniedSensitive,
            targetKind: .email,
            boundedText: "password field text",
            termHints: ["PROJECT-ORBIT"]
        )

        let rewriteContext = TextRewriteContext(context)

        XCTAssertEqual(rewriteContext.category, .email)
        XCTAssertEqual(rewriteContext.availability, .deniedSensitive)
        XCTAssertNil(rewriteContext.boundedText)
        XCTAssertEqual(rewriteContext.protectedTerms, ["PROJECT-ORBIT"])
    }

    func testMeaningValidatorRejectsLostAnchorsInventedClaimsContextLossAndLargeDeviation() {
        let validator = MeaningPreservationRewriteValidator()
        let request = makeRequest(
            text: "Bitte sende den Link https://example.com an Testperson Alpha für PROJECT-ORBIT nicht morgen.",
            protectedTerms: ["PROJECT-ORBIT"]
        )

        let lostAnchor = validator.validate(
            request: request,
            proposedText: "Bitte sende den Link https://evil.example an Testperson Alpha für PROJECT-ORBIT nicht morgen."
        )
        let inventedClaim = validator.validate(
            request: request,
            proposedText: "Bitte sende den Link https://example.com an Testperson Alpha und Testperson Beta für PROJECT-ORBIT nicht morgen."
        )
        let contextLoss = validator.validate(
            request: request,
            proposedText: "Bitte sende den Link https://example.com an Testperson Alpha nicht morgen."
        )
        let deviation = validator.validate(
            request: request,
            proposedText: "Alles ist erledigt."
        )

        XCTAssertEqual(lostAnchor.issues, [.lostProtectedAnchor])
        XCTAssertTrue(inventedClaim.issues.contains(.inventedClaim))
        XCTAssertTrue(contextLoss.issues.contains(.lostProtectedContextTerm))
        XCTAssertTrue(deviation.issues.contains(.excessiveDeviation))
    }

    func testRewriteRequestDefaultsUseContextSupportedPolicyAndTargetFormatting() {
        let email = makeRequest(
            text: "Bitte kurze Antwort.",
            context: TextRewriteContext(
                category: .email,
                availability: .available,
                boundedText: nil,
                protectedTerms: []
            )
        )
        let message = makeRequest(
            text: "Bitte kurze Antwort.",
            context: TextRewriteContext(
                category: .workMessaging,
                availability: .available,
                boundedText: nil,
                protectedTerms: []
            )
        )

        XCTAssertEqual(email.reconstructionPolicy, .contextSupportedReconstruction)
        XCTAssertEqual(email.targetFormat, .email)
        XCTAssertEqual(message.targetFormat, .message)
    }

    func testContextReferenceResolverUsesExactlyOneExplicitProjectName() {
        let resolution = ContextReferenceResolver.resolve(
            localText: "Ähm prüf das Projekt noch mal.",
            proposedText: "Prüfe das Projekt erneut.",
            context: TextRewriteContext(
                category: .workMessaging,
                availability: .available,
                boundedText: "Nutzer: Das Projekt heißt Nebelstern und bleibt vollständig lokal.",
                protectedTerms: []
            ),
            targetFormat: .message
        )

        XCTAssertEqual(resolution.text, "Prüfe Nebelstern erneut.")
        XCTAssertEqual(resolution.usedContextTerms, ["Nebelstern"])
    }

    func testContextReferenceResolverDoesNotChooseBetweenTwoProjectNames() {
        let resolution = ContextReferenceResolver.resolve(
            localText: "Ähm prüf das Projekt noch mal.",
            proposedText: "Prüfe das Projekt erneut.",
            context: TextRewriteContext(
                category: .workMessaging,
                availability: .available,
                boundedText: "Das Projekt heißt Nebelstern. Das Projekt heißt Nebelstirn.",
                protectedTerms: []
            ),
            targetFormat: .message
        )

        XCTAssertEqual(resolution.text, "Prüfe das Projekt erneut.")
        XCTAssertTrue(resolution.usedContextTerms.isEmpty)
    }

    func testMeaningValidatorAcceptsFillerRemovalReorderingSynonymsAndContextNearCorrection() {
        let validator = MeaningPreservationRewriteValidator()
        let request = makeRequest(
            text: "Normal und wenn wir wenn wir morgen projectorbit besprechen dann schick Link https://example.com",
            protectedTerms: ["PROJECT-ORBIT"]
        )

        let decision = validator.validate(
            request: request,
            proposedText: "Wenn wir morgen PROJECT-ORBIT besprechen, schick den Link https://example.com."
        )
        let synonymDecision = validator.validate(
            request: makeRequest(text: "Send report to Anna."),
            proposedText: "Sende den Bericht an Anna."
        )

        XCTAssertEqual(decision, .accepted)
        XCTAssertEqual(synonymDecision, .accepted)
    }

    func testMeaningValidatorAcceptsLogicalReconstructionOfReportedNormalModeSentence() {
        let validator = MeaningPreservationRewriteValidator()
        let source = "Normal und wenn wir wenn wir es normal testen dann kannst du auch gleich gucken ob die Formatierung korrekt aussieht und alles was irgendwie komisch ist rausgerufen wird."
        let expected = "Wenn wir es normal testen, kannst du gleichzeitig prüfen, ob die Formatierung korrekt ist, und auf alle Auffälligkeiten hinweisen."

        let decision = validator.validate(
            request: makeRequest(text: source),
            proposedText: expected
        )

        XCTAssertEqual(decision, .accepted)
    }

    func testMeaningValidatorAcceptsFillerHeavyAppleParaphraseWithUniqueContextName() {
        let validator = MeaningPreservationRewriteValidator()
        let source = "Ähm also das ähm mit dem Projekt also prüf das noch mal im Browser und sag, wenn was komisch ist."
        let proposed = "Prüfe Nebelstern im Browser und lass mich wissen, wenn etwas komisch ist."

        let decision = validator.validate(
            request: makeRequest(
                text: source,
                context: TextRewriteContext(
                    category: .workMessaging,
                    availability: .available,
                    boundedText: "Das Projekt heißt Nebelstern.",
                    protectedTerms: ["Nebelstern"]
                )
            ),
            proposedText: proposed
        )

        XCTAssertEqual(decision, .accepted)
    }

    func testMeaningValidatorRejectsNewNumbersNegationsURLsIDsAndClaims() {
        let validator = MeaningPreservationRewriteValidator()
        let request = makeRequest(
            text: "Schick verifyTargetToken an Anna mit Link https://example.com.",
            protectedTerms: ["PROJECT-ORBIT"]
        )

        let newNumber = validator.validate(
            request: request,
            proposedText: "Schick verifyTargetToken an Anna mit Link https://example.com um 14 Uhr."
        )
        let newNegation = validator.validate(
            request: request,
            proposedText: "Schick verifyTargetToken nicht an Anna mit Link https://example.com."
        )
        let changedURL = validator.validate(
            request: request,
            proposedText: "Schick verifyTargetToken an Anna mit Link https://evil.example."
        )
        let changedID = validator.validate(
            request: request,
            proposedText: "Schick verifyTargetTaken an Anna mit Link https://example.com."
        )
        let newClaim = validator.validate(
            request: request,
            proposedText: "Schick verifyTargetToken an Anna mit Link https://example.com. Sie hat alles freigegeben."
        )
        let appendedMeta = validator.validate(
            request: makeRequest(
                text: "OK, testen wir noch einmal, ob es funktioniert. Versuch mal, jetzt diesen Text einzusetzen und dann gucken wir, ob alles klappt wie es soll."
            ),
            proposedText: "OK, testen wir noch einmal, ob es funktioniert. Versuch mal, jetzt diesen Text einzusetzen und dann gucken wir, ob alles klappt wie es soll. Ich habe das jetzt. Schaut."
        )

        XCTAssertTrue(newNumber.issues.contains(.lostProtectedAnchor))
        XCTAssertTrue(newNegation.issues.contains(.lostProtectedAnchor))
        XCTAssertTrue(changedURL.issues.contains(.lostProtectedAnchor))
        XCTAssertTrue(changedID.issues.contains(.lostProtectedAnchor))
        XCTAssertTrue(newClaim.issues.contains(.inventedClaim))
        XCTAssertTrue(appendedMeta.issues.contains(.inventedClaim))
    }

    func testMeaningValidatorProtectsNamesButAllowsContextSupportedSpellingRepair() {
        let validator = MeaningPreservationRewriteValidator()

        let changedName = validator.validate(
            request: makeRequest(text: "Schick den Bericht an Anna nicht."),
            proposedText: "Schick den Bericht an Anne nicht."
        )
        let contextRepair = validator.validate(
            request: makeRequest(
                text: "Schick den Bericht an Ana.",
                protectedTerms: ["Anna"]
            ),
            proposedText: "Schick den Bericht an Anna."
        )
        let inventedSingleName = validator.validate(
            request: makeRequest(text: "Schick den Bericht an Anna nicht."),
            proposedText: "Schick den Bericht an Anna und Maria nicht."
        )

        XCTAssertTrue(changedName.issues.contains(.lostProtectedAnchor))
        XCTAssertEqual(contextRepair, .accepted)
        XCTAssertTrue(inventedSingleName.issues.contains(.inventedClaim))
    }

    func testFinalTextSanitizerRemovesJSONMarkdownWhitespaceAndDuplicatePunctuation() {
        let sanitized = FinalTextSanitizer.sanitize("""
        ```json
        {"text":"  **Hallo   Welt!!**  "}
        ```
        """)

        XCTAssertEqual(sanitized.text, "Hallo Welt!")
        XCTAssertGreaterThanOrEqual(sanitized.actionCount, 3)
    }

    func testFinalTextSanitizerPreservesIntentionalParagraphsAndLists() {
        let sanitized = FinalTextSanitizer.sanitize("""
          Erster Absatz.



          Zweiter Absatz:
          - Erster Punkt
          - Zweiter Punkt!!
        """)

        XCTAssertEqual(
            sanitized.text,
            "Erster Absatz.\n\nZweiter Absatz:\n- Erster Punkt\n- Zweiter Punkt!"
        )
        XCTAssertGreaterThan(sanitized.actionCount, 0)
    }

    func testFoundationModelsRewriterReportsDeterministicUnavailableWithoutCallingModel() async {
        let model = RecordingRewriteModel(
            availability: .unavailable(.frameworkUnavailable),
            response: .success(LocalRewriteModelResponse(rewrittenText: "Remote"))
        )
        let rewriter = FoundationModelsTextRewriter(model: model)

        let result = await rewriter.rewrite(makeRequest(text: "Lokaler Text"))
        let calls = await model.rewriteCallCount()

        XCTAssertEqual(result.outcome, .unavailable)
        XCTAssertEqual(result.unavailableReason, .frameworkUnavailable)
        XCTAssertEqual(result.outputText, "Lokaler Text")
        XCTAssertEqual(calls, 0)
    }

    func testFoundationModelsRewriterAcceptsValidatedFakeModelOutput() async {
        let model = RecordingRewriteModel(
            availability: .available,
            response: .success(LocalRewriteModelResponse(rewrittenText: "Bitte sende den Bericht heute."))
        )
        let rewriter = FoundationModelsTextRewriter(model: model)

        let result = await rewriter.rewrite(makeRequest(text: "Bitte sende Bericht heute."))

        XCTAssertEqual(result.outcome, .accepted)
        XCTAssertEqual(result.outputText, "Bitte sende den Bericht heute.")
    }

    func testFoundationModelsRewriterProducesExpectedLogicalNormalModeRegression() async {
        let source = "Normal und wenn wir wenn wir es normal testen dann kannst du auch gleich gucken ob die Formatierung korrekt aussieht und alles was irgendwie komisch ist rausgerufen wird."
        let expected = "Wenn wir es normal testen, kannst du gleichzeitig prüfen, ob die Formatierung korrekt ist, und auf alle Auffälligkeiten hinweisen."
        let model = RecordingRewriteModel(
            availability: .available,
            response: .success(LocalRewriteModelResponse(rewrittenText: expected))
        )
        let rewriter = FoundationModelsTextRewriter(model: model)

        let result = await rewriter.rewrite(
            makeRequest(
                text: source,
                context: TextRewriteContext(
                    category: .personalMessaging,
                    availability: .available,
                    boundedText: nil,
                    protectedTerms: []
                )
            )
        )

        XCTAssertEqual(result.outcome, .accepted, "issues=\(result.validationIssues)")
        XCTAssertEqual(result.outputText, expected, "issues=\(result.validationIssues)")
    }

    func testFoundationModelsRewriterAcceptsUniqueContextSupportedReconstructionForFillerHeavyChat() async {
        let source = "Ähm also das ähm mit dem Projekt also prüf das noch mal im Browser und sag, wenn was komisch ist."
        let expected = "Prüfe das Projekt Nebelstern erneut im Browser und weise auf Auffälligkeiten hin."
        let model = RecordingRewriteModel(
            availability: .available,
            response: .success(
                LocalRewriteModelResponse(
                    rewrittenText: expected,
                    usedContextTerms: ["Nebelstern"]
                )
            )
        )
        let rewriter = FoundationModelsTextRewriter(model: model)

        let result = await rewriter.rewrite(
            makeRequest(
                text: source,
                context: TextRewriteContext(
                    category: .workMessaging,
                    availability: .available,
                    boundedText: """
                    Nutzer: Das Projekt heißt Nebelstern und bleibt vollständig lokal.
                    Assistent: Als Nächstes soll die Kontextprüfung im Browser getestet werden.
                    """,
                    protectedTerms: []
                )
            )
        )

        XCTAssertEqual(result.outcome, .accepted, "issues=\(result.validationIssues)")
        XCTAssertEqual(result.outputText, expected, "issues=\(result.validationIssues)")
        XCTAssertEqual(result.usedContextTermCount, 1)
        XCTAssertFalse(result.outputText.localizedCaseInsensitiveContains("ähm"))
        XCTAssertFalse(result.outputText.localizedCaseInsensitiveContains("also"))
    }

    func testFoundationModelsRewriterDoesNotGuessBetweenAmbiguousChatContextTerms() async {
        let source = "Ähm prüf das Projekt noch mal."
        let model = RecordingRewriteModel(
            availability: .available,
            response: .success(
                LocalRewriteModelResponse(
                    rewrittenText: "Prüfe Nebelstern erneut.",
                    usedContextTerms: ["Nebelstern"],
                    hasAmbiguity: true
                )
            )
        )
        let rewriter = FoundationModelsTextRewriter(model: model)

        let result = await rewriter.rewrite(
            makeRequest(
                text: source,
                context: TextRewriteContext(
                    category: .workMessaging,
                    availability: .available,
                    boundedText: "Nebelstern und Nebelstirn sind zwei verschiedene Projekte.",
                    protectedTerms: []
                )
            )
        )

        XCTAssertEqual(result.outcome, .rejected)
        XCTAssertEqual(result.outputText, source)
        XCTAssertEqual(result.validationIssues, [.unknownMeaningChange])
        XCTAssertTrue(result.hadAmbiguity)
    }

    func testFoundationModelsRewriterRejectsContextOnlyNumberAndNegationInvention() async {
        let source = "Ähm prüf das Projekt noch mal."
        let model = RecordingRewriteModel(
            availability: .available,
            response: .success(
                LocalRewriteModelResponse(
                    rewrittenText: "Prüfe das Projekt am Freitag mit Version 3 und lade es nicht hoch.",
                    usedContextTerms: ["Freitag", "Version 3", "nicht hochladen"]
                )
            )
        )
        let rewriter = FoundationModelsTextRewriter(model: model)

        let result = await rewriter.rewrite(
            makeRequest(
                text: source,
                context: TextRewriteContext(
                    category: .workMessaging,
                    availability: .available,
                    boundedText: "Termin Freitag, Version 3, nicht hochladen.",
                    protectedTerms: []
                )
            )
        )

        XCTAssertEqual(result.outcome, .rejected)
        XCTAssertEqual(result.outputText, source)
        XCTAssertTrue(result.validationIssues.contains(.lostProtectedAnchor))

        let spokenSource = "OK, testen wir noch einmal, ob es funktioniert. Versuch mal, jetzt diesen Text einzusetzen und dann gucken wir, ob alles klappt wie es soll."
        let hallucinatingModel = RecordingRewriteModel(
            availability: .available,
            response: .success(
                LocalRewriteModelResponse(
                    rewrittenText: "\(spokenSource) Ich habe das jetzt. Schaut."
                )
            )
        )
        let hallucinationRewriter = FoundationModelsTextRewriter(model: hallucinatingModel)

        let hallucinationResult = await hallucinationRewriter.rewrite(
            makeRequest(text: spokenSource)
        )

        XCTAssertEqual(hallucinationResult.outcome, .rejected)
        XCTAssertEqual(hallucinationResult.outputText, spokenSource)
        XCTAssertTrue(hallucinationResult.validationIssues.contains(.inventedClaim))
    }

    func testLogicalRegressionHasCleanChatEmailAndDocumentEndFormatting() async {
        let source = "Normal und wenn wir wenn wir es normal testen dann kannst du auch gleich gucken ob die Formatierung korrekt aussieht und alles was irgendwie komisch ist rausgerufen wird."
        let expected = "Wenn wir es normal testen, kannst du gleichzeitig prüfen, ob die Formatierung korrekt ist, und auf alle Auffälligkeiten hinweisen."

        for category in [
            TextRewriteContextCategory.personalMessaging,
            .email,
            .other
        ] {
            let model = RecordingRewriteModel(
                availability: .available,
                response: .success(
                    LocalRewriteModelResponse(
                        rewrittenText: "```markdown\n\(expected)\n```"
                    )
                )
            )
            let rewriter = FoundationModelsTextRewriter(model: model)
            let result = await rewriter.rewrite(
                makeRequest(
                    text: source,
                    context: TextRewriteContext(
                        category: category,
                        availability: .available,
                        boundedText: nil,
                        protectedTerms: []
                    )
                )
            )

            XCTAssertEqual(result.outcome, .accepted, category.rawValue)
            XCTAssertEqual(result.outputText, expected, category.rawValue)
            XCTAssertFalse(result.outputText.contains("#"), category.rawValue)
            XCTAssertFalse(result.outputText.contains("```"), category.rawValue)
            XCTAssertEqual(result.outputText.components(separatedBy: "\n\n").count, 1)
        }
    }

    func testFoundationModelsRewriterSanitizesModelOutputBeforeValidation() async {
        let model = RecordingRewriteModel(
            availability: .available,
            response: .success(LocalRewriteModelResponse(rewrittenText: """
            ```markdown
            Bitte   sende den Bericht heute!!
            ```
            """))
        )
        let rewriter = FoundationModelsTextRewriter(model: model)

        let result = await rewriter.rewrite(makeRequest(text: "Bitte sende Bericht heute."))

        XCTAssertEqual(result.outcome, .accepted)
        XCTAssertEqual(result.outputText, "Bitte sende den Bericht heute!")
        XCTAssertGreaterThan(result.sanitizerActionCount, 0)
    }

    func testFoundationModelsRewriterFallsBackWhenModelReportsAmbiguity() async {
        let model = RecordingRewriteModel(
            availability: .available,
            response: .success(
                LocalRewriteModelResponse(
                    rewrittenText: "Vielleicht ist morgen gemeint.",
                    usedContextTerms: ["morgen"],
                    hasAmbiguity: true
                )
            )
        )
        let rewriter = FoundationModelsTextRewriter(model: model)

        let result = await rewriter.rewrite(makeRequest(text: "Morgen vielleicht."))

        XCTAssertEqual(result.outcome, .rejected)
        XCTAssertEqual(result.outputText, "Morgen vielleicht.")
        XCTAssertEqual(result.validationIssues, [.unknownMeaningChange])
        XCTAssertTrue(result.hadAmbiguity)
    }

    func testFoundationModelsRewriterRejectsUnreportedContextInjectionMetadata() async {
        let model = RecordingRewriteModel(
            availability: .available,
            response: .success(
                LocalRewriteModelResponse(
                    rewrittenText: "Bitte sende den Bericht heute.",
                    usedContextTerms: ["GeheimesProjekt"]
                )
            )
        )
        let rewriter = FoundationModelsTextRewriter(model: model)

        let result = await rewriter.rewrite(makeRequest(text: "Bitte sende Bericht heute."))

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(result.failureReason, .invalidModelOutput)
        XCTAssertEqual(result.outputText, "Bitte sende Bericht heute.")
    }

    func testFoundationModelsRewriterPrewarmsAvailableFakeModel() async {
        let model = RecordingRewriteModel(
            availability: .available,
            response: .success(LocalRewriteModelResponse(rewrittenText: "Lokaler Text"))
        )
        let rewriter = FoundationModelsTextRewriter(model: model)

        let result = await rewriter.prewarm(
            TextRewritePrewarmRequest(
                sessionID: DictationSessionID(rawValue: 77),
                language: .german,
                context: TextRewriteContext(
                    category: .personalMessaging,
                    availability: .available,
                    boundedText: nil,
                    protectedTerms: []
                ),
                promptPrefix: "Bitte"
            )
        )
        let prewarmCalls = await model.prewarmCallCount()
        let prewarmRequests = await model.prewarmRequestsSnapshot()

        XCTAssertEqual(result, .warmed)
        XCTAssertEqual(prewarmCalls, 1)
        XCTAssertEqual(prewarmRequests.map(\.sessionID), [DictationSessionID(rawValue: 77)])
    }

    func testFoundationModelsRewriterFallsBackWhenValidationRejectsModelOutput() async {
        let model = RecordingRewriteModel(
            availability: .available,
            response: .success(LocalRewriteModelResponse(rewrittenText: "Bitte sende den Bericht heute."))
        )
        let rewriter = FoundationModelsTextRewriter(model: model)

        let result = await rewriter.rewrite(makeRequest(text: "Bitte sende den Bericht heute nicht."))

        XCTAssertEqual(result.outcome, .rejected)
        XCTAssertEqual(result.outputText, "Bitte sende den Bericht heute nicht.")
        XCTAssertTrue(result.validationIssues.contains(.lostProtectedAnchor))
    }

    func testInstalledAppleFoundationModelPrewarmsGermanWhenExplicitlyRequested() async throws {
        guard ProcessInfo.processInfo.environment[
            "FLUSTERFLOW_RUN_APPLE_REWRITER_SMOKE"
        ] == "1" else {
            throw XCTSkip(
                "Set FLUSTERFLOW_RUN_APPLE_REWRITER_SMOKE=1 for the on-device Foundation Models smoke test"
            )
        }
        let rewriter = FoundationModelsTextRewriter()

        let result = await rewriter.prewarm(
            TextRewritePrewarmRequest(
                sessionID: DictationSessionID(rawValue: 9_004),
                language: .german,
                context: TextRewriteContext(
                    category: .other,
                    availability: .available,
                    boundedText: nil,
                    protectedTerms: ["FlusterFlow"]
                ),
                promptPrefix: "FlusterFlow"
            )
        )

        XCTAssertEqual(result, .warmed)
    }

    func testInstalledAppleFoundationModelRewritesExampleSentenceWhenExplicitlyRequested() async throws {
        guard ProcessInfo.processInfo.environment[
            "FLUSTERFLOW_RUN_APPLE_REWRITER_SMOKE"
        ] == "1" else {
            throw XCTSkip(
                "Set FLUSTERFLOW_RUN_APPLE_REWRITER_SMOKE=1 for the on-device Foundation Models smoke test"
            )
        }
        let source = "Normal und wenn wir wenn wir es normal testen dann kannst du auch gleich gucken ob die Formatierung korrekt aussieht und alles was irgendwie komisch ist rausgerufen wird."
        let request = makeRequest(
            text: source,
            context: TextRewriteContext(
                category: .personalMessaging,
                availability: .available,
                boundedText: nil,
                protectedTerms: []
            )
        )

        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Foundation Models requires macOS 26")
        }
        let installedModel = AppleFoundationModelsLocalRewriteModel()
        let availability = await installedModel.availability(for: .german)
        guard availability.isAvailable else {
            throw XCTSkip("Foundation Models rewriter is unavailable on this machine")
        }
        try await installedModel.prewarm(
            request: LocalRewriteModelPrewarmRequest(
                sessionID: request.sessionID,
                language: request.language,
                context: request.context,
                promptPrefix: "Sprache: Deutsch"
            )
        )
        let response = try await installedModel.rewrite(request: request)
        let rewriter = FoundationModelsTextRewriter(
            model: RecordingRewriteModel(
                availability: .available,
                response: .success(response)
            )
        )
        let result = await rewriter.rewrite(request)
        let diagnostic = "raw=\(response.rewrittenText) context=\(response.usedContextTerms) ambiguity=\(response.hasAmbiguity) issues=\(result.validationIssues)"
        #else
        throw XCTSkip("Foundation Models framework is not linked")
        #endif

        let output = result.outputText
        XCTAssertEqual(result.outcome, .accepted, diagnostic)
        XCTAssertFalse(output.localizedCaseInsensitiveContains("Normal und"), diagnostic)
        XCTAssertFalse(output.localizedCaseInsensitiveContains("wenn wir wenn wir"), diagnostic)
        XCTAssertTrue(output.localizedCaseInsensitiveContains("normal testen"), diagnostic)
        XCTAssertTrue(output.localizedCaseInsensitiveContains("formatierung"), diagnostic)
        XCTAssertTrue(
            ["prüfen", "kontrollieren", "ansehen"].contains {
                output.localizedCaseInsensitiveContains($0)
            },
            diagnostic
        )
        XCTAssertTrue(
            ["auffäll", "hinweis", "anmerk", "benenn"].contains {
                output.localizedCaseInsensitiveContains($0)
            },
            diagnostic
        )
        XCTAssertFalse(output.contains("**"), diagnostic)
        XCTAssertFalse(output.contains("```"), diagnostic)
        XCTAssertLessThanOrEqual(output.components(separatedBy: "\n\n").count, 2, diagnostic)
    }

    func testInstalledAppleFoundationModelUsesUniqueVisibleChatContextWhenExplicitlyRequested() async throws {
        guard ProcessInfo.processInfo.environment[
            "FLUSTERFLOW_RUN_APPLE_REWRITER_SMOKE"
        ] == "1" else {
            throw XCTSkip(
                "Set FLUSTERFLOW_RUN_APPLE_REWRITER_SMOKE=1 for the on-device Foundation Models smoke test"
            )
        }
        let source = "Ähm also das ähm mit dem Projekt also prüf das noch mal im Browser und sag, wenn was komisch ist."
        let request = makeRequest(
            text: source,
            context: TextRewriteContext(
                category: .workMessaging,
                availability: .available,
                boundedText: """
                Nutzer: Das Projekt heißt Nebelstern und bleibt vollständig lokal.
                Assistent: Als Nächstes soll die Kontextprüfung im Browser getestet werden.
                """,
                protectedTerms: []
            )
        )

        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Foundation Models requires macOS 26")
        }
        let installedModel = AppleFoundationModelsLocalRewriteModel()
        let availability = await installedModel.availability(for: .german)
        guard availability.isAvailable else {
            throw XCTSkip("Foundation Models rewriter is unavailable on this machine")
        }
        try await installedModel.prewarm(
            request: LocalRewriteModelPrewarmRequest(
                sessionID: request.sessionID,
                language: request.language,
                context: request.context,
                promptPrefix: "Sprache: Deutsch"
            )
        )
        let response = try await installedModel.rewrite(request: request)
        let rewriter = FoundationModelsTextRewriter(
            model: RecordingRewriteModel(
                availability: .available,
                response: .success(response)
            )
        )
        let result = await rewriter.rewrite(request)
        let diagnostic = "raw=\(response.rewrittenText) context=\(response.usedContextTerms) ambiguity=\(response.hasAmbiguity) issues=\(result.validationIssues)"
        #else
        throw XCTSkip("Foundation Models framework is not linked")
        #endif

        let output = result.outputText
        XCTAssertEqual(result.outcome, .accepted, diagnostic)
        XCTAssertTrue(output.localizedCaseInsensitiveContains("Nebelstern"), diagnostic)
        XCTAssertTrue(output.localizedCaseInsensitiveContains("Browser"), diagnostic)
        XCTAssertFalse(output.localizedCaseInsensitiveContains("ähm"), diagnostic)
        XCTAssertFalse(output.localizedCaseInsensitiveContains("also"), diagnostic)
        XCTAssertTrue(
            ["auffäll", "komisch", "problem", "hinweis"].contains {
                output.localizedCaseInsensitiveContains($0)
            },
            diagnostic
        )
        XCTAssertFalse(output.contains("**"), diagnostic)
        XCTAssertFalse(output.contains("```"), diagnostic)
    }

    private func makeRequest(
        text: String,
        protectedTerms: [String] = [],
        context: TextRewriteContext? = nil
    ) -> TextRewriteRequest {
        TextRewriteRequest(
            sessionID: DictationSessionID(rawValue: 42),
            localCandidate: LocalCandidate(text: text),
            language: .german,
            context: context ?? TextRewriteContext(
                category: .other,
                availability: .available,
                boundedText: nil,
                protectedTerms: protectedTerms
            )
        )
    }
}

private actor RecordingRewriteModel: LocalRewriteModeling {
    private let availabilityResult: LocalRewriteAvailability
    private let response: RecordingRewriteResponse
    private var calls = 0
    private var prewarmCalls = 0
    private var prewarmRequests: [LocalRewriteModelPrewarmRequest] = []

    init(
        availability: LocalRewriteAvailability,
        response: RecordingRewriteResponse
    ) {
        availabilityResult = availability
        self.response = response
    }

    func availability(for language: TextRewriteLanguage) async -> LocalRewriteAvailability {
        availabilityResult
    }

    func rewrite(request: TextRewriteRequest) async throws -> LocalRewriteModelResponse {
        calls += 1
        switch response {
        case .success(let response): return response
        case .failure(let error): throw error
        }
    }

    func prewarm(request: LocalRewriteModelPrewarmRequest) async throws {
        prewarmCalls += 1
        prewarmRequests.append(request)
        let availability = await availability(for: request.language)
        guard availability.isAvailable else {
            throw LocalRewriteModelError.unavailable(
                availability.unavailableReason ?? .modelUnavailable
            )
        }
    }

    func rewriteCallCount() -> Int {
        calls
    }

    func prewarmCallCount() -> Int {
        prewarmCalls
    }

    func prewarmRequestsSnapshot() -> [LocalRewriteModelPrewarmRequest] {
        prewarmRequests
    }
}

private enum RecordingRewriteResponse: Sendable {
    case success(LocalRewriteModelResponse)
    case failure(LocalRewriteModelError)
}
