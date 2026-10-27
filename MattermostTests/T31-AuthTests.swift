import Foundation
import WebKit
import XCTest
@testable import Mattermost

// T31 — native auth & session surface. One file, one card (docs/parallel-work.md §5).
//
// The suite is split the way the card is: the pure machines first (form rules, error copy, MFA
// step, SSO polling), then the app-level coordinator that owns one `AuthSession` per server, and
// finally the two security claims that are cheap to test and expensive to lose — no credential in a
// log line, and no credential left on the device after a sign-out whose network call failed.

// MARK: - Fakes

/// A scripted `LoginAuthenticating`, so the form tests never build a transport.
@MainActor
final class FakeLoginAuthenticator: LoginAuthenticating {

    struct Call: Equatable {
        var loginID: String
        var password: String
        var mfaToken: String?
    }

    private(set) var calls: [Call] = []
    private var results: [Result<AuthSession.Session, MMError>]

    init(results: [Result<AuthSession.Session, MMError>] = []) {
        self.results = results
    }

    func login(loginID: String, password: String, mfaToken: String?) async throws -> AuthSession.Session {
        calls.append(Call(loginID: loginID, password: password, mfaToken: mfaToken))
        guard !results.isEmpty else {
            throw MMError.transport("FakeLoginAuthenticator ran out of scripted results")
        }
        return try results.removeFirst().get()
    }

    static func session(username: String = "ada", userID: String = "u1",
                        token: String = "tok-1") -> AuthSession.Session {
        AuthSession.Session(serverID: UUID(), userID: userID, username: username, token: token)
    }

    static func success(username: String = "ada", token: String = "tok-1")
        -> Result<AuthSession.Session, Error> {
        .success(session(username: username, token: token))
    }

    static func failure(_ error: MMError) -> Result<AuthSession.Session, MMError> {
        .failure(error)
    }
}

/// Records the cookie-clearing half of sign-out (the vault half is asserted against the vault).
final class FakeCookieClearing: SessionCookieClearing {
    private(set) var cleared: [(url: URL, serverID: UUID)] = []

    func clearAuthCookie(for serverURL: URL, serverID: UUID) async {
        cleared.append((serverURL, serverID))
    }
}

// MARK: - Login form

@MainActor
final class T31LoginViewModelTests: XCTestCase {

    private let url = URL(string: "https://mm.example.com")!

    private func makeModel(_ authenticator: FakeLoginAuthenticator) -> LoginViewModel {
        LoginViewModel(serverName: "Test Server", serverURL: url, authenticator: authenticator)
    }

    func testSubmitIsDisabledUntilBothFieldsCarrySomething() {
        let model = makeModel(FakeLoginAuthenticator())
        XCTAssertFalse(model.canSubmit)

        model.loginID = "   "
        model.password = "pw"
        XCTAssertFalse(model.canSubmit, "a whitespace-only id is not an id")

        model.loginID = "ada"
        XCTAssertTrue(model.canSubmit)

        model.password = ""
        XCTAssertFalse(model.canSubmit)
    }

    func testLoginIDIsTrimmedAndLowercasedBeforeItReachesTheServer() async {
        let authenticator = FakeLoginAuthenticator(results: [.success(FakeLoginAuthenticator.session())])
        let model = makeModel(authenticator)
        model.loginID = "  Ada@Example.COM "
        model.password = "hunter2"

        await model.submit()

        XCTAssertEqual(authenticator.calls.first?.loginID, "ada@example.com",
                       "mobile's form.tsx lowercases the id before POST /users/login")
        XCTAssertEqual(authenticator.calls.first?.password, "hunter2")
        XCTAssertNil(authenticator.calls.first?.mfaToken)
        XCTAssertEqual(model.phase, .signedIn(username: "ada"))
    }

    func testWrongPasswordKeepsTheUserOnTheFormWithTheServersSentence() async {
        let authenticator = FakeLoginAuthenticator(results: [
            .failure(.unauthorized(message: "Enter a valid email or username and/or password."))
        ])
        let model = makeModel(authenticator)
        model.loginID = "ada"
        model.password = "nope"

        await model.submit()

        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(model.errorMessage, "Enter a valid email or username and/or password.")
        XCTAssertNil(model.mfa, "a wrong password is not an MFA challenge")
        XCTAssertFalse(model.isSignedIn)
    }

    func testWrongPasswordWithoutAServerSentenceFallsBackToTheMobileCopy() async {
        let model = makeModel(FakeLoginAuthenticator(results: [.failure(.unauthorized(message: nil))]))
        model.loginID = "ada"
        model.password = "nope"

        await model.submit()

        XCTAssertEqual(model.errorMessage, "The email and password combination is incorrect.")
    }

    func testMFARequiredMovesToTheSecondStepAndVerifiesWithTheSameCredential() async {
        let authenticator = FakeLoginAuthenticator(results: [
            .failure(.mfaRequired(message: "MFA required")),
            .success(FakeLoginAuthenticator.session(username: "ada", token: "tok-mfa"))
        ])
        let model = makeModel(authenticator)
        model.loginID = "ada"
        model.password = "hunter2"

        await model.submit()

        XCTAssertEqual(model.phase, .idle)
        let mfa = try? XCTUnwrap(model.mfa)
        XCTAssertNotNil(mfa, "the server asked for a second factor: the MFA step owns the screen")
        XCTAssertEqual(mfa?.loginID, "ada")

        await mfa?.submit()   // empty code: no call, inline rule
        XCTAssertEqual(authenticator.calls.count, 1)
        XCTAssertEqual(mfa?.errorMessage, "Please enter an MFA token.")

        mfa?.code = "123456"
        await mfa?.submit()

        XCTAssertEqual(authenticator.calls.count, 2)
        XCTAssertEqual(authenticator.calls.last?.mfaToken, "123456")
        XCTAssertEqual(authenticator.calls.last?.password, "hunter2",
                       "the MFA call re-sends the credential, as the API requires")
        XCTAssertEqual(model.phase, .signedIn(username: "ada"))
        XCTAssertNil(model.mfa)
        XCTAssertEqual(model.password, "", "the password is dropped once the session exists")
    }

