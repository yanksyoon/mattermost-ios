import XCTest
import UserNotifications
@testable import Mattermost

/// Unit tests for T8 `SessionStore` (desktop `appState.ts` + the macOS branch of `badge.ts`):
/// per-server mention/unread/expired accounting, cross-server totals, the badge math, and the
/// persisted "show unread badge" setting. The badge *setter* is a recording mock so the math is
/// verified without touching the real `UNUserNotificationCenter`.
final class BadgeMathTests: XCTestCase {

    // Desktop `showBadgeOSX` decision order: mentionCount > 0 -> the count; else unread (gated on the
    // setting); else expired-mark; else empty. iOS integers: `!` -> 1, and the unread step is the
    // **message count** when the client knows it (card t_93eca948) — `1` only when it does not.

    func testMentionsTakePrecedenceAndUseTheCount() {
        XCTAssertEqual(SessionStore.badgeNumber(mentions: 3, unreadMessages: 40, isUnread: true, anyExpired: true, showUnreadBadge: true), 3)
        XCTAssertEqual(SessionStore.badgeNumber(mentions: 0, unreadMessages: 0, isUnread: false, anyExpired: false, showUnreadBadge: true), 0)
    }

    func testUnreadOnlyShowsTheMessageCountWhenSettingOn() {
        XCTAssertEqual(SessionStore.badgeNumber(mentions: 0, unreadMessages: 40, isUnread: true, anyExpired: false, showUnreadBadge: true), 40,
                       "t_93eca948: the icon counts, it does not draw a dot-as-1")
    }

    /// The one honest fallback: a read-out that only said "unread" has no number, and desktop's dot
    /// (integer 1 here) is the closest true thing.
    func testUnreadWithNoKnownCountFallsBackToTheDotsOne() {
        XCTAssertEqual(SessionStore.badgeNumber(mentions: 0, unreadMessages: nil, isUnread: true, anyExpired: false, showUnreadBadge: true), 1)
        XCTAssertEqual(SessionStore.badgeNumber(mentions: 0, unreadMessages: 0, isUnread: true, anyExpired: false, showUnreadBadge: true), 1,
                       "unread but zero unread messages is a contradiction: never draw 0 for it")
    }

    func testUnreadHiddenWhenSettingOff() {
        XCTAssertEqual(SessionStore.badgeNumber(mentions: 0, unreadMessages: 40, isUnread: true, anyExpired: false, showUnreadBadge: false), 0)
    }

    func testExpiredShowsOneWhenNoMentionsAndNoUnread() {
        XCTAssertEqual(SessionStore.badgeNumber(mentions: 0, unreadMessages: nil, isUnread: false, anyExpired: true, showUnreadBadge: true), 1)
        // Desktop order: unread beats expired only when the setting is on.
        XCTAssertEqual(SessionStore.badgeNumber(mentions: 0, unreadMessages: 7, isUnread: true, anyExpired: true, showUnreadBadge: false), 1)
    }

    func testNegativeMentionsAreTreatAsZero() {
        XCTAssertEqual(SessionStore.badgeNumber(mentions: -1, unreadMessages: 0, isUnread: false, anyExpired: false, showUnreadBadge: true), 0)
    }
}

