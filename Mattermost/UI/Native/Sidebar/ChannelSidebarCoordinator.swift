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
    /// is one request, not ten. 1.5 s matches the rail's own `unreadRefreshDelay` (T32): one screen,
    /// one debounce. (The build note said 300 ms until T33-AV F7 measured it; the docs are corrected,
    /// the default is deliberate.)
    private let refreshDelay: TimeInterval
    /// The service seam: production uses the server's own `AuthSession.client`; a test supplies a
    /// fake server so the coordinator's own rules (one model per server, scope refresh, debounce)
    /// run without a network.
    private let serviceFactory: ((ServerConfig) -> ChannelSidebarServing)?

    private var models: [UUID: ChannelListViewModel] = [:]

    /// What the channel list for one server thinks it is doing.
    ///
    /// The native shell showed a permanent "Loading channels..." with no way to see why: the pane had
    /// no page to inspect (the webview is not there) and no log line said which team it was loading or
    /// what it had. This is the state the pane is actually drawing from — the `-shellSnapshot` seam
    /// prints it, so a stuck list is a measurement rather than a guess.
    func diagnosticSummary(for server: ServerConfig) -> String {
        guard let model = models[server.id] else { return "no-model" }
        let channelCount = model.groups.reduce(0) { $0 + $1.entries.count }
        return "team=\(model.teamID ?? "nil") phase=\(String(describing: model.phase)) stage=\(model.diagnosticStage) service=\(SidebarLoadTrace.step) groups=\(model.groups.count) channels=\(channelCount) err=\(model.actionError ?? "-") launch=\(lastLaunchDecision ?? "-")"
    }
    private var pendingRefresh: [UUID: Task<Void, Never>] = [:]
    private var refreshTokens: [UUID: UUID] = [:]
    /// Servers whose pending debounce must be a **full reload** instead of a counter refresh (a
    /// `channel_created` arrived: the channel list itself changed).
    private var pendingReload: Set<UUID> = []
    private var locationSink: AnyCancellable?
    /// The shell's per-channel "this record changed" revisions (t_c407645a). The conversion flow bumps
    /// one when its write lands; the socket echo of that write is suppressed, so this is what keeps
    /// the row from staying a group message.
    private var revisionSink: AnyCancellable?
    /// The revision counts already handled — `@Published` replays the current value on subscribe, and
    /// the sink must not refresh the list for a change it has always known about.
    private var seenChannelRevisions: [String: Int] = [:]
    /// One per list: the "the list has arrived, decide where to open" hook.
    private var launchSinks = Set<AnyCancellable>()
    /// The team each server's list was last asked for, so a location change that only moved the
    /// selected channel does not reload anything.
    private var loadedTeams: [UUID: String] = [:]

    // Observable evidence for tests and diagnostics.
    /// What the launch-destination step decided (diagnostics: the shell's dump prints it).
    private(set) var lastLaunchDecision: String?
    private(set) var counterRefreshCount = 0
    private(set) var reloadCount = 0
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
        revisionSink?.cancel()
        seenChannelRevisions = navigation.channelRevisions
        revisionSink = navigation.$channelRevisions
            .sink { [weak self] revisions in
                self?.applyChannelRevisions(revisions)
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
            service = SessionChannelSidebarService(profiles: UserProfileCache.shared(for: server.id)) { [weak self] in
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
        // The list can still be empty on the first pass — the sidebar is mounted before the team and
        // the session settle — and a launch destination computed against an empty list is no
        // destination at all. Decide once more when the list actually arrives (event-driven: polling
        // here kept the whole suite waiting on a timer).
        // `groups`, not `phase`: the model sets `phase = .loaded` a statement before it rebuilds the
        // groups, so a phase sink sees an empty list and decides "nothing to open" (measured: it did,
        // twice). The groups arriving is the fact this needs.
        model.$groups
            .sink { [weak self, weak model] groups in
                guard !groups.isEmpty, let self, let model else { return }
                // The arriving value, not `model.groups`: Combine publishes `@Published` in
                // **willSet**, so re-reading the model here hands the decide the *previous* list
                // (measured in `docs/t95a-gone-channel-build-note.md` §2 — that stale read is what
                // opened a channel the reader had left). The sink is the one caller that has the
                // new value in hand.
                self.applyLaunchDestinationIfNeeded(for: server, model: model, groups: groups)
            }
            .store(in: &launchSinks)
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
        applyLaunchDestinationIfNeeded(for: server, model: model, groups: model.groups)
    }

    /// Open what the shell should show when it starts with nowhere to go: the conversation the reader
    /// was last in, else the team's town hall, else the team's first ordinary channel.
    ///
    /// The product owner's requirement (2026-10-27): "launch into last opened channel, or default to
    /// town hall" — see `LaunchDestination` for the chain and for what survives from T95-A.
    ///
    /// Only when the shell has no destination of its own — a deep link, a tapped mention or a restored
    /// route always wins over a remembered channel. A saved channel that is no longer in the list
    /// (left, archived, deleted) falls through to the town hall rather than opening something that
    /// will error.
    ///
    /// - Parameter groups: the list to decide against. The `$groups` sink passes the value it was
    ///   handed (a `@Published` read inside the sink is still the previous publish); every other
    ///   caller passes `model.groups`.
    private func applyLaunchDestinationIfNeeded(for server: ServerConfig,
                                                model: ChannelListViewModel,
                                                groups: [ChannelSidebarGroup]) {
        guard let navigation else {
            lastLaunchDecision = "no-navigation"
            return
        }
        let location = navigation.location
        guard !location.opensADestination else { return }
        if let current = location.serverID, current != server.id { return }
        guard let teamID = model.teamID ?? location.teamID else { return }

        let entries = groups.flatMap(\.entries)
        let available = Set(entries.map(\.id))
        let townHallRow = entries.first { entry in
            LaunchDestination.townHallNames.contains(entry.name.lowercased())
        }
        let ordinaryRow = entries.first { !$0.kind.isDirect && $0.id != townHallRow?.id }
        let townHall = townHallRow.map { LaunchDestination.Candidate(id: $0.id, name: $0.name) }
        let fallback = ordinaryRow.map { LaunchDestination.Candidate(id: $0.id, name: $0.name) }
        lastLaunchDecision = "entries=\(entries.count) saved=\(navigation.savedChannel(for: server.id)?.channelID ?? "-") townhall=\(townHall?.id ?? "-") fallback=\(fallback?.id ?? "-")"
        guard let resolution = LaunchDestination.resolve(saved: navigation.savedChannel(for: server.id),
                                                         available: available,
                                                         townHall: townHall,
                                                         fallback: fallback,
                                                         serverID: server.id,
                                                         teamID: teamID,
                                                         teamName: location.teamName) else {
            // Nothing saved and nothing to fall back to (the list has not loaded, or the team has no
            // channels yet): the list is the destination. Recorded so a diagnostic can tell "decided
            // none" from "never decided".
            lastLaunchDecision? += " -> none"
            return
        }
        let outcome = navigation.openChannel(resolution.request)
        lastLaunchDecision? += " -> \(resolution.origin.label) -> \(outcome)"
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
        pendingReload.remove(serverID)
        refreshTokens[serverID] = nil
        models[serverID] = nil
        loadedTeams[serverID] = nil
        // The profiles this server taught the shell are not reused by whoever signs in next.
        UserProfileCache.forget(serverID: serverID)
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
        case .applied, .layoutChanged:
            // The event carried the new state (the server's exact counters, or the layout it stored),
            // so it is already on screen. Fetching it again would be a request with nothing to learn.
            return
        case .counters, .refreshNeeded:
            scheduleRefresh(serverID: serverID)
        case .reloadNeeded:
            scheduleRefresh(serverID: serverID, reload: true)
        }
    }

    /// Test/diagnostic surface: how many models this coordinator holds (one per active server).
    var modelCount: Int { models.count }

    /// The shell reported that a channel's **record** changed outside its pane
    /// (`NativeNavigation.channelDidChange`).
    ///
    /// t_c407645a: the conversion flow calls it when its write lands, and the socket's echo of that
    /// same write is deliberately suppressed (upstream ignores it too — the flow already applied the
    /// record). So this is the half that keeps the list honest for the app's **own** conversion: the
    /// same debounced refresh the event would have scheduled reads `/users/me/teams/{t}/channels`,
    /// which is where the row's type, name and team come from.
    ///
    /// One refresh per server, not per channel key: the refresh is a whole-list read anyway.
    private func applyChannelRevisions(_ revisions: [String: Int]) {
        defer { seenChannelRevisions = revisions }
        var changed: Set<UUID> = []
        for (key, count) in revisions where seenChannelRevisions[key] != count {
            // Keyed `"<server uuid>/<channel id>"` (see `NativeNavigation.channelDidChange`).
            guard let raw = key.split(separator: "/").first,
                  let serverID = UUID(uuidString: String(raw)) else { continue }
            changed.insert(serverID)
        }
        for serverID in changed where models[serverID] != nil {
            scheduleRefresh(serverID: serverID)
        }
    }

    /// The list for a server **if it has been created**, without creating one.
    ///
    /// t_e9550303: a landed read must not bring a sidebar into existence (a model built here would
    /// have no data, and clearing it would be clearing nothing). The read path uses this.
    func loadedModel(for serverID: UUID) -> ChannelListViewModel? { models[serverID] }

    /// A pane read this channel: clear its row now and report what the clear removed.
    ///
    /// The caller (`ChannelPaneCoordinator.onChannelRead` → `MattermostApp.bindShellStores`) uses the
    /// returned numbers for the badge, so the row, the group dot and the badge move from one update.
    @discardableResult
    func applyRead(serverID: UUID, channelID: String, cursors: [String: Int64]) -> ChannelReadOutcome {
        models[serverID]?.applyRead(channelID: channelID, cursors: cursors) ?? ChannelReadOutcome()
    }

    func loadedTeam(for serverID: UUID) -> String? { loadedTeams[serverID] }

    // MARK: Location → models

    /// The location moved. When the shell still has no destination, this is also the moment to try the
    /// launch destination again: the team arrives asynchronously (the rail picks it), so the first
    /// attempt after the list loads can legitimately find no team yet and must not be the last word.
    private func apply(_ location: NativeLocation) {
        defer {
            if !location.opensADestination, let serverStore,
               let server = serverStore.servers.first(where: { $0.id == location.serverID }) {
                let model = model(for: server)
                applyLaunchDestinationIfNeeded(for: server, model: model, groups: model.groups)
            }
        }
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

    private func scheduleRefresh(serverID: UUID, reload: Bool = false) {
        // A pending debounce absorbs this event. A reload is the stronger request: if it is watering
        // down into a counter refresh, upgrade the pending one rather than queueing a second task.
        if reload { pendingReload.insert(serverID) }
        guard pendingRefresh[serverID] == nil else { return }
        let token = UUID()
        refreshTokens[serverID] = token
        pendingRefresh[serverID] = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(max(0, self.refreshDelay) * 1_000_000_000))
            guard !Task.isCancelled, self.refreshTokens[serverID] == token else { return }
            self.pendingRefresh[serverID] = nil
            guard let model = self.models[serverID] else { return }
            if self.pendingReload.remove(serverID) != nil {
                // The channel list changed (a channel was created): counters alone cannot show a new
                // row, and a new channel may carry a DM label the load resolves.
                self.reloadCount += 1
                await model.reload()
            } else {
                self.counterRefreshCount += 1
                await model.refreshCounters()
            }
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
    /// The team this server's list is showing, when one has resolved. `nil` before the list knows —
    /// e.g. before the first load, or while the reader has no team selected.
    func currentTeamID(serverID: UUID) -> String? {
        guard let teamID = models[serverID]?.teamID, !teamID.isEmpty else { return nil }
        return teamID
    }

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

    /// Whether the loaded list **knows** the account is in `channelID` — no request (t_14c96dfd).
    ///
    /// A row in the list is a `.member`: the list a sidebar shows **is** the account's channels
    /// (`GET /users/me/teams/{id}/channels`), so a channel in it is one the reader is in, and that is the
    /// whole happy path of a tap — no request at all.
    ///
    /// Its *absence* is `.unknown`, never `.notMember`, because the sidebar deliberately hides archived
    /// channels (upstream `filterArchivedChannels`, `ChannelSidebarModels`). A member of an archived
    /// channel is therefore absent from it, and a tap that trusted absence would tell that reader they
    /// are "not a member" of a channel they can still read — while the pane has a composer banner for
    /// exactly that state. So absence defers to the server, which answers the one question this list
    /// cannot: is the channel still there, and am I still in it.
    func membership(serverID: UUID, channelID: String, teamID: String?) -> NotificationChannelMembership {
        guard !channelID.isEmpty, let model = models[serverID] else { return .unknown }
        return model.entry(id: channelID) != nil ? .member : .unknown
    }
}
