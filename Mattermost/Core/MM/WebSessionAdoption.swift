// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0, `app/client/rest/users.ts` and the
// webapp's `MMAUTHTOKEN` cookie hand-off; this repo's `WebViewContainer` SSO path. Own
// implementation per docs/path-b-adr.md §3.

import Foundation
import WebKit

/// Reads the session the **webview already established** so a native transport can adopt it.
///
/// Why this exists: the card keeps SSO/SAML/OIDC on the webview hand-off (that flow, and its
/// certificate handling, is load-bearing), but everything after sign-in is native. The web app
/// authenticates with the `MMAUTHTOKEN` cookie, which is `HttpOnly` — page JavaScript cannot read
/// it, and it must not be exfiltrated through the bridge. The one legitimate reader is the shell
/// itself, through `WKWebsiteDataStore.httpCookieStore`, which is exactly what
/// `WebKitSessionCookieReader` does. No SAML parsing, no token juggling in JS.
protocol SessionCookieReading {
    /// The `MMAUTHTOKEN` value the webview holds for `serverURL`, if the user is signed in there.
    func authToken(for serverURL: URL) async -> String?
}

/// Cookie matching rules, kept pure so they are testable without a `WKWebsiteDataStore`.
enum SessionCookiePolicy {

    /// The cookie Mattermost issues for a session (mobile `MattermostClient.login` accepts the
    /// same cookie when the `Token` header is absent).
    static let authCookieName = "MMAUTHTOKEN"

    /// The value of `name` among `cookies` that belongs to `serverURL`'s host and is not expired.
    ///
    /// Domain matching follows RFC 6265 §5.1.3 closely enough for our use: an exact host match, or
    /// a leading-dot/registrable-parent domain that the host falls under. Cookies from other hosts
    /// on the same device are never considered (that would be a cross-server credential leak).
    static func value(named name: String,
                      in cookies: [HTTPCookie],
                      for serverURL: URL,
                      now: Date = Date()) -> String? {
        guard let host = serverURL.host?.lowercased(), !host.isEmpty else { return nil }
        for cookie in cookies where cookie.name == name {
            guard domainMatches(cookieDomain: cookie.domain, host: host) else { continue }
            guard cookie.expiresDate.map({ $0 > now }) ?? true else { continue }
            guard !cookie.value.isEmpty else { continue }
            return cookie.value
        }
        return nil
    }

    static func domainMatches(cookieDomain: String, host: String) -> Bool {
        var domain = cookieDomain.lowercased()
        if domain.hasPrefix(".") { domain.removeFirst() }
        if domain.isEmpty { return false }
        if domain == host { return true }
        // A parent-domain cookie (`.example.com`) applies to `mm.example.com` — but only on a dot
        // boundary, so `notexample.com` never matches `example.com`.
        return host.hasSuffix("." + domain)
    }
}

/// The **written** side of the same cookie: the shell's own session, installed into a webview that
/// has none so a permanently-web surface (T46, `docs/dual-render.md` §13) opens signed in.
///
/// Why it is needed: a session can exist in two places, and only one of them is WebKit.
///  - signed in through the **webview** (T31's SSO hand-off): `MMAUTHTOKEN` is already in the
///    server's `WKWebsiteDataStore`, and a second webview on that store simply has it;
///  - signed in through the **native form** (T31's S01 card): the token lives in `SecureVault` and
///    the webview has no cookie at all, so a web fallback would show the login page — a second
///    login for a session the app already holds.
///
/// This policy builds the cookies that close the second case. It never reads a page and never hands
/// the token to JavaScript: it writes an `HttpOnly` token cookie into the shell-owned data store,
/// which is the same mechanism the server itself uses (`Set-Cookie: MMAUTHTOKEN=…`).
///
/// ## It is three cookies, not one (T46-R, measured)
///
/// The first implementation installed `MMAUTHTOKEN` alone. The surface then booted… and logged
/// itself out: on 9.11.19 the web app's boot issues `PUT /api/v4/users/me/patch` and
/// `POST /api/v4/users/logout` (both 200), because a session it cannot use is a session it clears.
/// The server's own browser login answers with **three** cookies, all `Path=/`, `Max-Age=2592000`:
///
///     MMAUTHTOKEN=<session token>; HttpOnly
///     MMUSERID=<user id>
///     MMCSRF=<26-char token>
///
/// `MMUSERID` is the identity the client reads to decide it is signed in; `MMCSRF` is the
/// double-submit CSRF token the client sends as `X-CSRF-Token` on state-changing requests (the
/// server compares header to cookie, so the value itself is not a secret the server holds). Without
/// them the boot's own requests fail the CSRF check and the client signs the session out — measured,
/// `docs/t46-build-note.md` §5.3. So the shell installs the same triple, in the same scope, and a
/// fallback surface opens on a session the web app can actually use.
enum WebSessionCookiePolicy {

    /// The names, in the order the server sets them (`Set-Cookie` on `POST /api/v4/users/login`).
    static let userIDCookieName = "MMUSERID"
    static let csrfCookieName = "MMCSRF"

