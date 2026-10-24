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

/// The production reader: asks the webview's own cookie store for the session token.
struct WebKitSessionCookieReader: SessionCookieReading {
    let dataStore: WKWebsiteDataStore

    init(dataStore: WKWebsiteDataStore = .default()) {
        self.dataStore = dataStore
    }

    func authToken(for serverURL: URL) async -> String? {
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            dataStore.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
        return SessionCookiePolicy.value(named: SessionCookiePolicy.authCookieName,
                                         in: cookies,
                                         for: serverURL)
    }
}
