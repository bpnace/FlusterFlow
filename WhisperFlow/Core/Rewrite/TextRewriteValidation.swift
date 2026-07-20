import Foundation

enum TextRewriteValidationDecision: Equatable, Sendable {
    case accepted
    case rejected([TextRewriteValidationIssue])

    var issues: [TextRewriteValidationIssue] {
        switch self {
        case .accepted: []
        case .rejected(let issues): issues
        }
    }
}

protocol TextRewriteValidating: Sendable {
    func validate(
        request: TextRewriteRequest,
        proposedText: String
    ) -> TextRewriteValidationDecision
}

struct MeaningPreservationRewriteValidator: TextRewriteValidating {
    private let rules = ContextSupportedMeaningPreservationRules()

    func validate(
        request: TextRewriteRequest,
        proposedText: String
    ) -> TextRewriteValidationDecision {
        let result = rules.evaluate(
            localText: request.localCandidate.text,
            proposedText: proposedText,
            protectedContextTerms: request.context.protectedTerms
        )
        return result.accepts ? .accepted : .rejected(result.issues)
    }
}
