// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: `app/client/rest/posts.ts` (`searchPosts`, `getFlaggedPosts`, `getPinnedPosts`, `pinPost`,
//        `unpinPost`), `app/client/rest/preferences.ts` + `app/actions/remote/preference.ts`
//        (save/unsave a post = the `flagged_post` preference), `app/client/rest/channels.ts`
//        (`getChannelsByIds`, the result row's channel name).
// Licence: Apache-2.0 — endpoints reimplemented against https://api.mattermost.com; no upstream
// source copied. Attribution: docs/THIRD_PARTY_NOTICES.md §16.
//
// Every path below was exercised against the pinned server (Mattermost **9.11.19**, build
// 16643067630, `ActiveSearchBackend: database`) by `scripts/t39_search_probe.py` /
// `scripts/t39_saved_pinned_probe.py`. What that measurement changed vs. the card's reference:
//
//  - **Saved posts**: `/users/me/teams/{team}/posts/saved` **404s** on 9.11.19 (the path the card
//    warned "has moved"); `/users/me/posts/flagged?team_id=…` answers 200 with the same shape. The
//    primary path here is the one that answers, and the newer team-scoped path is kept as a fallback
//    so a server that only has that one still works. Both are tried in a fixed order and the order is
//    unit-tested (`T39SearchAPITests`).
//  - **Saving a post**: `POST /posts/{id}/flag` and `/unflag` **404** on 9.11.19 — there is no flag
//    route. Saving is the `flagged_post` **preference** (measured: writing it makes the post appear in
//    `/users/me/posts/flagged`, deleting it removes it).
//  - **Pinning**: `POST /posts/{id}/pin` / `/unpin` answer `{"status":"OK"}` and
//    `GET /channels/{id}/pinned` then contains/drops the post (measured, `is_pinned: true` on the row).

import Foundation

extension APIClient {

    // MARK: - Search

    /// `POST /teams/{team_id}/posts/search`.
    ///
    /// `page`/`per_page` travel in the body because the documented request body carries them; the
    /// endpoint honours them only on an Elasticsearch backend (see `SearchResults.swift`).
    func searchPosts(teamID: String, body: SearchQuery.Body) async throws -> MMSearchResults {
        try await post(MMSearchResults.self, path: "/teams/\(teamID)/posts/search", body: body)
    }

    // MARK: - Saved posts

    /// The saved/flagged posts of the signed-in user, newest flagged first.
    ///
    /// Primary: `GET /users/me/posts/flagged?team_id=&page=&per_page=` (9.11.19). Fallback (only on a
    /// 404, and only when a team is known): `GET /users/me/teams/{team}/posts/saved`, the newer
    /// team-scoped spelling some server versions carry.
    func savedPosts(teamID: String?, page: Int, perPage: Int) async throws -> MMPostList {
        var query = [URLQueryItem(name: "page", value: String(max(0, page))),
                     URLQueryItem(name: "per_page", value: String(min(max(1, perPage), 200)))]
        if let teamID, !teamID.isEmpty {
            query.append(URLQueryItem(name: "team_id", value: teamID))
        }
        do {
            return try await get(MMPostList.self,
                                 path: "/users/me/posts/flagged",
                                 query: query,
                                 useETag: false)
        } catch MMError.notFound {
            guard let teamID, !teamID.isEmpty else { throw MMError.notFound }
            let fallbackQuery = [URLQueryItem(name: "page", value: String(max(0, page))),
                                 URLQueryItem(name: "per_page", value: String(min(max(1, perPage), 200)))]
            return try await get(MMPostList.self,
                                 path: "/users/me/teams/\(teamID)/posts/saved",
                                 query: fallbackQuery,
                                 useETag: false)
        }
    }

    /// `PUT /users/{user_id}/preferences` — save a post (`flagged_post` = the post id, value `true`).
    func savePost(postID: String, userID: String) async throws {
        let preference = MMPreference(userId: userID, category: Self.savedPostCategory,
                                      name: postID, value: "true")
        try await putForResponse(path: "/users/\(userID)/preferences", body: [preference])
    }

    /// `POST /users/{user_id}/preferences/delete` — unsave (the delete verb the API documents for a
    /// preference list).
    func unsavePost(postID: String, userID: String) async throws {
        let preference = MMPreference(userId: userID, category: Self.savedPostCategory,
                                      name: postID, value: "true")
        try await postForResponse(path: "/users/\(userID)/preferences/delete",
                                  body: try encode([preference]))
    }

    /// The preference category the clients use for a saved post (upstream `Preferences.CATEGORIES.SAVED_POST`).
    static let savedPostCategory = "flagged_post"

    // MARK: - Pinned posts

    /// `GET /channels/{channel_id}/pinned`.
    func pinnedPosts(channelID: String, page: Int = 0, perPage: Int = 60) async throws -> MMPostList {
        let query = [URLQueryItem(name: "page", value: String(max(0, page))),
                     URLQueryItem(name: "per_page", value: String(min(max(1, perPage), 200)))]
        return try await get(MMPostList.self,
                             path: "/channels/\(channelID)/pinned",
                             query: query,
                             useETag: false)
    }

    /// `POST /posts/{id}/pin` (answer is `{"status":"OK"}`).
    func pinPost(id: String) async throws {
        try await postForResponse(path: "/posts/\(id)/pin", body: nil)
    }

    /// `POST /posts/{id}/unpin`.
    func unpinPost(id: String) async throws {
        try await postForResponse(path: "/posts/\(id)/unpin", body: nil)
    }

    // MARK: - Channels by id (result subtitles)

    /// `POST /teams/{team_id}/channels/ids` — the channels a result window names.
    ///
    /// A search answer carries posts only, so the row's "#channel" line needs one batched lookup. The
    /// team-scoped form is used (rather than per-channel `GET /channels/{id}`) because the sidebar
    /// already knows the team and one request beats one per row.
    func channels(ids: [String], teamID: String) async throws -> [MMChannel] {
        guard !ids.isEmpty else { return [] }
        return try await post([MMChannel].self, path: "/teams/\(teamID)/channels/ids", body: ids)
    }
}
