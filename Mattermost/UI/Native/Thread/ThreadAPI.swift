// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/client/rest/threads.ts (`getThreads` `/users/me/teams/{team}/threads` with
//        extended/before/after/unread/totalsOnly/per_page, `getThread`, `markThreadAsRead`,
//        `markThreadAsUnread`, `updateThreadFollow` — PUT/DELETE `…/following`), and
//        app/client/rest/posts.ts (`getPostThread` `/posts/{id}/thread` with perPage/fromPost/
//        fromCreateAt/direction/collapsedThreads).
// Licence: Apache-2.0 — endpoints reimplemented against https://api.mattermost.com with attribution
// per docs/THIRD_PARTY_NOTICES.md §13; no upstream source copied.
//
// Measured on the pinned 9.11.19 server (`scripts/t36_thread_probe.py`, output in
// `docs/t36-build-note.md` §2):
//  - `GET /posts/{id}/thread` answers root-first, then replies ascending, in `order` + `posts`;
//    `fromPost` **requires** `fromCreateAt` (a request with only `fromPost` is a 400
//    `api.context.invalid_body_param.app_error`), which is why the paging call below passes both;
//  - `collapsedThreads=true` adds `participants` to the root, `collapsedThreadsExtended=true` makes
//    them full profiles (username/first_name) instead of id-only stubs — measured: 26,276 bytes
//    versus 25,780 for the same 31-root page, i.e. the extended form costs ~500 bytes;
//  - a deleted reply is omitted from the thread (even with `includeDeleted=true`, which the server
//    ignores) — a client keeps the tombstone it already had, never gets one back;
//  - `GET /users/me/teams/{team}/threads` carries `id, reply_count, last_reply_at, last_viewed_at,
//    participants, post, unread_replies, unread_mentions, is_urgent, delete_at` and **no
//    `is_following`** (list membership *is* following); `totalsOnly=true` answers
//    `{total, total_unread_threads, total_unread_mentions, total_unread_urgent_mentions,
//    threads: null}`;
//  - `PUT …/threads/{id}/read/{ts}` and `POST …/threads/{id}/set_unread/{post_id}` both answer the
//    **thread object** with the counters already updated, so the client takes the server's numbers
//    instead of decrementing its own;
//  - `PUT`/`DELETE …/threads/{id}/following` answer `{"status":"OK"}`, and a subsequent
//    `GET …/threads/{id}` is a **404** once unfollowed — which is how this file models "is this
//    thread followed?" without inventing a field the server does not send.
//
// `GET /users/me/teams/{team}/threads/mention_counts` (the path the card names) is **absent** from
// this server: it answers 404 `api.context.404.app_error` for every form tried. The same facts come
// from `totalsOnly=true` (`total_unread_mentions`, `total_unread_threads`), which is what
// `userThreads(totalsOnly: true)` uses; the dead path is pinned by `T36ThreadAPITests`.

import Foundation

extension APIClient {

    /// `GET /posts/{post_id}/thread` — the root and its replies, oldest page first when paging.
    ///
    /// `fromPost`/`fromCreateAt` are both required by the server when either is present (measured
    /// 400 otherwise); `nil` asks for the newest chain from the root.
    func thread(postID: String,
                fromPost: String? = nil,
                fromCreateAt: Int64? = nil,
                perPage: Int = 60) async throws -> MMPostList {
        var query = [URLQueryItem(name: "perPage", value: String(perPage)),
                     // Thread-collapsed is the mode this client reads in (the channel page asks for
                     // the same), and the extended form is what turns the root's participant stubs
                     // into profiles the avatar stack can draw.
                     URLQueryItem(name: "collapsedThreads", value: "true"),
                     URLQueryItem(name: "collapsedThreadsExtended", value: "true")]
        if let fromPost, let fromCreateAt {
            query.append(URLQueryItem(name: "fromPost", value: fromPost))
            query.append(URLQueryItem(name: "fromCreateAt", value: String(fromCreateAt)))
            query.append(URLQueryItem(name: "direction", value: "down"))
        }
        return try await get(MMPostList.self,
                             path: "/posts/\(postID)/thread",
                             query: query,
                             useETag: false)
    }

