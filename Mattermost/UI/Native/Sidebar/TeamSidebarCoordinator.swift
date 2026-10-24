// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/actions/remote/team.ts `handleTeamChange` (idempotent switch: current team changes, the
//        current channel is cleared, a switching flag brackets the work), app/client/websocket/
//        index.ts + app/actions/websocket/*.ts (one socket per server; handlers scoped to the
//        selected team), app/screens/home/channel_list/channel_list.tsx (the team rail is mounted
//        inside the channel list, so the rail and the channel list share one lifetime).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §3; no
// upstream source copied. The decomposition (a coordinator owning one model + one connection per
// server) is this repo's own (docs/component-map.md §1).

import Combine
import Foundation

/// What a tap on a team icon did.
enum TeamSelectionOutcome: Equatable {
    /// The tapped team is already the current one: upstream returns before touching anything.
    case alreadyCurrent
    case switched(teamID: String, teamName: String)
    /// The server's session is gone; the shell is showing re-auth (not this rail's business).
    case needsReauth
    /// The switch could not be applied, with the reason the rail shows.
    case unavailable(String)
}

// MARK: - The socket seam

/// The one socket per server, as a seam.
///
/// Production wraps `SocketClient` (T28, already tested); tests script the events. The seam exists
/// because the property this card has to prove — *one* subscription per server, whose team scope
/// follows the switch, with no duplicates after rapid switching — is a property of this coordinator,
/// not of `URLSessionWebSocketTask`.
@MainActor
protocol TeamEventSourcing: AnyObject {
    /// The server's event stream, connecting on first use. The returned stream is one subscriber on
    /// the single connection; calling again must not open a second one.
    func events(for server: ServerConfig, token: String) async -> AsyncStream<SocketEvent>?
    func close(serverID: UUID) async
    /// Test-observable: how many live connections this source holds.
    var openConnectionCount: Int { get }
}

/// Production source: `SocketClient` per server, with the shared `CertTrust` the webview uses (so a
/// self-signed server that was trusted in the webview does not prompt twice).
@MainActor
final class SocketTeamEventSource: TeamEventSourcing {
    private var clients: [UUID: SocketClient] = [:]
    private let certTrust: CertTrust
    private let onUntrustedCertificate: ((CertificatePrompt) -> Void)?

    init(certTrust: CertTrust = CertTrust(),
         onUntrustedCertificate: ((CertificatePrompt) -> Void)? = nil) {
        self.certTrust = certTrust
        self.onUntrustedCertificate = onUntrustedCertificate
    }

    var openConnectionCount: Int { clients.count }

    func events(for server: ServerConfig, token: String) async -> AsyncStream<SocketEvent>? {
        if let existing = clients[server.id] { return await existing.subscribe() }
        guard let base = MMBaseURL(server.url), let url = base.websocket() else { return nil }
        let configuration = SocketClient.Configuration(url: url,
                                                       token: token,
                                                       origin: base.origin)
        let certTrust = self.certTrust
        let onUntrustedCertificate = self.onUntrustedCertificate
        let client = SocketClient(
            configuration: configuration,
            transportFactory: { url, headers in
                WebSocketTransport(url: url,
                                   headers: headers,
                                   serverURL: server.url,
                                   certTrust: certTrust,
                                   onUntrustedCertificate: onUntrustedCertificate)
            })
        clients[server.id] = client
        await client.start()
        return await client.subscribe()
    }

    func close(serverID: UUID) async {
        guard let client = clients.removeValue(forKey: serverID) else { return }
        await client.stop()
    }
}

// MARK: - The coordinator

