import XCTest
@testable import WhisperFlow

final class OpenAICloudGateTests: XCTestCase, @unchecked Sendable {
    func testCloudDisabledNeverAuthorizesEvenWithStoredKey() async throws {
        let store = TestAPIKeyStore(key: try SecretAPIKey("sk-test"))
        let gate = CloudGate(keyStore: store)

        let decision = await gate.evaluate(consent: .localOnly)

        guard case .localOnly(.cloudDisabled) = decision else {
            return XCTFail("Expected local-only disabled decision")
        }
    }

    func testCloudEnabledWithoutKeyFailsClosed() async {
        let gate = CloudGate(keyStore: TestAPIKeyStore(key: nil))

        let decision = await gate.evaluate(
            consent: ConsentSnapshot(cloudEnabled: true, contextToCloud: true)
        )

        guard case .localOnly(.missingKey) = decision else {
            return XCTFail("Expected missing-key decision")
        }
    }

    func testContextRequiresIndependentConsent() async throws {
        let gate = CloudGate(keyStore: TestAPIKeyStore(key: try SecretAPIKey("sk-test")))

        let withoutContext = await gate.evaluate(
            consent: ConsentSnapshot(cloudEnabled: true, contextToCloud: false)
        )
        let withContext = await gate.evaluate(
            consent: ConsentSnapshot(cloudEnabled: true, contextToCloud: true)
        )

        guard case .authorized(let first) = withoutContext,
              case .authorized(let second) = withContext else {
            return XCTFail("Expected authorization")
        }
        XCTAssertFalse(first.includeContext)
        XCTAssertTrue(second.includeContext)
    }

    func testStrictCloudDTOContainsNoRawTranscriptOrAudioSurface() throws {
        let request = CloudEnrichmentRequest(
            localCandidate: "Local candidate",
            metadata: CloudRequestMetadata(language: .english, targetType: .document),
            context: nil
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )

        XCTAssertEqual(
            Set(object.keys),
            Set(["local_candidate", "language", "target_type"])
        )
        XCTAssertNil(object["audio"])
        XCTAssertNil(object["raw_transcript"])
    }
}

actor TestAPIKeyStore: APIKeyStoring {
    private var key: SecretAPIKey?

    init(key: SecretAPIKey?) {
        self.key = key
    }

    func save(_ key: SecretAPIKey) { self.key = key }
    func read() -> SecretAPIKey? { key }
    func delete() { key = nil }
}
