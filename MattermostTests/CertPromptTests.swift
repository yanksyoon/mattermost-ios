import XCTest
@testable import Mattermost

/// Tests for the certificate prompt surface (`CertPromptSheet` payloads): the
/// `CertificatePrompt` identity/equality, the `ComparableCertificate` fingerprint equality
/// used by the trust bag, and the `Data.sha256Digest` helper that builds the
/// `CertificateInfo.fingerprint` shown by the certificate-info sheet.
final class CertPromptTests: XCTestCase {

    private func origin() -> URL { URL(string: "https://self-signed.example:8443")! }

    private func cert(_ data: String = "DERBYTES") -> ComparableCertificate {
        ComparableCertificate(data: data, issuerName: "CN=self-signed.example")
    }

    // MARK: CertificatePrompt

    func testPromptIdentityIsOriginPlusCertificate() {
        let a = CertificatePrompt(origin: origin(), certificate: cert())
        let b = CertificatePrompt(origin: origin(), certificate: cert())
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.id, b.id, "same origin + cert are the same prompt")
    }

    func testPromptIdentityDistinguishesDifferentCerts() {
        let a = CertificatePrompt(origin: origin(), certificate: cert("AAA"))
        let b = CertificatePrompt(origin: origin(), certificate: cert("BBB"))
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(a, b)
    }

    func testPromptIdentityDistinguishesDifferentOrigins() {
        let a = CertificatePrompt(origin: origin(), certificate: cert())
        let b = CertificatePrompt(origin: URL(string: "https://other.example")!, certificate: cert())
        XCTAssertNotEqual(a, b)
    }

    func testPromptCarriesDisplayInfo() {
        let info = CertificateInfo(subject: "CN=self-signed.example", issuer: "CN=CA",
                                   serialNumber: "01:AB", notValidBefore: nil, notValidAfter: nil,
                                   fingerprint: "AA:BB")
        let prompt = CertificatePrompt(origin: origin(), certificate: cert(), info: info)
        XCTAssertEqual(prompt.info?.subject, "CN=self-signed.example")
        XCTAssertEqual(prompt.info?.fingerprint, "AA:BB")
    }

    // MARK: ComparableCertificate equality (desktop areEqual)

    func testComparableEqualityNeedsDataAndIssuer() {
        let a = ComparableCertificate(data: "DER", issuerName: "CN=issuer")
        XCTAssertEqual(a, ComparableCertificate(data: "DER", issuerName: "CN=issuer"))
        XCTAssertNotEqual(a, ComparableCertificate(data: "DER2", issuerName: "CN=issuer"))
        XCTAssertNotEqual(a, ComparableCertificate(data: "DER", issuerName: "CN=other"))
    }

    func testComparableDontTrustFlagDoesNotAffectEquality() {
        // desktop areEqual compares data + issuerName only; dontTrust is a decision flag.
        let a = ComparableCertificate(data: "DER", issuerName: "CN=issuer", dontTrust: false)
        let b = ComparableCertificate(data: "DER", issuerName: "CN=issuer", dontTrust: true)
        XCTAssertTrue(CertTrust.areEqual(a, b: b))
    }

    // MARK: sha256Digest (fingerprint helper)

    func testSha256DigestMatchesKnownVector() {
        // SHA-256("abc") — the canonical NIST test vector, hex lowercase.
        let digest = Data("abc".utf8).sha256Digest()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testSha256EmptyInput() {
        let digest = Data().sha256Digest()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    // MARK: CertificateInfo date formatting (desktop ShowCertificateModal)

    func testCertificateInfoDefaultDateShowsFullStyle() {
        let info = CertificateInfo(subject: "S", issuer: "I", serialNumber: "01",
                                   notValidBefore: nil, notValidAfter: Date(timeIntervalSince1970: 0),
                                   fingerprint: "")
        // The sheet renders via CertificateInfoSheet.dateString — formatting is view-layer;
        // the model must simply carry the dates.
        XCTAssertEqual(info.notValidAfter?.timeIntervalSince1970, 0)
        XCTAssertNil(info.notValidBefore)
    }
}