    func testWrongMFACodeStaysOnTheSecondStepWithItsOwnMessage() async {
        let authenticator = FakeLoginAuthenticator(results: [
            .failure(.mfaRequired(message: nil)),
            .failure(.invalidMFA(message: "That authentication code was not accepted."))
        ])
        let model = makeModel(authenticator)
        model.loginID = "ada"
        model.password = "pw"
        await model.submit()

        model.mfa?.code = "000000"
        await model.mfa?.submit()

        XCTAssertEqual(model.mfa?.phase, .failed)
        XCTAssertEqual(model.mfa?.errorMessage, "That authentication code was not accepted.")
        XCTAssertEqual(model.mfa?.code, "", "the rejected digits are cleared so they cannot be resent")
        XCTAssertFalse(model.isSignedIn)
        XCTAssertNil(model.errorMessage, "the password form's error is not reused for the code")
    }

    func testNetworkFailuresProduceTheirOwnCopy() async {
        for (error, expected) in [
            (MMError.offline, "You appear to be offline. Check your connection and try again."),
            (MMError.timeout, "The server took too long to respond. Try again."),
            (MMError.transport("boom"), "Could not reach the server. Check the address and your connection."),
            (MMError.certificateUntrusted(origin: "https://mm.example.com"),
             "This server's certificate is not trusted yet. Review it, then try again.")
        ] {
            let model = makeModel(FakeLoginAuthenticator(results: [.failure(error)]))
            model.loginID = "ada"
            model.password = "pw"
            await model.submit()
            XCTAssertEqual(model.errorMessage, expected, "copy for \(error)")
            XCTAssertEqual(model.phase, .failed)
        }
    }

    func testEmptySubmitIsAValidationMessageAndNeverCallsTheServer() async {
        let authenticator = FakeLoginAuthenticator()
        let model = makeModel(authenticator)
        model.password = "pw"   // id missing

        await model.submit()

        XCTAssertTrue(authenticator.calls.isEmpty)
        XCTAssertEqual(model.errorMessage, "Enter your email or username and password.")
    }

    func testEditingAFieldClearsTheInlineError() async {
        let model = makeModel(FakeLoginAuthenticator(results: [.failure(.unauthorized(message: "nope"))]))
        model.loginID = "ada"
        model.password = "pw"
        await model.submit()
        XCTAssertNotNil(model.errorMessage)

        model.clearError()

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.phase, .idle)
    }

    func testBackFromTheMFAStepReturnsToTheFormWithoutLosingTheId() async {
        let authenticator = FakeLoginAuthenticator(results: [.failure(.mfaRequired(message: nil))])
        let model = makeModel(authenticator)
        model.loginID = "ada"
        model.password = "pw"
        await model.submit()
        XCTAssertNotNil(model.mfa)

        model.leaveMFA()

        XCTAssertNil(model.mfa)
        XCTAssertEqual(model.loginID, "ada")
        XCTAssertEqual(model.phase, .idle)
    }

    // MARK: Security: the credential is not in any string or log line

    func testPasswordNeverAppearsInTheModelsOwnDescription() async {
        let password = "sekrit-password-9f3a"
        let model = makeModel(FakeLoginAuthenticator(results: [.failure(.unauthorized(message: "nope"))]))
        model.loginID = "ada@example.com"
        model.password = password
        await model.submit()

        XCTAssertFalse(model.redactedDescription.contains(password))
        XCTAssertFalse(model.redactedDescription.contains("ada@example.com"))
        XCTAssertTrue(model.redactedDescription.contains("<redacted>"))

        let mfaAuthenticator = FakeLoginAuthenticator(results: [.failure(.mfaRequired(message: nil))])
        let mfaModel = LoginViewModel(serverName: "T", serverURL: url, authenticator: mfaAuthenticator)
        mfaModel.loginID = "ada@example.com"
        mfaModel.password = password
        await mfaModel.submit()
        XCTAssertFalse(try XCTUnwrap(mfaModel.mfa).redactedDescription.contains("ada@example.com"))
    }

    func testAWholeSignInAttemptWritesNoCredentialToALogLine() async {
        let captured = LogCapture()
        let store = InMemorySecretStore()
        let vault = SecureVault(serviceNamespace: "t31-log-\(UUID().uuidString)", secureStore: store)
        let serverURL = URL(string: "https://mm.example.com")!
        let password = "sekrit-not-in-a-log-4711"
        let token = "sekrit-token-4711"
        let transport = FakeAPITransport(stubs: [
            .ok(.json(["id": "u1", "username": "ada"], headers: ["Token": token]))
        ])
        let coordinator = AuthCoordinator(vault: vault, certTrust: CertTrust(secureStore: InMemorySecretStore())) { config, _ in
            let client = try APIClient(serverURL: config.url,
                                       transport: transport,
                                       retryPolicy: .none,
                                       tokenProvider: { vault.getSecret(key: .authToken, serverURL: serverURL) },
                                       sleep: { _ in },
                                       random: { 0 })
            return AuthSession(serverID: config.id, serverURL: config.url, vault: vault, client: client)
        }
        let server = ServerConfig(name: "Test", url: serverURL)
        let model = LoginViewModel(serverName: "Test",
                                   serverURL: serverURL,
                                   authenticator: ServerSignIn(server: server, coordinator: coordinator))
        model.loginID = "ada@example.com"
        model.password = password

        await model.submit()

        XCTAssertEqual(model.phase, .signedIn(username: "ada"), "the flow has to succeed for this to prove anything")
        XCTAssertEqual(vault.getSecret(key: .authToken, serverURL: serverURL), token,
                       "the token is stored in the vault, not logged")
        let lines = captured.lines
        XCTAssertFalse(lines.isEmpty, "the flow must log something, or this proves nothing")
        for line in lines {
            XCTAssertFalse(line.contains(password), "a log line leaked the password: \(line)")
            XCTAssertFalse(line.contains(token), "a log line leaked the token: \(line)")
        }
        captured.stop()
    }
}

