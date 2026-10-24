import Foundation
import XCTest
@testable import Mattermost

/// T28 acceptance criterion 4: the native transports must make the *same* certificate decision as
/// the webview. `ServerTrustPolicy` is the pure decision matrix; these tests pin it, and one test
/// asserts the scope rule is identical to `WebViewContainer.CertChallengePolicy` so the two paths
/// cannot drift.
final class ServerTrustPolicyTests: XCTestCase {

    private let presented = ComparableCertificate(data: "ZGVyLWxlYWY=", issuerName: "mm.internal")
    private let otherCert = ComparableCertificate(data: "ZGVyLW90aGVy", issuerName: "mm.internal")

    // MARK: - Scope

    func testOnlyTheConfiguredServerUsesTheTrustBag() {
        XCTAssertEqual(ServerTrustPolicy.scope(challengeHost: "mm.example.com",
                                               serverHost: "mm.example.com"), .serverOrigin)
        XCTAssertEqual(ServerTrustPolicy.scope(challengeHost: "MM.Example.com",
                                               serverHost: "mm.example.com"), .serverOrigin)
        XCTAssertEqual(ServerTrustPolicy.scope(challengeHost: "login.okta.com",
                                               serverHost: "mm.example.com"), .thirdParty)
        XCTAssertEqual(ServerTrustPolicy.scope(challengeHost: "mm.example.com",
                                               serverHost: ""), .thirdParty)
        XCTAssertEqual(ServerTrustPolicy.scope(challengeHost: "mm.example.com",
                                               serverHost: nil), .thirdParty)
    }

    /// Parity guard: if someone changes one scoping rule, this fails before an SSO page blanks.
    func testScopeMatchesWebviewCertificatePolicy() {
        let hosts = ["mm.example.com", "MM.EXAMPLE.COM", "login.okta.com", "", "127.0.0.1"]
        let servers: [String?] = ["mm.example.com", "login.okta.com", "", nil]
        for host in hosts {
            for server in servers {
                let native = ServerTrustPolicy.scope(challengeHost: host, serverHost: server)
                let webview = WebViewContainer.CertChallengePolicy.scope(challengeHost: host,
                                                                        serverHost: server)
                let expected: WebViewContainer.CertChallengePolicy.Scope =
                    native == .serverOrigin ? .serverOrigin : .thirdParty
                XCTAssertEqual(webview, expected,
                               "scope mismatch for host=\(host) server=\(server ?? "nil")")
            }
        }
    }

    // MARK: - Decision matrix

    func testThirdPartyHostAlwaysUsesTheSystemPolicy() {
        // Even an "untrusted" chain for an IdP is left to the system: we never prompt for it.
        XCTAssertEqual(ServerTrustPolicy.decision(challengeHost: "login.okta.com",
                                                  serverHost: "mm.example.com",
                                                  systemValidates: false,
                                                  presented: presented,
                                                  recorded: nil,
                                                  explicitlyUntrusted: false),
                       .performDefaultHandling)
    }

    func testPubliclyValidChainUsesTheSystemPolicy() {
        XCTAssertEqual(ServerTrustPolicy.decision(challengeHost: "mm.example.com",
                                                  serverHost: "mm.example.com",
                                                  systemValidates: true,
                                                  presented: presented,
                                                  recorded: nil,
                                                  explicitlyUntrusted: false),
                       .performDefaultHandling)
    }

    func testRecordedTrustAcceptsTheSameCertificate() {
        XCTAssertEqual(ServerTrustPolicy.decision(challengeHost: "mm.example.com",
                                                  serverHost: "mm.example.com",
                                                  systemValidates: false,
                                                  presented: presented,
                                                  recorded: presented,
                                                  explicitlyUntrusted: false),
                       .accept)
    }

    func testRecordedTrustDoesNotAcceptAReissuedCertificate() {
        XCTAssertEqual(ServerTrustPolicy.decision(challengeHost: "mm.example.com",
                                                  serverHost: "mm.example.com",
                                                  systemValidates: false,
                                                  presented: otherCert,
                                                  recorded: presented,
                                                  explicitlyUntrusted: false),
                       .prompt,
                       "a different certificate is a new decision, never inherited trust")
    }

    func testExplicitRefusalHardRejectsWithoutPrompting() {
        let refused = ComparableCertificate(data: presented.data,
                                            issuerName: presented.issuerName,
                                            dontTrust: true)
        XCTAssertEqual(ServerTrustPolicy.decision(challengeHost: "mm.example.com",
                                                  serverHost: "mm.example.com",
                                                  systemValidates: false,
                                                  presented: presented,
                                                  recorded: refused,
                                                  explicitlyUntrusted: true),
                       .reject)
    }

    func testUnseenCertificatePromptsOnTheUsersOwnServer() {
        XCTAssertEqual(ServerTrustPolicy.decision(challengeHost: "mm.example.com",
                                                  serverHost: "mm.example.com",
                                                  systemValidates: false,
                                                  presented: presented,
                                                  recorded: nil,
                                                  explicitlyUntrusted: false),
                       .prompt)
    }

    func testUnreadableCertificateNeverGrantsTrust() {
        XCTAssertEqual(ServerTrustPolicy.decision(challengeHost: "mm.example.com",
                                                  serverHost: "mm.example.com",
                                                  systemValidates: false,
                                                  presented: nil,
                                                  recorded: nil,
                                                  explicitlyUntrusted: false),
                       .performDefaultHandling)
    }

    // MARK: - Origin shaping (the CertTrust key)

    func testOriginURLDropsTheDefaultPortAndKeepsACustomOne() {
        XCTAssertEqual(ServerTrustPolicy.originURL(host: "mm.example.com", port: 443)?.absoluteString,
                       "https://mm.example.com")
        XCTAssertEqual(ServerTrustPolicy.originURL(host: "127.0.0.1", port: 8443)?.absoluteString,
                       "https://127.0.0.1:8443")
    }

    // MARK: - Error mapping

    func testURLErrorMappingIsTyped() {
        XCTAssertEqual(URLSessionTransport.map(URLError(.timedOut), origin: "o"), .timeout)
        XCTAssertEqual(URLSessionTransport.map(URLError(.notConnectedToInternet), origin: "o"), .offline)
        XCTAssertEqual(URLSessionTransport.map(URLError(.cancelled), origin: "o"), .cancelled)
        XCTAssertEqual(URLSessionTransport.map(URLError(.serverCertificateUntrusted), origin: "o"),
                       .certificateUntrusted(origin: "o"))
        XCTAssertEqual(URLSessionTransport.map(URLError(.serverCertificateHasUnknownRoot), origin: "o"),
                       .certificateUntrusted(origin: "o"))
    }
}
