import Foundation
import XCTest
@testable import Mattermost

/// T28 acceptance criteria for `AuthSession`: login, MFA, token storage in the existing
/// `SecureVault`, session restore, logout, SSO hand-off, and 401 → re-auth surfacing. Every test
/// runs against `FakeAPITransport` and an in-memory secret backend.
@MainActor
final class AuthSessionTests: XCTestCase {

    private var store: InMemorySecretStore!
    private var vault: SecureVault!
    private let serverURL = URL(string: "https://mm.example.com")!
    private let serverID = UUID()

    override func setUp() {
        super.setUp()
        store = InMemorySecretStore()
        vault = SecureVault(serviceNamespace: "t28-auth-\(UUID().uuidString)", secureStore: store)
    }

    // MARK: - Helpers

    private func makeSession(_ transport: FakeAPITransport) throws -> AuthSession {
        let vault = self.vault!
        let serverURL = self.serverURL
        let client = try APIClient(serverURL: serverURL,
                                   transport: transport,
                                   retryPolicy: APIClient.RetryPolicy.none,
                                   tokenProvider: { vault.getSecret(key: .authToken, serverURL: serverURL) },
                                   sleep: { _ in },
                                   random: { 0 })
        return AuthSession(serverID: serverID, serverURL: serverURL, vault: vault, client: client)
    }

    private func userJSON(id: String = "u1", username: String = "ada") -> [String: Any] {
        ["id": id, "username": username, "email": "ada@example.com",
         "first_name": "Ada", "last_name": "Lovelace", "nickname": "ada"]
    }

    private func errorPayload(_ id: String, _ message: String, status: Int) -> APIResponse {
        .json(["id": id, "message": message, "status_code": status], status: status)
    }

