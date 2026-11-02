// T49 — the terms-of-service gate, and sign-up / forgot-password (S06, S04).
//
// The suite is split the way the card's acceptance criteria are:
//   1. the **pure** gate derivation (`AuthPhase` × `TermsOfServiceState` → blocked / signedIn) —
//      pending, accepted, a server without terms, and an unreadable answer;
//   2. the **coordinator** wiring: a sign-in with outstanding terms never reports `.signedIn` to the
//      shell, Accept flips it, sign-out forgets it, and a remembered verdict blocks the optimistic
//      launch window;
//   3. the **requests**: `GET /terms_of_service`, `POST /users/me/terms_of_service`,
//      `POST /users`, `POST /users/password/reset/send` — asserted on the bytes a fake transport
//      receives, not on a UI observation;
//   4. the **server policy** decode: the sign-up copy and rules come from `GET /config/client`,
//      including the 9.11 shape where every value is a string.

import Foundation
import XCTest
@testable import Mattermost

// MARK: - Fakes

@MainActor
final class FakeTermsOfServiceProvider: TermsOfServiceProviding {
    var document: TermsOfServiceDocument?
    var documentError: Error?
    var user = MMUser(id: "u1", username: "ada")
    var userError: Error?
    var acceptError: Error?
    /// Whether `accept` is reflected by the next `currentUser()` — the "server recorded it" half.
    var reflectsAcceptance = true

    private(set) var acceptedDocumentIDs: [String] = []

    func latestDocument() async throws -> TermsOfServiceDocument? {
        if let documentError { throw documentError }
        return document
    }

    func currentUser() async throws -> MMUser {
        if let userError { throw userError }
        var current = user
        if reflectsAcceptance, let id = acceptedDocumentIDs.last {
            current.termsOfServiceID = id
        }
        return current
    }

    func accept(documentID: String) async throws {
        if let acceptError { throw acceptError }
        acceptedDocumentIDs.append(documentID)
    }
}

@MainActor
final class FakeAccountService: AccountServicing {
    var policyValue = ServerAuthPolicy()
    var policyError: Error?
    var created: [(email: String, password: String)] = []
    var createResultID = "new-user-id"
    var createError: Error?
    var resets: [String] = []
    var resetError: Error?

    func policy() async throws -> ServerAuthPolicy {
        if let policyError { throw policyError }
        return policyValue
    }

    func createAccount(email: String, password: String) async throws -> String {
        if let createError { throw createError }
        created.append((email, password))
        return createResultID
    }

    func requestPasswordReset(email: String) async throws {
        if let resetError { throw resetError }
        resets.append(email)
    }
}

// MARK: - 1. The pure gate

final class T49TermsOfServiceGateTests: XCTestCase {

    private let document = TermsOfServiceDocument(id: "tos-1", text: "Accept these terms.")

    func testPendingTermsBlockASignedInSession() {
        XCTAssertEqual(TermsOfServiceGate.decide(phase: .signedIn, terms: .pending(document)),
                       .termsOfService,
                       "a live session with an outstanding acceptance must not mount the workspace")
    }

    func testAcceptedTermsLetTheSessionThrough() {
        XCTAssertEqual(TermsOfServiceGate.decide(phase: .signedIn, terms: .accepted), .signedIn)
    }

    func testAServerWithoutTermsNeverShowsTheGate() {
        XCTAssertEqual(TermsOfServiceGate.decide(phase: .signedIn, terms: .notRequired), .signedIn,
                       "404/feature-disabled must behave exactly as the shell did before T49")
    }

    func testAnUnreadableAnswerFailsClosedToTheGate() {
        XCTAssertEqual(TermsOfServiceGate.decide(phase: .signedIn, terms: .unreadable("500")),
                       .termsOfService,
                       "an answer that could not be read is not an acceptance")
    }

    func testAnUnaskedQuestionIsTodayBehaviourNotAnAcceptance() {
        XCTAssertEqual(TermsOfServiceGate.decide(phase: .signedIn, terms: .unknown), .signedIn)
    }

