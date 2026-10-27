import Foundation
import WebKit
import XCTest
@testable import Mattermost

// T31 (follow-up): **harvest the webview's session for the native stack.**
//
// The shell's normal sign-in is the web view: Path A ships the Mattermost SPA, and its login (or the
// SSO/SAML hand-off that is deliberately kept there) authenticates by writing an `HttpOnly`
// `MMAUTHTOKEN` cookie into that server's isolated `WKWebsiteDataStore`. Every native surface after
// that — the rail's `/teams`, the channel list, the socket, the panes — authenticates from the
// **vault**, through `AuthSession.client`. So without a harvest the app is in two states at once: the
// web pane is signed in and the native stack is signed out, which renders the native sign-in surface
// for a user who is plainly signed in.
//
// What is pinned here, in the order the risk sits:
//   1. a launch with **no** vault token and a webview cookie adopts the cookie, and the very next
//      native request carries it (the observable the panes depend on);
//   2. the adoption persists the token, so the *next* launch restores from the vault even when the
//      webview's cookie is gone;
//   3. a cookie the server rejects leaves nothing behind and does not pretend to be a session;
//   4. a **rejected vault token** still expires the session; it must not fall through to adoption,
//      which would race the expiry's cookie clear and could re-sign-in on a refused credential;
//   5. the production wiring reads the **server's own** website-data store (the reader a webview
//      login actually writes), not WebKit's `.default()` one.

// MARK: - Fakes

/// Records which server's session was asked for, so "the harvest used *this* server's store" is an
/// assertion and not a reading of the code.
@MainActor
final class RecordingCookieReader: SessionCookieReading {
    private let token: String?
    private(set) var asked: [URL] = []

    init(token: String?) { self.token = token }

    func authToken(for serverURL: URL) async -> String? {
        asked.append(serverURL)
        return token
    }
}

/// A transport that is specific about **which** token it accepts, so a test can prove that the path
/// which ran is the one that decided the outcome: `acceptedToken` answers 200, everything else 401.
final class TokenAwareTransport: APITransport {
    private let acceptedToken: String
    private let lock = NSLock()
    private var seen: [APIRequest] = []

    init(acceptedToken: String) { self.acceptedToken = acceptedToken }

    var requests: [APIRequest] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    func send(_ request: APIRequest) async throws -> APIResponse {
        lock.lock()
        seen.append(request)
        lock.unlock()
        if request.headers["Authorization"] == "Bearer \(acceptedToken)" {
            return .json(["id": "u1", "username": "grace", "email": "grace@example.com"])
        }
        return .json(["id": "api.context.session_expired.app_error",
                      "message": "Session expired",
                      "status_code": 401], status: 401)
    }
}

// MARK: - The harvest

@MainActor
final class T31WebSessionHarvestTests: XCTestCase {

    private var vault: SecureVault!
    private var certTrust: CertTrust!
    private var cookies: FakeCookieClearing!
    private var server: ServerConfig!
    private let serverURL = URL(string: "https://mm.example.com")!

    override func setUp() {
        super.setUp()
        vault = SecureVault(serviceNamespace: "t31harvest-\(UUID().uuidString)",
                            secureStore: InMemorySecretStore())
        certTrust = CertTrust(serviceNamespace: "t31harvest-cert-\(UUID().uuidString)",
                              secureStore: InMemorySecretStore())
        cookies = FakeCookieClearing()
        server = ServerConfig(name: "Test Server", url: serverURL)
    }

    /// The coordinator as the app builds it, except for the transport and the cookie read.
    private func makeCoordinator(_ transport: FakeAPITransport,
                                 reader: SessionCookieReading? = nil) -> AuthCoordinator {
        makeCoordinator(transport: transport, reader: reader)
    }

    /// Same construction for a transport that is not the scripted fake (the token-aware one below).
    private func makeCoordinator(transport: APITransport,
                                 reader: SessionCookieReading? = nil) -> AuthCoordinator {
        let vault = self.vault!
        let certTrust = self.certTrust!
        return AuthCoordinator(vault: vault,
                              certTrust: certTrust,
                              cookieClearing: cookies,
                              cookieReader: reader.map { scripted in { _ in scripted } }) { config, _ in
            let client = try APIClient(serverURL: config.url,
                                       transport: transport,
                                       retryPolicy: .none,
                                       tokenProvider: { vault.getSecret(key: .authToken,
                                                                       serverURL: config.url) },
                                       sleep: { _ in },
                                       random: { 0 })
            return AuthSession(serverID: config.id, serverURL: config.url, vault: vault, client: client)
        }
    }

    private func userJSON(username: String = "grace") -> [String: Any] {
        ["id": "u1", "username": username, "email": "grace@example.com"]
    }

