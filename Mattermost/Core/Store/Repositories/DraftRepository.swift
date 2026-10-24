// T29 — `DraftRepository`: composer drafts, one per channel and one per thread inside a channel.
//
// Shape ported from mattermost/mattermost-mobile @ v2.45.0
// (162f2560d0e1df073220f7701d5a67cc17c8abeb), app/database/schema/server/table_schemas/draft.ts and
// the draft helpers in ios/Gekidou/Sources/Gekidou/Storage/Database+Posts.swift — Apache-2.0, ported
// with attribution per docs/THIRD_PARTY_NOTICES.md.

import Foundation
import GRDB

protocol DraftRepository: Sendable {
    /// Saves (or overwrites) the draft for `(channelID, rootID)`. A draft is typed text, so it is
    /// written on every keystroke burst: this must be cheap and must not rewrite the whole channel.
    func save(_ draft: MMDraft) async throws

    /// Removes the draft for a channel (or a thread inside it). Returns `true` if a row was removed,
    /// which is what the composer uses to decide whether it needs to tell the server it cleared it.
    func delete(channelID: String, rootID: String) async throws -> Bool

    /// Removes every draft in the store (a logout / "clear local data" action).
    func deleteAll() async throws -> Int

    func draft(channelID: String, rootID: String) throws -> MMDraft?

    /// All drafts, most recently edited first.
    func drafts(limit: Int) throws -> [MMDraft]

    func count() throws -> Int
}

// MARK: - SQLite

final class SQLiteDraftRepository: DraftRepository {
    private let store: MMStore

    init(store: MMStore) {
        self.store = store
    }

    func save(_ draft: MMDraft) async throws {
        try await store.write { db in
            var values = MMRowValues(keyColumns: ["channel_id", "root_id"])
            values.set("channel_id", draft.channelId)
            values.set("root_id", draft.rootId)
            values.set("message", draft.message)
            values.set("files", MMJSONColumn.text(draft.files) ?? "[]")
            values.setJSON("metadata", draft.metadata)
            values.set("type", draft.type)
            values.set("update_at", draft.updateAt)
            // Plain last-write-wins: a draft has one writer (the composer), and the newest save is
            // by definition the truth.
            try values.executeUpsert(db, table: MMStoreTable.draft)
        }
    }

    func delete(channelID: String, rootID: String) async throws -> Bool {
        try await store.write { db in
            try db.execute(sql: "DELETE FROM draft WHERE channel_id = ? AND root_id = ?",
                           arguments: [channelID, rootID])
            return db.changesCount > 0
        }
    }

    func deleteAll() async throws -> Int {
        try await store.write { db in
            try db.execute(sql: "DELETE FROM draft")
            return db.changesCount
        }
    }

    func draft(channelID: String, rootID: String) throws -> MMDraft? {
        try store.read { db in
            try MMDraft.fetchOne(db, sql: "SELECT * FROM draft WHERE channel_id = ? AND root_id = ?",
                                 arguments: [channelID, rootID])
        }
    }

    func drafts(limit: Int) throws -> [MMDraft] {
        guard limit > 0 else { return [] }
        return try store.read { db in
            try MMDraft.fetchAll(db, sql: "SELECT * FROM draft ORDER BY update_at DESC LIMIT ?",
                                 arguments: [limit])
        }
    }

    func count() throws -> Int {
        try store.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM draft") ?? 0 }
    }
}
