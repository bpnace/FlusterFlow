import Foundation

enum CloudLocalOnlyReason: Equatable, Sendable {
    case cloudDisabled
    case missingKey
    case keyUnavailable
}

struct CloudAuthorization: Sendable {
    let apiKey: SecretAPIKey
    let includeContext: Bool
}

enum CloudGateDecision: Sendable {
    case localOnly(CloudLocalOnlyReason)
    case authorized(CloudAuthorization)
}

actor CloudGate {
    private let keyStore: any APIKeyStoring

    init(keyStore: any APIKeyStoring) {
        self.keyStore = keyStore
    }

    func evaluate(consent: ConsentSnapshot) async -> CloudGateDecision {
        guard consent.cloudEnabled else {
            return .localOnly(.cloudDisabled)
        }
        do {
            guard let key = try await keyStore.read() else {
                return .localOnly(.missingKey)
            }
            return .authorized(
                CloudAuthorization(
                    apiKey: key,
                    includeContext: consent.contextToCloud
                )
            )
        } catch {
            return .localOnly(.keyUnavailable)
        }
    }
}
