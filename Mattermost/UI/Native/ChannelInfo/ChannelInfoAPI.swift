// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/client/rest/channels.ts (`getChannelStats`, `getChannelMembers`, `getChannelMember`,
//        `patchChannel`, `addToChannel`, `removeFromChannel`, `getChannels`, `getArchivedChannels`,
//        `getChannelByNameAndTeamName`), app/client/rest/users.ts (`getProfilesNotInChannel`,
//        `searchProfiles`), app/client/rest/preferences.ts (`savePreferences`),
//        app/client/rest/roles.ts (`getRolesByNames`).
// Licence: Apache-2.0 — endpoints reimplemented against https://api.mattermost.com with attribution
// per docs/THIRD_PARTY_NOTICES.md §17; no upstream source copied.
//
// Only the endpoints T40 needs that the existing groups do not already cover:
//   * `teamChannels(teamID:)` (my channels) and `channelMembers(channelID:perPage:)` already exist in
//     `ChannelSidebarAPI` and are **reused**, not redeclared — the browse screen calls the first with
//     the team id, the member list uses this file's paged variant;
//   * `users(ids:)` / `statuses(ids:)` / `channel(id:)` / `preferences(userID:)` already exist in
//     `MMEndpoints`.
//
// Two shapes worth stating because they are easy to get wrong:
//
//  1. `POST /roles/names` answers **only the roles it found** — an unknown name is dropped from the
//     array rather than answered as an error (measured). So a caller must not zip its request with the
//     answer; it must index by `name`.
//  2. `POST /channels/{id}/members` answers the **membership row** (`MMChannelMember`), not the
//     channel, and `DELETE /channels/{id}/members/{user_id}` answers `{"status":"OK"}` — which is why
//     the remove path returns no model.

import Foundation

extension APIClient {

    // MARK: - Roles and permissions

    /// `GET /users/me` as `MMPrincipal` — the signed-in user's **role names**, which is the root of the
    /// permission union (`roles(names:)` turns them into permission ids).
    ///
    /// Distinct from `MMEndpoints.currentUser()` on purpose: that one answers the rendering model, which
    /// carries no roles (see `MMPrincipal`'s note in `MMChannelAdminTypes`).
    func currentPrincipal() async throws -> MMPrincipal {
        try await get(MMPrincipal.self, path: "/users/me", useETag: false)
    }

    /// `GET /teams/{team_id}/members/{user_id}` — one team membership, for its `roles`.
    ///
    /// The team roles matter: `manage_team` (which unarchive requires) lives here, not on the user row.
    func teamMembership(teamID: String, userID: String) async throws -> MMTeamMembership {
        try await get(MMTeamMembership.self,
                      path: "/teams/\(teamID)/members/\(userID)",
                      useETag: false)
    }

    /// `POST /roles/names` — the roles for a set of role names, in **one** request.
    ///
    /// One request rather than one `GET /roles/name/{name}` per role: a user's permission union needs
    /// `system_user` + `team_user` + `channel_user` at minimum, and a channel administrator adds
    /// `tea...`-level roles on top; four round trips on every channel-info open is a visible delay for
    /// no benefit. Measured on 9.11.19: a 6-name body answers 6 roles in one 200.
    ///
    /// Unknown names are simply absent from the answer (measured), so the caller indexes the result by
    /// `name` and treats a missing role as "grants nothing" — never as "grants everything".
    func roles(names: [String]) async throws -> [MMRole] {
        let unique = Array(Set(names.filter { !$0.isEmpty })).sorted()
        guard !unique.isEmpty else { return [] }
        return try await post([MMRole].self, path: "/roles/names", body: unique)
    }

    // MARK: - Channel stats and members

    /// `GET /channels/{channel_id}/stats` — `member_count`, `guest_count`, `pinnedpost_count`,
    /// `files_count`.
    ///
    /// No ETag: a member is added or removed by *other* people while this screen is open, and a 304
    /// replay would pin the "6 members" line to what it said on the first open.
    func channelStats(channelID: String) async throws -> MMChannelStats {
        try await get(MMChannelStats.self, path: "/channels/\(channelID)/stats", useETag: false)
    }