/// The app-level owner of the team rail: **one model and one socket per server**.
///
/// ## Why one owner rather than `@StateObject` in the rail
///
/// The rail is a `View` inside the sidebar pane, and SwiftUI re-creates views freely — a tab switch,
/// a size-class change, the compact/regular layout swap in `NativeShellView`. If the view owned the
/// model, every re-mount would restart the load and (worse) open a second WebSocket for the same
/// server. So the model and the connection are owned here, keyed by server id, exactly like
/// `AuthCoordinator` owns one `AuthSession` per server.
///
/// ## The single source of truth for "which team is current"
///
/// Nothing here stores a selection. The current team lives in `NativeNavigation.location` — the one
/// value a rail tap, a deep link and a notification tap all write — and this object *subscribes* to
/// it: every location change re-seeds each server's model (`setSelection`) and replaces that
/// server's `TeamSocketScope`. That is what makes "the rail highlights the team the deep link
/// opened" true without a second code path, and what makes "the socket scope follows the switch"
/// true without a second switch implementation.
@MainActor
final class TeamSidebarCoordinator: ObservableObject {

    weak var auth: AuthCoordinator?
    weak var navigation: NativeNavigation?
    weak var serverStore: ServerStore?

    /// The seam the channel view (T34) and the thread pane (T36) consume: events that belong to the
    /// team that is on screen, delivered after they passed the current scope.
    var onTeamEvent: ((UUID, SocketEvent) -> Void)?

    private let events: TeamEventSourcing
    /// How long post activity is coalesced before the counters are refetched. A burst of ten posts
    /// is one request, not ten (the unread endpoint is cheap, but it is still the server).
    private let unreadRefreshDelay: TimeInterval
    /// Seams. Production uses `SessionTeamSidebarService` (the server's own `AuthSession.client`) and
    /// the live session's token; a test supplies a fake server and a fixed token so the coordinator's
    /// own rules — one subscription, scope follows the switch, counters refresh on activity — are
    /// exercised without a network, a vault or a handshake.
    private let serviceFactory: ((ServerConfig) -> TeamSidebarServing)?
    private let tokenOverride: ((ServerConfig) -> String?)?

    private var models: [UUID: TeamSwitchViewModel] = [:]
    /// server id → the one pump task reading that server's socket.
    private var pumps: [UUID: Task<Void, Never>] = [:]
    /// Guards against a finished pump clearing a newer one (a reconnect raced by a sign-out).
    private var pumpTokens: [UUID: UUID] = [:]
    private var scopes: [UUID: TeamSocketScope] = [:]
    private var pendingUnreadRefresh: [UUID: Task<Void, Never>] = [:]
    private var locationSink: AnyCancellable?

    // Observable evidence for tests and diagnostics.
    private(set) var deliveredEventCount = 0
    private(set) var refusedEventCount = 0
    private(set) var scopeSwitchCount = 0

    init(events: TeamEventSourcing? = nil,
         unreadRefreshDelay: TimeInterval = 1.5,
         makeService: ((ServerConfig) -> TeamSidebarServing)? = nil,
         tokenProvider: ((ServerConfig) -> String?)? = nil) {
        // Built here, not as a default argument: a default argument is evaluated in a nonisolated
        // context, and `SocketTeamEventSource` is main-actor isolated like the rest of the shell.
        self.events = events ?? SocketTeamEventSource()
        self.unreadRefreshDelay = unreadRefreshDelay
        self.tokenOverride = tokenProvider
        self.serviceFactory = makeService
    }

    // MARK: Wiring

    /// Bind the shell objects this coordinator reads. Idempotent — `bindShellStores()` may run more
    /// than once (the app's `.task` and `onOpenURL`).
    func bind(auth: AuthCoordinator,
              navigation: NativeNavigation,
              serverStore: ServerStore?) {
        self.auth = auth
        self.navigation = navigation
        self.serverStore = serverStore
        locationSink?.cancel()
        // Deliberately synchronous: the rail's selection and the socket scope must have moved by the
        // time `select(_:on:)` returns, so a tap cannot be observed mid-switch by the next event.
        locationSink = navigation.$location
            .sink { [weak self] location in
                self?.apply(location)
            }
        apply(navigation.location)
    }

