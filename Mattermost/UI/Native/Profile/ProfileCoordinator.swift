// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/user_profile/index.ts (one screen instance per user, rebuilt from the server on
//        each open), app/actions/websocket/user.ts (`status_change`, `user_updated`),
//        app/actions/websocket/index.ts (the single socket per server), app/actions/app/global.ts
//        (the app-state handler that ages presence on background/foreground).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §18; no
// upstream source copied. The coordinator decomposition mirrors T40's `ChannelInfoCoordinator` and
// T33's `ChannelSidebarCoordinator` (one owner, one model per key, one socket), which is this repo's
// convention (docs/component-map.md §1).
//
// Why a coordinator and not a `@StateObject` in the sheet:
//  - the sheet is re-created on every presentation, and a model that died with it would re-read the
//    profile and the status on every open;
//  - `status_change` / `user_updated` arrive on the rail's socket (`TeamSidebarCoordinator.onTeamEvent`)
//    which is the app's single WebSocket per server — a view cannot be the subscriber without owning
//    a socket;
//  - **auto-away** is an app-lifecycle fact, not a screen fact: it has to happen with no profile open
//    at all, so it belongs to an object that outlives every screen.
//
// The cache is bounded (LRU, 6 profiles per server): each model holds a profile, a presence row and
// possibly an avatar. Eviction is safe because every model is rebuilt from the server on the next
// open (nothing is written back).

import Foundation
import Combine

/// Owns one `ProfileViewModel` per (server, user), the app's per-server presence memory, and the
/// auto-away pass.
@MainActor
final class ProfileCoordinator: ObservableObject {

    /// How many profiles keep their state warm per server.
    static let warmProfileLimit = 6

    private var auth: AuthCoordinator?
    private var serverStore: ServerStore?

    private var models: [UUID: [String: ProfileViewModel]] = [:]
    /// Most-recently-opened user ids per server, newest last.
    private var recent: [UUID: [String]] = [:]

    /// My own presence per server, as far as this app knows it (a status read, a socket frame, or a
    /// write of ours). Auto-away reasons about this and nothing else.
    private var myStatus: [UUID: UserStatusSnapshot] = [:]
    /// The status the reader last chose per server; what a return to the foreground restores.
    private var preferredPresence: [UUID: UserPresence] = [:]
    /// Servers where *this app* set `away` on the way to the background.
    private var autoAwayServers: Set<UUID> = []
    /// The server's answer to that write, per server. It is what lets the return tell this client's
    /// own `away` (which the server marks `manual`) apart from one somebody else chose.
    private var autoAwayWrites: [UUID: UserStatusSnapshot] = [:]

    /// Test seam: replaces the production session-backed service (T40's `serviceFactory`).
    var serviceFactory: ((ServerConfig) -> ProfileServing)?

    /// Test seam for the team-scoped permission reads the **write rows** need (T5449 C3): the four
    /// reads `ChannelMemberAdminDirectory` performs. Production resolves the session's client per
    /// call, like `serviceFactory`.
    var channelInfoServiceFactory: ((ServerConfig) -> ChannelInfoServing)?

    /// The team-scoped "may I manage members here?" answers, per (server, team).
    ///
    /// Resolved when a profile sheet opens and read from the matrix — **never** on a row's tap path,
    /// and never assumed: an unresolved (server, team) means the Add to a channel row is absent
    /// (`docs/t_8f9f5449-profile-popover-parity.md` §4, §6).
    let channelAdmin = ChannelMemberAdminDirectory()

    /// How often an open profile re-reads presence. Production default is in
    /// `ProfileViewModel.defaultPresenceInterval`; a UI test sets it through
    /// `-uiTestProfilePresenceInterval` (the socket half is asserted inside a window shorter than this,
    /// so a passing socket assertion cannot be a poll that happened to fire).
    var presenceInterval: TimeInterval = ProfileViewModel.defaultPresenceInterval

    /// Diagnostics: how many profile models are alive (one test asserts the cache is bounded).
    var modelCount: Int { models.values.reduce(0) { $0 + $1.count } }

    /// Diagnostics: the auto-away bookkeeping, so a test can assert it without a server.
    var autoAwayCount: Int { autoAwayServers.count }

    func bind(auth: AuthCoordinator?, serverStore: ServerStore?) {
        self.auth = auth
        self.serverStore = serverStore
    }

    // MARK: Models

