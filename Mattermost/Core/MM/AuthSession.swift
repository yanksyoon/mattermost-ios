// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0, `app/client/rest/users.ts`
// (`POST /users/login`, `POST /users/login/mfa`, `POST /users/logout`), Gekidou
// `Keychain.swift` (credential storage) and this repo's desktop parity row
// `AuthInfo`/`secureStorage` -> `SecureVault`. Own implementation per docs/path-b-adr.md §3.

import Combine
import Foundation

/// Per-server authentication: login, MFA, session restore, logout, and 401 → re-auth surfacing.
///
/// Credential storage is the **existing** `SecureVault` (`authToken` + `userID`), not a second
/// vault — `SecureVault` already gives the shell a Keychain-first, encrypted-file-fallback store
/// keyed by the canonical server URL, and duplicating it would be a security regression, not a
/// feature.
///
/// SSO/SAML/OIDC stay exactly where they are: the webview hand-off in `WebViewContainer`, whose
/// certificate handling is load-bearing. When that flow completes, the shell calls
/// `adoptWebSession(using:)` with a reader bound to **that server's** webview cookie store, and
/// everything downstream (REST, socket, screen state) is native from there.
///
/// There is deliberately no `adoptSSOSession(token:…)` take-a-token entry point: the cookie store
/// is the only legitimate producer of an SSO session, so the shell has no API that would let a JS
/// bridge hand native code a token string it obtained some other way.
@MainActor
final class AuthSession: ObservableObject {

    /// A signed-in session. The token is held for the transport, and is **redacted** from
    /// `description`/`debugDescription` so an accidental interpolation (a crash report, a
    /// `print`, a test failure message) cannot leak it.
    struct Session: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
        let serverID: UUID
        let userID: String
        let username: String
        let token: String

        var description: String {
            "Session(server: \(serverID.uuidString), user: \(username), token: <redacted>)"
        }

