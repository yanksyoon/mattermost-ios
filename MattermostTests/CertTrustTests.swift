import XCTest
import Security
@testable import Mattermost

/// Unit tests for `CertTrust` (desktop `src/main/security/certificateStore.ts`), the
/// Keychain-persisted user-confirmable trust bag consulted by the webview TLS challenge.
///
/// The headline item is that trust for a self-signed Mattermost server certificate is
/// remembered across instances (Keychain persistence, like SecureVault) and that only an
/// exact-match accepted certificate is trusted — an untrusted or different cert never passes.
///
/// Every test forges a unique `serviceNamespace` so Keychain items never collide with the
/// app's real store or other tests, mirroring the SecureVault tests.
final class CertTrustTests: XCTestCase {

    /// A real self-signed X.509 cert DER, base64. Generated once with openssl for the suite:
    ///   openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
    ///     -subj "/CN=mattermost-dev.example/O=MattermostDev"
    private static let selfSignedDERB64 = "MIIC7jCCAdYCCQDOe9KUgEi62DANBgkqhkiG9w0BAQsFADA5MR8wHQYDVQQDDBZtYXR0ZXJtb3N0LWRldi5leGFtcGxlMRYwFAYDVQQKDA1NYXR0ZXJtb3N0RGV2MB4XDTI2MTAyMTE4NTgyNFoXDTI2MTEyMDE4NTgyNFowOTEfMB0GA1UEAwwWbWF0dGVybW9zdC1kZXYuZXhhbXBsZTEWMBQGA1UECgwNTWF0dGVybW9zdERldjCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBANwtuZSY5Ujr2aBzcH7hyl51WYj/tcH6DmgvJww2tsjzAVodQDYxy+vCsAV0crOK8YkIUK3Kxd39R2aaJJD+jni1eIICMhjD+yxj/0JawGwoEb9+/FJq+UWMymP2vZbnB++vdusiLNXgBAxcRaV9zPDO07T4xcaZPdl+r+sip4XKU8WB72qa8PEMJXQcfbssmvHlY6uppgnlMKKbUZy8vverTYC9kpbdcXtyL1uBj2dsAqUMmYg2BQ2tix/H6Q3/Fj6r5+nUE6kxVhFPurxnT/tzhMhAnRftvVLI6WTX1AObH7yqcL93z2Dk52Gh8aO88MLtSks7yCEbUEG3tY9FPeMCAwEAATANBgkqhkiG9w0BAQsFAAOCAQEAnpqpETn0nK9/2DmveQml/P/Wvyp4mPhkjUQDUqLmOeMtpgBlvHcJ55d0MRx0EodI6+6LCAixI3nH+xk0rViV53hEE+4nkX58XsQByQRdtKLHR7RepB8xqwsgsFWVt0xdeR5nKhzfDTt+ftsi7c7KSozOKioS5imxNaDkgrzA1ELMrrRi32675EPBTnHvtmQXAjnJBxSRA6CY0mAhNXePXg7R0OzzOFGvU/DngKrlcmpUqR7RfjNNOBOUPM+tswBTsRD4PIalwbSTWTCVBc5hlyCwpxGvbtQHaEHZx0vxjeJnTasSqxdUFtUtVMQUiWeR72yciBweA9l0OjCfZODUcw=="

    private func makeStore() -> CertTrust {
        CertTrust(serviceNamespace: "CertTrustTests-\(UUID().uuidString)")
    }

    private func serverURL(_ string: String = "https://mattermost-dev.example") -> URL {
        URL(string: string)!
    }

    /// Load the fixture cert into a live `SecCertificate`, then fingerprint it exactly as the
    /// webview challenge does (the full SecCertificate -> ComparableCertificate pipeline).
    private func fixtureCertificate() throws -> ComparableCertificate {
        guard let der = Data(base64Encoded: CertTrustTests.selfSignedDERB64) else {
            throw CertTrustError.cannotReadPresentedCertificate
        }
        guard let cert = SecCertificateCreateWithData(nil, der as CFData) else {
            throw CertTrustError.cannotReadPresentedCertificate
        }
        return try CertTrust.comparable(from: cert)
    }

