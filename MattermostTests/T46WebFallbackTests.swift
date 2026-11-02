import XCTest
import WebKit
@testable import Mattermost

/// T46 — the permanent-web escape hatch (`docs/dual-render.md` §13).
///
/// What these tests are allowed to claim, and what they are not:
///  - the **route** rules (`/boards`, `/playbooks`, `/admin_console`, `/plugins/<id>`) are pure and
///    pinned here;
///  - **session sharing** is measured against real `WKWebsiteDataStore` objects: a cookie written
///    through the pane's store is read back through the fallback's webview, and a native token is
///    installed only when the store has no cookie. No network is touched;
///  - **teardown** is measured by weak references: twenty created-and-closed fallbacks must leave
///    twenty deallocated `WKWebView`s. That is the object-level half of the memory claim; the
///    process-level half is the sampled WebContent count in `docs/t46-build-note.md`.
///
/// A live run is what proves the page itself renders (the UI suite, `T46WebFallbackUITests`): a
/// fixture would only prove this file's own strings.
@MainActor
final class T46WebFallbackTests: XCTestCase {

    // MARK: - The route catalogue

    func testTheFixedRowsAddressExactlyTheWebAppsOwnRoutes() {
        XCTAssertEqual(WebFallbackSurface(kind: .boards).path, "/boards")
        XCTAssertEqual(WebFallbackSurface(kind: .playbooks).path, "/playbooks")
        XCTAssertEqual(WebFallbackSurface(kind: .systemConsole).path, "/admin_console")
        XCTAssertEqual(WebFallbackSurface.fixedMenu.map(\.id), ["boards", "playbooks", "systemConsole"])
    }

    func testAPluginScreenIsOneSegmentUnderThePluginRoot() {
        let surface = WebFallbackSurface(kind: .plugin, pluginID: "com.mattermost.calls")
        XCTAssertEqual(surface.path, "/plugins/com.mattermost.calls")
        XCTAssertEqual(surface.id, "plugin.com.mattermost.calls")
        XCTAssertEqual(surface.title, "Plugin: com.mattermost.calls")
        // The id is only meaningful for `.plugin`; every other kind ignores it.
        XCTAssertEqual(WebFallbackSurface(kind: .boards, pluginID: "x").pluginID, nil)
    }

    func testAPluginIDThatCouldEscapeThePluginRootHasNoRoute() {
        let bad = ["", "..", ".", "../admin_console", "a/b", "/boards", "a?x=1", "a#b",
                   "a b", "com..mattermost", "-leading", ".leading", "a\nb",
                   String(repeating: "a", count: 191)]
        for id in bad {
            let surface = WebFallbackSurface(kind: .plugin, pluginID: id)
            XCTAssertNil(surface.path, "\(id.debugDescription) must not address a route")
        }
        // Empty and missing are the same state, and neither is a route.
        XCTAssertNil(WebFallbackSurface(kind: .plugin).path)
        XCTAssertTrue(WebFallbackSurface.isValidPluginID("focalboard"))
        XCTAssertTrue(WebFallbackSurface.isValidPluginID("com.mattermost.calls"))
    }

    func testTheRouteKeepsASubPathInstall() throws {
        let root = try XCTUnwrap(URL(string: "https://mm.example.com"))
        let subPath = try XCTUnwrap(URL(string: "https://mm.example.com/company/mattermost"))
        let trailing = try XCTUnwrap(URL(string: "https://mm.example.com/company/mattermost/"))
        let boards = WebFallbackSurface(kind: .boards)

        XCTAssertEqual(boards.url(relativeTo: root)?.absoluteString, "https://mm.example.com/boards")
        XCTAssertEqual(boards.url(relativeTo: subPath)?.absoluteString,
                       "https://mm.example.com/company/mattermost/boards")
        XCTAssertEqual(boards.url(relativeTo: trailing)?.absoluteString,
                       "https://mm.example.com/company/mattermost/boards")
        // A server with an explicit port (a dev/fixture server) keeps it.
        let fixture = try XCTUnwrap(URL(string: "http://127.0.0.1:8065"))
        XCTAssertEqual(WebFallbackSurface(kind: .systemConsole).url(relativeTo: fixture)?.absoluteString,
                       "http://127.0.0.1:8065/admin_console")
    }

