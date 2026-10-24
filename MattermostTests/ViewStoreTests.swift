import XCTest
import WebKit
@testable import Mattermost

@MainActor
final class ViewStoreTests: XCTestCase {

    private func makeServer(name: String = "Server",
                            url: String = "https://community.mattermost.com") -> ServerConfig {
        ServerConfig(name: name, url: URL(string: url)!)
    }

    /// A switch away from a server must not tear its webview down — that webview holds the
    /// signed-in session, so the same instance has to come back.
    func testViewIsCreatedOncePerServer() {
        let store = ViewStore()
        let server = makeServer()

        let first = store.ensureStore(for: server)
        let second = store.ensureStore(for: server)

        XCTAssertTrue(first === second, "returning to a server must reuse its live webview")
        XCTAssertEqual(store.stores.count, 1)
    }

    /// Per-server session isolation: each server's webview owns its own persistent data store,
    /// keyed by the server uuid, so two servers can be signed in as different users.
    func testEachServerGetsAnIsolatedDataStore() {
        let store = ViewStore()
        let alpha = makeServer(name: "Alpha")
        let beta = makeServer(name: "Beta")

        let alphaView = store.ensureStore(for: alpha)
        let betaView = store.ensureStore(for: beta)

        XCTAssertEqual(alphaView.dataStoreIdentifier, alpha.id)
        XCTAssertEqual(betaView.dataStoreIdentifier, beta.id)
        XCTAssertFalse(
            alphaView.webView.configuration.websiteDataStore
                === betaView.webView.configuration.websiteDataStore,
            "servers must never share cookies/storage"
        )
        XCTAssertFalse(
            alphaView.webView.configuration.websiteDataStore === WKWebsiteDataStore.default(),
            "a per-server store must not fall back to the shared app store"
        )
    }

    /// The isolation key is the server uuid, so a relaunch (new ViewStore) re-attaches to the
    /// same on-disk store and the user stays signed in.
    func testDataStoreKeyIsStableAcrossStoreRecreation() {
        let server = makeServer()
        let first = ViewStore().ensureStore(for: server)
        let second = ViewStore().ensureStore(for: server)

        XCTAssertEqual(first.dataStoreIdentifier, second.dataStoreIdentifier)
        XCTAssertNotNil(second.dataStoreIdentifier)
    }

    func testSetPrimaryTracksActiveServer() {
        let store = ViewStore()
        let alpha = makeServer(name: "Alpha")
        let beta = makeServer(name: "Beta")
        _ = store.ensureStore(for: alpha)
        _ = store.ensureStore(for: beta)

        store.setPrimary(beta.id)

        XCTAssertEqual(store.primaryServerID, beta.id)
    }

    func testRemoveDropsStoreAndClearsPrimary() {
        let store = ViewStore()
        let alpha = makeServer(name: "Alpha")
        let beta = makeServer(name: "Beta")
        _ = store.ensureStore(for: alpha)
        _ = store.ensureStore(for: beta)
        store.setPrimary(beta.id)

        store.remove(serverID: beta.id)

        XCTAssertNil(store.view(forServerID: beta.id), "removed server's webview must be released")
        XCTAssertNotNil(store.view(forServerID: alpha.id))
        XCTAssertNil(store.primaryServerID, "primary view must not point at a removed server")
    }

    func testMountedStoresFollowServerOrder() {
        let store = ViewStore()
        let alpha = makeServer(name: "Alpha")
        let beta = makeServer(name: "Beta")
        let alphaView = store.ensureStore(for: alpha)
        let betaView = store.ensureStore(for: beta)

        let mounted = store.mountedStores(for: [beta, alpha])

        XCTAssertEqual(mounted.count, 2)
        XCTAssertTrue(mounted[0] === betaView)
        XCTAssertTrue(mounted[1] === alphaView)
    }