    /// The profile model for one account, created on first use.
    func model(for server: ServerConfig, userID: String) -> ProfileViewModel {
        if let existing = models[server.id]?[userID] {
            // Keep an open model in step with the app's own presence memory (auto-away may have
            // written while this screen was closed).
            if let mine = myStatus[server.id], mine.userID == userID {
                existing.applyMyStatus(mine)
            }
            touch(serverID: server.id, userID: userID)
            return existing
        }
        let model = ProfileViewModel(serverID: server.id,
                                     userID: userID,
                                     myUserID: myUserID(for: server),
                                     service: service(for: server))
        model.onMyStatusChanged = { [weak self] serverID, snapshot in
            self?.myStatus[serverID] = snapshot
            self?.preferredPresence[serverID] = snapshot.presence
        }
        models[server.id, default: [:]][userID] = model
        touch(serverID: server.id, userID: userID)
        evictIfNeeded(serverID: server.id)
        return model
    }

    /// The signed-in account's own profile model (the header's avatar, the shell's "you" entry).
    func myModel(for server: ServerConfig) -> ProfileViewModel? {
        guard let id = myUserID(for: server), !id.isEmpty else { return nil }
        return model(for: server, userID: id)
    }

    /// The signed-in user's id for a server, from the auth coordinator's phase (no request).
    func myUserID(for server: ServerConfig) -> String? {
        guard let auth else { return nil }
        if case .signedIn(_, let userID) = auth.phase(for: server) { return userID }
        return nil
    }

    func forget(serverID: UUID, userID: String) {
        models[serverID]?[userID] = nil
        recent[serverID]?.removeAll { $0 == userID }
    }

    // MARK: Socket

    /// One event from the server's socket. Delivered by `TeamSidebarCoordinator.onTeamEvent`, i.e. the
    /// app's single WebSocket per server.
    func handle(_ event: SocketEvent, serverID: UUID) {
        // Presence is app-wide state first: remember my own status even when no profile is open, so
        // the next auto-away pass has something to reason about.
        if case .statusChange(let change) = event,
           var mine = myStatus[serverID], mine.userID == change.userID {
            mine = mine.applying(socketStatus: change.status)
            myStatus[serverID] = mine
            // A socket frame is the server telling us what everybody sees, and usually the newest
            // fact about a choice the reader made on another device — so it becomes the restore
            // preference. The exception is the server echoing *our own* auto-away write back at us
            // (it does, within milliseconds): adopting that echo would set the preference to `away`
            // and the return would then find nothing to put back, leaving the reader away for good.
            if AutoAwayRule.adoptsSocketStatus(mine.presence,
                                               owningAutoAway: autoAwayServers.contains(serverID)) {
                preferredPresence[serverID] = mine.presence
            }
            if mine.presence != .away { autoAwayServers.remove(serverID) }
        }
        for (_, model) in models[serverID] ?? [:] {
            model.handle(event)
        }
    }

    /// Sign-out / expiry / server removal: drop everything this credential built.
    func deactivate(_ serverID: UUID) {
        models[serverID] = nil
        recent[serverID] = nil
        myStatus[serverID] = nil
        preferredPresence[serverID] = nil
        autoAwayServers.remove(serverID)
        autoAwayWrites[serverID] = nil
        channelAdmin.forget(serverID: serverID)
    }

    func authPhaseChanged(_ serverID: UUID) {
        deactivate(serverID)
    }

    // MARK: Auto-away

    /// The app moved between foreground and background.
    ///
    /// `servers` is the shell's live server list: auto-away is per credential, and a server that is
    /// signed out has nothing to write. The decisions themselves are pure (`AutoAwayRule`); this
    /// method only supplies the facts and performs the write.
    func sceneChanged(isActive: Bool, servers: [ServerConfig]) async {
        if isActive {
            await restoreAfterAutoAway(servers: servers)
        } else {
            await ageToAway(servers: servers)
        }
    }

    /// Backgrounding: age a server-derived `online` to `away`, and remember which servers this app
    /// touched so the return knows what to put back.
    private func ageToAway(servers: [ServerConfig]) async {
        for server in servers where myUserID(for: server) != nil {
            guard let mine = await currentStatus(for: server) else { continue }
            myStatus[server.id] = mine
            guard case .setAway = AutoAwayRule.onBackground(current: mine) else { continue }
            autoAwayServers.insert(server.id)
            if let confirmed = await write(presence: .away, dndEndTime: nil, for: server) {
                // Keep the server's own answer: `away` comes back `manual: true`, and the return has
                // to recognise it as this client's doing rather than as somebody else's choice.
                autoAwayWrites[server.id] = confirmed
            }
        }
    }

