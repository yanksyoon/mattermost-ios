// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/actions/remote/channel.ts + category.ts (the load sequence: my channels for the team,
//        my channel memberships, the sidebar categories, then the profiles a DM/GM needs a name
//        from), app/client/rest/{channels,categories,users}.ts (endpoint shapes),
//        app/actions/remote/team.ts `handleTeamChange` (a team switch reloads that team's channels).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §3; no
// upstream source copied. The protocol/implementation split is this repo's own
// (docs/component-map.md §1), matching `TeamSidebarServing` in the T32 rail.

import Foundation

/// What the channel sidebar needs from one server.
///
/// Split from the view model so a test can hand in fixtures, and so the production implementation is
/// the only place that knows about `AuthSession` / `APIClient`.
@MainActor
protocol ChannelSidebarServing: AnyObject {
    /// The full load for one team: its channels, the user's memberships (counters + mute), the
    /// sidebar categories, and enough profile data to name the DMs/GMs.
    func load(teamID: String) async throws -> ChannelSidebarData

    /// The cheap socket-driven refresh: the two counter-bearing endpoints only.
    func refresh(teamID: String) async throws -> ChannelSidebarRefresh

    /// Persist a category layout (a reorder, a favourite, a collapse). Returns the categories the
    /// server stored — **a bare array**, which is the write's answer shape, not the GET's keyed
    /// `{order, categories}` shape (T33-AV F1). The caller rebases its groups on it.
    func save(categories: [MMSidebarCategory], teamID: String) async throws -> [MMSidebarCategory]

    /// Mute (`mark_unread = "mention"`) or unmute (`"all"`) one channel.
    func setMuted(_ muted: Bool, channelID: String) async throws
}

/// The production implementation: the server's own `AuthSession.client`, resolved **per call**.
///
/// Per call, not captured, for the same reason `SessionTeamSidebarService` resolves per call: the
/// sidebar is created when the shell first draws it, which can be before the server's session has
/// finished restoring, and a captured `APIClient` would then be a permanently signed-out one.
/// Because every call goes through that client, a 401 from any of them lands in
/// `AuthCoordinator.reportUnauthorized` — this file must not swallow it.
@MainActor
final class SessionChannelSidebarService: ChannelSidebarServing {
    private let resolve: () -> (client: APIClient, userID: String?)?

    init(resolve: @escaping () -> (client: APIClient, userID: String?)?) {
        self.resolve = resolve
    }

    private func resolved() throws -> (client: APIClient, userID: String?) {
        guard let value = resolve() else { throw MMError.notSignedIn }
        return value
    }

    func load(teamID: String) async throws -> ChannelSidebarData {
        let (client, resolvedUserID) = try resolved()
        // The channel list is the one required answer: without it there is nothing to draw, and its
        // error is the error the sidebar shows. Everything else degrades with a defined behaviour.
        let channels = try await client.teamChannels(teamID: teamID)
        var userID = resolvedUserID
        if userID == nil { userID = (try? await client.currentUser())?.id }

        var data = ChannelSidebarData(channels: channels)
        do {
            data.members = try await client.myChannelMembers()
        } catch {
            data.membersFailed = true
            // A 401 is the session, not a hiccup: it has to reach re-auth.
            if case MMError.unauthorized = error { throw error }
        }

        if let userID {
            do {
                let categories = try await client.sidebarCategories(userID: userID, teamID: teamID)
                data.categories = categories.categories
                data.categoryOrder = categories.order
            } catch {
                data.categoriesFailed = true
                if case MMError.unauthorized = error { throw error }
            }
            // The legacy favourite preference is only consulted when there is no categories answer;
            // asking for it anyway would be a request that is almost always discarded.
            if data.categoriesFailed || data.categories.isEmpty {
                data.preferences = (try? await client.preferences(userID: userID)) ?? []
            }
        }

        let labels = await Self.resolveDirectLabels(client: client,
                                                    userID: userID,
                                                    channels: channels)
        data.directLabels = labels.labels
        data.searchTerms = labels.terms
        return data
    }

