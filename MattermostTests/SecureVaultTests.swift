import XCTest
@testable import Mattermost

/// Unit tests for `SecureVault`, the Keychain wrapper that replaces desktop
/// `secureStorage.ts`/Electron `safeStorage`.
///
/// Real Keychain calls run against the simulator's keychain (the unit-test host is the app), so
/// every test forges a unique `serviceNamespace` to keep its items isolated from any stored user
/// data and from other tests. Lifecycle is still exercised: the headline assertions are that a
/// token written by one vault instance is read back by a *fresh* instance (same namespace) —
/// the Keychain item persisted on disk, exactly the "survives relaunch" the task demands.
final class SecureVaultTests: XCTestCase {

    /// A fresh vault with a per-test unique namespace so tests never collide with each other
    /// or with the app's real stored credentials.
    private func makeVault() -> SecureVault {
        SecureVault(serviceNamespace: "SecureVaultTests-\(UUID().uuidString)")
    }

    private func url(_ string: String = "https://community.mattermost.com") -> URL {
        URL(string: string)!
    }

    // MARK: Round-trip + relaunch persistence

    func testAuthTokenRoundTripReadableOnlyViaVault() throws {
        let vault = makeVault()
        try vault.setSecret("abc123token", key: .authToken, serverURL: url())
        XCTAssertTrue(vault.hasSecret(key: .authToken, serverURL: url()))
        XCTAssertEqual(vault.getSecret(key: .authToken, serverURL: url()), "abc123token")

        // It must NOT live in UserDefaults / plist storage — "readable only via the vault".
        let storedAnywhereInDefaults = UserDefaults.standard.dictionaryRepresentation()
            .values.contains { ($0 as? String) == "abc123token" }
        XCTAssertFalse(storedAnywhereInDefaults, "token escaped into UserDefaults (plaintext at rest)")
    }

    func testTokenSurvivesFreshVaultInstance_simulatingRelaunch() throws {
        let namespace = "SecureVaultTests-relaunch-\(UUID().uuidString)"
        let first = SecureVault(serviceNamespace: namespace)
        try first.setSecret("persist-me", key: .authToken, serverURL: url())

        // A brand-new vault object (as after a relaunch) reading the SAME namespace must see the
        // token — the Keychain item is durable on disk, not held in memory.
        let second = SecureVault(serviceNamespace: namespace)
        XCTAssertEqual(second.getSecret(key: .authToken, serverURL: url()), "persist-me")
        XCTAssertTrue(second.hasSecret(key: .authToken, serverURL: url()))

        try second.deleteSecret(.authToken, serverURL: url())
        XCTAssertFalse(second.hasSecret(key: .authToken, serverURL: url()))
    }

    // MARK: Per-server isolation

    func testSecretsAreIsolatedPerServer() throws {
        let vault = makeVault()
        try vault.setSecret("token-A", key: .authToken, serverURL: url("https://a.example"))
        try vault.setSecret("token-B", key: .authToken, serverURL: url("https://b.example"))
        XCTAssertEqual(vault.getSecret(key: .authToken, serverURL: url("https://a.example")), "token-A")
        XCTAssertEqual(vault.getSecret(key: .authToken, serverURL: url("https://b.example")), "token-B")
        // No cross-leak.
        XCTAssertNotEqual(vault.getSecret(key: .authToken, serverURL: url("https://a.example")), "token-B")
    }

    func testSameServerSubpathsAreDistinct() throws {
        let vault = makeVault()
        try vault.setSecret("prod", key: .authToken, serverURL: url("https://co.example/mattermost-prod"))
        try vault.setSecret("dev", key: .authToken, serverURL: url("https://co.example/mattermost-dev"))
        // Desktop keys by origin+path so two instance paths on one domain keep separate creds.
        XCTAssertEqual(vault.getSecret(key: .authToken, serverURL: url("https://co.example/mattermost-prod")), "prod")
        XCTAssertEqual(vault.getSecret(key: .authToken, serverURL: url("https://co.example/mattermost-dev")), "dev")
    }