    func testAnUnaddressableSurfaceHasNoURL() {
        XCTAssertNil(WebFallbackSurface(kind: .plugin).url(relativeTo: URL(string: "https://mm.example.com")!))
        // A malformed server URL cannot produce a route either.
        let strange = URL(fileURLWithPath: "/tmp/local")
        XCTAssertNil(WebFallbackSurface(kind: .boards).url(relativeTo: strange))
    }

    // MARK: - The session cookies

    func testTheSessionCookieIsScopedToTheServerOrigin() throws {
        let http = try XCTUnwrap(URL(string: "http://127.0.0.1:8065"))
        let cookie = try XCTUnwrap(WebSessionCookiePolicy.authCookie(for: http, token: "abc"))
        XCTAssertEqual(cookie.name, "MMAUTHTOKEN")
        XCTAssertEqual(cookie.value, "abc")
        XCTAssertEqual(cookie.domain, "127.0.0.1")
        XCTAssertEqual(cookie.path, "/")
        XCTAssertFalse(cookie.isSecure, "an http fixture must still receive its session")

        let https = try XCTUnwrap(URL(string: "https://mm.example.com/company/mattermost"))
        let secure = try XCTUnwrap(WebSessionCookiePolicy.authCookie(for: https, token: "abc"))
        XCTAssertEqual(secure.domain, "mm.example.com")
        XCTAssertTrue(secure.isSecure)

        XCTAssertNil(WebSessionCookiePolicy.authCookie(for: https, token: ""),
                     "an empty token is not a session")
        XCTAssertNil(WebSessionCookiePolicy.authCookie(for: URL(fileURLWithPath: "/tmp/x"), token: "abc"))
    }

    /// The handoff is the triple the server itself sets on a browser login — measured on 9.11.19:
    ///
    ///     Set-Cookie: MMAUTHTOKEN=…; Path=/; Max-Age=2592000; HttpOnly
    ///     Set-Cookie: MMUSERID=…;   Path=/; Max-Age=2592000
    ///     Set-Cookie: MMCSRF=…;     Path=/; Max-Age=2592000
    ///
    /// Installing `MMAUTHTOKEN` alone makes the web app boot, fail its own CSRF-signed requests, and
    /// sign the session out — the exact flake this suite exists to prevent.
    func testTheSessionHandoffIsTheServersOwnThreeCookies() throws {
        let url = try XCTUnwrap(URL(string: "https://mm.example.com/company/mattermost"))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cookies = WebSessionCookiePolicy.sessionCookies(for: url,
                                                            token: "session-token",
                                                            userID: "user-id",
                                                            csrf: "csrf-token",
                                                            now: now)
        XCTAssertEqual(cookies.map(\.name),
                       ["MMAUTHTOKEN", "MMUSERID", "MMCSRF"],
                       "the whole triple, in the order the server sets it")

        let byName = Dictionary(uniqueKeysWithValues: cookies.map { ($0.name, $0) })
        XCTAssertEqual(byName["MMAUTHTOKEN"]?.value, "session-token")
        XCTAssertEqual(byName["MMUSERID"]?.value, "user-id")
        XCTAssertEqual(byName["MMCSRF"]?.value, "csrf-token")

        for cookie in cookies {
            XCTAssertEqual(cookie.domain, "mm.example.com", "\(cookie.name) follows the server host")
            XCTAssertEqual(cookie.path, "/", "\(cookie.name) covers a sub-path install")
            XCTAssertTrue(cookie.isSecure)
            let expires = try XCTUnwrap(cookie.expiresDate)
            XCTAssertEqual(expires.timeIntervalSince(now),
                           WebSessionCookiePolicy.lifetime,
                           accuracy: 1,
                           "\(cookie.name) outlives a sheet dismissal, as the server's does")
        }

        // The token stays out of reach of page script; the two the web client reads itself do not.
        let scriptVisible = cookies.filter { $0.isHTTPOnly }.map(\.name)
        XCTAssertEqual(scriptVisible, ["MMAUTHTOKEN"],
                       "only the session token is HttpOnly; MMCSRF is read by the page by design")
    }

