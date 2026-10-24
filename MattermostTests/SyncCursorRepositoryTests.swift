import Foundation
import XCTest
@testable import Mattermost

/// T29 — the cursor round-trip that makes a resync possible: the last socket event id per server and
/// the last post id per channel, surviving a relaunch and never confusing one scope with another.
final class SyncCursorRepositoryTests: XCTestCase {

    private var harness: StoreHarness!

    override func setUpWithError() throws { harness = try StoreHarness() }
    override func tearDownWithError() throws { harness.cleanup(); harness = nil }

    func testCursorsSurviveACloseAndReopen() async throws {
        try await harness.cursors.setLastSocketEventID("event-77", serverID: "server-1", updatedAt: 1_000)
        try await harness.cursors.setLastPostID("post-5", channelID: "c1", updatedAt: 1_001)

        let reopened = try harness.reopen()
        defer { reopened.close() }
        let cursors = SQLiteSyncCursorRepository(store: reopened)
        XCTAssertEqual(try cursors.lastSocketEventID(serverID: "server-1"), "event-77")
        XCTAssertEqual(try cursors.lastPostID(channelID: "c1"), "post-5")
    }

    func testScopesDoNotCollide() async throws {
        // The same key in two scopes is two cursors, not one overwritten.
        try await harness.cursors.set("shared-key", scope: .serverSocketEvent,
                                      scopeKey: "k", updatedAt: 1)
        try await harness.cursors.set("other-value", scope: .channelLastPost,
                                      scopeKey: "k", updatedAt: 2)
        try await harness.cursors.set("thread-value", scope: .threadLastPost,
                                      scopeKey: "k", updatedAt: 3)

        XCTAssertEqual(try harness.cursors.cursor(scope: .serverSocketEvent, scopeKey: "k")?.cursor,
                       "shared-key")
        XCTAssertEqual(try harness.cursors.cursor(scope: .channelLastPost, scopeKey: "k")?.cursor,
                       "other-value")
        XCTAssertEqual(try harness.cursors.cursor(scope: .threadLastPost, scopeKey: "k")?.cursor,
                       "thread-value")
        XCTAssertEqual(try harness.store.rowCount(in: "sync_cursor"), 3)
    }

    func testAllReturnsNewestFirstWithinAScope() async throws {
        try await harness.cursors.setLastPostID("post-1", channelID: "c1", updatedAt: 100)
        try await harness.cursors.setLastPostID("post-2", channelID: "c2", updatedAt: 300)
        try await harness.cursors.setLastPostID("post-3", channelID: "c3", updatedAt: 200)

        let cursors = try harness.cursors.all(scope: .channelLastPost)
        XCTAssertEqual(cursors.map(\.scopeKey), ["c2", "c3", "c1"])
        XCTAssertEqual(cursors.first?.scope, .channelLastPost)
        XCTAssertEqual(try harness.cursors.all(scope: .serverSocketEvent).count, 0)
    }

    func testClearAllWipesEveryScope() async throws {
        try await harness.cursors.setLastSocketEventID("e", serverID: "server-1", updatedAt: 1)
        try await harness.cursors.setLastPostID("p", channelID: "c1", updatedAt: 2)
        let cleared = try await harness.cursors.clearAll()
        XCTAssertEqual(cleared, 2)
        XCTAssertEqual(try harness.store.rowCount(in: "sync_cursor"), 0)
    }

    func testUnknownScopeNameInTheTableIsIgnoredRatherThanCrashing() async throws {
        // A row written by an older/newer build with an unknown scope string must not crash a read,
        // and must not be handed to a caller that asked for a scope it does not belong to.
        try await harness.store.write { db in
            try db.execute(sql: """
                INSERT INTO sync_cursor (scope, scope_key, cursor, updated_at)
                VALUES ('something.else', 'k', 'v', 1)
                """)
        }
        XCTAssertEqual(try harness.cursors.all(scope: .serverSocketEvent).count, 0)
        XCTAssertEqual(try harness.store.rowCount(in: "sync_cursor"), 1,
                       "the unknown row is left alone, not destroyed")
    }
}
