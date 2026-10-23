import Foundation
import Security
import CommonCrypto

/// A comparable fingerprint of a server certificate, mirroring the desktop
/// `types/certificate.ts` `ComparableCertificate`. Two certificates are equal when their DER
/// `data` AND `issuerName` match (desktop `areEqual`).
///
/// On iOS the DER bytes come from `SecCertificateCopyData`; the issuer label from the cert's
/// subject summary (a stable, human-readable per-cert string — the iOS analogue of Electron's
/// `issuerName` used to disambiguate re-issued certs carrying identical key material).
struct ComparableCertificate: Codable, Equatable {
    /// The certificate's raw DER bytes, base64-encoded for persistence/comparison.
    let data: String
    /// A stable per-certificate label (desktop `issuerName`; iOS: subject summary).
    let issuerName: String
    /// Whether this certificate was explicitly marked untrusted ("Don't ask again" cancel).
    let dontTrust: Bool

    init(data: String, issuerName: String, dontTrust: Bool = false) {
        self.data = data
        self.issuerName = issuerName
        self.dontTrust = dontTrust
    }
}

/// Display-facing certificate details — the iOS analogue of the Electron `Certificate` object
/// the desktop `ShowCertificateModal` renders (subject/issuer common names, serial number,
/// validity window, fingerprint). Built from a live `SecCertificate` at prompt time via
/// `CertTrust.info(from:)`; everything here is derived data, never persisted.
struct CertificateInfo: Equatable {
    /// Subject CN / the cert's subject summary line (desktop `subject.commonName`).
    var subject: String
    /// Issuer CN / the cert's issuer summary line (desktop `issuer.commonName`).
    var issuer: String
    /// Serial number as a hex string (desktop `serialNumber`).
    var serialNumber: String
    /// `notValidBefore` (desktop `validStart`; months floor to day precision).
    var notValidBefore: Date?
    /// `notValidAfter` (desktop `validExpiry`).
    var notValidAfter: Date?
    /// SHA-256 fingerprint, hex, colon-separated. Desktop splits `fingerprint.split('/')[0]`
    /// as the "Algorithm" row; ours shows the full fingerprint in the info sheet.
    var fingerprint: String

    init(subject: String, issuer: String, serialNumber: String,
         notValidBefore: Date?, notValidAfter: Date?, fingerprint: String) {
        self.subject = subject
        self.issuer = issuer
        self.serialNumber = serialNumber
        self.notValidBefore = notValidBefore
        self.notValidAfter = notValidAfter
        self.fingerprint = fingerprint
    }
}

/// A single server-trust decision the shell asks the user about — the payload carried from
/// the webview's `didReceive` challenge into the native `CertPromptSheet` (parity row:
/// desktop `certificateStore` + `modals/certificate` -> `CertPromptSheet`).
struct CertificatePrompt: Identifiable, Equatable {
    /// Stable identity for SwiftUI `.sheet(item:)`.
    var id: String { origin.absoluteString + "|" + certificate.data }
    /// The origin (scheme://host[:port]) whose certificate raised the prompt.
    var origin: URL
    /// The comparable fingerprint used to record the decision in the trust bag.
    var certificate: ComparableCertificate
    /// Richer display fields for the "Certificate Information" sheet, when derivable.
    var info: CertificateInfo?

    init(origin: URL, certificate: ComparableCertificate, info: CertificateInfo? = nil) {
        self.origin = origin
        self.certificate = certificate
        self.info = info
    }
}

/// Error surfaced when the certificate store cannot talk to the Keychain.
enum CertTrustError: Error, CustomStringConvertible {
    case keychainFailed(OSStatus)
    case cannotReadPresentedCertificate

    var description: String {
        switch self {
        case .keychainFailed(let s): return "Keychain operation failed (status \(s))"
        case .cannotReadPresentedCertificate: return "Could not read the presented server certificate"
        }
    }
}

/// Native counterpart of desktop `src/main/security/certificateStore.ts`: the user-confirmable
/// trust bag for self-signed / enterprise Mattermost server certificates. Parity row:
/// `certificateStore` -> `CertTrust` (trusted-cert-bag, persisted in Keychain, consulted by the
/// webview `didReceive` challenge). Status: native, Phase 2.
///
/// The desktop writes a JSON file keyed by `targetURL.origin`. On iOS we persist the *same*
/// trust decision in the OS Keychain instead (a `kSecClassGenericPassword` item per origin,
/// mirroring `SecureVault`'s service-per-identity pattern), so the trust decision —
/// `{ data, issuerName, dontTrust }` — survives relaunch and never sits in UserDefaults /
/// plaintext. The URL session's `didReceive` server-trust challenge consults
/// `isTrusted(for: presented:)` to auto-accept, and `isExplicitlyUntrusted` to hard-reject a
/// cert the user previously told us to refuse.
///
/// Security boundary: this is shell-only (`Core`), never reachable through `Bridge`/JS — a
/// page cannot add itself to the trust bag. Only the native challenge handler and the native
/// confimration flow (CertPromptSheet) call it.
final class CertTrust {