        var debugDescription: String { description }
    }

    enum State: Equatable {
        case signedOut
        case signedIn(Session)
    }

    @Published private(set) var state: State = .signedOut
    /// `true` after a 401 invalidated a live session: screens show re-auth instead of a spinner.
    @Published private(set) var needsReauth = false

    let serverID: UUID
    let serverURL: URL

    private let vault: SecureVault
    private let client: APIClient

    /// - Parameters:
    ///   - client: an `APIClient` for this server. Its token provider must read the same vault
    ///     this session writes (the convenience initializer wires that automatically).
    init(serverID: UUID, serverURL: URL, vault: SecureVault, client: APIClient) {
        self.serverID = serverID
        self.serverURL = serverURL
        self.vault = vault
        self.client = client
        self.client.onUnauthorized = { [weak self] in
            Task { @MainActor [weak self] in self?.handleUnauthorized() }
        }
    }

    /// Production wiring: `URLSessionTransport` (sharing `CertTrust` with the webview) plus a
    /// token provider backed by `SecureVault`.
    convenience init(serverID: UUID,
                     serverURL: URL,
                     vault: SecureVault = SecureVault(),
                     certTrust: CertTrust = CertTrust(),
                     onUntrustedCertificate: ((CertificatePrompt) -> Void)? = nil,
                     retryPolicy: APIClient.RetryPolicy = APIClient.RetryPolicy()) throws {
        let transport = URLSessionTransport(serverURL: serverURL,
                                            certTrust: certTrust,
                                            onUntrustedCertificate: onUntrustedCertificate)
        let client = try APIClient(serverURL: serverURL,
                                   transport: transport,
                                   retryPolicy: retryPolicy,
                                   tokenProvider: { vault.getSecret(key: .authToken, serverURL: serverURL) })
        self.init(serverID: serverID, serverURL: serverURL, vault: vault, client: client)
    }

    // MARK: - Login

    /// `POST /users/login` (or `/users/login/mfa` when `mfaToken` is supplied).
    ///
    /// Throws `MMError.mfaRequired` when the server demands a second factor; the caller then
    /// re-invokes with `mfaToken`. A wrong password and a wrong MFA code are distinguishable
    /// (`.unauthorized` vs `.invalidMFA`) because the screens show different copy.
    @discardableResult
    func login(loginID: String, password: String, mfaToken: String? = nil) async throws -> Session {
        let trimmedLogin = loginID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLogin.isEmpty, !password.isEmpty else {
            throw MMError.unauthorized(message: "Enter your email or username and password.")
        }

        var body: [String: String] = ["login_id": trimmedLogin, "password": password]
        let path: String
        if let mfaToken, !mfaToken.trimmingCharacters(in: .whitespaces).isEmpty {
            body["token"] = mfaToken.trimmingCharacters(in: .whitespaces)
            path = "/users/login/mfa"
        } else {
            path = "/users/login"
        }
        let payload = try JSONEncoder().encode(body)

        let response: APIResponse
        do {
            response = try await client.postForResponse(path: path, body: payload, requiresAuth: false)
        } catch let error as MMError {
            if case .unauthorized = error, path == "/users/login/mfa" {
                throw MMError.invalidMFA(message: "That authentication code was not accepted.")
            }
            throw error
        }

        guard let token = response.sessionToken, !token.isEmpty else {
            // A 200 without a token is not a session; fail loudly instead of storing nothing.
            throw MMError.malformedResponse("login response carried no session token")
        }
        let user = try client.decode(MMUser.self, from: response)
        return try persist(Session(serverID: serverID,
                                   userID: user.id,
                                   username: user.username,
                                   token: token))
    }

    /// SSO hand-off, read straight from the webview's cookie store.
    ///
    /// The web app signs in with the `HttpOnly` `MMAUTHTOKEN` cookie; this asks the shell-side
    /// reader for it (never page JavaScript), then resolves the identity with one authenticated
    /// call. If the identity call fails the token is not left behind.
    @discardableResult
    func adoptWebSession(using reader: SessionCookieReading) async throws -> Session {
        guard let token = await reader.authToken(for: serverURL),
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MMError.notSignedIn
        }
        try vault.setSecret(token, key: .authToken, serverURL: serverURL)
        do {
            let user = try await client.currentUser()
            return try persist(Session(serverID: serverID,
                                       userID: user.id,
                                       username: user.username,
                                       token: token))
        } catch {
            try? vault.deleteSecret(.authToken, serverURL: serverURL)
            throw error
        }
    }

    // MARK: - Restore

    /// Restore a stored session at launch. Returns `nil` when no token is stored or the token was
    /// rejected; throws only for transport failures (so an offline launch can show cached UI
    /// instead of a sign-in screen).
    @discardableResult
    func restore() async throws -> Session? {
        guard let token = vault.getSecret(key: .authToken, serverURL: serverURL), !token.isEmpty else {
            state = .signedOut
            return nil
        }
        do {
            let user = try await client.currentUser()
            let session = Session(serverID: serverID,
                                  userID: user.id,
                                  username: user.username,
                                  token: token)
            try? vault.setSecret(user.id, key: .userID, serverURL: serverURL)
            state = .signedIn(session)
            needsReauth = false
            return session
        } catch MMError.unauthorized {
            clearStoredCredentials()
            needsReauth = true
            state = .signedOut
            return nil
        }
    }

    // MARK: - Logout

    /// `POST /users/logout`, then drop the stored credentials either way. A failed network call must
    /// not leave a usable credential on the device.
    func logout() async {
        _ = try? await client.postForResponse(path: "/users/logout", body: nil, requiresAuth: true)
        // A sign-out is a full clear: token *and* the user id that identifies its owner.
        try? vault.deleteSecret(.authToken, serverURL: serverURL)
        try? vault.deleteSecret(.userID, serverURL: serverURL)
        client.clearETagCache()
        needsReauth = false
        state = .signedOut
    }

    // MARK: - 401 surfacing

    /// A 401 from any authenticated call: the server no longer accepts the token.
    private func handleUnauthorized() {
        // A 401 while signed *out* is a failed login attempt, not an expired session.
        guard case .signedIn = state else { return }
        clearStoredCredentials()
        needsReauth = true
        state = .signedOut
        MMLog.info("MMAuth", "server rejected the session token; re-auth required")
    }

    // MARK: - Helpers

    /// The token the socket needs. Never logged, never placed in a URL.
    var currentToken: String? {
        if case .signedIn(let session) = state { return session.token }
        return vault.getSecret(key: .authToken, serverURL: serverURL)
    }

    private func persist(_ session: Session) throws -> Session {
        do {
            try vault.setSecret(session.token, key: .authToken, serverURL: serverURL)
            try vault.setSecret(session.userID, key: .userID, serverURL: serverURL)
        } catch {
            // Storing the credential is the point of signing in: fail rather than pretend.
            throw MMError.transport("could not persist the session credential")
        }
        state = .signedIn(session)
        needsReauth = false
        MMLog.info("MMAuth", "signed in as \(session.username) on \(serverURL.host ?? "server")")
        return session
    }

    private func clearStoredCredentials() {
        try? vault.deleteSecret(.authToken, serverURL: serverURL)
    }
}
