import Foundation
import XCTest
@testable import WhisperFlow

final class ContextTermExtractorTests: XCTestCase {
    func testCorpusTermsAreExtractedAndCorrectionsAreAmbiguitySafe() throws {
        let corpus: ContextCorpus = try decodeContextFixture("Context/wf-ctx-terms-1.json")
        let extractor = ContextTermExtractor()
        let corrector = ContextualTermCorrector()
        var positiveCount = 0
        var contextOffMatches = 0
        var contextOnMatches = 0
        var forcedAmbiguityCorrections = 0

        for fixture in corpus.fixtures {
            let terms = extractor.extract(from: fixture.boundedContext)
            let corrected = corrector.correct(fixture.contextOff.transcript, terms: terms)
            XCTAssertEqual(corrected, fixture.contextOn.expectedTranscript, fixture.id)
            if let target = fixture.gold.targetTerm {
                positiveCount += 1
                if fixture.contextOff.termMatch { contextOffMatches += 1 }
                if containsAcceptedVariant(corrected, fixture.gold.acceptedVariants) {
                    contextOnMatches += 1
                }
                XCTAssertTrue(terms.contains(target), "missing \(target): \(fixture.id)")
                for token in fixture.gold.nonTermTokens {
                    XCTAssertTrue(
                        corrected.localizedCaseInsensitiveContains(token),
                        "non-term regression '\(token)': \(fixture.id)"
                    )
                }
            } else if corrected != fixture.contextOff.transcript {
                forcedAmbiguityCorrections += 1
            }
        }

        let onAccuracy = Double(contextOnMatches) / Double(positiveCount)
        let improvement = Double(contextOnMatches - contextOffMatches) / Double(positiveCount)
        XCTAssertGreaterThanOrEqual(onAccuracy, 0.85)
        XCTAssertGreaterThanOrEqual(improvement, 0.15)
        XCTAssertEqual(forcedAmbiguityCorrections, 0)
    }

    func testExtractionIsBoundedUniqueAndExcludesSensitiveValues() {
        let generatedTerms = (1...40).map { "ProductTerm\($0)" }.joined(separator: " ")
        let sensitive = "alice@example.com https://private.example/Secret sk-test_1234567890123456 4111 1111 1111 1111"
        let terms = ContextTermExtractor().extract(from: "\(generatedTerms) \(sensitive)")

        XCTAssertEqual(terms.count, ContextTermExtractor.maximumTerms)
        XCTAssertEqual(Set(terms.map { $0.lowercased() }).count, terms.count)
        XCTAssertFalse(terms.contains { $0.localizedCaseInsensitiveContains("alice") })
        XCTAssertFalse(terms.contains { $0.localizedCaseInsensitiveContains("secret") })
        XCTAssertFalse(terms.contains { $0.localizedCaseInsensitiveContains("test_123") })
    }

    func testSelectionAndHighSignalTermsPrecedeRepeatedLowercaseAndPhrases() {
        let terms = ContextTermExtractor().extract(
            selection: "ChosenToken",
            nearbyContext: "the quasar appears twice: quasar. Neural Engine uses render_pipeline2."
        )

        XCTAssertEqual(terms.first, "ChosenToken")
        XCTAssertTrue(terms.contains("render_pipeline2"))
        XCTAssertTrue(terms.contains("quasar"))
        XCTAssertTrue(terms.contains("Neural Engine"))
        XCTAssertFalse(terms.contains { $0.caseInsensitiveCompare("the") == .orderedSame })
        XCTAssertLessThanOrEqual(terms.count, ContextTermExtractor.maximumTerms)
    }

    private func containsAcceptedVariant(_ text: String, _ variants: [String]) -> Bool {
        variants.contains { text.localizedCaseInsensitiveContains($0) }
    }
}

private struct ContextCorpus: Decodable {
    let fixtures: [ContextFixture]
}

private struct ContextFixture: Decodable {
    struct Transcript: Decodable {
        let transcript: String
        let termMatch: Bool
    }
    struct ExpectedTranscript: Decodable {
        let expectedTranscript: String
        let termMatch: Bool
    }
    struct Gold: Decodable {
        let targetTerm: String?
        let acceptedVariants: [String]
        let nonTermTokens: [String]
    }

    let id: String
    let boundedContext: String
    let gold: Gold
    let contextOff: Transcript
    let contextOn: ExpectedTranscript
}

private func decodeContextFixture<T: Decodable>(_ path: String) throws -> T {
    let data = try TestResourceLoader.data("Fixtures/\(path)")
    return try JSONDecoder().decode(T.self, from: data)
}
