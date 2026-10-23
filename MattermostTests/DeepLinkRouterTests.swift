import XCTest
@testable import Mattermost

@MainActor
final class DeepLinkRouterTests: XCTestCase {

    private func makeStore(servers: [ServerConfig]) -> ServerStore {
        let prefs = AppPreferences(defaults: UserDefaults(suiteName: "deeplink-tests-\(UUID().uuidString)")!)
        prefs.removeObject(forKey: AppPreferences.Keys.servers)
        let store = ServerStore(preferences: prefs)
        for s in servers { _ = store.add(s) }
        return store
    }

    private func community() -> ServerConfig {
        ServerConfig(name: "Community", url: URL(string: "https://community.mattermost.com")!)
    }

    // MARK: parsing (parity: getDeeplinkingURL / parseURL)

    func testParsesMattermostScheme() {
        let link = DeepLinkParsing.parse("mattermost://community.mattermost.com/team/general")
        XCTAssertEqual(link?.serverURL?.host, "community.mattermost.com")
        XCTAssertEqual(link?.path, "/team/general")
    }

    func testParsesMattermostBetaScheme() {
        let link = DeepLinkParsing.parse("mattermost-beta://community.mattermost.com/team")
        XCTAssertEqual(link?.serverURL?.host, "community.mattermost.com")
        XCTAssertEqual(link?.path, "/team")
    }

    func testParsesHttpLink() {
        let link = DeepLinkParsing.parse("https://community.mattermost.com/team/general")
        XCTAssertEqual(link?.serverURL?.host, "community.mattermost.com")
        XCTAssertEqual(link?.path, "/team/general")
    }

    func testPreservesPortOnMattermostScheme() {
        let link = DeepLinkParsing.parse("mattermost://mattermost.example.org:8443/team")
        XCTAssertEqual(link?.serverURL?.port, 8443)
    }

    func testRejectsUnknownScheme() {
        XCTAssertNil(DeepLinkParsing.parse("ftp://example.com/team"))
        XCTAssertNil(DeepLinkParsing.parse(""))
    }

    func testRejectsOversizedLink() {
        let big = String(repeating: "a", count: 3000)
        XCTAssertNil(DeepLinkParsing.parse("mattermost://\(big)"))
    }

    func testRejectsNulByte() {
        XCTAssertNil(DeepLinkParsing.parse("mattermost://foo\u{0000}bar"))
    }

    // MARK: routing (parity: navigationManager.openLinkInPrimaryTab)

    func testRoutesToMatchingServer() {
        let server = community()
        let serverStore = makeStore(servers: [server])
        let viewStore = ViewStore()
        let router = DeepLinkRouter()
        router.serverStore = serverStore
        router.viewStore = viewStore
        router.ready()

        let outcome = router.handle("mattermost://community.mattermost.com/team/general")

        XCTAssertEqual(outcome, .routed)
        XCTAssertEqual(serverStore.activeServerID, server.id, "deep link must switch to the matching server")
        XCTAssertEqual(viewStore.primaryServerID, server.id)
    }

    func testRoutesWithoutChannelToServerRoot() {
        let server = community()
        let serverStore = makeStore(servers: [server])
        let viewStore = ViewStore()
        let router = DeepLinkRouter()
        router.serverStore = serverStore
        router.viewStore = viewStore
        router.ready()

        let outcome = router.handle("mattermost://community.mattermost.com")

        XCTAssertEqual(outcome, .routed)
        XCTAssertEqual(serverStore.activeServerID, server.id)
    }

    func testUnmatchedHostOffersServerAdd() {
        let serverStore = makeStore(servers: [community()])
        let router = DeepLinkRouter()
        router.serverStore = serverStore
        router.ready()

        let outcome = router.handle("mattermost://other.example.com/team")

        XCTAssertEqual(outcome, .needsServerAdd(serverURL: URL(string: "https://other.example.com")))
    }

    func testNoServersOffersAdd() {
        let serverStore = makeStore(servers: [])
        let router = DeepLinkRouter()
        router.serverStore = serverStore
        router.ready()

        let outcome = router.handle("mattermost://fresh.example.com/team")

        XCTAssertEqual(outcome, .needsServerAdd(serverURL: URL(string: "https://fresh.example.com")))
    }

    /// Before `ready()`, the router must queue the link and apply it on `ready()`.
    func testQueuesUntilReady() {
        let server = community()
        let serverStore = makeStore(servers: [server])
        let router = DeepLinkRouter()
        router.serverStore = serverStore

        XCTAssertEqual(router.handle("mattermost://community.mattermost.com/team/general"), .queued)
        XCTAssertNil(serverStore.activeServerID, "no routing before ready()")

        router.ready()
        XCTAssertEqual(serverStore.activeServerID, server.id)
    }

    /// A link routed before the router has a store returns ignored (nothing to drive) rather
    /// than queueing forever.
    func testUnreadyWithoutStoreIsIgnored() {
        let router = DeepLinkRouter()
        let outcome = router.handle("mattermost://community.mattermost.com/team")
        XCTAssertNotEqual(outcome, .routed)
    }
}