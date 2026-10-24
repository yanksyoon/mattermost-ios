// T29 — native local store: value types the store adds on top of the T28 API DTOs.
//
// Schema/queries ported from mattermost/mattermost-mobile @ v2.45.0
// (162f2560d0e1df073220f7701d5a67cc17c8abeb):
//   app/database/schema/server/table_schemas/*.ts   (table shapes: which columns exist)
//   ios/Gekidou/Sources/Gekidou/Storage/Database+*.swift  (which columns a query actually reads)
// Licence: Apache-2.0 (upstream LICENSE.txt) — ported with attribution per
// docs/THIRD_PARTY_NOTICES.md. Divergences are recorded in docs/t29-build-note.md §3.
//
// The API DTOs (`MMPost`, `MMChannel`, `MMUser`, `MMReaction`, `MMPreference`) are reused from
// MMTypes.swift rather than duplicated: the store persists exactly what the transport decoded, so
// a second set of models would be a second source of truth.

import Foundation

// MARK: - Errors

/// Every failure the store can report. Typed so a screen can tell "no such row" (normal, e.g. a
/// draft that was never written) from "the database is broken" (report it).
enum MMStoreError: Error, Equatable, LocalizedError {
    /// The SQLite file could not be opened/created at this path.
    case openFailed(path: String, reason: String)
    /// A migration in the chain threw. Carries the migration name so a bug report is actionable.
    case migrationFailed(name: String, reason: String)
    /// The on-disk schema is newer than this build knows about (a downgrade, e.g. an app rollback).
    case schemaTooNew(found: Int, supported: Int)
    /// A row that must exist for the write to mean anything is missing.
    case missingParentRow(table: String, id: String)
    /// Another connection held the write lock for longer than the store's busy timeout, so SQLite
    /// answered `SQLITE_BUSY`/`SQLITE_LOCKED`. Typed so a caller can tell "try again later" from
    /// "this write is invalid" instead of receiving a raw GRDB `DatabaseError` (T29-AV F2).
    case storeBusy(path: String, reason: String)
    /// SQLite rejected the statement.
    case sqlite(message: String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let path, let reason):
            return "Could not open the local store at \(path): \(reason)"
        case .migrationFailed(let name, let reason):
            return "Local store migration \(name) failed: \(reason)"
        case .schemaTooNew(let found, let supported):
            return "Local store schema v\(found) is newer than this build supports (v\(supported))"
        case .missingParentRow(let table, let id):
            return "Local store is missing \(table) row \(id)"
        case .storeBusy(let path, let reason):
            return "Local store at \(path) is busy: \(reason)"
        case .sqlite(let message):
            return "Local store error: \(message)"
        }
    }
}

// MARK: - Retention policy

/// How much history a channel keeps on disk.
///
/// The card asks for a *bounded per-channel post window* and for the disk cost of a busy server to
/// be answerable. Both come from this one number: posts are the only table that grows without a
/// natural cap (channels/users/teams are bounded by the server's own inventory, drafts by the number
/// of channels, reactions/files by the posts they hang off).
struct MMRetentionPolicy: Equatable, Sendable {
    /// Posts kept per channel. `nil` = unbounded (only for tests and for a user who asked for it).
    var maxPostsPerChannel: Int?
    /// Evict as part of a post write when the channel is over budget. When `false` only an explicit
    /// `evictChannel` call trims, which is what a screen-driven "free up space" action uses.
    var evictOnWrite: Bool
    /// Leave the channel alone until it is over budget by this many posts, so a busy channel does
    /// not pay for an eviction query on every incoming socket event.
    var evictionSlack: Int

    init(maxPostsPerChannel: Int? = 200, evictOnWrite: Bool = true, evictionSlack: Int = 50) {
        self.maxPostsPerChannel = maxPostsPerChannel
        self.evictOnWrite = evictOnWrite
        self.evictionSlack = evictionSlack
    }

    /// The default: 200 posts per channel, trimmed lazily in blocks of 50.
    static let `default` = MMRetentionPolicy()

    /// Unbounded history (a user who opted out of trimming).
    static let unbounded = MMRetentionPolicy(maxPostsPerChannel: nil, evictOnWrite: false)

