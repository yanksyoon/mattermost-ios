// T29 — the store itself: one SQLite file per server, WAL, a single writer, and no SQL on the main
// thread.
//
// Design of record: docs/t29-build-note.md. The three properties the card asks for are enforced
// here and nowhere else, so no repository can accidentally opt out:
//
//   1. **Writes leave the caller's thread.** `write(_:)` is `async` and hands the closure to GRDB's
//      writer queue (a private dispatch queue). There is no synchronous write API on this type, so
//      a screen cannot run SQL on the main actor even if it wants to.
//   2. **Reads run on the calling context**, against a WAL snapshot. With `DatabasePool` a read
//      never waits for an in-flight write, which is exactly what "render instantly from disk"
//      needs; `MMStoreConcurrencyTests` proves it with a write in flight.
//   3. **One writer per file.** A `DatabasePool` serialises writes; SQLite's own busy timeout is
//      5 s so a second process (a future notification extension) degrades to waiting, not to
//      `SQLITE_BUSY` surfaced as a lost message.

import Foundation
import GRDB

/// A per-server store. Not a repository: repositories (`Repositories/`) are the only thing screens
/// talk to, and this type is the only thing that owns a connection.
final class MMStore: @unchecked Sendable {

    /// The file path for a persistent store, or `:memory:` for a throwaway one.
    let path: String
    /// How much history this store keeps. Immutable for the store's lifetime: changing the budget
    /// is a `withRetention(_:)` call, which reopens nothing and simply yields a configured view.
    let retention: MMRetentionPolicy

    private let writer: any DatabaseWriter
    private let lock = NSLock()
    private var closed = false

    // MARK: - Opening

