// T29 — schema v1..v3 for the native local store, and the versioned migration chain that owns it.
//
// Table shapes and the columns each query reads were taken from
// mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb):
//   app/database/schema/server/table_schemas/*.ts          — which columns exist per table
//   ios/Gekidou/Sources/Gekidou/Storage/Database+*.swift   — which columns a real query filters on
// Licence: Apache-2.0 — ported with attribution per docs/THIRD_PARTY_NOTICES.md.
//
// Divergences from upstream (all recorded in docs/t29-build-note.md §3):
//   * WatermelonDB bookkeeping columns (`_status`, `_changed`, `_deleted`) are not carried: one
//     native writer, not an ORM with a sync protocol.
//   * Upstream's `MyChannel` (per-user unread state) is merged into `channel_member`.
//   * Upstream's `System` key/value table is replaced by the explicit `sync_cursor` table.
//   * **A column exists only if something writes it.** v1 carries the columns the T28 DTOs decode
//     plus the ones the queries in `Repositories/` filter on; a column upstream has but this client
//     cannot fill yet (presence, roles, custom status, optimistic-send ids) is added by the
//     migration chain when its owning card lands, not left sitting at a default that lies.
//   * Timestamps are INTEGER milliseconds (upstream stores Double milliseconds in SQLite).

import Foundation
import GRDB

/// Table names. Kept in one place so a typo is a compile error instead of a runtime "no such table".
enum MMStoreTable {
    static let server = "server"
    static let team = "team"
    static let teamMember = "team_member"
    static let channel = "channel"
    static let channelMember = "channel_member"
    static let user = "user"
    static let post = "post"
    static let postReaction = "post_reaction"
    static let fileInfo = "file_info"
    static let draft = "draft"
    static let syncCursor = "sync_cursor"
    static let preference = "preference"

    /// Every table the store owns, in dependency order (children last).
    static let all: [String] = [
        server, team, teamMember, channel, channelMember, user,
        post, postReaction, fileInfo, draft, syncCursor, preference,
    ]

    /// Tables that hold synced server content (used by the size measurement, and by a "clear local
    /// data" action, which must not delete the `server` identity row).
    static let contentTables: [String] = [
        team, teamMember, channel, channelMember, user,
        post, postReaction, fileInfo, draft, syncCursor, preference,
    ]
}

/// One step of the migration chain.
///
/// The chain is an explicit, ordered list of named steps rather than a version integer: a name is
/// what a failure report needs, and an applied-step ledger (`grdb_migrations`, written by GRDB) is
/// what makes re-running a no-op. `version` is derived from the position and mirrored into
/// `PRAGMA user_version` so an external `sqlite3` session can tell what it is looking at.
enum MMMigration: String, CaseIterable, Sendable {
    case v1InitialSchema = "v1_initial_schema"
    case v2PostMetadataAndUnread = "v2_post_metadata_and_unread"
    case v3ServerAPIVersion = "v3_server_api_version"

    /// 1-based position in the chain.
    var version: Int {
        switch self {
        case .v1InitialSchema: return 1
        case .v2PostMetadataAndUnread: return 2
        case .v3ServerAPIVersion: return 3
        }
    }

    /// The newest schema this build knows how to produce or read.
    static var currentVersion: Int { allCases.map(\.version).max() ?? 0 }

    func apply(_ db: Database) throws {
        switch self {
        case .v1InitialSchema:
            try MMSchema.execute(MMSchema.v1Statements, in: db)
        case .v2PostMetadataAndUnread:
            try MMSchema.execute(MMSchema.v2Statements, in: db)
        case .v3ServerAPIVersion:
            try MMSchema.execute(MMSchema.v3Statements, in: db)
        }
    }
}

/// The DDL itself.
enum MMSchema {

    /// Runs a list of statements one at a time so a failure names the statement that broke.
    static func execute(_ statements: [String], in db: Database) throws {
        for statement in statements {
            do {
                try db.execute(sql: statement)
            } catch {
                throw MMStoreError.migrationFailed(
                    name: "ddl",
                    reason: "\(error.localizedDescription) — while running: \(statement.prefix(160))")
            }
        }
    }

    // MARK: - v1

