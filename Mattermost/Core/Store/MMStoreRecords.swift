// T29 — row mapping between the store tables and the T28 DTOs.
//
// Reads: `FetchableRecord` conformances declared here (extensions), so the API DTOs in MMTypes.swift
// stay free of any GRDB knowledge and the same type is used by transport and storage.
//
// Writes: `MMRowValues` builds the INSERT/UPDATE from a column→value map the caller fills in. This
// is deliberately not positional: a positional bind list that drifts from its column list is the
// classic way a store silently writes a channel id into a user id column.

import Foundation
import GRDB

// MARK: - JSON columns

/// `props`, `metadata`, `file_ids`, `notify_props` and `files` are JSON in Mattermost's API and TEXT
/// in SQLite. `JSONValue.canonicalString()` (MMJSON.swift) sorts keys, so the same value always
/// produces the same bytes — which is what makes a row comparison in a test meaningful.
enum MMJSONColumn {
    static func text(_ value: JSONValue?) -> String? {
        value.map { $0.canonicalString() }
    }

    static func value(_ text: String?) -> JSONValue? {
        guard let text, !text.isEmpty, text != "null" else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// `post.file_ids` is a JSON array of strings.
    static func idArrayText(_ ids: [String]) -> String {
        guard let data = try? JSONEncoder().encode(ids),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    static func ids(_ text: String?) -> [String] {
        guard let text, !text.isEmpty, let data = text.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}

// MARK: - Row access with defaults

/// Typed, non-trapping row access. A column that is NULL or absent becomes the type's zero value
/// instead of a `try!` crash: a partially-written row (an older migration fixture, a hand-edited
/// database in a bug report) must not take the app down on launch.
struct MMRow {
    let row: Row

    init(_ row: Row) { self.row = row }

    func string(_ column: String) -> String {
        (try? row.decode(String.self, forColumn: column)) ?? ""
    }

    func optionalString(_ column: String) -> String? {
        row[column] as String?
    }

    func int64(_ column: String) -> Int64 {
        (try? row.decode(Int64.self, forColumn: column)) ?? 0
    }

    func int(_ column: String) -> Int {
        (try? row.decode(Int.self, forColumn: column)) ?? 0
    }

    func bool(_ column: String) -> Bool {
        (try? row.decode(Bool.self, forColumn: column)) ?? false
    }

    func json(_ column: String) -> JSONValue? {
        MMJSONColumn.value(optionalString(column))
    }
}

// MARK: - Row → DTO

extension MMPost: FetchableRecord {
    init(row: Row) {
        let r = MMRow(row)
        self.init(
            id: r.string("id"),
            createAt: r.int64("create_at"),
            updateAt: r.int64("update_at"),
            editAt: r.int64("edit_at"),
            deleteAt: r.int64("delete_at"),
            isPinned: r.bool("is_pinned"),
            userId: r.string("user_id"),
            channelId: r.string("channel_id"),
            rootId: r.string("root_id"),
            originalId: r.string("original_id"),
            message: r.string("message"),
            messageSource: r.string("message_source"),
            type: r.string("type"),
            props: r.json("props"),
            metadata: r.json("metadata"),
            fileIds: MMJSONColumn.ids(r.optionalString("file_ids")),
            replyCount: r.int("reply_count"),
            lastReplyAt: r.int64("last_reply_at"),
            isFollowing: r.bool("is_following"),
            participants: nil)
    }

    /// The columns this record writes. `metadata` is a v2 column; `insertColumns` includes it only
    /// because every store instance is migrated to current before a repository sees it.
    static let writeColumns = [
        "id", "channel_id", "user_id", "root_id", "original_id", "message", "message_source",
        "type", "props", "metadata", "file_ids", "create_at", "update_at", "edit_at", "delete_at",
        "is_pinned", "reply_count", "last_reply_at", "is_following",
    ]

    /// Columns that must not be overwritten by a merge from an older payload (an out-of-order
    /// socket event or a stale page): `create_at` and `id` are immutable, and `message` must not go
    /// backwards when `update_at` does.
    static let immutableColumns = ["id", "channel_id", "user_id", "create_at"]
}

extension MMChannel: FetchableRecord {
    init(row: Row) {
        let r = MMRow(row)
        self.init(
            id: r.string("id"),
            name: r.string("name"),
            displayName: r.string("display_name"),
            type: r.string("type"),
            teamId: r.string("team_id"),
            header: r.string("header"),
            purpose: r.string("purpose"),
            lastPostAt: r.int64("last_post_at"),
            totalMsgCount: r.int64("total_msg_count"))
    }

    static let writeColumns = [
        "id", "team_id", "name", "display_name", "type", "header", "purpose",
        "last_post_at", "total_msg_count",
    ]
}

extension MMUser: FetchableRecord {
    init(row: Row) {
        let r = MMRow(row)
        self.init(
            id: r.string("id"),
            username: r.string("username"),
            email: r.string("email"),
            firstName: r.string("first_name"),
            lastName: r.string("last_name"),
            nickname: r.string("nickname"),
            deleteAt: r.int64("delete_at"),
            updateAt: r.int64("update_at"))
    }

    static let writeColumns = [
        "id", "username", "email", "first_name", "last_name", "nickname", "update_at", "delete_at",
    ]
}

extension MMReaction: FetchableRecord {
    init(row: Row) {
        let r = MMRow(row)
        self.init(
            userId: r.string("user_id"),
            postId: r.string("post_id"),
            emojiName: r.string("emoji_name"),
            createAt: r.int64("create_at"))
    }

    static let writeColumns = ["post_id", "user_id", "emoji_name", "create_at"]
}

extension MMPreference: FetchableRecord {
    init(row: Row) {
        let r = MMRow(row)
        self.init(
            userId: r.string("user_id"),
            category: r.string("category"),
            name: r.string("name"),
            value: r.string("value"))
    }

    static let writeColumns = ["user_id", "category", "name", "value"]
}

extension MMTeam: FetchableRecord {
    init(row: Row) {
        let r = MMRow(row)
        self.init(
            id: r.string("id"),
            name: r.string("name"),
            displayName: r.string("display_name"),
            description: r.string("description"),
            type: r.string("type"),
            allowedDomains: r.string("allowed_domains"),
            isAllowOpenInvite: r.bool("is_allow_open_invite"),
            isGroupConstrained: r.bool("is_group_constrained"),
            lastTeamIconUpdatedAt: r.int64("last_team_icon_updated_at"),
            inviteId: r.string("invite_id"),
            createAt: r.int64("create_at"),
            updateAt: r.int64("update_at"),
            deleteAt: r.int64("delete_at"))
    }

    static let writeColumns = [
        "id", "name", "display_name", "description", "type", "allowed_domains",
        "is_allow_open_invite", "is_group_constrained", "last_team_icon_updated_at",
        "invite_id", "create_at", "update_at", "delete_at",
    ]
}

extension MMChannelMember: FetchableRecord {
    init(row: Row) {
        let r = MMRow(row)
        self.init(
            channelId: r.string("channel_id"),
            userId: r.string("user_id"),
            roles: r.string("roles"),
            schemeAdmin: r.bool("scheme_admin"),
            schemeUser: r.bool("scheme_user"),
            lastViewedAt: r.int64("last_viewed_at"),
            msgCount: r.int64("msg_count"),
            mentionCount: r.int64("mention_count"),
            urgentMentionCount: r.int64("urgent_mention_count"),
            lastUpdateAt: r.int64("last_update_at"),
            manuallyUnread: r.bool("manually_unread"),
            notifyProps: r.json("notify_props"))
    }

    static let writeColumns = [
        "channel_id", "user_id", "roles", "scheme_admin", "scheme_user", "last_viewed_at",
        "msg_count", "mention_count", "urgent_mention_count", "last_update_at",
        "manually_unread", "notify_props",
    ]
}

extension MMDraft: FetchableRecord {
    init(row: Row) {
        let r = MMRow(row)
        self.init(
            channelId: r.string("channel_id"),
            rootId: r.string("root_id"),
            message: r.string("message"),
            files: r.json("files"),
            metadata: r.json("metadata"),
            type: r.string("type"),
            updateAt: r.int64("update_at"))
    }

    static let writeColumns = [
        "channel_id", "root_id", "message", "files", "metadata", "type", "update_at",
    ]
}

extension MMFileInfo: FetchableRecord {
    init(row: Row) {
        let r = MMRow(row)
        self.init(
            id: r.string("id"),
            postId: r.string("post_id"),
            name: r.string("name"),
            fileExtension: r.string("extension"),
            mimeType: r.string("mime_type"),
            size: r.int64("size"),
            width: r.int("width"),
            height: r.int("height"),
            imageThumbnail: r.string("image_thumbnail"),
            localPath: r.string("local_path"),
            isBlocked: r.bool("is_blocked"))
    }

    static let writeColumns = [
        "id", "post_id", "name", "extension", "mime_type", "size", "width", "height",
        "image_thumbnail", "local_path", "is_blocked",
    ]
}

// MARK: - Writes

/// An ordered column→value map that builds its own upsert statement, so the SQL and the bound
/// values cannot drift apart.
struct MMRowValues {
    private var columns: [String] = []
    private var values: [any DatabaseValueConvertible] = []
    /// Columns that participate in a conflict target (`PRIMARY KEY`), i.e. never updated.
    private var keyColumns: [String] = []

    init(keyColumns: [String] = ["id"]) {
        self.keyColumns = keyColumns
    }

    mutating func set(_ column: String, _ value: any DatabaseValueConvertible) {
        if let existing = columns.firstIndex(of: column) {
            values[existing] = value
            return
        }
        columns.append(column)
        values.append(value)
    }

    mutating func setJSON(_ column: String, _ value: JSONValue?) {
        // `Optional<String>` itself conforms to DatabaseValueConvertible, so a nil JSON value binds
        // as SQL NULL rather than as the empty string.
        set(column, MMJSONColumn.text(value) as String?)
    }

    /// `INSERT … ON CONFLICT(key) DO UPDATE SET <every non-key column>`
    ///
    /// When `versionColumn` is given the update is additionally guarded by
    /// `excluded.<versionColumn> >= <table>.<versionColumn>`: a stale page that arrives after a
    /// newer socket event refreshes nothing. Without the guard, scrolling back in history can undo
    /// an edit that already landed.
    func upsertSQL(table: String, versionColumn: String? = nil) -> String {
        let columnList = columns.joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        let target = keyColumns.joined(separator: ", ")
        let updates = columns
            .filter { !keyColumns.contains($0) }
            .map { "\($0) = excluded.\($0)" }
            .joined(separator: ", ")
        if updates.isEmpty {
            return "INSERT INTO \(table) (\(columnList)) VALUES (\(placeholders)) ON CONFLICT(\(target)) DO NOTHING"
        }
        var sql = "INSERT INTO \(table) (\(columnList)) VALUES (\(placeholders)) ON CONFLICT(\(target)) DO UPDATE SET \(updates)"
        if let versionColumn {
            sql += " WHERE excluded.\(versionColumn) >= \(table).\(versionColumn)"
        }
        return sql
    }

    func arguments() -> StatementArguments {
        StatementArguments(values)
    }

    func executeUpsert(_ db: Database, table: String, versionColumn: String? = nil) throws {
        try db.execute(sql: upsertSQL(table: table, versionColumn: versionColumn), arguments: arguments())
    }
}
