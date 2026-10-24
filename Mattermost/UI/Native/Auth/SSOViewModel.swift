// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/sso/sso.tsx + sso_authentication.tsx (the webview-hosted identity provider
//        flow, whose completion is observed as a session, not scraped), and
//        ios/Gekidou/Sources/Gekidou/Keychain.swift (credential storage).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §3; no
// upstream source copied.

import Foundation
import WebKit

/// The webview-held session, written side: dropping the `MMAUTHTOKEN` cookie for one server.
///
/// Sign-out has two halves on this device because a session can arrive two ways: a native sign-in
/// writes `SecureVault`, an SSO hand-off writes the webview's cookie store (and then the vault,
/// when adopted). Clearing only one leaves the other usable — so `AuthCoordinator.signOut` clears
/// both, and this is the cookie half.
protocol SessionCookieClearing {
    func clearAuthCookie(for serverURL: URL, serverID: UUID) async
}

/// Production implementation: the server's **own** persistent `WKWebsiteDataStore(forIdentifier:)`,
/// the same store `WebKitSessionCookieReader` reads and `WebViewStore` writes. `WKWebsiteDataStore`
/// hands back the same underlying store for the same identifier, so this reaches the live cookie.
struct WebKitSessionCookieClearing: SessionCookieClearing {

    func clearAuthCookie(for serverURL: URL, serverID: UUID) async {
        let dataStore = WKWebsiteDataStore(forIdentifier: serverID)
        let cookies = await dataStore.httpCookieStore.allCookies()
        for cookie in cookies where cookie.name == SessionCookiePolicy.authCookieName
            && SessionCookiePolicy.domainMatches(cookieDomain: cookie.domain,
                                                 host: serverURL.host?.lowercased() ?? "") {
            await dataStore.httpCookieStore.deleteCookie(cookie)
        }
    }
}

/// Drives the webview SSO hand-off: watch the server's cookie store until the web app signs in,
/// then adopt that session natively.
///
/// Nothing here parses SAML/OIDC, reads page JavaScript or touches a token header. The identity
/// provider runs inside `WebViewContainer` exactly as it did before (that flow, and its
/// certificate handling, is load-bearing), and the only signal used is the `HttpOnly`
/// `MMAUTHTOKEN` cookie becoming readable through `WKWebsiteDataStore` — the same reader the
/// webview-era shell already had (`SessionCookieReading`, T28).
///
/// Split from the view so the poll/adopt/timeout logic is unit-testable with a stub reader, a
/// stub adopter and a no-op sleeper.
@MainActor
final class SSOViewModel: ObservableObject {

    enum Phase: Equatable {
        /// The webview is on screen; no session yet.
        case waiting
        /// A cookie appeared; the native identity call is in flight.
        case adopting
        case signedIn(username: String)
        /// The hand-off finished without a session (timeout, or the server rejected the cookie).
        case failed(String)
    }

    @Published private(set) var phase: Phase = .waiting
    /// Number of polls performed — the evidence a test (and the build note) can count.
    @Published private(set) var polls = 0
    /// True once the webview reached a page whose URL is the configured server (i.e. the user is
    /// past any external IdP redirect). Presentation only; never used as a credential signal.
    @Published private(set) var isBackOnTheServer = false

    let serverName: String
    private let serverURL: URL
    /// One second: the cookie is set by the web app itself, so the wait is for a human + a request,
    /// not for a timer. Two minutes is well past any interactive sign-in.
    let pollInterval: TimeInterval
    let maxPolls: Int

    init(serverName: String,
         serverURL: URL,
         pollInterval: TimeInterval = 1,
         maxPolls: Int = 120) {
        self.serverName = serverName
        self.serverURL = serverURL
        self.pollInterval = pollInterval
        self.maxPolls = maxPolls
    }

    var isWorking: Bool {
        switch phase {
        case .waiting, .adopting: return true
        case .signedIn, .failed: return false
        }
    }

    /// Poll the cookie store, then adopt. Returns when the hand-off resolves (signed in, failed or
    /// cancelled by the enclosing `.task`).
    ///
    /// - Parameters:
    ///   - reader: where the session cookie is read from (the server's webview store).
    ///   - adopt: the native adoption call (normally `AuthCoordinator.adoptWebSession`).
    ///   - sleep: the wait between polls; injected so tests do not spend real seconds.
    func observe(reader: SessionCookieReading,
                 adopt: @escaping () async throws -> AuthSession.Session,
                 sleep: @escaping () async -> Void = {
                     try? await Task.sleep(nanoseconds: 1_000_000_000)
                 }) async {
        for _ in 0..<maxPolls {
            if Task.isCancelled { return }
            polls += 1
            let token = await reader.authToken(for: serverURL)
            guard let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                await sleep()
                continue
            }
            phase = .adopting
            do {
                let session = try await adopt()
                phase = .signedIn(username: session.username)
            } catch {
                phase = .failed(Self.message(for: error))
            }
            return
        }
        phase = .failed("Sign-in was not completed in the web view. Try again, or use another sign-in method.")
    }

    /// The webview reached the configured server again (used for the status line only).
    func noteNavigation(to url: URL?) {
        guard let host = url?.host?.lowercased(), let serverHost = serverURL.host?.lowercased() else { return }
        isBackOnTheServer = host == serverHost
    }

    /// A failed sign-in the webview reported through its own page (e.g. the IdP returned an error):
    /// the honest state is "failed", not an endless spinner.
    func fail(_ message: String) {
        phase = .failed(message)
    }

    /// Re-arm the hand-off after a failure ("Try again"): back to `waiting`, poll count reset.
    func restart() {
        polls = 0
        phase = .waiting
    }

    /// Copy for an adoption failure. The webview has already done the hard part; this only explains
    /// why the *native* side could not take over.
    static func message(for error: Error) -> String {
        guard let mmError = error as? MMError else {
            return "Signed in, but this device could not complete the hand-off. Try again."
        }
        switch mmError {
        case .notSignedIn:
            return "The web view has no session yet. Finish signing in, then this screen continues by itself."
        case .unauthorized:
            return "The server rejected the web session. Sign in again."
        case .offline:
            return "You appear to be offline, so the session could not be confirmed."
        case .timeout:
            return "The server took too long to confirm the session."
        case .certificateUntrusted:
            return "This server's certificate is not trusted yet. Review the prompt, then try again."
        default:
            return mmError.errorDescription ?? "Signed in, but this device could not complete the hand-off."
        }
    }
}