    /// `GET /users/me/teams/{team_id}/threads` — one page of the threads I follow.
    ///
    /// `before` is the **last thread id** of the previous page (the server's own list order is
    /// newest activity first). `totalsOnly` asks for the counters alone, which is the supported
    /// source of the mention counts on this server (see the file comment).
    func userThreads(teamID: String,
                     before: String? = nil,
                     perPage: Int = 60,
                     unreadOnly: Bool = false,
                     totalsOnly: Bool = false) async throws -> MMThreadList {
        var query = [URLQueryItem(name: "extended", value: "true"),
                     URLQueryItem(name: "per_page", value: String(perPage)),
                     URLQueryItem(name: "deleted", value: "false")]
        if let before, !before.isEmpty {
            query.append(URLQueryItem(name: "before", value: before))
        }
        if unreadOnly {
            query.append(URLQueryItem(name: "unread", value: "true"))
        }
        if totalsOnly {
            query.append(URLQueryItem(name: "totalsOnly", value: "true"))
        }
        return try await get(MMThreadList.self,
                             path: "/users/me/teams/\(teamID)/threads",
                             query: query,
                             useETag: false)
    }

    /// `GET /users/me/teams/{team_id}/threads/{thread_id}` — the thread row for one thread I follow.
    ///
    /// Answers `nil` for a thread I do **not** follow: the server's 404 is the only field-level
    /// answer to "am I following this?" (a measured fact, not a guess — see the file comment). A
    /// 404 is therefore mapped to `nil`, while every other error still throws so an offline pane
    /// says so instead of silently claiming "not following".
    func followedThread(teamID: String, threadID: String) async throws -> MMThread? {
        do {
            return try await get(MMThread.self,
                                 path: "/users/me/teams/\(teamID)/threads/\(threadID)",
                                 query: [URLQueryItem(name: "extended", value: "true")],
                                 useETag: false)
        } catch let error as MMError {
            if case .notFound = error { return nil }
            throw error
        }
    }

    /// `PUT|DELETE /users/me/teams/{team_id}/threads/{thread_id}/following` — follow or unfollow.
    ///
    /// Both directions answer `{"status":"OK"}`; the follow state itself is re-read through
    /// `followedThread` (or arrives on `thread_follow_changed`), because the write's answer carries
    /// no state.
    func followThread(teamID: String, threadID: String, following: Bool) async throws {
        let path = "/users/me/teams/\(teamID)/threads/\(threadID)/following"
        if following {
            _ = try await putForResponse(path: path, body: MMEmptyBody())
        } else {
            _ = try await delete(path: path)
        }
    }

    /// `PUT /users/me/teams/{team_id}/threads/{thread_id}/read/{timestamp}` — mark read up to now.
    ///
    /// The answer is the thread with its counters **already applied**, so the pane draws the
    /// server's arithmetic rather than subtracting what it thinks it saw.
    func markThreadRead(teamID: String, threadID: String, timestamp: Int64) async throws -> MMThread {
        try await put(MMThread.self,
                      path: "/users/me/teams/\(teamID)/threads/\(threadID)/read/\(timestamp)",
                      body: MMEmptyBody())
    }

    /// `POST /users/me/teams/{team_id}/threads/{thread_id}/set_unread/{post_id}` — mark unread.
    ///
    /// The answer is again the thread object with the counters the server computed (measured:
    /// `unread_replies` becomes the number of replies after `post_id`, not just 1).
    func markThreadUnread(teamID: String, threadID: String, postID: String) async throws -> MMThread {
        try await post(MMThread.self,
                       path: "/users/me/teams/\(teamID)/threads/\(threadID)/set_unread/\(postID)",
                       body: MMEmptyBody())
    }

    /// `GET /posts/{post_id}` lives in `MMEndpoints` (`APIClient.post(id:)`), not here: it is not a
    /// thread endpoint, and a second copy on the same type is a redeclaration.
}

/// The empty JSON body Mattermost's write endpoints expect (`{}`), named once so a request cannot
/// accidentally send `null`.
struct MMEmptyBody: Encodable {}
