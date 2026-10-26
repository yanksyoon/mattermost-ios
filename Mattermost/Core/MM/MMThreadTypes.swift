// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/actions/remote/thread.ts (the `Thread` shape `fetchThreads`/`fetchThread` return),
//        app/actions/websocket/threads.ts (`thread_updated`'s `data.thread`).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §13; no
// upstream source copied.
//
// Why these live under `Core/MM` rather than beside the thread screens: `SocketEvent` (the transport
// layer) decodes `thread_updated`'s payload into the same type the REST calls return, and the
// transport must not depend on a view's file. `MMPost`/`MMPostList` sit here for exactly the same
// reason. The *derivation* (ordering, unread copy, participant stacks) stays in
// `UI/Native/Thread/ThreadModels.swift`.
//
// Measured contract, pinned by `MattermostTests/T36ThreadModelsTests` and
// `scripts/t36_thread_probe.py` against the local 9.11.19 server:
//  - a thread object (from the thread list, `thread_updated`, or the read/unread answer) carries
//    `id, reply_count, last_reply_at, last_viewed_at, participants, post, unread_replies,
//    unread_mentions, is_urgent, delete_at` — and **no `is_following`**: the thread list is the set
//    of threads I follow, and `GET /users/me/teams/{t}/threads/{id}` answers 404 once unfollowed.
//  - `post.reply_count` inside a thread object can lag the thread's own `reply_count` (measured:
//    thread 2, post 0). The thread's field is the authority for the reply-count line.
//  - a deleted reply is **omitted** from `GET /posts/{id}/thread` (order and posts both), even with
//    `includeDeleted=true` (the server ignores the parameter). A tombstone therefore only survives
//    in a client that keeps the reply it already had — which is what `ThreadDerivation.merge`
//    does, and what the acceptance criterion "including … deleted replies" means in practice.

import Foundation

/// One thread as the thread endpoints, `thread_updated` and `thread_follow_changed` describe it.
///
/// Identity is the **root post id** (`post.id` and `id` are the same value in every measured
/// payload); `post` is the root the pane draws first.
struct MMThread: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var replyCount: Int
    var lastReplyAt: Int64
    var lastViewedAt: Int64
    var participants: [MMUser]
    var post: MMPost
    var unreadReplies: Int
    var unreadMentions: Int
    var isUrgent: Bool
    var deleteAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, participants, post
        case replyCount = "reply_count"
        case lastReplyAt = "last_reply_at"
        case lastViewedAt = "last_viewed_at"
        case unreadReplies = "unread_replies"
        case unreadMentions = "unread_mentions"
        case isUrgent = "is_urgent"
        case deleteAt = "delete_at"
    }

    init(id: String,
         replyCount: Int = 0,
         lastReplyAt: Int64 = 0,
         lastViewedAt: Int64 = 0,
         participants: [MMUser] = [],
         post: MMPost = MMPost(id: ""),
         unreadReplies: Int = 0,
         unreadMentions: Int = 0,
         isUrgent: Bool = false,
         deleteAt: Int64 = 0) {
        self.id = id
        self.replyCount = replyCount
        self.lastReplyAt = lastReplyAt
        self.lastViewedAt = lastViewedAt
        self.participants = participants
        self.post = post
        self.unreadReplies = unreadReplies
        self.unreadMentions = unreadMentions
        self.isUrgent = isUrgent
        self.deleteAt = deleteAt
    }

    /// Tolerant decoding, the same rule `MMPost`/`MMUser` follow: a field an older or newer server
    /// omits becomes its zero value instead of failing the whole list. Only `id` is identity.
    ///
    /// `id` falls back to `post.id` because one measured shape (`thread_updated`'s `thread`, which
    /// always carries its root) is occasionally relayed without the top-level id by proxies;
    /// `post` falls back to an empty post, which no caller can mistake for a real one.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let post = (try? values.decodeIfPresent(MMPost.self, forKey: .post)) ?? MMPost(id: "")
        let decodedID = try values.decodeIfPresent(String.self, forKey: .id) ?? ""
        id = decodedID.isEmpty ? post.id : decodedID
        self.post = post
        replyCount = try values.decodeIfPresent(Int.self, forKey: .replyCount) ?? 0
        lastReplyAt = try values.decodeIfPresent(Int64.self, forKey: .lastReplyAt) ?? 0
        lastViewedAt = try values.decodeIfPresent(Int64.self, forKey: .lastViewedAt) ?? 0
        participants = (try? values.decodeIfPresent([MMUser].self, forKey: .participants)) ?? []
        unreadReplies = try values.decodeIfPresent(Int.self, forKey: .unreadReplies) ?? 0
        unreadMentions = try values.decodeIfPresent(Int.self, forKey: .unreadMentions) ?? 0
        isUrgent = try values.decodeIfPresent(Bool.self, forKey: .isUrgent) ?? false
        deleteAt = try values.decodeIfPresent(Int64.self, forKey: .deleteAt) ?? 0
    }

    /// The reply count the pane draws: the thread's own field, never `post.reply_count` (which can
    /// lag — measured 2 vs 0 in the thread list).
    var displayedReplyCount: Int { max(replyCount, 0) }
}