    func testSignedOutAndExpiredAlwaysFailToTheSignInScreen() {
        let states: [TermsOfServiceState] = [.unknown, .notRequired, .accepted,
                                             .pending(document), .unreadable("offline")]
        for terms in states {
            XCTAssertEqual(TermsOfServiceGate.decide(phase: .signedOut, terms: terms), .signedOut)
            XCTAssertEqual(TermsOfServiceGate.decide(phase: .expired, terms: terms), .signedOut)
        }
    }

    func testTheBlockingDocumentIsThePendingOne() {
        XCTAssertEqual(TermsOfServiceGate.blockingDocument(phase: .signedIn, terms: .pending(document)),
                       document)
        XCTAssertNil(TermsOfServiceGate.blockingDocument(phase: .signedIn, terms: .accepted))
        XCTAssertNil(TermsOfServiceGate.blockingDocument(phase: .signedOut, terms: .pending(document)),
                     "the gate is never mounted for a signed-out server")
    }
}

// MARK: - 2. The coordinator's wiring

@MainActor
final class T49AuthCoordinatorGateTests: XCTestCase {

    private var vault: SecureVault!
    private var store: InMemorySecretStore!
    private var certTrust: CertTrust!
    private var verdicts: TermsOfServiceVerdictStore!
    private var server: ServerConfig!
    private var serverURL: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        store = InMemorySecretStore()
        vault = SecureVault(serviceNamespace: "t49-vault-\(UUID().uuidString)", secureStore: store)
        certTrust = CertTrust(serviceNamespace: "t49-cert-\(UUID().uuidString)",
                              secureStore: InMemorySecretStore())
        // A private defaults suite per test: verdicts must not leak between tests (or into the
        // pre-T49 suites, which share `UserDefaults.standard` and `https://mm.example.com`).
        let suite = "t49-verdicts-\(UUID().uuidString)"
        suiteName = suite
        defaults = UserDefaults(suiteName: suite)!
        verdicts = TermsOfServiceVerdictStore(defaults: defaults, keyPrefix: "t49.")
        serverURL = URL(string: "https://t49-\(UUID().uuidString).example.com")!
        server = ServerConfig(name: "T49 Server", url: serverURL)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func userJSON(username: String = "ada", termsID: String? = nil) -> [String: Any] {
        var body: [String: Any] = ["id": "u1", "username": username, "email": "ada@example.com"]
        if let termsID { body["terms_of_service_id"] = termsID }
        return body
    }

    private func makeCoordinator(_ transport: FakeAPITransport,
                                 terms: FakeTermsOfServiceProvider? = nil) -> AuthCoordinator {
        let vault = self.vault!
        let coordinator = AuthCoordinator(vault: vault,
                                          certTrust: certTrust,
                                          cookieClearing: FakeCookieClearing(),
                                          termsVerdicts: verdicts) { config, _ in
            let client = try APIClient(serverURL: config.url,
                                       transport: transport,
                                       retryPolicy: .none,
                                       tokenProvider: { vault.getSecret(key: .authToken, serverURL: config.url) },
                                       sleep: { _ in },
                                       random: { 0 })
            return AuthSession(serverID: config.id, serverURL: config.url, vault: vault, client: client)
        }
        if let terms {
            coordinator.makeTermsOfService = { _, _ in terms }
        }
        return coordinator
    }

    private func loginTransport() -> FakeAPITransport {
        FakeAPITransport(stubs: [.ok(.json(userJSON(), headers: ["Token": "tok-1"]))])
    }

