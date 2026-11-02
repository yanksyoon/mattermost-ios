// T46 — the webview that renders a permanently-web surface (`docs/dual-render.md` §13).
//
// One model per open fallback sheet. It owns a **second** `WebViewStore` for the server, created
// with the same `WKWebsiteDataStore(forIdentifier: server.id)` the pane uses, so the reader's
// sign-in is shared and there is no second login. It is not the pane's webview and never touches
// it: the pane's webview is released when a pane-owning native card owns the work area
// (`ViewStore.release`), and navigating that one to `/boards` would destroy the conversation the
// reader was reading. This one lives exactly as long as the sheet and is torn down on close.
//
// Session continuity is therefore a property of the *data store*, not of a webview instance —
// which is the same design `docs/dual-render.md` §7 states for the pane ("the store owns the
// instance"), applied one level up: the store owns the cookies, the sheet owns the view.

import Foundation
import Combine
import WebKit

@MainActor
final class WebFallbackModel: ObservableObject {

    /// Where the session the page will see came from. Published because it is the measurable form
    /// of "the fallback shares the server's session": the sheet carries it as an accessibility
    /// value, so a live test can assert *which* case it is instead of inferring it from a screenshot.
    enum SessionSource: String {
        /// The shared `WKWebsiteDataStore` already held the server's `MMAUTHTOKEN` (a webview
        /// sign-in: the SSO hand-off, or an earlier fallback).
        case shared
        /// The store held no cookie; the shell's own token (`SecureVault`) was installed as one.
        case installed
        /// No session at all — a signed-out server. The page will show its own login.
        case none
        /// The entry could not be addressed (`target == nil`); no webview was created.
        case unavailable
    }

    let server: ServerConfig
    let surface: WebFallbackSurface

    /// The absolute URL of exactly this surface, or `nil` when the entry names nothing loadable.
    let target: URL?

    /// The webview owner for this sheet. `nil` when `target` is `nil`: a row that cannot address
    /// a route must not spawn a WebContent process to show an error.
    let store: WebViewStore?

    @Published private(set) var sessionSource: SessionSource = .unavailable
    /// Mirrored so the sheet's toolbar can offer the web page's own Back button without observing
    /// the store in two places.
    @Published private(set) var canGoBack = false

    /// Characters of text the page itself says it has painted (`document.body.innerText`), or `nil`
    /// until it has answered.
    ///
    /// This is the difference between "the navigation committed" and "the surface is on screen".
    /// `didFinish` fires on the SPA's **shell** document, which is a valid, loaded, empty page: the
    /// System Console's own JS bundle routes to `/admin_console/about/license` and paints a second or
    /// so later. A live test that stops at `pageLoadState == .loaded` therefore passes on a white
    /// rectangle — measured while re-running this card, `docs/t46-build-note.md` §7.3. Asking the page
    /// how much text it has is the smallest signal that separates the two, and it is the page's own
    /// answer, not the shell's opinion of it.
    @Published private(set) var paintedCharacters: Int?

    /// The shell's token for the server. Injected so a test can supply a session without a Keychain.
    private let tokenProvider: (ServerConfig) -> String?
    /// The signed-in user's id for the server (`MMUSERID`), same injection rule as the token.
    private let userIDProvider: (ServerConfig) -> String?
    /// Whether this model created its webview — i.e. whether there is anything to tear down.
    private(set) var isStarted = false
    private(set) var isTornDown = false
    /// Whether the web app's landing page was already left (one skip per presentation).
    private(set) var didSkipLandingPage = false

    private var cancellables = Set<AnyCancellable>()
    /// The paint probe's loop, kept so `tearDown()` stops asking a webview that is going away.
    private var paintProbe: Task<Void, Never>?