    /// `GET /channels/{channel_id}/members?page=&per_page=` — one page of membership rows.
    ///
    /// Distinct from `channelMembers(channelID:perPage:)` (whose one call a group message's *name*
    /// uses): this one pages, and it is unconditional, because the list is being edited while it is
    /// open (a `304` would restore a member who has just been removed).
    func channelMemberPage(channelID: String, page: Int, perPage: Int) async throws -> [MMChannelMember] {
        let query = [URLQueryItem(name: "page", value: String(max(0, page))),
                     URLQueryItem(name: "per_page", value: String(max(1, perPage)))]
        return try await get([MMChannelMember].self,
                             path: "/channels/\(channelID)/members",
                             query: query,
                             useETag: false)
    }

    /// `GET /channels/{channel_id}/members/{user_id}` — one membership row, used to reconcile an add or
    /// a `user_added` event that arrived before the local row did.
    func channelMember(channelID: String, userID: String) async throws -> MMChannelMember {
        try await get(MMChannelMember.self,
                      path: "/channels/\(channelID)/members/\(userID)",
                      useETag: false)
    }

    /// `POST /channels/{channel_id}/members` with `{"user_id": …}` — add one member (or join, when the
    /// user id is my own).
    func addChannelMember(channelID: String, userID: String) async throws -> MMChannelMember {
        try await post(MMChannelMember.self,
                       path: "/channels/\(channelID)/members",
                       body: AddMemberBody(userID: userID))
    }

    /// `DELETE /channels/{channel_id}/members/{user_id}` — remove a member, or leave when the id is my
    /// own. Answers `{"status":"OK"}`; the caller reconciles from the event or the next page.
    func removeChannelMember(channelID: String, userID: String) async throws {
        _ = try await delete(path: "/channels/\(channelID)/members/\(userID)")
    }

    /// `PUT /channels/{channel_id}/patch` — rename / purpose / header, answering the patched channel.
    ///
    /// The answer is the **server's** channel and is used as the new truth (the server normalises a
    /// trailing space in a display name and may reject nothing else), matching T33's rule for the
    /// categories write: re-read from the answer, never from the optimistic guess.
    func patchChannel(channelID: String, patch: MMChannelPatch) async throws -> MMChannel {
        try await put(MMChannel.self, path: "/channels/\(channelID)/patch", body: patch)
    }

    /// `DELETE /channels/{channel_id}` — archive. Answers the archived channel (or a bare
    /// `{"status":"OK"}` on a server that trims the body, in which case the caller already knows which
    /// channel it asked about).
    ///
    /// Measured on 9.11.19: a **second** archive attempt answers 400 (`…already archived`), so the
    /// caller treats this as a one-shot write and disables the row while it is in flight.
    @discardableResult
    func archiveChannel(channelID: String) async throws -> MMChannel {
        let response = try await delete(path: "/channels/\(channelID)")
        // `DELETE` is documented as returning the channel, and 9.11.19 does. A body that is not a
        // channel (a proxy's `{"status":"OK"}`) is not a failure: the write happened, and the caller's
        // next read of `/channels/{id}` shows `delete_at`.
        guard let channel = try? decode(MMChannel.self, from: response), !channel.id.isEmpty else {
            return MMChannel(id: channelID, deleteAt: 1)
        }
        return channel
    }

    /// `POST /channels/{channel_id}/restore` — unarchive. Answers the restored channel.
    ///
    /// The route is `POST`; `PUT /channels/{id}/restore` answers 404 (measured), which is the kind of
    /// mistake that reads as "not supported by this server" instead of "wrong verb".
    func restoreChannel(channelID: String) async throws -> MMChannel {
        let response = try await postForResponse(path: "/channels/\(channelID)/restore", body: nil)
        return try decode(MMChannel.self, from: response)
    }

