// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/actions/remote/category.ts + channel.ts (one channel-list owner per server; a team
//        switch reloads that team's channels and categories), app/actions/websocket/*.ts (the
//        channel-scoped events that move the sidebar: `posted`, `post_deleted`, `channel_viewed`,
//        `preferences_changed`), app/screens/home/channel_list/channel_list.tsx (the list is mounted
//        inside the team region, sharing one lifetime with it).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §3; no
// upstream source copied. The coordinator shape is this repo's own (docs/component-map.md §1),
// deliberately mirroring `TeamSidebarCoordinator` from T32.

import Combine
import Foundation

/// The app-level owner of the channel sidebar: **one model per server**, and no socket of its own.
///
/// ## Why no second socket
///
/// `TeamSidebarCoordinator` already owns exactly one WebSocket per server (T32's card proves that
/// property). A sidebar that opened its own connection would double the sockets for the same user —
/// the memory cost Path B exists to remove, and a second place where "which events are mine?" is
/// decided. So this coordinator is fed by `TeamSidebarCoordinator.onTeamEvent`, which delivers only
/// events that passed the current team's `TeamSocketScope`. The channel→team map that scope needs to
/// attribute an event to a team is published here, from the channel list itself (that is what
/// `TeamSocketScope.channelTeams` was reserved for).
///
/// ## Why the selection is not stored
///
/// The current channel/team lives in `NativeNavigation.location` — the one value a row tap, a deep
/// link and a notification tap write. This object subscribes to it and pushes it into each model, so
/// the list cannot disagree with the destination the shell is showing, and a team switch reloads the
/// list through the same path a fresh launch takes.
@MainActor
final class ChannelSidebarCoordinator: ObservableObject {

    weak var auth: AuthCoordinator?
    weak var navigation: NativeNavigation?
    weak var serverStore: ServerStore?
    /// The team rail, read for two things: a team's display name (a row's `sidebarCurrentTeam`) and
    /// name → id resolution for a deep link that carries only `/acme/channels/general`.
    weak var teams: TeamSidebarCoordinator?

    private let events: TeamEventSourcing
    /// How long socket activity is coalesced before the counters are refetched. A burst of ten posts
    /// is one request, not ten.
    private let refreshDelay: TimeInterval
    /// The service seam: production uses the server's own `AuthSession.client`; a test supplies a
    /// fake server so the coordinator's own rules (one model per server, scope refresh, debounce)
    /// run without a network.
    private let serviceFactory: ((ServerConfig) -> ChannelSidebarServing)?

    private var models: [UUID: ChannelListViewModel] = [:]
    private var pendingRefresh: [UUID: Task<Void, Never>] = [:]
    private var refreshTokens: [UUID: UUID] = [:]
    private var locationSink: AnyCancellable?
    /// The team each server's list was last asked for, so a location change that only moved the
    /// selected channel does not reload anything.
    private var loadedTeams: [UUID: String] = [:]

    // Observable evidence for tests and diagnostics.
    private(set) var counterRefreshCount = 0
    private(set) var eventCount = 0

    init(events: TeamEventSourcing? = nil,
         refreshDelay: TimeInterval = 1.5,
         makeService: ((ServerConfig) -> ChannelSidebarServing)? = nil) {
        // Built here, not as a default argument: a default argument is evaluated in a nonisolated
        // context and `SocketTeamEventSource` is main-actor isolated like the rest of the shell.
        self.events = events ?? SocketTeamEventSource()
        self.refreshDelay = refreshDelay
        self.serviceFactory = makeService
    }

    // MARK: Wiring

    /// Bind the shell objects this coordinator reads. Idempotent — `bindShellStores()` may run more
    /// than once (the app's `.task` and `onOpenURL`).
    func bind(auth: AuthCoordinator,
              navigation: NativeNavigation,
              serverStore: ServerStore?,
              teams: TeamSidebarCoordinator?) {
        self.auth = auth
        self.navigation = navigation
        self.serverStore = serverStore
        self.teams = teams
        locationSink?.cancel()
        locationSink = navigation.$location
            .sink { [weak self] location in
                self?.apply(location)
            }
        apply(navigation.location)
    }