    /// How many posts may exist before a write triggers a trim.
    var writeThreshold: Int? {
        guard let maxPostsPerChannel else { return nil }
        return maxPostsPerChannel + max(0, evictionSlack)
    }
}

// MARK: - Models the schema needs but the transport does not (yet) decode

/// A team (`GET /api/v4/users/me/teams`). Upstream: `table_schemas/team.ts`.
struct MMTeam: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var displayName: String
    var description: String
    var type: String
    var allowedDomains: String
    var isAllowOpenInvite: Bool
    var isGroupConstrained: Bool
    var lastTeamIconUpdatedAt: Int64
    var inviteId: String
    var createAt: Int64
    var updateAt: Int64
    var deleteAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, name, description, type
        case displayName = "display_name"
        case allowedDomains = "allowed_domains"
        case isAllowOpenInvite = "allow_open_invite"
        case isGroupConstrained = "group_constrained"
        case lastTeamIconUpdatedAt = "last_team_icon_update"
        case inviteId = "invite_id"
        case createAt = "create_at"
        case updateAt = "update_at"
        case deleteAt = "delete_at"
    }

    init(id: String,
         name: String = "",
         displayName: String = "",
         description: String = "",
         type: String = "",
         allowedDomains: String = "",
         isAllowOpenInvite: Bool = false,
         isGroupConstrained: Bool = false,
         lastTeamIconUpdatedAt: Int64 = 0,
         inviteId: String = "",
         createAt: Int64 = 0,
         updateAt: Int64 = 0,
         deleteAt: Int64 = 0) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.description = description
        self.type = type
        self.allowedDomains = allowedDomains
        self.isAllowOpenInvite = isAllowOpenInvite
        self.isGroupConstrained = isGroupConstrained
        self.lastTeamIconUpdatedAt = lastTeamIconUpdatedAt
        self.inviteId = inviteId
        self.createAt = createAt
        self.updateAt = updateAt
        self.deleteAt = deleteAt
    }
}

/// A channel membership *with* the per-user channel state (`GET /api/v4/users/me/teams/{id}/channels`
/// members and `channel_viewed` / `post_unread` socket events).
///
/// Upstream keeps this in two tables — `ChannelMembership` (`channel_id`, `user_id`, `scheme_admin`)
/// and `MyChannel` (message/mention counts, `last_viewed_at`, `manually_unread`). T29 merges them
/// into `channel_member` keyed `(channel_id, user_id)`: unread state is per-user membership state,
/// and one table means one place that can disagree with itself. See build note §3.4.
struct MMChannelMember: Codable, Equatable, Sendable {
    var channelId: String
    var userId: String
    var roles: String
    var schemeAdmin: Bool
    var schemeUser: Bool
    var lastViewedAt: Int64
    var msgCount: Int64
    var mentionCount: Int64
    var urgentMentionCount: Int64
    var lastUpdateAt: Int64
    var manuallyUnread: Bool
    var notifyProps: JSONValue?

    enum CodingKeys: String, CodingKey {
        case roles
        case channelId = "channel_id"
        case userId = "user_id"
        case schemeAdmin = "scheme_admin"
        case schemeUser = "scheme_user"
        case lastViewedAt = "last_viewed_at"
        case msgCount = "msg_count"
        case mentionCount = "mention_count"
        case urgentMentionCount = "urgent_mention_count"
        case lastUpdateAt = "last_update_at"
        case manuallyUnread = "manually_unread"
        case notifyProps = "notify_props"
    }

    init(channelId: String,
         userId: String,
         roles: String = "",
         schemeAdmin: Bool = false,
         schemeUser: Bool = true,
         lastViewedAt: Int64 = 0,
         msgCount: Int64 = 0,
         mentionCount: Int64 = 0,
         urgentMentionCount: Int64 = 0,
         lastUpdateAt: Int64 = 0,
         manuallyUnread: Bool = false,
         notifyProps: JSONValue? = nil) {
        self.channelId = channelId
        self.userId = userId
        self.roles = roles
        self.schemeAdmin = schemeAdmin
        self.schemeUser = schemeUser
        self.lastViewedAt = lastViewedAt
        self.msgCount = msgCount
        self.mentionCount = mentionCount
        self.urgentMentionCount = urgentMentionCount
        self.lastUpdateAt = lastUpdateAt
        self.manuallyUnread = manuallyUnread
        self.notifyProps = notifyProps
    }
}