// MARK: - MFA form

@MainActor
final class T31MFAViewModelTests: XCTestCase {

    func testEmptyCodeIsRefusedLocally() async {
        let authenticator = FakeLoginAuthenticator()
        let model = MFAViewModel(serverName: "T",
                                 loginID: "ada",
                                 password: "pw",
                                 authenticator: authenticator)
        model.code = "   "

        XCTAssertFalse(model.canSubmit)
        await model.submit()

        XCTAssertTrue(authenticator.calls.isEmpty)
        XCTAssertEqual(model.errorMessage, "Please enter an MFA token.")
    }

    func testAcceptedCodeReportsTheSessionToTheForm() async {
        let authenticator = FakeLoginAuthenticator(results: [
            .success(FakeLoginAuthenticator.session(username: "grace"))
        ])
        let model = MFAViewModel(serverName: "T",
                                 loginID: "ada",
                                 password: "pw",
                                 authenticator: authenticator)
        var signedInAs: String?
        model.onSignedIn = { signedInAs = $0.username }
        model.code = " 654321 "

        await model.submit()

        XCTAssertEqual(authenticator.calls.first?.mfaToken, "654321")
        XCTAssertEqual(signedInAs, "grace")
        XCTAssertEqual(model.phase, .signedIn(username: "grace"))
    }
}

// MARK: - SSO polling

@MainActor
final class T31SSOViewModelTests: XCTestCase {

    /// A reader that returns one scripted value per poll (last value repeats).
    private final class ScriptedReader: SessionCookieReading {
        private var values: [String?]
        private(set) var calls = 0
        init(_ values: [String?]) { self.values = values }
        func authToken(for serverURL: URL) async -> String? {
            defer { calls += 1 }
            if values.count > 1 { return values.removeFirst() }
            return values.first ?? nil
        }
    }

    private let url = URL(string: "https://mm.example.com")!

    func testTheCookieIsPolledUntilTheSessionAppearsAndThenAdoptedOnce() async {
        let reader = ScriptedReader([nil, nil, "sso-cookie-token"])
        let model = SSOViewModel(serverName: "T", serverURL: url, maxPolls: 10)
        var adoptions = 0

        await model.observe(reader: reader,
                            adopt: {
                                adoptions += 1
                                return FakeLoginAuthenticator.session(username: "grace", token: "sso-cookie-token")
                            },
                            sleep: {})

        XCTAssertEqual(model.phase, .signedIn(username: "grace"))
        XCTAssertEqual(adoptions, 1, "adoption runs once, when a cookie exists")
        XCTAssertEqual(reader.calls, 3)
        XCTAssertEqual(model.polls, 3)
    }

    func testAnAlreadySignedInWebviewIsAdoptedOnTheFirstPoll() async {
        let reader = ScriptedReader(["already-signed-in"])
        let model = SSOViewModel(serverName: "T", serverURL: url, maxPolls: 5)

        await model.observe(reader: reader,
                            adopt: { FakeLoginAuthenticator.session(username: "ada") },
                            sleep: {})

        XCTAssertEqual(reader.calls, 1)
        XCTAssertEqual(model.phase, .signedIn(username: "ada"))
    }

    func testARejectedCookieFailsWithTheReasonInsteadOfSpinning() async {
        let reader = ScriptedReader(["stale-cookie"])
        let model = SSOViewModel(serverName: "T", serverURL: url, maxPolls: 5)

        await model.observe(reader: reader,
                            adopt: { throw MMError.unauthorized(message: "Session expired") },
                            sleep: {})

        XCTAssertEqual(model.phase, .failed("The server rejected the web session. Sign in again."))
        XCTAssertEqual(reader.calls, 1, "a failed adoption stops polling")
    }

    func testTheHandOffGivesUpAfterThePollBudget() async {
        let reader = ScriptedReader([nil])
        let model = SSOViewModel(serverName: "T", serverURL: url, pollInterval: 0, maxPolls: 3)

        await model.observe(reader: reader,
                            adopt: { XCTFail("nothing to adopt"); return FakeLoginAuthenticator.session() },
                            sleep: {})

        XCTAssertEqual(model.polls, 3)
        guard case .failed(let message) = model.phase else {
            return XCTFail("expected a failed hand-off, got \(model.phase)")
        }
        XCTAssertTrue(message.contains("not completed"))
        XCTAssertFalse(model.isWorking)
    }

    func testRestartRearmsTheHandOff() {
        let model = SSOViewModel(serverName: "T", serverURL: url)
        model.fail("IdP said no")
        guard case .failed = model.phase else { return XCTFail("expected failed") }

        model.restart()

        XCTAssertEqual(model.phase, .waiting)
        XCTAssertEqual(model.polls, 0)
        XCTAssertTrue(model.isWorking)
    }

    func testNavigationBackToTheServerIsTrackedForTheStatusLine() {
        let model = SSOViewModel(serverName: "T", serverURL: url)
        model.noteNavigation(to: URL(string: "https://idp.example.com/login"))
        XCTAssertFalse(model.isBackOnTheServer)
        model.noteNavigation(to: URL(string: "https://mm.example.com/acme/channels/town-square"))
        XCTAssertTrue(model.isBackOnTheServer)
    }

    // MARK: Cookie clearing (the webview half of sign-out)