@MainActor
final class SessionStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SessionStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        suiteName = nil
        defaults = nil
        super.tearDown()
    }

    private func makeStore() -> (SessionStore, RecordingBadge) {
        let badge = RecordingBadge()
        let store = SessionStore(preferences: AppPreferences(defaults: defaults), badgeSetter: badge)
        return (store, badge)
    }

    private func makeServer(id: UUID = UUID(), name: String = "Example") -> ServerConfig {
        ServerConfig(name: name, url: URL(string: "https://example.mattermost.com")!, hasSession: true).with(id: id)
    }

    // MARK: Totals + badge application

    func testInitialStateIsZeroBadge() {
        let (store, badge) = makeStore()
        XCTAssertEqual(store.totalMentions, 0)
        XCTAssertFalse(store.hasUnread)
        XCTAssertFalse(store.anyExpired)
        XCTAssertEqual(store.badgeNumber, 0)
        XCTAssertEqual(badge.sets, [0], "initial recompute applies an empty badge")
    }

    func testMentionsSumAcrossServersAndDriveBadge() {
        let (store, badge) = makeStore()
        let a = UUID()
        let b = UUID()
        store.updateMentions(serverID: a, mentionCount: 3, isUnread: true)
        store.updateMentions(serverID: b, mentionCount: 2, isUnread: true)
        XCTAssertEqual(store.totalMentions, 5)
        XCTAssertEqual(store.badgeNumber, 5)
        XCTAssertEqual(badge.sets.last, 5)
    }

    func testUnreadOnlyAppliesDotBadge() {
        let (store, _) = makeStore()
        store.updateMentions(serverID: UUID(), mentionCount: 0, isUnread: true)
        XCTAssertTrue(store.hasUnread)
        XCTAssertEqual(store.badgeNumber, 1)
    }

    func testZeroMentionReportClearsBadge() {
        let (store, _) = makeStore()
        let id = UUID()
        store.updateMentions(serverID: id, mentionCount: 4, isUnread: true)
        XCTAssertEqual(store.badgeNumber, 4)
        store.updateMentions(serverID: id, mentionCount: 0, isUnread: false)
        XCTAssertEqual(store.badgeNumber, 0)
    }

    func testNegativeMentionCountIsClamped() {
        let (store, _) = makeStore()
        store.updateMentions(serverID: UUID(), mentionCount: -5, isUnread: true)
        XCTAssertEqual(store.totalMentions, 0)
        XCTAssertEqual(store.badgeNumber, 1, "unread still applies the dot")
    }

    func testExpiredServerDrivesBadge() {
        let (store, _) = makeStore()
        let id = UUID()
        store.updateExpired(serverID: id, isExpired: true)
        XCTAssertTrue(store.anyExpired)
        XCTAssertEqual(store.badgeNumber, 1)
        store.updateExpired(serverID: id, isExpired: false)
        XCTAssertEqual(store.badgeNumber, 0)
    }

    func testMentionsBeatExpired() {
        let (store, _) = makeStore()
        let id = UUID()
        store.updateExpired(serverID: id, isExpired: true)
        store.updateMentions(serverID: id, mentionCount: 7, isUnread: false)
        XCTAssertEqual(store.badgeNumber, 7)
    }

    func testClearResetsServerState() {
        let (store, _) = makeStore()
        let id = UUID()
        store.updateMentions(serverID: id, mentionCount: 2, isUnread: true)
        store.updateExpired(serverID: id, isExpired: true)
        store.clear(serverID: id)
        XCTAssertEqual(store.states[id], nil)
        XCTAssertEqual(store.badgeNumber, 0)
    }

    func testRemoveDropsServerFromTotals() {
        let (store, _) = makeStore()
        let a = UUID(), b = UUID()
        store.updateMentions(serverID: a, mentionCount: 3, isUnread: true)
        store.updateMentions(serverID: b, mentionCount: 2, isUnread: false)
        store.remove(serverID: a)
        XCTAssertEqual(store.totalMentions, 2)
        XCTAssertFalse(store.hasUnread)
        XCTAssertEqual(store.badgeNumber, 2)
    }

    // MARK: "Show unread badge" setting (desktop defaultPreferences.showUnreadBadge, default true)

    func testShowUnreadBadgeDefaultsTrue() {
        let (store, _) = makeStore()
        XCTAssertTrue(store.showUnreadBadge)
    }

    func testShowUnreadBadgePersistsAndRecomputes() {
        let (store, badge) = makeStore()
        store.updateMentions(serverID: UUID(), mentionCount: 0, isUnread: true)
        XCTAssertEqual(store.badgeNumber, 1)

        store.showUnreadBadge = false
        XCTAssertEqual(store.badgeNumber, 0)
        XCTAssertEqual(badge.sets.last, 0)

        // A fresh store reads the persisted setting.
        let reloaded = SessionStore(preferences: AppPreferences(defaults: defaults),
                                    badgeSetter: RecordingBadge())
        XCTAssertFalse(reloaded.showUnreadBadge)
    }

    // MARK: Server removal binding (desktop AppState SERVER_REMOVED handler)

    func testObserveServerRemovalsDropsState() {
        let (store, _) = makeStore()
        let serverStore = ServerStore(preferences: AppPreferences(defaults: defaults))
        let server = makeServer()
        _ = serverStore.add(server)
        store.observeServerRemovals(from: serverStore)
        store.updateMentions(serverID: server.id, mentionCount: 4, isUnread: true)
        XCTAssertEqual(store.totalMentions, 4)

        _ = serverStore.remove(id: server.id)
        XCTAssertEqual(store.states[server.id], nil)
        XCTAssertEqual(store.badgeNumber, 0)
    }
}

private extension ServerConfig {
    func with(id: UUID) -> ServerConfig {
        ServerConfig(id: id, name: name, url: url, order: order, lastActiveAt: lastActiveAt, hasSession: hasSession)
    }
}

/// Records every badge write so tests can assert the applied values.
@MainActor
final class RecordingBadge: BadgeSettable {
    private(set) var sets: [Int] = []
    func setBadge(_ count: Int) {
        sets.append(count)
    }
}
