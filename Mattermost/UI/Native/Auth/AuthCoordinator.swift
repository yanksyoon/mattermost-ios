// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/actions/remote/session.ts (login / logout / session restore orchestration),
//        app/client/rest/users.ts (`POST /users/login`, `POST /users/login/mfa`,
//        `POST /users/logout`, `GET /users/me`), app/screens/login/form.tsx (the MFA hand-off),
//        ios/Gekidou/Sources/Gekidou/Keychain.swift (credential storage).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §3; no
// upstream source copied. SwiftUI/async-swift decomposition is this repo's own
// (docs/component-map.md §1).

import Combine
import Foundation

/// The per-server auth state machine the auth screens render, and the shell's `NativeAuthGate`.
///
/// ## Why this object exists at all
///
/// `AuthSession` (T28) already owns *one* server's login/MFA/restore/logout logic and the vault
/// writes. What was missing is the app-level owner of those objects: something that
///  - keeps one live `AuthSession` per configured server for the whole app lifetime (so a 401 from
///    any future native call lands in the same place),
///  - restores stored sessions at launch (the "no login prompt after relaunch" criterion),
///  - converts each session's state into the single value the SwiftUI shell reads
///    (`NativeAuthGate`), and
///  - tells the shell to re-evaluate that value whenever it changes (401, login, logout).
///
/// ## The optimistic launch window (and why it is deliberate)
///
/// `AuthSession.state` is `.signedOut` until `restore()` has actually round-tripped to the server.
/// Using that directly as the gate would flash a login form on every launch, which is exactly the
/// behaviour the card forbids. So an unresolved server (no restore attempt yet this run) is treated
/// as **signed in when the vault holds a token**, i.e. the same answer `VaultAuthGate` gave before
/// this card — and a launcher that is offline keeps that answer instead of locking the user out.
/// Only the server can turn that optimism into `.signedOut`: an accepted token resolves to
/// `.signedIn`, a rejected one to `.expired` (which renders the re-auth banner, not a silent form).
///
/// ## Security boundary
///
/// This object never sees a password beyond passing it to `AuthSession.login`, never logs it, and
/// never persists it: the only credential written to disk is the session token, and only through
/// `SecureVault` (inside `AuthSession`). It holds no bridge/JS surface at all.
@MainActor
final class AuthCoordinator: ObservableObject, NativeAuthGate {

    /// What the shell and the auth screens need to know about one server.
    enum Phase: Equatable {
        /// No restore has resolved yet this run. The gate answers from the vault (see above).
        case unresolved
        case signedIn(username: String, userID: String)
        /// Explicitly signed out: no stored credential (fresh server, or a finished sign-out).
        case signedOut
        /// A stored session was rejected by the server (401). The screen shows re-auth, not a
        /// spinner, and not a bare login form with no explanation.
        case expired

        var isSignedIn: Bool {
            if case .signedIn = self { return true }
            return false
        }

        var isExpired: Bool { self == .expired }

        var username: String? {
            if case .signedIn(let username, _) = self { return username }
            return nil
        }
    }

    /// Per-server phases. Absent means `.unresolved`.
    @Published private(set) var phases: [UUID: Phase] = [:]

    /// Per-server terms-of-service verdicts (T49). Absent means "this run has not asked"; the
    /// launch answer then comes from `termsVerdicts` (the previous run's). The shell's gate reads
    /// this through `termsState(for:)`, and `authState(for:)` folds it into the decision.
    @Published private(set) var termsStates: [UUID: TermsOfServiceState] = [:]

    /// How a server's terms are read and accepted. **Set by `MattermostApp.bindShellStores()`** on
    /// the production object; `nil` means this process performs no TOS check, which is what keeps
    /// the pre-T49 suites (and any host that does not wire the gate) behaving exactly as before.
    ///
    /// It is a factory rather than an object because a provider needs the server's live
    /// `AuthSession`, which is created on first use, not at app launch.
    var makeTermsOfService: ((ServerConfig, AuthSession) -> TermsOfServiceProviding)?

