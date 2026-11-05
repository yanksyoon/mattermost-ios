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

    /// Whether `cookie` is present in `cookies` — name, **value** and scope all agreeing.
    ///
    /// This is the verification half of `WebSessionCookieInstaller`: a store that still holds a
    /// previous launch's token under the same name must not be read as "the write landed", or an
    /// installer would report success for a cookie it never stored.
    static func isPresent(_ cookie: HTTPCookie, in cookies: [HTTPCookie]) -> Bool {
        let domain = normalizedDomain(cookie.domain)
        let path = cookie.path.isEmpty ? "/" : cookie.path
        return cookies.contains { present in
            present.name == cookie.name
                && present.value == cookie.value
                && normalizedDomain(present.domain) == domain
                && (present.path.isEmpty ? "/" : present.path) == path
        }
    }

    /// A cookie domain without its leading dot, lowercased (`WebKit` keeps some domains dotted).
    static func normalizedDomain(_ domain: String) -> String {
        let lower = domain.lowercased()
        return lower.hasPrefix(".") ? String(lower.dropFirst()) : lower
    }
}

/// A cookie store a writer can install into.
///
/// `WKHTTPCookieStore` in production; a scripted double in the unit suite, because the failure this
/// abstraction exists for — a write the store silently discards — cannot be provoked on demand
/// against WebKit. See `WebSessionCookieInstaller`.
protocol SessionCookieStoring {
    func allCookies() async -> [HTTPCookie]
    func setCookie(_ cookie: HTTPCookie) async
}

/// The production cookie store: `WKWebsiteDataStore.httpCookieStore`, unwrapped to this protocol.
///
/// ## The main-thread rule this type exists to keep (measured, t_d393d211)
///
/// `WKHTTPCookieStore` is UI-process API, and `setCookie` is **not** executor-neutral: the first
/// write into a store whose WebKit **Networking** process is not up yet creates that process
/// synchronously on the calling thread, and that path traps off-main. Measured against
/// `WKWebsiteDataStore(forIdentifier:)` on iPhone 16 Pro / iOS 18.3.1: a Swift `async` caller that
/// reached `install(_:)` from a **nonisolated** async function ran on a cooperative thread and the
/// test host died instantly with `EXC_BREAKPOINT` in `WebKit::allDataStores()`
/// (`HTTPCookieStore::setCookies` → `filterAppBoundCookies` → `NetworkProcessProxy`, crash report
/// `Mattermost-2026-11-05-073146.ips`). The same write issued from a `@MainActor` test body
/// (`AuthSessionTests`) passes.
///
/// So the hop lives *here*, at the one place that touches WebKit: `SessionCookieStoring` stays
/// nonisolated (the scripted double in the unit suite must be usable from any context), and the
/// production conformance answers its `async` requirements on the main actor regardless of where
/// it was awaited from.
struct WebKitCookieStore: SessionCookieStoring {
    let store: WKHTTPCookieStore

    func allCookies() async -> [HTTPCookie] { await allCookiesOnMain(in: store) }

    func setCookie(_ cookie: HTTPCookie) async { await setCookieOnMain(cookie, in: store) }
}

/// The main-actor side of `WebKitCookieStore` — see the note on that type.
@MainActor
private func allCookiesOnMain(in store: WKHTTPCookieStore) async -> [HTTPCookie] {
    await store.allCookies()
}

/// The main-actor side of `WebKitCookieStore` — see the note on that type.
@MainActor
private func setCookieOnMain(_ cookie: HTTPCookie, in store: WKHTTPCookieStore) async {
    await store.setCookie(cookie)
}

/// The same rule for the reader: reach the store's cookie store from the main actor, so the
/// property access and the WebKit call share one thread.
@MainActor
private func allCookiesOnMain(in dataStore: WKWebsiteDataStore) async -> [HTTPCookie] {
    await dataStore.httpCookieStore.allCookies()
}

