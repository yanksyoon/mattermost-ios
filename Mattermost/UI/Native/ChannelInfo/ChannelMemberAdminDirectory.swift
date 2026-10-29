// T5449 C3 — the team-scoped answer to "may I manage the members of a channel here?".
//
// Behaviour reference: mattermost/mattermost @ v9.11.0,
// `webapp/channels/src/packages/mattermost-redux/src/selectors/entities/channels.ts`
// (`canManageAnyChannelMembersInCurrentTeam`, l. 904) and
// `webapp/channels/src/components/add_user_to_channel_modal/add_user_to_channel_modal.tsx` (the
// picker this answer feeds). Licence: Apache-2.0 — reimplemented against the REST routes and the
// permission ids; no upstream source copied.
//
// Why this is one object rather than two call sites:
//
// Upstream asks the same question with two quantifiers — the profile popover's **row** is drawn when
// I can manage members on *some* channel of the current team (∃), and a **picker row** is drawn when
// I can on *that* channel (one). Both come from the same rule
// (`ChannelInfoCapabilities.canManageMembers(channel:permissions:)`), and both must cost **zero**
// requests on the row's tap path: the answer is resolved once per (server, team), when a profile
// opens, and remembered here (owned by `ProfileCoordinator`).
//
// The reads are the four the card names (`docs/t_8f9f5449-profile-popover-parity.md` §6):
//
//   GET /users/me/teams/{tid}/channels   → my channels on the team           (`myTeamChannels`)
//   GET /users/me/channel_members        → my roles on each of them          (`myChannelMemberships`)
//   GET /users/me                        → my system roles                   (`principal`)
//   GET /teams/{tid}/members/me          → my team roles                     (`myTeamMembership`)
//   POST /roles/names                    → role name → permission ids, once  (`rolePermissions`)
//
// and the per-channel permission union is `ChannelPermissions.roleNames`'s three sources, exactly as
// the channel-info screen builds it — so an answer that says "you may" here says "you may" there.

import Foundation

/// The team-wide member-administration answer, for every channel I am in on one team.
///
/// `manageableChannelIDs` is the picker's list; `canManageAnyChannelMembers` is the profile row's
/// gate (`!manageableChannelIDs.isEmpty`, stated as its own field because that is the fact the row
/// reads and the fact a test asserts).
struct ChannelMemberAdminAnswer: Equatable, Sendable {
    /// My channels on the team, in the server's order.
    var channels: [MMChannel]
    /// The ids of the channels in `channels` whose members I may manage.
    var manageableChannelIDs: Set<String>

    var canManageAnyChannelMembers: Bool { !manageableChannelIDs.isEmpty }

    /// The picker's rows: my channels I can manage, most useful first (display name, then id so the
    /// order is total).
    var manageableChannels: [MMChannel] {
        channels
            .filter { manageableChannelIDs.contains($0.id) }
            .sorted { lhs, rhs in
                let left = lhs.displayName.isEmpty ? lhs.name : lhs.displayName
                let right = rhs.displayName.isEmpty ? rhs.name : rhs.displayName
                let comparison = left.localizedCaseInsensitiveCompare(right)
                if comparison == .orderedSame { return lhs.id < rhs.id }
                return comparison == .orderedAscending
            }
    }