    /// Foregrounding: put back the status this app changed, and only that one.
    private func restoreAfterAutoAway(servers: [ServerConfig]) async {
        for server in servers where autoAwayServers.contains(server.id) {
            let preferred = preferredPresence[server.id] ?? .online
            let mine = await currentStatus(for: server)
            guard case .restore(let presence) = AutoAwayRule.onForeground(current: mine,
                                                                         preferred: preferred,
                                                                         didAutoAway: true,
                                                                         ownWrite: autoAwayWrites[server.id]) else {
                // Either the status is already what it should be, or something else changed it while
                // the app was away — in both cases this client stops owning the change.
                autoAwayServers.remove(server.id)
                autoAwayWrites[server.id] = nil
                continue
            }
            await write(presence: presence, dndEndTime: nil, for: server)
            autoAwayServers.remove(server.id)
            autoAwayWrites[server.id] = nil
        }
    }

    /// Read my status for a server: the remembered row when there is one, a server read otherwise
    /// (a launch that never received a `status_change`).
    private func currentStatus(for server: ServerConfig) async -> UserStatusSnapshot? {
        if let remembered = myStatus[server.id], !remembered.userID.isEmpty { return remembered }
        guard let myID = myUserID(for: server), !myID.isEmpty else { return nil }
        let service = service(for: server)
        guard let statuses = try? await service.statuses(ids: [myID]),
              let match = statuses.first(where: { $0.userId == myID }) else { return nil }
        let snapshot = ProfileViewModel.snapshot(from: match)
        myStatus[server.id] = snapshot
        if preferredPresence[server.id] == nil { preferredPresence[server.id] = snapshot.presence }
        return snapshot
    }

    /// One presence write, and the memory of its answer.
    @discardableResult
    private func write(presence: UserPresence, dndEndTime: Int64?,
                       for server: ServerConfig) async -> UserStatusSnapshot? {
        guard let myID = myUserID(for: server) else { return nil }
        let service = service(for: server)
        guard let answer = try? await service.setPresence(presence, dndEndTime: dndEndTime, userID: myID) else {
            // A failed auto-away write is not a screen error: the next launch reads the truth from
            // the server. Forget the bookkeeping so a later foreground does not claim a restore.
            autoAwayServers.remove(server.id)
            autoAwayWrites[server.id] = nil
            return nil
        }
        let snapshot = ProfileViewModel.snapshot(from: answer)
        myStatus[server.id] = snapshot
        models[server.id]?[myID]?.applyMyStatus(snapshot)
        if presence != .away { preferredPresence[server.id] = presence }
        return snapshot
    }

    /// Set my status from a screen (the profile's status setter). Routed through the coordinator so
    /// the auto-away memory and the open models cannot disagree with the screen that made the change.
    func setMyPresence(_ presence: UserPresence,
                       dndDuration: StatusDuration?,
                       server: ServerConfig) async {
        preferredPresence[server.id] = presence
        autoAwayServers.remove(server.id)
        autoAwayWrites[server.id] = nil
        guard let myID = myUserID(for: server) else { return }
        if let model = models[server.id]?[myID] {
            await model.setPresence(presence, dndDuration: dndDuration)
            return
        }
        let endMillis = presence == .dnd ? dndDuration?.dndEndTimeMillis(from: Date()) : nil
        await write(presence: presence, dndEndTime: endMillis, for: server)
    }

    // MARK: - The write rows' context (T5449 C3)

