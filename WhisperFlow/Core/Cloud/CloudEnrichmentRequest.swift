import Foundation

enum CloudLanguage: String, Codable, Equatable, Sendable {
    case automatic = "auto"
    case german = "de"
    case english = "en"
}

enum CloudTargetType: String, Codable, Equatable, Sendable {
    case email
    case chat
    case document
    case unknown
}

struct CloudRequestMetadata: Equatable, Sendable {
    let language: CloudLanguage
    let targetType: CloudTargetType

    init(language: CloudLanguage, targetType: CloudTargetType) {
        self.language = language
        self.targetType = targetType
    }

    init(language: CloudLanguage, context: ContextSnapshot) {
        self.language = language
        targetType = CloudTargetType(context.targetKind)
    }
}

struct CloudEnrichmentRequest: Encodable, Equatable, Sendable {
    static let maximumContextCharacters = 1_500

    let localCandidate: String
    let language: CloudLanguage
    let targetType: CloudTargetType
    let context: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case localCandidate = "local_candidate"
        case language
        case targetType = "target_type"
        case context
    }

    init(
        localCandidate: String,
        metadata: CloudRequestMetadata,
        context: String?
    ) {
        self.localCandidate = localCandidate
        language = metadata.language
        targetType = metadata.targetType
        self.context = context.map {
            String($0.prefix(Self.maximumContextCharacters))
        }
    }
}

extension CloudTargetType {
    init(_ targetKind: TargetKind) {
        switch targetKind {
        case .email: self = .email
        case .chat: self = .chat
        case .document: self = .document
        case .unknown: self = .unknown
        }
    }
}

struct CloudModelIdentifier: Equatable, Sendable, CustomStringConvertible {
    static let defaultEfficientModel: Self = try! Self("gpt-5.6-luna")

    let value: String

    init(_ value: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:-"))
        guard !value.isEmpty,
              value.count <= 128,
              value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw CloudConfigurationError.invalidModelIdentifier
        }
        self.value = value
    }

    var description: String { value }
}

enum CloudConfigurationError: Error, Equatable, Sendable {
    case invalidModelIdentifier
}

protocol CloudTextTransport: Sendable {
    func enrich(
        request: CloudEnrichmentRequest,
        apiKey: SecretAPIKey,
        model: CloudModelIdentifier
    ) async throws -> String
}