    /// The real isolation claim, tested on the mechanism that carries a Mattermost login: the
    /// `MMAUTHTOKEN` cookie. Two servers — even on the *same* host — must have independent
    /// cookie jars, so each can hold a different signed-in user at the same time.
    func testAuthCookiesDoNotLeakBetweenServers() async throws {
        let store = ViewStore()
        let work = store.ensureStore(for: makeServer(name: "Community (work)"))
        let personal = store.ensureStore(for: makeServer(name: "Community (personal)"))

        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .name: "MMAUTHTOKEN",
            .value: "work-session",
            .domain: "community.mattermost.com",
            .path: "/",
            .secure: "TRUE",
            .expires: Date().addingTimeInterval(3600)
        ]))
        let workStore = work.webView.configuration.websiteDataStore.httpCookieStore
        let personalStore = personal.webView.configuration.websiteDataStore.httpCookieStore
        await workStore.setCookie(cookie)

        let workCookies = await cookies(of: workStore)
        let personalCookies = await cookies(of: personalStore)

        XCTAssertTrue(workCookies.contains { $0.name == "MMAUTHTOKEN" && $0.value == "work-session" },
                      "the server that was signed in keeps its session cookie")
        XCTAssertFalse(personalCookies.contains { $0.name == "MMAUTHTOKEN" },
                       "a second server must not inherit another server's session")
    }

    private func cookies(of store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    // MARK: - Webview release policy (T26-R R4, docs/dual-render.md §12)

    /// §12.1's four-condition table, exhaustively: 2 × 2 × 2 × 2 × 2 = 32 rows.
    ///
    /// The rule is `paneSurfaceResolved == .native && paneOwning && (approved || allowUnapproved)
    /// && !navigationInFlight`, and every row is asserted against that formula rather than against a
    /// hand-written list — a hand-written list is what drifts when someone "simplifies" the predicate.
    func testMayReleaseTruthTable() {
        var rows = 0
        for resolved in SurfaceRenderMode.allCases {
            for approved in [false, true] {
                for paneOwning in [false, true] {
                    for inFlight in [false, true] {
                        for allow in [false, true] {
                            let expected = resolved == .native && paneOwning
                                && (approved || allow) && !inFlight
                            let actual = WebViewReleasePolicy.mayRelease(
                                paneSurfaceResolved: resolved,
                                approved: approved,
                                paneOwning: paneOwning,
                                navigationInFlight: inFlight,
                                allowUnapproved: allow)
                            XCTAssertEqual(actual, expected,
                                           "pane=\(resolved) approved=\(approved) "
                                           + "paneOwning=\(paneOwning) inFlight=\(inFlight) "
                                           + "allowUnapproved=\(allow)")
                            rows += 1
                        }
                    }
                }
            }
        }
        XCTAssertEqual(rows, 32, "the table must stay complete — every condition matters (§12.1)")
    }

    /// The one condition that must never be traded away: a navigation in flight always blocks, even
    /// with both registries approving and the bypass armed — never kill a login/SSO mid-flight.
    func testNavigationInFlightAlwaysBlocksRelease() {
        for resolved in SurfaceRenderMode.allCases {
            for approved in [false, true] {
                for allow in [false, true] {
                    XCTAssertFalse(WebViewReleasePolicy.mayRelease(
                        paneSurfaceResolved: resolved,
                        approved: approved,
                        paneOwning: true,
                        navigationInFlight: true,
                        allowUnapproved: allow),
                        "in-flight navigation must block (pane=\(resolved), approved=\(approved), "
                        + "allowUnapproved=\(allow))")
                }
            }
        }
    }

    /// A stand-in pane is not enough, however it was routed to native: approval without pane
    /// ownership (the `UnportedSurfaceView` case) can never release. §12.7's first rejected
    /// alternative, pinned as a test.
    func testApprovedButNotPaneOwningNeverReleases() {
        XCTAssertFalse(WebViewReleasePolicy.mayRelease(paneSurfaceResolved: .native,
                                                      approved: true,
                                                      paneOwning: false,
                                                      navigationInFlight: false))
    }

    /// §12.2: release = destroy the page and the process, **keep** the persistent data store.
    ///
    /// Evidence, per the decision: the last committed URL is remembered (so the return trip lands
    /// where the user was), the store is gone from the registry, and a re-created store still owns
    /// the *same* `WKWebsiteDataStore` identifier — which is where the Mattermost session lives.
    /// (Cookies are not read here on purpose: the isolation guarantee is asserted through the data
    /// store identity, which is the thing a release could break.)
    func testReleaseKeepsLastURLAndDoesNotPurgeDataStore() {
        let viewStore = ViewStore()
        let server = makeServer()
        let store = viewStore.ensureStore(for: server)
        let delegates = RecordingDelegates()
        store.webView.navigationDelegate = delegates
        store.webView.uiDelegate = delegates
        let committed = URL(string: "https://community.mattermost.com/team/channels/town-square")!
        store.url = committed

        viewStore.release(serverID: server.id)

        XCTAssertEqual(viewStore.lastURLs[server.id], committed,
                       "the released webview's committed URL must survive, so the reopen lands there")
        XCTAssertNil(viewStore.view(forServerID: server.id), "the store must be dropped, not parked")
        XCTAssertNil(store.webView.navigationDelegate, "nothing may answer WebKit for a destroyed store")
        XCTAssertNil(store.webView.uiDelegate)

        let recreated = viewStore.ensureStore(for: server)
        XCTAssertEqual(recreated.dataStoreIdentifier, server.id,
                       "a release must keep the per-server data store — that is the session")
        XCTAssertTrue(recreated.webView.configuration.websiteDataStore
                        === WKWebsiteDataStore(forIdentifier: server.id),
                      "the re-created webview must re-attach the same persistent data store")
    }

    /// §12.4's resurrection trap, in the store: only the creating accessor can bring a released
    /// webview back, and repeated non-creating reads must never do it.
    func testNonCreatingAccessorNeverResurrects() {
        let viewStore = ViewStore()
        let server = makeServer()
        _ = viewStore.ensureStore(for: server)
        viewStore.release(serverID: server.id)

        for _ in 0..<5 {
            XCTAssertNil(viewStore.view(forServerID: server.id),
                         "view(forServerID:) is a read; a SwiftUI body may call it any number of times")
        }
        XCTAssertTrue(viewStore.stores.isEmpty)
        XCTAssertEqual(viewStore.mountedStores(for: [server]).count, 0)

        // Idempotent: a sweep may release the same server again (and an unknown one) without harm.
        viewStore.release(serverID: server.id)
        viewStore.release(serverID: UUID())
        XCTAssertTrue(viewStore.stores.isEmpty)
    }

    /// Identity rules around a release: stable while alive (session continuity), different after a
    /// release (the webview really was destroyed), same data store either way.
    func testEnsureStoreReturnsFreshInstanceAfterRelease() {
        let viewStore = ViewStore()
        let server = makeServer()
        let first = viewStore.ensureStore(for: server)
        XCTAssertTrue(viewStore.ensureStore(for: server) === first,
                      "while alive the store (and its webview) must be re-attached, not rebuilt")
        let webView = first.webView

        viewStore.release(serverID: server.id)
        let second = viewStore.ensureStore(for: server)

        XCTAssertFalse(second === first, "a released store is destroyed: the next one is a new instance")
        XCTAssertFalse(second.webView === webView, "a released WKWebView is gone: the next one is new")
        XCTAssertEqual(second.dataStoreIdentifier, first.dataStoreIdentifier,
                       "…but it re-attaches the same persistent store, so no re-login (§12.3)")
    }

    /// The acceptance criterion in its strongest form: with the shipping registries, the release
    /// path is **unreachable** — for every surface, every resolution, either navigational state.
    func testEmptyRegistriesMakeReleaseUnreachable() {
        XCTAssertTrue(SurfaceDefaults.nativeApprovedSurfaces.isEmpty,
                      "no surface may be native-by-default until its -AV card lands")
        XCTAssertTrue(SurfaceDefaults.paneOwningSurfaces.isEmpty,
                      "no card owns a pane yet: release must be inert in this build")

        for surface in Surface.allCases {
            for resolved in SurfaceRenderMode.allCases {
                for inFlight in [false, true] {
                    XCTAssertFalse(WebViewReleasePolicy.shouldRelease(
                        paneSurfaceResolved: resolved,
                        approved: SurfaceDefaults.nativeApprovedSurfaces.contains(surface),
                        paneOwning: SurfaceDefaults.paneOwningSurfaces.contains(surface),
                        navigationInFlight: inFlight),
                        "\(surface.rawValue) resolved \(resolved.rawValue) (inFlight=\(inFlight)) "
                        + "must not release a webview in the shipping configuration")
                }
            }
        }
        // And the pane host is still the surface this release is inert for.
        XCTAssertEqual(SurfaceDefaults.paneHostSurface, .channelView)
    }
}

/// A do-nothing delegate pair, so a release test can prove the webview's `navigationDelegate` /
/// `uiDelegate` are detached (nothing may answer a WebKit callback for a destroyed store).
private final class RecordingDelegates: NSObject, WKNavigationDelegate, WKUIDelegate {}