    /// Fill a profile model's `actionContext`: the app facts the Call and Add-to-a-channel rows are
    /// gated on (`docs/t_8f9f5449-profile-popover-parity.md` §4).
    ///
    /// Called from `ProfileSheet`'s `.task` — i.e. **when the sheet opens**, never from a row's tap
    /// path — and it publishes what it already knows *before* the two team reads answer, so the
    /// Message row appears with the profile rather than after the network.
    ///
    /// The two team answers are resolved here because this object owns the cache:
    ///
    ///  * `inCurrentTeam` — `GET /teams/{tid}/members/{userID}`, asked once per (profile, team);
    ///  * `canManageAnyChannelMembers` — `ChannelMemberAdminDirectory`, resolved once per
    ///    (server, team) and reused by the picker.
    ///
    /// A failed read leaves the field `nil`, which the matrix reads as **absent** — the row appears
    /// on the next open rather than being offered on a guess.
    func prepareActions(model: ProfileViewModel,
                        server: ServerConfig,
                        teamID: String?,
                        callsAvailable: Bool,
                        callsSurfaceNative: Bool,
                        hasLiveCallElsewhere: Bool) async {
        var context = ProfileActionContext()
        context.myUserID = model.myUserID
        context.hasCustomStatus = model.activeCustomStatus != nil
        context.callsAvailable = callsAvailable
        context.callsSurfaceNative = callsSurfaceNative
        context.hasLiveCallElsewhere = hasLiveCallElsewhere
        context.hasTeam = !(teamID ?? "").isEmpty
        model.actionContext = context

        // Nothing below can change a row for my own profile or for an account that cannot receive
        // either write: skip the two round trips.
        guard let teamID, !teamID.isEmpty,
              let profile = model.profile, !profile.isDeactivated, !model.isMe else { return }

        async let memberRead = isTeamMember(server: server, teamID: teamID, userID: profile.id)
        async let adminRead = resolveChannelAdmin(server: server, teamID: teamID)
        let (member, admin) = await (memberRead, adminRead)

        var prepared = model.actionContext
        prepared.inCurrentTeam = member
        prepared.canManageAnyChannelMembers = admin?.canManageAnyChannelMembers
        model.actionContext = prepared
    }

    /// The cached team answer, or `nil` when this (server, team) has not been resolved yet.
    func channelAdminAnswer(serverID: UUID, teamID: String) -> ChannelMemberAdminAnswer? {
        channelAdmin.answer(serverID: serverID, teamID: teamID)
    }

    /// Resolve — or read from the cache — whether I may manage members of any channel in this team.
    ///
    /// The read is the five-request fan-in `ChannelMemberAdminDirectory.resolve` performs; a failure
    /// answers `nil` (rows absent), never a guess and never a banner over a profile that loaded fine.
    @discardableResult
    func resolveChannelAdmin(server: ServerConfig, teamID: String,
                             force: Bool = false) async -> ChannelMemberAdminAnswer? {
        if !force, let cached = channelAdminAnswer(serverID: server.id, teamID: teamID) {
            return cached
        }
        guard let myID = myUserID(for: server), !myID.isEmpty else { return nil }
        do {
            let answer = try await ChannelMemberAdminDirectory.resolve(service: channelInfoService(for: server),
                                                                      teamID: teamID,
                                                                      myUserID: myID)
            channelAdmin.store(answer, serverID: server.id, teamID: teamID)
            return answer
        } catch {
            MMLog.debug("MMProfile", "channel-admin answer failed for team \(teamID): \(error)")
            return nil
        }
    }

    /// Is this account a **live** member of that team? `nil` when the server could not be asked.
    func isTeamMember(server: ServerConfig, teamID: String, userID: String) async -> Bool? {
        do {
            let membership = try await channelInfoService(for: server).teamMembership(teamID: teamID,
                                                                                     userID: userID)
            return membership.deleteAt == 0
        } catch MMError.notFound {
            return false
        } catch {
            return nil
        }
    }

    /// The channel-info service for one server — the seam the write rows' reads go through, resolved
    /// per call so a service built before the session finished restoring is not a signed-out one.
    func channelInfoService(for server: ServerConfig) -> ChannelInfoServing {
        if let channelInfoServiceFactory { return channelInfoServiceFactory(server) }
        let auth = self.auth
        return SessionChannelInfoService {
            guard let auth, let session = try? auth.session(for: server) else { return nil }
            return session.client
        }
    }

    // MARK: Internals

    private func service(for server: ServerConfig) -> ProfileServing {
        if let serviceFactory { return serviceFactory(server) }
        let auth = self.auth
        return SessionProfileService {
            guard let auth, let session = try? auth.session(for: server) else { return nil }
            return session.client
        }
    }

    private func touch(serverID: UUID, userID: String) {
        var list = recent[serverID] ?? []
        list.removeAll { $0 == userID }
        list.append(userID)
        recent[serverID] = list
    }

    private func evictIfNeeded(serverID: UUID) {
        guard let list = recent[serverID], list.count > Self.warmProfileLimit else { return }
        let excess = list.count - Self.warmProfileLimit
        for userID in list.prefix(excess) {
            models[serverID]?[userID] = nil
        }
        recent[serverID] = Array(list.dropFirst(excess))
    }
}
