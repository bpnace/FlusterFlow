import XCTest
@testable import WhisperFlow

final class OpenAITransportTests: XCTestCase, @unchecked Sendable {
    override func tearDown() {
        OpenAIURLProtocolStub.reset()
        super.tearDown()
    }

    func testDefaultTransportSessionPolicyIsEphemeralAndStateFree() {
        let configuration = OpenAITransport.defaultSessionConfiguration()

        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(configuration.urlCache)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
    }

    func testResponsesRequestIsStatelessTextOnlyAndStrict() async throws {
        let captured = CapturedURLRequest()
        OpenAIURLProtocolStub.install { request in
            captured.store(request)
            return try response(status: 200, outputText: "Improved text")
        }
        let session = makeStubSession()
        defer { session.invalidateAndCancel() }
        let transport = OpenAITransport(session: session)

        let result = try await transport.enrich(
            request: CloudEnrichmentRequest(
                localCandidate: "Local text",
                metadata: CloudRequestMetadata(language: .english, targetType: .chat),
                context: nil
            ),
            apiKey: SecretAPIKey("sk-transport-canary"),
            model: CloudModelIdentifier("configurable-model")
        )

        XCTAssertEqual(result, "Improved text")
        let request = try XCTUnwrap(captured.value())
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-transport-canary")

        let body = try jsonDictionary(try XCTUnwrap(captured.bodyValue()))
        XCTAssertEqual(Set(body.keys), Set(["model", "store", "input", "text"]))
        XCTAssertEqual(body["model"] as? String, "configurable-model")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertNil(body["tools"])
        XCTAssertNil(body["files"])
        XCTAssertNil(body["background"])
        XCTAssertNil(body["previous_response_id"])
        XCTAssertNil(body["conversation"])

        let inputs = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(inputs.count, 2)
        let developerContent = try XCTUnwrap(inputs[0]["content"] as? [[String: Any]])
        let developerInstruction = try XCTUnwrap(developerContent.first?["text"] as? String)
        XCTAssertTrue(developerInstruction.contains("contextSupportedReconstruction"))
        XCTAssertTrue(developerInstruction.contains("target_type rules"))
        XCTAssertTrue(developerInstruction.contains("recent visible conversation"))
        XCTAssertTrue(developerInstruction.contains("Never introduce new numbers"))
        let userContent = try XCTUnwrap(inputs[1]["content"] as? [[String: Any]])
        let encodedDTO = try XCTUnwrap(userContent.first?["text"] as? String)
        let dto = try jsonDictionary(Data(encodedDTO.utf8))
        XCTAssertEqual(Set(dto.keys), Set(["local_candidate", "language", "target_type"]))
        XCTAssertNil(dto["audio"])
        XCTAssertNil(dto["raw_transcript"])

        let text = try XCTUnwrap(body["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["strict"] as? Bool, true)
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(
            Set(try XCTUnwrap(schema["required"] as? [String])),
            Set(["text", "used_context_terms", "has_ambiguity"])
        )
    }

    func testSanitizesStrictResponseTextBeforeReturning() async throws {
        OpenAIURLProtocolStub.install { _ in
            try response(
                status: 200,
                rawData: responseData(outputObject: [
                    "text": """
                    ```markdown
                    Improved   text!!
                    ```
                    """,
                    "used_context_terms": [],
                    "has_ambiguity": false
                ])
            )
        }
        let session = makeStubSession()
        defer { session.invalidateAndCancel() }
        let transport = OpenAITransport(session: session)

        let result = try await transport.enrich(
            request: sampleRequest(),
            apiKey: SecretAPIKey("sk-test"),
            model: .defaultEfficientModel
        )

        XCTAssertEqual(result, "Improved text!")
    }

    func testOptionalContextIsBoundedBeforeTransportEncoding() async throws {
        let captured = CapturedURLRequest()
        OpenAIURLProtocolStub.install { request in
            captured.store(request)
            return try response(status: 200, outputText: "Same")
        }
        let session = makeStubSession()
        defer { session.invalidateAndCancel() }
        let transport = OpenAITransport(session: session)

        _ = try await transport.enrich(
            request: CloudEnrichmentRequest(
                localCandidate: "Same",
                metadata: CloudRequestMetadata(language: .german, targetType: .document),
                context: String(repeating: "x", count: 2_000)
            ),
            apiKey: SecretAPIKey("sk-test"),
            model: .defaultEfficientModel
        )

        _ = try XCTUnwrap(captured.value())
        let body = try jsonDictionary(try XCTUnwrap(captured.bodyValue()))
        let inputs = try XCTUnwrap(body["input"] as? [[String: Any]])
        let userContent = try XCTUnwrap(inputs[1]["content"] as? [[String: Any]])
        let encodedDTO = try XCTUnwrap(userContent.first?["text"] as? String)
        let dto = try jsonDictionary(Data(encodedDTO.utf8))
        XCTAssertEqual((dto["context"] as? String)?.count, 1_500)
    }

    func testRejectsAmbiguousOrUnsupportedContextMetadata() async throws {
        let responses: [([String: Any], String?, OpenAITransportError)] = [
            (
                ["text": "Vielleicht morgen.", "used_context_terms": [], "has_ambiguity": true],
                nil,
                .ambiguousResponse
            ),
            (
                ["text": "PROJECT-ORBIT morgen.", "used_context_terms": ["PROJECT-ORBIT"], "has_ambiguity": false],
                "Nur FlusterFlow steht im Kontext.",
                .invalidResponse
            )
        ]

        for (object, context, expectedError) in responses {
            let responseBody = try responseData(outputObject: object)
            OpenAIURLProtocolStub.install { _ in
                try response(status: 200, rawData: responseBody)
            }
            let session = makeStubSession()
            defer { session.invalidateAndCancel() }
            let transport = OpenAITransport(session: session)
            do {
                _ = try await transport.enrich(
                    request: CloudEnrichmentRequest(
                        localCandidate: "Lokaler Text",
                        metadata: CloudRequestMetadata(language: .german, targetType: .chat),
                        context: context
                    ),
                    apiKey: SecretAPIKey("sk-test"),
                    model: .defaultEfficientModel
                )
                XCTFail("Expected structured rewrite rejection")
            } catch {
                XCTAssertEqual(error as? OpenAITransportError, expectedError)
            }
        }
    }

    func testHTTPStatusAndSchemaErrorsAreContentFree() async throws {
        for (status, expected) in [
            (401, OpenAITransportError.unauthorized),
            (429, OpenAITransportError.rateLimited),
            (500, OpenAITransportError.providerFailure)
        ] {
            OpenAIURLProtocolStub.install { _ in
                try response(status: status, rawData: Data("secret-provider-body".utf8))
            }
            let session = makeStubSession()
            let transport = OpenAITransport(session: session)
            do {
                _ = try await transport.enrich(
                    request: sampleRequest(),
                    apiKey: SecretAPIKey("sk-secret-canary"),
                    model: .defaultEfficientModel
                )
                XCTFail("Expected status mapping")
            } catch {
                XCTAssertEqual(error as? OpenAITransportError, expected)
                XCTAssertFalse(String(describing: error).contains("secret-provider-body"))
                XCTAssertFalse(String(describing: error).contains("sk-secret-canary"))
            }
            session.invalidateAndCancel()
        }
    }

    func testMalformedOrAdditionalResponseFieldsAreRejected() async throws {
        let bodies: [Data] = [
            Data("{invalid".utf8),
            try responseData(outputObject: ["text": "Changed", "extra": "not allowed"]),
            try responseData(outputObject: ["text": ""])
        ]

        for body in bodies {
            OpenAIURLProtocolStub.install { _ in
                try response(status: 200, rawData: body)
            }
            let session = makeStubSession()
            let transport = OpenAITransport(session: session)
            do {
                _ = try await transport.enrich(
                    request: sampleRequest(),
                    apiKey: SecretAPIKey("sk-test"),
                    model: .defaultEfficientModel
                )
                XCTFail("Expected schema rejection")
            } catch {
                XCTAssertEqual(error as? OpenAITransportError, .invalidResponse)
            }
            session.invalidateAndCancel()
        }
    }

    func testURLSessionTimeoutMapsToContentFreeTimeout() async throws {
        OpenAIURLProtocolStub.install { _ in
            throw URLError(.timedOut)
        }
        let session = makeStubSession()
        defer { session.invalidateAndCancel() }
        let transport = OpenAITransport(
            session: session,
            configuration: OpenAITransportConfiguration(timeout: .milliseconds(20))
        )

        do {
            _ = try await transport.enrich(
                request: sampleRequest(),
                apiKey: SecretAPIKey("sk-timeout-canary"),
                model: .defaultEfficientModel
            )
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? OpenAITransportError, .timeout)
            XCTAssertFalse(String(describing: error).contains("sk-timeout-canary"))
        }
    }
}

private func sampleRequest() -> CloudEnrichmentRequest {
    CloudEnrichmentRequest(
        localCandidate: "Local survives",
        metadata: CloudRequestMetadata(language: .automatic, targetType: .unknown),
        context: nil
    )
}

private func makeStubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OpenAIURLProtocolStub.self]
    return URLSession(configuration: configuration)
}

