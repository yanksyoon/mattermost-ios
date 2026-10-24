import XCTest
import WebKit
@testable import Mattermost

@MainActor
final class WebViewStoreTests: XCTestCase {

    /// The document (File 4) pins the Phase-0 WebView configuration: inline media playback ON,
    /// no mediaTypesRequiringUserActionForPlayback. These two are load-bearing defaults.
    func testConfigurationAllowsInlinePlaybackAndAutoplay() {
        let store = WebViewStore()
        XCTAssertTrue(store.configuration.allowsInlineMediaPlayback, "voice/video clips must play inline")
        XCTAssertEqual(
            store.configuration.mediaTypesRequiringUserActionForPlayback,
            [],
            "no user-gesture requirement so media plays as the web app expects"
        )
    }

    func testStoreOwnsASingleReusableWebView() {
        let store = WebViewStore()
        XCTAssertNotNil(store.webView)
        // First access must not create a second instance (identity stability for SwiftUI).
        XCTAssertTrue(store.webView === store.webView)
    }

    func testLoadClearsErrorAndBeginsNavigation() {
        let store = WebViewStore()
        let url = URL(string: "https://community.mattermost.com")!
        // Prime an error to prove load() clears it.
        store.pageError = NSError(domain: "test", code: 0)
        // Load is fire-and-forget: this must not throw and must clear the stale error.
        store.load(url)
        XCTAssertNil(store.pageError)
    }

    func testInitialStateIsEmpty() {
        let store = WebViewStore()
        XCTAssertEqual(store.progress, 0)
        XCTAssertNil(store.title)
        XCTAssertNil(store.url)
        XCTAssertNil(store.pageError)
    }

    /// The server must serve the *web app*, not the mobile "view in app / view in browser"
    /// landing page it returns for iOS UAs — so the shell declares a desktop/Electron UA,
    /// exactly as the desktop client does.
    func testUserAgentMirrorsDesktopShell() {
        let store = WebViewStore()
        guard let userAgent = store.webView.customUserAgent else {
            return XCTFail("shell must pin a custom user agent")
        }
        XCTAssertFalse(userAgent.contains("iPhone"), "an iOS UA gets the mobile-app interstitial")
        XCTAssertTrue(userAgent.contains("Macintosh"), "a desktop UA is required to be served the web app")
        // Claiming to be Mattermost Desktop makes the web app run its Electron code path, which
        // needs a fuller window.desktop API than the shell implements; the workspace then mounts
        // its chrome and never renders a channel.
        XCTAssertFalse(userAgent.contains("Mattermost/"), "must not claim to be the Electron desktop app")
        XCTAssertFalse(userAgent.contains("Electron/"), "must not claim to be the Electron desktop app")
    }

    // MARK: Navigation policy (the SSO path)

    /// SSO providers finish by redirecting to a non-web scheme, or by opening the IdP in a popup.
    /// Both must be classified at the policy layer, otherwise the flow stalls on a blank page
    /// after the user authenticates.
    func testWebSchemesLoadInTheWebView() {
        for raw in ["https://community.mattermost.com/login", "http://localhost:8065/",
                    "about:blank", "data:text/html,hi", "blob:https://chat.example/1",
                    "javascript:void(0)"] {
            XCTAssertEqual(WebViewContainer.WebNavigationPolicy.decision(for: URL(string: raw)), .load,
                           "\(raw) is a web navigation and must load")
        }
    }

    func testNonWebSchemesAreHandedToTheApp() {
        for raw in ["mattermost://chat.example/landing", "msauth://com.example.app/callback",
                    "com.okta.example://callback", "chrome://settings"] {
            XCTAssertEqual(WebViewContainer.WebNavigationPolicy.decision(for: URL(string: raw)), .handOff,
                           "\(raw) cannot be loaded by WKWebView and must be handed to the app")
        }
    }

    func testMissingURLLoadsRatherThanBlocking() {
        XCTAssertEqual(WebViewContainer.WebNavigationPolicy.decision(for: nil), .load,
                       "a navigation without a URL must not be swallowed")
    }

    // MARK: Certificate-challenge scoping (the blank-SSO-page bug)

    /// The trust bag and the certificate sheet exist for the user's own server. A public
    /// identity provider must never be routed through them.
    func testCertChallengeFromConfiguredServerUsesTheTrustBag() {
        XCTAssertEqual(
            WebViewContainer.CertChallengePolicy.scope(challengeHost: "chat.example.com",
                                                      serverHost: "chat.example.com"),
            .serverOrigin)
        XCTAssertEqual(
            WebViewContainer.CertChallengePolicy.scope(challengeHost: "CHAT.Example.COM",
                                                      serverHost: "chat.example.com"),
            .serverOrigin,
            "host comparison must be case-insensitive, DNS is")
    }

