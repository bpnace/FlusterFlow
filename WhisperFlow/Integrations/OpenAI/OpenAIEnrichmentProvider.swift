import Foundation

actor OpenAIEnrichmentProvider: CloudEnrichmentProviding {
    private let gate: CloudGate
    private let transport: any CloudTextTransport
    private let validator: any CloudMeaningValidating
    private let model: CloudModelIdentifier
    private let metadataResolver: CloudMetadataResolver
    private var requests: [DictationSessionID: Task<String, Error>] = [:]

    init(
        gate: CloudGate,
        transport: any CloudTextTransport,
        validator: any CloudMeaningValidating = ConservativeCloudMeaningValidator(),
        model: CloudModelIdentifier = .defaultEfficientModel,
        metadataResolver: @escaping CloudMetadataResolver = { context, _ in
            CloudRequestMetadata(language: .automatic, context: context)
        }
    ) {
        self.gate = gate
        self.transport = transport
        self.validator = validator
        self.model = model
        self.metadataResolver = metadataResolver
    }

    func enrich(
        _ candidate: LocalCandidate,
        context: ContextSnapshot,
        consent: ConsentSnapshot,
        sessionID: DictationSessionID
    ) async throws -> EnrichedCandidate {
        let decision = await gate.evaluate(consent: consent)
        guard case .authorized(let authorization) = decision else {
            return EnrichedCandidate(text: candidate.text)
        }

        let request = CloudEnrichmentRequest(
            localCandidate: candidate.text,
            metadata: metadataResolver(context, sessionID),
            context: authorization.includeContext && context.availability == .available
                ? context.boundedText
                : nil
        )
        let task = Task { [transport, model] in
            try await transport.enrich(
                request: request,
                apiKey: authorization.apiKey,
                model: model
            )
        }
        requests[sessionID]?.cancel()
        requests[sessionID] = task
        defer { requests[sessionID] = nil }

        do {
            let proposedText = try await task.value
            let referenceResolution = ContextReferenceResolver.resolve(
                localText: candidate.text,
                proposedText: proposedText,
                context: TextRewriteContext(context),
                targetFormat: Self.targetFormat(for: context.targetKind)
            )
            guard !Task.isCancelled,
                  validator.accepts(
                      localCandidate: candidate,
                      proposedText: referenceResolution.text,
                      protectedContextTerms: context.termHints
                        + referenceResolution.usedContextTerms
                  ) else {
                return EnrichedCandidate(text: candidate.text)
            }
            return EnrichedCandidate(text: referenceResolution.text)
        } catch {
            return EnrichedCandidate(text: candidate.text)
        }
    }

    func cancel(sessionID: DictationSessionID) {
        requests.removeValue(forKey: sessionID)?.cancel()
    }

    private static func targetFormat(for targetKind: TargetKind) -> TextRewriteTargetFormat {
        switch targetKind {
        case .email: .email
        case .chat: .message
        case .document, .unknown: .prose
        }
    }
}