    private func bodyJSON(_ request: APIRequest?) throws -> [String: String] {
        let data = try XCTUnwrap(request?.body)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: String])
    }

    // MARK: - Login

    func testLoginPersistsTokenInSecureVaultAndSignsIn() async throws {
        let transport = FakeAPITransport(stubs: [
            .ok(.json(userJSON(), headers: ["Token": "tok-session-1"]))
        ])
        let auth = try makeSession(transport)

        let session = try await auth.login(loginID: "ada@example.com", password: "hunter2")

        XCTAssertEqual(session.token, "tok-session-1")
        XCTAssertEqual(session.userID, "u1")
        XCTAssertEqual(auth.state, .signedIn(session))
        XCTAssertFalse(auth.needsReauth)
        // The credential lives in the existing vault, under the same key the webview-era shell uses.
        XCTAssertEqual(vault.getSecret(key: .authToken, serverURL: serverURL), "tok-session-1")
        XCTAssertEqual(vault.getSecret(key: .userID, serverURL: serverURL), "u1")

        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.url.path, "/api/v4/users/login")
        XCTAssertEqual(request.method, .post)
        XCTAssertNil(request.headers["Authorization"], "login is unauthenticated")
        let body = try bodyJSON(request)
        XCTAssertEqual(body["login_id"], "ada@example.com")
        XCTAssertEqual(body["password"], "hunter2")
        XCTAssertNil(body["token"])
    }

    func testLoginAcceptsTheMMAUTHTOKENCookieWhenNoTokenHeaderIsSent() async throws {
        let transport = FakeAPITransport(stubs: [
            .ok(.json(userJSON(), headers: [
                "Set-Cookie": "MMAUTHTOKEN=cookie-token-9; Path=/; HttpOnly; Secure, OTHER=1"
            ]))
        ])
        let auth = try makeSession(transport)
        let session = try await auth.login(loginID: "ada", password: "pw")
        XCTAssertEqual(session.token, "cookie-token-9",
                       "mobile accepts the MMAUTHTOKEN cookie; so does this client")
        XCTAssertEqual(vault.getSecret(key: .authToken, serverURL: serverURL), "cookie-token-9")
    }

    func testLoginWithoutAnyTokenIsMalformedRatherThanASilentSession() async throws {
        let transport = FakeAPITransport(stubs: [.ok(.json(userJSON()))])
        let auth = try makeSession(transport)
        do {
            _ = try await auth.login(loginID: "ada", password: "pw")
            XCTFail("expected .malformedResponse")
        } catch let error as MMError {
            guard case .malformedResponse(let detail) = error else {
                return XCTFail("expected .malformedResponse, got \(error)")
            }
            XCTAssertTrue(detail.contains("session token"))
        }
        XCTAssertEqual(vault.getSecret(key: .authToken, serverURL: serverURL), nil)
    }

    // MARK: - MFA

    func testMFAChallengeIsTypedAndDoesNotSignIn() async throws {
        let transport = FakeAPITransport(stubs: [
            .ok(errorPayload("api.context.mfa_required", "MFA required", status: 401))
        ])
        let auth = try makeSession(transport)
        do {
            _ = try await auth.login(loginID: "ada", password: "pw")
            XCTFail("expected .mfaRequired")
        } catch {
            XCTAssertEqual(error as? MMError, .mfaRequired(message: "MFA required"))
        }
        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertNil(vault.getSecret(key: .authToken, serverURL: serverURL))
    }

    func testLoginWithMFATokenUsesTheMFAEndpointAndStoresTheSession() async throws {
        let transport = FakeAPITransport(stubs: [
            .ok(.json(userJSON(), headers: ["Token": "tok-mfa"]))
        ])
        let auth = try makeSession(transport)
        let session = try await auth.login(loginID: "ada", password: "pw", mfaToken: "123456")

        XCTAssertEqual(session.token, "tok-mfa")
        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.url.path, "/api/v4/users/login/mfa")
        let body = try bodyJSON(request)
        XCTAssertEqual(body["token"], "123456")
        XCTAssertEqual(body["login_id"], "ada")
    }

    func testRejectedMFACodeIsDistinctFromAWrongPassword() async throws {
        let transport = FakeAPITransport(stubs: [
            .ok(errorPayload("api.user.login.invalid_mfa", "Invalid MFA token", status: 401))
        ])
        let auth = try makeSession(transport)
        do {
            _ = try await auth.login(loginID: "ada", password: "pw", mfaToken: "000000")
            XCTFail("expected .invalidMFA")
        } catch {
            XCTAssertEqual(error as? MMError, .invalidMFA(message: "That authentication code was not accepted."))
        }
    }

    func testWrongPasswordIsUnauthorizedAndDoesNotRaiseReauth() async throws {
        let transport = FakeAPITransport(stubs: [
            .ok(errorPayload("api.user.login.invalid_credentials_email_username",
                             "Enter a valid email or username and/or password.", status: 401))
        ])
        let auth = try makeSession(transport)
        do {
            _ = try await auth.login(loginID: "ada", password: "nope")
            XCTFail("expected .unauthorized")
        } catch {
            XCTAssertEqual(error as? MMError,
                           .unauthorized(message: "Enter a valid email or username and/or password."))
        }
        XCTAssertFalse(auth.needsReauth, "a failed login is not an expired session")
        XCTAssertEqual(auth.state, .signedOut)
    }

    // MARK: - Restore

    func testRestoreReturnsTheStoredSessionWhenTheTokenStillWorks() async throws {
        try vault.setSecret("tok-existing", key: .authToken, serverURL: serverURL)
        let transport = FakeAPITransport(stubs: [.ok(.json(userJSON()))])
        let auth = try makeSession(transport)

        let session = try await auth.restore()

        XCTAssertEqual(session?.token, "tok-existing")
        XCTAssertEqual(session?.username, "ada")
        XCTAssertEqual(auth.state, .signedIn(try XCTUnwrap(session)))
        XCTAssertEqual(transport.lastRequest?.headers["Authorization"], "Bearer tok-existing")
    }

    func testRestoreDropsARevokedTokenAndSurfacesReauth() async throws {
        try vault.setSecret("tok-revoked", key: .authToken, serverURL: serverURL)
        let transport = FakeAPITransport(stubs: [
            .ok(errorPayload("api.context.session_expired.app_error", "Session expired", status: 401))
        ])
        let auth = try makeSession(transport)

        let session = try await auth.restore()

        XCTAssertNil(session)
        XCTAssertTrue(auth.needsReauth)
        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertNil(vault.getSecret(key: .authToken, serverURL: serverURL),
                     "a rejected token must not be left on the device")
    }

    func testRestoreWithoutAStoredTokenIsSignedOut() async throws {
        let transport = FakeAPITransport(stubs: [])
        let auth = try makeSession(transport)
        let session = try await auth.restore()
        XCTAssertNil(session)
        XCTAssertEqual(transport.requestCount, 0)
        XCTAssertEqual(auth.state, .signedOut)
    }

    // MARK: - 401 during a live session

    func testUnauthorizedDuringASessionMarksNeedsReauthAndClearsTheVault() async throws {
        let transport = FakeAPITransport(stubs: [
            .ok(.json(userJSON(), headers: ["Token": "tok-1"])),
            .ok(errorPayload("api.context.session_expired.app_error", "Session expired", status: 401))
        ])
        let auth = try makeSession(transport)
        _ = try await auth.login(loginID: "ada", password: "pw")
        guard case .signedIn(let session) = auth.state else {
            return XCTFail("expected a signed-in session after login")
        }
        XCTAssertEqual(session.token, "tok-1")

        // The next authenticated call (restore re-validates with GET /users/me) hits the 401:
        // the client fires `onUnauthorized`, the session drops the credential and flags re-auth.
        let restored = try await auth.restore()

        XCTAssertNil(restored)
        XCTAssertTrue(auth.needsReauth)
        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertNil(vault.getSecret(key: .authToken, serverURL: serverURL))
    }

    // MARK: - Logout + SSO

    func testLogoutClearsStoredCredentialsEvenWhenTheServerCallFails() async throws {
        let transport = FakeAPITransport(stubs: [
            .ok(.json(userJSON(), headers: ["Token": "tok-1"])),
            .ok(.json(["message": "server on fire"], status: 500))
        ])
        let auth = try makeSession(transport)
        _ = try await auth.login(loginID: "ada", password: "pw")
        await auth.logout()
        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertNil(vault.getSecret(key: .authToken, serverURL: serverURL))
        XCTAssertNil(vault.getSecret(key: .userID, serverURL: serverURL))
        XCTAssertEqual(transport.requests.last?.url.path, "/api/v4/users/logout")
    }

    func testAdoptingAnSSOSessionPersistsTheWebviewToken() throws {
        let auth = try makeSession(FakeAPITransport(stubs: []))
        let session = try auth.adoptSSOSession(token: "sso-token-42", userID: "u9", username: "grace")
        XCTAssertEqual(session.token, "sso-token-42")
        XCTAssertEqual(vault.getSecret(key: .authToken, serverURL: serverURL), "sso-token-42")
        XCTAssertEqual(auth.state, .signedIn(session))
    }

    func testAdoptingAnEmptySSOTokenFails() throws {
        let auth = try makeSession(FakeAPITransport(stubs: []))
        XCTAssertThrowsError(try auth.adoptSSOSession(token: "  ", userID: "u9", username: "grace"))
        XCTAssertEqual(auth.state, .signedOut)
    }

    // MARK: - Webview hand-off (SSO)

    private struct StubCookieReader: SessionCookieReading {
        var token: String?
        func authToken(for serverURL: URL) async -> String? { token }
    }

    func testAdoptingAWebviewSessionUsesTheCookieReaderAndVerifiesTheIdentity() async throws {
        let transport = FakeAPITransport(stubs: [.ok(.json(userJSON(id: "u7", username: "grace")))])
        let auth = try makeSession(transport)

        let session = try await auth.adoptWebSession(using: StubCookieReader(token: "cookie-session-7"))

        XCTAssertEqual(session.token, "cookie-session-7")
        XCTAssertEqual(session.userID, "u7")
        XCTAssertEqual(session.username, "grace")
        XCTAssertEqual(vault.getSecret(key: .authToken, serverURL: serverURL), "cookie-session-7")
        XCTAssertEqual(transport.lastRequest?.headers["Authorization"], "Bearer cookie-session-7")
        XCTAssertEqual(transport.lastRequest?.url.path, "/api/v4/users/me")
    }

    func testAdoptingAWebviewSessionWithoutACookieFails() async throws {
        let auth = try makeSession(FakeAPITransport(stubs: []))
        do {
            _ = try await auth.adoptWebSession(using: StubCookieReader(token: nil))
            XCTFail("expected .notSignedIn")
        } catch {
            XCTAssertEqual(error as? MMError, .notSignedIn)
        }
        XCTAssertEqual(auth.state, .signedOut)
    }

    func testAdoptingAWebviewSessionDropsARejectedCookie() async throws {
        let transport = FakeAPITransport(stubs: [
            .ok(errorPayload("api.context.session_expired.app_error", "Session expired", status: 401))
        ])
        let auth = try makeSession(transport)
        do {
            _ = try await auth.adoptWebSession(using: StubCookieReader(token: "stale-cookie"))
            XCTFail("expected .unauthorized")
        } catch {
            XCTAssertEqual(error as? MMError, .unauthorized(message: "Session expired"))
        }
        XCTAssertNil(vault.getSecret(key: .authToken, serverURL: serverURL),
                     "a cookie the server rejects must not be persisted")
    }

    // MARK: - Cookie matching

    func testCookieMatchingIsScopedToTheServersHost() throws {
        func cookie(_ name: String, _ value: String, domain: String) throws -> HTTPCookie {
            try XCTUnwrap(HTTPCookie(properties: [
                .name: name, .value: value, .domain: domain, .path: "/"
            ]))
        }
        let exact = try cookie("MMAUTHTOKEN", "tok-exact", domain: "mm.example.com")
        let parent = try cookie("MMAUTHTOKEN", "tok-parent", domain: ".example.com")
        let foreign = try cookie("MMAUTHTOKEN", "tok-foreign", domain: "evil.example.net")
        let otherName = try cookie("OTHER", "tok-other", domain: "mm.example.com")
        let server = URL(string: "https://mm.example.com")!

        XCTAssertEqual(SessionCookiePolicy.value(named: "MMAUTHTOKEN", in: [exact], for: server), "tok-exact")
        XCTAssertEqual(SessionCookiePolicy.value(named: "MMAUTHTOKEN", in: [parent], for: server), "tok-parent")
        XCTAssertNil(SessionCookiePolicy.value(named: "MMAUTHTOKEN", in: [foreign], for: server))
        XCTAssertNil(SessionCookiePolicy.value(named: "MMAUTHTOKEN", in: [otherName], for: server))
        XCTAssertFalse(SessionCookiePolicy.domainMatches(cookieDomain: "example.com",
                                                        host: "notexample.com"))
    }

    func testExpiredCookiesAreIgnored() throws {
        let expired = try XCTUnwrap(HTTPCookie(properties: [
            .name: "MMAUTHTOKEN", .value: "tok-expired", .domain: "mm.example.com", .path: "/",
            .expires: Date(timeIntervalSince1970: 1_000_000)
        ]))
        let server = URL(string: "https://mm.example.com")!
        XCTAssertNil(SessionCookiePolicy.value(named: "MMAUTHTOKEN", in: [expired], for: server))
    }

    // MARK: - Redaction

    func testSessionDescriptionRedactsTheToken() async throws {
        let transport = FakeAPITransport(stubs: [
            .ok(.json(userJSON(), headers: ["Token": "super-secret-token"]))
        ])
        let auth = try makeSession(transport)
        let session = try await auth.login(loginID: "ada", password: "pw")
        XCTAssertFalse(String(describing: session).contains("super-secret-token"))
        XCTAssertFalse(session.debugDescription.contains("super-secret-token"))
        XCTAssertTrue(String(describing: session).contains("<redacted>"))
    }
}
