import XCTest
import Security
@testable import Mattermost

/// The `CertTrust` trust-bag contract exercised against the -34018 pathway (ad-hoc Catalyst):
/// `FallbackSecretPersisting(primary: UnavailableKeychainStub, fallback: encrypted file)`.
/// Mirrors `CertTrustTests` for the Keychain path, proving the trust decision still persists
/// across store instances when the Keychain is refused.
final class CertTrustFallbackTests: XCTestCase {

    /// The same real self-signed X.509 cert DER used by `CertTrustTests`:
    ///   openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
    ///     -subj "/CN=mattermost-dev.example/O=MattermostDev"
    private static let selfSignedDERB64 = "MIIC7jCCAdYCCQDOe9KUgEi62DANBgkqhkiG9w0BAQsFADA5MR8wHQYDVQQDDBZtYXR0ZXJtb3N0LWRldi5leGFtcGxlMRYwFAYDVQQKDA1NYXR0ZXJtb3N0RGV2MB4XDTI2MTAyMTE4NTgyNFoXDTI2MTEyMDE4NTgyNFowOTEfMB0GA1UEAwwWbWF0dGVybW9zdC1kZXYuZXhhbXBsZTEWMBQGA1UECgwNTWF0dGVybW9zdERldjCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBANwtuZSY5Ujr2aBzcH7hyl51WYj/tcH6DmgvJww2tsjzAVodQDYxy+vCsAV0crOK8YkIUK3Kxd39R2aaJJD+jni1eIICMhjD+yxj/0JawGwoEb9+/FJq+UWMymP2vZbnB++vdusiLNXgBAxcRaV9zPDO07T4xcaZPdl+r+sip4XKU8WB72qa8PEMJXQcfbssmvHlY6uppgnlMKKbUZy8vverTYC9kpbdcXtyL1uBj2dsAqUMmYg2BQ2tix/H6Q3/Fj6r5+nUE6kxVhFPurxnT/tzhMhAnRftvVLI6WTX1AObH7yqcL93z2Dk52Gh8aO88MLtSks7yCEbUEG3tY9FPeMCAwEAATANBgkqhkiG9w0BAQsFAAOCAQEAnpqpETn0nK9/2DmveQml/P/Wvyp4mPhkjUQDUqLmOeMtpgBlvHcJ55d0MRx0EodI6+6LCAixI3nH+xk0rViV53hEE+4nkX58XsQByQRdtKLHR7RepB8xqwsgsFWVt0xdeR5nKhzfDTt+ftsi7c7KSozOKioS5imxNaDkgrzA1ELMrrRi32675EPBTnHvtmQXAjnJBxSRA6CY0mAhNXePXg7R0OzzOFGvU/DngKrlcmpUqR7RfjNNOBOUPM+tswBTsRD4PIalwbSTWTCVBc5hlyCwpxGvbtQHaEHZx0vxjeJnTasSqxdUFtUtVMQUiWeR72yciBweA9l0OjCfZODUcw=="

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CertTrustFallbackTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeFallbackStore() -> CertTrust {
        let store = FallbackSecretPersisting(
            primary: UnavailableKeychainStub(),
            fallback: EncryptedFileSecretPersisting(directory: dir)
        )
        // One namespace per test; one directory is fine because services stay unique per
        // namespace+origin and each test creates its own temp dir anyway.
        return CertTrust(serviceNamespace: "CertTrustFallbackTests-\(UUID().uuidString)",
                         secureStore: store)
    }

    private func serverURL(_ string: String = "https://mattermost-dev.example") -> URL {
        URL(string: string)!
    }

    private func fixtureCertificate() throws -> ComparableCertificate {
        guard let der = Data(base64Encoded: CertTrustFallbackTests.selfSignedDERB64),
              let cert = SecCertificateCreateWithData(nil, der as CFData) else {
            throw CertTrustError.cannotReadPresentedCertificate
        }
        return try CertTrust.comparable(from: cert)
    }

    private func otherCertificate() -> ComparableCertificate {
        ComparableCertificate(data: "QIAAAA=", issuerName: "CN=other.example")
    }

