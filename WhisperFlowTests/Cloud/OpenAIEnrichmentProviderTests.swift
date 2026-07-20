import XCTest
@testable import WhisperFlow

final class OpenAIEnrichmentProviderTests: XCTestCase, @unchecked Sendable {
    func testDisabledCloudReturnsLocalWithoutTransport() async throws {
        let transport = RecordingCloudTransport(result: .success("Remote"))
        let provider = try makeProvider(transport: transport, key: SecretAPIKey("sk-test"))

        let result = try await provider.enrich(
            LocalCandidate(text: "Local"),
            context: .unavailable(targetKind: .document),
            consent: .localOnly,
            sessionID: DictationSessionID(rawValue: 1)
        )
        let requestCount = await transport.requestCount()

        XCTAssertEqual(result, EnrichedCandidate(text: "Local"))
        XCTAssertEqual(requestCount, 0)
    }

    func testMissingKeyReturnsLocalWithoutTransport() async throws {
        let transport = RecordingCloudTransport(result: .success("Remote"))
        let provider = try makeProvider(transport: transport, key: nil)

        let result = try await provider.enrich(
            LocalCandidate(text: "Local"),
            context: .unavailable(targetKind: .document),
            consent: ConsentSnapshot(cloudEnabled: true, contextToCloud: true),
            sessionID: DictationSessionID(rawValue: 2)
        )
        let requestCount = await transport.requestCount()

        XCTAssertEqual(result.text, "Local")
        XCTAssertEqual(requestCount, 0)
    }

    func testContextOffSendsOnlyCandidateLanguageAndGenericTarget() async throws {
        let transport = RecordingCloudTransport(result: .success("Remote accepted"))
        let provider = try makeProvider(
            transport: transport,
            key: SecretAPIKey("sk-test"),
            validator: AcceptAllCloudMeaningValidator(),
            language: .german
        )
        let context = ContextSnapshot(
            availability: .available,
            targetKind: .chat,
            boundedText: "Context canary",
            termHints: []
        )

        let result = try await provider.enrich(
            LocalCandidate(text: "Local candidate"),
            context: context,
            consent: ConsentSnapshot(cloudEnabled: true, contextToCloud: false),
            sessionID: DictationSessionID(rawValue: 3)
        )
        let recordedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(recordedRequest)

        XCTAssertEqual(result.text, "Remote accepted")
        XCTAssertEqual(request.localCandidate, "Local candidate")
        XCTAssertEqual(request.language, .german)
        XCTAssertEqual(request.targetType, .chat)
        XCTAssertNil(request.context)
    }

    func testContextOnBoundsPayloadToFifteenHundredCharacters() async throws {
        let transport = RecordingCloudTransport(result: .success("Same"))
        let provider = try makeProvider(
            transport: transport,
            key: SecretAPIKey("sk-test"),
            validator: AcceptAllCloudMeaningValidator()
        )
        let context = ContextSnapshot(
            availability: .available,
            targetKind: .email,
            boundedText: String(repeating: "x", count: 2_000),
            termHints: []
        )

        _ = try await provider.enrich(
            LocalCandidate(text: "Local"),
            context: context,
            consent: ConsentSnapshot(cloudEnabled: true, contextToCloud: true),
            sessionID: DictationSessionID(rawValue: 4)
        )
        let recordedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(recordedRequest)

        XCTAssertEqual(request.context?.count, 1_500)
    }

    func testEveryTransportErrorFallsBackToLocalCandidate() async throws {
        let transport = RecordingCloudTransport(result: .failure)
        let provider = try makeProvider(
            transport: transport,
            key: SecretAPIKey("sk-test"),
            validator: AcceptAllCloudMeaningValidator()
        )

        let result = try await provider.enrich(
            LocalCandidate(text: "Local survives"),
            context: .unavailable(targetKind: .unknown),
            consent: ConsentSnapshot(cloudEnabled: true, contextToCloud: false),
            sessionID: DictationSessionID(rawValue: 5)
        )

        XCTAssertEqual(result.text, "Local survives")
    }

    func testConservativeDefaultRejectsChangedCloudText() async throws {
        let transport = RecordingCloudTransport(result: .success("Changed remotely"))
        let provider = try makeProvider(
            transport: transport,
            key: SecretAPIKey("sk-test")
        )

        let result = try await provider.enrich(
            LocalCandidate(text: "Original local"),
            context: .unavailable(targetKind: .document),
            consent: ConsentSnapshot(cloudEnabled: true, contextToCloud: false),
            sessionID: DictationSessionID(rawValue: 6)
        )

        XCTAssertEqual(result.text, "Original local")
    }

    func testCloudRewriteResolvesExactlyOneVisibleChatProjectBeforeValidation() async throws {
        let transport = RecordingCloudTransport(
            result: .success("Prüfe das Projekt erneut.")
        )
        let provider = try makeProvider(
            transport: transport,
            key: SecretAPIKey("sk-test"),
            validator: MeaningPreservationPolicy(),
            language: .german
        )
        let context = ContextSnapshot(
            availability: .available,
            targetKind: .chat,
            boundedText: "Das Projekt heißt Nebelstern.",
            termHints: [],
            localCategory: .workMessaging
        )

        let result = try await provider.enrich(
            LocalCandidate(text: "Prüfe das Projekt erneut."),
            context: context,
            consent: ConsentSnapshot(cloudEnabled: true, contextToCloud: true),
            sessionID: DictationSessionID(rawValue: 7)
        )

        XCTAssertEqual(result.text, "Prüfe Nebelstern erneut.")
    }
}

private func makeProvider(
    transport: RecordingCloudTransport,
    key: SecretAPIKey?,
    validator: any CloudMeaningValidating = ConservativeCloudMeaningValidator(),
    language: CloudLanguage = .automatic
) throws -> OpenAIEnrichmentProvider {
    OpenAIEnrichmentProvider(
        gate: CloudGate(keyStore: TestAPIKeyStore(key: key)),
        transport: transport,
        validator: validator,
        model: try CloudModelIdentifier("test-model"),
        metadataResolver: { context, _ in
            CloudRequestMetadata(language: language, context: context)
        }
    )
}

private struct AcceptAllCloudMeaningValidator: CloudMeaningValidating {
    func accepts(
        localCandidate: LocalCandidate,
        proposedText: String,
        protectedContextTerms: [String]
    ) -> Bool {
        true
    }
}

private enum CloudTransportTestError: Error {
    case expected
}

private actor RecordingCloudTransport: CloudTextTransport {
    enum Result: Sendable {
        case success(String)
        case failure
    }

    private let result: Result
    private var recordedRequests: [CloudEnrichmentRequest] = []

    init(result: Result) {
        self.result = result
    }

    func enrich(
        request: CloudEnrichmentRequest,
        apiKey: SecretAPIKey,
        model: CloudModelIdentifier
    ) throws -> String {
        recordedRequests.append(request)
        switch result {
        case .success(let text): return text
        case .failure: throw CloudTransportTestError.expected
        }
    }

    func requestCount() -> Int { recordedRequests.count }
    func lastRequest() -> CloudEnrichmentRequest? { recordedRequests.last }
}