/// The reader's production path: **resolve the store and read it on one main-actor turn**.
///
/// The resolution is the point. `WKWebsiteDataStore(forIdentifier:)` is not a plain object
/// construction: it goes through WebKit's data-store registry (`WebKit::allDataStores()`), which is
/// UI-process state and traps off-main — measured on t_249bc296 (iPhone 16 Pro / iOS 18.3.1,
/// `EXC_BREAKPOINT`, "Test crashed with signal trap") with a reader built from a **nonisolated**
/// async test method, the same executor the t_d393d211 crash report
/// (`Mattermost-2026-11-05-073146.ips`) was captured on. Hopping only the `allCookies()` call was
/// therefore not enough: the initializer had already touched the registry by then.
@MainActor
private func allCookiesOnMain(forServerID serverID: UUID) async -> [HTTPCookie] {
    let dataStore = WKWebsiteDataStore(forIdentifier: serverID)
    return await dataStore.httpCookieStore.allCookies()
}

/// Install cookies into a webview data store, and **verify that they landed**.
///
/// ## Why a verification loop, and not `setCookie` alone (measured)
///
/// `WKHTTPCookieStore.setCookie` completes whether or not the store keeps the cookie. The store's
/// WebKit **Networking** process is launched lazily on first use of a fresh app launch, and a write
/// issued while it is still coming up is dropped without an error. Measured on the T31 harvest path
/// (`t_4528b67e`, 2026-11-04, iPhone 16 Pro / iOS 18.3.1, `http://127.0.0.1:8065`):
///
///     t0    setCookie(MMAUTHTOKEN) → log line "planted", allCookies() == []   (same instance)
///     t2    allCookies() 2 s later                       == []   (so: discarded, not delayed)
///     t2b   setCookie again, after the process was up    == ["MMAUTHTOKEN@127.0.0.1"]
///     …and the harvest then adopted it: "signed in as perfprobe", "adopted the webview session".
///
/// The consequence is not cosmetic: a launch that plants the webview's session (the
/// `-uiTestSeedWebSessionToken` seam) or shares the shell's session with a fallback pane (T46,
/// `WebFallbackModel.installSession()`) would resolve as *signed out* with no failure anywhere in
/// the log. The T31 harvest suite was red for exactly that reason — its cookie never existed — not
/// because the harvest was wrong.
///
/// So the rule here is: write, read back, and only report success when the cookie is really in the
/// store. The default window (8 rounds × 0.25 s) covers the measured ~1.3–1.7 s process launch, and
/// costs nothing on a warm store, where the first round already verifies.
struct WebSessionCookieInstaller {
    let store: SessionCookieStoring
    /// Write→verify rounds before giving up. Each round rewrites every cookie.
    var attempts: Int = 8
    /// Wait between rounds.
    var interval: TimeInterval = 0.25
    /// How the installer waits — injected so the unit suite does not spend the window for real.
    var pause: @Sendable (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    init(store: SessionCookieStoring,
         attempts: Int = 8,
         interval: TimeInterval = 0.25,
         pause: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
             try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
         }) {
        self.store = store
        self.attempts = attempts
        self.interval = interval
        self.pause = pause
    }

