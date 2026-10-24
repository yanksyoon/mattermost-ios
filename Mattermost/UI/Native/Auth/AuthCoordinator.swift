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
    init(vault: SecureVault = SecureVault(),
         certTrust: CertTrust = CertTrust(),
         cookieClearing: SessionCookieClearing? = nil,
         makeSession: ((ServerConfig, @escaping (CertificatePrompt) -> Void) throws -> AuthSession)? = nil) {
        self.vault = vault
        self.certTrust = certTrust
        self.cookieClearing = cookieClearing ?? WebKitSessionCookieClearing()
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
    func authState(for server: ServerConfig) -> NativeAuthState {
        switch phase(for: server.id) {
        case .signedIn:
            return .signedIn
        case .signedOut, .expired:
            return .signedOut
        case .unresolved:
            return hasStoredToken(for: server) ? .signedIn : .signedOut
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

    /// Restore one server's stored session.
    ///
    /// - Returns: the restored session, or `nil` when the server rejected the stored token or there
    ///   was none.
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
                setPhase(.signedIn(username: restored.username, userID: restored.userID), for: server.id)
            } else if session.needsReauth {
                // No stored token, or the server rejected it (AuthSession has already cleared the
                // vault copy and flagged re-auth). The expiry transition clears the webview's copy
                // too, before the phase moves, so a consumer that sees `.expired` knows the device
                // holds no credential for this server at all.
                await requireReauth(server)
            } else {
                setPhase(.signedOut, for: server.id)
            }
            return restored
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
        setPhase(.signedIn(username: adopted.username, userID: adopted.userID), for: server.id)
        return adopted
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