    private func payload(_ id: String, _ message: String, status: Int) -> APIResponse {
        .json(["id": id, "message": message, "status_code": status], status: status)
    }

    // MARK: 1. A webview-only session becomes a native one

    /// The card in one test: the vault holds nothing, the webview holds a session, and after launch
    /// the native transport is authenticated with that session — not rendered as signed out.
    func testRestoreAdoptsAWebviewOnlySessionAndAuthenticatesTheNativeTransport() async throws {
        let reader = RecordingCookieReader(token: "sso-cookie-token")
        let transport = FakeAPITransport(stubs: [.ok(.json(userJSON()))])
        let coordinator = makeCoordinator(transport, reader: reader)
        XCTAssertEqual(coordinator.authState(for: server), .signedOut,
                       "precondition: the vault has no token, so the gate starts signed out")
        var notified: [UUID] = []
        coordinator.onChange = { notified.append($0) }

        let restored = try await coordinator.restore(server)

        XCTAssertEqual(restored?.username, "grace")
        XCTAssertEqual(coordinator.phase(for: server.id),
                       .signedIn(username: "grace", userID: "u1"),
                       "a login done in the webview must reach the native auth state machine")
        XCTAssertEqual(coordinator.authState(for: server), .signedIn,
                       "the shell's gate is what decides between the sign-in surface and the workspace")
        XCTAssertEqual(vault.getSecret(key: .authToken, serverURL: serverURL), "sso-cookie-token",
                       "the harvested token is persisted — the native transport reads the vault")
        XCTAssertEqual(transport.lastRequest?.url.path, "/api/v4/users/me")
        XCTAssertEqual(transport.lastRequest?.headers["Authorization"], "Bearer sso-cookie-token",
                       "the identity call that verifies the cookie is *itself* authenticated by it: "
                       + "without that, adoption could only ever fail")
        XCTAssertEqual(reader.asked, [serverURL],
                       "the harvest reads this server's session, once")
        XCTAssertEqual(notified, [server.id],
                       "the shell is told once, so the native panes can reload against the credential")
    }

    /// And the next launch does not need the webview at all: the vault is now the source of truth,
    /// which is what keeps a native run working after the webview's cookie expires or is cleared.
    func testTheHarvestSurvivesARelaunchWithNoWebviewSessionLeft() async throws {
        let adopting = makeCoordinator(FakeAPITransport(stubs: [.ok(.json(userJSON()))]),
                                       reader: RecordingCookieReader(token: "sso-cookie-token"))
        _ = try await adopting.restore(server)
        XCTAssertEqual(vault.getSecret(key: .authToken, serverURL: serverURL), "sso-cookie-token")

        // A fresh process: new coordinator, same vault, and a webview store that no longer holds
        // the cookie (the user cleared web data, or the cookie simply expired).
        let relaunched = makeCoordinator(FakeAPITransport(stubs: [.ok(.json(userJSON()))]),
                                         reader: RecordingCookieReader(token: nil))

        let restored = try await relaunched.restore(server)

        XCTAssertEqual(restored?.username, "grace")
        XCTAssertEqual(relaunched.phase(for: server.id),
                       .signedIn(username: "grace", userID: "u1"))
        XCTAssertEqual(relaunched.authState(for: server), .signedIn)
    }

    // MARK: 2. No session anywhere is still "signed out" — with no network call

    func testNoVaultTokenAndNoWebviewSessionResolvesSignedOutWithoutTouchingTheServer() async {
        let transport = FakeAPITransport(stubs: [])
        let coordinator = makeCoordinator(transport, reader: RecordingCookieReader(token: nil))

        await coordinator.restoreAll([server])

        XCTAssertEqual(transport.requestCount, 0,
                       "an anonymous launch must not fire an unauthenticated /users/me")
        XCTAssertEqual(coordinator.phase(for: server.id), .signedOut)
        XCTAssertEqual(coordinator.authState(for: server), .signedOut)
        XCTAssertNil(vault.getSecret(key: .authToken, serverURL: serverURL))
    }

    /// A cookie the server refuses is not a session, and must not leave a credential behind — the
    /// device would otherwise keep a token it knows is dead and retry it on every launch.
    func testARejectedWebviewCookieLeavesNoCredentialAndNoSession() async {
        let transport = FakeAPITransport(stubs: [
            .ok(payload("api.context.session_expired.app_error", "Session expired", status: 401)),
        ])
        let coordinator = makeCoordinator(transport, reader: RecordingCookieReader(token: "dead-cookie"))

        await coordinator.restoreAll([server])

        XCTAssertEqual(transport.lastRequest?.url.path, "/api/v4/users/me",
                       "the cookie was actually tried before this conclusion")
        XCTAssertEqual(coordinator.phase(for: server.id), .signedOut)
        XCTAssertNil(vault.getSecret(key: .authToken, serverURL: serverURL),
                     "`AuthSession.adoptWebSession` deletes the token when the server rejects it")
    }

