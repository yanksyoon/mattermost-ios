// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/actions/remote/thread.ts (`fetchThread`, `fetchThreads`, `markThreadAsRead`,
//        `markThreadAsUnread`, `updateThreadFollowing` — each one a client call plus the local
//        bookkeeping this client does in memory), app/screens/thread/thread_post_list/.
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §13; no
// upstream source copied. The protocol/implementation split is this repo's own
// (docs/component-map.md §1), matching `ChannelServing`/`SessionChannelService` from T34.

import Foundation

/// What a thread pane and the global threads list need from one server.
///
/// Split from the view models for the same reason `ChannelServing` is: the rules that matter
/// (chain ordering, paging cursors, follow/unfollow persistence, unread arithmetic) are testable
/// against a fake, and the production implementation is the only place that knows about
/// `AuthSession`/`APIClient`.
@MainActor
protocol ThreadServing: AnyObject {
    /// One page of a thread: the root plus replies, root-first.
    func thread(postID: String, fromPost: String?, fromCreateAt: Int64?, perPage: Int) async throws -> MMPostList

    /// One page of the team's followed threads, newest activity first. The page also carries the
    /// team's counters (`MMThreadList.totals`), measured on 9.11.19 — no separate call is needed.
    func threads(teamID: String, before: String?, perPage: Int, unreadOnly: Bool) async throws -> MMThreadList

    /// The thread row for one thread, or `nil` when I do not follow it (the server answers 404).
    func followedThread(teamID: String, threadID: String) async throws -> MMThread?

    /// Follow (`true`) or unfollow (`false`) — the write; the state is re-read or patched by the caller.
    func setFollowing(teamID: String, threadID: String, following: Bool) async throws

    /// Mark the thread read up to `at`; the answer carries the server's new counters.
    func markRead(teamID: String, threadID: String, at: Int64) async throws -> MMThread

    /// Mark the thread unread from `postID`; the answer carries the server's new counters.
    func markUnread(teamID: String, threadID: String, postID: String) async throws -> MMThread

    /// One post (a root opened from a permalink, or a thread row's root).
    func post(id: String) async throws -> MMPost

    /// Author profiles for the ids on screen, in one batched request.
    func users(ids: [String]) async throws -> [MMUser]

    /// `POST /reactions` — a reaction write from the thread pane (S16/T37).
    ///
    /// Defaults to a failure, so a service that has not implemented the write path still draws
    /// reactions and reports an error on a tap instead of silently ignoring it.
    func addReaction(postID: String, emojiName: String, userID: String) async throws -> MMReaction

    /// `DELETE /users/{user_id}/posts/{post_id}/reactions/{emoji_name}`.
    func removeReaction(postID: String, emojiName: String, userID: String) async throws

    /// Page size, injectable so a test can page a fixture without 60 real threads.
    var pageSize: Int { get }
}

extension ThreadServing {
    var pageSize: Int { 60 }
    /// A service that has not implemented the batched profile call simply renders id-only avatars;
    /// it must never fail a whole thread because a face is missing.
    func users(ids: [String]) async throws -> [MMUser] { [] }
    func addReaction(postID: String, emojiName: String, userID: String) async throws -> MMReaction {
        throw MMError.notFound
    }
    func removeReaction(postID: String, emojiName: String, userID: String) async throws {
        throw MMError.notFound
    }
}

/// The production implementation: the server's own `AuthSession.client`, resolved **per call** so a
/// service created before the session finished restoring is not a permanently signed-out one (the
/// same reason `SessionChannelService` resolves per call).
@MainActor
final class SessionThreadService: ThreadServing {
    private let resolve: () -> APIClient?
    let pageSize: Int

    init(pageSize: Int = 60, resolve: @escaping () -> APIClient?) {
        self.pageSize = pageSize
        self.resolve = resolve
    }

    private func client() throws -> APIClient {
        guard let client = resolve() else { throw MMError.notSignedIn }
        return client
    }

    func thread(postID: String, fromPost: String?, fromCreateAt: Int64?,
                perPage: Int) async throws -> MMPostList {
        try await client().thread(postID: postID, fromPost: fromPost,
                                  fromCreateAt: fromCreateAt, perPage: perPage)
    }

    func threads(teamID: String, before: String?, perPage: Int,
                 unreadOnly: Bool) async throws -> MMThreadList {
        try await client().userThreads(teamID: teamID, before: before, perPage: perPage,
                                       unreadOnly: unreadOnly, totalsOnly: false)
    }

    func followedThread(teamID: String, threadID: String) async throws -> MMThread? {
        try await client().followedThread(teamID: teamID, threadID: threadID)
    }

    func setFollowing(teamID: String, threadID: String, following: Bool) async throws {
        try await client().followThread(teamID: teamID, threadID: threadID, following: following)
    }

    func markRead(teamID: String, threadID: String, at: Int64) async throws -> MMThread {
        try await client().markThreadRead(teamID: teamID, threadID: threadID, timestamp: at)
    }

    func markUnread(teamID: String, threadID: String, postID: String) async throws -> MMThread {
        try await client().markThreadUnread(teamID: teamID, threadID: threadID, postID: postID)
    }

    func post(id: String) async throws -> MMPost {
        try await client().post(id: id)
    }

    func users(ids: [String]) async throws -> [MMUser] {
        // A profile failure must not fail the thread: rows fall back to the id-derived avatar, which
        // is still ordered and still says which post belongs to whom.
        (try? await client().users(ids: ids)) ?? []
    }

    /// S16/T37: the thread pane's reaction writes go through the same `APIClient` endpoints as the
    /// channel pane's; the alias is canonicalised by the caller (`thumbsup` → `+1`).
    func addReaction(postID: String, emojiName: String, userID: String) async throws -> MMReaction {
        try await client().addReaction(postID: postID, emojiName: emojiName, userID: userID)
    }

    func removeReaction(postID: String, emojiName: String, userID: String) async throws {
        try await client().removeReaction(postID: postID, emojiName: emojiName, userID: userID)
    }
}
