// T29 — the migration harness: one ordered, named chain that every store instance runs on open.
//
// GRDB's `DatabaseMigrator` supplies the ledger (`grdb_migrations` table) that makes a repeat run a
// no-op and makes a partial run resumable; `MMMigration` supplies the steps. The chain is
// deliberately not "run all DDL every time": a v2 database must not be rebuilt to be opened, and an
// upgrade must not lose rows.

import Foundation
import GRDB

struct MMMigrator: Sendable {
    /// Steps to apply, in chain order. A test may pass a prefix (e.g. `[.v1InitialSchema]`) to
    /// build a fixture at an older schema.
    let migrations: [MMMigration]

    init(_ migrations: [MMMigration] = MMMigration.allCases) {
        self.migrations = migrations.sorted { $0.version < $1.version }
    }

    /// Version this migrator brings a database to.
    var targetVersion: Int { migrations.map(\.version).max() ?? 0 }

    /// Applies every pending step to `writer` as a single GRDB migration run.
    func migrate(_ writer: some DatabaseWriter) throws {
        do {
            try grdbMigrator().migrate(writer)
        } catch let error as MMStoreError {
            throw error
        } catch {
            throw MMStoreError.migrationFailed(name: "chain", reason: error.localizedDescription)
        }
    }

    private func grdbMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        // A migration is atomic by default; keep that, and make the failure legible.
        migrator.eraseDatabaseOnSchemaChange = false
        for step in migrations {
            migrator.registerMigration(step.rawValue) { db in
                try step.apply(db)
                try db.execute(sql: "PRAGMA user_version = \(step.version)")
            }
        }
        return migrator
    }

    // MARK: - Introspection (tests, diagnostics, and the downgrade guard)

    /// Names of the steps already applied to this database, oldest first.
    static func appliedMigrations(_ db: Database) throws -> [String] {
        guard try db.tableExists("grdb_migrations") else { return [] }
        return try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
    }

    /// The schema version a database is at: the highest applied step's version, or `user_version`
    /// if the ledger is missing (a database created by an older build or by hand).
    static func schemaVersion(_ db: Database) throws -> Int {
        let applied = try appliedMigrations(db)
        if !applied.isEmpty {
            let versions = applied.compactMap { name in
                MMMigration(rawValue: name)?.version
            }
            if let maxVersion = versions.max() { return maxVersion }
            // An unknown future step name: fall back to the recorded user_version.
        }
        return try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
    }

    /// Refuses to open a store written by a newer build. Silently treating a v3 file as v2 would
    /// mean reading columns we do not know about and writing rows a v3 build cannot parse.
    static func guardAgainstDowngrade(_ reader: some DatabaseReader,
                                      supported: Int = MMMigration.currentVersion) throws {
        try checkDowngrade(found: reader.read { db in try schemaVersion(db) }, supported: supported)
    }

    /// The same guard on an already-open connection.
    ///
    /// `MMStore` uses this one and runs it on the **writer** connection: going through a
    /// `DatabaseReader` makes a `DatabasePool` open a reader before the DDL exists, and that
    /// connection then serves the first post-upgrade read from the pre-migration schema.
    static func guardAgainstDowngrade(in db: Database,
                                      supported: Int = MMMigration.currentVersion) throws {
        try checkDowngrade(found: try schemaVersion(db), supported: supported)
    }

    private static func checkDowngrade(found: Int, supported: Int) throws {
        if found > supported {
            throw MMStoreError.schemaTooNew(found: found, supported: supported)
        }
    }
}
