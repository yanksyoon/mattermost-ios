// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/actions/remote/channel.ts (`fetchChannelInfo`, `addMembersToChannel`,
//        `removeMemberFromChannel`, `leaveChannel`, `patchChannel`, `archiveChannel`,
//        `unarchiveChannel`, `fetchChannelStats`, `handleKickFromChannel`),
//        app/actions/remote/role.ts (`fetchRolesIfNeeded`), app/queries/servers/role.ts.
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §17; no
// upstream source copied. The protocol/implementation split is this repo's own (component-map.md §1),
// matching `ChannelServing` (T34) and `ThreadServing` (T36).
//
// Why a protocol: every rule the card asserts about the *screen* (a removed member disappears, a
// refused write leaves the list untouched, a socket event reconciles with an optimistic row) has to be
// testable without a server. The fake in the tests implements this protocol; the production class is
// the only thing that knows about `AuthSession`/`APIClient`.

import Foundation

/// What the channel-info surface needs from one server.
@MainActor
protocol ChannelInfoServing: AnyObject {
    /// The channel itself (`GET /channels/{id}`) — header, purpose, type, `delete_at`.
    func channel(id: String) async throws -> MMChannel
    /// `member_count` and friends (`GET /channels/{id}/stats`).
    func stats(channelID: String) async throws -> MMChannelStats

    /// The signed-in user, for their role names.
    func principal() async throws -> MMPrincipal
    /// My membership row for this channel, for its `roles` (and `scheme_admin`).
    func myMembership(channelID: String) async throws -> MMChannelMember
    /// My team membership, for the team roles (`manage_team`).
    func myTeamMembership(teamID: String) async throws -> MMTeamMembership
    /// The permission ids of the named roles (`POST /roles/names`).
    ///
    /// A role name the server does not answer contributes nothing; it must not fail the load, because a
    /// role deleted on the server would otherwise blank the whole screen.
    func rolePermissions(names: [String]) async throws -> [MMRole]

    /// One page of memberships (`GET /channels/{id}/members`).
    func members(channelID: String, page: Int, perPage: Int) async throws -> [MMChannelMember]
    /// One membership row by user id, for reconciling an add or a `user_added` event.
    func member(channelID: String, userID: String) async throws -> MMChannelMember
    /// Batched profiles (`POST /users/ids`) — display names and initials.
    func users(ids: [String]) async throws -> [MMUser]
    /// Batched presence (`POST /users/status/ids`); a failure means "unknown", never "offline".
    func statuses(ids: [String]) async throws -> [MMStatus]

    /// `PUT /channels/{id}/patch` — rename / purpose / header. Answers the server's channel.
    func patch(channelID: String, patch: MMChannelPatch) async throws -> MMChannel
    /// `DELETE /channels/{id}`.
    func archive(channelID: String) async throws -> MMChannel
    /// `POST /channels/{id}/restore`.
    func restore(channelID: String) async throws -> MMChannel
    /// `POST /channels/{id}/members`.
    func addMember(channelID: String, userID: String) async throws -> MMChannelMember
    /// `DELETE /channels/{id}/members/{user_id}`.
    func removeMember(channelID: String, userID: String) async throws
    /// The DM/GM "close": the `direct_channel_show` preference, **not** a membership delete.
    func closeDirectChannel(userID: String, channelID: String) async throws

    /// The channels I am in on this team (`GET /users/me/teams/{tid}/channels`) — the browser's "joined"
    /// set, and the id set the browser needs to split its two sections.
    func myTeamChannels(teamID: String) async throws -> [MMChannel]
    /// The team's public channels (`GET /teams/{tid}/channels`).
    func teamPublicChannels(teamID: String, page: Int, perPage: Int) async throws -> [MMChannel]
    /// The team's archived channels (`GET /teams/{tid}/channels/deleted`); 403 when the reader may not
    /// list them, which the browser treats as "none".
    func archivedTeamChannels(teamID: String, page: Int, perPage: Int) async throws -> [MMChannel]
    /// The add-members picker's opening list (`GET /users?in_team=&not_in_channel=`).
    func usersNotInChannel(teamID: String, channelID: String, page: Int, perPage: Int) async throws -> [MMUser]
    /// The picker's typed search (`POST /users/search` with `not_in_channel_id`).
    func searchUsersNotInChannel(teamID: String, channelID: String, term: String) async throws -> [MMUser]

    /// Page size for the member list; injectable so a test can page a 3-row fixture.
    var memberPageSize: Int { get }
    /// Page size for the picker.
    var pickerPageSize: Int { get }
}

extension ChannelInfoServing {
    var memberPageSize: Int { 60 }
    var pickerPageSize: Int { 50 }

    /// A service that cannot answer the archived list simply has none: the browser then shows the live
    /// channels only, which is what a reader without `list_team_channels` would see anyway.
    func archivedTeamChannels(teamID: String, page: Int, perPage: Int) async throws -> [MMChannel] { [] }