    /// A *different* certificate (valid DER, different subject) to prove exact-match trust.
    private func otherCertificate() throws -> ComparableCertificate {
        ComparableCertificate(data: "QIAAAA=", issuerName: "CN=other.example")
    }

    // MARK: Keychain persistence (the headline: trust survives a fresh store instance)

    func testTrustSurvivesFreshStoreInstance_simulatingRelaunch() throws {
        let namespace = "CertTrustTests-relaunch-\(UUID().uuidString)"
        let cert = try fixtureCertificate()
        let first = CertTrust(serviceNamespace: namespace)
        try first.add(serverURL(), certificate: cert)

        // A brand-new store (as after a relaunch) in the same namespace must remember trust.
        let second = CertTrust(serviceNamespace: namespace)
        XCTAssertTrue(second.isExisting(for: serverURL()))
        XCTAssertTrue(second.isTrusted(serverURL(), certificate: cert))
        XCTAssertFalse(second.isExplicitlyUntrusted(for: serverURL()))
    }

    // MARK: Trust decision semantics

    func testExactCertificateIsTrustedAndDifferentIsNot() throws {
        let store = makeStore()
        let cert = try fixtureCertificate()
        try store.add(serverURL(), certificate: cert)
        XCTAssertTrue(store.isExisting(for: serverURL()))
        XCTAssertTrue(store.isTrusted(serverURL(), certificate: cert))
        // A different cert for the same origin must not pass.
        let other = try otherCertificate()
        XCTAssertFalse(store.isTrusted(serverURL(), certificate: other))
        XCTAssertFalse(store.isExisting(for: serverURL("https://unrelated.example")))
    }

    func testUntrustedOriginIsNotTrusted() throws {
        let store = makeStore()
        // No decision recorded -> not trusted, not existing, not explicitly untrusted.
        let cert = try fixtureCertificate()
        XCTAssertFalse(store.isTrusted(serverURL(), certificate: cert))
        XCTAssertFalse(store.isExisting(for: serverURL()))
        XCTAssertFalse(store.isExplicitlyUntrusted(for: serverURL()))
    }

    // MARK: "Don't ask again" (dontTrust)

    func testExplicitlyUntrustedCertificateIsRefusedEvenIfPresented() throws {
        let store = makeStore()
        let cert = try fixtureCertificate()
        try store.add(serverURL(), certificate: cert, dontTrust: true)
        XCTAssertTrue(store.isExplicitlyUntrusted(for: serverURL()))
        XCTAssertFalse(store.isTrusted(serverURL(), certificate: cert))
    }

    // MARK: Origin keying

    func testTrustIsScopedPerOriginNotPerPortOrSubpath() throws {
        let store = makeStore()
        let cert = try fixtureCertificate()
        try store.add(URL(string: "https://mattermost-dev.example/dev")!, certificate: cert)
        // Same origin, sub-path -> still trusted (certificates cover their whole origin).
        XCTAssertTrue(store.isTrusted(URL(string: "https://mattermost-dev.example")!, certificate: cert))
        // Different host -> isolated.
        XCTAssertFalse(store.isTrusted(URL(string: "https://other.example")!, certificate: cert))
    }

    // MARK: Remove

    func testRemoveClearsTrustDecision() throws {
        let store = makeStore()
        let cert = try fixtureCertificate()
        try store.add(serverURL(), certificate: cert)
        XCTAssertTrue(store.isExisting(for: serverURL()))
        try store.remove(for: serverURL())
        XCTAssertFalse(store.isExisting(for: serverURL()))
        XCTAssertFalse(store.isTrusted(serverURL(), certificate: cert))
    }

    // MARK: Equality (desktop areEqual)

    func testAreEqualRequiresDataAndIssuer() {
        let a = ComparableCertificate(data: "abc", issuerName: "CN=iss")
        XCTAssertTrue(CertTrust.areEqual(a, b: ComparableCertificate(data: "abc", issuerName: "CN=iss")))
        XCTAssertFalse(CertTrust.areEqual(a, b: ComparableCertificate(data: "abc", issuerName: "CN=other")))
        XCTAssertFalse(CertTrust.areEqual(a, b: ComparableCertificate(data: "abd", issuerName: "CN=iss")))
    }
}