    func testSignInWithOutstandingTermsReportsTheGateNotTheWorkspace() async throws {
        let terms = FakeTermsOfServiceProvider()
        let document = TermsOfServiceDocument(id: "tos-1", text: "Accept these terms.")
        terms.document = document
        let coordinator = makeCoordinator(loginTransport(), terms: terms)

        let session = try await coordinator.signIn(server, loginID: "ada", password: "hunter2")

        XCTAssertEqual(session.userID, "u1", "the login itself succeeded — the server minted a token")
        XCTAssertEqual(coordinator.phase(for: server.id), .signedIn(username: "ada", userID: "u1"))
        XCTAssertEqual(coordinator.termsState(for: server), .pending(document))
        XCTAssertEqual(coordinator.authState(for: server), .termsOfServiceRequired,
                       "an outstanding acceptance must never reach the shell as .signedIn")
    }

    func testSignInOnAServerWithoutTermsIsUntouched() async throws {
        let terms = FakeTermsOfServiceProvider()
        terms.document = nil
        let coordinator = makeCoordinator(loginTransport(), terms: terms)

        _ = try await coordinator.signIn(server, loginID: "ada", password: "hunter2")

        XCTAssertEqual(coordinator.termsState(for: server), .notRequired)
        XCTAssertEqual(coordinator.authState(for: server), .signedIn)
    }

    func testAnAcceptedDocumentIsSignedIn() async throws {
        let terms = FakeTermsOfServiceProvider()
        terms.document = TermsOfServiceDocument(id: "tos-1", text: "Terms")
        terms.user = MMUser(id: "u1", username: "ada", termsOfServiceID: "tos-1")
        let coordinator = makeCoordinator(loginTransport(), terms: terms)

        _ = try await coordinator.signIn(server, loginID: "ada", password: "hunter2")

        XCTAssertEqual(coordinator.termsState(for: server), .accepted)
        XCTAssertEqual(coordinator.authState(for: server), .signedIn)
    }

    func testAnUnreadableTermsAnswerBlocksInsteadOfMountingTheWorkspace() async throws {
        let terms = FakeTermsOfServiceProvider()
        terms.documentError = MMError.server(status: 500, message: nil)
        let coordinator = makeCoordinator(loginTransport(), terms: terms)

        _ = try await coordinator.signIn(server, loginID: "ada", password: "hunter2")

        guard case .unreadable = coordinator.termsState(for: server) else {
            return XCTFail("expected .unreadable, got \(coordinator.termsState(for: server))")
        }
        XCTAssertEqual(coordinator.authState(for: server), .termsOfServiceRequired)
    }

    func testAcceptRecordsTheDocumentAndUnblocksTheShell() async throws {
        let terms = FakeTermsOfServiceProvider()
        let document = TermsOfServiceDocument(id: "tos-1", text: "Terms")
        terms.document = document
        let coordinator = makeCoordinator(loginTransport(), terms: terms)
        var notified: [UUID] = []
        coordinator.onChange = { notified.append($0) }

        _ = try await coordinator.signIn(server, loginID: "ada", password: "hunter2")
        notified.removeAll()
        try await coordinator.acceptTermsOfService(server)

        XCTAssertEqual(terms.acceptedDocumentIDs, ["tos-1"],
                       "the accept is the card's POST /users/me/terms_of_service")
        XCTAssertEqual(coordinator.termsState(for: server), .accepted)
        XCTAssertEqual(coordinator.authState(for: server), .signedIn)
        XCTAssertEqual(notified, [server.id], "the shell is told once, so it re-reads the gate")
    }

    func testAnAcceptTheServerDidNotRecordIsNotTreatedAsAccepted() async throws {
        let terms = FakeTermsOfServiceProvider()
        terms.document = TermsOfServiceDocument(id: "tos-1", text: "Terms")
        terms.reflectsAcceptance = false
        let coordinator = makeCoordinator(loginTransport(), terms: terms)
        _ = try await coordinator.signIn(server, loginID: "ada", password: "hunter2")

        do {
            try await coordinator.acceptTermsOfService(server)
            XCTFail("a POST whose acceptance the server does not echo must not unblock the shell")
        } catch {
            XCTAssertEqual(coordinator.authState(for: server), .termsOfServiceRequired)
        }
    }

