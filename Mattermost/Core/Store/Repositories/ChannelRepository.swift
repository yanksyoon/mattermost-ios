// T29 — `ChannelRepository`: channels, membership, and the unread/mention math the sidebar and the
// app-icon badge read.
//
// Query shapes ported from mattermost/mattermost-mobile @ v2.45.0
// (162f2560d0e1df073220f7701d5a67cc17c8abeb), ios/Gekidou/Sources/Gekidou/Storage/
// Database+Channels.swift (`insertOrUpdateMyChannel`, unread state, `serverHasChannels`) —
// Apache-2.0, ported with attribution per docs/THIRD_PARTY_NOTICES.md.

import Foundation
import GRDB

protocol ChannelRepository: Sendable {
    // MARK: Writes

    func upsert(_ channels: [MMChannel]) async throws

    /// Inserts or replaces membership rows (`GET /users/me/teams/{id}/channels` + `channel_viewed`).
    func upsertMembership(_ members: [MMChannelMember]) async throws

    /// Applies a `channel_viewed` event / an explicit "mark read": clears the counters, records the
    /// view time, and clears a manual unread mark (opening a channel is the user's answer to it).
    func markRead(channelID: String, userID: String, viewedAt: Int64) async throws

    /// Applies unread counters from the server (`GET /users/me/channels` payloads, `post_unread`).
    func setUnread(channelID: String,
                   userID: String,
                   messageCount: Int64,
                   mentionCount: Int64,
                   lastViewedAt: Int64) async throws

    /// The "keep as unread" action (`manually_unread` in upstream's MyChannel).
    func setManuallyUnread(channelID: String, userID: String, unread: Bool) async throws

    /// A channel left/deleted: removes the channel, its memberships, its posts, and the reactions and
    /// file rows of those posts. Returns the number of posts removed.
    func delete(channelID: String) async throws -> Int

    // MARK: Reads

    func channel(_ channelID: String) throws -> MMChannel?

    /// Channels of one team, newest activity first. `teamID` empty means "direct/group channels".
    func channels(teamID: String) throws -> [MMChannel]

    /// Channels the user is a member of, ordered by when they last looked at them (the sidebar's
    /// "recent" order upstream applies in `getChannelsWithTeam`).
    func recentChannels(userID: String, limit: Int) throws -> [MMChannel]

    func membership(channelID: String, userID: String) throws -> MMChannelMember?

    func unread(channelID: String, userID: String) throws -> MMChannelUnread

    /// Every unread channel for a user in one query — the badge must not be an N+1.
    func unreadByChannel(userID: String) throws -> [String: MMChannelUnread]

    func unreadTotals(userID: String) throws -> MMUnreadTotals
}

// MARK: - SQLite

final class SQLiteChannelRepository: ChannelRepository {
    private let store: MMStore

    init(store: MMStore) {
        self.store = store
    }

    // MARK: Writes

    func upsert(_ channels: [MMChannel]) async throws {
        guard !channels.isEmpty else { return }
        try await store.write { db in
            for channel in channels {
                var values = MMRowValues()
                values.set("id", channel.id)
                values.set("team_id", channel.teamId)
                values.set("name", channel.name)
                values.set("display_name", channel.displayName)
                values.set("type", channel.type)
                values.set("header", channel.header)
                values.set("purpose", channel.purpose)
                values.set("last_post_at", channel.lastPostAt)
                values.set("total_msg_count", channel.totalMsgCount)
                try values.executeUpsert(db, table: MMStoreTable.channel)
            }
        }
    }

    func upsertMembership(_ members: [MMChannelMember]) async throws {
        guard !members.isEmpty else { return }
        try await store.write { db in
            for member in members {
                try Self.upsertMember(member, into: db)
            }
        }
    }

    func markRead(channelID: String, userID: String, viewedAt: Int64) async throws {
        try await store.write { db in
            // `last_update_at` moves forward too, so a membership snapshot that was fetched before
            // this view (and still carries the old counters) cannot re-apply them.
            try db.execute(sql: """
                UPDATE channel_member
                   SET last_viewed_at = MAX(last_viewed_at, ?),
                       last_update_at = MAX(last_update_at, ?),
                       msg_count = 0,
                       mention_count = 0,
                       urgent_mention_count = 0,
                       manually_unread = 0,
                       is_unread = 0
                 WHERE channel_id = ? AND user_id = ?
                """, arguments: [viewedAt, viewedAt, channelID, userID])
        }
    }

    func setUnread(channelID: String,
                   userID: String,
                   messageCount: Int64,
                   mentionCount: Int64,
                   lastViewedAt: Int64) async throws {
        try await store.write { db in
            try db.execute(sql: """
                UPDATE channel_member
                   SET msg_count = ?,
                       mention_count = ?,
                       last_viewed_at = MAX(last_viewed_at, ?),
                       is_unread = CASE WHEN ? > 0 OR manually_unread = 1 THEN 1 ELSE 0 END
                 WHERE channel_id = ? AND user_id = ?
                """, arguments: [messageCount, mentionCount, lastViewedAt,
                                 messageCount, channelID, userID])
        }
    }

