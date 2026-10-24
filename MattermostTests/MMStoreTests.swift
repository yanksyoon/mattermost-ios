import Foundation
import XCTest
import GRDB
@testable import Mattermost

/// T29 — the store's own contract: what a fresh file looks like, that the schema is at the version
/// this build claims, that the indices the queries need exist, and that reopening/downgrading
/// behaves.
final class MMStoreTests: XCTestCase {

    private var harness: StoreHarness!

    override func setUpWithError() throws {
        harness = try StoreHarness()
    }

    override func tearDownWithError() throws {
        harness.cleanup()
        harness = nil
    }

    // MARK: Schema

    func testFreshStoreIsAtCurrentSchemaVersion() throws {
        XCTAssertEqual(try harness.store.schemaVersion(), MMMigration.currentVersion)
        XCTAssertEqual(MMMigration.currentVersion, 2, "v2 is the newest step in the chain")
        let userVersion = try harness.store.read { db in
            try Int.fetchOne(db, sql: "PRAGMA user_version")
        }
        XCTAssertEqual(userVersion, MMMigration.currentVersion,
                       "PRAGMA user_version mirrors the chain, for external sqlite3 inspection")
    }

    func testEveryTableTheCardRequiresExists() throws {
        let required = ["server", "team", "channel", "channel_member", "user", "post",
                        "post_reaction", "file_info", "draft", "sync_cursor", "preference"]
        for table in required {
            XCTAssertTrue(try harness.store.read { db in try db.tableExists(table) },
                          "missing table \(table)")
        }
    }

    func testIndicesTheQueriesNeedExist() throws {
        let expected: [String: [String]] = [
            "post": ["idx_post_channel_window", "idx_post_root_window", "idx_post_user"],
            "channel": ["idx_channel_team", "idx_channel_name", "idx_channel_last_post"],
            "channel_member": ["idx_channel_member_recent", "idx_channel_member_unread"],
            "post_reaction": ["idx_reaction_post", "idx_reaction_user"],
            "file_info": ["idx_file_post"],
            "user": ["idx_user_username"],
            "draft": ["idx_draft_update_at"],
            "preference": ["idx_preference_lookup"],
            "server": ["idx_server_url"],
        ]
        for (table, indexNames) in expected.sorted(by: { $0.key < $1.key }) {
            // `sqlite_master` is the ground truth; GRDB's `indexes(on:)` also reports what the
            // query planner can actually see. Both are asserted so a "declared but invisible"
            // index cannot pass.
            let actual = try harness.store.read { db in
                try db.indexes(on: table, in: "main").map(\.name)
            }
            let raw = try harness.store.read { db in
                try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ? ORDER BY name",
                                    arguments: [table])
            }
            for indexName in indexNames {
                XCTAssertTrue(actual.contains(indexName),
                              "\(table) is missing index \(indexName) (grdb \(actual), sqlite_master \(raw))")
                XCTAssertTrue(raw.contains(indexName),
                              "\(table) index \(indexName) is not in sqlite_master (\(raw))")
            }
        }
    }

    func testSchemaUsesWALForFileStores() throws {
        XCTAssertEqual(try harness.store.journalMode().lowercased(), "wal",
                       "a file store must be WAL so reads do not block writers")
        let memory = try MMStore.inMemory()
        XCTAssertNotEqual(try memory.journalMode().lowercased(), "wal")
        memory.close()
    }

    func testServerRowMakesTheFileSelfDescribing() throws {
        let rows = try harness.store.read { db in
            try Row.fetchAll(db, sql: "SELECT id, url, db_path FROM server")
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["id"] as String?, "server-1")
        XCTAssertEqual(rows[0]["url"] as String?, "https://mm.invalid")
        XCTAssertEqual(rows[0]["db_path"] as String?, harness.path)
    }

    func testInMemoryStoreHasNoFileButFullSchema() throws {
        let memory = try MMStore.inMemory()
        defer { memory.close() }
        XCTAssertEqual(try memory.schemaVersion(), MMMigration.currentVersion)
        XCTAssertEqual(memory.fileBytes(), 0)
        XCTAssertTrue(try memory.read { db in try db.tableExists("post") })
    }

    // MARK: Reopen / upgrade / downgrade

    func testReopeningDoesNotReapplyMigrationsOrLoseRows() async throws {
        try await harness.posts.upsert([T29Fixtures.post(id: "p1", createAt: 1)])
        let reopened = try harness.reopen()
        defer { reopened.close() }

        XCTAssertEqual(try reopened.schemaVersion(), MMMigration.currentVersion)
        let applied = try reopened.read { db in try MMMigrator.appliedMigrations(db) }
        XCTAssertEqual(applied, [MMMigration.v1InitialSchema.rawValue,
                                 MMMigration.v2PostMetadataAndUnread.rawValue],
                       "the ledger records each step exactly once")
        let count = try reopened.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM post") }
        XCTAssertEqual(count, 1, "rows survive a reopen")
    }

    func testOpeningAFileWrittenByANewerBuildIsRefused() async throws {
        // Simulate a rollback: the file keeps a v99 ledger from a future build.
        try await harness.store.write { db in
            try db.execute(sql: "PRAGMA user_version = 99")
            try db.execute(sql: "DELETE FROM grdb_migrations")
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v99_from_the_future')")
        }
        harness.store.close()

        XCTAssertThrowsError(
            try MMStore.open(at: harness.path, serverID: "server-1",
                             serverURL: URL(string: "https://mm.invalid")!)) { error in
            guard case MMStoreError.schemaTooNew(let found, let supported) = error else {
                return XCTFail("expected schemaTooNew, got \(error)")
            }
            XCTAssertEqual(found, 99)
            XCTAssertEqual(supported, MMMigration.currentVersion)
        }
    }

    func testCloseIsIdempotent() throws {
        let store = try MMStore.open(at: harness.directory.appendingPathComponent("second.db").path,
                                     serverID: "server-2",
                                     serverURL: URL(string: "https://mm.invalid")!)
        store.close()
        store.close()
        XCTAssertTrue(store.isClosed)
    }

    func testStoreSizeReportsPagesAndFileBytes() async throws {
        try await harness.posts.upsert([
            T29Fixtures.post(id: "p1", createAt: 1, message: String(repeating: "x", count: 512)),
        ])
        try harness.store.checkpoint()
        let size = try harness.store.size()
        XCTAssertGreaterThan(size.pageSize, 0)
        XCTAssertGreaterThan(size.pageCount, 0)
        XCTAssertGreaterThan(size.fileBytes, 0)
        XCTAssertGreaterThanOrEqual(size.megabytes, 0)
    }
}