    /// How a **public** (unauthenticated) client is built for a server — the seam the unit suite
    /// scripts to test the policy / sign-up / reset paths without a socket. `nil` means the
    /// production construction below (a real `URLSessionTransport` sharing `certTrust`).
    var makePublicClient: ((ServerConfig) throws -> APIClient)?

    /// An untrusted-certificate decision the *native* transport is waiting on. The auth surface
    /// presents `CertPromptSheet` for it (the webview keeps its own prompt in `ContentView`); the
    /// trust bag itself is shared, so trusting here also covers the webview and vice versa.
    @Published var pendingCertificatePrompt: CertificatePrompt?

    /// Called after every phase change with the server id, so the shell can refresh its gate
    /// (`NativeNavigation.refreshAuthState()`). Wired in `MattermostApp.bindShellStores()`.
    var onChange: ((UUID) -> Void)?

    private let vault: SecureVault
    private let certTrust: CertTrust
    private let cookieClearing: SessionCookieClearing
    private let makeSession: (ServerConfig, @escaping (CertificatePrompt) -> Void) throws -> AuthSession
    /// The last verdict per server, so a relaunch does not mount a workspace for a user whose terms
    /// are outstanding while `restore()` re-validates the answer.
    private let termsVerdicts: TermsOfServiceVerdictStore
    /// One provider per server, kept so a retry/accept reuses the session's own client.
    private var termsProviders: [UUID: TermsOfServiceProviding] = [:]

    /// How the **webview-held** session for a server is read (see `WebSessionAdoption.swift`).
    ///
    /// A seam, not a convenience: the production reader is bound to one server's isolated
    /// `WKWebsiteDataStore`, which is a container-scoped store a test cannot populate from another
    /// process, and the restore path's whole claim — "a login done in the web view is a session here"
    /// — is only testable if that read can be scripted. Production default: the server's own store.
    private let makeCookieReader: (UUID) -> SessionCookieReading

    /// One live session per server, kept for the app lifetime: the transport's `onUnauthorized`
    /// callback belongs to *that* object, so re-creating it would orphan a live 401 path.
    private var sessions: [UUID: AuthSession] = [:]
    private var unauthorizedObservers: [UUID: AnyCancellable] = [:]
    private var resolving: Set<UUID> = []
    /// Servers whose expiry transition (cookie clear → phase) is in flight. A second 401 shares the
    /// one transition instead of clearing twice or notifying the shell twice, and `await`ing it
    /// guarantees the phase has been written when the caller resumes.
    private var expiring: [UUID: Task<Void, Never>] = [:]

    /// - Parameters:
    ///   - makeSession: a seam so tests can supply an `AuthSession` backed by a fake transport.
    ///     Production builds use the convenience `AuthSession` initialiser, whose transport
    ///     shares `certTrust` with the webview (T28 criterion 4).
    ///   - cookieReader: a seam so tests can script the webview-held session; production reads the
    ///     server's own `WKWebsiteDataStore`.
    init(vault: SecureVault = SecureVault(),
         certTrust: CertTrust = CertTrust(),
         cookieClearing: SessionCookieClearing? = nil,
         cookieReader: ((UUID) -> SessionCookieReading)? = nil,
         termsVerdicts: TermsOfServiceVerdictStore = TermsOfServiceVerdictStore(),
         makeSession: ((ServerConfig, @escaping (CertificatePrompt) -> Void) throws -> AuthSession)? = nil) {
        self.vault = vault
        self.certTrust = certTrust
        self.cookieClearing = cookieClearing ?? WebKitSessionCookieClearing()
        self.makeCookieReader = cookieReader ?? { serverID in WebKitSessionCookieReader(serverID: serverID) }
        self.termsVerdicts = termsVerdicts
        if let makeSession {
            self.makeSession = makeSession
        } else {
            self.makeSession = { server, onUntrusted in
                try AuthSession(serverID: server.id,
                                serverURL: server.url,
                                vault: vault,
                                certTrust: certTrust,
                                onUntrustedCertificate: onUntrusted)
            }
        }
    }

    // MARK: - Reading state

    func phase(for serverID: UUID) -> Phase {
        phases[serverID] ?? .unresolved
    }