    /// The rail's model for one server (created on first use and kept for the app's lifetime).
    func model(for server: ServerConfig) -> TeamSwitchViewModel {
        if let existing = models[server.id] { return existing }
        let service: TeamSidebarServing
        if let serviceFactory {
            service = serviceFactory(server)
        } else {
            service = SessionTeamSidebarService { [weak self] in
                guard let self, let auth = self.auth,
                      let session = try? auth.session(for: server) else { return nil }
                return (session.client, auth.userID(for: server.id))
            }
        }
        let model = TeamSwitchViewModel(
            server: server,
            service: service,
            userID: { [weak self] in self?.auth?.userID(for: server.id) }
        )
        models[server.id] = model
        return model
    }

    /// The appearance pass: load the rail (once) and make sure the server's one socket is running.
    func activate(_ server: ServerConfig) async {
        let model = model(for: server)
        if let location = navigation?.location, location.serverID == server.id {
            model.setSelection(teamID: location.teamID, teamName: location.teamName)
        }
        await model.load(ifNeeded: true)
        applyDefaultTeamIfNeeded(for: server, model: model)
        connectSocketIfPossible(for: server)
    }

    /// A rail tap. Everything the switch has to change — the location's team, the channel it drops,
    /// the push stack, the socket scope — is changed by the navigation funnel, so the tap cannot
    /// leave a second, divergent copy of "current team" behind.
    @discardableResult
    func select(_ entry: TeamSidebarEntry, on server: ServerConfig) -> TeamSelectionOutcome {
        guard let navigation else {
            return .unavailable("The shell is not bound to a navigation model yet.")
        }
        let location = navigation.location
        if location.serverID == server.id {
            let sameByID = location.teamID == entry.id
            let sameByName = location.teamID == nil && location.teamName == entry.name
            if sameByID || sameByName { return .alreadyCurrent }
        }

        let outcome = navigation.openChannel(
            NativeChannelRequest(serverID: server.id, teamID: entry.id, teamName: entry.name))
        switch outcome {
        case .opened(let applied):
            // The funnel wrote one location; read it back rather than trusting the request, so a
            // refused/redirected route reports honestly instead of the rail pretending it switched.
            guard applied.teamID == entry.id else {
                return .unavailable("The shell did not switch to that team.")
            }
            return .switched(teamID: entry.id, teamName: entry.name)
        case .needsAuth:
            return .needsReauth
        case .needsServerAdd:
            return .unavailable("This server is no longer configured on this device.")
        case .unsupported(let reason):
            return .unavailable(reason)
        }
    }

    /// Sign-out / expiry / server removal: stop the socket and forget the server's rail.
    ///
    /// The `AuthCoordinator` phase is the trigger (it is the one place a session's death is decided),
    /// so a rail can never outlive the credential it was built with.
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

    func deactivate(_ serverID: UUID) async {
        pendingUnreadRefresh[serverID]?.cancel()
        pendingUnreadRefresh[serverID] = nil
        pumpTokens[serverID] = nil
        pumps[serverID]?.cancel()
        pumps[serverID] = nil
        scopes[serverID] = nil
        models[serverID] = nil
        await events.close(serverID: serverID)
    }

    // MARK: Test/diagnostic surface

    /// How many live socket pumps this coordinator holds. Must be 0 or 1 per server, whatever the
    /// user does to the rail.
    var subscriptionCount: Int { pumps.count }

    func scope(for serverID: UUID) -> TeamSocketScope? { scopes[serverID] }

    /// Give the server's scope the channel→team map the channel list knows (S08/T33).
    ///
    /// `TeamSocketScope.channelTeams` was reserved for exactly this: without it, with a team selected,
    /// every event for a channel that is not the *open* channel is refused, so a sidebar could never
    /// learn that another channel of the team just became unread. Called by
    /// `ChannelSidebarCoordinator` after each load/refresh; an empty map clears it (sign-out).
    func setChannelTeams(_ channelTeams: [String: String], for serverID: UUID) {
        var scope = scopes[serverID] ?? TeamSocketScope()
        guard scope.channelTeams != channelTeams else { return }
        scope.channelTeams = channelTeams
        scopes[serverID] = scope
    }