    /// Build the answer from the five reads' results. **Pure** — no I/O, so the per-channel rule is
    /// a unit test (`T5449AddToChannelPickerTests`).
    ///
    /// - Parameters:
    ///   - channels: my channels on the team.
    ///   - myMemberships: my membership rows; only the ones naming a channel in `channels` are used,
    ///     so another team's roles cannot leak into this team's answer.
    ///   - systemRoles: `MMPrincipal.roles` (space-separated names).
    ///   - teamRoles: the team membership's roles.
    ///   - rolesByName: `POST /roles/names`' answer, indexed by name. A name the server did not
    ///     answer contributes nothing — never "everything".
    static func resolve(channels: [MMChannel],
                        myMemberships: [MMChannelMember],
                        systemRoles: String,
                        teamRoles: String,
                        rolesByName: [String: MMRole]) -> ChannelMemberAdminAnswer {
        let channelIDs = Set(channels.map(\.id))
        var rolesPerChannel: [String: String] = [:]
        for membership in myMemberships where channelIDs.contains(membership.channelId) {
            rolesPerChannel[membership.channelId] = membership.roles
        }

        var manageable = Set<String>()
        for channel in channels {
            let names = ChannelPermissions.roleNames(systemRoles: systemRoles,
                                                    teamRoles: teamRoles,
                                                    channelRoles: rolesPerChannel[channel.id] ?? "")
            let permissions = names.reduce(into: Set<String>()) { result, name in
                guard let role = rolesByName[name] else { return }
                result.formUnion(Set(role.permissions))
            }
            if ChannelInfoCapabilities.canManageMembers(channel: channel, permissions: permissions) {
                manageable.insert(channel.id)
            }
        }
        return ChannelMemberAdminAnswer(channels: channels, manageableChannelIDs: manageable)
    }
}

/// The cache, per (server, team). Owned by `ProfileCoordinator`, which is what makes the answer
/// survive a sheet close and a second profile open within the same session.
@MainActor
final class ChannelMemberAdminDirectory {

    private struct Key: Hashable {
        let serverID: UUID
        let teamID: String
    }

    private var answers: [Key: ChannelMemberAdminAnswer] = [:]

    /// The remembered answer, or `nil` when this (server, team) has not been resolved yet.
    ///
    /// `nil` is what the profile row's gate reads as **absent**: an unresolved permission is never
    /// assumed (`docs/t_8f9f5449-profile-popover-parity.md` §4).
    func answer(serverID: UUID, teamID: String) -> ChannelMemberAdminAnswer? {
        answers[Key(serverID: serverID, teamID: teamID)]
    }

    func store(_ answer: ChannelMemberAdminAnswer, serverID: UUID, teamID: String) {
        answers[Key(serverID: serverID, teamID: teamID)] = answer
    }

    /// Sign-out / server removal: forget everything this credential learned.
    func forget(serverID: UUID) {
        answers = answers.filter { $0.key.serverID != serverID }
    }

    /// How many teams are remembered (diagnostics, and a test asserting sign-out clears the cache).
    var count: Int { answers.count }

    /// Ask the server: the four reads in parallel, then **one** `POST /roles/names` for the union of
    /// every role name involved (system + team + each channel membership).
    ///
    /// Throws only when a read fails: a failed answer is `nil` at the caller, i.e. rows stay absent —
    /// never a guess, and never a banner over a profile that loaded fine.
    static func resolve(service: ChannelInfoServing,
                        teamID: String,
                        myUserID: String) async throws -> ChannelMemberAdminAnswer {
        async let principalRead = service.principal()
        async let teamRead = service.myTeamMembership(teamID: teamID)
        async let channelsRead = service.myTeamChannels(teamID: teamID)
        async let membershipsRead = service.myChannelMemberships()
        let (principal, teamMembership, channels, memberships) = try await (principalRead,
                                                                          teamRead,
                                                                          channelsRead,
                                                                          membershipsRead)

        // The team membership is mine only when the server says so; a route that answered somebody
        // else's row must not contribute team roles.
        let teamRoles = teamMembership.userId == myUserID ? teamMembership.roles : ""

        var names = Set(principal.roles.split(separator: " ").map(String.init))
        names.formUnion(teamRoles.split(separator: " ").map(String.init))
        let channelIDs = Set(channels.map(\.id))
        for membership in memberships where channelIDs.contains(membership.channelId) {
            names.formUnion(membership.roles.split(separator: " ").map(String.init))
        }
        names = names.filter { !$0.isEmpty }

        let roles = try await service.rolePermissions(names: Array(names))
        var rolesByName: [String: MMRole] = [:]
        for role in roles { rolesByName[role.name] = role }

        return ChannelMemberAdminAnswer.resolve(channels: channels,
                                                myMemberships: memberships,
                                                systemRoles: principal.roles,
                                                teamRoles: teamRoles,
                                                rolesByName: rolesByName)
    }
}
