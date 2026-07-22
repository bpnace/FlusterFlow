import Foundation

actor FoundationModelsTextRewriter: TextRewriting, TextRewritePrewarming {
    let identifier: TextRewriterIdentifier = .appleFoundationModels

    private let model: any LocalRewriteModeling
    private let validator: any TextRewriteValidating
    private let sanitizer: FinalTextSanitizer
    private var requests: [DictationSessionID: Task<LocalRewriteModelResponse, Error>] = [:]

    init(
        model: any LocalRewriteModeling = FoundationModelsLocalRewriteModelFactory.make(),
        validator: any TextRewriteValidating = MeaningPreservationRewriteValidator(),
        sanitizer: FinalTextSanitizer = FinalTextSanitizer()
    ) {
        self.model = model
        self.validator = validator
        self.sanitizer = sanitizer
    }

    func rewrite(_ request: TextRewriteRequest) async -> TextRewriteResult {
        let originalText = request.localCandidate.text
        guard request.context.availability != .deniedSensitive else {
            return .unavailable(originalText: originalText, reason: .sensitiveContextDenied)
        }

        let availability = await model.availability(for: request.language)
        guard availability.isAvailable else {
            return .unavailable(
                originalText: originalText,
                reason: availability.unavailableReason ?? .modelUnavailable
            )
        }

        let task = Task { [model] in
            try await model.rewrite(request: request)
        }
        requests[request.sessionID]?.cancel()
        requests[request.sessionID] = task
        defer { requests[request.sessionID] = nil }

        do {
            let response = try await task.value
            guard !Task.isCancelled else {
                return .cancelled(originalText: originalText)
            }

            let sanitized = sanitizer.sanitize(response.rewrittenText)
            guard !sanitized.text.isEmpty else {
                return .failed(originalText: originalText, reason: .invalidModelOutput)
            }

            guard !response.hasAmbiguity else {
                return .rejected(
                    originalText: originalText,
                    issues: [.unknownMeaningChange],
                    sanitizerActionCount: sanitized.actionCount,
                    usedContextTermCount: 0,
                    hadAmbiguity: true
                )
            }
            guard Self.reportedTermsAreSupported(
                response.usedContextTerms,
                by: request
            ) else {
                return .failed(originalText: originalText, reason: .invalidModelOutput)
            }

            let referenceResolution = ContextReferenceResolver.resolve(
                localText: request.localCandidate.text,
                proposedText: sanitized.text,
                context: request.context,
                targetFormat: request.targetFormat
            )
            let rewrittenText = referenceResolution.text
            let actualContextTerms = Self.actualContextTerms(
                response.usedContextTerms + referenceResolution.usedContextTerms,
                in: request
            )
            let usedContextTermCount = actualContextTerms.count

            let validationRequest = Self.validationRequest(
                request,
                addingContextTerms: actualContextTerms
            )
            switch validator.validate(request: validationRequest, proposedText: rewrittenText) {
            case .accepted:
                return .accepted(
                    originalText: originalText,
                    rewrittenText: rewrittenText,
                    sanitizerActionCount: sanitized.actionCount,
                    usedContextTermCount: usedContextTermCount
                )
            case .rejected(let issues):
                return .rejected(
                    originalText: originalText,
                    issues: issues.isEmpty ? [.unknownMeaningChange] : issues,
                    sanitizerActionCount: sanitized.actionCount,
                    usedContextTermCount: usedContextTermCount
                )
            }
        } catch is CancellationError {
            return .cancelled(originalText: originalText)
        } catch LocalRewriteModelError.unavailable(let reason) {
            return .unavailable(originalText: originalText, reason: reason)
        } catch LocalRewriteModelError.invalidOutput {
            return .failed(originalText: originalText, reason: .invalidModelOutput)
        } catch {
            return .failed(originalText: originalText, reason: .generationFailed)
        }
    }

    func prewarm(_ request: TextRewritePrewarmRequest) async -> TextRewritePrewarmResult {
        guard request.context.availability != .deniedSensitive else {
            return .unavailable(.sensitiveContextDenied)
        }

        let availability = await model.availability(for: request.language)
        guard availability.isAvailable else {
            return .unavailable(availability.unavailableReason ?? .modelUnavailable)
        }

        do {
            try await model.prewarm(
                request: LocalRewriteModelPrewarmRequest(
                    sessionID: request.sessionID,
                    language: request.language,
                    context: request.context,
                    promptPrefix: request.promptPrefix
                )
            )
            return .warmed
        } catch LocalRewriteModelError.unavailable(let reason) {
            return .unavailable(reason)
        } catch LocalRewriteModelError.invalidOutput {
            return .failed(.invalidModelOutput)
        } catch {
            return .failed(.generationFailed)
        }
    }

    func cancel(sessionID: DictationSessionID) async {
        requests.removeValue(forKey: sessionID)?.cancel()
    }

    private static func reportedTermsAreSupported(
        _ terms: [String],
        by request: TextRewriteRequest
    ) -> Bool {
        guard !terms.isEmpty else { return true }
        guard terms.count <= 16 else { return false }
        let availableSources = request.context.protectedTerms
            + [request.context.boundedText ?? "", request.localCandidate.text]
        return terms.allSatisfy { term in
            let normalized = term.trimmingCharacters(in: .whitespacesAndNewlines)
            let wordCount = normalized.split(whereSeparator: { $0.isWhitespace }).count
            return !normalized.isEmpty
                && normalized.count <= 120
                && wordCount <= 12
                && availableSources.contains { source in
                source.range(
                    of: normalized,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) != nil
            }
        }
    }

    private static func actualContextTerms(
        _ terms: [String],
        in request: TextRewriteRequest
    ) -> [String] {
        let contextSources = request.context.protectedTerms
            + [request.context.boundedText ?? ""]
        var seen: Set<String> = []
        return terms.compactMap { term -> String? in
            let normalized = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty,
                  request.localCandidate.text.range(
                    of: normalized,
                    options: [.caseInsensitive, .diacriticInsensitive]
                  ) == nil,
                  contextSources.contains(where: { source in
                source.range(
                    of: normalized,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) != nil
            }) else {
                return nil
            }
            let key = normalized.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: nil
            )
            return seen.insert(key).inserted ? normalized : nil
        }
    }

    private static func validationRequest(
        _ request: TextRewriteRequest,
        addingContextTerms contextTerms: [String]
    ) -> TextRewriteRequest {
        guard !contextTerms.isEmpty else { return request }

        var seen: Set<String> = []
        let combinedTerms = (request.context.protectedTerms + contextTerms).filter { term in
            let key = term.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: nil
            )
            return seen.insert(key).inserted
        }
        return TextRewriteRequest(
            sessionID: request.sessionID,
            localCandidate: request.localCandidate,
            language: request.language,
            context: TextRewriteContext(
                category: request.context.category,
                availability: request.context.availability,
                boundedText: request.context.boundedText,
                protectedTerms: combinedTerms
            ),
            reconstructionPolicy: request.reconstructionPolicy,
            targetFormat: request.targetFormat
        )
    }
}

enum FoundationModelsLocalRewriteModelFactory {
    static func make() -> any LocalRewriteModeling {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return AppleFoundationModelsLocalRewriteModel()
        } else {
            return UnavailableLocalRewriteModel(reason: .operatingSystemUnsupported)
        }
        #else
        return UnavailableLocalRewriteModel(reason: .frameworkUnavailable)
        #endif
    }
}