    // MARK: Location → model + scope

    private func apply(_ location: NativeLocation) {
        guard let serverID = location.serverID else { return }
        let previous = scopes[serverID]
        models[serverID]?.setSelection(teamID: location.teamID, teamName: location.teamName)
        var scope = previous ?? TeamSocketScope()
        var teamID = location.teamID
        if teamID == nil, let name = location.teamName, !name.isEmpty {
            // A deep link carries a name, not an id. Adopt the id from the rail as soon as the team
            // list knows it, so the scope compares ids like everything else.
            teamID = models[serverID]?.entries.first(where: { $0.name == name })?.id
        }
        scope.teamID = teamID
        scope.activeChannelID = location.channelID
        scopes[serverID] = scope
        if previous?.teamID != scope.teamID || previous?.activeChannelID != scope.activeChannelID {
            scopeSwitchCount += 1
        }
    }

    /// With no team in the location, the first team of the rail becomes current — upstream's
    /// behaviour when no team is stored (`handleTeamChange` selects a team; the rail's first ordered
    /// team is what a fresh client shows). Never applied over a destination a link/notification
    /// opened, and never over a team the user already chose.
    private func applyDefaultTeamIfNeeded(for server: ServerConfig, model: TeamSwitchViewModel) {
        guard let navigation, let first = model.entries.first else { return }
        let location = navigation.location
        guard !location.opensADestination else { return }
        if location.serverID == server.id,
           location.teamID != nil || location.teamName != nil {
            return
        }
        // A different server is on screen: selecting this one's team would switch the shell away
        // from what the user is looking at. The next appearance activates this server properly.
        if let current = location.serverID, current != server.id { return }
        _ = navigation.openChannel(
            NativeChannelRequest(serverID: server.id, teamID: first.id, teamName: first.name))
    }

    private func reloadIfActive(_ serverID: UUID) async {
        guard let server = serverStore?.servers.first(where: { $0.id == serverID }) else { return }
        await activate(server)
    }

    // MARK: The socket

    private func connectSocketIfPossible(for server: ServerConfig) {
        guard pumps[server.id] == nil else { return }
        let token = tokenOverride?(server) ?? (try? auth?.session(for: server))?.currentToken
        guard let token, !token.isEmpty else {
            // No credential yet (unresolved restore, or a UI-test gate with no session): the rail is
            // still correct on load, it just will not update itself until the next activation.
            return
        }
        let tokenID = UUID()
        pumpTokens[server.id] = tokenID
        let source = events
        pumps[server.id] = Task { [weak self] in
            guard let stream = await source.events(for: server, token: token) else { return }
            for await event in stream {
                guard let self else { return }
                await self.handle(event, serverID: server.id)
            }
            self?.pumpFinished(serverID: server.id, token: tokenID)
        }
    }

    private func pumpFinished(serverID: UUID, token: UUID) {
        guard pumpTokens[serverID] == token else { return }
        pumpTokens[serverID] = nil
        pumps[serverID] = nil
    }

    private func handle(_ event: SocketEvent, serverID: UUID) async {
        switch event {
        case .posted, .postEdited, .postDeleted, .channelViewed:
            // Any of these can change a team's counters — for *any* team, since the socket is
            // server-scoped. The counters are refetched rather than incremented locally because the
            // server owns the arithmetic (and a local increment would drift after a reconnect).
            scheduleUnreadRefresh(serverID: serverID)
        default:
            break
        }

        let scope = scopes[serverID] ?? TeamSocketScope()
        if scope.accepts(event) {
            deliveredEventCount += 1
            onTeamEvent?(serverID, event)
        } else {
            refusedEventCount += 1
        }
    }

    private func scheduleUnreadRefresh(serverID: UUID) {
        guard pendingUnreadRefresh[serverID] == nil else { return }
        pendingUnreadRefresh[serverID] = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(max(0, self.unreadRefreshDelay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.pendingUnreadRefresh[serverID] = nil
            await self.models[serverID]?.refreshUnreads()
        }
    }
}