/// `GET /users/me/teams/{team_id}/threads` — one page, plus the totals the same call can answer.
///
/// `threads` is **omitted** (`null`) when `totalsOnly=true`; `includesThreads` records that, so
/// "the server said none" and "the server was not asked" cannot be confused by a caller.
/// `includesTotals` does the same job for `total`: a page that omits it (measured: the field is
/// always present on 9.11.19, but a proxy or a future server may drop it) must not be read as
/// "zero threads".
struct MMThreadList: Codable, Equatable, Sendable {
    var threads: [MMThread]
    var total: Int
    var totalUnreadThreads: Int
    var totalUnreadMentions: Int
    var totalUnreadUrgentMentions: Int
    /// Whether the answer actually carried a `threads` array.
    var includesThreads: Bool
    /// Whether the answer actually carried a `total` (the counter line's source).
    var includesTotals: Bool

    enum CodingKeys: String, CodingKey {
        case threads, total
        case totalUnreadThreads = "total_unread_threads"
        case totalUnreadMentions = "total_unread_mentions"
        case totalUnreadUrgentMentions = "total_unread_urgent_mentions"
    }

    init(threads: [MMThread] = [],
         total: Int = 0,
         totalUnreadThreads: Int = 0,
         totalUnreadMentions: Int = 0,
         totalUnreadUrgentMentions: Int = 0,
         includesThreads: Bool = true,
         includesTotals: Bool = true) {
        self.threads = threads
        self.total = total
        self.totalUnreadThreads = totalUnreadThreads
        self.totalUnreadMentions = totalUnreadMentions
        self.totalUnreadUrgentMentions = totalUnreadUrgentMentions
        self.includesThreads = includesThreads
        self.includesTotals = includesTotals
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        includesThreads = values.contains(.threads)
            && (try? values.decodeIfPresent([MMThread].self, forKey: .threads)) != nil
        threads = (try? values.decodeIfPresent([MMThread].self, forKey: .threads)) ?? []
        includesTotals = values.contains(.total)
        total = try values.decodeIfPresent(Int.self, forKey: .total) ?? 0
        totalUnreadThreads = try values.decodeIfPresent(Int.self, forKey: .totalUnreadThreads) ?? 0
        totalUnreadMentions = try values.decodeIfPresent(Int.self, forKey: .totalUnreadMentions) ?? 0
        totalUnreadUrgentMentions = try values.decodeIfPresent(Int.self, forKey: .totalUnreadUrgentMentions) ?? 0
    }

    /// The counters alone, for a `totalsOnly` answer (which carries no threads).
    var totals: ThreadTotals {
        ThreadTotals(total: total,
                     unreadThreads: totalUnreadThreads,
                     unreadMentions: totalUnreadMentions,
                     unreadUrgentMentions: totalUnreadUrgentMentions)
    }
}

/// The server's own unread arithmetic for the team's threads.
struct ThreadTotals: Equatable, Sendable {
    var total: Int = 0
    var unreadThreads: Int = 0
    var unreadMentions: Int = 0
    var unreadUrgentMentions: Int = 0

    static let zero = ThreadTotals()
}
