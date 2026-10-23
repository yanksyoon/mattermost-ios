import XCTest
@testable import Mattermost

/// Test fakes backing the fallback-store tests.
///
/// `UnavailableKeychainStub` reproduces the ad-hoc-Catalyst condition precisely: every
/// `SecItem*`-shaped call fails with `errSecMissingEntitlement` (-34018).
final class UnavailableKeychainStub: SecretPersisting {
    private(set) var callCount = 0
    var backendDescription: String { "Keychain" }
    func get(service: String, account: String) throws -> Data? {
        callCount += 1
        throw SecretStoreError.keychainUnavailable(-34018)
    }
    func set(service: String, account: String, value: Data) throws {
        callCount += 1
        throw SecretStoreError.keychainUnavailable(-34018)
    }
    func delete(service: String, account: String) throws {
        callCount += 1
        throw SecretStoreError.keychainUnavailable(-34018)
    }
    func deleteAll(service: String) throws {
        callCount += 1
        throw SecretStoreError.keychainUnavailable(-34018)
    }
}

/// A Keychain that fails with a NON -34018 error (`errSecInteractionNotAllowed`). The
/// fallback composite must NOT route around this — only `keychainUnavailable` triggers the
/// fallback, so genuine Keychain bugs still surface on iOS instead of being masked.
final class OtherKeychainFailureStub: SecretPersisting {
    func get(service: String, account: String) throws -> Data? {
        throw SecretStoreError.keychainFailure(errSecInteractionNotAllowed)
    }
    func set(service: String, account: String, value: Data) throws {
        throw SecretStoreError.keychainFailure(errSecInteractionNotAllowed)
    }
    func delete(service: String, account: String) throws {
        throw SecretStoreError.keychainFailure(errSecInteractionNotAllowed)
    }
    func deleteAll(service: String) throws {
        throw SecretStoreError.keychainFailure(errSecInteractionNotAllowed)
    }
}

/// A trivially working in-memory backend (used as the primary to prove the fallback file is
/// NOT touched while the Keychain works — the iOS behaviour guarantee).
final class InMemorySecretStub: SecretPersisting {
    private var storage: [String: [String: Data]] = [:]
    func get(service: String, account: String) throws -> Data? {
        storage[service]?[account]
    }
    func set(service: String, account: String, value: Data) throws {
        storage[service, default: [:]][account] = value
    }
    func delete(service: String, account: String) throws {
        storage[service]?.removeValue(forKey: account)
    }
    func deleteAll(service: String) throws {
        storage.removeValue(forKey: service)
    }
}

/// Unit tests for `FallbackSecretPersisting`, the production composite that keeps the Keychain
/// primary and routes to the encrypted file only on `errSecMissingEntitlement` (-34018).
final class FallbackSecretStoreTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FallbackSecretStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func fileFallback() -> EncryptedFileSecretPersisting {
        EncryptedFileSecretPersisting(directory: dir)
    }

    private func sampleData(_ text: String) -> Data { Data(text.utf8) }

    // MARK: The -34018 pathway (ad-hoc Catalyst)

    func testUnavailablePrimarySetGetRoundTripsThroughFile() throws {
        let keychain = UnavailableKeychainStub()
        let store = FallbackSecretPersisting(primary: keychain, fallback: fileFallback())

        try store.set(service: "svc-a", account: "acct-1", value: sampleData("token-abc"))
        XCTAssertEqual(try store.get(service: "svc-a", account: "acct-1"), sampleData("token-abc"))
        XCTAssertGreaterThan(keychain.callCount, 0, "The Keychain must be attempted first, not skipped")
    }

    func testUnavailablePrimaryDeleteDeleteAllRouteToFile() throws {
        let store = FallbackSecretPersisting(primary: UnavailableKeychainStub(), fallback: fileFallback())
        try store.set(service: "svc-a", account: "acct-1", value: sampleData("v"))
        try store.set(service: "svc-a", account: "acct-2", value: sampleData("v2"))

        try store.delete(service: "svc-a", account: "acct-1")
        XCTAssertNil(try store.get(service: "svc-a", account: "acct-1"))
        XCTAssertEqual(try store.get(service: "svc-a", account: "acct-2"), sampleData("v2"))

        try store.deleteAll(service: "svc-a")
        XCTAssertNil(try store.get(service: "svc-a", account: "acct-2"))
    }

    func testValueSurvivesFreshCompositeAcrossRefiles() throws {
        let first = FallbackSecretPersisting(primary: UnavailableKeychainStub(), fallback: fileFallback())
        try first.set(service: "svc-a", account: "acct-1", value: sampleData("persist-me"))

        // A new composite reading the same fallback directory sees the value (relaunch parity).
        let second = FallbackSecretPersisting(primary: UnavailableKeychainStub(), fallback: fileFallback())
        XCTAssertEqual(try second.get(service: "svc-a", account: "acct-1"), sampleData("persist-me"))
    }

    func testBackendDescriptionReflectsEngagedFallback() throws {
        let store = FallbackSecretPersisting(primary: UnavailableKeychainStub(), fallback: fileFallback())
        // Before any operation the composite reports the primary backend (the Keychain).
        XCTAssertEqual(store.backendDescription, "Keychain")
        XCTAssertFalse(store.backendDescription.contains("Encrypted file"))
        _ = try? store.get(service: "svc-a", account: "acct-0") // triggers the fallback path
        XCTAssertTrue(store.backendDescription.contains("Keychain unavailable"))
        XCTAssertTrue(store.backendDescription.contains("Encrypted file"))
    }

    // MARK: Working-Keychain guarantee (iOS / team-signed Mac)

    func testWorkingPrimaryNeverTouchesFallbackFile() throws {
        let fallback = fileFallback()
        let store = FallbackSecretPersisting(primary: InMemorySecretStub(), fallback: fallback)

        try store.set(service: "svc-a", account: "acct-1", value: sampleData("ios-token"))
        XCTAssertEqual(try store.get(service: "svc-a", account: "acct-1"), sampleData("ios-token"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fallback.dataFile.path),
                       "While the Keychain works the fallback file must never be created")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fallback.keyFile.path))
    }

    // MARK: Only -34018 routes to the fallback

    func testNonMissingEntitlementFailureIsNotSilentlyRouted() throws {
        let fallback = fileFallback()
        let store = FallbackSecretPersisting(primary: OtherKeychainFailureStub(), fallback: fallback)

        // A genuine Keychain failure must surface — never masked by the file fallback.
        XCTAssertThrowsError(try store.set(service: "svc-a", account: "acct-1", value: sampleData("x"))) { error in
            guard case SecretStoreError.keychainFailure = error else {
                return XCTFail("expected keychainFailure, got \(error)")
            }
        }
        XCTAssertThrowsError(try store.get(service: "svc-a", account: "acct-1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fallback.dataFile.path),
                       "No fallback file may be created for non--34018 failures")
    }
}