    func refresh(teamID: String) async throws -> ChannelSidebarRefresh {
        let (client, _) = try resolved()
        let channels = try await client.teamChannels(teamID: teamID)
        do {
            let members = try await client.myChannelMembers()
            return ChannelSidebarRefresh(channels: channels, members: members)
        } catch {
            // A 401 is the session, not a hiccup: it has to reach re-auth.
            if case MMError.unauthorized = error { throw error }
            // Anything else is **reported**, not swallowed (T33-AV F5): returning `members: []`
            // as if it were an answer says "every badge is zero" and claims the numbers are fresh.
            // The channels we did get are still useful (a new channel appears), so they travel with
            // the failure instead of being thrown away.
            return ChannelSidebarRefresh(channels: channels, members: [], membersFailed: true)
        }
    }

    func save(categories: [MMSidebarCategory], teamID: String) async throws -> [MMSidebarCategory] {
        let (client, userID) = try resolved()
        guard let userID else { throw MMError.notSignedIn }
        return try await client.updateSidebarCategories(userID: userID,
                                                        teamID: teamID,
                                                        categories: categories)
    }

    func setMuted(_ muted: Bool, channelID: String) async throws {
        let (client, userID) = try resolved()
        guard let userID else { throw MMError.notSignedIn }
        try await client.updateChannelNotifyProps(
            channelID: channelID,
            userID: userID,
            markUnread: ChannelSidebarDerivation.markUnread(forMuted: muted))
    }

    // MARK: - DM / GM labels

    /// Turn opaque DM/GM channels into something a person can read.
    ///
    /// A DM's `name` is `<userID>__<userID>` and a GM's is a hash, so the only source of a label is
    /// the member profiles. One batched `POST /users/ids` answers all of them; the GM member lists are
    /// fetched concurrently because there is no "members of many channels" endpoint.
    ///
    /// Deliberately best-effort: a failure leaves the rows labelled "Direct message"/"Group message"
    /// rather than failing the sidebar. The counter and category rules do not depend on names.
    static func resolveDirectLabels(
        client: APIClient,
        userID: String?,
        channels: [MMChannel]
    ) async -> (labels: [String: String], terms: [String: [String]]) {
        let directs = channels.filter {
            ChannelSidebarDerivation.kind(of: $0)?.isDirect == true
        }
        guard !directs.isEmpty else { return ([:], [:]) }

        // channel id → the other people in it.
        var memberIDsByChannel: [String: [String]] = [:]
        for channel in directs {
            switch ChannelSidebarDerivation.kind(of: channel) {
            case .directMessage:
                // The DM's name carries both participant ids, so no member call is needed.
                memberIDsByChannel[channel.id] = channel.name
                    .components(separatedBy: "__")
                    .filter { !$0.isEmpty && $0 != userID }
            case .groupMessage:
                if let members = try? await client.channelMembers(channelID: channel.id) {
                    memberIDsByChannel[channel.id] = members.map(\.userId).filter { $0 != userID }
                }
            default:
                break
            }
        }

        let ids = Array(Set(memberIDsByChannel.values.flatMap { $0 }))
        guard !ids.isEmpty else { return ([:], [:]) }
        let users = (try? await client.users(ids: ids)) ?? []
        let byID = Dictionary(users.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var labels: [String: String] = [:]
        var terms: [String: [String]] = [:]
        for (channelID, ids) in memberIDsByChannel {
            let people = ids.compactMap { byID[$0] }
            guard !people.isEmpty else { continue }
            labels[channelID] = people
                .map(Self.label(for:))
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .joined(separator: ", ")
            terms[channelID] = people.flatMap(Self.searchTerms(for:))
        }
        return (labels, terms)
    }

    /// The human name upstream shows for a person: nickname, else the full name, else the username.
    static func label(for user: MMUser) -> String {
        if !user.nickname.isEmpty { return user.nickname }
        let full = [user.firstName, user.lastName].filter { !$0.isEmpty }.joined(separator: " ")
        if !full.isEmpty { return full }
        return user.username
    }

    /// Every name a quick switcher may match this person by (`@ada`, `ada`, `Ada Lovelace`).
    static func searchTerms(for user: MMUser) -> [String] {
        var terms = [user.username, label(for: user)]
        if !user.firstName.isEmpty { terms.append(user.firstName) }
        let full = [user.firstName, user.lastName].filter { !$0.isEmpty }.joined(separator: " ")
        if !full.isEmpty { terms.append(full) }
        return terms.filter { !$0.isEmpty }
    }
}

// MARK: - The view model (one per server, owned by `ChannelSidebarCoordinator`)

/// One server's channel sidebar: what to draw, how to refresh it, and the three writes a person can
/// make (reorder, favourite, mute).
///
/// **The selection is not stored here as the truth.** It is pushed in from
/// `NativeNavigation.location` by the coordinator (`setSelection`), the same one value a row tap, a
/// deep link and a notification tap write. This model keeps a copy only because it has to draw a
/// checkmark/reorder against it.
@MainActor
final class ChannelListViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    let server: ServerConfig

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var groups: [ChannelSidebarGroup] = []
    @Published private(set) var totals = ChannelSidebarTotals()
    /// The team this sidebar is currently showing (`nil` until the shell has a team for this server).
    @Published private(set) var teamID: String?
    /// A category write failed: the row keeps its place and the user is told why, rather than a
    /// silent revert.
    @Published private(set) var actionError: String?
    @Published private(set) var isRefreshing = false
    /// Counters could not be refreshed: keep the last numbers and say they may be out of date.
    @Published private(set) var countsAreStale = false
    /// The grouping is not the user's (the categories call failed and the defaults are drawn).
    @Published private(set) var groupingIsApproximate = false
    /// The rows are grouped from the server's categories; without them a write would rewrite
    /// somebody's layout from a guess, so writes are refused in that state.
    var canWriteLayout: Bool { !groupingIsApproximate && teamID != nil }

