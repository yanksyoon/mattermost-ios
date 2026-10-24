// T29 — `SyncCursorRepository`: "where did I get to", per server and per channel.
//
// Upstream keeps the same information in two places — its `System` key/value table (last socket
// event, current channel) and the `PostsInChannel` window rows (earliest/latest post). T29 uses one
// explicit cursor table: a cursor is a single (scope, key) → value fact, and having one place to
// read it from is what lets a resync ask "what did I already apply?" without scanning post windows.

import Foundation
import GRDB

protocol SyncCursorRepository: Sendable {
    func set(_ cursor: String, scope: MMSyncCursorScope, scopeKey: String, updatedAt: Int64) async throws
    func cursor(scope: MMSyncCursorScope, scopeKey: String) throws -> MMSyncCursor?
    func all(scope: MMSyncCursorScope) throws -> [MMSyncCursor]
    func clear(scope: MMSyncCursorScope, scopeKey: String) async throws -> Bool
    func clearAll() async throws -> Int

    // Typed conveniences — the two the card names explicitly.
    func setLastSocketEventID(_ eventID: String, serverID: String, updatedAt: Int64) async throws
    func lastSocketEventID(serverID: String) throws -> String?
    func setLastPostID(_ postID: String, channelID: String, updatedAt: Int64) async throws
    func lastPostID(channelID: String) throws -> String?
}

// MARK: - SQLite

final class SQLiteSyncCursorRepository: SyncCursorRepository {
    private let store: MMStore

    init(store: MMStore) {
        self.store = store
    }

    func set(_ cursor: String, scope: MMSyncCursorScope, scopeKey: String, updatedAt: Int64) async throws {
        try await store.write { db in
            var values = MMRowValues(keyColumns: ["scope", "scope_key"])
            values.set("scope", scope.rawValue)
            values.set("scope_key", scopeKey)
            values.set("cursor", cursor)
            values.set("updated_at", updatedAt)
            try values.executeUpsert(db, table: MMStoreTable.syncCursor)
        }
    }

    func cursor(scope: MMSyncCursorScope, scopeKey: String) throws -> MMSyncCursor? {
        try store.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT scope, scope_key, cursor, updated_at FROM sync_cursor
                 WHERE scope = ? AND scope_key = ?
                """, arguments: [scope.rawValue, scopeKey]) else { return nil }
            return Self.cursor(from: row)
        }
    }

    func all(scope: MMSyncCursorScope) throws -> [MMSyncCursor] {
        try store.read { db in
            try Row.fetchAll(db, sql: """
                SELECT scope, scope_key, cursor, updated_at FROM sync_cursor
                 WHERE scope = ? ORDER BY updated_at DESC
                """, arguments: [scope.rawValue]).map(Self.cursor(from:))
        }
    }

    func clear(scope: MMSyncCursorScope, scopeKey: String) async throws -> Bool {
        try await store.write { db in
            try db.execute(sql: "DELETE FROM sync_cursor WHERE scope = ? AND scope_key = ?",
                           arguments: [scope.rawValue, scopeKey])
            return db.changesCount > 0
        }
    }

    func clearAll() async throws -> Int {
        try await store.write { db in
            try db.execute(sql: "DELETE FROM sync_cursor")
            return db.changesCount
        }
    }

    // MARK: Typed conveniences

    func setLastSocketEventID(_ eventID: String, serverID: String, updatedAt: Int64) async throws {
        try await set(eventID, scope: .serverSocketEvent, scopeKey: serverID, updatedAt: updatedAt)
    }

    func lastSocketEventID(serverID: String) throws -> String? {
        try cursor(scope: .serverSocketEvent, scopeKey: serverID)?.cursor
    }

    func setLastPostID(_ postID: String, channelID: String, updatedAt: Int64) async throws {
        try await set(postID, scope: .channelLastPost, scopeKey: channelID, updatedAt: updatedAt)
    }

    func lastPostID(channelID: String) throws -> String? {
        try cursor(scope: .channelLastPost, scopeKey: channelID)?.cursor
    }

    private static func cursor(from row: Row) -> MMSyncCursor {
        let r = MMRow(row)
        return MMSyncCursor(scope: MMSyncCursorScope(rawValue: r.string("scope")) ?? .serverSocketEvent,
                            scopeKey: r.string("scope_key"),
                            cursor: r.string("cursor"),
                            updatedAt: r.int64("updated_at"))
    }
}
