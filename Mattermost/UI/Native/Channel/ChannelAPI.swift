// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/client/rest/posts.ts (`getPosts` `/channels/{id}/posts` with `before`, `per_page`),
//        app/client/rest/files.ts (`getFile`, `getFileThumbnail`).
// Licence: Apache-2.0 — endpoints reimplemented against https://api.mattermost.com with attribution
// per docs/THIRD_PARTY_NOTICES.md §10; no upstream source copied.
//
// T34 adds only what T28's endpoint group does not already cover: the *unconditional* channel page
// (T28's `posts(channelID:page:)` is a generic conditional GET) and file bytes. The channel and the
// batched profiles are T28's own `channel(id:)` / `users(ids:)` and are used from there rather than
// redeclared here.
//
// Why this page is unconditional: a 304 replay of a channel page would hand back the previous page
// (with the previous `order`) after an edit, a delete or a new post — the stale-badge failure T32
// forbids on the unread endpoints, and here it would mean a message the reader can see on the server
// but not in the list. A channel page is also cheap and cursor-keyed, so there is nothing to save.

import Foundation

extension APIClient {

    /// `GET /channels/{channel_id}/posts?per_page=&before=&collapsedThreads=` — one page of a channel,
    /// newest first, **top-level posts only**.
    ///
    /// `page.cursor == .page(0)` asks for the newest page; `.before(oldestLoadedID)` asks for the page
    /// older than what the reader already holds (the cursor the server's own `next_post_id` implies).
    ///
    /// `collapsedThreads=true` is the server's own thread-collapsed view of the channel: it answers
    /// with the channel's root posts and leaves the replies to `GET /posts/{id}/thread`, which is what
    /// a thread-collapsed Mattermost centre timeline shows. Measured on the pinned 9.11.19 server
    /// (perf-feed: 503 posts = 215 roots + 288 replies, T34-R5): without the parameter a 60-post page
    /// came back 25 roots + 35 replies, and the client drew all 60 as top-level rows; with it, 60
    /// roots, 0 replies, and `before`-paging over the roots walked the same 215 ids as an unfiltered
    /// walk's roots with no gap and no duplicate. The view model still applies the same rule to what
    /// arrives (`ChannelViewModel.isTimelineRow`), because a proxy that strips an unknown query
    /// parameter must not turn replies into rows.
    func channelPosts(channelID: String, page: MMPostPage,
                      collapsedThreads: Bool = true) async throws -> MMPostList {
        var query = page.queryItems
        if collapsedThreads {
            query.append(URLQueryItem(name: "collapsedThreads", value: "true"))
            // T36: the same page also carries each root's thread participants. Without the extended
            // form the server answers id-only stubs (measured: `username` empty), which is enough for
            // an avatar but not for a name; with it, the row's participant stack is drawable from
            // this one page instead of a follow-up request per root (~500 bytes on a 31-root page).
            query.append(URLQueryItem(name: "collapsedThreadsExtended", value: "true"))
        }
        return try await get(MMPostList.self,
                             path: "/channels/\(channelID)/posts",
                             query: query,
                             useETag: false)
    }

    /// `GET /files/{file_id}/thumbnail` (a JPEG the server generates) or the file's own bytes.
    ///
    /// A thumbnail endpoint answers 404 for an image too small to have one, so the caller can ask for
    /// the original bytes with `thumbnail: false` — the row then scales them down itself.
    func fileBytes(fileID: String, thumbnail: Bool) async throws -> Data {
        try await getData(path: "/files/\(fileID)\(thumbnail ? "/thumbnail" : "")")
    }

    /// `GET /channels/{channel_id}/members/me` — my membership row.
    ///
    /// T34 needs one field from it, `last_viewed_at`: it is the only honest source for where the
    /// "New messages" line goes (the channel page itself carries no read state). Unread counts live
    /// in the same row and are T32/T33's to render, not this pane's.
    func channelMembership(channelID: String) async throws -> MMChannelMember {
        try await get(MMChannelMember.self, path: "/channels/\(channelID)/members/me", useETag: false)
    }

    /// `GET /emoji?page=&per_page=&sort=` — the team's custom emoji, one page at a time.
    ///
    /// The list is small and changes rarely, so there is no ETag: a stale cached answer would hide a
    /// newly added emoji behind a shortcode until the app restarted.
    func customEmoji(page: Int, perPage: Int) async throws -> [MMEmoji] {
        try await get([MMEmoji].self,
                      path: "/emoji",
                      query: [URLQueryItem(name: "page", value: String(page)),
                              URLQueryItem(name: "per_page", value: String(perPage)),
                              URLQueryItem(name: "sort", value: "")],
                      useETag: false)
    }

    /// `GET /emoji/{emoji_id}/image` — the PNG the server generated when the emoji was uploaded.
    func emojiImage(emojiID: String) async throws -> Data {
        try await getData(path: "/emoji/\(emojiID)/image", useETag: false)
    }
}
