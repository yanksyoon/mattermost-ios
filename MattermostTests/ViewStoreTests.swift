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

        let first = store.view(for: server)
        let second = store.view(for: server)

        XCTAssertTrue(first === second, "returning to a server must reuse its live webview")
        XCTAssertEqual(store.stores.count, 1)
    }

    /// Per-server session isolation: each server's webview owns its own persistent data store,
    /// keyed by the server uuid, so two servers can be signed in as different users.
    func testEachServerGetsAnIsolatedDataStore() {
        let store = ViewStore()
        let alpha = makeServer(name: "Alpha")
        let beta = makeServer(name: "Beta")

        let alphaView = store.view(for: alpha)
        let betaView = store.view(for: beta)

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
        let first = ViewStore().view(for: server)
        let second = ViewStore().view(for: server)

        XCTAssertEqual(first.dataStoreIdentifier, second.dataStoreIdentifier)
        XCTAssertNotNil(second.dataStoreIdentifier)
    }

    func testSetPrimaryTracksActiveServer() {
        let store = ViewStore()
        let alpha = makeServer(name: "Alpha")
        let beta = makeServer(name: "Beta")
        _ = store.view(for: alpha)
        _ = store.view(for: beta)

        store.setPrimary(beta.id)

        XCTAssertEqual(store.primaryServerID, beta.id)
    }

    func testRemoveDropsStoreAndClearsPrimary() {
        let store = ViewStore()
        let alpha = makeServer(name: "Alpha")
        let beta = makeServer(name: "Beta")
        _ = store.view(for: alpha)
        _ = store.view(for: beta)
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
        let alphaView = store.view(for: alpha)
        let betaView = store.view(for: beta)

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
        let work = store.view(for: makeServer(name: "Community (work)"))
        let personal = store.view(for: makeServer(name: "Community (personal)"))

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
}