    func testClearingTheAuthCookieRemovesOnlyThisServersSessionCookie() async throws {
        let serverID = UUID()
        let otherServerID = UUID()
        let dataStore = WKWebsiteDataStore(forIdentifier: serverID)
        let auth = try XCTUnwrap(HTTPCookie(properties: [
            .name: "MMAUTHTOKEN", .value: "sso-token-abc", .domain: "mm.example.com", .path: "/"
        ]))
        let unrelated = try XCTUnwrap(HTTPCookie(properties: [
            .name: "MMCSRF", .value: "csrf-1", .domain: "mm.example.com", .path: "/"
        ]))
        await dataStore.httpCookieStore.setCookie(auth)
        await dataStore.httpCookieStore.setCookie(unrelated)

        await WebKitSessionCookieClearing().clearAuthCookie(for: url, serverID: serverID)

        let reader = WebKitSessionCookieReader(serverID: serverID)
        let remaining = await reader.authToken(for: url)
        XCTAssertNil(remaining, "the MMAUTHTOKEN cookie is gone")
        let cookies = await dataStore.httpCookieStore.allCookies()
        XCTAssertTrue(cookies.contains { $0.name == "MMCSRF" },
                      "an unrelated cookie on the same server is left alone")
        let other = await WebKitSessionCookieReader(serverID: otherServerID).authToken(for: url)
        XCTAssertNil(other, "another server's store was never touched (and never held it)")

        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                   modifiedSince: .distantPast)
    }
}

// MARK: - The app-level coordinator

@MainActor
final class T31AuthCoordinatorTests: XCTestCase {

    private var vault: SecureVault!
    private var store: InMemorySecretStore!
    private var certTrust: CertTrust!
    private var cookies: FakeCookieClearing!
    private var server: ServerConfig!
    private let serverURL = URL(string: "https://mm.example.com")!

    override func setUp() {
        super.setUp()
        store = InMemorySecretStore()
        vault = SecureVault(serviceNamespace: "t31-coord-\(UUID().uuidString)", secureStore: store)
        certTrust = CertTrust(serviceNamespace: "t31-cert-\(UUID().uuidString)",
                              secureStore: InMemorySecretStore())
        cookies = FakeCookieClearing()
        server = ServerConfig(name: "Test Server", url: serverURL)
    }

    private func makeCoordinator(_ transport: FakeAPITransport) -> AuthCoordinator {
        let vault = self.vault!
        let certTrust = self.certTrust!
        return AuthCoordinator(vault: vault, certTrust: certTrust, cookieClearing: cookies) { config, _ in
            let client = try APIClient(serverURL: config.url,
                                       transport: transport,
                                       retryPolicy: .none,
                                       tokenProvider: { vault.getSecret(key: .authToken, serverURL: config.url) },
                                       sleep: { _ in },
                                       random: { 0 })
            return AuthSession(serverID: config.id, serverURL: config.url, vault: vault, client: client)
        }
    }

    private func userJSON(username: String = "ada") -> [String: Any] {
        ["id": "u1", "username": username, "email": "ada@example.com"]
    }

    private func payload(_ id: String, _ message: String, status: Int) -> APIResponse {
        .json(["id": id, "message": message, "status_code": status], status: status)
    }

    // MARK: Gate semantics

    func testBeforeAnyRestoreAStoredTokenCountsAsSignedInAndNoTokenCountsAsSignedOut() {
        let coordinator = makeCoordinator(FakeAPITransport(stubs: []))
        XCTAssertEqual(coordinator.phase(for: server.id), .unresolved)
        XCTAssertEqual(coordinator.authState(for: server), .signedOut,
                       "a server that has never been signed in shows the sign-in surface")

        try? vault.setSecret("stored-token", key: .authToken, serverURL: serverURL)
        XCTAssertEqual(coordinator.authState(for: server), .signedIn,
                       "relaunch must not flash a login form while restore is in flight")
    }

    func testRestoreResolvesASignedInSessionWithOneIdentityCall() async throws {
        try vault.setSecret("stored-token", key: .authToken, serverURL: serverURL)
        let transport = FakeAPITransport(stubs: [.ok(.json(userJSON()))])
        let coordinator = makeCoordinator(transport)
        var notified: [UUID] = []
        coordinator.onChange = { notified.append($0) }

        let restored = try await coordinator.restore(server)

        XCTAssertEqual(restored?.username, "ada")
        XCTAssertEqual(coordinator.phase(for: server.id), .signedIn(username: "ada", userID: "u1"))
        XCTAssertEqual(coordinator.authState(for: server), .signedIn)
        XCTAssertEqual(transport.lastRequest?.url.path, "/api/v4/users/me")
        XCTAssertEqual(transport.lastRequest?.headers["Authorization"], "Bearer stored-token")
        XCTAssertEqual(notified, [server.id], "the shell is told exactly once to re-read the gate")
    }

    func testARejectedStoredTokenExpiresTheSessionAndClearsTheCredential() async throws {
        try vault.setSecret("revoked-token", key: .authToken, serverURL: serverURL)
        let transport = FakeAPITransport(stubs: [
            .ok(payload("api.context.session_expired.app_error", "Session expired", status: 401))
        ])
        let coordinator = makeCoordinator(transport)
        var notifications = 0
        coordinator.onChange = { _ in notifications += 1 }

        let restored = try await coordinator.restore(server)

        XCTAssertNil(restored)
        XCTAssertEqual(coordinator.phase(for: server.id), .expired)
        XCTAssertEqual(coordinator.authState(for: server), .signedOut,
                       "the shell shows the sign-in surface again…")
        XCTAssertNil(vault.getSecret(key: .authToken, serverURL: serverURL),
                     "…and the rejected credential is not left on the device")
        XCTAssertEqual(notifications, 1)
    }

