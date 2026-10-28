// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/actions/remote/channel.ts (`createChannel`, `createDirectChannel`),
//        app/client/rest/channels.ts (`createChannel` → `POST /channels`, `createDirectChannel` →
//        `POST /channels/direct`), app/client/rest/users.ts (`getProfilesInTeam`, `searchProfiles`).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §17; no
// upstream source copied. The protocol/implementation split is this repo's own (component-map.md §1),
// matching `ChannelServing` (T34) and `ChannelInfoServing` (T40).
//
// Why a **separate** protocol instead of three more requirements on `ChannelInfoServing`: T40's fake in
// `MattermostTests/T40ChannelInfoTests.swift` implements that protocol in full, and every requirement
// added to it is a compile error in a test file this card does not own. `ChannelCreationServing`
// *inherits* `ChannelInfoServing` (the create form needs the permission union from it), so the
// production object is still one class and a test that wants both fakes one conformance.

import Foundation

/// What the create surface needs from one server.
@MainActor
protocol ChannelCreationServing: ChannelInfoServing {
    /// `POST /channels` — the created channel (the server adds the creator as a member).
    func createChannel(_ body: MMChannelCreate) async throws -> MMChannel

    /// `GET /users?in_team=` — the direct-message picker's opening list.
    func teamMembers(teamID: String, page: Int, perPage: Int) async throws -> [MMUser]
    /// `POST /users/search` scoped to the team — the picker's typed search.
    func searchTeamMembers(teamID: String, term: String, page: Int, perPage: Int) async throws -> [MMUser]
    /// `POST /channels/direct` — create-or-find the conversation (`201` on both paths, measured).
    func createDirectChannel(userIDs: [String]) async throws -> MMChannel
}

@MainActor
extension ChannelCreationServing {
    var pickerPageSizeForPeople: Int { 50 }

    /// Presence for the picker's rows. A failure is "unknown", never "offline" — the same rule
    /// `SessionChannelInfoService.statuses` follows.
    func statusesOrEmpty(ids: [String]) async -> [MMStatus] {
        (try? await statuses(ids: ids)) ?? []
    }
}

/// The production implementation. `SessionChannelInfoService` already owns the per-call client
/// resolution (so a service built before the session restored is not a permanently signed-out one);
/// these four calls reuse it rather than resolving a second client.
@MainActor
extension SessionChannelInfoService: ChannelCreationServing {
    func createChannel(_ body: MMChannelCreate) async throws -> MMChannel {
        try await client().createChannel(body)
    }

    func teamMembers(teamID: String, page: Int, perPage: Int) async throws -> [MMUser] {
        try await client().teamMembers(teamID: teamID, page: page, perPage: perPage)
    }

    func searchTeamMembers(teamID: String, term: String, page: Int, perPage: Int) async throws -> [MMUser] {
        try await client().searchTeamMembers(teamID: teamID, term: term, page: page, perPage: perPage)
    }

    func createDirectChannel(userIDs: [String]) async throws -> MMChannel {
        try await client().directChannel(userIDs: userIDs)
    }
}