    // MARK: - Creating a channel

    /// `POST /channels` — create a public (`O`) or private (`P`) channel.
    ///
    /// Measured on 9.11.19: **201** with the created channel, `creator_id` set, and the creator added as
    /// a member by the server (`GET /channels/{id}/stats` → `member_count: 1`), so there is no second
    /// membership write to make. The answer is used as the truth, never an optimistic local channel: it
    /// carries the id the router needs and the `name` the server actually stored.
    ///
    /// The failure shapes a caller must handle (all measured, see `CreateChannelModels.swift`):
    /// `400 model.channel.is_valid.1_or_more.app_error` for a malformed URL name,
    /// `400 store.sql_channel.save_channel.exists.app_error` for a duplicate,
    /// `400 model.channel.is_valid.display_name.app_error` / `.purpose` / `.header` for the long fields,
    /// `404 app.channel.get_channels.not_found.app_error` for an unknown team, and — the reason the
    /// client refuses a 65-character name locally — `500 app.channel.create_channel.internal_error`.
    func createChannel(_ body: MMChannelCreate) async throws -> MMChannel {
        try await post(MMChannel.self, path: "/channels", body: body)
    }

    // MARK: - Team members (the "create a direct message" picker)

    /// `GET /users?in_team={tid}&page=&per_page=` — the team's members, which is the direct-message
    /// picker's opening list.
    ///
    /// Deliberately not `usersNotInChannel`: a conversation can be started with anybody on the team,
    /// and that call needs a channel to exclude from.
    func teamMembers(teamID: String, page: Int, perPage: Int) async throws -> [MMUser] {
        let query = [URLQueryItem(name: "in_team", value: teamID),
                     URLQueryItem(name: "page", value: String(max(0, page))),
                     URLQueryItem(name: "per_page", value: String(max(1, perPage)))]
        return try await get([MMUser].self, path: "/users", query: query, useETag: false)
    }

    /// `POST /users/search` with `team_id` — the picker's typed search.
    ///
    /// `POST /users/search` refuses an empty term (measured: `400 Invalid or missing term`), so the
    /// picker opens on the list above and only calls this with something typed.
    func searchTeamMembers(teamID: String, term: String, page: Int, perPage: Int) async throws -> [MMUser] {
        try await post([MMUser].self,
                       path: "/users/search",
                       body: TeamMemberSearchBody(term: term,
                                                  teamID: teamID,
                                                  page: max(0, page),
                                                  perPage: max(1, perPage),
                                                  allowInactive: false))
    }

    // MARK: - Channel browser

    /// `GET /teams/{team_id}/channels?page=&per_page=` — the team's **public** channels (joined or
    /// not). DMs and GMs never appear here, and a private channel appears only if I am in it — the
    /// server enforces that, so the client does not have to.
    ///
    /// Named `teamPublicChannels` rather than `teamChannels` because that name is already taken by the
    /// *my channels* call (`GET /users/me/teams/{id}/channels`) in `ChannelSidebarAPI`.
    func teamPublicChannels(teamID: String, page: Int, perPage: Int) async throws -> [MMChannel] {
        let query = [URLQueryItem(name: "page", value: String(max(0, page))),
                     URLQueryItem(name: "per_page", value: String(max(1, perPage)))]
        return try await get([MMChannel].self,
                             path: "/teams/\(teamID)/channels",
                             query: query,
                             useETag: false)
    }

    /// `GET /teams/{team_id}/channels/deleted` — the team's archived channels (requires
    /// `list_team_channels`; 403 otherwise).
    func archivedTeamChannels(teamID: String, page: Int, perPage: Int) async throws -> [MMChannel] {
        let query = [URLQueryItem(name: "page", value: String(max(0, page))),
                     URLQueryItem(name: "per_page", value: String(max(1, perPage)))]
        return try await get([MMChannel].self,
                             path: "/teams/\(teamID)/channels/deleted",
                             query: query,
                             useETag: false)
    }