    /// The list's model for one server (created on first use and kept for the app's lifetime).
    func model(for server: ServerConfig) -> ChannelListViewModel {
        if let existing = models[server.id] { return existing }
        let service: ChannelSidebarServing
        if let serviceFactory {
            service = serviceFactory(server)
        } else {
            service = SessionChannelSidebarService { [weak self] in
                guard let self, let auth = self.auth,
                      let session = try? auth.session(for: server) else { return nil }
                return (session.client, auth.userID(for: server.id))
            }
        }
        let model = ChannelListViewModel(server: server, service: service)
        if let location = navigation?.location, location.serverID == server.id {
            model.setSelection(teamID: location.teamID,
                               channelID: location.channelID,
                               channelName: location.channelName)
        }
        models[server.id] = model
        return model
    }

    /// The appearance pass: point the model at the shell's current team and load it once.
    func activate(_ server: ServerConfig) async {
        let model = model(for: server)
        if let location = navigation?.location, location.serverID == server.id {
            model.setSelection(teamID: location.teamID,
                               channelID: location.channelID,
                               channelName: location.channelName)
        }
        await model.load(ifNeeded: true)
        if let teamID = model.teamID { loadedTeams[server.id] = teamID }
        publishChannelTeams(for: server, model: model)
        await applyPendingTeam(for: server, model: model)
    }

    /// The auth coordinator's phase for one server changed.
    ///
    /// The `AuthCoordinator` phase is the one place a session's death or birth is decided, so the list
    /// cannot outlive the credential it was built with, and a finished sign-in reloads it.
    func authPhaseChanged(_ serverID: UUID) {
        guard let auth else { return }
        switch auth.phase(for: serverID) {
        case .signedOut, .expired:
            Task { await deactivate(serverID) }
        case .signedIn:
            Task { await reloadIfActive(serverID) }
        case .unresolved:
            break
        }
    }

    /// Sign-out / expiry / server removal: forget the server's list and its debounce.
    func deactivate(_ serverID: UUID) async {
        pendingRefresh[serverID]?.cancel()
        pendingRefresh[serverID] = nil
        refreshTokens[serverID] = nil
        models[serverID] = nil
        loadedTeams[serverID] = nil
        teams?.setChannelTeams([:], for: serverID)
    }

    // MARK: Socket

    /// One event from the server's socket, delivered by `TeamSidebarCoordinator.onTeamEvent` (i.e.
    /// already scoped to the team that is on screen).
    func handle(_ event: SocketEvent, serverID: UUID) async {
        guard let model = models[serverID] else { return }
        eventCount += 1
        switch model.handle(event, myUserID: auth?.userID(for: serverID)) {
        case .ignored:
            return
        case .applied, .counters:
            // The local state moved; the server's numbers are fetched on the debounce anyway, so a
            // burst still costs one request.
            scheduleRefresh(serverID: serverID)
        case .refreshNeeded, .layoutChanged:
            scheduleRefresh(serverID: serverID)
        }
    }

    /// Test/diagnostic surface: how many models this coordinator holds (one per active server).
    var modelCount: Int { models.count }

    func loadedTeam(for serverID: UUID) -> String? { loadedTeams[serverID] }

    // MARK: Location → models

    private func apply(_ location: NativeLocation) {
        guard let serverID = location.serverID else { return }
        let model = models[serverID]
        model?.setSelection(teamID: location.teamID,
                            channelID: location.channelID,
                            channelName: location.channelName)
        // A team change means different channels and different categories: reload through the same
        // path a fresh appearance takes.
        guard let model, let teamID = location.teamID, loadedTeams[serverID] != teamID else { return }
        Task { await self.load(serverID: serverID, model: model, teamID: teamID) }
    }

    /// A location that named a team only by *name* (a deep link): wait for the rail to resolve the
    /// id, then load that team.
    private func applyPendingTeam(for server: ServerConfig, model: ChannelListViewModel) async {
        guard model.teamID == nil, let location = navigation?.location,
              location.serverID == server.id else { return }
        guard let name = location.teamName, !name.isEmpty else { return }
        guard let id = teams?.model(for: server).entries.first(where: { $0.name == name })?.id else { return }
        model.setSelection(teamID: id, channelID: location.channelID, channelName: location.channelName)
        await load(serverID: server.id, model: model, teamID: id)
    }

