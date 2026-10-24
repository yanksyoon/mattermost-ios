// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/client/rest/channels.ts (`getMyChannels` `/users/me/teams/{team_id}/channels`,
//        `getMyChannelMembers` `/users/me/channel_members`, `getChannelMembers`),
//        app/client/rest/categories.ts (`getCategories`, `updateChannelCategories`),
//        app/client/rest/users.ts (`getProfilesByIds`), and the notify-props write in
//        app/client/rest/channels.ts / app/actions/remote/channel.ts.
// Licence: Apache-2.0 — endpoint shapes reimplemented with attribution per
// docs/THIRD_PARTY_NOTICES.md §3; no upstream source copied. This file is the T33 (S08) endpoint
// group on top of `APIClient`, per the rule MMEndpoints.swift states ("screen cards add their own
// endpoint groups").
//
// Every call goes through the server's own `AuthSession.client`, so a 401 from any of them lands in
// the app's one re-auth path. `teamChannels` and `myChannelMembers` deliberately do **not** use an
// ETag: both carry unread counters (`total_msg_count`, `msg_count`, `mention_count`), and a replayed
// 304 is exactly the stale-badge bug T32 forbids on `/users/me/teams/unread`.

import Foundation

extension APIClient {

    /// `GET /users/me/teams/{team_id}/channels` — the channels the signed-in user has on one team,
    /// DMs and GMs included (upstream `getMyChannels`).
    func teamChannels(teamID: String) async throws -> [MMChannel] {
        try await get([MMChannel].self,
                      path: "/users/me/teams/\(teamID)/channels",
                      useETag: false)
    }

    /// `GET /users/me/channel_members` — the user's membership row for every channel, which is where
    /// the unread counters (`msg_count`, `mention_count`) and the notify props (mute) live.
    func myChannelMembers() async throws -> [MMChannelMember] {
        try await get([MMChannelMember].self, path: "/users/me/channel_members", useETag: false)
    }

    /// `GET /channels/{channel_id}/members` — needed to name a group message (a GM channel's `name`
    /// is an opaque hash; only its member list says who is in it).
    func channelMembers(channelID: String, perPage: Int = 100) async throws -> [MMChannelMember] {
        let query = [URLQueryItem(name: "per_page", value: String(max(1, perPage)))]
        return try await get([MMChannelMember].self,
                             path: "/channels/\(channelID)/members",
                             query: query,
                             useETag: true)
    }

    /// `GET /users/{user_id}/teams/{team_id}/channels/categories` — the ordered sidebar categories.
    ///
    /// Read through `userID` rather than `/users/me` because that is the documented route
    /// (`api4` category routes are keyed by user), and because a test can then ask for a fixture
    /// user. `useETag: false`: the category list is what a reorder writes, and a 304 replay would
    /// hand back the **local** copy of a write the server may have normalised.
    func sidebarCategories(userID: String, teamID: String) async throws -> MMSidebarCategories {
        try await get(MMSidebarCategories.self,
                      path: "/users/\(userID)/teams/\(teamID)/channels/categories",
                      useETag: false)
    }

    /// `PUT /users/{user_id}/teams/{team_id}/channels/categories` — replace the user's categories.
    ///
    /// Upstream sends the **whole** ordered array (`updateChannelCategories`), not a single moved
    /// row: the server's handler reconciles ids, `sort_order` and `channel_ids` together, and that
    /// full-array shape is what makes a reorder a single atomic write.
    func updateSidebarCategories(userID: String,
                                 teamID: String,
                                 categories: [MMSidebarCategory]) async throws -> MMSidebarCategories {
        try await put(MMSidebarCategories.self,
                      path: "/users/\(userID)/teams/\(teamID)/channels/categories",
                      body: categories)
    }

    /// `PUT /channels/{channel_id}/members/{user_id}/notify_props` — mute/unmute one channel for the
    /// signed-in user.
    ///
    /// Muting in Mattermost is `mark_unread: "mention"` (upstream `isChannelMuted` reads exactly
    /// that value); unmuting restores `"all"`. The call is intentionally narrow so a sidebar row can
    /// only ever change the two fields mute is defined by.
    func updateChannelNotifyProps(channelID: String,
                                  userID: String,
                                  markUnread: String) async throws {
        struct NotifyProps: Encodable {
            let markUnread: String
            enum CodingKeys: String, CodingKey { case markUnread = "mark_unread" }
        }
        _ = try await putForResponse(path: "/channels/\(channelID)/members/\(userID)/notify_props",
                                     body: NotifyProps(markUnread: markUnread))
    }
}