    func testAFailedAcceptKeepsTheGate() async throws {
        let terms = FakeTermsOfServiceProvider()
        terms.document = TermsOfServiceDocument(id: "tos-1", text: "Terms")
        terms.acceptError = MMError.client(status: 400, message: "no")
        let coordinator = makeCoordinator(loginTransport(), terms: terms)
        _ = try await coordinator.signIn(server, loginID: "ada", password: "hunter2")

        do {
            try await coordinator.acceptTermsOfService(server)
            XCTFail("expected the server's rejection")
        } catch {
            XCTAssertEqual(coordinator.authState(for: server), .termsOfServiceRequired)
        }
    }

    func testRestoreChecksTheTermsBeforeItResolvesSignedIn() async throws {
        try vault.setSecret("stored-token", key: .authToken, serverURL: serverURL)
        let terms = FakeTermsOfServiceProvider()
        terms.document = TermsOfServiceDocument(id: "tos-1", text: "Terms")
        let transport = FakeAPITransport(stubs: [.ok(.json(userJSON()))])
        let coordinator = makeCoordinator(transport, terms: terms)

        let restored = try await coordinator.restore(server)

        XCTAssertNotNil(restored)
        XCTAssertEqual(coordinator.authState(for: server), .termsOfServiceRequired,
                       "the relaunch path must gate exactly like the sign-in path")
    }

    /// The launch window: no restore has resolved, a token is stored, and the previous run saw
    /// outstanding terms. The shell must show the gate — not the workspace for one round trip.
    func testTheRememberedVerdictBlocksTheOptimisticLaunchWindow() throws {
        try vault.setSecret("stored-token", key: .authToken, serverURL: serverURL)
        let document = TermsOfServiceDocument(id: "tos-1", text: "Terms")
        verdicts.save(.pending(document), for: serverURL)
        let coordinator = makeCoordinator(FakeAPITransport(stubs: []))

        XCTAssertEqual(coordinator.phase(for: server.id), .unresolved)
        XCTAssertEqual(coordinator.termsState(for: server), .pending(document))
        XCTAssertEqual(coordinator.authState(for: server), .termsOfServiceRequired)
    }

    func testARememberedAcceptanceStillCountsAsSignedInAtLaunch() throws {
        try vault.setSecret("stored-token", key: .authToken, serverURL: serverURL)
        verdicts.save(.accepted, for: serverURL)
        let coordinator = makeCoordinator(FakeAPITransport(stubs: []))

        XCTAssertEqual(coordinator.authState(for: server), .signedIn)
    }

    func testSignOutForgetsTheVerdict() async throws {
        let terms = FakeTermsOfServiceProvider()
        terms.document = TermsOfServiceDocument(id: "tos-1", text: "Terms")
        let coordinator = makeCoordinator(loginTransport(), terms: terms)
        _ = try await coordinator.signIn(server, loginID: "ada", password: "hunter2")
        XCTAssertNotNil(verdicts.verdict(for: serverURL))

        await coordinator.signOut(server)

        XCTAssertEqual(coordinator.authState(for: server), .signedOut)
        XCTAssertEqual(coordinator.termsState(for: server), .unknown)
        XCTAssertNil(verdicts.verdict(for: serverURL),
                     "the verdict belonged to the credential that just went away")
    }

    func testAPolicyCanStillBeReadWithoutASession() async throws {
        let transport = FakeAPITransport(stubs: [.ok(.json(["PasswordMinimumLength": "14"]))])
        let coordinator = makeCoordinator(transport, terms: nil)
        // No token is in the vault: the policy path must build its own public client.
        coordinator.makePublicClient = { config in
            try APIClient(serverURL: config.url, transport: transport, retryPolicy: .none,
                          tokenProvider: { nil })
        }

        let policy = try await coordinator.authPolicy(for: server)

        XCTAssertEqual(policy.minimumPasswordLength, 14)
        XCTAssertEqual(transport.lastRequest?.url.path, "/api/v4/config/client")
        XCTAssertNil(transport.lastRequest?.headers["Authorization"],
                     "the policy call is public and must not carry a credential")
    }
}