/// Per-user unread state for one channel, as the sidebar badge needs it.
///
/// Derived, not stored: `messageCount`/`mentionCount` live in `channel_member`, `isUnread` is
/// `msgCount > 0 || manuallyUnread` — the same rule upstream's `insertOrUpdateMyChannel` applies.
struct MMChannelUnread: Equatable, Sendable {
    var channelID: String
    var messageCount: Int64
    var mentionCount: Int64
    var urgentMentionCount: Int64
    var lastViewedAt: Int64
    var manuallyUnread: Bool

    var isUnread: Bool { messageCount > 0 || manuallyUnread }

    /// No membership row yet (a channel the user has not opened, or a cold cache).
    static func empty(_ channelID: String) -> MMChannelUnread {
        MMChannelUnread(channelID: channelID, messageCount: 0, mentionCount: 0,
                        urgentMentionCount: 0, lastViewedAt: 0, manuallyUnread: false)
    }
}

extension MMChannelUnread {
    /// The derived view of a stored membership row. One rule, used by both repository
    /// implementations so "unread" cannot mean two different things.
    init(member: MMChannelMember) {
        self.init(channelID: member.channelId,
                  messageCount: member.msgCount,
                  mentionCount: member.mentionCount,
                  urgentMentionCount: member.urgentMentionCount,
                  lastViewedAt: member.lastViewedAt,
                  manuallyUnread: member.manuallyUnread)
    }
}

/// Per-user totals across every channel — what the app-icon badge and the server switcher show.
struct MMUnreadTotals: Equatable, Sendable {
    var messageCount: Int64
    var mentionCount: Int64
    var urgentMentionCount: Int64
    /// Channels with at least one unread message or a manual mark.
    var unreadChannelCount: Int

    static let zero = MMUnreadTotals(messageCount: 0, mentionCount: 0,
                                     urgentMentionCount: 0, unreadChannelCount: 0)
}

/// A post draft. Upstream: `table_schemas/draft.ts` + `Database+Posts.swift` draft helpers.
///
/// Identity is `(channelID, rootID)` — one draft per channel, or one per thread root inside that
/// channel. Upstream generates a `Draft` row id instead and keeps a unique index on the pair; the
/// natural key is used here so a re-save is an upsert rather than a lookup-then-insert.
struct MMDraft: Codable, Equatable, Sendable {
    var channelId: String
    var rootId: String
    var message: String
    /// Attachment descriptors as uploaded-but-unsent file metadata (JSON array, upstream `files`).
    var files: JSONValue?
    var metadata: JSONValue?
    var type: String
    var updateAt: Int64

    enum CodingKeys: String, CodingKey {
        case message, files, metadata, type
        case channelId = "channel_id"
        case rootId = "root_id"
        case updateAt = "update_at"
    }

    init(channelId: String,
         rootId: String = "",
         message: String = "",
         files: JSONValue? = nil,
         metadata: JSONValue? = nil,
         type: String = "",
         updateAt: Int64 = 0) {
        self.channelId = channelId
        self.rootId = rootId
        self.message = message
        self.files = files
        self.metadata = metadata
        self.type = type
        self.updateAt = updateAt
    }
}