    func testAnUnreachableServerKeepsTheStoredSessionAtLaunch() async {
        try? vault.setSecret("stored-token", key: .authToken, serverURL: serverURL)
        let coordinator = makeCoordinator(FakeAPITransport(repeatingError: .offline))

        do {
            _ = try await coordinator.restore(server)
            XCTFail("expected the transport failure to surface")
        } catch {
            // expected
        }

        XCTAssertEqual(coordinator.phase(for: server.id), .unresolved,
                       "offline is not an expiry: the launch keeps the stored session")
        XCTAssertEqual(coordinator.authState(for: server), .signedIn)
        XCTAssertEqual(vault.getSecret(key: .authToken, serverURL: serverURL), "stored-token")
    }

    func testRestoreAllIsIdempotentAndSkipsResolvedServers() async {
        try? vault.setSecret("stored-token", key: .authToken, serverURL: serverURL)
        let transport = FakeAPITransport(stubs: [.ok(.json(userJSON()))])
        let coordinator = makeCoordinator(transport)

        await coordinator.restoreAll([server])
        await coordinator.restoreAll([server])
        await coordinator.restoreAll([server])

        XCTAssertEqual(transport.requestCount, 1,
                       "a resolved server is not re-validated every time the server list changes")
        XCTAssertEqual(coordinator.phase(for: server.id), .signedIn(username: "ada", userID: "u1"))
    }

    func testAFreshServerWithNoTokenResolvesSignedOutWithoutANetworkCall() async {
        let transport = FakeAPITransport(stubs: [])
        let coordinator = makeCoordinator(transport)

        await coordinator.restoreAll([server])

        XCTAssertEqual(transport.requestCount, 0)
        XCTAssertEqual(coordinator.phase(for: server.id), .signedOut)
    }

    // MARK: Sign in / MFA through the coordinator

    func testSignInStoresTheSessionAndFlipsTheGate() async throws {
        let transport = FakeAPITransport(stubs: [
            .ok(.json(userJSON(), headers: ["Token": "tok-live"]))
        ])
        let coordinator = makeCoordinator(transport)

        let session = try await coordinator.signIn(server, loginID: "ada", password: "pw")

        XCTAssertEqual(session.token, "tok-live")
        XCTAssertEqual(coordinator.phase(for: server.id), .signedIn(username: "ada", userID: "u1"))
        XCTAssertEqual(vault.getSecret(key: .authToken, serverURL: serverURL), "tok-live")
    }

    func testAFailedLoginIsNotAnExpiredSession() async throws {
        let transport = FakeAPITransport(stubs: [
            .ok(payload("api.user.login.invalid_credentials_email_username",
                        "Enter a valid email or username and/or password.", status: 401))
        ])
        let coordinator = makeCoordinator(transport)

        do {
            _ = try await coordinator.signIn(server, loginID: "ada", password: "wrong")
            XCTFail("expected .unauthorized")
        } catch {
            XCTAssertEqual(error as? MMError,
                           .unauthorized(message: "Enter a valid email or username and/or password."))
        }

        XCTAssertNotEqual(coordinator.phase(for: server.id), .expired,
                          "a wrong password must not raise the \"session expired\" banner")
        XCTAssertNil(vault.getSecret(key: .authToken, serverURL: serverURL))
    }

    func testMFAChallengeThenSuccess() async throws {
        let transport = FakeAPITransport(stubs: [
            .ok(payload("api.context.mfa_required", "MFA required", status: 401)),
            .ok(.json(userJSON(), headers: ["Token": "tok-mfa"]))
        ])
        let coordinator = makeCoordinator(transport)

        do {
            _ = try await coordinator.signIn(server, loginID: "ada", password: "pw")
            XCTFail("expected .mfaRequired")
        } catch {
            XCTAssertEqual(error as? MMError, .mfaRequired(message: "MFA required"))
        }
        XCTAssertEqual(coordinator.phase(for: server.id), .unresolved)
        XCTAssertNil(vault.getSecret(key: .authToken, serverURL: serverURL))

        let session = try await coordinator.signIn(server, loginID: "ada", password: "pw", mfaToken: "123456")

        XCTAssertEqual(session.token, "tok-mfa")
        XCTAssertEqual(transport.lastRequest?.url.path, "/api/v4/users/login/mfa")
        XCTAssertEqual(coordinator.phase(for: server.id), .signedIn(username: "ada", userID: "u1"))
    }

    // MARK: 401 from any native call

    func testA401OnALiveSessionTurnsTheGateToReauthWithoutAnyScreenInvolved() async throws {
        let transport = FakeAPITransport(stubs: [
            .ok(.json(userJSON(), headers: ["Token": "tok-live"])),
            .ok(payload("api.context.session_expired.app_error", "Session expired", status: 401))
        ])
        let coordinator = makeCoordinator(transport)
        var notifications: [UUID] = []
        coordinator.onChange = { notifications.append($0) }

        _ = try await coordinator.signIn(server, loginID: "ada", password: "pw")
        XCTAssertEqual(coordinator.authState(for: server), .signedIn)

        // Any authenticated call — here a re-validate, in the app any T32+ screen's first GET —
        // gets a 401. One place has to notice, and it is not the screen that made the call.
        _ = try await coordinator.restore(server)

        XCTAssertEqual(coordinator.phase(for: server.id), .expired)
        XCTAssertEqual(coordinator.authState(for: server), .signedOut)
        XCTAssertNil(vault.getSecret(key: .authToken, serverURL: serverURL))
        XCTAssertTrue(notifications.contains(server.id))
    }

    // MARK: Webview hand-off (SSO)

    private struct StubCookieReader: SessionCookieReading {
        var token: String?
        func authToken(for serverURL: URL) async -> String? { token }
    }

    func testAdoptingTheWebviewSessionSignsTheServerIn() async throws {
        let transport = FakeAPITransport(stubs: [.ok(.json(userJSON(username: "grace")))])
        let coordinator = makeCoordinator(transport)

        let session = try await coordinator.adoptWebSession(server,
                                                            using: StubCookieReader(token: "sso-token"))

        XCTAssertEqual(session.token, "sso-token")
        XCTAssertEqual(coordinator.phase(for: server.id), .signedIn(username: "grace", userID: "u1"))
        XCTAssertEqual(vault.getSecret(key: .authToken, serverURL: serverURL), "sso-token")
    }

