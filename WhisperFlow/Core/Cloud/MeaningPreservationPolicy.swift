import Foundation

struct MeaningPreservationPolicy: CloudMeaningValidating {
    private let rules = ContextSupportedMeaningPreservationRules()

    func accepts(
        localCandidate: LocalCandidate,
        proposedText: String,
        protectedContextTerms: [String]
    ) -> Bool {
        rules.evaluate(
            localText: localCandidate.text,
            proposedText: proposedText,
            protectedContextTerms: protectedContextTerms
        ).accepts
    }
}
