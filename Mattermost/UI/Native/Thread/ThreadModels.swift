// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/utils/thread/index.ts (the activity key a thread list is ordered by),
//        app/screens/thread/thread_post_list/thread_post_list.tsx (root + replies as one list,
//        `thread.viewed_at` for the unread divider),
//        app/actions/websocket/threads.ts / app/actions/remote/thread.ts (what the counters mean
//        when a thread is followed, read, or updated).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §13; no
// upstream source copied. The decomposition (a `Codable` payload type in `Core/MM`, a pure
// derivation enum here, a service seam, one observable model) is this repo's own
// (docs/component-map.md §1) and mirrors T34's `PostListModels`/`ChannelViewModel` pair.
//
// The wire types (`MMThread`, `MMThreadList`, `ThreadTotals`) live in `Core/MM/MMThreadTypes.swift`
// because `SocketEvent` decodes `thread_updated` into the same `MMThread` the REST calls return.
// This file is the presentation rule — ordering, counts, participant stacks, badge copy — and has
// no I/O and no clock of its own.
//
// Measured contract, pinned by `MattermostTests/T36ThreadModelsTests` and
// `scripts/t36_thread_probe.py` against the local 9.11.19 server:
//  - a thread object carries `id, reply_count, last_reply_at, last_viewed_at, participants, post,
//    unread_replies, unread_mentions, is_urgent, delete_at` — and **no `is_following`**: the thread
//    list is the set of threads I follow, and `GET /users/me/teams/{t}/threads/{id}` answers 404
//    once unfollowed.
//  - `post.reply_count` inside a thread object can lag the thread's own `reply_count` (measured:
//    thread 2, post 0). The thread's field is the authority for the reply-count line.
//  - a deleted reply is **omitted** from `GET /posts/{id}/thread` (order and posts both), even with
//    `includeDeleted=true` (the server ignores the parameter). A tombstone therefore only survives
//    in a client that keeps the reply it already had — which is what `ThreadDerivation.merge`
//    does, and what the acceptance criterion "including … deleted replies" means in practice.

import Foundation

// MARK: - Unread state

/// What a thread's unread counters mean to a reader.
struct ThreadUnread: Equatable, Sendable {
    var replies: Int = 0
    var mentions: Int = 0
    var isUrgent: Bool = false

    static let none = ThreadUnread()

    var isUnread: Bool { replies > 0 || mentions > 0 }

    /// The badge's text: mentions win over replies (a mention is the thing a reader must answer).
    var badge: String? {
        if mentions > 0 { return mentions == 1 ? "1 mention" : "\(mentions) mentions" }
        if replies > 0 { return replies == 1 ? "1 new reply" : "\(replies) new replies" }
        return nil
    }

    /// What a VoiceOver reader hears for the badge; `nil` when there is nothing to announce.
    var accessibilityLabel: String? {
        guard let badge else { return nil }
        return isUrgent ? "\(badge), urgent" : badge
    }
}

extension MMThread {
    /// The unread counters this thread reports, as one drawable value.
    var unread: ThreadUnread {
        ThreadUnread(replies: unreadReplies, mentions: unreadMentions, isUrgent: isUrgent)
    }
}

// MARK: - Derivation (pure; no I/O, no clock of its own)

/// Everything a thread pane derives from what the server sent, as one testable surface.
enum ThreadDerivation {

    /// How many participant avatars a root row draws before it collapses into "+N". Upstream draws
    /// a short stack; four is the widest that fits the reply line at the default text size.
    static let participantLimit = 4

    // MARK: The reply chain

    /// The chain a thread pane renders: the root first, then its replies oldest-first.
    ///
    /// The rules, each pinned by a test:
    ///  - the root is always first, even though `GET /posts/{id}/thread` returns it among the
    ///    replies — one root, one row;
    ///  - a post whose `root_id` is not this root is dropped (a page fetched with a stale cursor, or
    ///    a post from another channel) instead of being drawn as a reply to this thread;
    ///  - replies keep the server's order (`create_at`, then id as a deterministic tiebreak), which
    ///    is the order a conversation reads in;
    ///  - a tombstoned reply stays in the chain: the server omits it from later fetches (measured),
    ///    but a reader who saw it must see it become "This message was deleted", not vanish.
    static func chain(root: MMPost, replies: [MMPost]) -> [MMPost] {
        let accepted = replies.filter { post in
            !post.id.isEmpty && post.id != root.id && post.rootId == root.id
        }
        return [root] + sortedOldestFirst(dedupe(accepted))
    }

    /// Drop a repeated id, keeping the **last** occurrence (the freshest revision of a post).
    static func dedupe(_ posts: [MMPost]) -> [MMPost] {
        var order: [String] = []
        var latest: [String: MMPost] = [:]
        for post in posts where !post.id.isEmpty {
            if latest[post.id] == nil { order.append(post.id) }
            latest[post.id] = post
        }
        return order.compactMap { latest[$0] }
    }

    static func sortedOldestFirst(_ posts: [MMPost]) -> [MMPost] {
        posts.sorted { lhs, rhs in
            if lhs.createAt != rhs.createAt { return lhs.createAt < rhs.createAt }
            return lhs.id < rhs.id
        }
    }

