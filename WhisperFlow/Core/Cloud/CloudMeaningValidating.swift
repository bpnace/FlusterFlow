import Foundation

protocol CloudMeaningValidating: Sendable {
    func accepts(
        localCandidate: LocalCandidate,
        proposedText: String,
        protectedContextTerms: [String]
    ) -> Bool
}

struct ConservativeCloudMeaningValidator: CloudMeaningValidating {
    func accepts(
        localCandidate: LocalCandidate,
        proposedText: String,
        protectedContextTerms: [String]
    ) -> Bool {
        proposedText == localCandidate.text
    }
}