    /// The browser lifetime the server uses for these cookies (`Max-Age=2592000`, 30 days —
    /// `SessionLengthWebInDays`). A session cookie would work, but the server's own is persistent,
    /// and a fallback must not lose the session when the reader leaves the sheet.
    static let lifetime: TimeInterval = 30 * 24 * 60 * 60

    /// The session cookies for `serverURL`, or `[]` when the origin cannot carry them.
    ///
    /// Scoped to the server's host with path `/` — the same scope the server sets, so a sub-path
    /// install (`https://host/company/mattermost`) is covered by it. `secure` follows the server's
    /// own scheme: a `http://127.0.0.1:8065` fixture must still receive the cookie, and an
    /// `https://` server must not accept it over plaintext.
    ///
    /// - Parameters:
    ///   - token: the session token (`SecureVault.authToken`).
    ///   - userID: the signed-in user's id (`SecureVault.userID`), needed by the web client's boot.
    ///   - csrf: the double-submit CSRF value. Defaults to a fresh 26-character token, the shape the
    ///     server issues; only the cookie↔header agreement matters to the server.
    static func sessionCookies(for serverURL: URL,
                               token: String,
                               userID: String,
                               csrf: String = newCSRFToken(),
                               now: Date = Date()) -> [HTTPCookie] {
        guard let host = serverURL.host, !host.isEmpty,
              let scheme = serverURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              !token.isEmpty else { return [] }

        let expires = now.addingTimeInterval(lifetime)
        func cookie(_ name: String, _ value: String, httpOnly: Bool) -> HTTPCookie? {
            Self.cookie(name: name, value: value, host: host, expires: expires,
                        httpOnly: httpOnly, secure: scheme == "https")
        }

        return [
            cookie(SessionCookiePolicy.authCookieName, token, httpOnly: true),
            cookie(userIDCookieName, userID, httpOnly: false),
            cookie(csrfCookieName, csrf, httpOnly: false),
        ].compactMap { $0 }
    }

    /// The single token cookie. Kept because it is the one a reader of this file looks for, and the
    /// unit tests pin its scope; `sessionCookies` is what the fallback installs.
    static func authCookie(for serverURL: URL, token: String,
                           now: Date = Date()) -> HTTPCookie? {
        guard let host = serverURL.host, !host.isEmpty,
              let scheme = serverURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              !token.isEmpty else { return nil }
        return cookie(name: SessionCookiePolicy.authCookieName,
                      value: token,
                      host: host,
                      expires: now.addingTimeInterval(lifetime),
                      httpOnly: true,
                      secure: scheme == "https")
    }

    private static func cookie(name: String,
                               value: String,
                               host: String,
                               expires: Date,
                               httpOnly: Bool,
                               secure: Bool) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: host,
            .path: "/",
            .expires: expires,
        ]
        // The server's token cookie is HttpOnly; the page must not read the token back out of
        // `document.cookie` through a plugin screen. `MMUSERID` and `MMCSRF` are readable by the
        // web app by design (it reads both), so they stay plain.
        if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        // Measured: `HTTPCookie` treats the *presence* of the `secure` property as "secure", so
        // writing `FALSE` yields `isSecure == true` and an `http://` fixture would never send it.
        // The attribute is therefore omitted for http, not falsified.
        if secure { properties[.secure] = "TRUE" }
        return HTTPCookie(properties: properties)
    }

    /// A 26-character lowercase-alphanumeric token, the shape Mattermost issues (`MMCSRF`,
    /// session ids and tokens are all 26 chars of `[a-z0-9]`).
    static func newCSRFToken() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<26).map { _ in alphabet.randomElement()! })
    }
}

/// The production reader: asks the webview's own cookie store for the session token.
///
/// The store matters. This app gives every server its **own** persistent
/// `WKWebsiteDataStore(forIdentifier: server.id)` (`ViewStore.ensureStore(for:)` →
/// `WebViewStore(dataStoreIdentifier:)`), so `.default()` holds no session cookie for any server
/// and a reader pointed at it answers `nil` for every real sign-in. There is therefore no
/// default-value initializer: a caller has to say which store it means — either the server id
/// (production) or a store it already owns (tests, diagnostics).
struct WebKitSessionCookieReader: SessionCookieReading {
    let dataStore: WKWebsiteDataStore

    /// Production: the isolated store of the server whose webview signed in.
    init(serverID: UUID) {
        self.dataStore = WKWebsiteDataStore(forIdentifier: serverID)
    }

    /// Explicit store (tests, and callers that already hold the server's `WebViewStore`). No
    /// default argument: `.default()` is never the store a server's session lives in.
    init(dataStore: WKWebsiteDataStore) {
        self.dataStore = dataStore
    }

    func authToken(for serverURL: URL) async -> String? {
        let cookies = await dataStore.httpCookieStore.allCookies()
        return SessionCookiePolicy.value(named: SessionCookiePolicy.authCookieName,
                                         in: cookies,
                                         for: serverURL)
    }
}
