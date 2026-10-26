// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/channel_info/index.ts (what the screen asks for and in which order),
//        app/actions/remote/channel.ts (`fetchChannelInfo`, `addMembersToChannel`,
//        `removeMemberFromChannel`, `leaveChannel`, `patchChannel`, `archiveChannel`,
//        `unarchiveChannel`, `handleKickFromChannel`, `handleUserAddedToChannelEvent`,
//        `handleUserRemovedFromChannelEvent`), app/queries/servers/role.ts, and the screen's socket
//        subscriptions in app/screens/channel_info/useChannelInfo*.
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §17; no
// upstream source copied. The view-model shape is this repo's own (component-map.md §1) and mirrors
// `SearchViewModel`/`ChannelViewModel`: a generation guard, a service seam, and the rules kept out of
// the view.
//
// The card's criteria map onto this file:
//  1. header/member list/add/remove/leave/settings/archive + join browser — everything except the last
//     lives here; the browser is `BrowseChannelsViewModel`.
//  2. "permission-gated actions are hidden or disabled based on server permissions, not guessed from
//     role names" — `capabilities` comes from `ChannelInfoCapabilities.derive` over permission **ids**,
//     and every write below refuses when the corresponding flag is false. That second check is the
//     defence-in-depth the card calls a security assertion: hiding a row is a UI state, refusing the
//     write is the guarantee.
//  3. "add/remove/leave reconcile with socket events" — `handle(event:)` applies `user_added`,
//     `user_removed`, `channel_updated`, `channel_deleted`, `channel_restored`,
//     `channel_member_updated`, `status_change` and `user_updated`, and an optimistic row is only ever
//     a *prediction* of what those events will confirm.

import Foundation
import Combine