// MARK: - 3. The requests

@MainActor
final class T49TermsOfServiceAPITests: XCTestCase {

    private let url = URL(string: "https://t49-api.example.com")!

    private func makeSession(_ transport: FakeAPITransport) throws -> AuthSession {
        let vault = SecureVault(serviceNamespace: "t49-api-\(UUID().uuidString)",
                                secureStore: InMemorySecretStore())
        let serverURL = url
        try vault.setSecret("tok-1", key: .authToken, serverURL: serverURL)
        let client = try APIClient(serverURL: serverURL,
                                   transport: transport,
                                   retryPolicy: .none,
                                   tokenProvider: { vault.getSecret(key: .authToken, serverURL: serverURL) },
                                   sleep: { _ in },
                                   random: { 0 })
        return AuthSession(serverID: UUID(), serverURL: serverURL, vault: vault, client: client)
    }

    func testLatestDocumentReadsTheServersDocument() async throws {
        let transport = FakeAPITransport(stubs: [.ok(.json([
            "id": "tos-1",
            "create_at": 1_793_644_926_809,
            "user_id": "admin",
            "text": "These are the terms."
        ]))])
        let api = ServerTermsOfServiceAPI(session: try makeSession(transport))

        let document = try await api.latestDocument()

        XCTAssertEqual(document?.id, "tos-1")
        XCTAssertEqual(document?.text, "These are the terms.")
        XCTAssertEqual(transport.lastRequest?.url.path, "/api/v4/terms_of_service")
        XCTAssertEqual(transport.lastRequest?.headers["Authorization"], "Bearer tok-1")
    }

    func testAServerWithoutTermsAnswers404AndThatIsNotAnError() async throws {
        let transport = FakeAPITransport(stubs: [.ok(.json([
            "id": "app.user_terms_of_service.get_by_user.no_rows.app_error",
            "message": "No terms of service found.",
            "status_code": 404
        ], status: 404))])
        let api = ServerTermsOfServiceAPI(session: try makeSession(transport))

        let document = try await api.latestDocument()

        XCTAssertNil(document, "404 is the server saying 'there is nothing to accept'")
    }

    func testTheFeatureDisabledAnswerIsAlsoNoTerms() async throws {
        let transport = FakeAPITransport(stubs: [.ok(.json([
            "id": "api.create_terms_of_service.custom_terms_of_service_disabled.app_error",
            "message": "Custom terms of service feature is disabled.",
            "status_code": 400
        ], status: 400))])
        let api = ServerTermsOfServiceAPI(session: try makeSession(transport))

        let document = try await api.latestDocument()
        XCTAssertNil(document)
    }

    func testAFailedReadThrowsSoTheGateCanFailClosed() async throws {
        let transport = FakeAPITransport(stubs: [.ok(.json(["message": "boom"], status: 500))])
        let api = ServerTermsOfServiceAPI(session: try makeSession(transport))

        do {
            _ = try await api.latestDocument()
            XCTFail("a 5xx must not read as 'no terms'")
        } catch {
            XCTAssertTrue(error is MMError)
        }
    }

    func testAcceptPostsTheCamelCaseBodyTheServerExpects() async throws {
        let transport = FakeAPITransport(stubs: [.ok(.json(["status": "OK"]))])
        let api = ServerTermsOfServiceAPI(session: try makeSession(transport))

        try await api.accept(documentID: "tos-1")

        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.url.path, "/api/v4/users/me/terms_of_service")
        let body = try XCTUnwrap(request.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["termsOfServiceId"] as? String, "tos-1")
        XCTAssertEqual(json["accepted"] as? Bool, true)
    }
}

@MainActor
final class T49AccountRequestTests: XCTestCase {

    private let url = URL(string: "https://t49-account.example.com")!

    private func makeService(_ transport: FakeAPITransport) throws -> ServerAccountAPI {
        let client = try APIClient(serverURL: url,
                                   transport: transport,
                                   retryPolicy: .none,
                                   tokenProvider: { nil })
        return ServerAccountAPI { client }
    }