    func setManuallyUnread(channelID: String, userID: String, unread: Bool) async throws {
        try await store.write { db in
            try db.execute(sql: """
                UPDATE channel_member
                   SET manually_unread = ?,
                       is_unread = CASE WHEN ? = 1 OR msg_count > 0 THEN 1 ELSE 0 END
                 WHERE channel_id = ? AND user_id = ?
                """, arguments: [unread, unread, channelID, userID])
        }
    }

    func delete(channelID: String) async throws -> Int {
        try await store.write { db in
            // Posts go first so their reactions/files can be found; then the channel and membership.
            let removedPosts = try SQLitePostRepository.evict(channelID: channelID, keepingNewest: 0, in: db)
            try db.execute(sql: "DELETE FROM channel_member WHERE channel_id = ?", arguments: [channelID])
            try db.execute(sql: "DELETE FROM channel WHERE id = ?", arguments: [channelID])
            return removedPosts
        }
    }

    // MARK: Reads

    func channel(_ channelID: String) throws -> MMChannel? {
        try store.read { db in
            try MMChannel.fetchOne(db, sql: "SELECT * FROM channel WHERE id = ?", arguments: [channelID])
        }
    }

    func channels(teamID: String) throws -> [MMChannel] {
        try store.read { db in
            try MMChannel.fetchAll(db, sql: """
                SELECT * FROM channel WHERE team_id = ? ORDER BY last_post_at DESC, display_name ASC
                """, arguments: [teamID])
        }
    }

    func recentChannels(userID: String, limit: Int) throws -> [MMChannel] {
        guard limit > 0 else { return [] }
        return try store.read { db in
            try MMChannel.fetchAll(db, sql: """
                SELECT c.* FROM channel c
                  JOIN channel_member m ON m.channel_id = c.id
                 WHERE m.user_id = ?
                 ORDER BY m.last_viewed_at DESC, c.last_post_at DESC
                 LIMIT ?
                """, arguments: [userID, limit])
        }
    }

    func membership(channelID: String, userID: String) throws -> MMChannelMember? {
        try store.read { db in
            try MMChannelMember.fetchOne(db, sql: """
                SELECT * FROM channel_member WHERE channel_id = ? AND user_id = ?
                """, arguments: [channelID, userID])
        }
    }

    func unread(channelID: String, userID: String) throws -> MMChannelUnread {
        try membership(channelID: channelID, userID: userID).map(MMChannelUnread.init(member:))
            ?? .empty(channelID)
    }

    func unreadByChannel(userID: String) throws -> [String: MMChannelUnread] {
        try store.read { db in
            let rows = try MMChannelMember.fetchAll(db, sql: """
                SELECT * FROM channel_member WHERE user_id = ? AND is_unread = 1
                """, arguments: [userID])
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.channelId, MMChannelUnread(member: $0)) })
        }
    }

    func unreadTotals(userID: String) throws -> MMUnreadTotals {
        try store.read { db in
            let messages = try Int64.fetchOne(
                db, sql: "SELECT COALESCE(SUM(msg_count), 0) FROM channel_member WHERE user_id = ?",
                arguments: [userID]) ?? 0
            let mentions = try Int64.fetchOne(
                db, sql: "SELECT COALESCE(SUM(mention_count), 0) FROM channel_member WHERE user_id = ?",
                arguments: [userID]) ?? 0
            let urgent = try Int64.fetchOne(
                db, sql: "SELECT COALESCE(SUM(urgent_mention_count), 0) FROM channel_member WHERE user_id = ?",
                arguments: [userID]) ?? 0
            let unreadChannels = try Int.fetchOne(
                db, sql: "SELECT COALESCE(SUM(is_unread), 0) FROM channel_member WHERE user_id = ?",
                arguments: [userID]) ?? 0
            return MMUnreadTotals(messageCount: messages,
                                 mentionCount: mentions,
                                 urgentMentionCount: urgent,
                                 unreadChannelCount: unreadChannels)
        }
    }

    // MARK: - Shared statements

    static func upsertMember(_ member: MMChannelMember, into db: Database) throws {
        var values = MMRowValues(keyColumns: ["channel_id", "user_id"])
        values.set("channel_id", member.channelId)
        values.set("user_id", member.userId)
        values.set("roles", member.roles)
        values.set("scheme_admin", member.schemeAdmin)
        values.set("scheme_user", member.schemeUser)
        values.set("last_viewed_at", member.lastViewedAt)
        values.set("msg_count", member.msgCount)
        values.set("mention_count", member.mentionCount)
        values.set("urgent_mention_count", member.urgentMentionCount)
        values.set("last_update_at", member.lastUpdateAt)
        values.set("manually_unread", member.manuallyUnread)
        values.set("is_unread", member.msgCount > 0 || member.manuallyUnread)
        values.set("notify_props", MMJSONColumn.text(member.notifyProps) ?? "{}")
        // No version guard here: `last_update_at` is the time of the last *membership* change and is
        // not monotonic with unread counters, so guarding on it would swallow legitimate updates.
        // Post rows are guarded (see PostRepository.insert); membership snapshots are last-write-wins
        // because the server is the source of truth for the counters.
        try values.executeUpsert(db, table: MMStoreTable.channelMember)
    }
}