    // MARK: Sign out

    func testSignOutClearsTheVaultTheLiveSessionAndTheWebviewCookie() async throws {
        let transport = FakeAPITransport(stubs: [
            .ok(.json(userJSON(), headers: ["Token": "tok-live"])),
            .ok(.json([:]))
        ])
        let coordinator = makeCoordinator(transport)
        _ = try await coordinator.signIn(server, loginID: "ada", password: "pw")

        await coordinator.signOut(server)

        XCTAssertEqual(coordinator.phase(for: server.id), .signedOut)
        XCTAssertEqual(coordinator.authState(for: server), .signedOut)
        XCTAssertNil(vault.getSecret(key: .authToken, serverURL: serverURL))
        XCTAssertNil(vault.getSecret(key: .userID, serverURL: serverURL))
        XCTAssertEqual(transport.requests.last?.url.path, "/api/v4/users/logout")
        XCTAssertEqual(cookies.cleared.count, 1)
        XCTAssertEqual(cookies.cleared.first?.serverID, server.id)
        XCTAssertEqual(cookies.cleared.first?.url, serverURL)
    }

    func testSignOutClearsTheCredentialEvenWhenTheServerCallFails() async throws {
        let transport = FakeAPITransport(stubs: [
            .ok(.json(userJSON(), headers: ["Token": "tok-live"])),
            .ok(.json(["message": "server on fire"], status: 500))
        ])
        let coordinator = makeCoordinator(transport)
        _ = try await coordinator.signIn(server, loginID: "ada", password: "pw")

        await coordinator.signOut(server)

        XCTAssertNil(vault.getSecret(key: .authToken, serverURL: serverURL),
                     "a failed logout call must not leave a usable credential behind")
        XCTAssertEqual(cookies.cleared.count, 1,
                       "the webview copy is cleared too — one credential, two places")
        XCTAssertEqual(coordinator.phase(for: server.id), .signedOut)
    }

    func testSignOutWithoutALiveSessionStillClearsTheStoredCredential() async {
        try? vault.setSecret("stored-token", key: .authToken, serverURL: serverURL)
        try? vault.setSecret("u1", key: .userID, serverURL: serverURL)
        let coordinator = makeCoordinator(FakeAPITransport(stubs: []))

        await coordinator.signOut(server)

        XCTAssertNil(vault.getSecret(key: .authToken, serverURL: serverURL))
        XCTAssertNil(vault.getSecret(key: .userID, serverURL: serverURL))
        XCTAssertEqual(cookies.cleared.count, 1)
        XCTAssertEqual(coordinator.phase(for: server.id), .signedOut)
    }

    // MARK: Certificate prompt

    func testTrustingAnUntrustedCertificateRecordsTheSharedDecision() throws {
        let coordinator = makeCoordinator(FakeAPITransport(stubs: []))
        let prompt = CertificatePrompt(
            origin: serverURL,
            certificate: ComparableCertificate(data: "der-bytes", issuerName: "CN=mm.example.com"))
        coordinator.pendingCertificatePrompt = prompt

        coordinator.resolveCertificatePrompt(trust: true, dontTrustAgain: false)

        XCTAssertNil(coordinator.pendingCertificatePrompt)
        XCTAssertTrue(certTrust.isTrusted(serverURL, certificate: prompt.certificate),
                      "the native transport and the webview share one trust bag (T28 §4)")
    }

    func testCancellingACertificatePromptRecordsNoDecision() throws {
        let coordinator = makeCoordinator(FakeAPITransport(stubs: []))
        let prompt = CertificatePrompt(
            origin: serverURL,
            certificate: ComparableCertificate(data: "der-bytes", issuerName: "CN=mm.example.com"))
        coordinator.pendingCertificatePrompt = prompt

        coordinator.resolveCertificatePrompt(trust: false, dontTrustAgain: false)

        XCTAssertFalse(certTrust.isTrusted(serverURL, certificate: prompt.certificate))
        XCTAssertFalse(certTrust.isExplicitlyUntrusted(for: serverURL))
    }

    // MARK: T31-AV F1 — an expiry drops the webview's copy of the credential too

    /// The AV finding in one test: sign-out cleared both copies, expiry cleared one, so "Your
    /// session expired" could be followed by the pane escape hatch still being signed in. The
    /// restore-rejection path is the one an expiry takes at launch.
    func testASessionExpiryClearsTheWebviewCookieAsWellAsTheVault() async throws {
        try vault.setSecret("revoked-token", key: .authToken, serverURL: serverURL)
        let transport = FakeAPITransport(stubs: [
            .ok(payload("api.context.session_expired.app_error", "Session expired", status: 401))
        ])
        let coordinator = makeCoordinator(transport)

        let restored = try await coordinator.restore(server)

        XCTAssertNil(restored)
        XCTAssertEqual(coordinator.phase(for: server.id), .expired)
        XCTAssertNil(vault.getSecret(key: .authToken, serverURL: serverURL),
                     "the vault copy is gone")
        XCTAssertEqual(cookies.cleared.map(\.serverID), [server.id],
                       "an expiry must drop the webview's MMAUTHTOKEN too — otherwise one login has "
                       + "two states and the pane escape hatch stays signed in after "
                       + "\"Your session expired\"")
        XCTAssertEqual(cookies.cleared.map(\.url), [serverURL],
                       "the cookie clear is scoped to this server, not another")
    }