    private let service: ChannelSidebarServing
    private var data = ChannelSidebarData()
    private var selectedChannelID: String?
    private var selectedChannelName: String?
    /// The team whose data is in `data` (so `ifNeeded` cannot answer for the wrong team).
    private var loadedTeamID: String?
    /// Every load takes a number; a load that finishes after a newer one started is dropped.
    private var generation = 0

    init(server: ServerConfig, service: ChannelSidebarServing) {
        self.server = server
        self.service = service
    }

    // MARK: Reads

    /// Everything the quick switcher can offer, in draw order.
    var allEntries: [ChannelSidebarEntry] { groups.flatMap(\.entries) }

    func entry(id: String) -> ChannelSidebarEntry? {
        allEntries.first { $0.id == id }
    }

    /// What the quick switcher shows for `query`.
    func searchResults(for query: String) -> [ChannelSidebarEntry] {
        ChannelSidebarDerivation.search(query, in: allEntries)
    }

    /// The model's answer to a deep link (via the coordinator's `NativeChannelDirectory`).
    func identity(channelID: String?, channelName: String?) -> (teamID: String?, channelID: String?, channelName: String?) {
        if let channelID, let entry = entry(id: channelID) {
            return (teamID, entry.id, entry.name)
        }
        if let channelName, !channelName.isEmpty,
           let entry = allEntries.first(where: { $0.name == channelName || $0.displayName == channelName }) {
            return (teamID, entry.id, entry.name)
        }
        return (teamID, channelID, channelName)
    }

    // MARK: Selection

    /// The shell moved. Idempotent: only a changed value re-derives the rows.
    func setSelection(teamID: String?, channelID: String?, channelName: String?) {
        let normalisedTeam = teamID?.isEmpty == false ? teamID : nil
        let normalisedID = channelID?.isEmpty == false ? channelID : nil
        let normalisedName = channelName?.isEmpty == false ? channelName : nil
        guard normalisedTeam != self.teamID
                || normalisedID != selectedChannelID
                || normalisedName != selectedChannelName else { return }
        self.teamID = normalisedTeam
        selectedChannelID = normalisedID
        selectedChannelName = normalisedName
        rebuild()
    }

    // MARK: Loading