    func testCreateAccountPostsEmailAndPasswordWithoutACredential() async throws {
        let transport = FakeAPITransport(stubs: [.ok(.json([
            "id": "new-user", "username": "new", "email": "new@example.com"
        ], status: 201))])
        let service = try makeService(transport)

        let id = try await service.createAccount(email: "new@example.com", password: "Long-Enough-1")

        XCTAssertEqual(id, "new-user")
        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.url.path, "/api/v4/users")
        XCTAssertNil(request.headers["Authorization"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.body)) as? [String: Any])
        XCTAssertEqual(json["email"] as? String, "new@example.com")
        XCTAssertEqual(json["password"] as? String, "Long-Enough-1")
    }

    func testPasswordResetPostsTheEmailToTheServersEndpoint() async throws {
        let transport = FakeAPITransport(stubs: [.ok(.json(["status": "OK"]))])
        let service = try makeService(transport)

        try await service.requestPasswordReset(email: "ada@example.com")

        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.url.path, "/api/v4/users/password/reset/send")
        XCTAssertNil(request.headers["Authorization"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.body)) as? [String: Any])
        XCTAssertEqual(json["email"] as? String, "ada@example.com")
    }

    func testAPasswordResetTheServerCouldNotSendIsAnErrorNotASuccess() async throws {
        let transport = FakeAPITransport(stubs: [.ok(.json([
            "id": "api.user.send_password_reset.send.app_error",
            "message": "Failed to send password reset email successfully.",
            "status_code": 500
        ], status: 500))])
        let service = try makeService(transport)

        do {
            try await service.requestPasswordReset(email: "ada@example.com")
            XCTFail("a 500 must surface as a failure, not the sent state")
        } catch let error as MMError {
            XCTAssertEqual(LoginErrorCopy.message(for: error), "Failed to send password reset email successfully.")
        }
    }

    func testThePolicyIsDecodedFromTheStringValuedClientConfig() async throws {
        let transport = FakeAPITransport(stubs: [.ok(.json([
            "PasswordMinimumLength": "14",
            "PasswordRequireNumber": "true",
            "PasswordRequireUppercase": "false",
            "EnableSignUpWithEmail": "false",
            "EnableUserCreation": "true",
            "TermsOfServiceLink": "https://mm.example.com/terms",
            "SiteName": "Example"
        ]))])
        let service = try makeService(transport)

        let policy = try await service.policy()

        XCTAssertEqual(policy.minimumPasswordLength, 14)
        XCTAssertEqual(policy.maximumPasswordLength, 72)
        XCTAssertTrue(policy.requiresNumber)
        XCTAssertFalse(policy.requiresUppercase)
        XCTAssertFalse(policy.offersSignUp)
        XCTAssertEqual(policy.termsOfServiceLink?.absoluteString, "https://mm.example.com/terms")
        XCTAssertEqual(transport.lastRequest?.url.path, "/api/v4/config/client")
        XCTAssertEqual(transport.lastRequest?.url.query, "format=old")
    }
}

// MARK: - 4. The policy, purely

final class T49ServerAuthPolicyTests: XCTestCase {

    func testAnOlderServersMissingKeysTakeTheDocumentedDefaults() {
        let policy = ServerAuthPolicy(clientConfig: [:])

        XCTAssertEqual(policy.minimumPasswordLength, 8, "the server's own default")
        XCTAssertEqual(policy.maximumPasswordLength, 72)
        XCTAssertTrue(policy.offersSignUp)
        XCTAssertTrue(policy.allowsPasswordReset)
        XCTAssertNil(policy.termsOfServiceEnabled, "absent is 'not stated', never 'off'")
        XCTAssertNil(policy.termsOfServiceLink)
    }