    func testTheMintedCSRFTokenLooksLikeTheServers() {
        let token = WebSessionCookiePolicy.newCSRFToken()
        XCTAssertEqual(token.count, 26, "Mattermost ids are 26 characters")
        XCTAssertTrue(token.allSatisfy { $0.isLowercase || $0.isNumber },
                      "lowercase alphanumerics only: \(token)")
        XCTAssertNotEqual(token, WebSessionCookiePolicy.newCSRFToken(),
                          "each handoff gets its own double-submit value")
    }

    func testASessionCookiesExistOnlyForAnHttpOrigin() {
        XCTAssertTrue(WebSessionCookiePolicy.sessionCookies(for: URL(fileURLWithPath: "/tmp/x"),
                                                            token: "t", userID: "u").isEmpty)
        XCTAssertTrue(WebSessionCookiePolicy.sessionCookies(for: URL(string: "https://a.example")!,
                                                            token: "", userID: "u").isEmpty,
                      "no token is no session")
    }

    // MARK: - Sharing the server's session (no second login)

    func testAFallbackSeesTheCookieTheWebViewAlreadyHas() async throws {
        let id = UUID()
        let server = Self.server(id: id)
        // What a webview sign-in leaves behind: the server's own three cookies in the server's own
        // data store. The app keeps that store alive for the whole run (`ViewStore` owns one
        // `WebViewStore` per server), and the fallback asks `WKWebsiteDataStore(forIdentifier:)` for
        // the same identifier — so a cookie written through the pane's store is the fallback's
        // cookie, not a copy of it. Measured fact: a synthetic write is only visible while a handle
        // is alive, so the pane's store is held here exactly as `ViewStore` holds it in the app.
        let paneStore = WebViewStore(dataStoreIdentifier: id)
        let paneCookies = paneStore.webView.configuration.websiteDataStore.httpCookieStore
        for cookie in WebSessionCookiePolicy.sessionCookies(for: server.url,
                                                            token: "web-session",
                                                            userID: "web-user") {
            await paneCookies.setCookie(cookie)
        }
        let written = await paneCookies.allCookies()
        XCTAssertEqual(SessionCookiePolicy.value(named: "MMAUTHTOKEN", in: written, for: server.url),
                       "web-session",
                       "precondition: the server's store must already hold the session")

        let model = WebFallbackModel(server: server, surface: .init(kind: .boards),
                                     tokenProvider: { _ in nil })
        let fallbackStore = try XCTUnwrap(model.store)
        let seen = await fallbackStore.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        XCTAssertEqual(SessionCookiePolicy.value(named: "MMAUTHTOKEN", in: seen, for: server.url),
                       "web-session",
                       "the fallback must read the server's own session, not a copy of it")
        let secondSource = await model.installSession()
        XCTAssertEqual(secondSource, .shared,
                       "a complete session is the web's, and is not rewritten")
        model.tearDown()
        withExtendedLifetime(paneStore) {}
    }

    func testANativeSessionIsInstalledWhenTheWebViewHasNoCookie() async throws {
        let server = Self.server(id: UUID())
        let model = WebFallbackModel(server: server, surface: .init(kind: .systemConsole),
                                     tokenProvider: { _ in "native-token" },
                                     userIDProvider: { _ in "native-user" })
        let source = await model.installSession()
        XCTAssertEqual(source, .installed)
        XCTAssertEqual(model.sessionSource, .installed)

        let store = try XCTUnwrap(model.store)
        let cookies = await store.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        XCTAssertEqual(SessionCookiePolicy.value(named: "MMAUTHTOKEN", in: cookies, for: server.url),
                       "native-token",
                       "the shell's own token must reach the page, or the fallback is a second login")
        XCTAssertEqual(SessionCookiePolicy.value(named: "MMUSERID", in: cookies, for: server.url),
                       "native-user",
                       "the web client's boot reads the identity cookie")
        let csrf = SessionCookiePolicy.value(named: "MMCSRF", in: cookies, for: server.url)
        XCTAssertEqual(csrf?.count, 26,
                       "without the double-submit cookie the boot signs the session out")
        model.tearDown()
    }

