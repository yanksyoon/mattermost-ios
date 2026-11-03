import Foundation
import WebKit
import XCTest
@testable import Mattermost

// T31 (t_4528b67e): **a cookie written into a webview store must be verified, because the store can
// discard the write and still call the setter's completion handler.**
//
// Measured before this suite existed (2026-11-04, iPhone 16 Pro / iOS 18.3.1, fresh app launch):
// the T31 harvest suite planted `MMAUTHTOKEN` before the store's WebKit Networking process was up;
// `setCookie` completed, `allCookies()` answered `[]` immediately and still `[]` two seconds later,
// and the harvest therefore resolved the launch as signed out. The same write issued once the
// process was up stayed, and the harvest adopted it ("signed in as perfprobe", "adopted the webview
// session"). So the assertion that failed was true of the *product* and false of the *fixture*: the
// cookie never existed.
//
// What is pinned here:
//   1. an installer retries a write a store drops and reports success only when it landed;
//   2. an installer gives up (bounded) and names what never landed, so a caller cannot mistake a
//      dead store for a planted session;
//   3. a store holding a *previous* token of the same name is not "the write landed" — the value and
//      scope have to agree;
//   4. against a real `WKWebsiteDataStore`, the installed cookie is what the production reader
//      (`WebKitSessionCookieReader`) then finds.

// MARK: - A store that can drop writes

/// Scripted `SessionCookieStoring`: drops a given number of `setCookie` calls, exactly the way the
/// real one did at launch — quietly, with the caller's `await` returning as if it had worked.
final class ScriptedCookieStore: SessionCookieStoring {
    private let lock = NSLock()
    private var cookies: [HTTPCookie]
    private var writesToDrop: Int
    private(set) var setCalls = 0

    init(droppingWrites writesToDrop: Int, holding: [HTTPCookie] = []) {
        self.writesToDrop = writesToDrop
        self.cookies = holding
    }

    var held: [HTTPCookie] {
        lock.lock(); defer { lock.unlock() }
        return cookies
    }

    func allCookies() async -> [HTTPCookie] { held }

    func setCookie(_ cookie: HTTPCookie) async {
        lock.lock(); defer { lock.unlock() }
        setCalls += 1
        guard writesToDrop <= 0 else {
            writesToDrop -= 1
            return
        }
        cookies.removeAll { $0.name == cookie.name && $0.domain == cookie.domain }
        cookies.append(cookie)
    }
}

// MARK: - The tests

@MainActor
final class T31HarvestCookieInstallTests: XCTestCase {

    private let serverURL = URL(string: "http://127.0.0.1:8065")!

    private func cookie(_ value: String,
                        name: String = SessionCookiePolicy.authCookieName,
                        domain: String = "127.0.0.1",
                        path: String = "/") -> HTTPCookie {
        HTTPCookie(properties: [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
            .expires: Date().addingTimeInterval(3000),
        ])!
    }

    private func installer(_ store: SessionCookieStoring, attempts: Int = 8) -> WebSessionCookieInstaller {
        // No real waiting: the unit suite tests the decision, not the clock.
        WebSessionCookieInstaller(store: store, attempts: attempts, interval: 0.25, pause: { _ in })
    }

    // MARK: 1. It retries

    /// The launch case: the first writes are discarded by the store, a later one is kept. The
    /// installer must not report success on the first completion handler, and must not give up.
    func testTheInstallerRetriesAWriteTheStoreDiscards() async throws {
        let store = ScriptedCookieStore(droppingWrites: 2)

        let missing = await installer(store).install([cookie("fresh-token")])

        XCTAssertEqual(missing, [], "the write landed on the third round, so nothing is missing")
        XCTAssertEqual(store.setCalls, 3, "two dropped writes, then the kept one")
        XCTAssertEqual(store.held.map(\.value), ["fresh-token"])
    }

    // MARK: 2. It gives up, honestly

    /// A store that never keeps the cookie. The caller gets the names back — the one signal that
    /// lets a launch say "this session does not exist" instead of "planted".
    func testTheInstallerNamesWhatADeadStoreNeverKept() async throws {
        let store = ScriptedCookieStore(droppingWrites: .max)

        let missing = await installer(store, attempts: 3).install([cookie("fresh-token")])

        XCTAssertEqual(missing, [SessionCookiePolicy.authCookieName],
                       "the cookie that never landed is named")
        XCTAssertEqual(store.setCalls, 3, "bounded: exactly the configured number of rounds")
        XCTAssertTrue(store.held.isEmpty)
    }

    /// An empty install is not a failure and not a write: a signed-out server must not be turned
    /// into one by a stray round of `setCookie`.
    func testAnEmptyInstallWritesNothing() async throws {
        let store = ScriptedCookieStore(droppingWrites: 0)

        let missing = await installer(store).install([])

        XCTAssertEqual(missing, [])
        XCTAssertEqual(store.setCalls, 0)
    }

    // MARK: 3. Value and scope, not just the name

    /// The store still holds the *previous* launch's token under the same name (a session that was
    /// signed out server-side, or a leftover). A name-only check would call the dropped write a
    /// success; the harvest would then adopt a token nothing wrote.
    func testAPreviousTokenOfTheSameNameIsNotTheWrite() async throws {
        let stale = cookie("stale-token")
        let store = ScriptedCookieStore(droppingWrites: .max, holding: [stale])

        let missing = await installer(store, attempts: 2).install([cookie("fresh-token")])

        XCTAssertEqual(missing, [SessionCookiePolicy.authCookieName])
        XCTAssertEqual(store.held.map(\.value), ["stale-token"], "the stale copy is untouched")
    }

    /// …and the presence rule itself: name alone is not enough, and neither is a different scope.
    func testPresenceNeedsTheSameValueDomainAndPath() throws {
        let wanted = cookie("fresh-token")

        XCTAssertTrue(SessionCookiePolicy.isPresent(wanted, in: [wanted]))
        XCTAssertFalse(SessionCookiePolicy.isPresent(wanted, in: [cookie("other-token")]),
                       "same name and scope, different value")
        XCTAssertFalse(SessionCookiePolicy.isPresent(wanted, in: [cookie("fresh-token", domain: "mm.example.com")]),
                       "same value, different domain")
        XCTAssertFalse(SessionCookiePolicy.isPresent(wanted, in: [cookie("fresh-token", path: "/sub")]),
                       "same value, different path")
        XCTAssertTrue(SessionCookiePolicy.isPresent(wanted, in: [cookie("fresh-token", domain: ".127.0.0.1")]),
                      "WebKit may return the domain with a leading dot")
    }

    // MARK: 4. The real store, through the production reader

    /// The chain that exists in the app: install into a server's own persistent store with the
    /// installer, then read it with `WebKitSessionCookieReader(serverID:)` — the reader
    /// `AuthCoordinator` uses when there is no vault token (the harvest).
    func testARealStoreKeepsTheInstalledCookieAndTheProductionReaderFindsIt() async throws {
        let serverID = UUID()
        let dataStore = WKWebsiteDataStore(forIdentifier: serverID)
        defer {
            Task {
                await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                           modifiedSince: .distantPast)
            }
        }

        let wanted = cookie("real-store-token")
        let missing = await WebSessionCookieInstaller(dataStore: dataStore).install([wanted])
        XCTAssertEqual(missing, [], "a warm store keeps the very first write")

        let read = await WebKitSessionCookieReader(serverID: serverID).authToken(for: serverURL)
        XCTAssertEqual(read, "real-store-token",
                       "the harvest's reader finds exactly what the installer verified")
    }
}