    init(server: ServerConfig,
         surface: WebFallbackSurface,
         tokenProvider: @escaping (ServerConfig) -> String? = WebFallbackModel.vaultToken,
         userIDProvider: @escaping (ServerConfig) -> String? = WebFallbackModel.vaultUserID) {
        self.server = server
        self.surface = surface
        self.tokenProvider = tokenProvider
        self.userIDProvider = userIDProvider

        let target = surface.url(relativeTo: server.url)
        self.target = target
        let store = target.map { _ in WebViewStore(dataStoreIdentifier: server.id) }
        self.store = store
        if let store {
            store.$canGoBack.assign(to: &$canGoBack)
            // The web app's first-visit landing page is not the surface (see `WebAppLandingPage`).
            // Observed rather than handled at `didFinish` because `Root` pushes it after the first
            // document has finished loading, i.e. as a later URL change.
            store.$url
                .compactMap { $0 }
                .sink { [weak self] url in self?.skipLandingPageIfNeeded(url) }
                .store(in: &cancellables)
            // A finished navigation is when the page can first be asked what it painted. The
            // probe keeps asking for a few seconds, because the SPA paints after its shell loads.
            store.$hasFinishedPageLoad
                .filter { $0 }
                .sink { [weak self] _ in self?.startPaintProbe() }
                .store(in: &cancellables)
            // Signed-out is not an error: the web app draws its own login page, and that is the
            // honest state of a server with no session. The value is published so the UI test can
            // tell it apart from the two signed-in cases.
            sessionSource = .none
        }
    }

    /// The production token source: the same `SecureVault` entry the native transport reads.
    nonisolated static func vaultToken(_ server: ServerConfig) -> String? {
        SecureVault().getSecret(key: .authToken, serverURL: server.url)
    }

    /// The production identity source: the user id the native sign-in stored, which is the
    /// `MMUSERID` the web client's boot reads. No user id means there is no session to hand over.
    nonisolated static func vaultUserID(_ server: ServerConfig) -> String? {
        SecureVault().getSecret(key: .userID, serverURL: server.url)
    }

    // MARK: Opening

    /// Install the session (if the shared store has none) and load exactly this surface.
    ///
    /// Order matters and is the whole of "no second login": the cookie must be in the shared
    /// cookie store **before** the first request, otherwise the web app's boot sequence answers
    /// `401` and paints its login form before the cookie could take effect.
    func start() async {
        guard let store, let target, !isStarted else { return }
        isStarted = true
        // The landing-page flag goes in **before** the first request (T46-R, measured): the landing
        // page signs the session out, so following it afterwards cannot work — the surface's own
        // boot would already be a 401. See `WebAppLandingPage.preloadScript`.
        installLandingPageFlag()
        let source = await installSession()
        Logger.info("WebFallback",
                    "opening \(surface.id) at \(target.absoluteString) (session: "
                    + "\(source.rawValue), server \(server.id))")
        store.load(target)
    }

    /// Mark the web app's first-visit landing page as seen for this store, idempotently.
    ///
    /// One user script per presented sheet, and the sheet is not reused (`WebFallbackSheet` owns a
    /// fresh model), so this cannot accumulate. `atDocumentStart` is what makes it take effect
    /// before the SPA's own code reads the flag — `start()` calls it before the first `load`.
    func installLandingPageFlag() {
        guard let store else { return }
        let controller = store.webView.configuration.userContentController
        let source = WebAppLandingPage.preloadScript
        guard !controller.userScripts.contains(where: { $0.source == source }) else { return }
        controller.addUserScript(WebAppLandingPage.userScript)
    }

    /// Share the server's session with this webview. Idempotent; returns what it found.
    ///
    /// Separated from `start()` so the rule can be tested without a navigation (the unit suite
    /// never opens a connection), and so a caller can prepare a session before deciding to load.
    @discardableResult
    func installSession() async -> SessionSource {
        guard let store else {
            sessionSource = .unavailable
            return .unavailable
        }
        sessionSource = await installSessionCookieIfNeeded(for: store)
        return sessionSource
    }

