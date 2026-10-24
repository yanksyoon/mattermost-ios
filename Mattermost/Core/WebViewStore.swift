import Foundation
import WebKit
import Combine

/// Observable wrapper around a `WKWebView`, mirroring the design's Phase-0 deliverable and
/// the desktop `WebContentsView` lifecycle. Parity row: `BaseWindow`/`MattermostWebContentsView`
/// -> `WebViewContainer` + `WebViewStore`. Status: native, P0.2/P1.2.
///
/// Owns the `WKWebView` (so SwiftUI's view identity doesn't tear it down) and publishes the
/// navigation/load state it can observe without polling. This is an intentionally thin,
/// single-purpose store: heavy shell behaviour (cert store, downloads, bridge) plugs in via
/// its `configuration`, `navigationDelegate`, `uiDelegate` and injected scripts — none of
/// which belong inside this store.
@MainActor
final class WebViewStore: ObservableObject {

    // MARK: Published state

    /// Loading progress 0...1, surfaced for a native `ProgressView`.
    @Published var progress: Double = 0
    /// True while a main-frame navigation is in flight.
    @Published var isLoading: Bool = false
    /// Latest committed page title.
    @Published var title: String?
    /// Latest committed page URL.
    @Published var url: URL?
    /// First error thrown by the page / navigation, cleared on the next successful load.
    @Published var pageError: Error?
    /// History availability, mirrored from the webview so the toolbar can disable Back.
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false

    /// A server-trust decision waiting on the user (self-signed / unknown certificate).
    /// Published by the `WebViewContainer` Coordinator when the webview's `didReceive`
    /// server-trust challenge meets a certificate with no recorded trust decision; ContentView
    /// presents `CertPromptSheet` off this value. `nil` == no pending prompt.
    @Published var pendingCertificatePrompt: CertificatePrompt?

    /// True once the current page's **main-frame navigation finished** (`didFinish`); reset when a
    /// navigation starts.
    ///
    /// It distinguishes "loaded" from "interrupted" (T26-R R6): dismantling the web branch calls
    /// `stopLoading()`, which leaves a committed page (`url != nil`) whose navigation never
    /// finished. `loadIfNeeded(_:)` uses this to resume such a page instead of treating the
    /// committed URL as "nothing to do".
    @Published private(set) var hasFinishedPageLoad: Bool = false

    /// Set synchronously by `stopForDismantle()` when the web branch goes away with an unfinished
    /// page, and consumed by the next `loadIfNeeded(_:)`. Not published: it is a fact about the
    /// webview's lifecycle, not something a view renders. Internal (not private) so the unit suite
    /// can pin that the dismantle records it and the resume consumes it.
    private(set) var interruptedByDismantle: Bool = false

    /// Closure the Coordinator installs to record the user's decision into the trust bag
    /// (`CertTrust.add`) and re-drive navigation. ContentView triggers it via
    /// `resolveCertificatePrompt(trust:dontTrustAgain:)`.
    var certificateDecisionHandler: ((CertificatePrompt, Bool, Bool) -> Void)?

    // MARK: The webview

    /// User agent presented to the server.
    ///
    /// It must be a **desktop** UA: many Mattermost servers answer an iOS/Mobile-Safari UA with
    /// the "view in app / view in browser" landing page instead of the web app.
    ///
    /// It must *not* claim to be Mattermost Desktop. The web app switches to its Electron code
    /// path when the UA carries `Mattermost/… Electron/…`, and that path expects the full
    /// `window.desktop` API surface. The shell implements a subset, so the app mounted the global
    /// header and the team sidebar and then stopped: 230 DOM nodes, an empty `main-wrapper`, a
    /// perma-"Loading" channel view, and no posts request ever issued. A plain Safari UA renders
    /// the whole workspace (measured: ~4,900 DOM nodes, channel header, post list).
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    let webView: WKWebView
    let configuration: WKWebViewConfiguration

    /// The isolation key for this webview's data store, when it owns a per-server store.
    /// `nil` means the app-wide default store (single-server / test usage).
    let dataStoreIdentifier: UUID?

    /// The JS↔native bridge for this webview (Phase-1 `Bridge`). Its delegate (`JsBridge`) is
    /// installed by `WebViewContainer`'s Coordinator, and the injected preload + message handler
    /// are registered on this webview's content controller at creation.
    let bridge: Bridge

    /// Optional sink for the WKWebView progress observation.
    private var cancellables = Set<AnyCancellable>()