    /// Default: no profiles. A member row then falls back to the user id, never to a made-up name (the
    /// same degradation rule as `ChannelServing.users`).
    func users(ids: [String]) async throws -> [MMUser] { [] }
    func statuses(ids: [String]) async throws -> [MMStatus] { [] }
}

/// The production implementation: the server's own `AuthSession.client`, resolved **per call** so a
/// service built before the session finished restoring is not a permanently signed-out one (the same
/// reason `SessionChannelService` resolves per call).
@MainActor
final class SessionChannelInfoService: ChannelInfoServing {
    private let resolve: () -> APIClient?
    let memberPageSize: Int
    let pickerPageSize: Int

    init(memberPageSize: Int = 60,
         pickerPageSize: Int = 50,
         resolve: @escaping () -> APIClient?) {
        self.memberPageSize = memberPageSize
        self.pickerPageSize = pickerPageSize
        self.resolve = resolve
    }

    /// The server's client, resolved per call. Internal rather than private because the create surface
    /// (`CreateChannelService.swift`) is an extension of this class in another file and must use the
    /// **same** resolution — a second way of getting a client is a second way of being signed out.
    func client() throws -> APIClient {
        guard let client = resolve() else { throw MMError.notSignedIn }
        return client
    }

    // MARK: Reads

    func channel(id: String) async throws -> MMChannel {
        try await client().channel(id: id)
    }

    func stats(channelID: String) async throws -> MMChannelStats {
        try await client().channelStats(channelID: channelID)
    }

    func principal() async throws -> MMPrincipal {
        try await client().currentPrincipal()
    }

    func myMembership(channelID: String) async throws -> MMChannelMember {
        try await client().channelMembership(channelID: channelID)
    }

    func myTeamMembership(teamID: String) async throws -> MMTeamMembership {
        let principal = try await client().currentPrincipal()
        return try await client().teamMembership(teamID: teamID, userID: principal.id)
    }

    func rolePermissions(names: [String]) async throws -> [MMRole] {
        try await client().roles(names: names)
    }

    func members(channelID: String, page: Int, perPage: Int) async throws -> [MMChannelMember] {
        try await client().channelMemberPage(channelID: channelID, page: page, perPage: perPage)
    }

    func member(channelID: String, userID: String) async throws -> MMChannelMember {
        try await client().channelMember(channelID: channelID, userID: userID)
    }

    func users(ids: [String]) async throws -> [MMUser] {
        // A profile failure must not fail the list: rows fall back to the user id, which is honest and
        // still ordered (the same rule as `SessionChannelService.users`).
        (try? await client().users(ids: ids)) ?? []
    }

    func statuses(ids: [String]) async throws -> [MMStatus] {
        (try? await client().statuses(ids: ids)) ?? []
    }

    // MARK: Writes

    func patch(channelID: String, patch: MMChannelPatch) async throws -> MMChannel {
        try await client().patchChannel(channelID: channelID, patch: patch)
    }

    func archive(channelID: String) async throws -> MMChannel {
        try await client().archiveChannel(channelID: channelID)
    }

    func restore(channelID: String) async throws -> MMChannel {
        try await client().restoreChannel(channelID: channelID)
    }

    func addMember(channelID: String, userID: String) async throws -> MMChannelMember {
        try await client().addChannelMember(channelID: channelID, userID: userID)
    }

    func removeMember(channelID: String, userID: String) async throws {
        try await client().removeChannelMember(channelID: channelID, userID: userID)
    }

    func closeDirectChannel(userID: String, channelID: String) async throws {
        try await client().setDirectChannelVisible(userID: userID, channelID: channelID, visible: false)
    }

    // MARK: Browser

    func myTeamChannels(teamID: String) async throws -> [MMChannel] {
        try await client().teamChannels(teamID: teamID)
    }

    func teamPublicChannels(teamID: String, page: Int, perPage: Int) async throws -> [MMChannel] {
        try await client().teamPublicChannels(teamID: teamID, page: page, perPage: perPage)
    }

    func archivedTeamChannels(teamID: String, page: Int, perPage: Int) async throws -> [MMChannel] {
        // 403 is the documented answer for a reader without `list_team_channels`: not an error the screen
        // should report, just "there are no archived channels you may see".
        (try? await client().archivedTeamChannels(teamID: teamID, page: page, perPage: perPage)) ?? []
    }

    func usersNotInChannel(teamID: String, channelID: String,
                           page: Int, perPage: Int) async throws -> [MMUser] {
        try await client().usersNotInChannel(teamID: teamID, channelID: channelID,
                                             page: page, perPage: perPage)
    }

    func searchUsersNotInChannel(teamID: String, channelID: String, term: String) async throws -> [MMUser] {
        try await client().searchUsersNotInChannel(teamID: teamID, channelID: channelID,
                                                   term: term, page: 0, perPage: pickerPageSize)
    }
}