    // MARK: Delete / empty-value semantics

    func testEmptyValueDeletesExistingSecret() throws {
        let vault = makeVault()
        try vault.setSecret("keep-me", key: .userID, serverURL: url())
        try vault.setSecret("", key: .userID, serverURL: url())
        XCTAssertFalse(vault.hasSecret(key: .userID, serverURL: url()))
        XCTAssertNil(vault.getSecret(key: .userID, serverURL: url()))
    }

    func testDeleteSecret() throws {
        let vault = makeVault()
        try vault.setSecret("dying", key: .preauth, serverURL: url())
        XCTAssertTrue(vault.hasSecret(key: .preauth, serverURL: url()))
        try vault.deleteSecret(.preauth, serverURL: url())
        XCTAssertFalse(vault.hasSecret(key: .preauth, serverURL: url()))
        XCTAssertNil(vault.getSecret(key: .preauth, serverURL: url()))
    }

    func testDeleteSecretNotPresentIsNoOp() throws {
        let vault = makeVault()
        XCTAssertNoThrow(try vault.deleteSecret(.authToken, serverURL: url()))
    }

    func testDeleteAllSecretsClearsEveryKey() throws {
        let vault = makeVault()
        try vault.setSecret("t", key: .authToken, serverURL: url())
        try vault.setSecret("u", key: .userID, serverURL: url())
        try vault.setSecret("p", key: .preauth, serverURL: url())
        vault.deleteAllSecrets(for: url())
        for key in SecureVault.Key.allCases {
            XCTAssertFalse(vault.hasSecret(key: key, serverURL: url()))
        }
    }

    func testDeleteAllSecretsDoesNotTouchOtherServers() throws {
        let vault = makeVault()
        try vault.setSecret("keep", key: .authToken, serverURL: url("https://keep.example"))
        try vault.setSecret("drop", key: .authToken, serverURL: url("https://drop.example"))
        vault.deleteAllSecrets(for: url("https://drop.example"))
        XCTAssertEqual(vault.getSecret(key: .authToken, serverURL: url("https://keep.example")), "keep")
        XCTAssertNil(vault.getSecret(key: .authToken, serverURL: url("https://drop.example")))
    }

    // MARK: Different key names don't collide

    func testKeysAreDistinctAccountsWithinAServer() throws {
        let vault = makeVault()
        try vault.setSecret("token-1", key: .authToken, serverURL: url())
        try vault.setSecret("preauth-y", key: .preauth, serverURL: url())
        XCTAssertEqual(vault.getSecret(key: .authToken, serverURL: url()), "token-1")
        XCTAssertEqual(vault.getSecret(key: .preauth, serverURL: url()), "preauth-y")
        XCTAssertNil(vault.getSecret(key: .userID, serverURL: url()))
    }

    // MARK: Server canonicalisation (desktop normalizeUrl parity)

    func testCanonicalServerURLCollapsesDefaultPortAndTrailingSlash() {
        XCTAssertEqual(
            SecureVault.canonicalServerURL(url("https://a.example:443/")),
            "https://a.example")
        XCTAssertEqual(
            SecureVault.canonicalServerURL(url("https://a.example")),
            "https://a.example")
        XCTAssertEqual(
            SecureVault.canonicalServerURL(url("http://a.example:80")),
            "http://a.example")
    }

    func testCanonicalServerURLKeepsNonDefaultPortAndSubPath() {
        XCTAssertEqual(
            SecureVault.canonicalServerURL(url("https://a.example:8443")),
            "https://a.example:8443")
        XCTAssertEqual(
            SecureVault.canonicalServerURL(url("https://co.example/x/prod")),
            "https://co.example/x/prod")
        XCTAssertEqual(
            SecureVault.canonicalServerURL(url("https://co.example/x/prod/")),
            "https://co.example/x/prod")
    }
}