    private func load(serverID: UUID, model: ChannelListViewModel, teamID: String) async {
        loadedTeams[serverID] = teamID
        await model.load(ifNeeded: true)
        // Re-publish after a load: the model now knows this team's channels, which is what the
        // socket scope needs to attribute their events to this team.
        if let server = serverStore?.servers.first(where: { $0.id == serverID }) {
            publishChannelTeams(for: server, model: model)
        }
    }

    /// A finished sign-in for a server that is already on screen: reload its list.
    private func reloadIfActive(_ serverID: UUID) async {
        guard let model = models[serverID],
              let server = serverStore?.servers.first(where: { $0.id == serverID }) else { return }
        await activate(server)
        _ = model
    }

    /// Give the team scope the channel→team map, so an event for a channel of the team on screen is
    /// delivered instead of refused (`TeamSocketScope` refuses un-attributable events on purpose).
    private func publishChannelTeams(for server: ServerConfig, model: ChannelListViewModel) {
        guard let teamID = model.teamID else { return }
        var map: [String: String] = [:]
        for entry in model.allEntries { map[entry.id] = teamID }
        teams?.setChannelTeams(map, for: server.id)
    }

    private func scheduleRefresh(serverID: UUID) {
        guard pendingRefresh[serverID] == nil else { return }
        let token = UUID()
        refreshTokens[serverID] = token
        pendingRefresh[serverID] = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(max(0, self.refreshDelay) * 1_000_000_000))
            guard !Task.isCancelled, self.refreshTokens[serverID] == token else { return }
            self.pendingRefresh[serverID] = nil
            guard let model = self.models[serverID] else { return }
            self.counterRefreshCount += 1
            await model.refreshCounters()
            if let server = self.serverStore?.servers.first(where: { $0.id == serverID }) {
                self.publishChannelTeams(for: server, model: model)
            }
        }
    }
}

// MARK: - The channel directory

/// `NativeChannelDirectory` for the native shell (T30's seam, reserved for exactly this card).
///
/// A deep link carries `/acme/channels/general` (team *name*, channel *name*), a notification tap
/// carries `channel_id` + `team_id` and no names. With a loaded channel list both can be completed
/// into one `NativeLocation`, which is the convergence T30 could only describe structurally.
///
/// Resolution is deliberately partial and honest: facts the list does not know are left as the
/// caller supplied them (`nil` stays `nil`), never guessed. A permalink that names only a post is not
/// this object's business (S12/T36 resolves posts to channels).
extension ChannelSidebarCoordinator: NativeChannelDirectory {
    func identity(for request: NativeChannelRequest, serverID: UUID) -> NativeChannelIdentity? {
        guard let model = models[serverID] else { return nil }
        // Team name → id from the rail (the channel list knows the team it was loaded for, the rail
        // knows every team of this user).
        var teamID = request.teamID
        var teamName = request.teamName
        if teamID == nil, let name = teamName, !name.isEmpty,
           let server = serverStore?.servers.first(where: { $0.id == serverID }),
           let entry = teams?.model(for: server).entries.first(where: { $0.name == name }) {
            teamID = entry.id
            teamName = entry.name
        }

        guard request.channelID != nil || request.channelName != nil else {
            // Nothing to resolve against the list; hand back the team facts so a `/{team}` route and
            // a `/{team}/channels/<id>` route still agree on the team.
            return NativeChannelIdentity(teamID: teamID,
                                         teamName: teamName,
                                         channelID: request.channelID,
                                         channelName: request.channelName)
        }

        // Only the team on screen has a loaded list; a channel of another team resolves once that
        // team is opened (and the shell keeps what the caller supplied until then).
        guard model.teamID == nil || model.teamID == teamID else {
            return NativeChannelIdentity(teamID: teamID,
                                         teamName: teamName,
                                         channelID: request.channelID,
                                         channelName: request.channelName)
        }
        let resolved = model.identity(channelID: request.channelID, channelName: request.channelName)
        return NativeChannelIdentity(teamID: resolved.teamID ?? teamID,
                                     teamName: teamName,
                                     channelID: resolved.channelID,
                                     channelName: resolved.channelName)
    }
}