    func phase(for server: ServerConfig) -> Phase { phase(for: server.id) }

    /// The shell's gate. Signed in when the server's session is live, or (before the server has
    /// answered) when a token is stored — never signed out optimistically, because that would be a
    /// login prompt for a session that is very probably still valid.
    ///
    /// T49 folds the terms-of-service verdict into that answer:
    ///  - a live session with outstanding terms → `.termsOfServiceRequired` (the blocking gate);
    ///  - an unreadable terms answer → the same, so a workspace is never mounted on a guess;
    ///  - a server with no custom terms, or one whose published document this user accepted →
    ///    `.signedIn`, exactly as before.
    ///
    /// During the optimistic launch window the answer comes from the **remembered** verdict
    /// (`termsState(for:)`), which is what keeps a relaunch of a terms-pending user from mounting
    /// the workspace for the length of the restore call.
    func authState(for server: ServerConfig) -> NativeAuthState {
        let state = phase(for: server.id)
        let terms = termsState(for: server)

        switch state {
        case .signedIn:
            return Self.nativeState(TermsOfServiceGate.decide(phase: .signedIn, terms: terms))
        case .signedOut, .expired:
            return .signedOut
        case .unresolved:
            // The pre-T49 optimism, preserved: a stored token keeps the shell signed in while
            // `restore()` is in flight (an offline launch must not become a login screen). The
            // remembered verdict still wins, so a stale "pending" keeps the gate.
            guard hasStoredToken(for: server) else { return .signedOut }
            return Self.nativeState(TermsOfServiceGate.decide(phase: .signedIn, terms: terms))
        }
    }

    /// What the gate knows about this server's terms right now: this run's answer when there is
    /// one, else the previous run's remembered verdict, else `.unknown` (nothing asked yet).
    func termsState(for server: ServerConfig) -> TermsOfServiceState {
        if let state = termsStates[server.id] { return state }
        return termsVerdicts.verdict(for: server.url) ?? .unknown
    }

    private static func nativeState(_ decision: AuthGateDecision) -> NativeAuthState {
        switch decision {
        case .signedIn: return .signedIn
        case .signedOut: return .signedOut
        case .termsOfService: return .termsOfServiceRequired
        }
    }