    func testATokenWithNoUserIDIsNotHandedOver() async throws {
        let server = Self.server(id: UUID())
        let model = WebFallbackModel(server: server, surface: .init(kind: .boards),
                                     tokenProvider: { _ in "native-token" },
                                     userIDProvider: { _ in nil })
        let source = await model.installSession()
        XCTAssertEqual(source, .none,
                       "half a handoff would boot the web app into a logout")
        let store = try XCTUnwrap(model.store)
        let cookies = await store.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        XCTAssertTrue(cookies.isEmpty, "nothing is written, so nothing is half-signed-in")
        model.tearDown()
    }

    /// A store that holds the token but not the rest is not a usable web session — it is the exact
    /// state the first T46 build produced, and it lands on `/login?redirect_to=…`.
    func testATokenOnlyStoreIsRepairedIntoAUsableSession() async throws {
        let id = UUID()
        let server = Self.server(id: id)
        let paneStore = WebViewStore(dataStoreIdentifier: id)
        let paneCookies = paneStore.webView.configuration.websiteDataStore.httpCookieStore
        await paneCookies.setCookie(try XCTUnwrap(
            WebSessionCookiePolicy.authCookie(for: server.url, token: "token-only")))

        let model = WebFallbackModel(server: server, surface: .init(kind: .systemConsole),
                                     tokenProvider: { _ in "native-token" },
                                     userIDProvider: { _ in "native-user" })
        let repaired = await model.installSession()
        XCTAssertEqual(repaired, .installed)

        let cookies = await paneCookies.allCookies()
        XCTAssertEqual(SessionCookiePolicy.value(named: "MMUSERID", in: cookies, for: server.url),
                       "native-user")
        XCTAssertNotNil(SessionCookiePolicy.value(named: "MMCSRF", in: cookies, for: server.url))
        model.tearDown()
        withExtendedLifetime(paneStore) {}
    }

    func testAnExistingWebSessionIsNeverOverwrittenByTheNativeToken() async throws {
        let id = UUID()
        let server = Self.server(id: id)
        // The pane's store, held exactly as `ViewStore` holds it (see the sharing test above).
        let paneStore = WebViewStore(dataStoreIdentifier: id)
        for cookie in WebSessionCookiePolicy.sessionCookies(for: server.url,
                                                            token: "web-session",
                                                            userID: "web-user") {
            await paneStore.webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        }

        let model = WebFallbackModel(server: server, surface: .init(kind: .boards),
                                     tokenProvider: { _ in "stale-native-token" },
                                     userIDProvider: { _ in "stale-native-user" })
        let source = await model.installSession()
        XCTAssertEqual(source, .shared)

        let store = try XCTUnwrap(model.store)
        let cookies = await store.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        XCTAssertEqual(SessionCookiePolicy.value(named: "MMAUTHTOKEN", in: cookies, for: server.url),
                       "web-session",
                       "a web sign-in outranks the vault; overwriting it would be a silent re-login")
        XCTAssertEqual(SessionCookiePolicy.value(named: "MMUSERID", in: cookies, for: server.url),
                       "web-user")
        model.tearDown()
        withExtendedLifetime(paneStore) {}
    }

    func testASignedOutServerInstallsNothing() async throws {
        let server = Self.server(id: UUID())
        let model = WebFallbackModel(server: server, surface: .init(kind: .boards),
                                     tokenProvider: { _ in nil },
                                     userIDProvider: { _ in nil })
        let source = await model.installSession()
        XCTAssertEqual(source, .none)
        let store = try XCTUnwrap(model.store)
        let cookies = await store.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        XCTAssertNil(SessionCookiePolicy.value(named: "MMAUTHTOKEN", in: cookies, for: server.url))
        model.tearDown()
    }

    func testClosingTheFallbackDoesNotLogTheServerOut() async throws {
        let id = UUID()
        let server = Self.server(id: id)
        // The app's per-server store, held for the run — the same object `ViewStore` keeps.
        let paneStore = WebViewStore(dataStoreIdentifier: id)
        var model: WebFallbackModel? = WebFallbackModel(
            server: server,
            surface: .init(kind: .boards),
            tokenProvider: { _ in "native-token" },
            userIDProvider: { _ in "native-user" })
        let source = await model?.installSession()
        XCTAssertEqual(source, .installed)
        model?.tearDown()
        model?.tearDown()   // idempotent: a second disappear must not do anything twice
        model = nil

        let cookies = await paneStore.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        XCTAssertEqual(SessionCookiePolicy.value(named: "MMAUTHTOKEN", in: cookies, for: server.url),
                       "native-token",
                       "closing a plugin screen must not clear the session it shared")
        XCTAssertNotNil(SessionCookiePolicy.value(named: "MMCSRF", in: cookies, for: server.url),
                        "the rest of the handoff survives teardown too")
    }