    /// The decision behind `installSession()`, for one store:
    ///
    /// - `.shared`: the per-server data store already carries a **usable** session — `MMAUTHTOKEN`
    ///   *and* `MMUSERID` *and* `MMCSRF`, the triple a browser login produces. Nothing is written; a
    ///   web session must never be overwritten by a stale native token. (A store that holds only
    ///   the token is *not* shared: the web app cannot use it and signs it out — see below.)
    /// - `.installed`: the session is missing or incomplete, but the shell holds a token for this
    ///   server (the native form's sign-in). The cookies are written into the **same** store the
    ///   pane's webview uses, which is what makes the session shared rather than copied.
    /// - `.none`: signed out. The page shows its own login; T46 does not create a session.
    ///
    /// The completeness check is the measured lesson from T46's first run: `MMAUTHTOKEN` alone makes
    /// the web app boot into `PUT /users/me/patch` + `POST /users/logout` (both 200) and then land on
    /// `/login?redirect_to=…`, because the client's own state-changing requests fail the CSRF check
    /// and a session it cannot use is a session it clears. Installing the triple is what makes "no
    /// second login" true.
    private func installSessionCookieIfNeeded(for store: WebViewStore) async -> SessionSource {
        let cookieStore = store.webView.configuration.websiteDataStore.httpCookieStore
        let existing = await cookieStore.allCookies()
        if hasUsableSession(in: existing) {
            return .shared
        }
        guard let token = tokenProvider(server), let userID = userIDProvider(server) else {
            return .none
        }
        let cookies = WebSessionCookiePolicy.sessionCookies(for: server.url,
                                                            token: token,
                                                            userID: userID)
        guard !cookies.isEmpty else { return .none }
        for cookie in cookies {
            await cookieStore.setCookie(cookie)
        }
        Logger.info("WebFallback",
                    "installed the shell's session cookies for \(server.id) "
                    + "(\(cookies.map(\.name).joined(separator: ", ")))")
        return .installed
    }

    /// Whether the store already holds everything the web app needs to treat itself as signed in.
    ///
    /// `MMCSRF` is required even though the shell could mint a fresh one: if the store has a token
    /// but no CSRF cookie, its session was created by someone else (a webview sign-in that has since
    /// lost the cookie) and rewriting half of it would put the token and the client state out of
    /// step. A partially populated store is repaired by writing all three.
    private func hasUsableSession(in cookies: [HTTPCookie]) -> Bool {
        let names = [SessionCookiePolicy.authCookieName,
                     WebSessionCookiePolicy.userIDCookieName,
                     WebSessionCookiePolicy.csrfCookieName]
        return names.allSatisfy {
            SessionCookiePolicy.value(named: $0, in: cookies, for: server.url) != nil
        }
    }

    /// Leave the web app's first-visit landing page and load the surface it names.
    ///
    /// One skip per presentation: the landing page's own push marks it seen, so the retry sticks.
    /// If a store refuses the flag (blocked `localStorage`), the second landing page is shown to the
    /// reader instead of the sheet navigating in a loop.
    func skipLandingPageIfNeeded(_ url: URL) {
        guard let target = landingPageSkipTarget(for: url) else { return }
        didSkipLandingPage = true
        Logger.info("WebFallback", "left the web app's landing page for \(target.path)")
        store?.load(target)
    }

    /// The decision above, separated so the one-skip rule is testable without a navigation.
    func landingPageSkipTarget(for url: URL) -> URL? {
        guard !didSkipLandingPage else { return nil }
        return WebAppLandingPage.surfaceTarget(in: url, on: server.url)
    }

    // MARK: What the page has painted

    /// The JavaScript the shell asks its own page. Deliberately trivial and read-only: a character
    /// count of the rendered body. It reads no cookie, calls no bridge and hands nothing back into
    /// the page — the security boundary (`docs/dual-render.md` §9) is untouched.
    static let paintProbeScript = "document.body ? document.body.innerText.trim().length : 0"

    /// How many attempts (0.5 s apart) the probe makes before giving up. Ten seconds is longer than
    /// any surface on the fixture needed (the System Console paints at ~1 s; Playbooks' shell at
    /// ~0.5 s) and short enough that a dead page is reported as a dead page, not as a slow one.
    static let paintProbeAttempts = 20