    /// - Parameter dataStoreIdentifier: when provided, the webview gets its **own** persistent
    ///   `WKWebsiteDataStore`, keyed by this uuid, so cookies/localStorage/IndexedDB (the
    ///   Mattermost session) are isolated from every other server. Passing `nil` uses
    ///   `WKWebsiteDataStore.default()`.
    init(dataStoreIdentifier: UUID? = nil) {
        self.dataStoreIdentifier = dataStoreIdentifier
        let config = WKWebViewConfiguration()
        // Phase-0 baseline from the design doc §5.2: default inline media playback and
        // auto-play allowed (voice/video clips inside the web app).
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // Per-server session isolation (design §5, task 9): named persistent stores keyed by the
        // server uuid. `nonPersistent()` would drop the login on relaunch, so it is never used.
        config.websiteDataStore = dataStoreIdentifier.map { WKWebsiteDataStore(forIdentifier: $0) }
            ?? .default()
        // Fresh content controller. Phase 0 adds NO default user scripts/handlers — the
        // bridge surface stays closed so no shell capability is exposed to arbitrary page JS
        // (security boundary). Phase 1's Bridge registers its single handler + preload here.
        let contentController = WKUserContentController()
        config.userContentController = contentController
        configuration = config

        let args = ProcessInfo.processInfo.arguments

        // Phase-1 JS↔native bridge: the single message handler plus the shell-side page fixes
        // (SSO entry guard, bounded error log). Always installed — these are what make sign-in
        // work at all.
        let bridge = Bridge()
        contentController.add(bridge, name: Bridge.handlerName)
        contentController.addUserScript(WKUserScript(
            source: Bridge.pageJavascript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        // The `window.desktop` surface is opt-in. Advertising it makes the web app take its
        // Electron code path, which needs more of that API than the shell provides: the workspace
        // shell mounts and the channel view never loads. Kept behind a flag (and its unit tests)
        // so the bridge work is not lost while the surface is filled in.
        if args.contains("-desktopBridge") {
            contentController.addUserScript(WKUserScript(
                source: Bridge.preloadJavascript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
        }
        self.bridge = bridge

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.userAgent
        self.webView = webView

        // KVO on progress wrapped into Combine for cleaner observation.
        webView.publisher(for: \.estimatedProgress)
            .assign(to: &$progress)
        webView.publisher(for: \.isLoading)
            .assign(to: &$isLoading)
        // Normalise the pre-navigation empty title to nil: `WKWebView.title` starts as "" and
        // would otherwise publish an empty string that SwiftUI bindings render as a blank bar.
        webView.publisher(for: \.title)
            .map { $0?.isEmpty == false ? $0 : nil }
            .assign(to: &$title)
        webView.publisher(for: \.url)
            .assign(to: &$url)
        // History state feeds the toolbar's Back button (SSO flows navigate several hops).
        webView.publisher(for: \.canGoBack)
            .assign(to: &$canGoBack)
        webView.publisher(for: \.canGoForward)
            .assign(to: &$canGoForward)
    }

    // MARK: Loading

    /// Begin loading a Mattermost server base URL. The web app handles its own redirects and
    /// auth; the shell only starts the navigation. Clears any stale error first.
    func load(_ url: URL) {
        pageError = nil
        hasFinishedPageLoad = false
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        webView.load(request)
    }

    /// What the shell owes this store when its web branch (re)appears.
    ///
    /// Split out as a pure function so the rule below is unit-tested as a truth table
    /// (`WebViewStoreTests.testLoadNeedTruthTable`) instead of only through a live webview.
    enum LoadNeed: Equatable {
        /// Nothing committed yet: start the scene's navigation.
        case load(URL)
        /// A page is committed but its navigation neither finished nor is running — it was
        /// stopped mid-load (the surface toggle dismantles the web branch). Re-issue it.
        case resume(URL)
        /// A navigation is in flight, the page is already loaded, or it failed: leave it alone.
        case none
    }

    /// The resume rule (T26-R R6). `dismantleUIView` stops the load, which leaves a committed page
    /// whose navigation never finished; the old `guard store.url == nil` therefore no-oped forever
    /// and the pane stayed incomplete.
    ///
    /// `interruptedByDismantle` is checked **before** `isLoading` on purpose: `WKWebView.isLoading`
    /// flips to `false` asynchronously (KVO), so a re-attach that happens immediately after the
    /// dismantle can still see `isLoading == true` for a load that is already stopped. Trusting it
    /// there answered `.none` and stranded the page — the flake this flag removes (`stopForDismantle`
    /// records the fact synchronously, at the moment the branch goes away).
    static func loadNeed(committedURL: URL?,
                         serverURL: URL,
                         isLoading: Bool,
                         hasFinishedPageLoad: Bool,
                         hasPageError: Bool,
                         interruptedByDismantle: Bool = false) -> LoadNeed {
        guard let committedURL else {
            // Nothing committed: first navigation, or a retry after a provisional failure.
            return .load(serverURL)
        }
        if hasFinishedPageLoad { return .none }     // loaded (or signed in): leave it alone
        if hasPageError { return .none }            // failed: the error/retry UI owns this
        if interruptedByDismantle { return .resume(committedURL) }  // stopped by the toggle
        if isLoading { return .none }               // genuinely in flight: never re-issue it
        return .resume(committedURL)                // committed, unfinished, not running: stopped
    }

    /// The one entry the shell uses to take ownership of a scene's navigation: starts it, resumes
    /// an interrupted one, or leaves a live/finished page untouched. Idempotent, so it is safe to
    /// call on every web-branch appearance.
    func loadIfNeeded(_ serverURL: URL) {
        let need = Self.loadNeed(committedURL: url,
                                 serverURL: serverURL,
                                 isLoading: webView.isLoading,
                                 hasFinishedPageLoad: hasFinishedPageLoad,
                                 hasPageError: pageError != nil,
                                 interruptedByDismantle: interruptedByDismantle)
        interruptedByDismantle = false
        switch need {
        case .load(let target), .resume(let target):
            load(target)
        case .none:
            break
        }
    }

    /// Stop the page because the web branch is being dismantled (surface toggle, scene teardown).
    ///
    /// Records the interruption **synchronously** so the next `loadIfNeeded(_:)` resumes the page even
    /// if `isLoading` has not caught up yet. Only an *unfinished committed* page needs resuming: a
    /// signed-in page is left alone, and a page that never committed is re-loaded from the server URL
    /// anyway.
    func stopForDismantle() {
        if url != nil && !hasFinishedPageLoad && pageError == nil {
            interruptedByDismantle = true
        }
        webView.stopLoading()
    }

    /// Called by `WebViewContainer`'s coordinator when a main-frame navigation starts, so a page
    /// that is superseded by a new navigation is no longer considered finished.
    func markPageLoadStarted() {
        hasFinishedPageLoad = false
    }

    /// Called by `WebViewContainer`'s coordinator on `didFinish` (`hasFinishedPageLoad`).
    func markPageLoadFinished() {
        hasFinishedPageLoad = true
    }

    /// Record a failed navigation.
    ///
    /// **A cancellation is not a page failure.** `dismantleUIView` → `stopLoading()` (the surface
    /// toggle taking the web branch away) and a navigation superseded by a newer one both end with
    /// `NSURLErrorCancelled`, and WebKit reports a replaced/provisional-download navigation as
    /// `WebKitErrorDomain` 102 ("frame load interrupted"). Recording either as `pageError` is wrong
    /// twice over: the error/retry overlay covers a page that is merely *paused*, and `loadNeed`
    /// answers `.none` for `hasPageError`, so the interrupted load is never resumed — the R6 strand
    /// in a second form, found by re-running the repro after the first fix. Stopped navigations are
    /// resumed by `loadIfNeeded(_:)` instead; only a genuine failure sets `pageError`.
    func markPageLoadFailed(_ error: Error) {
        isLoading = false
        let nsError = error as NSError
        let cancelled = Self.isCancellation(error)
        Logger.info("WebView",
                    "navigation failed [\(nsError.domain) \(nsError.code)] -> "
                    + (cancelled ? "ignored (stopped; resumable)" : "shown as page error"))
        if cancelled { return }
        pageError = error
    }

    /// Whether `error` means "this navigation was stopped", not "this page failed".
    static func isCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return true }
        // WebKitErrorDomain 102 = kWebKitErrorFrameLoadInterruptedByPolicyChange. Apple's guidance is
        // to ignore it: the frame load was replaced, not broken.
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return true }
        return false
    }

    /// Walk the webview's own history back one entry, if there is one.
    func goBack() {
        guard webView.canGoBack else { return }
        pageError = nil
        webView.goBack()
    }

    /// Reload the current page (the shell's only recovery affordance besides retry).
    func reload() {
        pageError = nil
        webView.reload()
    }

    /// Recovery entry for retry UI: re-issue the loaded (or configured) URL.
    func retry() {
        if let url { load(url) }
    }

    /// Record the user's certificate decision and dismiss the pending prompt. `trust` == add
    /// to the trust bag; `dontTrustAgain` (`trust == false`) marks an explicit refusal that
    /// suppresses future prompts. The Coordinator's handler owns the Keychain write + reload.
    func resolveCertificatePrompt(trust: Bool, dontTrustAgain: Bool) {
        guard let prompt = pendingCertificatePrompt else { return }
        pendingCertificatePrompt = nil
        certificateDecisionHandler?(prompt, trust, dontTrustAgain)
    }

    /// Native counterpart of desktop `clearCacheAndReload` (the ConnectionErrorView
    /// troubleshooting bullet): wipe this webview's website data store (cookies, cache,
    /// localStorage — but NOT the persistent session we intentionally keep per server) and
    /// reload the last URL. The session is *not* cleared: desktop's `session.clearCache()`
    /// also keeps cookies/localStorage, it clears the HTTP cache partition, and iOS WKWebView
    /// has no narrower public API inside a single webview's store — so this drops the store's
    /// cache + transient data and reloads, which is the honest analogue of the bullet.
    func clearCacheAndReload() {
        let store = webView.configuration.websiteDataStore
        let dataTypes = Set([WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache,
                             WKWebsiteDataTypeOfflineWebApplicationCache])
        store.removeData(ofTypes: dataTypes, modifiedSince: .distantPast) { [weak self] in
            Task { @MainActor [weak self] in
                self?.retry()
            }
        }
    }

    func stopLoading() {
        webView.stopLoading()
    }
}