    /// The same guarantee on the *live* path: a 401 from a call on the session's own client (what a
    /// screen does) clears both copies before the banner, and notifies the shell exactly once.
    func testA401FromANonRestoreCallClearsBothCopiesBeforeTheBanner() async throws {
        let transport = FakeAPITransport(stubs: [
            .ok(.json(userJSON(), headers: ["Token": "tok-live"])),
            .ok(payload("api.context.session_expired.app_error", "Session expired", status: 401)),
        ])
        let (coordinator, client) = try makeCoordinatorAndClient(transport)
        var notifications: [UUID] = []
        coordinator.onChange = { notifications.append($0) }

        _ = try await coordinator.signIn(server, loginID: "ada", password: "pw")
        XCTAssertEqual(coordinator.authState(for: server), .signedIn)
        notifications.removeAll()

        // `setPhase` writes the phase and *then* calls `onChange`, so the notification is the signal
        // that the transition landed — no poll of `phase(for:)` (kanban t_00fb623c). Installed after
        // the sign-in on purpose: the earlier `.signedIn` notification would otherwise satisfy it.
        let phaseChanges = TestSignal<UUID>()
        let serverID = server.id
        coordinator.onChange = { changedID in
            notifications.append(changedID)
            phaseChanges.send(changedID)
        }

        // A screen's first GET, on the client the coordinator injected — not a restore.
        do {
            _ = try await client.get(MMUser.self, path: "/users/me", useETag: false)
            XCTFail("the revoked token must not answer 200")
        } catch {
            XCTAssertEqual(error as? MMError, .unauthorized(message: "Session expired"))
        }

        await awaitSignal("the expiry transition", signal: phaseChanges) { $0 == serverID }
        XCTAssertEqual(coordinator.phase(for: server.id), .expired)
        XCTAssertNil(vault.getSecret(key: .authToken, serverURL: serverURL))
        XCTAssertEqual(cookies.cleared.map(\.serverID), [server.id],
                       "one 401 → one cookie clear (the sink and the call site both notice)")
        XCTAssertEqual(notifications, [server.id], "one re-auth notification, not a storm")
    }

    // MARK: T31-AV F2 — the local clear happens before the network

    /// A transport whose `/users/logout` stalls for 2 s: the vault must already be empty while that
    /// call is in flight, or a kill in the window keeps a usable token for a server being removed.
    private final class StallingLogoutTransport: APITransport {
        func send(_ request: APIRequest) async throws -> APIResponse {
            if request.url.path.hasSuffix("/users/logout") {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                throw APITransportError.offline
            }
            return .json(["id": "u1", "username": "ada"], headers: ["Token": "tok-live"])
        }
    }

    func testSignOutClearsTheVaultBeforeTheLogoutCallCompletes() async throws {
        let vault = self.vault!
        let certTrust = self.certTrust!
        let serverURL = self.serverURL
        let coordinator = AuthCoordinator(vault: vault, certTrust: certTrust, cookieClearing: cookies) { config, _ in
            let client = try APIClient(serverURL: config.url,
                                       transport: StallingLogoutTransport(),
                                       retryPolicy: .none,
                                       tokenProvider: { vault.getSecret(key: .authToken, serverURL: config.url) },
                                       sleep: { _ in },
                                       random: { 0 })
            return AuthSession(serverID: config.id, serverURL: config.url, vault: vault, client: client)
        }
        _ = try await coordinator.signIn(server, loginID: "ada", password: "pw")
        XCTAssertEqual(vault.getSecret(key: .authToken, serverURL: serverURL), "tok-live")

        let signOut = Task { await coordinator.signOut(server) }
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertNil(vault.getSecret(key: .authToken, serverURL: serverURL),
                     "0.4 s into a sign-out whose /users/logout is still in flight, the vault must "
                     + "already be empty: otherwise a termination here leaves a usable token behind")
        XCTAssertNil(vault.getSecret(key: .userID, serverURL: serverURL))
        XCTAssertEqual(coordinator.phase(for: server.id), .signedOut,
                       "the shell sees the sign-out immediately, not when the network answers")

        await signOut.value
        XCTAssertEqual(cookies.cleared.count, 1, "the webview copy is cleared as well")
    }

    /// The half `SettingsView` depends on: the vault clear is **synchronous**, so it has happened
    /// before the server row is removed on the same turn (a detached `Task` has not run yet).
    func testBeginSignOutIsSynchronousAndStillRevokesWithTheDiscardedToken() async throws {
        let transport = FakeAPITransport(stubs: [
            .ok(.json(userJSON(), headers: ["Token": "tok-live"])),
            .ok(.json([:])),
        ])
        let coordinator = makeCoordinator(transport)
        _ = try await coordinator.signIn(server, loginID: "ada", password: "pw")

        // No `await` between this call and the assertions — this is the Settings-remove turn.
        let discarded = coordinator.beginSignOut(server)

        XCTAssertNil(vault.getSecret(key: .authToken, serverURL: serverURL),
                     "removing a server must clear its token on the same turn")
        XCTAssertNil(vault.getSecret(key: .userID, serverURL: serverURL))
        XCTAssertEqual(coordinator.phase(for: server.id), .signedOut)
        XCTAssertEqual(discarded.token, "tok-live", "the token is remembered for the revocation")

        await coordinator.finishSignOut(discarded)

        XCTAssertEqual(transport.lastRequest?.url.path, "/api/v4/users/logout")
        XCTAssertEqual(transport.lastRequest?.headers["Authorization"], "Bearer tok-live",
                       "revocation still authenticates — with the token the device just dropped, "
                       + "so the ordered sign-out does not silently become an unauthenticated call")
        XCTAssertEqual(cookies.cleared.count, 1)
    }

    // MARK: T31-AV F3 — a 401 from a call path that does not use the session's client

