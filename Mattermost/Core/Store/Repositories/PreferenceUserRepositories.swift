// T29 — `PreferenceRepository` and `UserRepository`.
//
// Preference shapes ported from mattermost/mattermost-mobile @ v2.45.0
// (162f2560d0e1df073220f7701d5a67cc17c8abeb), table_schemas/preference.ts and
// ios/Gekidou/Sources/Gekidou/Storage/Database+Preferences.swift; user lookups from
// Database+Users.swift (username prefix search for @-autocomplete, `/users/ids` batching).
// Apache-2.0, ported with attribution per docs/THIRD_PARTY_NOTICES.md.

import Foundation
import GRDB

// MARK: - Preferences

protocol PreferenceRepository: Sendable {
    /// Upserts preference rows. The API returns and accepts them in batches, so this is a batch too.
    func upsert(_ preferences: [MMPreference]) async throws

    /// Every preference in a category (`display_settings`, `sidebar_settings`, `notifications`, …).
    func preferences(userID: String, category: String) throws -> [MMPreference]

    /// One preference value — the shape a theme or a setting actually needs.
    func value(userID: String, category: String, name: String) throws -> String?

    func delete(userID: String, category: String, name: String) async throws -> Bool
    func deleteAll(userID: String) async throws -> Int
    func count() throws -> Int
}

final class SQLitePreferenceRepository: PreferenceRepository {
    private let store: MMStore

    init(store: MMStore) {
        self.store = store
    }

    func upsert(_ preferences: [MMPreference]) async throws {
        guard !preferences.isEmpty else { return }
        try await store.write { db in
            for preference in preferences {
                var values = MMRowValues(keyColumns: ["user_id", "category", "name"])
                values.set("user_id", preference.userId)
                values.set("category", preference.category)
                values.set("name", preference.name)
                values.set("value", preference.value)
                try values.executeUpsert(db, table: MMStoreTable.preference)
            }
        }
    }

    func preferences(userID: String, category: String) throws -> [MMPreference] {
        try store.read { db in
            try MMPreference.fetchAll(db, sql: """
                SELECT * FROM preference WHERE user_id = ? AND category = ? ORDER BY name ASC
                """, arguments: [userID, category])
        }
    }

    func value(userID: String, category: String, name: String) throws -> String? {
        try store.read { db in
            try String.fetchOne(db, sql: """
                SELECT value FROM preference WHERE user_id = ? AND category = ? AND name = ?
                """, arguments: [userID, category, name])
        }
    }

    func delete(userID: String, category: String, name: String) async throws -> Bool {
        try await store.write { db in
            try db.execute(sql: """
                DELETE FROM preference WHERE user_id = ? AND category = ? AND name = ?
                """, arguments: [userID, category, name])
            return db.changesCount > 0
        }
    }

    func deleteAll(userID: String) async throws -> Int {
        try await store.write { db in
            try db.execute(sql: "DELETE FROM preference WHERE user_id = ?", arguments: [userID])
            return db.changesCount
        }
    }

    func count() throws -> Int {
        try store.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM preference") ?? 0 }
    }
}

// MARK: - Users

protocol UserRepository: Sendable {
    func upsert(_ users: [MMUser]) async throws
    func user(_ userID: String) throws -> MMUser?
    /// Batch fetch for the `/users/ids` case: one query, not one per id.
    func users(ids: [String]) throws -> [MMUser]
    /// `@`-autocomplete: username prefix match, case-insensitive, ordered like the API's.
    func searchUsers(usernamePrefix: String, limit: Int) throws -> [MMUser]
    func count() throws -> Int
}

final class SQLiteUserRepository: UserRepository {
    private let store: MMStore

    init(store: MMStore) {
        self.store = store
    }

    func upsert(_ users: [MMUser]) async throws {
        guard !users.isEmpty else { return }
        try await store.write { db in
            for user in users {
                var values = MMRowValues()
                values.set("id", user.id)
                values.set("username", user.username)
                values.set("email", user.email)
                values.set("first_name", user.firstName)
                values.set("last_name", user.lastName)
                values.set("nickname", user.nickname)
                values.set("update_at", user.updateAt)
                values.set("delete_at", user.deleteAt)
                try values.executeUpsert(db, table: MMStoreTable.user, versionColumn: "update_at")
            }
        }
    }

    func user(_ userID: String) throws -> MMUser? {
        try store.read { db in
            try MMUser.fetchOne(db, sql: "SELECT * FROM user WHERE id = ?", arguments: [userID])
        }
    }

    func users(ids: [String]) throws -> [MMUser] {
        guard !ids.isEmpty else { return [] }
        return try store.read { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
            return try MMUser.fetchAll(db, sql: "SELECT * FROM user WHERE id IN (\(placeholders))",
                                       arguments: StatementArguments(ids))
        }
    }

    func searchUsers(usernamePrefix: String, limit: Int) throws -> [MMUser] {
        guard limit > 0 else { return [] }
        let prefix = usernamePrefix.hasPrefix("@")
            ? String(usernamePrefix.dropFirst())
            : usernamePrefix
        guard !prefix.isEmpty else { return [] }
        return try store.read { db in
            // Case-insensitive on both sides so `Ada` matches `ada`. A leading-wildcard-free LIKE
            // can still use `idx_user_username`.
            try MMUser.fetchAll(db, sql: """
                SELECT * FROM user
                 WHERE LOWER(username) LIKE LOWER(?) || '%'
                 ORDER BY username ASC
                 LIMIT ?
                """, arguments: [prefix, limit])
        }
    }

    func count() throws -> Int {
        try store.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM user") ?? 0 }
    }
}
