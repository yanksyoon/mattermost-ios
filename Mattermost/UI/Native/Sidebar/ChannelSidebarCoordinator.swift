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
    /// One per list: the "the list has arrived, decide where to open" hook.
    private var launchSinks = Set<AnyCancellable>()
    /// The team each server's list was last asked for, so a location change that only moved the
    /// selected channel does not reload anything.
    private var loadedTeams: [UUID: String] = [:]
    /// Servers whose saved record's **team** has already been asked for on this launch. The ask is a
    /// list load, not a decision: once per launch is enough, and asking again would be a loop between
    /// the decide and the location sink it causes (see `applyLaunchDestinationIfNeeded`).
    private var askedForSavedTeam: Set<UUID> = []
    /// Servers whose launch destination has already been **decided** against a loaded directory
    /// (opened, or "nothing to open"). See `applyLaunchDestinationIfNeeded`: a launch decision is a
    /// launch decision, and re-running it on every location write is what pushes the just-saved
    /// channel back over the list when the reader taps Back.
    private var launchDecisionSettled: Set<UUID> = []

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
        // The list can still be empty on the first pass — the sidebar is mounted before the team and
        // the session settle — and a launch destination computed against an empty list is no
        // destination at all. Decide once more when the list actually arrives (event-driven: polling
        // here kept the whole suite waiting on a timer).
        // `groups`, not `phase`: the model sets `phase = .loaded` a statement before it rebuilds the
        // groups, so a phase sink sees an empty list and decides "nothing to open" (measured: it did,
        // twice). The groups arriving is the fact this needs.
        //
        // `sink` fires in the **willSet** of `@Published`, so inside this closure `model.groups` is
        // still the *previous* value; the value being published is the parameter. The decide is handed
        // that parameter (`arrivingEntries:`), never `model.groups` — measured (T95-A-AV-R, card
        // `t_fcbd5cc8`): the directory-arrival decide read `sink groups=2 modelGroups=0`, i.e. it was
        // one publish behind, and on that read it opened the channel the reader had left.
        model.$groups
            .sink { [weak self, weak model] groups in
                guard !groups.isEmpty, let self, let model else { return }
                self.applyLaunchDestinationIfNeeded(for: server,
                                                    model: model,
                                                    arrivingEntries: groups.flatMap(\.entries))
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
        applyLaunchDestinationIfNeeded(for: server, model: model)
    }

    /// Open what the shell should show when it starts with nowhere to go: the conversation the reader
    /// was last in — and nothing else.
    ///
    /// Only when the shell has no destination of its own — a deep link, a tapped mention or a restored
    /// route always wins over a remembered channel. A saved channel that is no longer in the list
    /// (left, archived, deleted) opens nothing rather than something that will error, and a launch
    /// with nothing saved stays on the channel list. Upstream's cold start does the same: last thread,
    /// else last channel, else `HOME` (`app/init/launch.ts:245-262`, `:290-294`) — there is no
    /// town-hall fallback to reproduce (`docs/t95-shell-tab-bar-decision.md` §3).
    ///
    /// ## The rule: the directory is the judge, and an unarrived directory is not an empty one
    ///
    /// (Repair for card `t_e0cef465`, measured on `t_fcbd5cc8` /
    /// `docs/t95a-gone-channel-build-note.md`.) `LaunchDestination.request(saved:available:)` reads
    /// `available.isEmpty` as "the list is not known yet — trust the saved record, the pane is the
    /// judge". That reading is only safe when something else has already established that the saved
    /// channel exists. At launch nothing has: `activate` and the location-change `defer` both called
    /// this decide **before the first load returned** (`groups=0 phase=idle`, measured) and handed the
    /// request function an empty `available`, which it is contractually right to trust — and the shell
    /// opened a channel the account had already left (`launch=entries=0 saved=dqjbyw37… -> opened(…)`,
    /// in the same diagnostics line that reports `channels=42` for the sidebar).
    ///
    /// So the decide answers **nothing** while the directory has not arrived, and is re-run when it
    /// does: the `$groups` sink (with the arriving value, see `model(for:)`) and `activate` after its
    /// own load. Two consequences, both deliberate:
    ///
    ///  * `available` is never empty when `LaunchDestination.request` sees it, so its
    ///    "not loaded yet, trust the record" branch is unreachable from this coordinator — the
    ///    function's contract and its unit tests are untouched, and they should be: the function was
    ///    right, the value and the moment were wrong.
    ///  * an **offline** launch (the load never returns) now lands on the channel list instead of
    ///    restoring a channel it cannot verify. That is the honest direction: a false "gone" costs one
    ///    tap on a row that is on screen, a false "open" strands the reader in a conversation they are
    ///    not a member of, and behind it the pane's own error surface.
    ///
    /// The alternative the card allowed — let a later decide correct an earlier open — was not taken.
    /// It still writes a location the reader never asked for, and whether that location is *rendered*
    /// depends on mount order: under mutant M1 (sink fix only, `docs/t95a-gone-channel-build-note.md`
    /// §2) the coordinator still applied `openChannel` for the gone channel on every run and the pane
    /// merely failed to appear, for a reason this repo has not measured. Not opening is a fact the
    /// shell can hold; un-opening is a race.
    ///
    /// ## Which directory judges the record: the record's own team's
    ///
    /// The sidebar holds **one team at a time**, and the team the shell lands on first is the rail's
    /// first — sorted by the `teams_order` preference, else by display name (`TeamSidebarDerivation`),
    /// which need not be the team the reader was in. Measured on the fixture while repairing this
    /// (2026-10-28): the relaunch loaded `team=ops` with 8 rows while the saved record named a channel
    /// of `perf` (42), so "not in `available`" said *nothing* about the channel — it only said the
    /// wrong list was on screen, and a saved channel that is still there would have been refused with
    /// it. So before judging, the decide asks the shell for the record's team **once**; the location
    /// change reloads the list (`apply(_:)` → `load(serverID:model:teamID:)`) and this decide runs
    /// again with that team's rows. Upstream restores team and channel together for the same reason
    /// (`app/init/launch.ts:245-262`), and the reader lands on their own team's list even when the
    /// channel is gone, instead of on whichever team sorted first.
    ///
    /// - Parameter arrivingEntries: the rows the publisher is delivering, when this decide is running
    ///   from the `$groups` sink (inside which `model.groups` is still the previous value). `nil` means
    ///   "read the model" — correct after an `await` on the load (`activate`), wrong inside `sink`.
    private func applyLaunchDestinationIfNeeded(for server: ServerConfig,
                                               model: ChannelListViewModel,
                                               arrivingEntries: [ChannelSidebarEntry]? = nil) {
        guard let navigation else {
            lastLaunchDecision = "no-navigation"
            return
        }
        let location = navigation.location
        guard !location.opensADestination else { return }
        if let current = location.serverID, current != server.id { return }

        let saved = navigation.savedChannel(for: server.id)
        let savedID = saved?.channelID ?? saved?.channelName ?? "-"

        // A launch decision is a **launch** decision. Once this server's has been answered against a
        // loaded directory, later location writes must not answer it again: a row tap saves the
        // channel, the reader's Back writes the root location, the decide ran a second time and
        // pushed the just-saved channel back over the list. Measured on the compact-layout parity
        // suite (`T95ShellLayoutUITests` `:194`, red on `origin/main` too — 3/3 runs, the pane left in
        // the hierarchy offscreen while the tab bar was on screen) and it is the same "a later decide
        // re-applies an open" fragility that mutant M1 left behind
        // (`docs/t95a-gone-channel-build-note.md` §2). Deferrals ("directory not arrived") are not
        // decisions: the retry this method exists for stays available until it can be answered.
        guard !launchDecisionSettled.contains(server.id) else { return }

        // The record's team, when the sidebar is not on it yet (or has no team at all). Asked once per
        // server per launch: the answer is a list load, and asking again on every decide is a loop.
        if let savedTeam = saved?.teamID, model.teamID != savedTeam,
           !askedForSavedTeam.contains(server.id) {
            askedForSavedTeam.insert(server.id)
            let entryCount = arrivingEntries?.count ?? model.groups.flatMap(\.entries).count
            lastLaunchDecision = "entries=\(entryCount) saved=\(savedID) -> loading the saved team \(savedTeam) first"
            _ = navigation.openChannel(NativeChannelRequest(serverID: server.id,
                                                           teamID: savedTeam,
                                                           teamName: saved?.teamName))
            return
        }

        guard let teamID = model.teamID ?? location.teamID else { return }

        // The rows and the team have to be the same team's before anything is judged:
        // `setSelection` re-derives `groups` from the **previous** team's data until the new team's
        // load returns, and `phase` stays `.loaded` across that change, so non-empty rows can still be
        // another team's list (measured while repairing: `team=ops channels=8` on screen while the
        // record named a `perf` channel). `loadedTeamID == teamID` is the one signal that says "this
        // team's directory is what is on screen" — true for the `$groups` sink too, which fires after
        // the model has recorded the team it just loaded.
        guard model.teamID != nil, model.loadedTeamID == model.teamID else {
            lastLaunchDecision = "saved=\(savedID) -> deferred (this team's rows have not arrived)"
            return
        }

        let entries = arrivingEntries ?? model.groups.flatMap(\.entries)
        guard !entries.isEmpty else {
            // Nothing to judge the saved record against. A loaded, genuinely empty directory is a
            // decision ("none"); anything else is "not yet" and is re-decided when it arrives.
            if model.phase == .loaded { launchDecisionSettled.insert(server.id) }
            lastLaunchDecision = model.phase == .loaded
                ? "entries=0 phase=loaded saved=\(savedID) -> none"
                : "entries=0 phase=\(String(describing: model.phase)) saved=\(savedID) -> deferred (directory not arrived)"
            return
        }

        let available = Set(entries.map(\.id))
        launchDecisionSettled.insert(server.id)
        lastLaunchDecision = "entries=\(entries.count) saved=\(savedID)"
        guard let request = LaunchDestination.request(saved: saved,
                                                     available: available,
                                                     serverID: server.id,
                                                     teamID: teamID,
                                                     teamName: location.teamName) else {
            // Nothing saved, or the saved channel is gone: the list is the destination (upstream's
            // `HOME`). Recorded so a diagnostic can tell "decided none" from "never decided".
            lastLaunchDecision? += " -> none"
            return
        }
        let outcome = navigation.openChannel(request)
        lastLaunchDecision? += " -> \(outcome)"
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
        // A new session for this server may carry a different saved record; let the next launch
        // decide ask for its team again, and decide again.
        askedForSavedTeam.remove(serverID)
        launchDecisionSettled.remove(serverID)
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

    func loadedTeam(for serverID: UUID) -> String? { loadedTeams[serverID] }

    // MARK: Location → models

    /// The location moved. When the shell still has no destination, this is also the moment to try the
    /// launch destination again: the team arrives asynchronously (the rail picks it), so the first
    /// attempt after the list loads can legitimately find no team yet and must not be the last word.
    private func apply(_ location: NativeLocation) {
        // The launch decision is over the moment a **destination reaches the screen**: a row tap, a
        // deep link, a notification tap or the decide's own open. Whatever the decide had not managed
        // to answer by then is moot — the reader has chosen, and re-answering it later is what pushed
        // the just-saved channel back over the list when they tapped Back
        // (`T95ShellLayoutUITests` `:194`, `docs/t95a-gone-channel-build-note.md` §3.1 (d)).
        if location.opensADestination, let id = location.serverID {
            launchDecisionSettled.insert(id)
        }
        defer {
            if !location.opensADestination, let serverStore,
               let server = serverStore.servers.first(where: { $0.id == location.serverID }) {
                applyLaunchDestinationIfNeeded(for: server, model: model(for: server))
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