    func testTheCopyAndTheRuleUseTheServersNumbers() {
        let policy = ServerAuthPolicy(clientConfig: [
            "PasswordMinimumLength": .string("14"),
            "PasswordMaximumLength": .string("64"),
            "PasswordRequireUppercase": .string("true"),
            "PasswordRequireSymbol": .string("true")
        ])

        XCTAssertEqual(policy.passwordPolicyCopy,
                       "Use 14–64 characters. The server also requires an uppercase letter and a symbol.")
        XCTAssertEqual(policy.passwordProblem("short"), "Password must be at least 14 characters.")
        XCTAssertEqual(policy.passwordProblem("aaaaaaaaaaaaaa"), "Password must include an uppercase letter.")
        XCTAssertEqual(policy.passwordProblem("AAAAAAAAAAAAAA1"), "Password must include a symbol.")
        XCTAssertNil(policy.passwordProblem("Aaaaaaaaaaaaaa1!"))
        XCTAssertEqual(policy.passwordProblem(String(repeating: "a", count: 65)),
                       "Password must be at most 64 characters.")
    }

    func testTheTermsKeyHasNoBearingOnTheGateWhenAbsent() {
        // Measured on 9.11.19: `GET /config/client?format=old` does not publish the TOS keys at
        // all. The gate must therefore never require them — the document endpoint decides.
        let policy = ServerAuthPolicy(clientConfig: ["SiteName": .string("Mattermost")])
        XCTAssertNil(policy.termsOfServiceEnabled)
    }

    func testEmailShape() {
        XCTAssertTrue(EmailAddress.isValid("ada@example.com"))
        XCTAssertFalse(EmailAddress.isValid(""))
        XCTAssertFalse(EmailAddress.isValid("ada"))
        XCTAssertFalse(EmailAddress.isValid("ada@example"))
        XCTAssertFalse(EmailAddress.isValid("ada @example.com"))
        XCTAssertFalse(EmailAddress.isValid("@example.com"))
    }