    /// First load for the team. `ifNeeded` keeps a SwiftUI re-mount (a tab switch, a rotation) from
    /// refetching the sidebar, exactly as the team rail does — but a **team switch** always reloads,
    /// because the previous team's channels are not this team's.
    func load(ifNeeded: Bool = true) async {
        guard let teamID else { return }
        if ifNeeded, phase == .loaded, loadedTeamID == teamID { return }
        await performLoad(teamID: teamID)
    }

    /// An explicit reload: the sidebar's "Try again", or a team switch that must not trust the
    /// previous team's channels.
    func reload() async {
        guard let teamID else { return }
        await performLoad(teamID: teamID)
    }

    /// Counter-only refresh (socket activity). A failure never clears the numbers it already has:
    /// "no mentions" while the server says otherwise is the exact wrong direction for a badge.
    func refreshCounters() async {
        guard let teamID, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let requested = generation
        do {
            let refresh = try await service.refresh(teamID: teamID)
            guard requested == generation else { return }
            let trusted = data.replaceCounters(channels: refresh.channels,
                                               members: refresh.members,
                                               membersFailed: refresh.membersFailed)
            // A partial answer is not fresh: the numbers it could not fetch keep their old values and
            // are drawn as stale (T33-AV F5).
            countsAreStale = !trusted
            rebuild()
        } catch {
            guard requested == generation else { return }
            countsAreStale = true
        }
    }

    // MARK: Socket

    /// One event from the server's socket, already scoped to the team on screen.
    ///
    /// - `channel_viewed` by this user: the channel is read, so its badge goes now.
    /// - `multiple_channels_viewed` for me: the **view call's** event (T33-AV2 F1) — every channel in
    ///   its `channel_times` map is read, so each row clears. This is what makes a channel read in
    ///   another client of mine clear here without a relaunch. (`post_unread` is the *mark-unread*
    ///   event, `POST /users/{uid}/posts/{pid}/set_unread`; it is not the answer to a view.)
    /// - `posted` / `post_deleted` / `post_edited` / `preferences_changed`: the counters or the layout
    ///   may have moved; the caller's debounce turns a burst into one refresh.
    /// - `post_unread`: the server's own arithmetic for one channel — applied directly, no request.
    /// - `channel_member_updated` for **me**: my membership row changed (a mute set in another
    ///   client), so the row is replaced from the payload.
    /// - `sidebar_category_updated`: the layout the server stored, applied directly — this is what
    ///   makes a reorder/collapse/favourite made elsewhere visible without a relaunch (T33-AV F3).
    /// - `channel_created`: the list gained a channel; the caller reloads. `channel_deleted`: the
    ///   channel list read drops it, so the ordinary counter refresh is enough.
    /// - `user_added` / `user_removed` **for me**: my own membership moved, and the endpoint the list is
    ///   built from (`GET /users/me/teams/{t}/channels`) is "the channels *I* am in" — a counter
    ///   refresh reads the same endpoint, but the row has to be **added** (or dropped) rather than
    ///   re-counted, so the caller reloads. T40-R F3 measured what its absence cost: a join reached the
    ///   server, the pane opened, and the sidebar never gained the row. Somebody else's membership
    ///   change is not this list's business and must not cost a reload (it would be one request per
    ///   join of every other member of the team).
    func handle(_ event: SocketEvent, myUserID: String?) -> ChannelEventOutcome {
        switch event {
        case .channelViewed(let viewed):
            guard viewed.userID == myUserID else { return .ignored }
            clearCounters(channelID: viewed.channelID)
            return .counters
        case .multipleChannelsViewed(let viewed):
            // The view call's event (T33-AV2 F1). No channel and no team in the envelope — only my
            // own user id — so the channels it names that this list has loaded are the ones cleared.
            // A channel the list does not know about is skipped rather than inserted: the frame says
            // "read", which cannot justify adding a row.
            guard viewed.userID.isEmpty || viewed.userID == myUserID else { return .ignored }
            let loadedChannels = Set(data.members.map(\.channelId))
            let readChannels = viewed.channelTimes.keys.filter { loadedChannels.contains($0) }
            guard !readChannels.isEmpty else { return .ignored }
            for channelID in readChannels { clearCounters(channelID: channelID) }
            return .counters
        case .posted, .postDeleted, .postEdited, .preferencesChanged:
            return .refreshNeeded
        case .userAdded(let change):
            // A join. Only my own changes this list; anybody else's is ignored.
            guard change.userID == myUserID else { return .ignored }
            return .reloadNeeded
        case .userRemoved(let change):
            // A removal or a leave. Mine drops the row; somebody else's does not touch my list.
            guard change.userID == myUserID else { return .ignored }
            return .reloadNeeded
        case .postUnread(let unread):
            guard unread.teamID.isEmpty || unread.teamID == teamID else { return .ignored }
            guard applyUnread(unread, myUserID: myUserID) else { return .ignored }
            return .applied
        case .channelMemberUpdated(let update):
            guard update.userID == myUserID else { return .ignored }
            guard applyMember(update.member) else { return .ignored }
            return .applied
        case .sidebarCategoryUpdated(let update):
            guard update.teamID.isEmpty || update.teamID == teamID else { return .ignored }
            guard applyLayout(update.categories) else { return .ignored }
            return .layoutChanged
        case .channelCreated:
            return .reloadNeeded
        case .channelDeleted:
            return .refreshNeeded
        default:
            return .ignored
        }
    }