/// A file attached to a post. Upstream: `table_schemas/file.ts`.
struct MMFileInfo: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var postId: String
    var name: String
    /// Upstream column / REST field is `extension` (a Swift keyword, so spelled out here).
    var fileExtension: String
    var mimeType: String
    var size: Int64
    var width: Int
    var height: Int
    var imageThumbnail: String
    var localPath: String
    var isBlocked: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, size, width, height
        case fileExtension = "extension"
        case postId = "post_id"
        case mimeType = "mime_type"
        case imageThumbnail = "image_thumbnail"
        case localPath = "local_path"
        case isBlocked = "is_blocked"
    }

    /// The (older) `post.metadata.files` shape names the identity `file_id` instead of `id`.
    private enum AlternateKeys: String, CodingKey {
        case fileID = "file_id"
    }

    init(id: String,
         postId: String = "",
         name: String = "",
         fileExtension: String = "",
         mimeType: String = "",
         size: Int64 = 0,
         width: Int = 0,
         height: Int = 0,
         imageThumbnail: String = "",
         localPath: String = "",
         isBlocked: Bool = false) {
        self.id = id
        self.postId = postId
        self.name = name
        self.fileExtension = fileExtension
        self.mimeType = mimeType
        self.size = size
        self.width = width
        self.height = height
        self.imageThumbnail = imageThumbnail
        self.localPath = localPath
        self.isBlocked = isBlocked
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let alternate = try decoder.container(keyedBy: AlternateKeys.self)
        // The REST API calls the identity `id`; the socket `file_ids` array on a post only carries
        // ids. `file_id` is accepted for the (older) metadata shape seen in `post.metadata.files`.
        id = try values.decodeIfPresent(String.self, forKey: .id)
            ?? alternate.decodeIfPresent(String.self, forKey: .fileID)
            ?? ""
        postId = try values.decodeIfPresent(String.self, forKey: .postId) ?? ""
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        fileExtension = try values.decodeIfPresent(String.self, forKey: .fileExtension) ?? ""
        mimeType = try values.decodeIfPresent(String.self, forKey: .mimeType) ?? ""
        size = try values.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        width = try values.decodeIfPresent(Int.self, forKey: .width) ?? 0
        height = try values.decodeIfPresent(Int.self, forKey: .height) ?? 0
        imageThumbnail = try values.decodeIfPresent(String.self, forKey: .imageThumbnail) ?? ""
        localPath = try values.decodeIfPresent(String.self, forKey: .localPath) ?? ""
        isBlocked = try values.decodeIfPresent(Bool.self, forKey: .isBlocked) ?? false
    }
}

/// What a sync cursor points at. The set is deliberately small and named after the two things the
/// card asks for: the last socket event id per server, and the last post id per channel.
enum MMSyncCursorScope: String, CaseIterable, Sendable {
    /// Per server: the id of the last WebSocket v4 event applied (`seq_reply` / `event.id`).
    case serverSocketEvent = "server.socket_event_id"
    /// Per channel: the id of the newest post stored, used as the `since`/`after` boundary.
    case channelLastPost = "channel.last_post_id"
    /// Per thread root: the newest reply stored.
    case threadLastPost = "thread.last_post_id"
}

/// A `sync_cursor` row. Upstream keeps the same information split between its `System` key/value
/// table and the `PostsInChannel` window rows; T29 keeps one explicit cursor table (build note §3.5).
struct MMSyncCursor: Equatable, Sendable {
    var scope: MMSyncCursorScope
    var scopeKey: String
    var cursor: String
    var updatedAt: Int64
}

/// What `MMStore.checkpoint()` did, so a test (and Diagnostics) can tell "the WAL was truncated"
/// from "a reader was in the way and the checkpoint degraded to PASSIVE" (T29-AV F8).
enum MMCheckpointOutcome: Equatable, Sendable {
    /// The database uses a journal other than WAL (the in-memory store); nothing to fold.
    case notWAL
    /// `TRUNCATE` completed: the WAL is folded back into the main file and reset.
    case truncated
    /// `PASSIVE` was asked for explicitly.
    case passive
    /// `TRUNCATE` hit `SQLITE_BUSY`/`SQLITE_LOCKED` (a reader held its snapshot past the busy
    /// timeout), so the checkpoint was retried as `PASSIVE`: pages are folded where possible and the
    /// rest of the WAL stays on disk until the reader finishes.
    case passiveFallback(reason: String)
}

/// Measured size of the store, in the shape a diagnostics screen and the build note both want.
struct MMStoreSize: Equatable, Sendable {
    /// Bytes on disk (sum of the main file plus `-wal` and `-shm`; 0 for an in-memory store).
    var fileBytes: Int64
    /// `PRAGMA page_count` — pages allocated, whether or not they are all still in use.
    var pageCount: Int64
    /// `PRAGMA page_size` — 4096 by default; the unit of the page count.
    var pageSize: Int64
    /// `PRAGMA freelist_count` — pages reserved by SQLite for reuse after deletes.
    var freePageCount: Int64

    /// Pages actually holding data.
    var usedBytes: Int64 { max(0, pageCount - freePageCount) * pageSize }

    var megabytes: Double { Double(fileBytes) / 1_048_576.0 }
}