    /// Namespace inserted into every Keychain `service` so trust items never collide with the
    /// vault's items or another app's; tests forge a unique namespace per test.
    private let serviceNamespace: String

    init(serviceNamespace: String = Bundle.main.bundleIdentifier ?? "com.mattermost.ios") {
        self.serviceNamespace = serviceNamespace
    }

    // MARK: Trust queries (mirror desktop certificateStore surface)

    /// Whether a trust decision is recorded for `targetURL` (matched or refused).
    func isExisting(for targetURL: URL) -> Bool {
        guard let _ = stored(for: targetURL) else { return false }
        return true
    }

    /// Whether `certificate` (as presented by the server at `targetURL`) matches the recorded
    /// trust decision AND that decision was to trust it. Desktop `isTrusted`.
    func isTrusted(_ targetURL: URL, certificate: ComparableCertificate) -> Bool {
        guard let recorded = stored(for: targetURL) else { return false }
        return !recorded.dontTrust && Self.areEqual(recorded, b: certificate)
    }

    /// Whether we previously recorded an explicit "don't trust" for `targetURL` (the desktop
    /// "Don't ask again" cancel). When true we reject the connection without prompting.
    func isExplicitlyUntrusted(for targetURL: URL) -> Bool {
        self.stored(for: targetURL)?.dontTrust ?? false
    }

    /// The recorded certificate for `targetURL`, if any.
    func trustedCertificate(for targetURL: URL) -> ComparableCertificate? {
        stored(for: targetURL)
    }

    // MARK: Mutations (desktop add)

    /// Record a trust decision for `targetURL`'s origin. `dontTrust = true` marks the
    /// certificate explicitly refused (desktop "Don't ask again" + cancel). Also mirrors the
    /// cert to the `wss://` origin so websocket connections on the same host trust it too.
    func add(_ targetURL: URL, certificate: ComparableCertificate, dontTrust: Bool = false) throws {
        let record = ComparableCertificate(data: certificate.data,
                                           issuerName: certificate.issuerName,
                                           dontTrust: dontTrust)
        try persist(record, for: Self.canonicalOrigin(of: targetURL))
        // Desktop certificateStore.add also trusts wss:// on the same origin.
        if (targetURL.scheme?.lowercased() ?? "") == "https" {
            var wss = URLComponents()
            wss.scheme = "wss"
            wss.host = targetURL.host?.lowercased()
            if let port = targetURL.port, !Self.isDefaultPort(port, forScheme: "https") {
                wss.port = port
            }
            try persist(record, for: wss.string ?? Self.canonicalOrigin(of: targetURL))
        }
    }

    /// Remove a recorded decision for `targetURL` (desktop delete-on-server-removal).
    func remove(for targetURL: URL) throws {
        try delete(origin: Self.canonicalOrigin(of: targetURL))
    }

    // MARK: Equality (desktop areEqual)

    static func areEqual(_ a: ComparableCertificate, b: ComparableCertificate) -> Bool {
        a.data == b.data && a.issuerName == b.issuerName
    }

    // MARK: Certificate fingerprinting

    /// Build a `ComparableCertificate` from a live `SecCertificate`. `data` is the base64 DER
    /// (stable identity), `issuerName` the subject summary (stable per-cert label).
    static func comparable(from certificate: SecCertificate) throws -> ComparableCertificate {
        guard let der = SecCertificateCopyData(certificate) as? Data else {
            throw CertTrustError.cannotReadPresentedCertificate
        }
        // A stable per-cert label: prefer the subject summary; fall back to the raw issuer
        // sequence. Either way it is deterministic for a given certificate.
        var issuerName = "unknown"
        if let summary = SecCertificateCopySubjectSummary(certificate) as? String, !summary.isEmpty {
            issuerName = summary
        } else if let issuerSeq = SecCertificateCopyNormalizedIssuerSequence(certificate) as? Data {
            issuerName = String(data: issuerSeq, encoding: .utf8) ?? "unknown"
        }
        return ComparableCertificate(
            data: der.base64EncodedString(),
            issuerName: issuerName
        )
    }

