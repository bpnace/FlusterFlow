import Foundation

enum HTTPSModelProvisioningTransportError: Error, Equatable, Sendable {
    case insecureSource
    case disallowedSourceHost
    case invalidHTTPResponse
    case unsuccessfulHTTPStatus(Int)
    case insecureRedirect
    case transportFailure
    case destinationWriteFailed
}

/// The only model-provisioning implementation that owns a network client.
/// Runtime loading never receives this transport and remains offline-only.
actor HTTPSModelProvisioningTransport: ModelProvisioningTransport {
    private let session: URLSession
    private let redirectDelegate: HTTPSOnlyRedirectDelegate
    private let allowedSourceHost: String
    private let fileManager: FileManager

    init(
        configuration: URLSessionConfiguration = .ephemeral,
        allowedSourceHost: String = "huggingface.co",
        fileManager: FileManager = .default
    ) {
        let redirectDelegate = HTTPSOnlyRedirectDelegate()
        self.redirectDelegate = redirectDelegate
        self.session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
        self.allowedSourceHost = allowedSourceHost
        self.fileManager = fileManager
    }

    func download(_ request: ModelArtifactDownloadRequest) async throws {
        guard request.sourceURL.scheme?.lowercased() == "https" else {
            throw HTTPSModelProvisioningTransportError.insecureSource
        }
        guard request.sourceURL.host?.lowercased() == allowedSourceHost.lowercased() else {
            throw HTTPSModelProvisioningTransportError.disallowedSourceHost
        }

        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await session.download(from: request.sourceURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw HTTPSModelProvisioningTransportError.transportFailure
        }
        defer { try? fileManager.removeItem(at: temporaryURL) }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPSModelProvisioningTransportError.invalidHTTPResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw HTTPSModelProvisioningTransportError.unsuccessfulHTTPStatus(
                httpResponse.statusCode
            )
        }
        guard httpResponse.url?.scheme?.lowercased() == "https" else {
            throw HTTPSModelProvisioningTransportError.insecureRedirect
        }

        do {
            if fileManager.fileExists(atPath: request.destinationURL.path) {
                try fileManager.removeItem(at: request.destinationURL)
            }
            try fileManager.moveItem(at: temporaryURL, to: request.destinationURL)
        } catch {
            throw HTTPSModelProvisioningTransportError.destinationWriteFailed
        }
    }
}

private final class HTTPSOnlyRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard request.url?.scheme?.lowercased() == "https" else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