    /// Local "this channel is read now" — optimistic, and corrected by the next refresh.
    private func clearCounters(channelID: String) {
        guard let index = data.members.firstIndex(where: { $0.channelId == channelID }) else { return }
        data.members[index].mentionCount = 0
        data.members[index].msgCount = data.channels.first(where: { $0.id == channelID })?.totalMsgCount
            ?? data.members[index].msgCount
        data.members[index].manuallyUnread = false
        rebuild()
    }

    /// Apply the server's `post_unread` counters for one channel.
    ///
    /// These are the numbers the sidebar's whole arithmetic is built on (`total_msg_count −
    /// msg_count`, `mention_count`), measured by the server, so they are used as they arrive instead
    /// of being incremented locally (which would drift after a reconnect). A row that is not loaded
    /// yet is inserted rather than ignored: a `post_unread` can arrive for a channel the last load
    /// did not have.
    private func applyUnread(_ unread: SocketPostUnread, myUserID: String?) -> Bool {
        guard !unread.channelID.isEmpty, data.channels.contains(where: { $0.id == unread.channelID })
                || data.members.contains(where: { $0.channelId == unread.channelID }) else {
            return false
        }
        if let index = data.members.firstIndex(where: { $0.channelId == unread.channelID }) {
            data.members[index].msgCount = unread.msgCount
            data.members[index].mentionCount = unread.mentionCount
            data.members[index].lastViewedAt = unread.lastViewedAt
            // The server clears "keep as unread" when it moves the cursor to the end.
            if unread.msgCount >= (data.channels.first(where: { $0.id == unread.channelID })?.totalMsgCount ?? 0) {
                data.members[index].manuallyUnread = false
            }
        } else {
            data.members.append(MMChannelMember(channelId: unread.channelID,
                                                userId: myUserID ?? "",
                                                lastViewedAt: unread.lastViewedAt,
                                                msgCount: unread.msgCount,
                                                mentionCount: unread.mentionCount))
        }
        rebuild()
        return true
    }

    /// Replace one membership row from a `channel_member_updated` payload (my own row only: another
    /// person's mute says nothing about my badges).
    private func applyMember(_ member: MMChannelMember) -> Bool {
        guard data.channels.contains(where: { $0.id == member.channelId })
                || data.members.contains(where: { $0.channelId == member.channelId }) else {
            return false
        }
        if let index = data.members.firstIndex(where: { $0.channelId == member.channelId }) {
            data.members[index] = member
        } else {
            data.members.append(member)
        }
        rebuild()
        return true
    }

    // MARK: Writes

