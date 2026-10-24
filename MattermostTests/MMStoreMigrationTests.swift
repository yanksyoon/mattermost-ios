import Foundation
import XCTest
import GRDB
@testable import Mattermost

/// T29 — "migration test proves an older schema upgrades without data loss".
///
/// The fixture is a real v1 database: it is created by running only the v1 step of this build's own
/// chain, then seeded with rows written by v1-era SQL (no `metadata`, no `manually_unread`, no
/// `urgent_mention_count`). The test then reopens it with the current chain and checks every row.
final class MMStoreMigrationTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("t29-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var path: String { directory.appendingPathComponent("app.db").path }

    // MARK: - Fixture

    /// Creates a database at schema v1 and fills it the way a v1 build would have.
    private func makeV1Fixture() async throws {
        let store = try MMStore.open(at: path, serverID: "server-1",
                                     serverURL: URL(string: "https://mm.invalid")!,
                                     migrations: [.v1InitialSchema])
        XCTAssertEqual(try store.schemaVersion(), 1)
        try await store.write { db in
            try db.execute(sql: """
                INSERT INTO team (id, name, display_name) VALUES ('team-1', 'core', 'Core Team')
                """)
            try db.execute(sql: """
                INSERT INTO channel (id, team_id, name, display_name, type, last_post_at, total_msg_count)
                VALUES ('channel-1', 'team-1', 'town-square', 'Town Square', 'O', 4000, 12)
                """)
            // v1 channel_member has neither manually_unread nor urgent_mention_count.
            try db.execute(sql: """
                INSERT INTO channel_member (channel_id, user_id, roles, last_viewed_at, msg_count,
                                            mention_count, last_update_at, is_unread, notify_props)
                VALUES ('channel-1', 'user-1', 'channel_user', 3000, 4, 2, 3000, 1, '{}')
                """)
            try db.execute(sql: """
                INSERT INTO user (id, username, email, update_at) VALUES ('user-1', 'ada', 'ada@mm.invalid', 10)
                """)
            // v1 post has no `metadata` column.
            try db.execute(sql: """
                INSERT INTO post (id, channel_id, user_id, root_id, message, props, file_ids,
                                  create_at, update_at, delete_at)
                VALUES ('post-1', 'channel-1', 'user-1', '', 'pre-migration message', '{}', '[]',
                        1000, 1000, 0)
                """)
            try db.execute(sql: """
                INSERT INTO post_reaction (post_id, user_id, emoji_name, create_at)
                VALUES ('post-1', 'user-2', 'thumbsup', 1100)
                """)
            try db.execute(sql: """
                INSERT INTO file_info (id, post_id, name, extension, mime_type, size)
                VALUES ('file-1', 'post-1', 'diagram.png', 'png', 'image/png', 2048)
                """)
            try db.execute(sql: """
                INSERT INTO draft (channel_id, root_id, message, files, update_at)
                VALUES ('channel-1', '', 'unsent draft', '[]', 5000)
                """)
            try db.execute(sql: """
                INSERT INTO sync_cursor (scope, scope_key, cursor, updated_at)
                VALUES ('server.socket_event_id', 'server-1', 'event-42', 6000)
                """)
            try db.execute(sql: """
                INSERT INTO preference (user_id, category, name, value)
                VALUES ('user-1', 'theme', 'theme', '{"type":"MM-dark"}')
                """)
        }
        store.close()
    }

    // MARK: - Tests

    func testV1FixtureUpgradesToCurrentWithoutDataLoss() async throws {
        try await makeV1Fixture()

        let store = try MMStore.open(at: path, serverID: "server-1",
                                     serverURL: URL(string: "https://mm.invalid")!)
        defer { store.close() }

        XCTAssertEqual(try store.schemaVersion(), MMMigration.currentVersion)
        XCTAssertEqual(try store.read { db in try Int.fetchOne(db, sql: "PRAGMA user_version") },
                       MMMigration.currentVersion)
        let applied = try store.read { db in try MMMigrator.appliedMigrations(db) }
        XCTAssertEqual(applied, [MMMigration.v1InitialSchema.rawValue,
                                 MMMigration.v2PostMetadataAndUnread.rawValue,
                                 MMMigration.v3ServerAPIVersion.rawValue])

        // Every pre-existing row is still there, with the same values.
        XCTAssertEqual(try store.rowCount(in: "team"), 1)
        XCTAssertEqual(try store.rowCount(in: "channel"), 1)
        XCTAssertEqual(try store.rowCount(in: "channel_member"), 1)
        XCTAssertEqual(try store.rowCount(in: "user"), 1)
        XCTAssertEqual(try store.rowCount(in: "post"), 1)
        XCTAssertEqual(try store.rowCount(in: "post_reaction"), 1)
        XCTAssertEqual(try store.rowCount(in: "file_info"), 1)
        XCTAssertEqual(try store.rowCount(in: "draft"), 1)
        XCTAssertEqual(try store.rowCount(in: "sync_cursor"), 1)
        XCTAssertEqual(try store.rowCount(in: "preference"), 1)

        let post = try SQLitePostRepository(store: store).post("post-1")
        XCTAssertEqual(post?.message, "pre-migration message")
        XCTAssertEqual(post?.createAt, 1000)
        XCTAssertNil(post?.metadata, "the new column starts NULL for pre-existing rows")

        let member = try SQLiteChannelRepository(store: store)
            .membership(channelID: "channel-1", userID: "user-1")
        XCTAssertEqual(member?.msgCount, 4)
        XCTAssertEqual(member?.mentionCount, 2)
        XCTAssertFalse(member?.manuallyUnread ?? true, "new column defaults to 0")
        XCTAssertEqual(member?.urgentMentionCount, 0)
        XCTAssertEqual(try SQLiteChannelRepository(store: store)
                        .unread(channelID: "channel-1", userID: "user-1").messageCount, 4)

        XCTAssertEqual(try SQLiteDraftRepository(store: store)
                        .draft(channelID: "channel-1", rootID: "")?.message, "unsent draft")
        XCTAssertEqual(try SQLiteSyncCursorRepository(store: store)
                        .lastSocketEventID(serverID: "server-1"), "event-42")
        XCTAssertEqual(try SQLitePreferenceRepository(store: store)
                        .value(userID: "user-1", category: "theme", name: "theme"),
                       "{\"type\":\"MM-dark\"}")
        XCTAssertEqual(try SQLitePostRepository(store: store).reactions(postID: "post-1").count, 1)
        XCTAssertEqual(try SQLitePostRepository(store: store).files(postID: "post-1").count, 1)
    }

    func testUpgradedSchemaAcceptsWritesToTheNewColumns() async throws {
        try await makeV1Fixture()
        let store = try MMStore.open(at: path, serverID: "server-1",
                                     serverURL: URL(string: "https://mm.invalid")!)
        defer { store.close() }
        let posts = SQLitePostRepository(store: store)
        let channels = SQLiteChannelRepository(store: store)

        var post = T29Fixtures.post(id: "post-2", createAt: 2000)
        post.metadata = .object(["priority": .object(["priority": .string("urgent")])])
        try await posts.upsert([post])
        XCTAssertEqual(try posts.post("post-2")?.metadata,
                       .object(["priority": .object(["priority": .string("urgent")])]))

        try await channels.upsertMembership([
            T29Fixtures.member(channelID: "channel-1", msgCount: 0, urgentMentionCount: 1,
                               manuallyUnread: true),
        ])
        let member = try channels.membership(channelID: "channel-1", userID: "user-1")
        XCTAssertEqual(member?.manuallyUnread, true)
        XCTAssertEqual(member?.urgentMentionCount, 1)
        XCTAssertTrue(try channels.unread(channelID: "channel-1", userID: "user-1").isUnread,
                      "manually unread counts as unread even with msg_count 0")
    }

    /// T29-AV F5 / ADR §5: a v1 (and a v2) file upgraded to current gets `server_api_version`, reads
    /// it back as "not recorded" rather than as a fake value, and keeps a recorded value across a
    /// reopen.
    func testServerAPIVersionIsAddedByTheUpgradeAndSurvivesAReopen() async throws {
        try await makeV1Fixture()

        let upgraded = try MMStore.open(at: path, serverID: "server-1",
                                        serverURL: URL(string: "https://mm.invalid")!)
        XCTAssertNil(try upgraded.serverAPIVersion(),
                     "the v3 step adds the column with '', and the accessor reports that as unrecorded")

        try await upgraded.recordServerAPIVersion("9.11.2")
        XCTAssertEqual(try upgraded.serverAPIVersion(), "9.11.2")
        upgraded.close()

        let reopened = try MMStore.open(at: path, serverID: "server-1",
                                        serverURL: URL(string: "https://mm.invalid")!)
        defer { reopened.close() }
        XCTAssertEqual(try reopened.schemaVersion(), MMMigration.currentVersion)
        XCTAssertEqual(try reopened.serverAPIVersion(), "9.11.2")
        XCTAssertEqual(try reopened.rowCount(in: "server"), 1,
                       "the upgrade does not duplicate the server identity row")
    }

    /// The v2 half of the same fixture: a file that stopped at v2 (the schema da6dec5 shipped) must
    /// also reach v3 and record a version.
    func testV2FixtureUpgradesToV3AndRecordsAVersion() async throws {
        let store = try MMStore.open(at: path, serverID: "server-1",
                                     serverURL: URL(string: "https://mm.invalid")!,
                                     migrations: [.v1InitialSchema, .v2PostMetadataAndUnread])
        XCTAssertEqual(try store.schemaVersion(), 2)
        let v2Columns = try store.read { db in try db.columns(in: "server").map(\.name) }
        XCTAssertFalse(v2Columns.contains("server_api_version"), "v2 has no such column at all")
        store.close()

        let upgraded = try MMStore.open(at: path, serverID: "server-1",
                                        serverURL: URL(string: "https://mm.invalid")!)
        defer { upgraded.close() }
        XCTAssertEqual(try upgraded.schemaVersion(), 3)
        try await upgraded.recordServerAPIVersion("10.0.0")
        XCTAssertEqual(try upgraded.serverAPIVersion(), "10.0.0")
    }

    func testMigrationIsIdempotentAcrossReopens() async throws {
        try await makeV1Fixture()
        for _ in 0..<3 {
            let store = try MMStore.open(at: path, serverID: "server-1",
                                         serverURL: URL(string: "https://mm.invalid")!)
            XCTAssertEqual(try store.schemaVersion(), MMMigration.currentVersion)
            XCTAssertEqual(try store.rowCount(in: "post"), 1)
            XCTAssertEqual(try store.rowCount(in: "preference"), 1)
            let applied = try store.read { db in try MMMigrator.appliedMigrations(db) }
            XCTAssertEqual(applied.count, MMMigration.allCases.count)
            store.close()
        }
    }
}
