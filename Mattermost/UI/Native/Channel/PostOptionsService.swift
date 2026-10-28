// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/actions/remote/post.ts (`markPostAsUnread`), app/actions/remote/preference.ts
//        (`savePostPreference` / `deleteSavedPost`), app/actions/remote/post.ts (`togglePinPost`),
//        app/actions/remote/thread.ts (`updateThreadFollowing`), app/queries/servers/role.ts
//        (the permission union), app/queries/servers/post.ts (`observePostSaved`).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §18; no
// upstream source copied. The protocol/implementation split is this repo's own (component-map.md §1),
// matching `ChannelInfoServing` and `ThreadServing`.
//
// Why a protocol: the menu's guarantee is "each option performs a real request or is absent", and that
// has to be testable without a server — the fake records which call an option made. The production
// class is the only thing that knows about `AuthSession`/`APIClient`.

import Foundation

/// What the post options surface needs from one server.
@MainActor
protocol PostOptionsServing: AnyObject {
    /// The union of my role permissions on this server for this channel: system roles, the team
    /// membership's roles and the channel membership's roles, expanded through `POST /roles/names`.
    /// An empty set means "the lookup answered and granted nothing"; a thrown error means "unknown",
    /// which the caller treats exactly like no permissions (the closed direction).
    func permissions(channelID: String, teamID: String, userID: String) async throws -> Set<String>

    /// The post ids the server holds as saved for me (`flagged_post` preference rows).
    func savedPostIDs() async throws -> Set<String>

    /// `GET /channels/{id}` — read for its `delete_at` only: an archived channel offers no writes.
    func isArchived(channelID: String) async throws -> Bool

    /// `GET /channels/{id}` — the channel's own `team_id`. The route's team can be stale or absent
    /// (a deep link carries a channel name only), and the permalink's segment and the role union both
    /// belong to the channel's team, not to whatever team the shell last showed.
    func channelTeamID(channelID: String) async throws -> String

    /// The team's URL **name** for the permalink (`GET /users/me/teams`, matched by id). `nil` when the
    /// team is not in my list — a permalink built from a guess would be a wrong link, which is worse
    /// than no Copy Link row.
    func teamName(teamID: String) async throws -> String?

    /// The `flagged_post` preference write (`PUT /users/{id}/preferences`) or its delete
    /// (`POST /users/{id}/preferences/delete`).
    func setSaved(postID: String, saved: Bool, userID: String) async throws

    /// `POST /posts/{id}/pin` / `/unpin`.
    func setPinned(postID: String, pinned: Bool) async throws

    /// `POST /users/{id}/posts/{post_id}/set_unread` — answers the membership row with the server's own
    /// counters.
    func markUnread(postID: String, userID: String) async throws -> MMChannelMember

    /// `PUT|DELETE /users/me/teams/{team}/threads/{root}/following`.
    func setFollowing(teamID: String, rootID: String, following: Bool) async throws
}

/// The production implementation: the session's `APIClient`, resolved **per call** so a service built
/// before the session finished restoring is not a permanently signed-out one (the same rule as
/// `SessionChannelInfoService` and `SessionChannelService`).
@MainActor
final class SessionPostOptionsService: PostOptionsServing {
    private let resolve: () -> APIClient?

    init(resolve: @escaping () -> APIClient?) {
        self.resolve = resolve
    }

    private func client() throws -> APIClient {
        guard let client = resolve() else { throw MMError.notSignedIn }
        return client
    }

    func permissions(channelID: String, teamID: String, userID: String) async throws -> Set<String> {
        do {
            return try await loadPermissions(channelID: channelID, teamID: teamID, userID: userID)
        } catch {
            Logger.error("T48", "permission lookup failed for channel \(channelID): \(error)")
            throw error
        }
    }

    private func loadPermissions(channelID: String, teamID: String, userID: String) async throws
        -> Set<String> {
        let client = try client()
        // Upstream `hasPermission(roles, permission)` is the union of the roles' `permissions`; the
        // role *names* come from three rows and the ids from one batched `POST /roles/names`
        // (measured: 6 names answer 6 roles in one 200).
        let principal = try await client.currentPrincipal()
        let resolvedUser = principal.id.isEmpty ? userID : principal.id
        var names = principal.roleNames
        if !teamID.isEmpty,
           let teamMembership = try? await client.teamMembership(teamID: teamID, userID: resolvedUser) {
            names.append(contentsOf: ChannelPermissions.roleNames(systemRoles: "",
                                                                  teamRoles: teamMembership.roles,
                                                                  channelRoles: ""))
        }
        if let channelMembership = try? await client.channelMembership(channelID: channelID) {
            names.append(contentsOf: ChannelPermissions.roleNames(systemRoles: "",
                                                                  teamRoles: "",
                                                                  channelRoles: channelMembership.roles))
        }
        let unique = Array(Set(names.filter { !$0.isEmpty }))
        guard !unique.isEmpty else { return [] }
        let roles = try await client.roles(names: unique)
        return ChannelPermissions.union(roles: roles)
    }

    func savedPostIDs() async throws -> Set<String> {
        let preferences = try await client().preferences()
        return SavedPostDerivation.savedIDs(from: preferences)
    }

    func isArchived(channelID: String) async throws -> Bool {
        try await client().channel(id: channelID).deleteAt != 0
    }

    func channelTeamID(channelID: String) async throws -> String {
        try await client().channel(id: channelID).teamId
    }

    func teamName(teamID: String) async throws -> String? {
        guard !teamID.isEmpty else { return nil }
        let teams = try await client().myTeams()
        return teams.first { $0.id == teamID }?.name
    }

    func setSaved(postID: String, saved: Bool, userID: String) async throws {
        let client = try client()
        let resolved = userID.isEmpty ? (try await client.currentPrincipal().id) : userID
        if saved {
            try await client.savePost(postID: postID, userID: resolved)
        } else {
            try await client.unsavePost(postID: postID, userID: resolved)
        }
    }

    func setPinned(postID: String, pinned: Bool) async throws {
        let client = try client()
        if pinned {
            try await client.pinPost(id: postID)
        } else {
            try await client.unpinPost(id: postID)
        }
    }

    func markUnread(postID: String, userID: String) async throws -> MMChannelMember {
        let client = try client()
        let resolved = userID.isEmpty ? (try await client.currentPrincipal().id) : userID
        return try await client.markPostUnread(userID: resolved, postID: postID)
    }

    func setFollowing(teamID: String, rootID: String, following: Bool) async throws {
        try await client().followThread(teamID: teamID, threadID: rootID, following: following)
    }
}