    /// Move a channel one place inside its category (the touch equivalent of a drag).
    ///
    /// The move is applied locally first (a sidebar that waits for a round trip before the row
    /// moves feels broken), then persisted. Manual sorting is the only sorting a move can mean, so
    /// the category is switched to it — upstream's optimistic `updateCategorySorting` on drop. A
    /// failed write puts the previous layout back and says so.
    @discardableResult
    func move(channelID: String, inCategory categoryID: String, by offset: Int) async -> Bool {
        guard canWriteLayout, let teamID else { return false }
        guard let groupIndex = groups.firstIndex(where: { $0.category.id == categoryID }) else { return false }
        let rows = groups[groupIndex].entries
        guard let index = rows.firstIndex(where: { $0.id == channelID }) else { return false }
        let target = index + offset
        guard rows.indices.contains(target) else { return false }

        var reordered = rows
        let moved = reordered.remove(at: index)
        reordered.insert(moved, at: target)

        var previous = data.categories
        guard let categoryIndex = data.categories.firstIndex(where: { $0.id == categoryID }) else { return false }
        data.categories[categoryIndex].sorting = "manual"
        // Keep any ids the category lists that are not on screen (a channel of another kind, a
        // stale row), appended after the visible ones, so a write cannot silently unassign them.
        let visible = Set(rows.map(\.id))
        let hidden = data.categories[categoryIndex].channelIds.filter { !visible.contains($0) }
        data.categories[categoryIndex].channelIds = reordered.map(\.id) + hidden
        rebuild()

        do {
            let saved = try await service.save(categories: data.categories, teamID: teamID)
            // The write landed; rebase on the array the server stored. An empty answer changes
            // nothing (the optimistic order is already on screen and the server accepted it).
            applyLayout(saved)
            actionError = nil
            return true
        } catch {
            data.categories = previous
            actionError = Self.message(for: error, action: "move that channel")
            rebuild()
            return false
        }
    }

    /// Add or remove a favourite. Favourites are the `favorites` category's channel ids; the write is
    /// the same full-array `PUT` a reorder uses.
    @discardableResult
    func setFavorite(_ favorite: Bool, channelID: String) async -> Bool {
        guard canWriteLayout, let teamID else { return false }
        let previous = data.categories
        var categories = data.categories
        if let index = categories.firstIndex(where: { $0.kind == .favorites }) {
            if favorite, !categories[index].channelIds.contains(channelID) {
                categories[index].channelIds.insert(channelID, at: 0)
            } else if !favorite {
                categories[index].channelIds.removeAll { $0 == channelID }
            }
        } else if favorite {
            categories.insert(ChannelSidebarDerivation.defaultCategory(.favorites,
                                                                       userID: "",
                                                                       teamID: teamID),
                              at: 0)
            categories[0].channelIds = [channelID]
        }
        data.categories = categories
        rebuild()
        do {
            let saved = try await service.save(categories: categories, teamID: teamID)
            applyLayout(saved)
            actionError = nil
            return true
        } catch {
            data.categories = previous
            actionError = Self.message(for: error, action: "change that favorite")
            rebuild()
            return false
        }
    }

    /// Mute or unmute one channel (`mark_unread`). The row updates only after the server accepted it:
    /// a mute that did not reach the server would silently start showing badges again.
    @discardableResult
    func setMuted(_ muted: Bool, channelID: String) async -> Bool {
        let previous = data.members
        if let index = data.members.firstIndex(where: { $0.channelId == channelID }) {
            data.members[index].notifyProps = Self.notifyProps(data.members[index].notifyProps,
                                                               markUnread: ChannelSidebarDerivation.markUnread(forMuted: muted))
            rebuild()
        }
        do {
            try await service.setMuted(muted, channelID: channelID)
            actionError = nil
            return true
        } catch {
            data.members = previous
            actionError = Self.message(for: error, action: muted ? "mute that channel" : "unmute that channel")
            rebuild()
            return false
        }
    }