    // MARK: Persistence (the headline: trust survives a fresh store instance)

    func testTrustSurvivesFreshStoreInstance_simulatingRelaunch() throws {
        let namespace = "CertTrustFallbackTests-relaunch-\(UUID().uuidString)"
        let cert = try fixtureCertificate()
        let firstStore = FallbackSecretPersisting(
            primary: UnavailableKeychainStub(),
            fallback: EncryptedFileSecretPersisting(directory: dir)
        )
        let first = CertTrust(serviceNamespace: namespace, secureStore: firstStore)
        try first.add(serverURL(), certificate: cert)

        // A brand-new store (as after a relaunch) in the same namespace + fallback directory
        // must remember the trust decision.
        let secondStore = FallbackSecretPersisting(
            primary: UnavailableKeychainStub(),
            fallback: EncryptedFileSecretPersisting(directory: dir)
        )
        let second = CertTrust(serviceNamespace: namespace, secureStore: secondStore)
        XCTAssertTrue(second.isExisting(for: serverURL()))
        XCTAssertTrue(second.isTrusted(serverURL(), certificate: cert))
        XCTAssertFalse(second.isExplicitlyUntrusted(for: serverURL()))
    }

    // MARK: Trust decision semantics

    func testExactCertificateIsTrustedAndDifferentIsNot() throws {
        let store = makeFallbackStore()
        let cert = try fixtureCertificate()
        try store.add(serverURL(), certificate: cert)
        XCTAssertTrue(store.isExisting(for: serverURL()))
        XCTAssertTrue(store.isTrusted(serverURL(), certificate: cert))
        let other = otherCertificate()
        XCTAssertFalse(store.isTrusted(serverURL(), certificate: other))
        XCTAssertFalse(store.isExisting(for: serverURL("https://unrelated.example")))
    }

    func testUntrustedOriginIsNotTrusted() throws {
        let store = makeFallbackStore()
        let cert = try fixtureCertificate()
        XCTAssertFalse(store.isTrusted(serverURL(), certificate: cert))
        XCTAssertFalse(store.isExisting(for: serverURL()))
        XCTAssertFalse(store.isExplicitlyUntrusted(for: serverURL()))
    }

    // MARK: "Don't ask again" (dontTrust)

    func testExplicitlyUntrustedCertificateIsRefusedEvenIfPresented() throws {
        let store = makeFallbackStore()
        let cert = try fixtureCertificate()
        try store.add(serverURL(), certificate: cert, dontTrust: true)
        XCTAssertTrue(store.isExplicitlyUntrusted(for: serverURL()))
        XCTAssertFalse(store.isTrusted(serverURL(), certificate: cert))
    }

    // MARK: Origin keying + wss mirror

    func testTrustIsScopedPerOriginNotPerPortOrSubpath() throws {
        let store = makeFallbackStore()
        let cert = try fixtureCertificate()
        try store.add(URL(string: "https://mattermost-dev.example/dev")!, certificate: cert)
        XCTAssertTrue(store.isTrusted(URL(string: "https://mattermost-dev.example")!, certificate: cert))
        XCTAssertFalse(store.isTrusted(URL(string: "https://other.example")!, certificate: cert))
    }

    func testHttpsTrustAlsoMirrorsToWSSOrigin() throws {
        let store = makeFallbackStore()
        let cert = try fixtureCertificate()
        try store.add(serverURL(), certificate: cert)
        XCTAssertTrue(store.isTrusted(URL(string: "wss://mattermost-dev.example")!, certificate: cert),
                      "Desktop certificateStore.add also trusts wss:// on the same origin")
    }

    // MARK: Remove

    func testRemoveClearsTrustDecision() throws {
        let store = makeFallbackStore()
        let cert = try fixtureCertificate()
        try store.add(serverURL(), certificate: cert)
        XCTAssertTrue(store.isExisting(for: serverURL()))
        try store.remove(for: serverURL())
        XCTAssertFalse(store.isExisting(for: serverURL()))
        XCTAssertFalse(store.isTrusted(serverURL(), certificate: cert))
    }
}
