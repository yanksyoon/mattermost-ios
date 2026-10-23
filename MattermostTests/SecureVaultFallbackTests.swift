import XCTest
@testable import Mattermost

/// The same `SecureVault` contract exercised against the -34018 pathway: a vault whose
/// injected backend is `FallbackSecretPersisting(primary: UnavailableKeychainStub, fallback:
/// encrypted file)` — exactly what an ad-hoc Mac Catalyst build experiences. On iOS the
/// Keychain works, so these paths are inert there; they prove the vault is fully functional
/// when its Keychain is refused, and that the Keychain is still *attempted* first.
final class SecureVaultFallbackTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecureVaultFallbackTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A vault wired to the -34018 pathway (unique namespace + unique file dir per test).
    private func makeFallbackVault() -> (SecureVault, UnavailableKeychainStub) {
        let keychain = UnavailableKeychainStub()
        let store = FallbackSecretPersisting(primary: keychain,
                                             fallback: EncryptedFileSecretPersisting(directory: dir))
        let vault = SecureVault(serviceNamespace: "SecureVaultFallbackTests-\(UUID().uuidString)",
                                secureStore: store)
        return (vault, keychain)
    }

    private func url(_ string: String = "https://community.mattermost.com") -> URL {
        URL(string: string)!
    }

    // MARK: Round-trip + persistence

    func testAuthTokenRoundTripThroughFallback() throws {
        let (vault, keychain) = makeFallbackVault()
        try vault.setSecret("abc123token", key: .authToken, serverURL: url())
        XCTAssertTrue(vault.hasSecret(key: .authToken, serverURL: url()))
        XCTAssertEqual(vault.getSecret(key: .authToken, serverURL: url()), "abc123token")
        XCTAssertGreaterThan(keychain.callCount, 0, "Keychain must be attempted before the fallback")
    }

    func testTokenSurvivesFreshVaultInstance_simulatingRelaunch() throws {
        let namespace = "SecureVaultFallbackTests-relaunch-\(UUID().uuidString)"
        let keychain = UnavailableKeychainStub()
        let store = FallbackSecretPersisting(primary: keychain,
                                             fallback: EncryptedFileSecretPersisting(directory: dir))
        let first = SecureVault(serviceNamespace: namespace, secureStore: store)
        try first.setSecret("persist-me", key: .authToken, serverURL: url())

        // A brand-new vault object (as after a relaunch) reading the SAME namespace + same
        // fallback directory must see the token — the sealed file is durable on disk.
        let secondKeychain = UnavailableKeychainStub()
        let secondStore = FallbackSecretPersisting(primary: secondKeychain,
                                                   fallback: EncryptedFileSecretPersisting(directory: dir))
        let second = SecureVault(serviceNamespace: namespace, secureStore: secondStore)
        XCTAssertEqual(second.getSecret(key: .authToken, serverURL: url()), "persist-me")
        XCTAssertTrue(second.hasSecret(key: .authToken, serverURL: url()))

        try second.deleteSecret(.authToken, serverURL: url())
        XCTAssertFalse(second.hasSecret(key: .authToken, serverURL: url()))
    }

    // MARK: Per-server isolation

    func testSecretsAreIsolatedPerServer() throws {
        let (vault, _) = makeFallbackVault()
        try vault.setSecret("token-A", key: .authToken, serverURL: url("https://a.example"))
        try vault.setSecret("token-B", key: .authToken, serverURL: url("https://b.example"))
        XCTAssertEqual(vault.getSecret(key: .authToken, serverURL: url("https://a.example")), "token-A")
        XCTAssertEqual(vault.getSecret(key: .authToken, serverURL: url("https://b.example")), "token-B")
        XCTAssertNotEqual(vault.getSecret(key: .authToken, serverURL: url("https://a.example")), "token-B")
    }

    func testSameServerSubpathsAreDistinct() throws {
        let (vault, _) = makeFallbackVault()
        try vault.setSecret("prod", key: .authToken, serverURL: url("https://co.example/mattermost-prod"))
        try vault.setSecret("dev", key: .authToken, serverURL: url("https://co.example/mattermost-dev"))
        XCTAssertEqual(vault.getSecret(key: .authToken, serverURL: url("https://co.example/mattermost-prod")), "prod")
        XCTAssertEqual(vault.getSecret(key: .authToken, serverURL: url("https://co.example/mattermost-dev")), "dev")
    }

    // MARK: Delete / empty-value semantics

    func testEmptyValueDeletesExistingSecret() throws {
        let (vault, _) = makeFallbackVault()
        try vault.setSecret("keep-me", key: .userID, serverURL: url())
        try vault.setSecret("", key: .userID, serverURL: url())
        XCTAssertFalse(vault.hasSecret(key: .userID, serverURL: url()))
        XCTAssertNil(vault.getSecret(key: .userID, serverURL: url()))
    }

    func testDeleteSecret() throws {
        let (vault, _) = makeFallbackVault()
        try vault.setSecret("dying", key: .preauth, serverURL: url())
        XCTAssertTrue(vault.hasSecret(key: .preauth, serverURL: url()))
        try vault.deleteSecret(.preauth, serverURL: url())
        XCTAssertFalse(vault.hasSecret(key: .preauth, serverURL: url()))
        XCTAssertNil(vault.getSecret(key: .preauth, serverURL: url()))
    }

    func testDeleteSecretNotPresentIsNoOp() throws {
        let (vault, _) = makeFallbackVault()
        XCTAssertNoThrow(try vault.deleteSecret(.authToken, serverURL: url()))
    }

    func testDeleteAllSecretsClearsEveryKey() throws {
        let (vault, _) = makeFallbackVault()
        try vault.setSecret("t", key: .authToken, serverURL: url())
        try vault.setSecret("u", key: .userID, serverURL: url())
        try vault.setSecret("p", key: .preauth, serverURL: url())
        vault.deleteAllSecrets(for: url())
        for key in SecureVault.Key.allCases {
            XCTAssertFalse(vault.hasSecret(key: key, serverURL: url()))
        }
    }

    func testDeleteAllSecretsDoesNotTouchOtherServers() throws {
        let (vault, _) = makeFallbackVault()
        try vault.setSecret("keep", key: .authToken, serverURL: url("https://keep.example"))
        try vault.setSecret("drop", key: .authToken, serverURL: url("https://drop.example"))
        vault.deleteAllSecrets(for: url("https://drop.example"))
        XCTAssertEqual(vault.getSecret(key: .authToken, serverURL: url("https://keep.example")), "keep")
        XCTAssertNil(vault.getSecret(key: .authToken, serverURL: url("https://drop.example")))
    }

    // MARK: Different key names don't collide

    func testKeysAreDistinctAccountsWithinAServer() throws {
        let (vault, _) = makeFallbackVault()
        try vault.setSecret("token-1", key: .authToken, serverURL: url())
        try vault.setSecret("preauth-y", key: .preauth, serverURL: url())
        XCTAssertEqual(vault.getSecret(key: .authToken, serverURL: url()), "token-1")
        XCTAssertEqual(vault.getSecret(key: .preauth, serverURL: url()), "preauth-y")
        XCTAssertNil(vault.getSecret(key: .userID, serverURL: url()))
    }
}