    /// Collapse or expand a category. Local-first (a header that waits for a round trip feels
    /// broken), then persisted — the server stores `collapsed`.
    ///
    /// The write is the same full-array `PUT` a move uses, and its answer is now decoded (T33-AV F1),
    /// so a collapse actually reaches the server. For that reason a **failed** write is no longer
    /// swallowed: the category goes back to its previous state and the reason is shown, exactly like
    /// a failed move — a header that stays collapsed locally while the server still says expanded would
    /// flip back on the next launch for no stated reason.
    func setCollapsed(_ collapsed: Bool, categoryID: String) async {
        guard let index = data.categories.firstIndex(where: { $0.id == categoryID }) else { return }
        guard data.categories[index].collapsed != collapsed else { return }
        let previous = data.categories
        data.categories[index].collapsed = collapsed
        rebuild()
        guard canWriteLayout, let teamID else { return }
        do {
            let saved = try await service.save(categories: data.categories, teamID: teamID)
            applyLayout(saved)
            actionError = nil
        } catch {
            data.categories = previous
            actionError = Self.message(for: error, action: collapsed ? "collapse that category"
                                                                     : "expand that category")
            rebuild()
        }
    }

    func isCollapsed(categoryID: String) -> Bool {
        data.categories.first(where: { $0.id == categoryID })?.collapsed ?? false
    }

    // MARK: Internals

    private func performLoad(teamID: String) async {
        generation += 1
        let mine = generation
        if groups.isEmpty { phase = .loading }
        do {
            let next = try await service.load(teamID: teamID)
            guard mine == generation else { return }
            // A team switch that landed while this load was in flight must not be overwritten.
            guard self.teamID == nil || self.teamID == teamID else { return }
            self.teamID = teamID
            loadedTeamID = teamID
            data = next
            countsAreStale = next.membersFailed
            // A synthesised layout is not the user's: it draws, but a write must not rewrite
            // somebody's grouping from a guess (`canWriteLayout`).
            groupingIsApproximate = next.categoriesFailed || next.categories.isEmpty
            phase = .loaded
            rebuild()
        } catch {
            guard mine == generation else { return }
            if let mmError = error as? MMError, case .unauthorized = mmError {
                // The session is gone; `AuthCoordinator` owns that transition.
                return
            }
            phase = .failed(Self.message(for: error, action: "load your channels"))
            rebuild()
        }
    }

    /// Rebase the groups on a categories array that came from the server — either the answer to a
    /// write (`PUT …/channels/categories`, a bare array) or a `sidebar_category_updated` event.
    ///
    /// The drawn order is kept from `categoryOrder` (a channel move does not reorder categories); only
    /// a category the answer introduced is appended, in the server's position — see
    /// `ChannelSidebarDerivation.order(afterSaved:previous:)`. Returns `false` when there is nothing to
    /// apply (an empty array), so an empty event payload can never blank the grouping.
    @discardableResult
    private func applyLayout(_ categories: [MMSidebarCategory]) -> Bool {
        guard !categories.isEmpty else { return false }
        data.categories = categories
        data.categoryOrder = ChannelSidebarDerivation.order(afterSaved: categories,
                                                            previous: data.categoryOrder)
        groupingIsApproximate = false
        rebuild()
        return true
    }

    private func rebuild() {
        groups = ChannelSidebarDerivation.groups(from: data,
                                                 selectedChannelID: selectedChannelID,
                                                 selectedChannelName: selectedChannelName)
        totals = ChannelSidebarDerivation.totals(groups)
    }

    private static func notifyProps(_ current: JSONValue?, markUnread: String) -> JSONValue {
        var object = current?.objectValue ?? [:]
        object["mark_unread"] = .string(markUnread)
        return .object(object)
    }

    /// Error copy for an action. A transport failure gets the app's existing wording
    /// (`MMError.errorDescription`); anything else gets a sentence that names what failed.
    static func message(for error: Error, action: String) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        return "Could not \(action)."
    }
}

/// What the model wants the coordinator to do after one socket event.
enum ChannelEventOutcome: Equatable, Sendable {
    case ignored
    /// Local state changed from the event payload; no request needed.
    case applied
    /// The counters may have moved — refresh them, debounced by the coordinator.
    case counters
    case refreshNeeded
    /// The layout was applied from the event payload (`sidebar_category_updated`); nothing to fetch.
    case layoutChanged
    /// The channel list itself gained or lost a channel: a **full** reload, debounced.
    case reloadNeeded
}