    /// Whether this device holds a stored session token for `server` (the vault is the one source
    /// of truth, shared with the webview-era shell).
    func hasStoredToken(for server: ServerConfig) -> Bool {
        guard let token = vault.getSecret(key: .authToken, serverURL: server.url) else { return false }
        return !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The signed-in user's id for `serverID`, when the session has resolved it.
    ///
    /// Screen cards need it to tell *their own* rows apart from everyone else's (T32's team
    /// memberships, and later every "is this mine?" question). It is deliberately `nil` before a
    /// restore resolves: callers treat "unknown" as "do not filter", never as a different user.
    func userID(for serverID: UUID) -> String? {
        if case .signedIn(_, let userID) = phase(for: serverID) { return userID }
        return nil
    }

    /// The live session for `server`, creating and observing it on first use.
    ///
    /// - Throws: `MMError.invalidURL`/transport-construction failures from `APIClient`.
    func session(for server: ServerConfig) throws -> AuthSession {
        if let existing = sessions[server.id] { return existing }
        let created = try makeSession(server) { [weak self] prompt in
            Task { @MainActor in self?.pendingCertificatePrompt = prompt }
        }
        sessions[server.id] = created
        // A 401 from *any* authenticated call on this server must land in one place. `AuthSession`
        // only flags re-auth for a live session, so a failed login never arrives here as an expiry.
        // The transition is `requireReauth`, which also drops the webview's copy of the credential
        // (T31-AV F1) — an expiry that cleared only the vault left the pane escape hatch signed in.
        unauthorizedObservers[server.id] = created.$needsReauth
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] needsReauth in
                guard needsReauth else { return }
                Task { @MainActor [weak self] in
                    await self?.requireReauth(server)
                }
            }
        return created
    }

    // MARK: - Session restore (launch / foreground)

    /// Adopt a session that exists **only** in the webview's cookie store.
    ///
    /// The shell's primary sign-in path is the web view: SSO/SAML runs there and the server answers
    /// with an `HttpOnly` `MMAUTHTOKEN`. The native transport reads the vault, not WebKit's cookie
    /// jar, so without this the app boots "signed out" for a user who is plainly signed in — and
    /// every native surface sits on its loading state because its requests are unauthenticated.
    ///
    /// Best effort by design: a missing/expired cookie is not an error, it just means this server
    /// really is signed out.
    ///
    /// - Returns: the session the webview's cookie was adopted as, or `nil` when there was no usable
    ///   cookie. Callers get the session because this **is** the sign-in on this path: a caller that
    ///   only got `true` would have to re-read `phase(for:)` to learn who signed in.
    private func adoptExistingWebSessionIfPresent(_ server: ServerConfig) async -> AuthSession.Session? {
        do {
            let adopted = try await adoptWebSession(server, using: cookieReader(for: server.id))
            MMLog.info("MMAuth", "adopted the webview session for \(server.name)")
            return adopted
        } catch {
            MMLog.info("MMAuth", "no webview session to adopt for \(server.name): \(error)")
            return nil
        }
    }

    /// The reader the harvest asks about `serverID`.
    ///
    /// Production (and Release in every case): the server's own `WKWebsiteDataStore`, exactly as a
    /// webview sign-in left it. DEBUG builds additionally honour a launch-supplied session — see
    /// `seedWebSession(token:for:)`.
    private func cookieReader(for serverID: UUID) -> SessionCookieReading {
        #if DEBUG
        if let token = seededWebSessions[serverID], !token.isEmpty {
            return SeededWebSessionCookieReader(token: token)
        }
        #endif
        return makeCookieReader(serverID)
    }

    #if DEBUG
    /// Per-server sessions a UI-test launch supplied (`-uiTestSeedWebSessionToken`), so a run can
    /// start in the state T31 is about: the webview holds a session, the vault holds nothing.
    ///
    /// Why the session arrives here rather than as a real cookie in the store: writing
    /// `MMAUTHTOKEN` into `WKWebsiteDataStore(forIdentifier:)` at launch was measured to (a) be
    /// silently dropped before the store's WebKit Networking process was up, which made the launch
    /// resolve signed out while the seam logged success, and (b) then crash the app under XCUITest
    /// when that process launched slowly (WebKit logs it as a *fault*, and a fault-level `os_log`
    /// during accessibility snapshotting dies inside XCTest's callback). The full measurement is on
    /// `MattermostApp.seedWebviewSessionIfRequested`. The real WebKit read stays covered by unit
    /// tests against a real store (`T31WebSessionHarvestTests`,
    /// `T31HarvestCookieInstallTests`).
    ///
    /// Compiled out of Release: a shipped build has no way to be handed a session it did not sign in
    /// for.
    private var seededWebSessions: [UUID: String] = [:]

    /// Arm the debug-only seeded session for one server (called by the launch-argument seam).
    func seedWebSession(token: String, for serverID: UUID) {
        seededWebSessions[serverID] = token
    }
    #endif

    /// Restore one server's stored session.
    ///
    /// The order of the four outcomes is the contract:
    /// 1. the vault's token is accepted → `.signedIn`;
    /// 2. the vault's token was **rejected** → the expiry transition (and only that: a dead login
    ///    must not be resurrected from the webview's copy of it);
    /// 3. the vault held **no** token but the webview holds one → adopt it (the Path A login);
    /// 4. neither → `.signedOut`.
    ///
    /// - Returns: the session this server resolved to, or `nil` when it resolved signed out/expired.
    /// - Throws: transport failures only, so an offline launch keeps the optimistic gate instead of
    ///   dropping the user on a login screen (the `AuthSession` contract).
    @discardableResult
    func restore(_ server: ServerConfig) async throws -> AuthSession.Session? {
        guard !resolving.contains(server.id) else { return nil }
        resolving.insert(server.id)
        defer { resolving.remove(server.id) }

        let session = try session(for: server)
        do {
            let restored = try await session.restore()
            if let restored {
                // T49: the terms are checked **before** the phase resolves signed in, so the shell
                // never mounts the workspace on an outstanding acceptance (and a check that cannot
                // be read blocks instead of guessing — see `checkTerms`).
                await checkTerms(ofService: server, session: session)
                setPhase(.signedIn(username: restored.username, userID: restored.userID), for: server.id)
                return restored
            }
            if session.needsReauth {
                // No stored token, or the server rejected it (AuthSession has already cleared the
                // vault copy and flagged re-auth). The expiry transition clears the webview's copy
                // too, before the phase moves, so a consumer that sees `.expired` knows the device
                // holds no credential for this server at all.
                //
                // Deliberately *before* the webview adoption below: a rejected token means this
                // login is dead server-side, and `requireReauth` is already clearing the cookie copy.
                // Adopting from that store would race the clear and could leave the shell signed in
                // on the credential the server just refused.
                await requireReauth(server)
                return nil
            }
            if let adopted = await adoptExistingWebSessionIfPresent(server) {
                // The vault held **no** token, yet the webview does: the sign-in happened in the
                // web view (Path A's normal path — the SPA's own login, or the SSO/SAML hand-off),
                // and this is where the native stack learns about it. `adoptWebSession` has already
                // verified the cookie with `GET /users/me`, persisted it to the vault and set the
                // phase, so the native transport, the socket and every pane are authenticated from
                // here on — and the next launch restores from the vault, not from a cookie.
                return adopted
            }
            setPhase(.signedOut, for: server.id)
            return nil
        } catch {
            // Offline / timeout / untrusted certificate: the launch keeps whatever the vault says.
            MMLog.info("MMAuth", "session restore for \(server.name) could not reach the server; keeping the stored session")
            throw error
        }
    }

    /// Restore every configured server that has not resolved yet. Idempotent: a server that is
    /// already signed in (or already expired) is skipped, so adding a server to the shell does not
    /// re-validate every other session.
    func restoreAll(_ servers: [ServerConfig]) async {
        for server in servers where phase(for: server.id) == .unresolved {
            do {
                _ = try await restore(server)
            } catch {
                // A launch must not fail because one server is unreachable (see `restore`).
            }
        }
    }

    // MARK: - Sign in

    /// Password (+ optional MFA) sign-in for one server. Throws `MMError` for the screen to map;
    /// on success the phase is `.signedIn` and the shell re-renders.
    @discardableResult
    func signIn(_ server: ServerConfig,
                loginID: String,
                password: String,
                mfaToken: String? = nil) async throws -> AuthSession.Session {
        let session = try session(for: server)
        let result = try await session.login(loginID: loginID, password: password, mfaToken: mfaToken)
        // T49: outstanding terms block the shell *here*, before the phase says "signed in". The
        // sign-in itself succeeded — the server minted a token — but the workspace must not mount
        // until the acceptance the server requires has been recorded.
        await checkTerms(ofService: server, session: session)
        setPhase(.signedIn(username: result.username, userID: result.userID), for: server.id)
        return result
    }

    /// SSO hand-off: adopt the session the webview established (the `MMAUTHTOKEN` cookie), then
    /// resolve the identity through the native transport.
    @discardableResult
    func adoptWebSession(_ server: ServerConfig,
                         using reader: SessionCookieReading) async throws -> AuthSession.Session {
        let session = try session(for: server)
        let adopted = try await session.adoptWebSession(using: reader)
        // T49: an SSO hand-off lands on the same terms requirement as a password sign-in.
        await checkTerms(ofService: server, session: session)
        setPhase(.signedIn(username: adopted.username, userID: adopted.userID), for: server.id)
        return adopted
    }

    // MARK: - Public server calls (policy, sign-up, password reset)

    /// A client for the **public** auth calls (`/config/client`, `/users`, password reset).
    ///
    /// It shares this coordinator's `CertTrust`, so a self-signed server prompts once for both the
    /// webview and these calls, and it surfaces an untrusted certificate through the same sheet the
    /// sign-in form already presents. It carries no credential: every call made with it passes
    /// `requiresAuth: false`.
    private func publicClient(for server: ServerConfig) throws -> APIClient {
        if let makePublicClient { return try makePublicClient(server) }
        return try APIClient(serverURL: server.url, vault: vault, certTrust: certTrust) { [weak self] prompt in
            Task { @MainActor in self?.pendingCertificatePrompt = prompt }
        }
    }

    /// The policy the sign-up form obeys and the TOS gate links to.
    func authPolicy(for server: ServerConfig) async throws -> ServerAuthPolicy {
        try await ServerAuthPolicyAPI(client: try publicClient(for: server)).load()
    }

    /// The account-creation / password-reset surface for one server.
    func accountService(for server: ServerConfig) -> AccountServicing {
        ServerAccountAPI { [weak self] in
            guard let self else { throw MMError.notSignedIn }
            return try self.publicClient(for: server)
        }
    }

    // MARK: - Terms of service (T49)

    /// The provider for one server, created on first use from the app-wired factory.
    private func termsProvider(for server: ServerConfig,
                               session: AuthSession) -> TermsOfServiceProviding? {
        if let existing = termsProviders[server.id] { return existing }
        guard let make = makeTermsOfService else { return nil }
        let provider = make(server, session)
        termsProviders[server.id] = provider
        return provider
    }

    /// Ask the server whether this user's terms are outstanding, and remember the answer.
    ///
    /// Outcomes, in the order they are decided:
    ///  1. no provider wired (a unit-test host, or a process that never installed the gate) →
    ///     nothing is claimed; the verdict is left as it was;
    ///  2. `GET /terms_of_service` says there is no document (`404`/`400`) → `.notRequired`, so a
    ///     server without terms behaves exactly as it did before this card;
    ///  3. a document exists and the user's `terms_of_service_id` is it → `.accepted`;
    ///  4. a document exists and the user's id is not it (or is absent) → `.pending(document)`;
    ///  5. anything else (transport, 5xx, an unreadable body) → `.unreadable(reason)`, which the
    ///     gate renders as the blocking screen. Deliberately **not** `.unknown`: an answer that
    ///     could not be read is not an acceptance.
    private func checkTerms(ofService server: ServerConfig, session: AuthSession) async {
        guard let provider = termsProvider(for: server, session: session) else { return }
        do {
            guard let document = try await provider.latestDocument() else {
                setTerms(.notRequired, for: server, notify: false)
                return
            }
            let user = try await provider.currentUser()
            let accepted = !user.termsOfServiceID.isEmpty && user.termsOfServiceID == document.id
            setTerms(accepted ? .accepted : .pending(document), for: server, notify: false)
            MMLog.info("MMAuth", "terms of service \(accepted ? "accepted" : "outstanding") on \(server.name)")
        } catch {
            let reason = LoginErrorCopy.message(for: error)
            setTerms(.unreadable(reason), for: server, notify: false)
            MMLog.info("MMAuth", "terms of service could not be read on \(server.name): \(reason)")
        }
    }

    /// Re-ask the server (the gate's Retry). Notifies the shell even when the verdict is unchanged,
    /// because the user asked and the screen must leave its spinner.
    func retryTermsOfService(_ server: ServerConfig) async {
        guard let session = try? session(for: server) else { return }
        await checkTerms(ofService: server, session: session)
        onChange?(server.id)
    }

    /// The gate's Accept: `POST /users/me/terms_of_service`, then a re-read that must confirm the
    /// acceptance before the shell is allowed to look signed in.
    ///
    /// The verification is the point, not a formality: a gate that believes its own request is the
    /// fake gate the card forbids, and the workspace's first write is refused by the server when
    /// the acceptance did not actually land.
    func acceptTermsOfService(_ server: ServerConfig) async throws {
        guard case .pending(let document) = termsState(for: server) else { return }
        let session = try session(for: server)
        guard let provider = termsProvider(for: server, session: session) else {
            throw MMError.transport("terms of service is not wired in this build")
        }
        try await provider.accept(documentID: document.id)
        let user = try await provider.currentUser()
        guard user.termsOfServiceID == document.id else {
            throw MMError.malformedResponse("terms_of_service was not recorded by the server")
        }
        setTerms(.accepted, for: server, notify: true)
    }

    private func setTerms(_ state: TermsOfServiceState, for server: ServerConfig, notify: Bool) {
        termsStates[server.id] = state
        termsVerdicts.save(state, for: server.url)
        if notify { onChange?(server.id) }
    }

    /// A credential is going away: the terms verdict belongs to it, not to the server forever.
    private func clearTermsState(for server: ServerConfig) {
        termsStates[server.id] = nil
        termsProviders[server.id] = nil
        termsVerdicts.clear(for: server.url)
    }

    // MARK: - Sign out

    /// A credential a sign-out has already discarded. Returned by `beginSignOut` so the async half
    /// (`finishSignOut`) has nothing left to look up — and therefore cannot be reordered back in
    /// front of the local clear.
    struct DiscardedCredential: Equatable {
        var server: ServerConfig
        /// The token the device no longer holds. `nil` when nothing was stored.
        var token: String?
    }

    /// **Synchronous** first half of a sign-out: both credential stores are cleared before this
    /// returns, and the phase is already `.signedOut`.
    ///
    /// It is synchronous on purpose (T31-AV F2). `SettingsView` removes the server on the same turn
    /// it asks for the sign-out, and `Task { await signOut(…) }` has not run a single line when that
    /// removal happens — so a sign-out expressed only as a detached `Task` is, for one turn, no
    /// sign-out at all. The vault delete (the copy a kill would leave *usable*) is therefore done
    /// here; only the webview cookie (WebKit's async store) and the best-effort revocation are async.
    @discardableResult
    func beginSignOut(_ server: ServerConfig) -> DiscardedCredential {
        let discarded: String?
        if let session = sessions[server.id] {
            discarded = session.beginSignOut()
        } else {
            // No live session object: clear the stored credential directly.
            discarded = vault.getSecret(key: .authToken, serverURL: server.url)
            try? vault.deleteSecret(.authToken, serverURL: server.url)
            try? vault.deleteSecret(.userID, serverURL: server.url)
        }
        pendingCertificatePrompt = nil
        clearTermsState(for: server)
        setPhase(.signedOut, for: server.id)
        return DiscardedCredential(server: server, token: discarded)
    }

    /// Async second half: clear the webview's `MMAUTHTOKEN` (the second copy of the same login),
    /// then attempt revocation with the token `beginSignOut` discarded.
    ///
    /// Both halves matter and neither can resurrect a credential: an SSO session exists twice on
    /// this device (vault token + webview cookie), and a failed network call must leave neither
    /// usable — which is exactly what "a failed logout must not leave a usable credential on the
    /// device" forbids. The revocation is best effort; the server expires the token on its own
    /// schedule if it was never reached.
    func finishSignOut(_ discarded: DiscardedCredential) async {
        await cookieClearing.clearAuthCookie(for: discarded.server.url, serverID: discarded.server.id)
        if let session = sessions[discarded.server.id] {
            await session.revokeSession(discardedToken: discarded.token)
        }
    }

    /// Sign out of one server end to end: local clear first, then the cookie, then the revocation.
    func signOut(_ server: ServerConfig) async {
        let discarded = beginSignOut(server)
        await finishSignOut(discarded)
    }

    // MARK: - 401 reported by another call path (not this server's client)

    /// A 401 seen on a call path that does **not** go through this server's `AuthSession` client —
    /// today the background `MentionPoller`, which owns an ephemeral `URLSession` because it runs
    /// from a `BGAppRefreshTask` with no scene.
    ///
    /// Without this, a revoked token left the poller failing silently while the shell still believed
    /// it was signed in, until the next launch/restore (T31-AV F3). It is deliberately the *same*
    /// transition a client-side 401 produces — vault copy dropped, webview cookie cleared, phase
    /// `.expired`, one `onChange` — so the app has one re-auth path regardless of who noticed.
    ///
    /// The rule this encodes for every later screen: **do not build your own `APIClient`/`URLSession`
    /// for authenticated server calls** — take the server's `AuthSession.client` so the 401 lands
    /// here for free. This entry point exists for the one caller that cannot.
    func reportUnauthorized(_ server: ServerConfig) async {
        let current = phase(for: server.id)
        let hadStoredToken = hasStoredToken(for: server)
        // A 401 for a server the shell already treats as signed out is not an expiry (it is a stale
        // request, or a failed login); it must not raise the banner.
        guard current.isSignedIn || (current == .unresolved && hadStoredToken) else { return }

        if let session = sessions[server.id] {
            // Drops the vault copy and flags `needsReauth` (also observed by the sink above; the
            // expiry transition is idempotent, so only one banner and one cookie clear happen).
            session.reportUnauthorized()
        } else {
            try? vault.deleteSecret(.authToken, serverURL: server.url)
            try? vault.deleteSecret(.userID, serverURL: server.url)
        }
        await requireReauth(server)
    }

    // MARK: - Certificate decisions (native transport)

    /// Resolve the pending prompt. `trust == true` records the certificate so the next attempt is
    /// accepted; `dontTrustAgain` records an explicit refusal (desktop "Don't ask again").
    func resolveCertificatePrompt(trust: Bool, dontTrustAgain: Bool) {
        guard let prompt = pendingCertificatePrompt else { return }
        pendingCertificatePrompt = nil
        guard trust || dontTrustAgain else { return }
        try? certTrust.add(prompt.origin, certificate: prompt.certificate, dontTrust: !trust)
    }

    // MARK: - Phase writes

    /// The single expiry transition: **both** copies of the dead credential go, then the phase.
    ///
    /// Ordering is the contract (T31-AV F1/F4). The vault token is deleted by `AuthSession` before
    /// this runs; the webview's `MMAUTHTOKEN` is the second copy of the same login and used to
    /// survive an expiry, so "Your session expired" could be followed by the pane escape hatch still
    /// being signed in. Writing the phase last means anyone who observes `.expired` — the shell, a
    /// test — can rely on the device holding no credential at all.
    ///
    /// Idempotent: a second 401 (or the Combine sink racing the restore path) shares the transition
    /// in flight rather than clearing the cookie twice, and both callers resume only once the phase
    /// has been written — so `await`ing this function means "the device holds no credential and the
    /// shell has been told", never "somebody else is doing that".
    private func requireReauth(_ server: ServerConfig) async {
        if let inFlight = expiring[server.id] {
            await inFlight.value
            return
        }
        guard phase(for: server.id) != .expired else { return }
        let transition = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.cookieClearing.clearAuthCookie(for: server.url, serverID: server.id)
            self.setPhase(.expired, for: server.id)
            MMLog.info("MMAuth", "session expired on \(server.name): both credential copies cleared")
        }
        expiring[server.id] = transition
        await transition.value
        expiring[server.id] = nil
    }

    /// The one place a phase is written, so the shell notification cannot be forgotten.
    private func setPhase(_ phase: Phase, for serverID: UUID) {
        guard self.phase(for: serverID) != phase else { return }
        phases[serverID] = phase
        onChange?(serverID)
    }
}

// MARK: - The screen-facing sign-in seam

/// What a login form needs from the auth layer: one call, typed failures, no storage.
///
/// `AuthCoordinator` conforms through `ServerSignIn` (below) so a screen test can inject a fake and
/// never touch a vault, a transport or a socket.
@MainActor
protocol LoginAuthenticating: AnyObject {
    func login(loginID: String, password: String, mfaToken: String?) async throws -> AuthSession.Session
}

/// Binds `LoginAuthenticating` to one configured server. The screen gets this, not the coordinator,
/// so it cannot loop over servers or mutate another server's session.
@MainActor
final class ServerSignIn: LoginAuthenticating {
    private let server: ServerConfig
    private weak var coordinator: AuthCoordinator?

    init(server: ServerConfig, coordinator: AuthCoordinator) {
        self.server = server
        self.coordinator = coordinator
    }

    func login(loginID: String, password: String, mfaToken: String?) async throws -> AuthSession.Session {
        guard let coordinator else { throw MMError.notSignedIn }
        return try await coordinator.signIn(server,
                                            loginID: loginID,
                                            password: password,
                                            mfaToken: mfaToken)
    }
}