    /// Schema v1: the twelve tables the card asks for, with the indices the repository queries use.
    ///
    /// Index rationale: every index below is either reached by a statement in `Repositories/`
    /// **today** (group 1) or is reserved for a query that a named later card runs against this same
    /// table shape (group 2, marked). Nothing in group 2 is a guess about a query we will invent: each
    /// is the access path for one already-scoped screen, and the alternative — adding an index in a
    /// migration when that card lands — buys nothing, because an unused index costs one page and no
    /// maintenance. T29-AV F7 found the previous wording ("no speculative indices") claiming
    /// otherwise while listing `idx_reaction_user` as "screen card T40+"; the split below is the
    /// correction, and `MMStoreTests.testIndicesTheQueriesNeedExist` asserts all seventeen.
    ///
    /// Queried today:
    ///  - `idx_server_url`             — one file per server; a duplicate URL is a bug.
    ///  - `idx_post_channel_window`    — `posts(inChannel:before:limit:)` orders a channel page.
    ///  - `idx_post_root_window`       — `posts(inThread:limit:)`, the root plus its replies, and the
    ///                                   `root_id IN (doomed)` cascade eviction adds.
    ///  - `idx_post_user`              — a user's posts, and `user_updated` reconciliation.
    ///  - `idx_channel_team`           — the sidebar's channel list for a team.
    ///  - `idx_channel_name`           — channel switcher prefix search.
    ///  - `idx_channel_last_post`      — "recent channels" ordering.
    ///  - `idx_channel_member_recent`  — the channel list ordered by `last_viewed_at`.
    ///  - `idx_channel_member_unread`  — badge totals across a user's channels.
    ///  - `idx_reaction_post`, `idx_file_post` — a post's reactions/files (and the eviction scan).
    ///  - `idx_user_username`          — @-autocomplete prefix search.
    ///  - `idx_draft_update_at`        — "recent drafts" ordering.
    ///  - `idx_preference_lookup`      — `preferences(userID:category:)`.
    ///
    /// Reserved, with the access path each is for:
    ///  - `idx_team_name`              — team-by-name resolution (`GET /teams/name/{name}`, a deep
    ///                                   link or a link from another server), i.e. "is this team
    ///                                   already in the store" without a full table scan. The teams
    ///                                   table has no repository yet (T30's sidebar owns it);
    ///                                   T29-AV F7 flagged it as undocumented, not as unused-but-wrong.
    ///  - `idx_team_member_user`       — "the teams this user belongs to": the sidebar's team switcher,
    ///                                   also T30. The PK is `(team_id, user_id)`, so a lookup by
    ///                                   `user_id` alone would otherwise scan.
    ///  - `idx_reaction_user`          — "reactions I have made", the profile/activity surface (T40+).
    ///                                   Marked speculative in the same sentence that used to deny it.
    static let v1Statements: [String] = [
        """
        CREATE TABLE server (
            id TEXT NOT NULL PRIMARY KEY,
            url TEXT NOT NULL,
            display_name TEXT NOT NULL DEFAULT '',
            last_active_at INTEGER NOT NULL DEFAULT 0,
            db_path TEXT NOT NULL DEFAULT ''
        )
        """,
        "CREATE UNIQUE INDEX idx_server_url ON server(url)",

        """
        CREATE TABLE team (
            id TEXT NOT NULL PRIMARY KEY,
            name TEXT NOT NULL DEFAULT '',
            display_name TEXT NOT NULL DEFAULT '',
            description TEXT NOT NULL DEFAULT '',
            type TEXT NOT NULL DEFAULT '',
            allowed_domains TEXT NOT NULL DEFAULT '',
            is_allow_open_invite INTEGER NOT NULL DEFAULT 0,
            is_group_constrained INTEGER NOT NULL DEFAULT 0,
            last_team_icon_updated_at INTEGER NOT NULL DEFAULT 0,
            invite_id TEXT NOT NULL DEFAULT '',
            create_at INTEGER NOT NULL DEFAULT 0,
            update_at INTEGER NOT NULL DEFAULT 0,
            delete_at INTEGER NOT NULL DEFAULT 0
        )
        """,
        "CREATE INDEX idx_team_name ON team(name)",

        """
        CREATE TABLE team_member (
            team_id TEXT NOT NULL,
            user_id TEXT NOT NULL,
            roles TEXT NOT NULL DEFAULT '',
            scheme_admin INTEGER NOT NULL DEFAULT 0,
            scheme_user INTEGER NOT NULL DEFAULT 1,
            PRIMARY KEY (team_id, user_id)
        )
        """,
        "CREATE INDEX idx_team_member_user ON team_member(user_id)",

        """
        CREATE TABLE channel (
            id TEXT NOT NULL PRIMARY KEY,
            team_id TEXT NOT NULL DEFAULT '',
            name TEXT NOT NULL DEFAULT '',
            display_name TEXT NOT NULL DEFAULT '',
            type TEXT NOT NULL DEFAULT '',
            header TEXT NOT NULL DEFAULT '',
            purpose TEXT NOT NULL DEFAULT '',
            last_post_at INTEGER NOT NULL DEFAULT 0,
            total_msg_count INTEGER NOT NULL DEFAULT 0
        )
        """,
        "CREATE INDEX idx_channel_team ON channel(team_id)",
        "CREATE INDEX idx_channel_name ON channel(name)",
        "CREATE INDEX idx_channel_last_post ON channel(last_post_at DESC)",

        """
        CREATE TABLE channel_member (
            channel_id TEXT NOT NULL,
            user_id TEXT NOT NULL,
            roles TEXT NOT NULL DEFAULT '',
            scheme_admin INTEGER NOT NULL DEFAULT 0,
            scheme_user INTEGER NOT NULL DEFAULT 1,
            last_viewed_at INTEGER NOT NULL DEFAULT 0,
            msg_count INTEGER NOT NULL DEFAULT 0,
            mention_count INTEGER NOT NULL DEFAULT 0,
            last_update_at INTEGER NOT NULL DEFAULT 0,
            is_unread INTEGER NOT NULL DEFAULT 0,
            notify_props TEXT NOT NULL DEFAULT '{}',
            PRIMARY KEY (channel_id, user_id)
        )
        """,
        "CREATE INDEX idx_channel_member_recent ON channel_member(user_id, last_viewed_at DESC)",
        "CREATE INDEX idx_channel_member_unread ON channel_member(user_id, is_unread)",

        """
        CREATE TABLE user (
            id TEXT NOT NULL PRIMARY KEY,
            username TEXT NOT NULL DEFAULT '',
            email TEXT NOT NULL DEFAULT '',
            first_name TEXT NOT NULL DEFAULT '',
            last_name TEXT NOT NULL DEFAULT '',
            nickname TEXT NOT NULL DEFAULT '',
            update_at INTEGER NOT NULL DEFAULT 0,
            delete_at INTEGER NOT NULL DEFAULT 0
        )
        """,
        "CREATE INDEX idx_user_username ON user(username)",

        """
        CREATE TABLE post (
            id TEXT NOT NULL PRIMARY KEY,
            channel_id TEXT NOT NULL,
            user_id TEXT NOT NULL DEFAULT '',
            root_id TEXT NOT NULL DEFAULT '',
            original_id TEXT NOT NULL DEFAULT '',
            message TEXT NOT NULL DEFAULT '',
            message_source TEXT NOT NULL DEFAULT '',
            type TEXT NOT NULL DEFAULT '',
            props TEXT NOT NULL DEFAULT '{}',
            file_ids TEXT NOT NULL DEFAULT '[]',
            create_at INTEGER NOT NULL DEFAULT 0,
            update_at INTEGER NOT NULL DEFAULT 0,
            edit_at INTEGER NOT NULL DEFAULT 0,
            delete_at INTEGER NOT NULL DEFAULT 0,
            is_pinned INTEGER NOT NULL DEFAULT 0,
            reply_count INTEGER NOT NULL DEFAULT 0,
            last_reply_at INTEGER NOT NULL DEFAULT 0,
            is_following INTEGER NOT NULL DEFAULT 0
        )
        """,
        "CREATE INDEX idx_post_channel_window ON post(channel_id, create_at DESC, id DESC)",
        "CREATE INDEX idx_post_root_window ON post(root_id, create_at DESC)",
        "CREATE INDEX idx_post_user ON post(user_id, create_at DESC)",

        """
        CREATE TABLE post_reaction (
            post_id TEXT NOT NULL,
            user_id TEXT NOT NULL,
            emoji_name TEXT NOT NULL,
            create_at INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (post_id, user_id, emoji_name)
        )
        """,
        "CREATE INDEX idx_reaction_post ON post_reaction(post_id, emoji_name)",
        "CREATE INDEX idx_reaction_user ON post_reaction(user_id)",

        """
        CREATE TABLE file_info (
            id TEXT NOT NULL PRIMARY KEY,
            post_id TEXT NOT NULL DEFAULT '',
            name TEXT NOT NULL DEFAULT '',
            extension TEXT NOT NULL DEFAULT '',
            mime_type TEXT NOT NULL DEFAULT '',
            size INTEGER NOT NULL DEFAULT 0,
            width INTEGER NOT NULL DEFAULT 0,
            height INTEGER NOT NULL DEFAULT 0,
            image_thumbnail TEXT NOT NULL DEFAULT '',
            local_path TEXT NOT NULL DEFAULT '',
            is_blocked INTEGER NOT NULL DEFAULT 0
        )
        """,
        "CREATE INDEX idx_file_post ON file_info(post_id)",

        """
        CREATE TABLE draft (
            channel_id TEXT NOT NULL,
            root_id TEXT NOT NULL DEFAULT '',
            message TEXT NOT NULL DEFAULT '',
            files TEXT NOT NULL DEFAULT '[]',
            metadata TEXT,
            type TEXT NOT NULL DEFAULT '',
            update_at INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (channel_id, root_id)
        )
        """,
        "CREATE INDEX idx_draft_update_at ON draft(update_at DESC)",

        """
        CREATE TABLE sync_cursor (
            scope TEXT NOT NULL,
            scope_key TEXT NOT NULL,
            cursor TEXT NOT NULL,
            updated_at INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (scope, scope_key)
        )
        """,

        """
        CREATE TABLE preference (
            user_id TEXT NOT NULL,
            category TEXT NOT NULL,
            name TEXT NOT NULL,
            value TEXT NOT NULL DEFAULT '',
            PRIMARY KEY (user_id, category, name)
        )
        """,
        "CREATE INDEX idx_preference_lookup ON preference(user_id, category)",
    ]