    // MARK: 3. A rejected *vault* token still expires — adoption must not resurrect it

    /// The ordering this test pins: `needsReauth` wins over the webview harvest.
    ///
    /// Both copies are the same login, and the expiry transition (`requireReauth`) clears the cookie
    /// copy. Adopting from that store in the same pass would race the clear and could set the phase
    /// back to `.signedIn` on the credential the server has just refused.
    ///
    /// The transport is deliberately **token-aware** — the cookie's token would be *accepted* — so
    /// this cannot pass by accident: if the harvest ran first, the server would hand back a session
    /// and the assertions below would fail. A 401 for everything would prove nothing about order.
    func testARejectedVaultTokenExpiresEvenWhenAWebviewCookieWouldBeAccepted() async throws {
        try vault.setSecret("revoked-token", key: .authToken, serverURL: serverURL)
        let reader = RecordingCookieReader(token: "same-logins-cookie")
        let transport = TokenAwareTransport(acceptedToken: "same-logins-cookie")
        let coordinator = makeCoordinator(transport: transport, reader: reader)

        let restored = try await coordinator.restore(server)

        XCTAssertNil(restored)
        XCTAssertEqual(coordinator.phase(for: server.id), .expired,
                       "a refused stored token is an expiry, not an invitation to adopt")
        XCTAssertTrue(reader.asked.isEmpty,
                      "the webview store is never consulted on this path")
        XCTAssertEqual(coordinator.authState(for: server), .signedOut)
        XCTAssertNil(vault.getSecret(key: .authToken, serverURL: serverURL))
    }

    /// …and the same transition still drops the webview's copy (T31-AV F1), which is the reason the
    /// harvest must not run before it.
    func testTheExpiryOfARejectedVaultTokenAlsoClearsTheWebviewCookie() async throws {
        try vault.setSecret("revoked-token", key: .authToken, serverURL: serverURL)
        let coordinator = makeCoordinator(transport: TokenAwareTransport(acceptedToken: "never-used"),
                                          reader: RecordingCookieReader(token: "dead-cookie"))

        _ = try await coordinator.restore(server)

        XCTAssertEqual(coordinator.phase(for: server.id), .expired)
        XCTAssertEqual(cookies.cleared.map(\.serverID), [server.id],
                       "one login, two copies: the expiry drops both")
        XCTAssertEqual(cookies.cleared.map(\.url), [serverURL])
    }

    // MARK: 4. The production reader looks at the store a webview login writes

    /// Pins the wiring, not the mechanism: with **no** `cookieReader:` argument (the app's
    /// construction), the harvest must read `WKWebsiteDataStore(forIdentifier: server.id)` — the
    /// store `ViewStore.ensureStore(for:)` gives that server's webview. A reader pointed at
    /// `.default()` would answer `nil` for every real sign-in and this test would fail.
    func testTheProductionReaderFindsTheSessionInTheServersOwnWebsiteDataStore() async throws {
        let serverID = UUID()
        let dataStore = WKWebsiteDataStore(forIdentifier: serverID)
        let auth = try XCTUnwrap(HTTPCookie(properties: [
            .name: SessionCookiePolicy.authCookieName,
            .value: "webview-only-token",
            .domain: "mm.example.com",
            .path: "/",
            .expires: Date().addingTimeInterval(3600),
        ]))
        await dataStore.httpCookieStore.setCookie(auth)
        defer {
            Task {
                await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                           modifiedSince: .distantPast)
            }
        }

        // The app's own construction: only the transport is substituted.
        let transport = FakeAPITransport(stubs: [.ok(.json(userJSON()))])
        let vault = self.vault!
        let coordinator = AuthCoordinator(vault: vault,
                                          certTrust: certTrust,
                                          cookieClearing: cookies) { config, _ in
            let client = try APIClient(serverURL: config.url,
                                       transport: transport,
                                       retryPolicy: .none,
                                       tokenProvider: { vault.getSecret(key: .authToken,
                                                                       serverURL: config.url) },
                                       sleep: { _ in },
                                       random: { 0 })
            return AuthSession(serverID: config.id, serverURL: config.url, vault: vault, client: client)
        }
        let seeded = ServerConfig(id: serverID, name: "Seeded", url: serverURL)

        let restored = try await coordinator.restore(seeded)

        XCTAssertEqual(restored?.username, "grace")
        XCTAssertEqual(vault.getSecret(key: .authToken, serverURL: serverURL), "webview-only-token")
        XCTAssertEqual(coordinator.phase(for: serverID),
                       .signedIn(username: "grace", userID: "u1"))
    }
}