    /// Merge an older/newer reply page into what the pane already holds.
    ///
    /// A reply that arrives twice (a page overlap, or the socket echo of a send) is **replaced** by
    /// its freshest version, never appended twice; a reply the pane already holds but the new page
    /// does not carry is kept (a tombstone the server has since dropped from the endpoint).
    static func merge(existing: [MMPost], page: [MMPost], rootID: String) -> [MMPost] {
        let incoming = page.filter { !$0.id.isEmpty && $0.id != rootID && $0.rootId == rootID }
        return sortedOldestFirst(dedupe(existing + incoming))
    }

    // MARK: Reply count

    /// The number the reply line and the channel row both draw.
    ///
    /// The server's count is the truth when it is larger than what is loaded: the pane may hold only
    /// the newest page of a long thread, and a count that shrank to the page size would be a lie the
    /// reader can see against the server. A locally loaded reply the server has not counted yet (the
    /// socket beat the `thread_updated` frame) is never smaller than the chain, so the maximum is the
    /// honest answer in both directions.
    static func replyCount(root: MMPost, replies: [MMPost], serverCount: Int) -> Int {
        max(serverCount, root.replyCount, loadedReplyCount(replies))
    }

    static func loadedReplyCount(_ replies: [MMPost]) -> Int {
        replies.filter { !$0.id.isEmpty && $0.deleteAt == 0 }.count
    }

    /// "3 replies" / "1 reply", the label next to the participant avatars.
    static func replyLabel(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 reply" : "\(count) replies"
    }

    // MARK: Participants

    /// The avatars a root row draws: the people in the thread, most recent activity first.
    ///
    /// The server sends `participants` on a root when the page asks for thread-collapsed posts
    /// (`collapsedThreadsExtended=true` gives full profiles, measured). When it does not — an older
    /// page, or a reply that arrived over the socket — the chain itself is the source: the loaded
    /// reply authors (newest reply first), then the root's author. Both paths produce the same
    /// shape, so the row draws avatars whatever the server managed to include.
    static func participants(root: MMPost,
                             replies: [MMPost],
                             users: [String: MMUser],
                             limit: Int = participantLimit) -> [PostAuthor] {
        // The server's own list first (it is ordered by most recent activity and carries the profiles
        // the page asked for), then whoever the loaded chain shows the server left out — a reply that
        // arrived over the socket after the page was fetched.
        var authors = PostListDerivation.participantAuthors(participants: root.participants ?? [],
                                                            users: users,
                                                            limit: limit)
        var seen = Set(authors.map(\.id))
        let derived = replies.reversed().map(\.userId).filter { !$0.isEmpty } + [root.userId]
        for id in derived where !seen.contains(id) {
            authors.append(author(for: users[id] ?? MMUser(id: id)))
            seen.insert(id)
        }
        return Array(authors.prefix(max(0, limit)))
    }

    /// One person as the avatar stack draws them; forwards to the one rule in `PostListDerivation`.
    static func author(for user: MMUser) -> PostAuthor {
        PostListDerivation.author(for: user)
    }

    // MARK: Followed threads

    /// The activity instant a thread is ordered by — the newest of its last reply and its own
    /// creation (upstream `getThreadsListEdges` computes the same maximum). `last_viewed_at` is
    /// deliberately **not** part of it: reading a thread must not reorder the list under the reader
    /// (upstream uses it only to pick the list's edges).
    static func activityAt(_ thread: MMThread) -> Int64 {
        max(thread.lastReplyAt, thread.post.createAt)
    }

    /// Newest activity first, id as the deterministic tiebreak.
    ///
    /// The server already answers in this order; the client sorts anyway because a merge of two
    /// pages, or a `thread_updated` for an old thread, must land in the position a reader expects.
    static func sorted(_ threads: [MMThread]) -> [MMThread] {
        threads.sorted { lhs, rhs in
            let lhsAt = activityAt(lhs), rhsAt = activityAt(rhs)
            if lhsAt != rhsAt { return lhsAt > rhsAt }
            return lhs.id > rhs.id
        }
    }

    /// Merge a page into the list, newest revision per thread id winning.
    static func mergeThreads(existing: [MMThread], page: [MMThread]) -> [MMThread] {
        var byID: [String: MMThread] = [:]
        for thread in existing where !thread.id.isEmpty { byID[thread.id] = thread }
        for thread in page where !thread.id.isEmpty { byID[thread.id] = thread }
        return sorted(Array(byID.values))
    }

    /// The `before` cursor for the next page, or `nil` when this page was the last.
    ///
    /// The cursor is the **last thread id the server sent**, not the last one kept: `before` is
    /// exclusive, so a page whose rows were all duplicates must still advance or paging stalls
    /// (T34's rule for the channel page, applied here for the same reason).
    static func nextBeforeCursor(page: MMThreadList, pageSize: Int) -> String? {
        guard page.includesThreads, page.threads.count >= pageSize else { return nil }
        return page.threads.last?.id
    }

    /// Whether another page exists behind `page`.
    ///
    /// A full page means "ask again"; a short page ends the list. `total` is consulted when the
    /// server sent one, because the unread filter can answer a full page that is also the last.
    static func hasMore(page: MMThreadList, pageSize: Int) -> Bool {
        guard page.includesThreads else { return false }
        guard page.threads.count >= pageSize else { return false }
        if page.total > 0 { return page.threads.count < page.total }
        return true
    }

    // MARK: Row diagnostics

    /// The ids a pane draws, in order (diagnostics + UI-test seams).
    static func chainIDs(root: MMPost, replies: [MMPost]) -> [String] {
        chain(root: root, replies: replies).map(\.id)
    }
}