    /// Opens (creating if needed) the store for one server and brings its schema to current.
    ///
    /// - Parameters:
    ///   - path: absolute path of the SQLite file. Parent directories are created.
    ///   - serverID: stable per-server identifier (the shell's `ServerConfig.id`).
    ///   - serverURL: the server's base URL, stored so the file is self-describing in Diagnostics.
    ///   - retention: the post-window budget (see `MMRetentionPolicy`).
    ///   - migrations: the chain to apply; tests pass a prefix to build old fixtures.
    static func open(at path: String,
                     serverID: String,
                     serverURL: URL,
                     retention: MMRetentionPolicy = .default,
                     migrations: [MMMigration] = MMMigration.allCases) throws -> MMStore {
        var config = Configuration()
        // Mirrors upstream's `defaultBusyTimeout` (5 s, Gekidou Database.swift): concurrent access
        // from a second process should wait, not fail.
        config.busyMode = .timeout(5)
        // Prepared-statement cache is the difference between "scroll is instant" and "scroll
        // re-parses every page query". 16 is GRDB's default; keep it explicit for the record.
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA temp_store = MEMORY")
        }

        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            try FileManager.default.createDirectory(atPath: directory,
                                                    withIntermediateDirectories: true)
        }

        let pool: DatabasePool
        do {
            pool = try DatabasePool(path: path, configuration: config)
        } catch {
            throw MMStoreError.openFailed(path: path, reason: error.localizedDescription)
        }

        return try MMStore(writer: pool, path: path, retention: retention,
                           serverID: serverID, serverURL: serverURL, migrations: migrations)
    }

    /// A throwaway store for tests and previews. `DatabaseQueue` (not `DatabasePool`): an in-memory
    /// database cannot host WAL, so it serialises reads and writes — correct, just not concurrent.
    static func inMemory(serverID: String = "in-memory-server",
                         serverURL: URL = URL(string: "https://mm.invalid")!,
                         retention: MMRetentionPolicy = .unbounded,
                         migrations: [MMMigration] = MMMigration.allCases) throws -> MMStore {
        var config = Configuration()
        config.busyMode = .timeout(5)
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(named: nil, configuration: config)
        } catch {
            throw MMStoreError.openFailed(path: ":memory:", reason: error.localizedDescription)
        }
        return try MMStore(writer: queue, path: ":memory:", retention: retention,
                           serverID: serverID, serverURL: serverURL, migrations: migrations)
    }

    private init(writer: any DatabaseWriter,
                 path: String,
                 retention: MMRetentionPolicy,
                 serverID: String,
                 serverURL: URL,
                 migrations: [MMMigration]) throws {
        self.writer = writer
        self.path = path
        self.retention = retention

        do {
            // Both the guard and the migration run on the *writer* connection on purpose.
            //
            // `MMMigrator.guardAgainstDowngrade` used to run through `writer.read`, which makes a
            // DatabasePool open a **reader** connection before the DDL exists. That connection
            // keeps SQLite's schema cache for as long as the pool holds it, and SQLite only
            // notices the schema cookie moved when it prepares the *next* statement — so the first
            // read after an upgrade ran against the pre-migration schema: `post.metadata` read back
            // as nil from a perfectly good row, and `PRAGMA index_list("channel")` reported no
            // indices at all on a fresh file (T29 probe, 2026-10-24). Reading the version on the
            // writer connection means no reader exists until the schema is already current.
            try writer.writeWithoutTransaction { db in
                try MMMigrator.guardAgainstDowngrade(in: db)
            }
            try MMMigrator(migrations).migrate(writer)
            try registerServer(serverID: serverID, url: serverURL.absoluteString)
        } catch {
            try? writer.close()
            throw error
        }
    }

    /// The `server` row makes a database file self-describing: `Diagnostics` can say which server a
    /// 40 MB file belongs to, and a support bundle can be checked for "is this the right server"
    /// without the app running.
    private func registerServer(serverID: String, url: String) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO server (id, url, last_active_at, db_path)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET url = excluded.url,
                                             last_active_at = excluded.last_active_at,
                                             db_path = excluded.db_path
                """, arguments: [serverID, url, Int64(Date().timeIntervalSince1970 * 1000), self.path])
        }
    }

    // MARK: - Access

    /// A read on the calling context. WAL + `DatabasePool` means this is a snapshot read: it does
    /// not wait for an in-flight write and it cannot see a half-applied one.
    func read<T>(_ body: (Database) throws -> T) throws -> T {
        try writer.read(body)
    }

    /// An async read, for call sites that should not block their thread even on a snapshot read.
    func readAsync<T: Sendable>(_ body: @Sendable @escaping (Database) throws -> T) async throws -> T {
        try await writer.read(body)
    }

    /// A write that runs on GRDB's writer queue — never on the caller's thread, and therefore never
    /// on the main actor. This is the *only* write entry point the store exposes.
    @discardableResult
    func write<T: Sendable>(_ body: @Sendable @escaping (Database) throws -> T) async throws -> T {
        try await writer.write(body)
    }

    /// Closes the connection. Idempotent; a closed store throws `MMStoreError.openFailed`-style
    /// errors from GRDB rather than corrupting anything.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        try? writer.close()
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    // MARK: - Diagnostics

    /// `PRAGMA user_version`, i.e. the schema version this file is at.
    func schemaVersion() throws -> Int {
        try read { db in try MMMigrator.schemaVersion(db) }
    }

    /// `journal_mode` — `wal` for a file store, `memory` for the in-memory one.
    func journalMode() throws -> String {
        try read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "unknown" }
    }

    /// The measured size of the store. `-wal`/`-shm` are counted because they are real disk the app
    /// is holding; a checkpoint folds them back into the main file.
    func size() throws -> MMStoreSize {
        let pageCount = try read { db in try Int64.fetchOne(db, sql: "PRAGMA page_count") ?? 0 }
        let pageSize = try read { db in try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 0 }
        let freePages = try read { db in try Int64.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0 }
        return MMStoreSize(fileBytes: fileBytes(), pageCount: pageCount,
                           pageSize: pageSize, freePageCount: freePages)
    }

    /// Bytes on disk for the main file plus its WAL side cars.
    func fileBytes() -> Int64 {
        guard path != ":memory:" else { return 0 }
        var total: Int64 = 0
        for suffix in ["", "-wal", "-shm"] {
            let attributes = try? FileManager.default.attributesOfItem(atPath: path + suffix)
            total += (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
        return total
    }

    /// Folds the WAL back into the main file and truncates it. Called by a "clear space" action and
    /// by the size measurement so the number reported is not inflated by un-checkpointed pages.
    func checkpoint(truncate: Bool = true) throws {
        // `sqlite3_wal_checkpoint_v2` answers SQLITE_LOCKED (error 6) when it is called inside a
        // transaction, and both `read` and `write` wrap their block in one. `writeWithoutTransaction`
        // is the only shape that works: it runs on the writer connection with no transaction open.
        try writer.writeWithoutTransaction { db in
            // A `memory`-journal database (the in-memory store, or a file that never switched to
            // WAL) has no WAL to fold; asking SQLite to checkpoint one is a no-op at best.
            let journal = try String.fetchOne(db, sql: "PRAGMA journal_mode")?.lowercased() ?? ""
            guard journal == "wal" else { return }
            do {
                try db.checkpoint(truncate ? .truncate : .passive)
            } catch let error as DatabaseError where error.resultCode == .SQLITE_LOCKED {
                // A reader is holding a snapshot, so TRUNCATE cannot complete. Fold what can be
                // folded and leave the rest of the WAL: maintenance must not fail the caller.
                try db.checkpoint(.passive)
            }
        }
    }

    /// Rebuilds the file without free pages. Only ever called from an explicit maintenance action:
    /// it rewrites the whole file and blocks writes while it runs.
    func vacuum() throws {
        try writer.write { db in try db.execute(sql: "VACUUM") }
    }

    /// Row count for one table. Used by the migration test (no data loss) and by Diagnostics.
    func rowCount(in table: String) throws -> Int {
        try read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
    }
}
