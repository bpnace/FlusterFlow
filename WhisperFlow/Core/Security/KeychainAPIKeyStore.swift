@preconcurrency import Security
import Foundation

enum KeychainStoreError: Error, Equatable, Sendable {
    case authorizationFailed
    case unavailable
    case invalidStoredValue
    case operationFailed
}

protocol GenericPasswordStoring: Sendable {
    func upsert(data: Data, service: String, account: String) async throws
    func read(service: String, account: String) async throws -> Data?
    func delete(service: String, account: String) async throws
}

actor KeychainAPIKeyStore: APIKeyStoring {
    static let defaultService = "local.flusterflow.openai"
    static let defaultAccount = "api-key"

    private let keychain: any GenericPasswordStoring
    private let service: String
    private let account: String

    init(
        keychain: any GenericPasswordStoring = SystemGenericPasswordStore(),
        service: String = defaultService,
        account: String = defaultAccount
    ) {
        self.keychain = keychain
        self.service = service
        self.account = account
    }

    func save(_ key: SecretAPIKey) async throws {
        guard let data = key.value.data(using: .utf8) else {
            throw KeychainStoreError.operationFailed
        }
        try await keychain.upsert(data: data, service: service, account: account)
    }

    func read() async throws -> SecretAPIKey? {
        guard let data = try await keychain.read(service: service, account: account) else {
            return nil
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.invalidStoredValue
        }
        do {
            return try SecretAPIKey(value)
        } catch {
            throw KeychainStoreError.invalidStoredValue
        }
    }

    func delete() async throws {
        try await keychain.delete(service: service, account: account)
    }
}

actor SystemGenericPasswordStore: GenericPasswordStoring {
    func upsert(data: Data, service: String, account: String) throws {
        let lookup: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any
        ]
        let update: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(lookup as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw Self.map(updateStatus)
        }

        var insertion = lookup
        insertion[kSecValueData] = data
        insertion[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw Self.map(addStatus)
        }
    }

    func read(service: String, account: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
            kSecReturnData: kCFBooleanTrue as Any,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw Self.map(status)
        }
        return data
    }

    func delete(service: String, account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.map(status)
        }
    }

    private static func map(_ status: OSStatus) -> KeychainStoreError {
        switch status {
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled:
            .authorizationFailed
        case errSecNotAvailable:
            .unavailable
        default:
            .operationFailed
        }
    }
}
