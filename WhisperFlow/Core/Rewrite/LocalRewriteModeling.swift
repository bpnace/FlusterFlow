import Foundation

struct LocalRewriteAvailability: Equatable, Sendable {
    static let available = Self(isAvailable: true, unavailableReason: nil)

    let isAvailable: Bool
    let unavailableReason: TextRewriteUnavailableReason?

    static func unavailable(_ reason: TextRewriteUnavailableReason) -> Self {
        Self(isAvailable: false, unavailableReason: reason)
    }
}

struct LocalRewriteModelResponse: Equatable, Sendable {
    let rewrittenText: String
    let usedContextTerms: [String]
    let hasAmbiguity: Bool

    init(
        rewrittenText: String,
        usedContextTerms: [String] = [],
        hasAmbiguity: Bool = false
    ) {
        self.rewrittenText = rewrittenText
        self.usedContextTerms = usedContextTerms
        self.hasAmbiguity = hasAmbiguity
    }
}

struct LocalRewriteModelPrewarmRequest: Equatable, Sendable {
    let language: TextRewriteLanguage
    let context: TextRewriteContext
    let promptPrefix: String
}

enum LocalRewriteModelError: Error, Equatable, Sendable {
    case unavailable(TextRewriteUnavailableReason)
    case invalidOutput
    case generationFailed
}

protocol LocalRewriteModeling: Sendable {
    func availability(for language: TextRewriteLanguage) async -> LocalRewriteAvailability
    func prewarm(request: LocalRewriteModelPrewarmRequest) async throws
    func rewrite(request: TextRewriteRequest) async throws -> LocalRewriteModelResponse
}

extension LocalRewriteModeling {
    func prewarm(request: LocalRewriteModelPrewarmRequest) async throws {
        let availability = await availability(for: request.language)
        guard availability.isAvailable else {
            throw LocalRewriteModelError.unavailable(
                availability.unavailableReason ?? .modelUnavailable
            )
        }
    }
}

struct UnavailableLocalRewriteModel: LocalRewriteModeling {
    let reason: TextRewriteUnavailableReason

    func availability(for language: TextRewriteLanguage) async -> LocalRewriteAvailability {
        .unavailable(reason)
    }

    func rewrite(request: TextRewriteRequest) async throws -> LocalRewriteModelResponse {
        throw LocalRewriteModelError.unavailable(reason)
    }
}