/// One channel's info screen: header, member list, and the writes it can perform.
@MainActor
final class ChannelInfoViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    // MARK: Identity

    let channelID: String
    /// The team the channel belongs to (`MMChannel.teamId`); empty until the channel is read.
    private(set) var teamID: String
    /// The title the channel pane already had, used for a DM/GM (whose `display_name` is empty).
    private let fallbackTitle: String?

    // MARK: State

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var channel: MMChannel?
    @Published private(set) var stats: MMChannelStats?
    @Published private(set) var capabilities: ChannelInfoCapabilities = .none
    @Published private(set) var memberRows: [ChannelMemberRow] = []
    @Published private(set) var hasMoreMembers = false
    @Published private(set) var isLoadingMoreMembers = false
    /// The action whose write is in flight, so its row can show a spinner and refuse a second tap.
    @Published private(set) var busyAction: ChannelInfoActionID?
    /// A failed write, in the reader's words. Never a silent no-op.
    @Published private(set) var banner: String?
    /// Set when the reader's own membership ended (a leave, or being removed): the screen closes.
    @Published private(set) var didLeave = false
    /// A refused action (the write path's gate). Distinct from `banner` because it is not a server
    /// failure — it means the screen was asked to do something this user may not do.
    @Published private(set) var refusedMessage: String?
    /// Whether the permission lookup answered. `false` renders the screen read-only with a note.
    @Published private(set) var permissionsAvailable = false

    /// The member list's own search field (upstream `manage_channel_members`'s search box).
    @Published var memberSearch: String = ""

    // MARK: Collaborators

    private let service: ChannelInfoServing

    // MARK: Request state

    private var myUserID: String?
    private var memberPage = 0
    private var members: [MMChannelMember] = []
    private var users: [String: MMUser] = [:]
    private var statuses: [String: MMStatus] = [:]
    private var permissions: Set<String> = []
    /// Whether I am a guest on this server (`system_guest` on the user row); `canLeave` depends on it.
    private var myIsGuest = false
    /// Every load/write bumps this; a late answer for an older generation is dropped.
    private var generation = 0

    init(channelID: String,
         teamID: String = "",
         fallbackTitle: String? = nil,
         service: ChannelInfoServing) {
        self.channelID = channelID
        self.teamID = teamID
        self.fallbackTitle = fallbackTitle
        self.service = service
    }

    // MARK: Derived

    var header: ChannelInfoHeader? {
        guard let channel else { return nil }
        return ChannelInfoHeader.derive(channel: channel, stats: stats, fallbackTitle: fallbackTitle)
    }

    var isArchived: Bool { (channel?.deleteAt ?? 0) != 0 }

    /// The rows the screen draws, in `offeredActions` order.
    var actions: [ChannelInfoActionID] { capabilities.offeredActions }

    /// The member rows after the list's search field, sorted the same way.
    var visibleMemberRows: [ChannelMemberRow] {
        let term = memberSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return memberRows }
        return memberRows.filter { row in
            row.displayName.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || row.username.range(of: term, options: [.caseInsensitive]) != nil
        }
    }

    /// The member list's footer: "6 members" from the stats call, and whether paging is pending.
    var memberCountText: String {
        guard let stats else { return "" }
        return ChannelInfoHeader.membersText(count: stats.memberCount)
    }

    /// The note a read-only screen shows when the permission lookup failed — the screen must say why
    /// nothing is offered rather than look like a channel with no actions.
    var readOnlyNote: String? {
        guard phase == .ready, !permissionsAvailable else { return nil }
        return "Actions are unavailable right now. Your permissions could not be checked."
    }

    // MARK: Load

    /// Read the channel, its counters, my roles and the first page of members.
    ///
    /// The channel is the only *required* answer: without it there is no screen. Stats, roles and members
    /// each degrade on their own — a channel whose stats request failed still shows its purpose, and a
    /// permission lookup that failed leaves the screen read-only rather than guessing.
    func load() async {
        generation += 1
        let token = generation
        if phase != .ready { phase = .loading }
        banner = nil
        refusedMessage = nil

        do {
            let channel = try await service.channel(id: channelID)
            guard token == generation else { return }
            self.channel = channel
            if !channel.teamId.isEmpty { teamID = channel.teamId }
            phase = .ready
        } catch {
            guard token == generation else { return }
            phase = .failed(Self.copy(for: error, fallback: "This channel could not be loaded."))
            return
        }

        // The three side-reads are independent and each degrades on its own: a channel whose stats
        // request failed still shows its purpose, and a permission lookup that failed leaves the screen
        // read-only rather than guessing. They are fetched in sequence rather than with `async let` so
        // that a failure can never cancel a sibling read — the point is that one failure does not take
        // the others with it.
        let stats = try? await service.stats(channelID: channelID)
        guard token == generation else { return }
        if let stats { self.stats = stats }

        let principal = try? await service.principal()
        let membership = try? await service.myMembership(channelID: channelID)
        var teamMembership: MMTeamMembership?
        if !teamID.isEmpty {
            teamMembership = try? await service.myTeamMembership(teamID: teamID)
        }
        guard token == generation else { return }
        self.myUserID = principal?.id
        await refreshPermissions(principal: principal,
                                 teamMembership: teamMembership,
                                 channelMembership: membership,
                                 token: token)
        guard token == generation else { return }
        await loadMembers(reset: true, token: token)
    }

    /// Re-read only the channel (after `channel_restored`, whose payload carries no `delete_at`).
    func refreshChannel() async {
        guard let channel = try? await service.channel(id: channelID) else { return }
        apply(channel: channel)
    }

    // MARK: Permissions

    /// Fetch the permission ids of every role I hold here, then derive the gates.
    ///
    /// The three role sources are all required for correctness: system roles on the user row, team roles
    /// on the team membership (`manage_team`), channel roles on the channel membership (`channel_admin`
    /// when a server uses schemes). A missing one is not fatal — it contributes nothing.
    private func refreshPermissions(principal: MMPrincipal?,
                                    teamMembership: MMTeamMembership?,
                                    channelMembership: MMChannelMember?,
                                    token: Int) async {
        guard let principal else {
            permissionsAvailable = false
            capabilities = ChannelInfoCapabilities.derive(channel: channel,
                                                          permissions: [],
                                                          isGuest: false)
            return
        }
        let roleNames = ChannelPermissions.roleNames(systemRoles: principal.roles,
                                                     teamRoles: teamMembership?.roles ?? "",
                                                     channelRoles: channelMembership?.roles ?? "")
        let roles = (try? await service.rolePermissions(names: roleNames)) ?? []
        guard token == generation else { return }
        // If not one role came back, the lookup failed (or the server knows none of my roles): the screen
        // goes read-only. Treating it as "no permissions" is the same answer, but the note tells the
        // reader why nothing is offered.
        // No role came back at all: every name is unknown to this server, or the lookup failed. Either way
        // the screen goes read-only with a note, and nothing is offered on a guess.
        permissionsAvailable = !roles.isEmpty
        permissions = ChannelPermissions.union(roles: roles)
        myIsGuest = principal.isGuest
        capabilities = ChannelInfoCapabilities.derive(channel: channel,
                                                     permissions: permissions,
                                                     isGuest: principal.isGuest)
    }

    // MARK: Members

    private func loadMembers(reset: Bool, token: Int) async {
        if reset {
            memberPage = 0
            members = []
            users = [:]
            statuses = [:]
        }
        let page = memberPage
        do {
            let pageRows = try await service.members(channelID: channelID,
                                                     page: page,
                                                     perPage: service.memberPageSize)
            guard token == generation else { return }
            merge(members: pageRows)
            memberPage += 1
            hasMoreMembers = pageRows.count >= service.memberPageSize
        } catch {
            guard token == generation else { return }
            hasMoreMembers = false
            if memberRows.isEmpty {
                banner = Self.copy(for: error, fallback: "The member list could not be loaded.")
            }
        }
        await loadProfiles(token: token)
    }

    /// Append one page of memberships (deduplicated by user id: a page can overlap a socket `user_added`).
    private func merge(members newMembers: [MMChannelMember]) {
        var index = Dictionary(uniqueKeysWithValues: members.enumerated().map { ($1.userId, $0) })
        for member in newMembers {
            if let existing = index[member.userId] {
                members[existing] = member
            } else {
                members.append(member)
                index[member.userId] = members.count - 1
            }
        }
        rebuildRows()
    }

    private func loadProfiles(token: Int) async {
        let missingIDs = members.map(\.userId).filter { users[$0] == nil }
        guard !missingIDs.isEmpty else { return }
        let profiles = await (try? service.users(ids: missingIDs)) ?? []
        guard token == generation else { return }
        for profile in profiles { users[profile.id] = profile }
        let statuses = await (try? service.statuses(ids: missingIDs)) ?? []
        guard token == generation else { return }
        for status in statuses { self.statuses[status.userId] = status }
        rebuildRows()
    }

    private func rebuildRows() {
        memberRows = ChannelMemberDerivation.rows(members: members,
                                                  users: users,
                                                  statuses: statuses,
                                                  myUserID: myUserID)
    }

    /// The next page, when the list is scrolled to its end.
    func loadMoreMembers() async {
        guard hasMoreMembers, !isLoadingMoreMembers, phase == .ready else { return }
        isLoadingMoreMembers = true
        let token = generation
        await loadMembers(reset: false, token: token)
        isLoadingMoreMembers = false
    }

    // MARK: Writes

    /// Add members. Returns whether the write landed.
    ///
    /// Optimistic: the row is inserted from the profile the picker already holds, so the list answers a
    /// tap immediately; a failure removes it again and says why. The `user_added` event that follows is
    /// idempotent with this prediction (`applyUserAdded` checks the id first).
    @discardableResult
    func addMembers(_ userIDs: [String], profiles: [String: MMUser] = [:]) async -> Bool {
        guard capabilities.canManageMembers else {
            refuse("You do not have permission to add members to this channel.")
            return false
        }
        let additions = userIDs.filter { id in !members.contains { $0.userId == id } }
        guard !additions.isEmpty else { return true }
        busyAction = .addMembers
        banner = nil
        defer { busyAction = nil }

        let predictions = additions.map { MMChannelMember(channelId: channelID, userId: $0) }
        for (id, profile) in profiles { users[id] = profile }
        merge(members: predictions)
        adjustMemberCount(by: Int64(predictions.count))

        var failed: String?
        for id in additions {
            do {
                let row = try await service.addMember(channelID: channelID, userID: id)
                merge(members: [row])
            } catch {
                failed = Self.copy(for: error, fallback: "That member could not be added.")
                members.removeAll { $0.userId == id }
                adjustMemberCount(by: -1)
                rebuildRows()
            }
        }
        await loadProfiles(token: generation)
        if let failed {
            banner = failed
            return false
        }
        return true
    }

    /// Remove somebody else. Returns whether the write landed.
    @discardableResult
    func removeMember(userID: String) async -> Bool {
        guard capabilities.canManageMembers else {
            refuse("You do not have permission to remove members from this channel.")
            return false
        }
        guard userID != myUserID else { return await leave() }
        busyAction = .members
        banner = nil
        defer { busyAction = nil }

        let removed = members.filter { $0.userId == userID }
        members.removeAll { $0.userId == userID }
        adjustMemberCount(by: -1)
        rebuildRows()
        do {
            try await service.removeMember(channelID: channelID, userID: userID)
            return true
        } catch {
            members.append(contentsOf: removed)
            adjustMemberCount(by: Int64(removed.count))
            rebuildRows()
            banner = Self.copy(for: error, fallback: "That member could not be removed.")
            return false
        }
    }

    /// Leave the channel — or, for a DM/GM, **close** it (see `ChannelLeavePrompt.action`).
    ///
    /// The two writes are genuinely different and the card names the difference: a `D`/`G` keeps its
    /// membership row (the other people are still in the conversation) and only loses this reader's
    /// `direct_channel_show` preference.
    @discardableResult
    func leave() async -> Bool {
        guard capabilities.canLeave, let channel else {
            refuse("You cannot leave this channel.")
            return false
        }
        let prompt = ChannelLeavePrompt.make(kind: capabilities.kind,
                                             displayName: header?.title ?? channel.name)
        busyAction = .leave
        banner = nil
        defer { busyAction = nil }
        do {
            switch prompt.action {
            case .leave:
                guard let myUserID else { throw MMError.notSignedIn }
                try await service.removeMember(channelID: channelID, userID: myUserID)
            case .closeDirectMessage:
                guard let myUserID else { throw MMError.notSignedIn }
                try await service.closeDirectChannel(userID: myUserID, channelID: channelID)
            }
            didLeave = true
            return true
        } catch {
            banner = Self.copy(for: error, fallback: "You could not leave this channel.")
            return false
        }
    }

    /// Rename / purpose / header. Answers whether the server accepted it.
    @discardableResult
    func save(_ patch: MMChannelPatch) async -> Bool {
        guard capabilities.canManageSettings else {
            refuse("You do not have permission to edit this channel.")
            return false
        }
        guard !patch.isEmpty else { return true }
        busyAction = .settings
        banner = nil
        defer { busyAction = nil }
        do {
            let updated = try await service.patch(channelID: channelID, patch: patch)
            apply(channel: updated)
            return true
        } catch {
            banner = Self.copy(for: error, fallback: "The channel could not be saved.")
            return false
        }
    }

    @discardableResult
    func archive() async -> Bool {
        guard capabilities.canArchive else {
            refuse("You do not have permission to archive this channel.")
            return false
        }
        busyAction = .archive
        banner = nil
        defer { busyAction = nil }
        do {
            let archived = try await service.archive(channelID: channelID)
            apply(channel: archived.deleteAt == 0 ? archiveStub(from: archived) : archived)
            return true
        } catch {
            banner = Self.copy(for: error, fallback: "The channel could not be archived.")
            return false
        }
    }

    @discardableResult
    func unarchive() async -> Bool {
        guard capabilities.canUnarchive else {
            refuse("You do not have permission to unarchive this channel.")
            return false
        }
        busyAction = .unarchive
        banner = nil
        defer { busyAction = nil }
        do {
            let restored = try await service.restore(channelID: channelID)
            apply(channel: restored)
            return true
        } catch {
            banner = Self.copy(for: error, fallback: "The channel could not be unarchived.")
            return false
        }
    }

    // MARK: Socket

    /// Apply one socket event. Called for every event of this server; only this channel's are used.
    func handle(event: SocketEvent) {
        switch event {
        case .channelUpdated(let updated):
            guard updated.id == channelID else { return }
            apply(channel: updated)
        case .channelDeleted(let event) where event.channelID == channelID:
            applyArchived(at: event.deleteAt)
        case .channelRestored(let event) where event.channelID == channelID:
            // The frame carries only the id, so the channel is re-read rather than guessed.
            Task { await refreshChannel() }
        case .userAdded(let change) where change.channelID == channelID:
            applyUserAdded(userID: change.userID)
        case .userRemoved(let change) where change.channelID == channelID:
            // Being removed from a channel I am looking at ends the screen, like a leave of my own.
            if change.userID == myUserID {
                didLeave = true
            } else {
                removeLocally(userID: change.userID)
            }
        case .channelMemberUpdated(let update) where update.channelID == channelID:
            merge(members: [update.member])
        case .statusChange(let change):
            guard statuses[change.userID] != nil else { return }
            statuses[change.userID] = MMStatus(userId: change.userID, status: change.status)
            rebuildRows()
        case .userUpdated(let user):
            guard users[user.id] != nil else { return }
            users[user.id] = user
            rebuildRows()
        default:
            break
        }
    }

    /// A member was added by somebody else (or confirmed to me after my own add).
    func applyUserAdded(userID: String) {
        guard !members.contains(where: { $0.userId == userID }) else { return }
        members.append(MMChannelMember(channelId: channelID, userId: userID))
        adjustMemberCount(by: 1)
        rebuildRows()
        // Name and presence come from the network: a row with the user id alone is worse than a row
        // that arrives a moment later with the right name.
        Task { await self.loadProfiles(token: self.generation) }
    }

    private func removeLocally(userID: String) {
        let before = members.count
        members.removeAll { $0.userId == userID }
        guard members.count != before else { return }
        adjustMemberCount(by: -1)
        rebuildRows()
    }

    private func apply(channel updated: MMChannel) {
        channel = updated
        if !updated.teamId.isEmpty { teamID = updated.teamId }
        // The role set does not change with a rename, so the gates are re-derived from what is already
        // known rather than re-fetched (a rename must not blank the actions for a moment).
        capabilities = ChannelInfoCapabilities.derive(channel: updated,
                                                      permissions: permissions,
                                                      isGuest: myIsGuest)
    }

    private func applyArchived(at deleteAt: Int64) {
        guard var current = channel else { return }
        current.deleteAt = deleteAt == 0 ? 1 : deleteAt
        apply(channel: current)
    }

    private func archiveStub(from archived: MMChannel) -> MMChannel {
        var stub = archived
        stub.deleteAt = max(stub.deleteAt, 1)
        return stub
    }

    private func adjustMemberCount(by delta: Int64) {
        guard var current = stats else { return }
        current.memberCount = max(0, current.memberCount + delta)
        stats = current
    }

    private func refuse(_ message: String) {
        refusedMessage = message
    }

    // MARK: Copy

    /// The reader-facing sentence for a failure, in this screen's words.
    static func copy(for error: Error, fallback: String) -> String {
        MMErrorCopy.message(for: error,
                            offline: "You appear to be offline. Try again when you have a connection.",
                            timeout: "The server took too long to answer. Try again.",
                            unauthorized: "Your session has expired. Please sign in again.",
                            forbidden: "You do not have permission to do that.",
                            notFound: "This channel no longer exists.",
                            rateLimited: "The server is busy. Try again shortly.",
                            fallback: fallback)
    }
}