    func testCertChallengeFromIdentityProviderIsThirdParty() {
        XCTAssertEqual(
            WebViewContainer.CertChallengePolicy.scope(challengeHost: "login.ubuntu.com",
                                                      serverHost: "chat.example.com"),
            .thirdParty)
        XCTAssertEqual(
            WebViewContainer.CertChallengePolicy.scope(challengeHost: "static.chat.example.com",
                                                      serverHost: "chat.example.com"),
            .thirdParty,
            "a sibling subdomain is a different origin with its own certificate")
        XCTAssertEqual(
            WebViewContainer.CertChallengePolicy.scope(challengeHost: "okta.com", serverHost: nil),
            .thirdParty,
            "no configured host means nothing can be scoped to the server")
        XCTAssertEqual(
            WebViewContainer.CertChallengePolicy.scope(challengeHost: "anything", serverHost: ""),
            .thirdParty)
    }

    // MARK: R6 — mid-load surface toggle must not strand a stopped page

    /// Truth table for `WebViewStore.loadNeed`, the decision the shell uses when a web branch
    /// (re)appears (T26-R R6). The interesting row is `(committed, not loading, unfinished, no
    /// error)` → `.resume`: that is a load the surface toggle stopped, and the pre-R6 code
    /// (`guard store.url == nil`) returned "nothing to do" for it, leaving the pane stranded.
    /// The end-to-end behaviour is covered by
    /// `MattermostUITests.testMidLoadSurfaceToggleResumesTheInterruptedWebview`.
    func testLoadNeedTruthTable() {
        let server = URL(string: "http://127.0.0.1:8111")!
        let committed = URL(string: "http://127.0.0.1:8111/channels/town-square")!

        // Nothing committed: start the scene's navigation (first mount, or a retry).
        XCTAssertEqual(WebViewStore.loadNeed(committedURL: nil, serverURL: server,
                                             isLoading: false, hasFinishedPageLoad: false,
                                             hasPageError: false), .load(server))
        XCTAssertEqual(WebViewStore.loadNeed(committedURL: nil, serverURL: server,
                                             isLoading: true, hasFinishedPageLoad: false,
                                             hasPageError: false), .load(server),
                       "a store that never committed must load regardless of KVO races")

        // In flight: never re-issue (that would restart the user's sign-in flow).
        XCTAssertEqual(WebViewStore.loadNeed(committedURL: committed, serverURL: server,
                                             isLoading: true, hasFinishedPageLoad: false,
                                             hasPageError: false), .none)

        // Loaded: leave the signed-in page alone.
        XCTAssertEqual(WebViewStore.loadNeed(committedURL: committed, serverURL: server,
                                             isLoading: false, hasFinishedPageLoad: true,
                                             hasPageError: false), .none)

        // Failed: the error/retry UI owns recovery, so do not fight it.
        XCTAssertEqual(WebViewStore.loadNeed(committedURL: committed, serverURL: server,
                                             isLoading: false, hasFinishedPageLoad: false,
                                             hasPageError: true), .none)

        // Committed, unfinished, nothing in flight → the load was stopped mid-flight (the surface
        // toggle dismantled the web branch): resume the committed URL, not the server root.
        XCTAssertEqual(WebViewStore.loadNeed(committedURL: committed, serverURL: server,
                                             isLoading: false, hasFinishedPageLoad: false,
                                             hasPageError: false), .resume(committed))

        // The race row: `stopLoading()`'s `isLoading` flag flips asynchronously, so a re-attach right
        // after the dismantle can still see `isLoading == true` for a load that is already stopped.
        // The recorded interruption outranks the stale flag — otherwise the page is stranded and the
        // batch UI run fails (observed once, then pinned here).
        XCTAssertEqual(WebViewStore.loadNeed(committedURL: committed, serverURL: server,
                                             isLoading: true, hasFinishedPageLoad: false,
                                             hasPageError: false, interruptedByDismantle: true),
                       .resume(committed),
                       "a recorded interruption must beat a stale isLoading=true")

        // A finished page and a failed page are never resumed, interruption or not.
        XCTAssertEqual(WebViewStore.loadNeed(committedURL: committed, serverURL: server,
                                             isLoading: false, hasFinishedPageLoad: true,
                                             hasPageError: false, interruptedByDismantle: true), .none)
        XCTAssertEqual(WebViewStore.loadNeed(committedURL: committed, serverURL: server,
                                             isLoading: false, hasFinishedPageLoad: false,
                                             hasPageError: true, interruptedByDismantle: true), .none)
    }