    // MARK: - v2

    /// Schema v2 — purely additive, and deliberately so: it is the fixture for the "older schema
    /// upgrades without data loss" test, so it must be the kind of change a real client ships
    /// after v1 (new column, new default, no rewrite of existing rows).
    ///
    /// What it adds, and why it is a *second* step rather than part of v1:
    ///  - `post.metadata` — upstream added this column with custom post attributes
    ///    (`table_schemas/post.ts`); a v1 database written before that feature simply lacks it.
    ///  - `channel_member.manually_unread` / `urgent_mention_count` — upstream's `MyChannel` gained
    ///    both after its first release; `Database+Channels.swift` ships
    ///    `hasMyChannelUrgentMentionCountColumn(_:)` as a runtime probe for exactly this migration,
    ///    which is upstream's own evidence that the column arrived late.
    static let v2Statements: [String] = [
        "ALTER TABLE post ADD COLUMN metadata TEXT",
        "ALTER TABLE channel_member ADD COLUMN manually_unread INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE channel_member ADD COLUMN urgent_mention_count INTEGER NOT NULL DEFAULT 0",
    ]

    // MARK: - v3

    /// Schema v3 — `server.server_api_version`, the column `docs/path-b-adr.md` §5 asks for
    /// ("T29's SQLite layer records the server version it was written against per model").
    ///
    /// Why the `server` table rather than a column on every table: this client keeps **one SQLite
    /// file per server**, so the `server` row *is* the per-model scope for the file — every row in it
    /// was written by a client talking to that one server. Putting the column on `post`, `channel`,
    /// `user`, … would store the same string dozens of times per row-per-table and still could not say
    /// which version wrote which row. The cost of this choice is stated in the build note §3.3: the
    /// granularity is per file, not per row.
    ///
    /// Additive, with a default: a v1/v2 file upgrades in place, existing rows read `''`, and
    /// `MMStore.serverAPIVersion()` reports `nil` for "not recorded yet" rather than a lie (T29-AV F5).
    static let v3Statements: [String] = [
        "ALTER TABLE server ADD COLUMN server_api_version TEXT NOT NULL DEFAULT ''",
    ]

    /// Statements for every step up to and including `migration`, in chain order. Used by the
    /// migration test to build a faithful fixture without hand-copying DDL.
    static func statements(upTo migration: MMMigration) -> [String] {
        MMMigration.allCases
            .sorted { $0.version < $1.version }
            .filter { $0.version <= migration.version }
            .flatMap { step in
                switch step {
                case .v1InitialSchema: return v1Statements
                case .v2PostMetadataAndUnread: return v2Statements
                case .v3ServerAPIVersion: return v3Statements
                }
            }
    }
}
