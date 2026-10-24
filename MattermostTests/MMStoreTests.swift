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
        XCTAssertEqual(MMMigration.currentVersion, 3, "v3 is the newest step in the chain")
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
        // All seventeen indices the DDL creates (T29-AV F7: the previous list was missing
        // `idx_team_name` and `idx_team_member_user`; the note and this test now agree with the DDL,
        // and the three that serve a later card are marked as such in `MMSchema.v1Statements`).
        let expected: [String: [String]] = [
            "post": ["idx_post_channel_window", "idx_post_root_window", "idx_post_user"],
            "channel": ["idx_channel_team", "idx_channel_name", "idx_channel_last_post"],
            "channel_member": ["idx_channel_member_recent", "idx_channel_member_unread"],
            "team": ["idx_team_name"],
            "team_member": ["idx_team_member_user"],
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

        // And the total: no index exists that neither this test nor the note accounts for, so the
        // inventory cannot drift again in the other direction (an index added to the DDL only).
        let declared = try harness.store.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sqlite_master
                 WHERE type = 'index' AND name NOT LIKE 'sqlite_autoindex%'
                """) ?? 0
        }
        XCTAssertEqual(declared, 17, "the note lists seventeen indices; the DDL must create seventeen")
        XCTAssertEqual(declared, expected.values.reduce(0) { $0 + $1.count },
                       "the table above and the database agree")
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
                                 MMMigration.v2PostMetadataAndUnread.rawValue,
                                 MMMigration.v3ServerAPIVersion.rawValue],
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
        let small = try harness.store.size()
        XCTAssertGreaterThan(small.pageSize, 0)
        XCTAssertGreaterThan(small.pageCount, 0)
        XCTAssertGreaterThan(small.fileBytes, 0)

        // T29-AV F9: this test used to end with `XCTAssertGreaterThanOrEqual(size.megabytes, 0)`,
        // which is a tautology. Assert the two relationships the type promises instead:
        // `usedBytes` is page arithmetic (never more than the pages allocated), and the file
        // genuinely grows when rows are written.
        XCTAssertEqual(small.usedBytes,
                       max(0, small.pageCount - small.freePageCount) * small.pageSize,
                       "usedBytes is (pageCount - freePageCount) * pageSize")
        XCTAssertLessThanOrEqual(small.usedBytes, small.pageCount * small.pageSize,
                                 "used pages cannot exceed allocated pages")
        XCTAssertEqual(small.megabytes, Double(small.fileBytes) / 1_048_576.0, accuracy: 1e-9)

        // A write that needs new pages must be visible in `fileBytes` (the WAL is counted too).
        try await harness.posts.upsert((2...400).map { index in
            T29Fixtures.post(id: "p\(index)", createAt: Int64(index),
                             message: String(repeating: "y", count: 1_024))
        })
        let large = try harness.store.size()
        XCTAssertGreaterThan(large.pageCount, small.pageCount,
                             "400 more 1 KB rows must allocate pages")
        XCTAssertGreaterThan(large.fileBytes, small.fileBytes,
                             "and those pages must show up on disk (main file + -wal)")
        XCTAssertGreaterThan(large.megabytes, small.megabytes)
    }

    // MARK: Server API version (ADR §5, T29-AV F5)

    func testServerAPIVersionSurvivesAReopen() async throws {
        // Nothing is recorded until a sync says so: the column exists, the accessor is honest.
        XCTAssertNil(try harness.store.serverAPIVersion())

        try await harness.store.recordServerAPIVersion("10.5.1")
        XCTAssertEqual(try harness.store.serverAPIVersion(), "10.5.1")

        let reopened = try harness.reopen()
        defer { reopened.close() }
        XCTAssertEqual(try reopened.serverAPIVersion(), "10.5.1",
                       "the recorded version is part of the file, not of the process")

        // An upgrade of the server records the new version over the old one.
        try await reopened.recordServerAPIVersion("10.6.0")
        XCTAssertEqual(try reopened.serverAPIVersion(), "10.6.0")
        XCTAssertEqual(try reopened.rowCount(in: "server"), 1,
                       "recording the version does not add a server row")
    }

    // MARK: Checkpoint (T29-AV F8)

    func testCheckpointTruncatesTheWALWhenNothingElseReads() async throws {
        try await harness.posts.upsert([T29Fixtures.post(id: "p1", createAt: 1)])
        XCTAssertGreaterThan(walBytes(), 0, "the fixture must leave something in the WAL")
        XCTAssertEqual(try harness.store.checkpoint(), .truncated)
        XCTAssertEqual(walBytes(), 0, "TRUNCATE leaves an empty WAL file")
        XCTAssertEqual(try harness.store.checkpoint(truncate: false), .passive)
        XCTAssertEqual(try MMStore.inMemory().checkpoint(), .notWAL,
                       "an in-memory database has no WAL to fold")
    }

    func testCheckpointDegradesToPassiveWhenAReaderHoldsTheWAL() async throws {
        // T29-AV F8 measured: with a live reader, TRUNCATE does not throw — SQLite waits on the busy
        // timeout for the reader to finish, which blocks the writer queue (1768.9 ms in the probe).
        // Past that wait it answers SQLITE_BUSY, which the store now catches (BUSY *and* LOCKED) and
        // retries as PASSIVE. This test uses a short busy timeout so it can prove the fallback
        // without spending five seconds doing it.
        let path = harness.directory.appendingPathComponent("reader.db").path
        let store = try MMStore.open(at: path, serverID: "server-1",
                                     serverURL: URL(string: "https://mm.invalid")!,
                                     busyTimeout: 0.2)
        defer { store.close() }
        try await store.write { db in
            try db.execute(sql: "INSERT INTO post (id, channel_id, create_at) VALUES ('p1', 'c1', 1)")
        }
        XCTAssertGreaterThan(fileBytes(at: path + "-wal"), 0)

        // A second connection holds a read snapshot open for longer than the writer's busy timeout.
        let reader = try DatabaseQueue(path: path)
        let readerHolds = ReaderSignal()
        let holdDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do {
                try reader.inTransaction(.deferred) { db -> Database.TransactionCompletion in
                    _ = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM post")
                    readerHolds.fulfill()
                    holdDone.wait()
                    return .commit
                }
            } catch {
                XCTFail("reader failed: \(error)")
                readerHolds.fulfill()
            }
        }
        XCTAssertEqual(readerHolds.wait(timeout: .now() + 5), .success,
                       "the reader never took its snapshot")
        defer { holdDone.signal() }

        let started = Date()
        let outcome = try store.checkpoint()
        let elapsed = Date().timeIntervalSince(started)
        guard case .passiveFallback(let reason) = outcome else {
            return XCTFail("expected the PASSIVE fallback under a live reader, got \(outcome)")
        }
        XCTAssertTrue(reason.lowercased().contains("lock") || reason.lowercased().contains("busy"),
                      "the reason names the SQLite failure: \(reason)")
        XCTAssertGreaterThanOrEqual(elapsed, 0.15,
                                    "TRUNCATE waited on the busy timeout before giving up (\(elapsed)s)")
        XCTAssertGreaterThan(fileBytes(at: path + "-wal"), 0,
                             "PASSIVE cannot truncate the WAL, so it is still there — that is the "
                             + "honest outcome, and the reason a \"clear space\" action can wait")
        XCTAssertEqual(try store.rowCount(in: "post"), 1, "the data is intact after the checkpoint")
        holdDone.signal()
    }

    private func walBytes() -> Int64 { fileBytes(at: harness.path + "-wal") }

    private func fileBytes(at path: String) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

/// A tiny one-shot signal for the background reader thread (XCTest's `XCTestExpectation` is
/// main-run-loop bound, and the reader must not hop to the main thread to signal).
final class ReaderSignal: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func fulfill() { semaphore.signal() }

    func wait(timeout: DispatchTime) -> DispatchTimeoutResult {
        semaphore.wait(timeout: timeout)
    }
}