    /// `MentionPoller` owns its own `URLSession` (background task, no scene), so its 401s cannot
    /// reach `AuthSession.onUnauthorized`. `reportUnauthorized` is the explicit route into the one
    /// re-auth path; this is the coordinator half of that contract.
    func testAReportedUnauthorizedExpiresTheSessionAndClearsBothCopies() async throws {
        let transport = FakeAPITransport(stubs: [
            .ok(.json(userJSON(), headers: ["Token": "tok-live"])),
        ])
        let coordinator = makeCoordinator(transport)
        var notifications: [UUID] = []
        coordinator.onChange = { notifications.append($0) }
        _ = try await coordinator.signIn(server, loginID: "ada", password: "pw")
        notifications.removeAll()

        // What the poller's reporter closure does when a poll gets a 401.
        await coordinator.reportUnauthorized(server)

        XCTAssertEqual(coordinator.phase(for: server.id), .expired,
                       "a poller's 401 must reach the same re-auth path as any other native call")
        XCTAssertEqual(coordinator.authState(for: server), .signedOut)
        XCTAssertNil(vault.getSecret(key: .authToken, serverURL: serverURL))
        XCTAssertEqual(cookies.cleared.map(\.serverID), [server.id],
                       "and it clears the webview copy, exactly like a client-side 401")
        XCTAssertEqual(notifications, [server.id])
    }

    func testAStale401ReportForASignedOutServerRaisesNoBanner() async throws {
        let coordinator = makeCoordinator(FakeAPITransport(stubs: []))

        await coordinator.reportUnauthorized(server)

        XCTAssertEqual(coordinator.phase(for: server.id), .unresolved,
                       "a 401 for a server with no stored session is not an expiry")
        XCTAssertTrue(cookies.cleared.isEmpty)
    }

    // MARK: Helpers

    /// A coordinator whose `AuthSession` client the test also holds, so a test can make a call
    /// *through* the session's client (the documented way for a screen to reach the server).
    private func makeCoordinatorAndClient(_ transport: FakeAPITransport) throws -> (AuthCoordinator, APIClient) {
        let vault = self.vault!
        let certTrust = self.certTrust!
        var created: APIClient?
        let coordinator = AuthCoordinator(vault: vault, certTrust: certTrust, cookieClearing: cookies) { config, _ in
            let client = try APIClient(serverURL: config.url,
                                       transport: transport,
                                       retryPolicy: .none,
                                       tokenProvider: { vault.getSecret(key: .authToken, serverURL: config.url) },
                                       sleep: { _ in },
                                       random: { 0 })
            created = client
            return AuthSession(serverID: config.id, serverURL: config.url, vault: vault, client: client)
        }
        _ = try coordinator.session(for: server)
        return (coordinator, try XCTUnwrap(created, "the coordinator did not build a session"))
    }

}

// MARK: - Error copy (every branch the AV finding named)

/// T31-AV F7: `LoginErrorCopy` is the user-visible copy of the auth surface, and only its network and
/// credential branches had a test. Every remaining branch is pinned here, including the two that
/// prefer the server's own sentence when it sends one.
final class T31LoginErrorCopyTests: XCTestCase {

    func testEveryUncoveredBranchMapsToItsOwnSentence() {
        let cases: [(MMError, String)] = [
            (.rateLimited(retryAfter: 30), "Too many attempts. Try again in 30s."),
            (.rateLimited(retryAfter: nil), "Too many attempts. Try again shortly."),
            (.forbidden(message: nil), "You do not have permission to sign in to this server."),
            (.notFound, "This server has no sign-in endpoint. Check the server address."),
            (MMError.server(status: 503, message: nil), "The server had a problem (503). Try again."),
            (MMError.client(status: 400, message: nil), "The server rejected that sign-in."),
            (.malformedResponse("body was not JSON"),
             "The server's answer could not be read. Check that this is a Mattermost server."),
            (.notSignedIn, "Your session expired. Sign in again."),
            (.invalidURL("nope"), "That server address is not valid."),
            (.cancelled, "Sign-in was cancelled."),
        ]
        for (error, expected) in cases {
            XCTAssertEqual(LoginErrorCopy.message(for: error), expected, "copy for \(error)")
        }
    }

    func testTheServerOwnSentenceWinsWhenItSendsOne() {
        XCTAssertEqual(LoginErrorCopy.message(for: MMError.server(status: 503, message: "Maintenance until 12:00")),
                       "Maintenance until 12:00",
                       "an operator who customises the server's message sees their own words")
        XCTAssertEqual(LoginErrorCopy.message(for: MMError.client(status: 400, message: "Login is disabled")),
                       "Login is disabled")
    }

    func testANonMattermostErrorFallsBackToItsOwnDescription() {
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        XCTAssertEqual(LoginErrorCopy.message(for: Boom()), "boom")
    }

    /// The same table through the form, so the copy is proven to be wired to the screen state and not
    /// only to the helper: a rate-limited server keeps the user on the form with that sentence.
    @MainActor
    func testARateLimitedSignInShowsTheRetrySentenceOnTheForm() async {
        let authenticator = FakeLoginAuthenticator(results: [.failure(.rateLimited(retryAfter: 12))])
        let model = LoginViewModel(serverName: "T",
                                   serverURL: URL(string: "https://mm.example.com")!,
                                   authenticator: authenticator)
        model.loginID = "ada"
        model.password = "pw"

        await model.submit()

        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(model.errorMessage, "Too many attempts. Try again in 12s.")
    }
}

// MARK: - A log sink for the duration of one test

/// Captures every line the app would send to `os_log`, so "no credential in a log line" can be
/// asserted on a live flow instead of on the redaction helper alone.
final class LogCapture {
    private var captured: [String] = []
    private let lock = NSLock()
    private let previousSink: ((String) -> Void)?

    init() {
        previousSink = Logger.testSink
        Logger.testSink = { [weak self] line in
            guard let self else { return }
            self.lock.lock()
            self.captured.append(line)
            self.lock.unlock()
        }
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func stop() {
        Logger.testSink = previousSink
    }
}
