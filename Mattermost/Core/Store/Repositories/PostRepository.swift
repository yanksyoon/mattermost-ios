// T29 — `PostRepository`: the only way a screen may read or write posts.
//
// Query shapes ported from mattermost/mattermost-mobile @ v2.45.0
// (162f2560d0e1df073220f7701d5a67cc17c8abeb), ios/Gekidou/Sources/Gekidou/Storage/
// Database+Posts.swift (channel page, thread window, soft delete) — Apache-2.0, ported with
// attribution per docs/THIRD_PARTY_NOTICES.md. The eviction policy is this repo's addition
// (docs/t29-build-note.md §4).

import Foundation
import GRDB

protocol PostRepository: Sendable {
    // MARK: Writes (async: they run on the store's writer queue, never on the caller's thread)

    /// Inserts or updates posts. Keyed by `id`; a payload whose `update_at` is older than the stored
    /// row is ignored, so a late history page cannot undo an edit or a delete that already landed.
    func upsert(_ posts: [MMPost]) async throws

    /// Applies a `post_deleted` event. The row survives so the channel can show a tombstone in
    /// place, but its content is dropped: a deleted message must not stay readable on disk.
    func markDeleted(_ postID: String, at deleteAt: Int64) async throws

    /// Inserts reactions for a post (`reaction_added`, or the `metadata` of a post payload).
    func upsertReactions(_ reactions: [MMReaction]) async throws

    /// Removes one reaction (`reaction_removed`).
    func removeReaction(postID: String, userID: String, emojiName: String) async throws

    /// Inserts or updates a post's file metadata.
    func upsertFiles(_ files: [MMFileInfo]) async throws

    /// Trims the channel to its newest `count` posts, returning how many were removed.
    /// Reactions and file rows of the removed posts go with them (no orphan rows), replies of a
    /// removed thread root are removed too, and pinned posts are never part of the window.
    func evict(channelID: String, keepingNewest count: Int) async throws -> Int

    /// Applies `MMRetentionPolicy` to one channel. Returns 0 when the channel is inside its budget.
    func evictIfNeeded(channelID: String) async throws -> Int

    // MARK: Reads (synchronous on the calling context, against a WAL snapshot)

    func post(_ postID: String) throws -> MMPost?

    /// One page of a channel, newest first. `before` is an exclusive `create_at` upper bound
    /// (`nil` for the first page). Soft-deleted posts are returned with `deleteAt != 0` so the UI
    /// can render the tombstone it already has a slot for.
    func posts(inChannel channelID: String, before createAt: Int64?, limit: Int) throws -> [MMPost]

    /// A thread: the root post followed by its replies, oldest first.
    func posts(inThread rootID: String, limit: Int) throws -> [MMPost]

    /// Every pinned post in a channel, newest first (T29-AV F6). Pinned posts are exempt from the
    /// eviction window, so this is what the Pinned screen can render without the network.
    func pinnedPosts(inChannel channelID: String, limit: Int) throws -> [MMPost]

    func reactions(postID: String) throws -> [MMReaction]
    func files(postID: String) throws -> [MMFileInfo]
    func count(inChannel channelID: String) throws -> Int
}

// MARK: - SQLite

final class SQLitePostRepository: PostRepository {
    private let store: MMStore

    init(store: MMStore) {
        self.store = store
    }

    // MARK: Writes

