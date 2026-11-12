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
    ///
    /// **The request and the answer are the same shape: a bare JSON array** (T33-AV F1). Measured on
    /// the pinned 9.11.19 server: `PUT [categories]` → 200 and the array of stored categories;
    /// `PUT {"order":…,"categories":…}` → 400 `api.context.invalid_body_param.app_error`. The GET's
    /// keyed `{order, categories}` shape is a *read* shape only — decoding the write with it throws
    /// `MMError.malformedResponse` after the server has already kept the change, which is exactly the
    /// rollback the validator saw.
    func updateSidebarCategories(userID: String,
                                 teamID: String,
                                 categories: [MMSidebarCategory]) async throws -> [MMSidebarCategory] {
        try await put([MMSidebarCategory].self,
                      path: "/users/\(userID)/teams/\(teamID)/channels/categories",
                      body: categories)
    }

    /// `POST /users/{user_id}/teams/{team_id}/channels/categories` — create one category.
    ///
    /// Not part of upstream mobile's client mix (`app/client/rest/categories.ts` at the pin has only
    /// the two GETs and the whole-array PUT), but it is the only way to create one on the server:
    /// a whole-array `PUT` that contains a category the server does not know answers 500
    /// `app.channel.sidebar_categories.app_error` ("Failed to insert record to database"), measured.
    ///
    /// **The pinned 9.11.19 server generates the id itself**: a request carrying a valid
    /// 26-character id came back with a different one (measured — `scripts/t19828e14_category_probe.py`
    /// Case A). The answer, not the local record, is therefore the category; the caller adopts it.
    func createSidebarCategory(userID: String,
                               teamID: String,
                               category: MMSidebarCategory) async throws -> MMSidebarCategory {
        try await post(MMSidebarCategory.self,
                       path: "/users/\(userID)/teams/\(teamID)/channels/categories",
                       body: category)
    }

    /// `DELETE /users/{user_id}/teams/{team_id}/channels/categories/{category_id}` — delete one
    /// category. Its channels are **not** deleted: the server returns each to the default category for
    /// its kind (measured: `channels` for `O`/`P`, `direct_messages` for `D`/`G`).
    ///
    /// The three default categories refuse the call with 400
    /// `app.channel.sidebar_categories.app_error`; the client refuses earlier (only a `custom`
    /// category draws the menu entry), so this is the server's belt to that braces.
    func deleteSidebarCategory(userID: String, teamID: String, categoryID: String) async throws {
        _ = try await delete(path: "/users/\(userID)/teams/\(teamID)/channels/categories/\(categoryID)")
    }

    /// `PUT /users/{user_id}/teams/{team_id}/channels/categories/order` — the drawn order, as the
    /// bare array of category ids that `GET …/categories/order` answers.
    ///
    /// The whole-array `PUT` does not reorder: it keeps each category's `sort_order` unless the body
    /// changes it (measured — sending the same categories in a different array order left the order
    /// untouched). This route is what a reorder writes, and the answer is the stored order.
    func updateSidebarCategoryOrder(userID: String,
                                    teamID: String,
                                    order: [String]) async throws -> [String] {
        try await put([String].self,
                      path: "/users/\(userID)/teams/\(teamID)/channels/categories/order",
                      body: order)
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
