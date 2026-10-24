// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0,
// `ios/Gekidou/Sources/Gekidou/Networking/Network+Delegate.swift` (the `URLSession` server-trust
// hook) and this repo's `Mattermost/UI/WebViewContainer.swift` (`didReceive challenge`). Own
// implementation per docs/path-b-adr.md §3: upstream validates against a bundled certificate
// pinning list and hard-cancels on mismatch; this app's trust model is the user-confirmed,
// per-origin `CertTrust` bag the webview already uses, so both transports must share it or a
// self-signed server would work in the webview and fail natively (T28 acceptance criterion 4).

import Foundation
import Security

/// The four answers a TLS server-trust challenge can receive.
enum ServerTrustDecision: Equatable {
    /// Let `URLSession` apply the system policy (public chains, and third-party hosts).
    case performDefaultHandling
    /// The user already trusted this exact certificate for this origin: accept it.
    case accept
    /// The user previously refused this certificate ("Don't ask again"): hard-reject.
    case reject
    /// Unseen certificate for the user's own server: surface `CertPromptSheet` and let the
    /// request fail while the sheet is up (the retry after the decision succeeds).
    case prompt
}

/// The pure trust decision shared by `URLSessionTransport` (HTTP) and `WebSocketTransport` (wss).
///
/// Kept free of `URLSession` and `SecTrust` so the whole matrix — third-party host, publicly
/// valid chain, recorded accept, recorded refusal, first sight — is unit-testable, and so the
/// native path provably matches the webview's `WebViewContainer` decision order
/// (`ServerTrustPolicyTests.testScopeMatchesWebviewCertificatePolicy`).
enum ServerTrustPolicy {

    enum Scope: Equatable {
        /// The configured Mattermost server: the trust bag applies.
        case serverOrigin
        /// An SSO identity provider, a CDN, an integration: the system chain alone decides.
        case thirdParty
    }

    /// Which host a challenge belongs to. Same rule as
    /// `WebViewContainer.CertChallengePolicy.scope(challengeHost:serverHost:)`.
    static func scope(challengeHost: String, serverHost: String?) -> Scope {
        guard let serverHost, !serverHost.isEmpty else { return .thirdParty }
        return challengeHost.caseInsensitiveCompare(serverHost) == .orderedSame ? .serverOrigin : .thirdParty
    }

    /// Decide a server-trust challenge.
    ///
    /// - Parameters:
    ///   - challengeHost: the host that presented the certificate.
    ///   - serverHost: the configured server's host (nil when unknown → third party).
    ///   - systemValidates: `SecTrustEvaluateWithError` on the presented chain.
    ///   - presented: the leaf certificate, when readable.
    ///   - recorded: the trust bag's record for this origin, when one exists.
    ///   - explicitlyUntrusted: the recorded decision was "don't ask again".
    static func decision(challengeHost: String,
                         serverHost: String?,
                         systemValidates: Bool,
                         presented: ComparableCertificate?,
                         recorded: ComparableCertificate?,
                         explicitlyUntrusted: Bool) -> ServerTrustDecision {
        // A certificate covering a host other than the user's server is judged by the system
        // alone: refusing an IdP's public certificate used to blank the SSO page (T22 regression).
        guard scope(challengeHost: challengeHost, serverHost: serverHost) == .serverOrigin else {
            return .performDefaultHandling
        }
        // A chain the system already validates needs no decision from us.
        if systemValidates { return .performDefaultHandling }
        // Unreadable certificate: never grant trust we cannot reason about.
        guard let presented else { return .performDefaultHandling }
        if explicitlyUntrusted { return .reject }
        if let recorded, !recorded.dontTrust, CertTrust.areEqual(recorded, b: presented) {
            return .accept
        }
        return .prompt
    }

    /// The HTTPS origin URL a challenge is scoped to (the `CertTrust` key shape).
    static func originURL(host: String, port: Int) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        if port > 0, port != 443 { components.port = port }
        return components.url
    }

    /// The leaf (server) certificate from a `SecTrust` chain, as the comparable fingerprint the
    /// trust bag stores. Index 0 is always the leaf.
    static func leafCertificate(from trust: SecTrust?) -> (certificate: ComparableCertificate, info: CertificateInfo?)? {
        guard let trust, SecTrustGetCertificateCount(trust) > 0,
              let leaf = SecTrustGetCertificateAtIndex(trust, 0),
              let comparable = try? CertTrust.comparable(from: leaf) else {
            return nil
        }
        return (comparable, CertTrust.info(from: leaf))
    }
}