    /// `stopForDismantle()` records the interruption synchronously — that is the property the resume
    /// rule relies on — and only for an *unfinished committed* page.
    func testStopForDismantleRecordsOnlyUnfinishedPages() {
        let committed = URL(string: "http://127.0.0.1:8112/")!

        let unfinished = WebViewStore()
        unfinished.url = committed                  // what KVO sets on didCommit
        unfinished.stopForDismantle()
        XCTAssertTrue(unfinished.interruptedByDismantle,
                      "an unfinished committed page must be marked resumable")

        let finished = WebViewStore()
        finished.url = committed
        finished.markPageLoadFinished()
        finished.stopForDismantle()
        XCTAssertFalse(finished.interruptedByDismantle,
                       "a signed-in/finished page is left alone, never re-issued")

        let failed = WebViewStore()
        failed.url = committed
        failed.markPageLoadFailed(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        failed.stopForDismantle()
        XCTAssertFalse(failed.interruptedByDismantle, "the retry UI owns a failed page")

        // The resume consumes the flag, so a second appearance does not re-issue the navigation.
        unfinished.loadIfNeeded(URL(string: "http://127.0.0.1:8112")!)
        XCTAssertFalse(unfinished.interruptedByDismantle, "the interruption is consumed by the resume")
    }

    /// `loadIfNeeded` is the shell's single entry: with a finished page it must not navigate, and
    /// a fresh store must start exactly one navigation (`load()` clears the finished flag).
    func testLoadIfNeededLeavesAFinishedPageAlone() {
        let store = WebViewStore()
        XCTAssertFalse(store.hasFinishedPageLoad, "a fresh store has no finished page")

        store.markPageLoadFinished()
        XCTAssertTrue(store.hasFinishedPageLoad)
        store.loadIfNeeded(URL(string: "https://chat.example.com")!)
        // Nothing to observe on the live webview in a unit test; the pure decision above pins the
        // rule, and `load()` clearing the flag is asserted here.
        store.load(URL(string: "https://chat.example.com")!)
        XCTAssertFalse(store.hasFinishedPageLoad, "a new navigation supersedes the finished page")
        store.markPageLoadStarted()
        XCTAssertFalse(store.hasFinishedPageLoad)
    }

    // MARK: R6 (second variant) — a stopped navigation must not masquerade as a page error

    /// `stopLoading()` (the surface toggle dismantling the web branch) and a superseding navigation
    /// end with `NSURLErrorCancelled`; WebKit's "frame load interrupted" (102) is the same story.
    /// Neither may become `pageError`, or the retry overlay covers a merely paused page **and**
    /// `loadNeed` refuses to resume it (`hasPageError` → `.none`) — the strand the first R6 fix
    /// missed, caught by re-running the UI repro.
    func testCancellationIsNotAPageError() {
        let store = WebViewStore()

        store.markPageLoadFailed(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        XCTAssertNil(store.pageError, "a cancelled navigation leaves the page resumable, not failed")
        XCTAssertFalse(store.isLoading)

        // WebKit's own spelling of the same event.
        store.markPageLoadFailed(NSError(domain: "WebKitErrorDomain", code: 102))
        XCTAssertNil(store.pageError)

        // `isCancellation` is the pure predicate both callbacks rely on.
        XCTAssertTrue(WebViewStore.isCancellation(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
        XCTAssertTrue(WebViewStore.isCancellation(NSError(domain: "WebKitErrorDomain", code: 102)))
        XCTAssertFalse(WebViewStore.isCancellation(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
        XCTAssertFalse(WebViewStore.isCancellation(NSError(domain: "WebKitErrorDomain", code: 101)))
    }

    /// A real failure still surfaces: the error/retry UI must keep working (no blanket swallow).
    func testGenuineFailureIsAPageError() {
        let store = WebViewStore()
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        store.markPageLoadFailed(timeout)
        XCTAssertNotNil(store.pageError)
        XCTAssertFalse(store.isLoading)

        // And `loadNeed` leaves that surface to the retry UI rather than re-navigating under it.
        XCTAssertEqual(WebViewStore.loadNeed(committedURL: URL(string: "https://chat.example.com")!,
                                             serverURL: URL(string: "https://chat.example.com")!,
                                             isLoading: false, hasFinishedPageLoad: false,
                                             hasPageError: store.pageError != nil), .none)
    }
}