    func upsert(_ posts: [MMPost]) async throws {
        guard !posts.isEmpty else { return }
        let retention = store.retention
        let touchedChannels = Set(posts.map(\.channelId).filter { !$0.isEmpty })
        try await store.write { db in
            for post in posts {
                try Self.insert(post, into: db)
            }
            guard retention.evictOnWrite,
                  let maxPosts = retention.maxPostsPerChannel,
                  let threshold = retention.writeThreshold else { return }
            for channelID in touchedChannels {
                let count = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM post WHERE channel_id = ?",
                    arguments: [channelID]) ?? 0
                if count > threshold {
                    _ = try Self.evict(channelID: channelID, keepingNewest: maxPosts, in: db)
                }
            }
        }
    }

    func markDeleted(_ postID: String, at deleteAt: Int64) async throws {
        try await store.write { db in
            try db.execute(sql: """
                UPDATE post
                   SET delete_at = ?,
                       update_at = MAX(update_at, ?),
                       message = '',
                       message_source = '',
                       props = '{}',
                       metadata = NULL,
                       file_ids = '[]'
                 WHERE id = ?
                """, arguments: [deleteAt, deleteAt, postID])
            try db.execute(sql: "DELETE FROM post_reaction WHERE post_id = ?", arguments: [postID])
        }
    }

    func upsertReactions(_ reactions: [MMReaction]) async throws {
        guard !reactions.isEmpty else { return }
        try await store.write { db in
            for reaction in reactions {
                var values = MMRowValues(keyColumns: ["post_id", "user_id", "emoji_name"])
                values.set("post_id", reaction.postId)
                values.set("user_id", reaction.userId)
                values.set("emoji_name", reaction.emojiName)
                values.set("create_at", reaction.createAt)
                try values.executeUpsert(db, table: MMStoreTable.postReaction)
            }
        }
    }

    func removeReaction(postID: String, userID: String, emojiName: String) async throws {
        try await store.write { db in
            try db.execute(sql: """
                DELETE FROM post_reaction
                 WHERE post_id = ? AND user_id = ? AND emoji_name = ?
                """, arguments: [postID, userID, emojiName])
        }
    }

    func upsertFiles(_ files: [MMFileInfo]) async throws {
        guard !files.isEmpty else { return }
        try await store.write { db in
            for file in files {
                var values = MMRowValues()
                values.set("id", file.id)
                values.set("post_id", file.postId)
                values.set("name", file.name)
                values.set("extension", file.fileExtension)
                values.set("mime_type", file.mimeType)
                values.set("size", file.size)
                values.set("width", file.width)
                values.set("height", file.height)
                values.set("image_thumbnail", file.imageThumbnail)
                values.set("local_path", file.localPath)
                values.set("is_blocked", file.isBlocked)
                try values.executeUpsert(db, table: MMStoreTable.fileInfo)
            }
        }
    }

    func evict(channelID: String, keepingNewest count: Int) async throws -> Int {
        try await store.write { db in
            try Self.evict(channelID: channelID, keepingNewest: count, in: db)
        }
    }

    func evictIfNeeded(channelID: String) async throws -> Int {
        guard store.retention.evictOnWrite, let maxPosts = store.retention.maxPostsPerChannel else {
            return 0
        }
        return try await store.write { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM post WHERE channel_id = ?",
                                         arguments: [channelID]) ?? 0
            guard count > maxPosts else { return 0 }
            return try Self.evict(channelID: channelID, keepingNewest: maxPosts, in: db)
        }
    }

    // MARK: Reads

    func post(_ postID: String) throws -> MMPost? {
        try store.read { db in
            try MMPost.fetchOne(db, sql: "SELECT * FROM post WHERE id = ?", arguments: [postID])
        }
    }

    func posts(inChannel channelID: String, before createAt: Int64?, limit: Int) throws -> [MMPost] {
        guard limit > 0 else { return [] }
        return try store.read { db in
            try MMPost.fetchAll(db, sql: """
                SELECT * FROM post
                 WHERE channel_id = :channel
                   AND (:before IS NULL OR create_at < :before)
                 ORDER BY create_at DESC, id DESC
                 LIMIT :limit
                """, arguments: ["channel": channelID, "before": createAt, "limit": limit])
        }
    }

    func posts(inThread rootID: String, limit: Int) throws -> [MMPost] {
        guard limit > 0 else { return [] }
        return try store.read { db in
            // The root plus its newest replies, then re-sorted oldest-first for rendering.
            // Upstream reads the thread through `PostsInThread` windows; a direct `root_id` scan
            // uses `idx_post_root_window` and returns the same rows for a bounded thread.
            let replies = try MMPost.fetchAll(db, sql: """
                SELECT * FROM post
                 WHERE root_id = :root
                 ORDER BY create_at DESC, id DESC
                 LIMIT :limit
                """, arguments: ["root": rootID, "limit": max(0, limit - 1)])
            let root = try MMPost.fetchOne(db, sql: "SELECT * FROM post WHERE id = ?",
                                           arguments: [rootID])
            return (root.map { [$0] } ?? []) + Array(replies.reversed())
        }
    }

    func pinnedPosts(inChannel channelID: String, limit: Int) throws -> [MMPost] {
        guard limit > 0 else { return [] }
        return try store.read { db in
            try MMPost.fetchAll(db, sql: """
                SELECT * FROM post
                 WHERE channel_id = :channel AND is_pinned = 1
                 ORDER BY create_at DESC, id DESC
                 LIMIT :limit
                """, arguments: ["channel": channelID, "limit": limit])
        }
    }

    func reactions(postID: String) throws -> [MMReaction] {
        try store.read { db in
            try MMReaction.fetchAll(db, sql: """
                SELECT * FROM post_reaction WHERE post_id = ? ORDER BY create_at ASC, emoji_name ASC
                """, arguments: [postID])
        }
    }

    func files(postID: String) throws -> [MMFileInfo] {
        try store.read { db in
            try MMFileInfo.fetchAll(db, sql: "SELECT * FROM file_info WHERE post_id = ? ORDER BY name ASC",
                                    arguments: [postID])
        }
    }

    func count(inChannel channelID: String) throws -> Int {
        try store.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM post WHERE channel_id = ?",
                             arguments: [channelID]) ?? 0
        }
    }

    // MARK: - Shared statement bodies (usable from an open transaction)

    static func insert(_ post: MMPost, into db: Database) throws {
        var values = MMRowValues()
        values.set("id", post.id)
        values.set("channel_id", post.channelId)
        values.set("user_id", post.userId)
        values.set("root_id", post.rootId)
        values.set("original_id", post.originalId)
        values.set("message", post.message)
        values.set("message_source", post.messageSource)
        values.set("type", post.type)
        values.set("props", MMJSONColumn.text(post.props) ?? "{}")
        values.setJSON("metadata", post.metadata)
        values.set("file_ids", MMJSONColumn.idArrayText(post.fileIds))
        values.set("create_at", post.createAt)
        values.set("update_at", post.updateAt)
        values.set("edit_at", post.editAt)
        values.set("delete_at", post.deleteAt)
        values.set("is_pinned", post.isPinned)
        values.set("reply_count", post.replyCount)
        values.set("last_reply_at", post.lastReplyAt)
        values.set("is_following", post.isFollowing)
        // `update_at` guard: stale payloads lose (see `upsertSQL`).
        try values.executeUpsert(db, table: MMStoreTable.post, versionColumn: "update_at")
    }

    /// Deletes every post of `channelID` older than the newest `keepingNewest`, together with the
    /// reaction and file rows that hang off them, and returns how many posts went away.
    ///
    /// Three rules, all of them in this one transaction (T29-AV F1, F6):
    ///
    ///  1. **The window is on posts** — the newest `keepingNewest` by `create_at` survive.
    ///  2. **Pinned posts are outside the window**: `is_pinned = 1` rows are never selected for
    ///     deletion, so a channel can hold the window *plus* its pinned posts. The Pinned screen has
    ///     nothing to render offline if eviction eats them, and the server can only re-supply them
    ///     when it is reachable.
    ///  3. **A reply never outlives its root.** Replies are always newer than the root they answer,
    ///     so the window drops the root first and used to leave its replies behind as orphans: a whole
    ///     channel page could be replies whose root no longer existed, and `posts(inThread:)` returned
    ///     them without a root. Every post whose `root_id` is in the doomed set is deleted in the same
    ///     transaction. One level is enough — a Mattermost thread is root plus replies, so a reply has
    ///     no children of its own.
    ///
    /// Consequence, stated rather than hidden: a channel dominated by one huge thread can be trimmed
    /// to nothing (its root falls out of the window, and every reply goes with it). That is the
    /// intended trade — an empty channel re-fetches on the next sync, an orphaned page never heals.
    ///
    /// Chunked: a busy channel can be trimmed by tens of thousands of rows in one call, and SQLite's
    /// bound-variable limit is 999 on older builds.
    @discardableResult
    static func evict(channelID: String, keepingNewest keeping: Int, in db: Database) throws -> Int {
        let keep = max(0, keeping)
        let windowIDs = try String.fetchAll(db, sql: """
            SELECT id FROM post
             WHERE channel_id = ? AND is_pinned = 0
             ORDER BY create_at DESC, id DESC
             LIMIT -1 OFFSET ?
            """, arguments: [channelID, keep])
        guard !windowIDs.isEmpty else { return 0 }

        var doomed = windowIDs
        var seen = Set(windowIDs)
        for replyID in try repliesOfDoomedRoots(windowIDs, in: db) where seen.insert(replyID).inserted {
            doomed.append(replyID)
        }

        let chunkSize = 400
        var index = 0
        while index < doomed.count {
            let chunk = Array(doomed[index..<min(index + chunkSize, doomed.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            try db.execute(sql: "DELETE FROM post_reaction WHERE post_id IN (\(placeholders))",
                           arguments: StatementArguments(chunk))
            try db.execute(sql: "DELETE FROM file_info WHERE post_id IN (\(placeholders))",
                           arguments: StatementArguments(chunk))
            try db.execute(sql: "DELETE FROM post WHERE id IN (\(placeholders))",
                           arguments: StatementArguments(chunk))
            index += chunkSize
        }
        return doomed.count
    }

    /// Replies whose `root_id` is one of `rootIDs`, chunked to stay inside SQLite's bound-variable
    /// limit. The `root_id` values come from the eviction window, so they are never empty strings and
    /// a post that is itself a root can never match.
    private static func repliesOfDoomedRoots(_ rootIDs: [String], in db: Database) throws -> [String] {
        let chunkSize = 400
        var replies: [String] = []
        var index = 0
        while index < rootIDs.count {
            let chunk = Array(rootIDs[index..<min(index + chunkSize, rootIDs.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            replies += try String.fetchAll(db, sql: """
                SELECT id FROM post WHERE root_id IN (\(placeholders))
                """, arguments: StatementArguments(chunk))
            index += chunkSize
        }
        return replies
    }
}