    /// What counts as "painted": more than a shell document's stray label. The System Console's
    /// first document is the web app's HTML shell; its own bundle then routes to
    /// `/admin_console/about/license` and paints the console UI, which is what this threshold
    /// demands before the probe stops asking.
    static let paintedSurfaceThreshold = 120

    /// Ask the page for its painted text until it looks painted, then stop.
    ///
    /// Idempotent per presentation: a navigation that finishes twice does not stack loops. The value
    /// published is the **maximum** seen — a SPA that paints, then swaps documents, must not make a
    /// later reading look emptier than the one the test already asserted.
    func startPaintProbe() {
        guard let store, paintProbe == nil else { return }
        paintProbe = Task { [weak self] in
            for _ in 0..<Self.paintProbeAttempts {
                if Task.isCancelled { return }
                if let count = await Self.paintedCharacters(in: store.webView) {
                    guard let self, !Task.isCancelled else { return }
                    self.paintedCharacters = max(self.paintedCharacters ?? 0, count)
                    if count >= Self.paintedSurfaceThreshold { return }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    /// One reading of `paintProbeScript`, or `nil` when the page could not be asked (a webview that
    /// has not created its content process yet, a page that navigated away underneath the call).
    nonisolated static func paintedCharacters(in webView: WKWebView) async -> Int? {
        let value = try? await webView.evaluateJavaScript(paintProbeScript)
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    // MARK: Closing

    /// Release the webview. Called from the sheet's `onDisappear` (and by the leak test, which is
    /// why it is a method rather than something only SwiftUI can do).
    ///
    /// Exactly the three things `ViewStore.release` does for a released pane, for the same reasons:
    /// stop the page so it is not still fetching, drop the delegates so no late WebKit callback is
    /// answered by a dead object, and drop the store's keep-alive on the coordinator so the
    /// store ↔ coordinator pair cannot outlive the sheet. It deliberately does **not** touch
    /// `WKWebsiteDataStore`: closing a plugin screen must not log the server out.
    func tearDown() {
        guard let store, !isTornDown else { return }
        isTornDown = true
        paintProbe?.cancel()
        paintProbe = nil
        store.stopLoading()
        store.webView.navigationDelegate = nil
        store.webView.uiDelegate = nil
        store.installCoordinator(nil)
        Logger.info("WebFallback", "closed \(surface.id) for server \(server.id) (data store kept)")
    }

    /// The accessibility value the live suite reads: page lifecycle, where the session came from,
    /// the committed URL, and — once the page has answered — how much text it has painted.
    /// The last field is what makes "renders real server data" an assertion instead of a picture:
    /// `loaded` is the navigation's verdict, `chars=0` is a white rectangle, and a painted surface
    /// is hundreds of characters of the server's own content.
    var observableState: String {
        let state = store?.pageLoadState.rawValue ?? "unavailable"
        let url = store?.url?.absoluteString ?? "-"
        return Self.observableState(pageLoadState: state,
                                    sessionSource: sessionSource.rawValue,
                                    url: url,
                                    paintedCharacters: paintedCharacters,
                                    requested: target?.absoluteString)
    }

    /// The format above, separated so it is testable without a webview.
    ///
    /// `requested` is the route the shell **asked** for, which is not always the route the page ends
    /// on: this fixture answers `/plugins/<id>` with `301 Location: /` for every installed plugin
    /// (measured, `docs/t46-build-note.md` §7.4), because a plugin's webapp bundle is a client-side
    /// route, not a server page. Keeping both means "the row opened exactly this surface" and "the
    /// server's answer is rendered" are separate, checkable facts rather than one guess.
    nonisolated static func observableState(pageLoadState: String,
                                            sessionSource: String,
                                            url: String,
                                            paintedCharacters: Int?,
                                            requested: String? = nil) -> String {
        let painted = paintedCharacters.map { "|chars=\($0)" } ?? ""
        let asked = requested.map { "|requested=\($0)" } ?? ""
        return "\(pageLoadState)|\(sessionSource)|\(url)\(painted)\(asked)"
    }
}