    // MARK: - Teardown (the memory claim's object-level half)

    /// A weak handle, so the assertion is about the object's lifetime rather than its state.
    private final class WeakWebView {
        weak var value: WKWebView?
        init(_ value: WKWebView?) { self.value = value }
    }

    private final class WeakModel {
        weak var value: WebFallbackModel?
        init(_ value: WebFallbackModel?) { self.value = value }
    }

    func testTwentyFallbacksLeaveNoWebViewAlive() throws {
        var handles: [WeakWebView] = []
        var modelHandles: [WeakModel] = []
        for cycle in 0..<20 {
            // Each presentation gets its own autorelease pool, exactly as a run-loop turn in the
            // app does. Without one, WebKit's autoreleased teardown objects would survive until
            // this test method returned and the probe would measure the **test's** pool rather than
            // the product's lifetime (measured: 20 of 20 "alive" without it, 0 of 20 with it).
            try autoreleasepool {
                let model = WebFallbackModel(server: Self.server(id: UUID()),
                                             surface: .init(kind: .boards),
                                             tokenProvider: { _ in nil })
                let view = try XCTUnwrap(model.store?.webView,
                                         "cycle \(cycle) created no webview")
                handles.append(WeakWebView(view))
                modelHandles.append(WeakModel(model))
                // The same call the sheet's `onDisappear` makes.
                model.tearDown()
            }
            // WebKit defers part of its teardown to the run loop; a short spin lets it happen.
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let aliveViews = handles.enumerated().filter { $0.element.value != nil }.map(\.offset)
        XCTAssertTrue(aliveViews.isEmpty,
                      "\(aliveViews.count) of 20 fallback webviews are still alive after teardown "
                      + "(cycles \(aliveViews); a leaked webview defeats the memory goal)")

        let aliveModels = modelHandles.enumerated().filter { $0.element.value != nil }.map(\.offset)
        XCTAssertTrue(aliveModels.isEmpty,
                      "\(aliveModels.count) of 20 fallback models are still alive (cycles "
                      + "\(aliveModels)); the sheet's state must not outlive its dismissal")
    }

    func testTeardownDropsTheDelegatesAndTheKeepAlive() throws {
        let model = WebFallbackModel(server: Self.server(id: UUID()), surface: .init(kind: .playbooks),
                                     tokenProvider: { _ in nil })
        let store = try XCTUnwrap(model.store)
        // Stand in for `WebViewContainer`'s coordinator: it holds the store, and the store holds
        // it back while the webview is mounted. That pair is why `dismantleUIView` (and this)
        // exists — `t_065c8753`.
        final class CoordinatorStub: NSObject, WKNavigationDelegate {
            let strongStore: WebViewStore
            init(store: WebViewStore) { self.strongStore = store }
        }
        let coordinator = CoordinatorStub(store: store)
        store.installCoordinator(coordinator)
        store.webView.navigationDelegate = coordinator

        model.tearDown()

        XCTAssertNil(store.webView.navigationDelegate, "a torn-down webview must answer nobody")
        XCTAssertNil(store.webView.uiDelegate)
        XCTAssertNil(store.installedCoordinator, "the store must not keep the coordinator alive")
        XCTAssertTrue(model.isTornDown)
    }

    func testAnUnaddressableSurfaceCreatesNoWebViewAtAll() {
        let model = WebFallbackModel(server: Self.server(id: UUID()),
                                     surface: WebFallbackSurface(kind: .plugin),
                                     tokenProvider: { _ in "token" })
        XCTAssertNil(model.target)
        XCTAssertNil(model.store, "a row with no route must not spawn a WebContent process")
        XCTAssertEqual(model.sessionSource, .unavailable)
        XCTAssertEqual(model.observableState.hasPrefix("unavailable|"), true)
    }

    func testTheObservableStateCarriesLifecycleSessionAndURL() throws {
        let server = Self.server(id: UUID())
        let model = WebFallbackModel(server: server, surface: .init(kind: .boards),
                                     tokenProvider: { _ in nil })
        // Nothing has loaded: the value still names the route the shell asked for, so a test can tell
        // an unaddressed surface from a pending one. There is no committed URL yet, hence `-`.
        let target = try XCTUnwrap(model.target).absoluteString
        XCTAssertEqual(model.observableState, "idle|none|-|requested=\(target)")
        model.tearDown()
    }

    // MARK: - The paint signal ("renders real server data", not "navigated")

    /// `didFinish` is the navigation's verdict; this is the page's. The value is parsed by the live
    /// suite, so its shape is pinned here rather than only observed in a run.
    func testTheObservableStateCarriesHowMuchThePagePainted() {
        XCTAssertEqual(WebFallbackModel.observableState(pageLoadState: "loaded",
                                                        sessionSource: "installed",
                                                        url: "http://127.0.0.1:8065/admin_console",
                                                        paintedCharacters: 1234),
                       "loaded|installed|http://127.0.0.1:8065/admin_console|chars=1234")
        XCTAssertEqual(WebFallbackModel.observableState(pageLoadState: "loaded",
                                                        sessionSource: "installed",
                                                        url: "http://127.0.0.1:8065/admin_console",
                                                        paintedCharacters: nil),
                       "loaded|installed|http://127.0.0.1:8065/admin_console",
                       "a page that has not answered must not report a count")
        XCTAssertEqual(WebFallbackModel.observableState(pageLoadState: "loaded",
                                                        sessionSource: "installed",
                                                        url: "http://127.0.0.1:8065/admin_console",
                                                        paintedCharacters: 0),
                       "loaded|installed|http://127.0.0.1:8065/admin_console|chars=0",
                       "a white rectangle is a reading, and the test must be able to see it")
        XCTAssertEqual(WebFallbackModel.observableState(pageLoadState: "loaded",
                                                        sessionSource: "installed",
                                                        url: "http://127.0.0.1:8065/",
                                                        paintedCharacters: 251,
                                                        requested: "http://127.0.0.1:8065/plugins/com.mattermost.calls"),
                       "loaded|installed|http://127.0.0.1:8065/|chars=251"
                       + "|requested=http://127.0.0.1:8065/plugins/com.mattermost.calls",
                       "the requested route and the committed page are separate facts")
    }

    /// The probe runs against the server's page, so it must be a read of that page — no cookie, no
    /// storage, no bridge call. This is the security-boundary half of the paint signal
    /// (`docs/dual-render.md` §9): a script injected at `atDocumentStart` could do anything; this one
    /// is evaluated on demand and only counts characters.
    func testThePaintProbeReadsNothingButThePageText() {
        let script = WebFallbackModel.paintProbeScript
        XCTAssertTrue(script.contains("document.body"))
        XCTAssertTrue(script.contains("innerText"))
        for forbidden in ["cookie", "localStorage", "sessionStorage", "webkit.messageHandlers",
                          "fetch(", "XMLHttpRequest", "eval("] {
            XCTAssertFalse(script.contains(forbidden),
                           "the paint probe must not touch \(forbidden)")
        }
    }

    // MARK: - The web app's first-visit landing page

    /// `Root` pushes `/landing#<path>` on the first load of a fresh store. Following it back is
    /// what makes "exactly that surface" true; the fragment is the surface the reader asked for.
    func testTheLandingPageNamesTheSurfaceItReplaced() throws {
        let root = try XCTUnwrap(URL(string: "http://127.0.0.1:8065"))
        let cases: [(String, String)] = [
            ("http://127.0.0.1:8065/landing#/admin_console",
             "http://127.0.0.1:8065/admin_console"),
            ("http://127.0.0.1:8065/landing#/playbooks?page=1",
             "http://127.0.0.1:8065/playbooks?page=1"),
            ("http://127.0.0.1:8065/landing#/plugins/com.mattermost.calls",
             "http://127.0.0.1:8065/plugins/com.mattermost.calls"),
        ]
        for (raw, expected) in cases {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertEqual(WebAppLandingPage.surfaceTarget(in: url, on: root)?.absoluteString, expected,
                           "\(raw) must name \(expected)")
        }

        // A sub-path install: the landing page is under the base path and the fragment carries the
        // base path too (the web app's fragment is its router location). Both are honoured.
        let subPath = try XCTUnwrap(URL(string: "https://mm.example.com/company/mattermost"))
        let subPathLanding = try XCTUnwrap(
            URL(string: "https://mm.example.com/company/mattermost/landing#/company/mattermost/boards"))
        XCTAssertEqual(WebAppLandingPage.surfaceTarget(in: subPathLanding, on: subPath)?.absoluteString,
                       "https://mm.example.com/company/mattermost/boards")
        // `/landing` at the host root is not this install's landing page.
        XCTAssertNil(WebAppLandingPage.surfaceTarget(
            in: try XCTUnwrap(URL(string: "https://mm.example.com/landing#/board")), on: subPath))
        // And a fragment that names something outside the install is not followed.
        XCTAssertNil(WebAppLandingPage.surfaceTarget(
            in: try XCTUnwrap(URL(string: "https://mm.example.com/company/mattermost/landing#/admin_console")),
            on: subPath))
    }

    /// Everything that is not the landing page, or not on the **configured server's** origin, is
    /// left alone. A shell that followed `//host` or an absolute URL out of a fragment would be an
    /// open redirect; a shell that followed a landing page on another host would let a redirect
    /// choose the next route.
    func testAnythingThatIsNotASameServerSurfaceIsNotFollowed() throws {
        let server = try XCTUnwrap(URL(string: "http://127.0.0.1:8065"))
        let untouched = ["http://127.0.0.1:8065/admin_console",
                         "http://127.0.0.1:8065/playbooks",
                         "http://127.0.0.1:8065/landing",
                         "http://127.0.0.1:8065/landing#",
                         "http://127.0.0.1:8065/landing#not-a-path"]
        for raw in untouched {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertNil(WebAppLandingPage.surfaceTarget(in: url, on: server),
                         "\(raw) must not be followed")
        }
        for fragment in ["//evil.example/x", "https://evil.example/x", "javascript:alert(1)"] {
            let url = try XCTUnwrap(URL(string: "http://127.0.0.1:8065/landing#" + fragment))
            XCTAssertNil(WebAppLandingPage.surfaceTarget(in: url, on: server),
                         "fragment \(fragment) must not be followed")
        }
        // The landing page of a *different* origin is not this server's: a server redirect must not
        // be able to name the route this shell loads next. (This case failed against the first
        // implementation, which compared the fragment to the landing page's own origin.)
        for raw in ["https://evil.example/landing#/admin_console",
                    "http://127.0.0.1:8066/landing#/admin_console",
                    "https://127.0.0.1:8065/landing#/admin_console"] {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertNil(WebAppLandingPage.surfaceTarget(in: url, on: server),
                         "\(raw) is another origin and must not be followed")
        }
    }

    /// One skip per presentation: a store that refuses the seen-flag (blocked localStorage) would
    /// otherwise bounce the sheet between the landing page and the surface forever.
    func testTheLandingPageIsLeftAtMostOncePerPresentation() throws {
        let server = Self.server(id: UUID())
        // An unaddressable entry has no store, so this exercises the rule without a navigation.
        let model = WebFallbackModel(server: server, surface: WebFallbackSurface(kind: .plugin),
                                     tokenProvider: { _ in nil })
        XCTAssertNil(model.store)
        let landing = try XCTUnwrap(URL(string: "http://127.0.0.1:8065/landing#/admin_console"))
        XCTAssertEqual(model.landingPageSkipTarget(for: landing)?.path, "/admin_console")
        model.skipLandingPageIfNeeded(landing)
        XCTAssertTrue(model.didSkipLandingPage)
        XCTAssertNil(model.landingPageSkipTarget(for: landing), "the second landing page is shown")
        let other = try XCTUnwrap(URL(string: "http://127.0.0.1:8065/landing#/playbooks"))
        XCTAssertNil(model.landingPageSkipTarget(for: other), "one skip covers every surface")
    }

    // MARK: - Helpers

    private static func server(id: UUID) -> ServerConfig {
        ServerConfig(id: id,
                     name: "Local",
                     url: URL(string: "http://127.0.0.1:8065")!,
                     order: 0,
                     lastActiveAt: .distantPast,
                     hasSession: true)
    }
}
