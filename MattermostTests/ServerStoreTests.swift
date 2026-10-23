import XCTest
@testable import Mattermost

final class ServerURLTests: XCTestCase {

    func testAddsHTTPSWhenSchemeMissing() throws {
        let url = try ServerURL.normalize("community.mattermost.com")
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "community.mattermost.com")
        XCTAssertEqual(url.absoluteString, "https://community.mattermost.com")
    }

    func testStripsTrailingSlash() throws {
        let url = try ServerURL.normalize("https://community.mattermost.com/")
        XCTAssertEqual(url.absoluteString, "https://community.mattermost.com")
    }

    func testKeepsHTTPSchemeWhenExplicit() throws {
        let url = try ServerURL.normalize("http://192.168.1.10:8065")
        XCTAssertEqual(url.scheme, "http")
        XCTAssertEqual(url.port, 8065)
    }

    func testTrimsWhitespace() throws {
        let url = try ServerURL.normalize("  https://community.mattermost.com  ")
        XCTAssertEqual(url.absoluteString, "https://community.mattermost.com")
    }

    func testThrowsOnEmpty() {
        XCTAssertThrowsError(try ServerURL.normalize("   ")) { error in
            guard case ServerURLError.empty = error else {
                return XCTFail("expected .empty, got \(error)")
            }
        }
    }

    func testThrowsOnInvalid() {
        XCTAssertThrowsError(try ServerURL.normalize("https://")) { error in
            guard case ServerURLError.invalid = error else {
                return XCTFail("expected .invalid, got \(error)")
            }
        }
    }
}

final class ServerStoreTests: XCTestCase {

    /// Backing defaults for the store under test, kept so a "reload" store can reuse them.
    private var suiteDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        let suiteName = "ServerStoreTests-\(UUID().uuidString)"
        suiteDefaults = UserDefaults(suiteName: suiteName)!
        // Ensure a clean slate (suiteName is unique per test, but removeAll defensively).
        suiteDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        suiteDefaults = nil
        super.tearDown()
    }

    private func makeStore() -> ServerStore {
        ServerStore(preferences: AppPreferences(defaults: suiteDefaults))
    }

    func testAddAssignsOrderAndUniqueID() throws {
        let store = makeStore()
        let a = try XCTUnwrap(store.add(ServerConfig(name: "A", url: URL(string: "https://a.example")!)))
        let b = try XCTUnwrap(store.add(ServerConfig(name: "B", url: URL(string: "https://b.example")!)))
        XCTAssertEqual(store.servers.count, 2)
        XCTAssertEqual(a.order, 0)
        XCTAssertEqual(b.order, 1)
        XCTAssertNotEqual(a.id, b.id)
    }

    func testAddRejectsDuplicateHost() throws {
        let store = makeStore()
        _ = store.add(ServerConfig(name: "A", url: URL(string: "https://a.example")!))
        // Same host with a different display name / trailing slash must be refused.
        let dup = store.add(ServerConfig(name: "A copy", url: URL(string: "https://A.example/")!))
        XCTAssertNil(dup, "desktop ServerManager refuses a second server on the same host")
        XCTAssertEqual(store.servers.count, 1)
        XCTAssertTrue(store.containsServer(withSameHostAs: ServerConfig(name: "x", url: URL(string: "https://a.example:443")!)))
    }

    func testPersistenceRoundTrip() throws {
        let store = makeStore()
        let one = try XCTUnwrap(store.add(ServerConfig(name: "One", url: URL(string: "https://one.example")!)))
        store.switchTo(id: one.id)

        // New store reading the same underlying suite must see the saved server + active id.
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.servers.count, 1)
        XCTAssertEqual(reloaded.servers.first?.name, "One")
        XCTAssertEqual(reloaded.activeServerID, one.id)
    }

    func testRemoveDropsServerAndReassignsActive() throws {
        let store = makeStore()
        let a = try XCTUnwrap(store.add(ServerConfig(name: "A", url: URL(string: "https://a.example")!)))
        _ = store.add(ServerConfig(name: "B", url: URL(string: "https://b.example")!))
        store.switchTo(id: a.id)
        store.remove(id: a.id)
        XCTAssertEqual(store.servers.map(\.id).count, 1)
        // Active re-allocated to the remaining server.
        XCTAssertNotNil(store.activeServerID)
        XCTAssertNotEqual(store.activeServerID, a.id)
    }

    func testInitialServerPrefersLastActiveThenOrder() throws {
        let store = makeStore()
        let a = try XCTUnwrap(store.add(ServerConfig(name: "A", url: URL(string: "https://a.example")!)))
        let b = try XCTUnwrap(store.add(ServerConfig(name: "B", url: URL(string: "https://b.example")!)))
        store.switchTo(id: b.id)
        XCTAssertEqual(store.initialServer?.id, b.id)
        XCTAssertEqual(store.activeServerID, b.id)
        XCTAssertEqual(store.servers.first?.id, a.id)
    }

    /// A server list persisted as fully empty must NOT be treated as a first run, so the shell
    /// won't re-seed community after the user removes their last server.
    func testHasEverConfiguredServersPersistsThroughEmptyList() throws {
        let store = makeStore()
        let a = try XCTUnwrap(store.add(ServerConfig(name: "A", url: URL(string: "https://a.example")!)))
        store.remove(id: a.id)
        XCTAssertTrue(store.servers.isEmpty)
        XCTAssertTrue(store.hasEverConfiguredServers, "empty-but-touched list is not a first run")
    }
}