    func testAUserDocumentCarriesTheAcceptanceFacts() throws {
        let json = """
        {"id":"u1","username":"ada","email":"ada@example.com",
         "terms_of_service_id":"tos-9","terms_of_service_create_at":1793644933083}
        """
        let user = try JSONDecoder().decode(MMUser.self, from: Data(json.utf8))
        XCTAssertEqual(user.termsOfServiceID, "tos-9")
        XCTAssertEqual(user.termsOfServiceCreateAt, 1_793_644_933_083)

        let older = try JSONDecoder().decode(MMUser.self, from: Data(#"{"id":"u1","username":"ada"}"#.utf8))
        XCTAssertEqual(older.termsOfServiceID, "", "an older server omits the key entirely")
    }
}

// MARK: - 5. The two forms

@MainActor
final class T49SignUpViewModelTests: XCTestCase {

    private func makeModel(_ service: FakeAccountService,
                           policy: ServerAuthPolicy? = ServerAuthPolicy()) -> SignUpViewModel {
        if let policy { service.policyValue = policy }
        return SignUpViewModel(serverName: "T49 Server", service: service)
    }

    func testTheButtonWaitsForAValidEmailAndAMatchingPolicyCompliantPassword() async {
        let service = FakeAccountService()
        let model = makeModel(service)
        await model.loadPolicy()

        model.email = "not-an-email"
        model.password = "Long-Enough-1"
        model.confirmPassword = "Long-Enough-1"
        XCTAssertFalse(model.canSubmit, "the address is not an address")

        model.email = "new@example.com"
        model.password = "short"
        model.confirmPassword = "short"
        XCTAssertFalse(model.canSubmit, "below the server's minimum")

        model.password = "Long-Enough-1"
        model.confirmPassword = "Long-Enough-2"
        XCTAssertFalse(model.canSubmit, "the confirmation does not match")

        model.confirmPassword = "Long-Enough-1"
        XCTAssertTrue(model.canSubmit)
    }

    func testSubmitCreatesTheAccountAndEntersTheVerificationState() async {
        let service = FakeAccountService()
        let model = makeModel(service)
        await model.loadPolicy()
        model.email = " New@Example.com "
        model.password = "Long-Enough-1"
        model.confirmPassword = "Long-Enough-1"

        await model.submit()

        XCTAssertEqual(service.created.first?.email, "new@example.com",
                       "the address is trimmed and lowercased before POST /users")
        XCTAssertEqual(model.phase, .created(email: "new@example.com"))
        XCTAssertEqual(model.password, "", "the password is dropped once it has done its job")
    }

    func testAShortPasswordIsStoppedLocallyWithTheServersSentence() async {
        let service = FakeAccountService()
        let model = makeModel(service, policy: ServerAuthPolicy(minimumPasswordLength: 14))
        await model.loadPolicy()
        model.email = "new@example.com"
        model.password = "only-twelve1"
        model.confirmPassword = "only-twelve1"

        await model.submit()

        XCTAssertTrue(service.created.isEmpty, "no request for a password the server would reject")
        XCTAssertEqual(model.errorMessage, "Password must be at least 14 characters.")
    }

    func testAServerCopyOfTheFailureIsShownVerbatim() async {
        let service = FakeAccountService()
        service.policyValue = ServerAuthPolicy(minimumPasswordLength: 8)
        service.createError = MMError.client(status: 400, message: "An account with that email already exists.")
        let model = makeModel(service)
        await model.loadPolicy()
        model.email = "new@example.com"
        model.password = "Long-Enough-1"
        model.confirmPassword = "Long-Enough-1"

        await model.submit()

        XCTAssertEqual(model.errorMessage, "An account with that email already exists.")
        XCTAssertFalse(model.phase.isCreated)
    }
}

@MainActor
final class T49ForgotPasswordViewModelTests: XCTestCase {

    func testAnInvalidAddressNeverReachesTheServer() async {
        let service = FakeAccountService()
        let model = ForgotPasswordViewModel(service: service)
        model.email = "not-an-email"

        await model.submit()

        XCTAssertTrue(service.resets.isEmpty)
        XCTAssertEqual(model.errorMessage, "Please enter a valid email address.")
    }

    func testASentRequestShowsTheConfirmationAndKeepsTheAccountsPrivacy() async {
        let service = FakeAccountService()
        let model = ForgotPasswordViewModel(service: service)
        model.email = " Ada@Example.com "

        await model.submit()

        XCTAssertEqual(service.resets, ["ada@example.com"])
        XCTAssertEqual(model.phase, .sent(email: "ada@example.com"))
        XCTAssertNil(model.errorMessage)
    }

    func testAFailedSendIsShownHonestly() async {
        let service = FakeAccountService()
        service.resetError = MMError.server(status: 500,
                                            message: "Failed to send password reset email successfully.")
        let model = ForgotPasswordViewModel(service: service)
        model.email = "ada@example.com"

        await model.submit()

        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(model.errorMessage, "Failed to send password reset email successfully.",
                       "a server with no SMTP must not show the sent state")
    }
}

// MARK: - 6. The logger crash this card surfaced

/// Surfaced by T49's first full-suite run: the host app crashed at launch inside
/// `Logger.os(_:)` (`-[__NSCFNumber objectForKey:]`) while `AuthCoordinator.restoreAll` logged from
/// several threads. The category cache was an unsynchronised `static var`; the gate added one more
/// concurrent reader at launch, which is what made the pre-existing race reproducible.
///
/// The assertion is only "it completes": a corrupted dictionary crashes the process rather than
/// returning a wrong value, so reaching the end *is* the observation. It is kept because the race
/// is invisible in every other test — the app simply dies before the suite starts.
final class T49LoggerConcurrencyTests: XCTestCase {
    func testConcurrentLoggingFromManyThreadsDoesNotCorruptTheCategoryCache() {
        let group = DispatchGroup()
        for thread in 0..<32 {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                for line in 0..<100 {
                    Logger.debug("T49-concurrent-\(thread % 5)", "thread \(thread) line \(line)")
                    Logger.info("T49-concurrent-shared", "shared \(thread)/\(line)")
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 60), .success)
    }
}
