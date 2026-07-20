import Foundation
import XCTest
@testable import WhisperFlow

final class MeaningPreservationPolicyTests: XCTestCase {
    func testGoldenCloudCorpusAcceptsBenignAndRejectsHighRiskChanges() throws {
        let corpus: CloudCorpus = try decodeCloudFixture("Cloud/wf-cloud-1.json")
        let policy = MeaningPreservationPolicy()
        let extractor = ContextTermExtractor()

        for fixture in corpus.fixtures where fixture.category == "highRisk" || fixture.category == "benign" {
            guard fixture.provider.kind == "response", let proposed = fixture.provider.text else { continue }
            let terms = fixture.request.context.map(extractor.extract(from:)) ?? []
            let accepted = policy.accepts(
                localCandidate: LocalCandidate(text: fixture.request.localCandidate),
                proposedText: proposed,
                protectedContextTerms: terms
            )
            XCTAssertEqual(accepted, fixture.category == "benign", fixture.id)
        }
    }

    func testProtectsURLsEmailsMentionsHashtagsIdentifiersAndQuotedLiterals() {
        let policy = MeaningPreservationPolicy()
        let local = LocalCandidate(
            text: #"Send verifyTargetToken to robot@example.com via https://example.com for @nova #release with “local only”."#
        )
        let changes = [
            #"Send verifyTargetTaken to robot@example.com via https://example.com for @nova #release with “local only”."#,
            #"Send verifyTargetToken to human@example.com via https://example.com for @nova #release with “local only”."#,
            #"Send verifyTargetToken to robot@example.com via https://evil.example for @nova #release with “local only”."#,
            #"Send verifyTargetToken to robot@example.com via https://example.com for @luna #release with “local only”."#,
            #"Send verifyTargetToken to robot@example.com via https://example.com for @nova #beta with “local only”."#,
            #"Send verifyTargetToken to robot@example.com via https://example.com for @nova #release with “cloud only”."#
        ]
        for proposed in changes {
            XCTAssertFalse(
                policy.accepts(
                    localCandidate: local,
                    proposedText: proposed,
                    protectedContextTerms: []
                ),
                proposed
            )
        }
    }

    func testAcceptsClauseReorderingSynonymsAndContextNearCorrections() {
        let policy = MeaningPreservationPolicy()

        XCTAssertTrue(policy.accepts(
            localCandidate: LocalCandidate(
                text: "Normal und wenn wir wenn wir morgen projectorbit besprechen dann schick Link https://example.com"
            ),
            proposedText: "Wenn wir morgen PROJECT-ORBIT besprechen, schick den Link https://example.com.",
            protectedContextTerms: ["PROJECT-ORBIT"]
        ))
        XCTAssertTrue(policy.accepts(
            localCandidate: LocalCandidate(text: "Send report to Anna."),
            proposedText: "Sende den Bericht an Anna.",
            protectedContextTerms: []
        ))
    }

    func testRejectsNewNumbersNegationsURLsIdentifiersAndUnsupportedClaims() {
        let policy = MeaningPreservationPolicy()
        let local = LocalCandidate(
            text: "Send verifyTargetToken to robot@example.com via https://example.com for @nova #release."
        )
        let rejected = [
            "Send verifyTargetToken to robot@example.com via https://example.com for @nova #release at 14:00.",
            "Do not send verifyTargetToken to robot@example.com via https://example.com for @nova #release.",
            "Send verifyTargetToken to robot@example.com via https://evil.example for @nova #release.",
            "Send verifyTargetTaken to robot@example.com via https://example.com for @nova #release.",
            "Send verifyTargetToken to robot@example.com via https://example.com for @nova #release. The customer approved it."
        ]

        for proposed in rejected {
            XCTAssertFalse(
                policy.accepts(
                    localCandidate: local,
                    proposedText: proposed,
                    protectedContextTerms: []
                ),
                proposed
            )
        }
    }
}

private struct CloudCorpus: Decodable {
    let fixtures: [CloudFixture]
}

private struct CloudFixture: Decodable {
    struct Request: Decodable {
        let localCandidate: String
        let context: String?
    }
    struct Provider: Decodable {
        let kind: String
        let text: String?
    }

    let id: String
    let category: String
    let request: Request
    let provider: Provider
}

private func decodeCloudFixture<T: Decodable>(_ path: String) throws -> T {
    let data = try TestResourceLoader.data("Fixtures/\(path)")
    return try JSONDecoder().decode(T.self, from: data)
}
