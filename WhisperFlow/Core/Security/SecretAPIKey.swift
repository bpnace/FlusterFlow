import Foundation

struct SecretAPIKey: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let value: String

    init(_ value: String) throws {
        guard !value.isEmpty,
              value.count <= 512,
              value.unicodeScalars.allSatisfy({
                  !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw APIKeyValidationError.invalidFormat
        }
        self.value = value
    }

    var description: String { "<redacted-api-key>" }
    var debugDescription: String { description }
}

enum APIKeyValidationError: Error, Equatable, Sendable {
    case invalidFormat
}

protocol APIKeyStoring: Sendable {
    func save(_ key: SecretAPIKey) async throws
    func read() async throws -> SecretAPIKey?
    func delete() async throws
}