    /// Build display-facing `CertificateInfo` from a live `SecCertificate` (desktop Electron
    /// `Certificate` used by `ShowCertificateModal`): subject, issuer, serial, and a SHA-256
    /// fingerprint. Validity dates are left nil: the iOS Security SDK does not expose the
    /// X.509 validity OIDs through `SecCertificateCopyValues` public headers, and the
    /// macOS-only `SecCertificateCopyValidityDates` is unavailable on iOS — so rather than
    /// guess OID string constants, the info sheet shows subject/issuer/serial/fingerprint
    /// (documented divergence in docs/t11-build-note.md). All optional readings fall back to
    /// empty/unknown so a partially readable cert still yields a useful prompt.
    static func info(from certificate: SecCertificate) -> CertificateInfo {
        let der = (SecCertificateCopyData(certificate) as Data?) ?? Data()
        let subject = (SecCertificateCopySubjectSummary(certificate) as String?) ?? "unknown"
        var issuer = "unknown"
        if let issuerSeq = SecCertificateCopyNormalizedIssuerSequence(certificate) as? Data,
           !issuerSeq.isEmpty {
            issuer = String(data: issuerSeq, encoding: .utf8) ?? "unknown"
        }
        var serial = ""
        if let serialData = SecCertificateCopySerialNumberData(certificate, nil) as Data? {
            serial = serialData.map { String(format: "%02X", $0) }.joined(separator: ":")
        }
        var fingerprint = ""
        if !der.isEmpty {
            let digest = der.sha256Digest()
            fingerprint = digest.map { String(format: "%02X", $0) }.joined(separator: ":")
        }
        return CertificateInfo(subject: subject, issuer: issuer, serialNumber: serial,
                               notValidBefore: nil, notValidAfter: nil,
                               fingerprint: fingerprint)
    }

    // MARK: Identity

    /// The origin key the desktop keys by (`scheme://host[:port]`). Sub-paths are not part of
    /// certificate identity — a certificate covers its whole origin.
    private static func canonicalOrigin(of url: URL) -> String {
        var out = URLComponents()
        out.scheme = (url.scheme ?? "https").lowercased()
        out.host = url.host?.lowercased()
        if let port = url.port, !isDefaultPort(port, forScheme: out.scheme) {
            out.port = port
        }
        out.path = ""
        out.query = nil
        out.fragment = nil
        // Rebuild from components; fall back to the absolute string only when unparsable.
        return out.string ?? url.absoluteString
    }

    private static func isDefaultPort(_ port: Int, forScheme scheme: String?) -> Bool {
        switch scheme { case "https": return port == 443; case "http": return port == 80; default: return false }
    }

    // MARK: Keychain persistence

    /// Access policy for *written* items: usable after first unlock, `ThisDeviceOnly` keeps the
    /// trust decision off iCloud/backups. Only the write (add/update) sets `kSecAttrAccessible`;
    /// the read/delete queries omit it — a trusted-value in a `SecItemCopyMatching` match query
    /// is unreliable on iOS and can surface `errSecInteractionNotAllowed`, so security-relevant
    /// match keys stay to class/service/account only (mirrors `SecureVault`, which reads without
    /// `kSecAttrAccessible` and is 12/12 green).
    private let accessible: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    private func baseQuery(for origin: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: origin),
            kSecAttrAccount as String: account,
        ]
        KeychainPlatform.apply(to: &query)
        return query
    }

    private func service(for origin: String) -> String {
        "\(serviceNamespace).certtrust.\(origin)"
    }

    private let account = "certificate"

    private func persist(_ record: ComparableCertificate, for origin: String) throws {
        guard let payload = try? JSONEncoder().encode(record) else { return }
        var query = baseQuery(for: origin)
        // The write sets the access policy (SecureVault parity).
        query[kSecAttrAccessible as String] = accessible
        if stored(origin: origin) != nil {
            // Update the existing item's payload in place (idempotent re-trust).
            var update = query
            update[kSecValueData as String] = payload
            let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard status == errSecSuccess else { throw CertTrustError.keychainFailed(status) }
        } else {
            var add = query
            add[kSecValueData as String] = payload
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw CertTrustError.keychainFailed(status) }
        }
    }

    private func delete(origin: String) throws {
        let query = baseQuery(for: origin)
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw CertTrustError.keychainFailed(status)
        }
    }

    private func stored(for targetURL: URL) -> ComparableCertificate? {
        stored(origin: Self.canonicalOrigin(of: targetURL))
    }

    private func stored(origin: String) -> ComparableCertificate? {
        var query = baseQuery(for: origin)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        guard let data = result as? Data else { return nil }
        let type = ComparableCertificate.self
        return try? JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Digest helper

extension Data {
    /// SHA-256 digest of the receiver (used to fingerprint a certificate's DER bytes).
    /// `CryptoKit` is overkill for a 30-line digest; this mirrors what the desktop's Electron
    /// `certificate.fingerprint` provides without adding a framework dependency.
    func sha256Digest() -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(count), &digest)
        }
        return Data(digest)
    }
}