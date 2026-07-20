import XCTest
@testable import WhisperFlow

final class KeychainAPIKeyStoreTests: XCTestCase, @unchecked Sendable {
    func testAddReadRotateAndDeleteThroughGenericPasswordBoundary() async throws {
        let backend = InMemoryGenericPasswordStore()
        let store = KeychainAPIKeyStore(
            keychain: backend,
            service: "test.service",
            account: "test-account"
        )
        let first = try SecretAPIKey("sk-test-first")
        let rotated = try SecretAPIKey("sk-test-rotated")

        try await store.save(first)
        let firstRead = try await store.read()
        XCTAssertEqual(firstRead?.value, "sk-test-first")

        try await store.save(rotated)
        let rotatedRead = try await store.read()
        let itemCount = await backend.itemCount()
        XCTAssertEqual(rotatedRead?.value, "sk-test-rotated")
        XCTAssertEqual(itemCount, 1)

        try await store.delete()
        let deletedRead = try await store.read()
        XCTAssertNil(deletedRead)
    }

    func testSecretNeverAppearsInDescriptionOrDebugDescription() throws {
        let canary = "sk-secret-canary-never-log"
        let key = try SecretAPIKey(canary)

        XCTAssertFalse(String(describing: key).contains(canary))
        XCTAssertFalse(String(reflecting: key).contains(canary))
    }

    func testKeychainDenialUsesContentFreeError() async throws {
        let store = KeychainAPIKeyStore(keychain: DenyingGenericPasswordStore())

        do {
            try await store.save(SecretAPIKey("sk-secret-canary"))
            XCTFail("Expected denial")
        } catch {
            XCTAssertEqual(error as? KeychainStoreError, .authorizationFailed)
            XCTAssertFalse(String(describing: error).contains("sk-secret-canary"))
        }
    }
}

private actor InMemoryGenericPasswordStore: GenericPasswordStoring {
    private var items: [String: Data] = [:]

    func upsert(data: Data, service: String, account: String) {
        items["\(service):\(account)"] = data
    }

    func read(service: String, account: String) -> Data? {
        items["\(service):\(account)"]
    }

    func delete(service: String, account: String) {
        items["\(service):\(account)"] = nil
    }

    func itemCount() -> Int { items.count }
}

private struct DenyingGenericPasswordStore: GenericPasswordStoring {
    func upsert(data: Data, service: String, account: String) async throws {
        throw KeychainStoreError.authorizationFailed
    }

    func read(service: String, account: String) async throws -> Data? {
        throw KeychainStoreError.authorizationFailed
    }

    func delete(service: String, account: String) async throws {
        throw KeychainStoreError.authorizationFailed
    }
}