    /// Production convenience: install into a server's own persistent store.
    @MainActor
    init(dataStore: WKWebsiteDataStore,
         attempts: Int = 8,
         interval: TimeInterval = 0.25,
         pause: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
             try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
         }) {
        self.init(store: WebKitCookieStore(store: dataStore.httpCookieStore),
                  attempts: attempts, interval: interval, pause: pause)
    }

    /// Write every cookie, then confirm each one is in the store.
    ///
    /// - Returns: the **names** of the cookies the store never kept; empty means everything landed.
    ///   Callers must not treat an empty return as "probably fine" — a non-empty one means the
    ///   session this install stood for does not exist on the device.
    @discardableResult
    func install(_ cookies: [HTTPCookie]) async -> [String] {
        let targets = cookies
        guard !targets.isEmpty else { return [] }
        let rounds = max(1, attempts)
        var missing = targets.map(\.name)
        for round in 0..<rounds {
            for cookie in targets { await store.setCookie(cookie) }
            let present = await store.allCookies()
            missing = targets.filter { !SessionCookiePolicy.isPresent($0, in: present) }.map(\.name)
            if missing.isEmpty { return [] }
            if round + 1 < rounds { await pause(interval) }
        }
        return missing
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
///
/// ## The main-thread rule this type keeps (measured, t_d393d211 → t_249bc296)
///
/// Both the store resolution and the cookie read happen on the main actor inside
/// `allCookiesOnMain(forServerID:)`, whichever executor `authToken(for:)` is awaited from. That is
/// not a nicety: `WKWebsiteDataStore(forIdentifier:)` reaches `WebKit::allDataStores()` and traps
/// off-main (iPhone 16 Pro / iOS 18.3.1, `EXC_BREAKPOINT`, crash report
/// `Mattermost-2026-11-05-073146.ips`; reproduced on the initializer itself by t_249bc296). The hop
/// is in `authToken`, not in the initializers, so `SessionCookieReading` stays nonisolated and the
/// struct stays constructible from any context.
struct WebKitSessionCookieReader: SessionCookieReading {
    /// Where the store comes from. The store itself is resolved *inside* `cookiesOnMain` — see the
    /// note on that helper: resolving a per-identifier store is a WebKit data-store-registry call,
    /// so it may not happen in this (nonisolated) initializer or anywhere else off the main actor.
    fileprivate enum Source {
        case server(UUID)
        case store(WKWebsiteDataStore)
    }

    fileprivate let source: Source

    /// Production: the isolated store of the server whose webview signed in.
    init(serverID: UUID) {
        self.source = .server(serverID)
    }

    /// Explicit store (tests, and callers that already hold the server's `WebViewStore`). No
    /// default argument: `.default()` is never the store a server's session lives in.
    init(dataStore: WKWebsiteDataStore) {
        self.source = .store(dataStore)
    }

    func authToken(for serverURL: URL) async -> String? {
        let cookies: [HTTPCookie]
        switch source {
        case .server(let serverID):
            cookies = await allCookiesOnMain(forServerID: serverID)
        case .store(let store):
            cookies = await allCookiesOnMain(in: store)
        }
        return SessionCookiePolicy.value(named: SessionCookiePolicy.authCookieName,
                                         in: cookies,
                                         for: serverURL)
    }
}

#if DEBUG
/// A **UI-test** stand-in for the webview's `MMAUTHTOKEN`: answers with a token the launch supplied
/// (`-uiTestSeedWebSessionToken`), so a live run can start with "the webview is signed in, the vault
/// holds nothing" without launching a WebKit process inside an XCUITest run.
///
/// Why the substitution is legitimate, and what it does **not** cover:
///  - the behaviour T31 claims — a launch whose only credential is the webview's session reaches the
///    native workspace — is entirely downstream of this answer: `AuthCoordinator.restore` finds no
///    vault token, asks a `SessionCookieReading`, verifies the token with `GET /users/me`, persists
///    it, flips the gate and every native pane authenticates with it. All of that is production
///    code, and all of it still runs;
///  - what is substituted is the *delivery* of the session, exactly as `-uiTestOpenDeepLink`
///    substitutes the delivery of a `mattermost://` open that XCUITest cannot perform;
///  - the real delivery — reading `WKWebsiteDataStore(forIdentifier:)` — is pinned by unit tests
///    against a real store (`T31WebSessionHarvestTests`,
///    `T31HarvestCookieInstallTests`), which is where a WebKit process can be driven without
///    XCTest's accessibility snapshots around it;
///  - writing a real cookie at launch was measured *not* to work reliably: the write is dropped while
///    the store's Networking process starts (`WebSessionCookieInstaller`), and the process launch then
///    faults under XCTest and kills the app (`docs/t8d-build-note.md` §1). See
///    `MattermostApp.seedWebviewSessionIfRequested`.
///
/// Debug-only: never compiled into Release, and never reachable from page JavaScript.
struct SeededWebSessionCookieReader: SessionCookieReading {
    let token: String

    func authToken(for serverURL: URL) async -> String? {
        token.isEmpty ? nil : token
    }
}
#endif
