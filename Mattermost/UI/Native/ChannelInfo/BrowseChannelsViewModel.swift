// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/browse_channels/browse_channels.tsx and its `search_handler.tsx` /
//        `channel_list.tsx`, app/actions/remote/channel.ts (`joinChannel`,
//        `joinIfNeededAndSwitchToChannel`, `fetchArchivedChannels`),
//        app/screens/browse_channels/convert_gm_to_channel_* (not in scope).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §17; no
// upstream source copied.
//
// The card's criterion for this screen: "joining a public channel from the browser navigates straight
// into it". So a tap is not a toggle and not a "you joined, find it in the sidebar": the join completes
// and the callback opens the channel. A tap on a channel I am already in opens it without a write
// (upstream: `joinIfNeededAndSwitchToChannel` skips the network when the membership exists).
//
// Gating: the browser itself needs `list_team_channels`; joining needs `join_public_channels`. Both come
// from the same permission union the info screen uses — a reader without the join permission sees the
// list (that is what `list_team_channels` means) with no Join affordance, rather than an error after a
// tap.

import Foundation
import Combine

@MainActor
final class BrowseChannelsViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    let teamID: String
    /// The channels I am already in — filled from `GET /users/me/teams/{tid}/channels`.
    @Published private(set) var joinedIDs: Set<String> = []
    @Published private(set) var entries: [BrowseChannelEntry] = []
    @Published private(set) var phase: Phase = .idle
    @Published var term: String = ""
    /// The channel whose join is in flight (its row shows a spinner and refuses a second tap).
    @Published private(set) var joiningID: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var canJoinPublicChannels = false
    /// Whether the list itself may be read at all (`list_team_channels`).
    @Published private(set) var canListChannels = false

    private let service: ChannelInfoServing
    private var myUserID: String?
    private var allChannels: [MMChannel] = []
    private var generation = 0

    /// Pages to walk when reading the team's channels. Upstream reads the team's list page by page until
    /// the search narrows it; this screen reads a bounded 4×100 (the fixture's team has 40, a large team
    /// has hundreds) and then **says so** rather than silently hiding channels — see `truncationNote`.
    static let pagesToRead = 4
    static let pageSize = 100

    init(teamID: String, service: ChannelInfoServing) {
        self.teamID = teamID
        self.service = service
    }

    var sections: (joined: [BrowseChannelEntry], others: [BrowseChannelEntry]) {
        let filtered = BrowseChannelsDerivation.entries(channels: allChannels, joined: joinedIDs, term: term)
        return BrowseChannelsDerivation.sections(filtered)
    }

    var isEmpty: Bool { entries.isEmpty }

    /// The sentence a reader sees when the team list hit this screen's page cap. An honest note, because
    /// a truncated list looks exactly like "the team has no more channels".
    var truncationNote: String? {
        guard allChannels.count >= Self.pagesToRead * Self.pageSize else { return nil }
        return "Only the first \(allChannels.count) channels are listed. Use the search to reach the rest."
    }

    // MARK: Loading

    func load() async {
        generation += 1
        let token = generation
        if phase != .ready { phase = .loading }
        errorMessage = nil
        do {
            let principal = try? await service.principal()
            let joined = try await service.myTeamChannels(teamID: teamID)
            guard token == generation else { return }
            myUserID = principal?.id
            joinedIDs = Set(joined.map(\.id))
            await resolvePermissions(principal: principal ?? MMPrincipal(), token: token)

            var channels: [MMChannel] = []
            for page in 0..<Self.pagesToRead {
                let pageChannels = try await service.teamPublicChannels(teamID: teamID,
                                                                        page: page,
                                                                        perPage: Self.pageSize)
                channels.append(contentsOf: pageChannels)
                if pageChannels.count < Self.pageSize { break }
            }
            guard token == generation else { return }
            // The archived list is additive and optional: a 403 (no `list_team_channels`) means "none".
            let archived = try await service.archivedTeamChannels(teamID: teamID,
                                                                  page: 0,
                                                                  perPage: Self.pageSize)
            guard token == generation else { return }
            allChannels = dedupe(channels + archived)
            phase = .ready
            applyFilter()
        } catch {
            guard token == generation else { return }
            phase = .failed(ChannelInfoViewModel.copy(for: error,
                                                      fallback: "Channels could not be loaded."))
        }
    }

    private func resolvePermissions(principal: MMPrincipal, token: Int) async {
        // The browser needs `list_team_channels` and `join_public_channels`; both live on the team
        // membership's roles, so the team row is part of the union.
        let teamMembership = try? await service.myTeamMembership(teamID: teamID)
        guard token == generation else { return }
        let roleNames = ChannelPermissions.roleNames(systemRoles: principal.roles,
                                                     teamRoles: teamMembership?.roles ?? "",
                                                     channelRoles: "")
        let roles = (try? await service.rolePermissions(names: roleNames)) ?? []
        guard token == generation else { return }
        let permissions = ChannelPermissions.union(roles: roles)
        canListChannels = permissions.contains(ChannelPermissionID.listTeamChannels)
        canJoinPublicChannels = permissions.contains(ChannelPermissionID.joinPublicChannels)
    }

    private func applyFilter() {
        entries = BrowseChannelsDerivation.entries(channels: allChannels, joined: joinedIDs, term: term)
    }

    private func dedupe(_ channels: [MMChannel]) -> [MMChannel] {
        var seen = Set<String>()
        return channels.filter { seen.insert($0.id).inserted }
    }

    // MARK: Join

    /// Join (or just open) one channel. Answers the channel id the caller should navigate to, or `nil`
    /// when the join failed.
    ///
    /// The write is `POST /channels/{id}/members` with my own user id — the same call upstream's
    /// `joinChannel` uses (it resolves the channel by name first, which this screen does not need because
    /// the row already carries the id).
    func join(_ entry: BrowseChannelEntry) async -> String? {
        errorMessage = nil
        if entry.isMember { return entry.id }
        guard canJoinPublicChannels else {
            errorMessage = "You do not have permission to join channels on this team."
            return nil
        }
        guard entry.isJoinable else {
            errorMessage = "This channel cannot be joined."
            return nil
        }
        guard let myUserID else {
            errorMessage = "You appear to be signed out. Please sign in again."
            return nil
        }
        joiningID = entry.id
        defer { joiningID = nil }
        do {
            _ = try await service.addMember(channelID: entry.id, userID: myUserID)
            joinedIDs.insert(entry.id)
            applyFilter()
            return entry.id
        } catch {
            errorMessage = ChannelInfoViewModel.copy(for: error,
                                                     fallback: "That channel could not be joined.")
            return nil
        }
    }
}
