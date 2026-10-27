// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: `app/client/rest/posts.ts` (`searchPostsWithParams`: **`teamId` empty → `POST /posts/search`**,
//        the cross-team form the mentions screen uses), `app/actions/remote/search.ts`
//        (`fetchRecentMentions`: mention keys as `terms`, `is_or_search: true`),
//        `app/client/rest/channels.ts` (`markChannelAsRead`).
// Licence: Apache-2.0 — endpoints reimplemented against https://api.mattermost.com; no upstream source
// copied. Attribution: docs/THIRD_PARTY_NOTICES.md §19.
//
// What this file adds, and what it deliberately does **not** add.
//
// Added (measured against the pinned server — Mattermost **9.11.19**, build 16643067630,
// `ActiveSearchBackend: database` — by `scripts/t42_activity_probe.py`):
//
//  - `POST /posts/search`: the mentions read. `GET /users/me/mentions` (the path the card names) **404s**,
//    and `/teams//posts/search` is normalised to a 404 too — the empty team segment does not survive the
//    router, which is why upstream branches on `teamId` and posts to the bare route. The answer is a plain
//    `MMSearchResults`, the shape the search screen already decodes.
//  - `GET /users/me` **into `ActivityProfile`**: the reader's `notify_props` are where the mention keys
//    live, and the shared `MMUser` decode does not carry them. Widening that decode would change every
//    existing caller for one screen, so this is one small type read once per feed.
//  - `GET /users/{user_id}/teams/{team_id}/channels/members`: the per-channel read cursors. The rows carry
//    `last_viewed_at`, `mention_count` and `msg_count`.
//  - `POST /channels/members/{user_id}/mark_read`: a bare JSON **array** of channel ids answers
//    `{status, last_viewed_at_times}` — the server's own new cursors, which is what the feed applies rather
//    than guessing "now".
//
// Not added, because an earlier card already ships it and a second spelling would be a second behaviour:
// `POST /users/ids` (`APIClient.users(ids:)`), `GET /channels/{id}` and `GET /channels/{id}/members/{user}`
// (`channel(id:)`, `channelMember(channelID:userID:)`), `GET /users/me/teams/unread` (`teamUnreads()`),
// `GET /users/me/teams/{team}/threads?unread=true` (`userThreads(unreadOnly:)`) and
// `PUT …/threads/{id}/read/{ts}` (`markThreadRead(teamID:threadID:timestamp:)`) — all T28/T36/T40.

import Foundation

extension APIClient {

    // MARK: - The mentions window

    /// `POST /posts/search` — the reader's mentions across **every** team.
    ///
    /// The body is the search screen's own `SearchQuery.Body` (same eight fields); only `terms` and
    /// `isOrSearch` differ, because a mention search is an OR of the reader's keys, exactly as upstream's
    /// `fetchRecentMentions` sends it. Paging is attempted (the caller asks for page 1 only when the server
    /// says `has_next`): on the database backend `page > 0` answers an empty `order` (measured), so the
    /// shipping path is one window.
    func mentionSearch(terms: String, page: Int = 0, perPage: Int = 60) async throws -> MMSearchResults {
        let query = SearchQuery(terms: terms,
                                isOrSearch: true,
                                includeDeletedChannels: true,
                                timeZoneOffsetSeconds: TimeZone.current.secondsFromGMT())
        return try await post(MMSearchResults.self, path: "/posts/search",
                              body: query.body(page: page, perPage: perPage))
    }

    /// `GET /users/me` — the signed-in account, for its mention keys (`notify_props`).
    func activityProfile() async throws -> ActivityProfile {
        try await get(ActivityProfile.self, path: "/users/me", useETag: false)
    }

    // MARK: - Read state

    /// `GET /users/{user_id}/teams/{team_id}/channels/members` — my read cursor for every channel of a
    /// team I belong to. One request covers every mention row in that team.
    func channelMembersForTeam(teamID: String, userID: String,
                               page: Int = 0, perPage: Int = 200) async throws -> [MMChannelMember] {
        try await get([MMChannelMember].self,
                      path: "/users/\(userID)/teams/\(teamID)/channels/members",
                      query: [URLQueryItem(name: "page", value: String(max(0, page))),
                              URLQueryItem(name: "per_page", value: String(min(max(1, perPage), 200)))],
                      useETag: false)
    }

    /// `POST /channels/members/{user_id}/mark_read` — "these channels are read", by the server's own
    /// definition (there is no read-up-to-a-post route: 9.11's `api4/channel.go` carries `viewChannel`,
    /// `readMultipleChannels` and the thread read, nothing finer). The answer carries the new
    /// `last_viewed_at` per channel.
    func markChannelsRead(channelIDs: [String], userID: String) async throws -> MMChannelViewResponse {
        try await post(MMChannelViewResponse.self,
                       path: "/channels/members/\(userID)/mark_read",
                       body: channelIDs)
    }
}