private func jsonDictionary(_ data: Data) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func response(
    status: Int,
    outputText: String
) throws -> (HTTPURLResponse, Data) {
    try response(
        status: status,
        rawData: responseData(outputObject: [
            "text": outputText,
            "used_context_terms": [],
            "has_ambiguity": false
        ])
    )
}

private func response(
    status: Int,
    rawData: Data
) throws -> (HTTPURLResponse, Data) {
    let url = try XCTUnwrap(URL(string: "https://api.openai.com/v1/responses"))
    let response = try XCTUnwrap(
        HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )
    )
    return (response, rawData)
}

private func responseData(outputObject: [String: Any]) throws -> Data {
    let inner = try JSONSerialization.data(withJSONObject: outputObject)
    let innerText = try XCTUnwrap(String(data: inner, encoding: .utf8))
    return try JSONSerialization.data(withJSONObject: [
        "output": [
            [
                "type": "message",
                "content": [
                    ["type": "output_text", "text": innerText]
                ]
            ]
        ]
    ])
}

private final class CapturedURLRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?
    private var body: Data?

    func store(_ request: URLRequest) {
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        lock.withLock {
            self.request = request
            self.body = body
        }
    }

    func value() -> URLRequest? {
        lock.withLock { request }
    }

    func bodyValue() -> Data? {
        lock.withLock { body }
    }

    private static func read(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

private final class OpenAIURLProtocolStub: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?

    static func install(_ handler: @escaping Handler) {
        lock.withLock { self.handler = handler }
    }

    static func reset() {
        lock.withLock { handler = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.lock.withLock { Self.handler }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
