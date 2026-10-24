import Foundation
import XCTest
@testable import Mattermost

/// T28 acceptance criterion: **a native REST call succeeds after the user trusts the certificate
/// via the existing `CertPromptSheet`** — a self-signed server that works in the webview must work
/// natively.
///
/// This is the one test that needs a real TLS peer. `scripts/t28-selfsigned-check.sh` generates a
/// throwaway certificate, starts an HTTPS fixture on `127.0.0.1:18443` serving
/// `GET /api/v4/system/ping`, and runs this suite. With no fixture listening the test skips, so the
/// rest of the suite stays runnable with no network and no configuration.
///
/// Deliberately no environment variables and no fixture files are read: the certificate under test
/// is the one the *server presents*, captured from the prompt the transport raises — exactly the
/// object `CertPromptSheet` records when the user taps Trust.
final class SelfSignedTrustTests: XCTestCase {

    /// The port `scripts/t28-selfsigned-check.sh` starts the fixture on.
    private static let fixtureURL = URL(string: "https://127.0.0.1:18443")!

    /// Thread-safe prompt capture (the transport calls back on a URLSession delegate queue).
    private final class PromptBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [CertificatePrompt] = []

        var prompts: [CertificatePrompt] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func append(_ prompt: CertificatePrompt) {
            lock.lock()
            defer { lock.unlock() }
            storage.append(prompt)
        }
    }

    func testNativeCallFailsUntrustedThenSucceedsAfterTheCertificateIsTrusted() async throws {
        let serverURL = Self.fixtureURL
        // Isolated trust bag: the test can neither inherit nor pollute the app's real decisions.
        let certTrust = CertTrust(serviceNamespace: "t28-selfsigned-\(UUID().uuidString)")
        try? certTrust.remove(for: serverURL)

        let prompts = PromptBox()
        let transport = URLSessionTransport(serverURL: serverURL,
                                            certTrust: certTrust,
                                            onUntrustedCertificate: { prompts.append($0) })
        let client = try APIClient(serverURL: serverURL,
                                   transport: transport,
                                   retryPolicy: APIClient.RetryPolicy.none,
                                   tokenProvider: { nil })

        // 1. First native call: the chain is not trusted and the bag holds no decision for this
        //    origin, so the request fails with the typed certificate error and a prompt is raised.
        do {
            _ = try await client.ping()
            XCTFail("the first call must not succeed before the user trusts the certificate")
        } catch let error as MMError {
            switch error {
            case .certificateUntrusted:
                break // expected
            case .offline, .timeout, .transport:
                throw XCTSkip("no self-signed fixture on \(serverURL): run scripts/t28-selfsigned-check.sh")
            default:
                throw error
            }
        }

        let prompt = try XCTUnwrap(prompts.prompts.first,
                                  "an untrusted certificate must raise a prompt")
        XCTAssertEqual(prompt.origin.host, "127.0.0.1")
        XCTAssertFalse(prompt.certificate.data.isEmpty)
        let info = try XCTUnwrap(prompt.info, "the prompt carries display details for the sheet")
        XCTAssertFalse(info.fingerprint.isEmpty)

        // 2. What `CertPromptSheet`'s Trust button does: record the decision in the same bag.
        try certTrust.add(prompt.origin, certificate: prompt.certificate)

        // 3. Retry through the same trust bag: the transport now accepts this certificate.
        let pong = try await client.ping()
        XCTAssertEqual(pong.status, "OK")
        XCTAssertEqual(pong.version, "t28-selfsigned", "served by the local TLS fixture")
    }

    // MARK: - The real wss transport (T28-AV F8)

    /// Collects transport events until `predicate` matches or the timeout elapses.
    private func collect(_ transport: WebSocketTransport,
                         timeout: TimeInterval,
                         until predicate: @escaping (SocketTransportEvent) -> Bool) async -> [SocketTransportEvent] {
        await withTaskGroup(of: [SocketTransportEvent].self) { group in
            group.addTask {
                var events: [SocketTransportEvent] = []
                for await event in transport.events {
                    events.append(event)
                    if predicate(event) { break }
                }
                return events
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return []
            }
            let result = await group.next() ?? []
            group.cancelAll()
            return result
        }
    }

    /// Every other socket test uses `ScriptedSocketTransport`, and the self-signed evidence covered
    /// HTTPS only, so the `wss` trust path rested on inspection. This drives the **real**
    /// `URLSessionWebSocketTask` transport against the fixture's WebSocket endpoint: an untrusted
    /// certificate fails the handshake (and raises the prompt `CertPromptSheet` shows), and once
    /// the decision is in `CertTrust` the same transport opens and receives the fixture's `hello`.
    func testRealWebSocketTransportOpensOnlyAfterTheCertificateIsTrusted() async throws {
        let serverURL = Self.fixtureURL
        let socketURL = URL(string: "wss://127.0.0.1:18443/api/v4/websocket")!
        // Isolated bag: this test can neither inherit nor pollute the app's decisions.
        let certTrust = CertTrust(serviceNamespace: "t28-wss-\(UUID().uuidString)")
        try? certTrust.remove(for: serverURL)

        let prompts = PromptBox()
        let refused = WebSocketTransport(url: socketURL,
                                         headers: [:],
                                         serverURL: serverURL,
                                         certTrust: certTrust,
                                         onUntrustedCertificate: { prompts.append($0) })
        refused.resume()
        let refusedEvents = await collect(refused, timeout: 8) { event in
            switch event {
            case .opened, .failed, .closed: return true
            case .text: return false
            }
        }
        refused.close()

        guard let prompt = prompts.prompts.first else {
            throw XCTSkip("no self-signed wss fixture on \(socketURL): run scripts/t28-selfsigned-check.sh")
        }
        XCTAssertFalse(refusedEvents.contains(.opened),
                       "an untrusted certificate must not open the socket")
        XCTAssertTrue(refusedEvents.contains { if case .failed = $0 { return true } else { return false } },
                      "the wss handshake must fail typed, got \(refusedEvents)")
        XCTAssertEqual(prompt.origin.host, "127.0.0.1")
        XCTAssertFalse(prompt.certificate.data.isEmpty)

        // What `CertPromptSheet`'s Trust button does.
        try certTrust.add(prompt.origin, certificate: prompt.certificate)

        let accepted = WebSocketTransport(url: socketURL,
                                          headers: ["Origin": "https://127.0.0.1:18443"],
                                          serverURL: serverURL,
                                          certTrust: certTrust)
        accepted.resume()
        let acceptedEvents = await collect(accepted, timeout: 10) { event in
            if case .text = event { return true }
            return false
        }
        accepted.close()

        XCTAssertTrue(acceptedEvents.contains(.opened),
                      "after trusting the certificate the real wss transport must open, got \(acceptedEvents)")
        let frames = acceptedEvents.compactMap { event -> String? in
            if case .text(let text) = event { return text }
            return nil
        }
        let hello = try XCTUnwrap(frames.first, "the fixture's hello frame must arrive, got \(acceptedEvents)")
        XCTAssertTrue(hello.contains("\"hello\""), "got \(hello)")
        XCTAssertTrue(hello.contains("t28-fixture"), "got \(hello)")
    }

    /// A re-issued certificate is a new decision: the bag must not hand it the old trust.
    func testReissuedCertificatePromptsAgainInsteadOfInheritingTrust() {
        let recorded = ComparableCertificate(data: "b2xkLWNlcnQ=", issuerName: "mm.internal")
        let reissued = ComparableCertificate(data: "bmV3LWNlcnQ=", issuerName: "mm.internal")

        let decision = ServerTrustPolicy.decision(challengeHost: "mm.internal",
                                                  serverHost: "mm.internal",
                                                  systemValidates: false,
                                                  presented: reissued,
                                                  recorded: recorded,
                                                  explicitlyUntrusted: false)
        XCTAssertEqual(decision, .prompt,
                       "a different certificate is a new decision — trust is never inherited")
    }
}