    /// `GET /teams/{team_id}/channels/name/{channel_name}` — resolve a channel by its URL name.
    ///
    /// This is the documented "join by name" route (`POST /channels/{id}/members` needs an id), and it
    /// is also what a deep link carries.
    func channelByName(teamID: String, name: String) async throws -> MMChannel {
        try await get(MMChannel.self,
                      path: "/teams/\(teamID)/channels/name/\(name)",
                      useETag: false)
    }

    // MARK: - People to add

    /// `GET /users?in_team=&not_in_channel=&page=&per_page=` — team members **not** in this channel,
    /// which is the add-members picker's opening list.
    ///
    /// Measured: `POST /users/search` refuses an empty term (`400 Invalid or missing term`), so the
    /// picker cannot open on a search; this endpoint is the one that lists without a term
    /// (`in_channel` is its inverse and is how the *members* list could also be built).
    func usersNotInChannel(teamID: String, channelID: String,
                           page: Int, perPage: Int) async throws -> [MMUser] {
        let query = [URLQueryItem(name: "in_team", value: teamID),
                     URLQueryItem(name: "not_in_channel", value: channelID),
                     URLQueryItem(name: "page", value: String(max(0, page))),
                     URLQueryItem(name: "per_page", value: String(max(1, perPage)))]
        return try await get([MMUser].self, path: "/users", query: query, useETag: false)
    }

    /// `POST /users/search` with `not_in_channel_id` — the typed search in the same picker.
    ///
    /// The body is the documented `UserSearch` shape; `allow_inactive: false` keeps deactivated
    /// accounts out of an add picker (the server would accept them, and adding a deactivated user is
    /// never what the reader meant).
    func searchUsersNotInChannel(teamID: String, channelID: String, term: String,
                                 page: Int, perPage: Int) async throws -> [MMUser] {
        try await post([MMUser].self,
                       path: "/users/search",
                       body: UserSearchBody(term: term,
                                            teamID: teamID,
                                            notInChannelID: channelID,
                                            page: max(0, page),
                                            perPage: max(1, perPage),
                                            allowInactive: false))
    }

    // MARK: - Closing a DM/GM

    /// `PUT /users/{user_id}/preferences` with the `direct_channel_show` row — **how a DM or GM is
    /// left**: it is closed for this reader and its membership row is untouched (measured: after the
    /// write both members remain; the channel merely leaves this user's sidebar).
    ///
    /// Same call shape as `SearchAPI.savePost`'s preference write, so the preferences path stays in one
    /// idiom.
    func setDirectChannelVisible(userID: String, channelID: String, visible: Bool) async throws {
        let preference = MMDirectChannelVisibility.preference(userID: userID,
                                                             channelID: channelID,
                                                             visible: visible)
        try await putForResponse(path: "/users/\(userID)/preferences", body: [preference])
    }

    // MARK: - Bodies

    private struct AddMemberBody: Encodable {
        let userID: String

        enum CodingKeys: String, CodingKey {
            case userID = "user_id"
        }
    }

    private struct UserSearchBody: Encodable {
        let term: String
        let teamID: String
        let notInChannelID: String
        let page: Int
        let perPage: Int
        let allowInactive: Bool

        enum CodingKeys: String, CodingKey {
            case term, page
            case teamID = "team_id"
            case notInChannelID = "not_in_channel_id"
            case perPage = "per_page"
            case allowInactive = "allow_inactive"
        }
    }

    /// `UserSearch` without `not_in_channel_id` (the direct-message picker searches the whole team).
    private struct TeamMemberSearchBody: Encodable {
        let term: String
        let teamID: String
        let page: Int
        let perPage: Int
        let allowInactive: Bool

        enum CodingKeys: String, CodingKey {
            case term, page
            case teamID = "team_id"
            case perPage = "per_page"
            case allowInactive = "allow_inactive"
        }
    }
}
