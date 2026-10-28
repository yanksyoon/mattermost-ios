// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/utils/deep_link/index.ts (CHANNEL_PATH `*serverUrl/:teamName/:path/:identifier`,
//        PERMALINK_PATH `*serverUrl/:teamName/pl/:postId`, the `isValidId` channel-id sniff) and
//        app/screens/home/tab_bar/index.tsx (top-level tab inventory: Home channel list / Search /
//        Mentions / Saved / Account, with the channel screen pushed on top of the list).
// Licence: Apache-2.0 (upstream LICENSE.txt) — behaviour ported with attribution per
// docs/THIRD_PARTY_NOTICES.md §3. No upstream source is copied: the SwiftUI decomposition is this
// repo's own (docs/component-map.md §1).

import Foundation
import Combine

// MARK: - Where a request wants to go

/// Which pane a channel destination is shown in. The channel view and the thread pane are two
/// renderings of one channel selection, exactly as upstream's `CHANNEL` screen and the RHS/thread
/// screen share a channel.
enum NativePane: String, Hashable {
    case channel
    case threads
}

/// The shell's top-level sections (upstream `app/screens/home/tab_bar`, trimmed to the five the native
/// shell renders: the channel list/Home tab, global threads, activity/mentions, search and saved messages).
///
/// T39 added `.search` and `.saved` with their screens (S19/S20); T42 added `.activity` (S25), which is
/// upstream's `Mentions` tab — the fifth of upstream's five. Only Account (S03) remains, and it is a
/// surface of its own (the profile sheet, T41) rather than a tab in this shell.
enum NativeTab: String, Hashable, CaseIterable {
    case channels
    case threads
    case activity
    case search
    case saved

    var title: String {
        switch self {
        case .channels: return "Channels"
        case .threads: return "Threads"
        case .activity: return "Mentions"
        case .search: return "Search"
        case .saved: return "Saved"
        }
    }

    var systemImage: String {
        switch self {
        case .channels: return "bubble.left.and.bubble.right"
        case .threads: return "text.bubble"
        case .activity: return "bell.badge"
        case .search: return "magnifyingglass"
        case .saved: return "bookmark"
        }
    }
}

/// A channel destination expressed in **whatever keys the caller actually has**.
///
/// This is the union of the three entry points that have to converge on one place:
///  - a `mattermost://<server>/<team>/channels/<channelName>` deep link has a team *name* and a
///    channel *name* (or a channel *id* — upstream sniffs a 26-char id and treats the same path
///    segment as an id, see `isValidId`);
///  - a tapped mention has a `channel_id` and a `team_id` and no names;
///  - the sidebar (once S08 lands) has ids *and* names.
///
/// Resolution to a single `NativeLocation` goes through `NativeChannelDirectory`, so the facts a
/// caller lacks are filled in rather than guessed.
struct NativeChannelRequest: Equatable {
    var serverID: UUID?
    /// Host from a deep link (`mattermost://mm.example/...`), matched against `ServerStore`.
    var serverHost: String?
    var teamID: String?
    var teamName: String?
    var channelID: String?
    var channelName: String?
    /// `/pl/<postID>` or `/channels/<name>/<postID>`.
    var postID: String?

    init(serverID: UUID? = nil,
         serverHost: String? = nil,
         teamID: String? = nil,
         teamName: String? = nil,
         channelID: String? = nil,
         channelName: String? = nil,
         postID: String? = nil) {
        self.serverID = serverID
        self.serverHost = serverHost
        self.teamID = teamID
        self.teamName = teamName
        self.channelID = channelID
        self.channelName = channelName
        self.postID = postID
    }
}

/// A navigation request, as produced by path parsing or by a direct caller.
enum NativeTarget: Equatable {
    /// The server's workspace root (what the web app calls `/` once the team is chosen).
    case home(serverID: UUID?, serverHost: String?)
    case channel(NativeChannelRequest)
    case threads(NativeChannelRequest)

    /// The server this target names, if it names one explicitly.
    var requestedServer: (id: UUID?, host: String?) {
        switch self {
        case .home(let id, let host): return (id, host)
        case .channel(let r), .threads(let r): return (r.serverID, r.serverHost)
        }
    }

    /// The request body, for `.channel`/`.threads`; `nil` for `.home`.
    var channelRequest: NativeChannelRequest? {
        switch self {
        case .home: return nil
        case .channel(let r), .threads(let r): return r
        }
    }
}

/// The resolved destination: **the one value every entry point produces** and every layout renders.
///
/// It carries ids *and* names, so "the deep link landed somewhere else than the notification tap"
/// is a plain `==` on this struct rather than a behavioural comparison of two screens.
///
/// **What that equality actually proves today** (T30-AV F1, corrected in T30-R): the funnel is
/// structural — every entry point writes this struct through `apply` — but the *facts* it fills in
/// come from `NativeChannelDirectory`, and no implementation ships yet (it arrives with the channel
/// list, S08/T32-T33). With `directory == nil` a `mattermost://…/channels/general` link carries a
/// channel *name* and no team id, while a tapped mention carries a channel *id* and a team id, so
/// the two locations agree on server and pane and differ on channel/team identity. Equality here is
/// therefore a statement about the shipping configuration only once that directory is installed;
/// `NativeNavigationTests.testDeepLinkAndMentionAgreeOnServerAndPaneWithoutADirectory` pins the
/// current, weaker truth so the gap cannot quietly be re-claimed as convergence.
struct NativeLocation: Hashable {
    var serverID: UUID?
    var serverName: String?
    var teamID: String?
    var teamName: String?
    var channelID: String?
    var channelName: String?
    var postID: String?
    var pane: NativePane = .channel

    /// Whether a channel (by id or name) is selected.
    var hasChannel: Bool { channelID != nil || channelName != nil }

    /// Whether this location is a destination the shell can **show** — i.e. something worth
    /// pushing on a compact layout (or selecting in a regular layout's detail column).
    ///
    /// A channel qualifies; so does a permalink that names only a post (`/pl/<post>`, whose channel
    /// needs S12/T36 to resolve) and a threads pane. T30-AV F3: `apply` used to gate the push on
    /// `hasChannel` alone, so those two routes parsed, changed the model and left a phone on the
    /// shell root — a link that visibly did nothing, and a "Resolving this permalink…" pane that
    /// only a wide layout could ever reach.
    var opensADestination: Bool { hasChannel || postID != nil || pane == .threads }

    /// The channel's display name, preferring the human name over the id.
    var channelDisplayName: String? { channelName ?? channelID }

    /// Identity of the channel without its presentation, for "is this the same channel?" checks.
    var channelKey: String? { channelID ?? channelName }

    /// The same destination expressed as a request — used when a view hands the location back to
    /// the router (a sidebar row, the channel header's Threads button), so the round trip goes
    /// through the one funnel instead of mutating state.
    var request: NativeChannelRequest {
        NativeChannelRequest(serverID: serverID,
                             teamID: teamID,
                             teamName: teamName,
                             channelID: channelID,
                             channelName: channelName,
                             postID: postID)
    }
}

// MARK: - Resolution seams

/// What a channel reference resolves to once the shell has data for it.
struct NativeChannelIdentity: Equatable {
    var teamID: String?
    var teamName: String?
    var channelID: String?
    var channelName: String?
}

/// Fills in the facts a request lacks (name → id, id → name, post → channel).
///
/// **No implementation ships in this card.** The channel/team data arrives with S08 (T32/T33) and
/// permalink resolution with S12 (T36); until then `NativeNavigation.directory` is `nil` and a
/// request resolves to exactly the keys it carried. That is deliberate: the alternative would be
/// inventing channel names, which is how a skeleton starts lying. The seam exists so those cards
/// plug in one method instead of rewriting the router.
@MainActor
protocol NativeChannelDirectory: AnyObject {
    func identity(for request: NativeChannelRequest, serverID: UUID) -> NativeChannelIdentity?
}

/// Whether a configured server has a usable session — i.e. whether the pane should show the auth
/// surface instead of a workspace.
enum NativeAuthState: Equatable {
    case signedIn
    case signedOut
}

/// The auth seam.
///
/// The shipping implementation reads the **same** credential `AuthSession` persists
/// (`SecureVault.authToken` for that server), so "signed out" means the same thing to the shell as
/// it does to the transport. It does not construct an `AuthSession`: that object's `state` is only
/// meaningful after `restore()` (a network round trip) and login/logout is T31's card, not this
/// one's. When T31 lands, it swaps this gate for one backed by the live session and the shell does
/// not change.
@MainActor
protocol NativeAuthGate: AnyObject {
    func authState(for server: ServerConfig) -> NativeAuthState
}

/// Default gate: a stored `AuthSession` token means signed in.
@MainActor
final class VaultAuthGate: NativeAuthGate {
    private let vault: SecureVault

    init(vault: SecureVault = SecureVault()) {
        self.vault = vault
    }

    func authState(for server: ServerConfig) -> NativeAuthState {
        guard let token = vault.getSecret(key: .authToken, serverURL: server.url),
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .signedOut
        }
        return .signedIn
    }
}

#if DEBUG
/// TEST SEAM (DEBUG builds only): answers `signedIn` for every server.
///
/// Installed only by the `-uiTestAssumeSignedIn` launch argument, so a UI test can exercise the
/// shell's panes against a seeded stub server that has no real session (there is no way to make a
/// stub server issue a stored credential without a real login, which is T31's card). It substitutes
/// the gate — never the routing, the panes or the resolver — and it does not exist in a Release
/// build.
@MainActor
final class AssumedSignedInAuthGate: NativeAuthGate {
    func authState(for server: ServerConfig) -> NativeAuthState { .signedIn }
}
#endif

/// What a routing request did.
enum NativeNavigationOutcome: Equatable {
    /// The shell is now showing `location`.
    case opened(NativeLocation)
    /// The server is configured but has no session: the shell shows the auth surface for it.
    case needsAuth(NativeLocation)
    /// No configured server matches the request; the caller should offer to add one.
    case needsServerAdd(serverURL: URL?)
    /// Parsed, but this skeleton cannot route it yet (the reason names the gap).
    case unsupported(String)
}

// MARK: - The router

/// The native navigation stack's state machine — the single seam every entry point goes through.
///
/// Three callers, one funnel:
///  1. `mattermost://` deep links (`DeepLinkRouter` → `handle(_:)`),
///  2. notification taps (`NotificationWorker.routeToChannel` → `routeMention(...)`),
///  3. the shell's own taps (sidebar row → `openChannel(_:)`, a tab → `select(tab:)`).
///
/// All three produce a `NativeTarget` and land in `open(_:)`, which resolves the server, switches
/// the shell to it, resolves the channel through the directory and applies one `NativeLocation`.
/// That is what makes "the deep link, the tapped mention and the manual tap land in the same place"
/// a structural property rather than a coincidence of three code paths.
///
/// **Scope of that claim, stated precisely** (T30-AV F1): the *funnel* is structural — one writer,
/// one value, one push decision. The *identity* of the channel inside that value depends on
/// `directory`, which is `nil` in every configuration that ships until S08/T32-T33 installs one.
/// Without it the three entry points agree on server and pane but not on channel/team keys, because
/// each caller only has half of them (a link has names, a mention has ids). The tests say exactly
/// that, in two pieces: convergence with a directory (the property the shell is built for) and
/// server+pane agreement without one (the property that holds today).
///
/// Layout-agnostic on purpose: the value here is *where*, and the compact/regular layouts decide
/// *how* (a push on a phone, a detail column on a wide layout). See `NativeShellView`.
@MainActor
final class NativeNavigation: ObservableObject {

    // MARK: Wiring

    weak var serverStore: ServerStore?
    weak var viewStore: ViewStore?

    /// Bind the shell stores this model routes against.
    ///
    /// Idempotent and cheap, so the view that owns the stores can call it on every appearance
    /// instead of relying on the app's `.task` to have won the race against the first route. When
    /// that task lost, `open(_:)` answered `.unsupported("no server store is bound to the native
    /// navigation model")`, no location was ever written, and a signed-out server rendered the
    /// workspace skeleton with no auth surface at all (T31-R; reproduced on the T31 tree).
    func bind(serverStore: ServerStore, viewStore: ViewStore) {
        self.serverStore = serverStore
        self.viewStore = viewStore
    }
    /// The one render-mode decision (T26). The shell is the native branch of
    /// `SurfaceDefaults.paneHostSurface`, so routing only diverts here while that surface resolves
    /// `native`.
    private let resolver: SurfaceModeResolver?
    /// Name ⇄ id resolution; `nil` until S08/T36 supply data (see `NativeChannelDirectory`).
    var directory: NativeChannelDirectory?
    /// Where the reader last was, so the next launch can open it instead of an empty pane.
    var lastChannels: LastChannelStore?
    var authGate: NativeAuthGate = VaultAuthGate()

    // MARK: Published state

    /// What the shell is showing right now.
    @Published private(set) var location = NativeLocation()
    /// The compact **push** stack. On a regular-width layout the shell renders `location` in the
    /// detail column instead and `RootView` binds this to a constant, so a wide layout never pushes
    /// (upstream does the same: `AdditionalTabletView` swaps the detail pane, it does not navigate).
    @Published var path: [NativeLocation] = []
    /// The selected top-level tab (compact layout).
    @Published var tab: NativeTab = .channels
    /// The active server's auth state, refreshed on every navigation and on appearance.
    @Published private(set) var authState: NativeAuthState = .signedIn

    /// Per-server memory of where the user was, so switching servers and back does not lose the
    /// channel (desktop `TabManager`/`ViewManager` keep each server's view alive; this keeps the
    /// pointer to it).
    private var lastLocations: [UUID: NativeLocation] = [:]

    init(resolver: SurfaceModeResolver? = nil) {
        self.resolver = resolver
    }

    // MARK: Mode

    /// Whether deep links and notification taps should be diverted here instead of the webview's
    /// SPA router.
    ///
    /// Read by `DeepLinkRouter`/`NotificationWorker` at call time, so flipping the surface back to
    /// `web` (the escape hatch) immediately restores the web path — no stale flag.
    var acceptsNativeRouting: Bool {
        resolver?.resolvedMode(for: SurfaceDefaults.paneHostSurface) == .native
    }

    /// The conversation this server was last left in, if any.
    func savedChannel(for serverID: UUID) -> LastChannel? {
        lastChannels?.last(for: serverID)
    }

    // MARK: The funnel

    /// Resolve a target and make it the shell's location. **Every** entry point ends here.
    @discardableResult
    func open(_ target: NativeTarget) -> NativeNavigationOutcome {
        guard let serverStore else {
            return .unsupported("no server store is bound to the native navigation model")
        }
        guard let server = resolveServer(for: target, in: serverStore) else {
            return .needsServerAdd(serverURL: requestedServerURL(for: target, in: serverStore))
        }

        // Multi-server: switching is part of routing, not a side effect of it (the desktop
        // `openLinkInPrimaryTab` / `NOTIFICATION_CLICKED` paths do the same).
        serverStore.switchTo(id: server.id)
        viewStore?.setPrimary(server.id)

        let state = authGate.authState(for: server)
        authState = state

        // A signed-out server shows the auth surface, not a channel behind a sign-in wall.
        guard state == .signedIn else {
            let authLocation = NativeLocation(serverID: server.id, serverName: server.name)
            apply(authLocation)
            return .needsAuth(authLocation)
        }

        let newLocation = location(for: target, server: server)
        apply(newLocation)
        return .opened(newLocation)
    }

    /// Deep-link entry point (already parsed by `DeepLinkParsing`, which owns the URL rules).
    @discardableResult
    func handle(_ link: DeepLink) -> NativeNavigationOutcome {
        guard let target = Self.target(forPath: link.path, serverURL: link.serverURL) else {
            return .unsupported("unrecognised deep-link path \(link.path.isEmpty ? "<empty>" : link.path)")
        }
        return open(target)
    }

    /// Convenience for the shell's `onOpenURL`/app-delegate string form.
    @discardableResult
    func handle(_ raw: String) -> NativeNavigationOutcome {
        guard let link = DeepLinkParsing.parse(raw) else {
            return .unsupported("unparseable deep link")
        }
        return handle(link)
    }

    @discardableResult
    func handle(_ url: URL) -> NativeNavigationOutcome {
        guard let link = DeepLinkParsing.parse(url) else {
            return .unsupported("unparseable deep link")
        }
        return handle(link)
    }

    /// Notification-tap entry point (desktop `NOTIFICATION_CLICKED`): a mention carries ids only.
    @discardableResult
    func routeMention(serverID: UUID, channelID: String, teamID: String?, postID: String? = nil)
        -> NativeNavigationOutcome {
        open(.channel(NativeChannelRequest(serverID: serverID,
                                           teamID: teamID,
                                           channelID: channelID,
                                           postID: postID)))
    }

    // MARK: Direct (manual) navigation — the third entry point

    @discardableResult
    func openChannel(_ request: NativeChannelRequest) -> NativeNavigationOutcome {
        open(.channel(request))
    }

    @discardableResult
    func openThreads(_ request: NativeChannelRequest) -> NativeNavigationOutcome {
        open(.threads(request))
    }

    /// Close an open thread and return to the channel it was opened from.
    ///
    /// A thread is a *pane route*, not a pushed destination, so on a regular-width layout there is no
    /// navigation-stack chevron to go back with — the pane simply swaps and the user is stranded
    /// unless they re-tap the channel. This is that back affordance: same server, team and channel,
    /// minus the post the thread was opened for. A thread opened from the global Threads list has no
    /// channel to return to, so it falls back to the shell root.
    func closeThread() {
        guard location.pane == .threads || location.postID != nil else { return }
        // The channel the reader came from, recorded *before* the thread was opened: the thread's own
        // route may carry only a post id, so reconstructing the channel from it can lose the name.
        if let channel = lastChannelLocation, channel.serverID == location.serverID {
            open(.channel(channel.request))
            return
        }
        var request = location.request
        request.postID = nil
        if request.channelID != nil || request.channelName != nil {
            open(.channel(request))
        } else {
            popToRoot()
        }
    }

    @discardableResult
    func openHome(serverID: UUID? = nil, serverHost: String? = nil) -> NativeNavigationOutcome {
        open(.home(serverID: serverID, serverHost: serverHost))
    }

    /// Pop every native route and land back on the shell's root (the sidebar) for the same server.
    ///
    /// Goes through `apply` like every other route write, so there is still exactly one place that
    /// sets `location`/`path`. Back from a stale route uses this: the destination it was showing no
    /// longer exists, and the only sane place to return to is the shell.
    func popToRoot() {
        guard location.opensADestination else {
            path = []
            return
        }
        apply(NativeLocation(serverID: location.serverID, serverName: location.serverName))
    }

    /// Shell-level server switch (the toolbar switcher): remember where the user was on the server
    /// they are leaving and restore it on the one they arrive at.
    ///
    /// Already being on `serverID` is a **no-op** — not a reset to the workspace root. That matters:
    /// `RootView.startUp()` runs on appearance, and a slow-starting appearance must not wipe a
    /// channel that a deep link or a notification tap has just routed (T30's seam, and the exact
    /// race the UI test `testNativeShellDeepLinkLandsOnTheChannelInTheNativeStack` pins).
    func activate(serverID: UUID) {
        if let current = location.serverID {
            if current == serverID {
                refreshAuthState()
                return
            }
            lastLocations[current] = location
        }
        if let remembered = lastLocations[serverID] {
            apply(remembered)
        } else {
            openHome(serverID: serverID)
        }
        refreshAuthState()
    }

    /// The **appearance/switch** entry point: `RootView` calls this when a server becomes active
    /// (first appearance, the toolbar switcher, a server removal). Populates the model only while
    /// the pane accepts native routing.
    ///
    /// T30-AV F4: `RootView.activate` used to call `activate(serverID:)` in *every* render mode, so
    /// with the flag off the model was populated on the first appearance — and `startUp()`'s
    /// "something already routed" guard (`location.serverID == nil`) then tripped on every later
    /// appearance, where pre-T30 the code re-activated `initialServer` each time. Gating at the one
    /// call site keeps the flag-off path literally the pre-T30 path: `location` stays empty, so the
    /// guard keeps answering what it answered before.
    ///
    /// Deliberately **not** folded into `activate(serverID:)`: the model still has to accept a
    /// direct activation (a route, a test, a future caller) whatever the pane resolves; it is the
    /// *appearance pass* that must not touch a pane it does not own.
    ///
    /// - Returns: whether the model was activated.
    @discardableResult
    func activateIfRouting(serverID: UUID) -> Bool {
        guard acceptsNativeRouting else { return false }
        activate(serverID: serverID)
        return true
    }

    /// Re-read the active server's auth state (appearance, foreground, a finished sign-in).
    func refreshAuthState() {
        guard let serverStore,
              let id = location.serverID ?? serverStore.activeServerID ?? serverStore.initialServer?.id,
              let server = serverStore.servers.first(where: { $0.id == id }) else { return }
        authState = authGate.authState(for: server)
    }

    /// Tab selection (a tab tap is navigation too: it survives a push and a rotation).
    func select(tab: NativeTab) {
        self.tab = tab
    }

    // MARK: Applying a location

    /// One write point for `location`/`path`, so the three entry points cannot diverge in
    /// what they leave behind.
    ///
    /// Deliberately **does not touch `tab`**: a tab is a user destination, not a routing result.
    /// A deep link that lands on a channel pushes that channel over whatever tab the user was on
    /// (and Back returns to it), which is what "the sidebar is a tab, the channel view is a push"
    /// means — a routing request must never move the tab bar under the user.
    ///
    /// A route is pushed when it [`opensADestination`](NativeLocation.opensADestination): a channel,
    /// a permalink whose channel is not resolved yet, or a threads pane. Pushing the last two is
    /// what makes `/pl/<post>` and `/{team}/threads` visible on a phone (T30-AV F3); the pane does
    /// the honest thing (a "Resolving this permalink…" state, a threads placeholder) instead of the
    /// link silently doing nothing.
    /// The last channel view the reader was on, without a thread open. Back from a thread returns
    /// here. Recorded in `apply`, so it is set by every route that shows a channel — a tap, a deep
    /// link, a notification — and never by a thread route.
    private var lastChannelLocation: NativeLocation?

    private func apply(_ newLocation: NativeLocation) {
        // Record the channel *before* a thread replaces it — the thread's own route may carry only a
        // post id, so reading it back afterwards cannot reconstruct where the reader came from.
        if location.hasChannel, location.postID == nil, location.pane == .channel,
           newLocation.postID != nil || newLocation.pane == .threads {
            lastChannelLocation = location
        }
        // Remembering the location per server here (not only in `activate`) keeps a deep link that
        // lands on server B from overwriting what server A was showing.
        if let id = location.serverID, id != newLocation.serverID {
            lastLocations[id] = location
        }
        // "Show me this team" arrives as a channel route with a team and no channel. It must not
        // close the conversation that is already open in that team — measured: the launch restore
        // opened the last channel and a team selection a moment later cleared it back to an empty pane.
        var resolved = newLocation
        if !newLocation.hasChannel, newLocation.pane == .channel, location.hasChannel,
           newLocation.serverID == location.serverID,
           newLocation.teamID != nil || newLocation.teamName != nil,
           newLocation.teamID == nil || newLocation.teamID == location.teamID {
            resolved = location
        }
        location = resolved

        // Remember the conversation, not the thread: a reply pane is a view *of* a channel, and
        // re-opening the app on a single thread would hide the channel it belongs to.
        if newLocation.pane == .channel, newLocation.postID == nil, newLocation.hasChannel,
           let serverID = newLocation.serverID {
            lastChannels?.save(LastChannel(serverID: serverID,
                                           teamID: newLocation.teamID,
                                           teamName: newLocation.teamName,
                                           channelID: newLocation.channelID,
                                           channelName: newLocation.channelName,
                                           openedAt: Date()))
        }

        guard resolved.opensADestination else {
            // The workspace root: the sidebar is the screen again.
            path = []
            return
        }
        // A thread opens *on top of* its channel, so Back returns to the conversation. Only when the
        // thread is actually scoped to that channel: a `/{team}/threads` route carries no channel
        // and must not stack onto whatever conversation happened to be open.
        if newLocation.pane == .threads,
           newLocation.hasChannel,
           let last = path.last,
           last.pane == .channel,
           last.channelKey == newLocation.channelKey,
           last.serverID == newLocation.serverID {
            if last != newLocation { path.append(newLocation) }
            return
        }
        // A thread opened **from the Threads list** stacks on the list. Without this the thread
        // replaced the list (the list carries no channel, so the case above does not fire, and the
        // fall-through resets `path`), which left `path` empty: the shell's back was disabled and a
        // reader who opened a thread from the list could not get back to it (T36-AV, measured — the
        // live suite could not reach the list's paging assertion after following/unfollowing a row).
        if newLocation.pane == .threads,
           newLocation.postID != nil,
           let last = path.last,
           last.pane == .threads,
           last.postID == nil,
           last.serverID == newLocation.serverID {
            if last != newLocation { path.append(newLocation) }
            return
        }
        if path.last == newLocation { return }
        path = [newLocation]
    }

    // MARK: Server + channel resolution

    private func resolveServer(for target: NativeTarget, in store: ServerStore) -> ServerConfig? {
        let (id, host) = target.requestedServer
        if let id, let server = store.servers.first(where: { $0.id == id }) { return server }
        if let host = host?.lowercased(), !host.isEmpty,
           let server = store.servers.first(where: { ($0.url.host ?? "").lowercased() == host }) {
            return server
        }
        // No explicit target: the shell's current server (the switcher already chose it).
        if id == nil && (host ?? "").isEmpty {
            if let primary = viewStore?.primaryServerID,
               let server = store.servers.first(where: { $0.id == primary }) { return server }
            if let active = store.activeServer ?? store.initialServer { return active }
        }
        return nil
    }

    /// The URL to offer the user when no configured server matches (so "add this server" can prefill
    /// it) — mirrors `DeepLinkRouter`'s `needsServerAdd` semantics.
    private func requestedServerURL(for target: NativeTarget, in store: ServerStore) -> URL? {
        let (id, host) = target.requestedServer
        if let id, let server = store.servers.first(where: { $0.id == id }) { return server.url }
        guard let host = host?.lowercased(), !host.isEmpty else { return nil }
        return URL(string: "https://\(host)")
    }

    private func location(for target: NativeTarget, server: ServerConfig) -> NativeLocation {
        guard let request = target.channelRequest else {
            return NativeLocation(serverID: server.id, serverName: server.name)
        }
        let pane: NativePane
        switch target {
        case .threads: pane = .threads
        default: pane = .channel
        }
        let resolved = directory?.identity(for: request, serverID: server.id)
        return NativeLocation(serverID: server.id,
                              serverName: server.name,
                              teamID: resolved?.teamID ?? request.teamID,
                              teamName: resolved?.teamName ?? request.teamName,
                              channelID: resolved?.channelID ?? request.channelID,
                              channelName: resolved?.channelName ?? request.channelName,
                              postID: request.postID,
                              pane: pane)
    }

    // MARK: Deep-link path parsing

    /// Upstream `isValidId`: a Mattermost id is 26 chars of `[a-z0-9]`. A `/channels/<x>` segment
    /// that matches is an **id**; anything else is a channel *name*.
    static func isValidID(_ candidate: String) -> Bool {
        guard candidate.count == 26 else { return false }
        return candidate.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) && !$0.isUppercase }
    }

    /// Turn a deep-link *path* into a target.
    ///
    /// Path shapes are upstream's (`app/utils/deep_link/index.ts`):
    ///   `/{team}/channels/{name|id}[/{postID}]`, `/{team}/messages/@{username}`,
    ///   `/{team}/pl/{postID}`, `/{team}/threads/{...}`, `/{team}`, `/`.
    /// Anything else is `nil` → the caller reports it instead of guessing.
    static func target(forPath path: String, serverURL: URL?) -> NativeTarget? {
        let host = serverURL?.host
        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let team = segments.first else { return .home(serverID: nil, serverHost: host) }

        func channel(_ identifiers: String?, name: String?, post: String?) -> NativeTarget {
            var request = NativeChannelRequest(serverHost: host, teamName: team)
            if let identifiers, !identifiers.isEmpty {
                if isValidID(identifiers) {
                    request.channelID = identifiers
                } else {
                    request.channelName = identifiers
                }
            }
            request.channelName = name ?? request.channelName
            request.postID = post
            return .channel(request)
        }

        if segments.count >= 2 {
            switch segments[1] {
            case "channels":
                guard segments.count >= 3 else { return nil }
                return channel(segments[2], name: nil, post: segments.count >= 4 ? segments[3] : nil)
            case "messages":
                guard segments.count >= 3 else { return nil }
                // `@{username}` is a DM: a channel name upstream (`userID__userID`), resolved from
                // the username only once the user directory exists (S08/S18).
                var name = segments[2]
                if name.hasPrefix("@") { name.removeFirst() }
                guard !name.isEmpty else { return nil }
                return channel(nil, name: name, post: nil)
            case "pl":
                guard segments.count >= 3 else { return nil }
                // A permalink names a post, not a channel: the channel is only known once the post
                // lookup exists (S12/T36). Keep the post so the pane can say so honestly.
                return channel(nil, name: nil, post: segments[2])
            case "threads":
                var request = NativeChannelRequest(serverHost: host, teamName: team)
                if segments.count >= 3 {
                    if isValidID(segments[2]) { request.channelID = segments[2] } else { request.channelName = segments[2] }
                }
                return .threads(request)
            default:
                return nil
            }
        }
        // `/{team}` — the team's root, which for this skeleton is the server's workspace root.
        return .home(serverID: nil, serverHost: host)
    }
}

// MARK: - Where the app opens
//
// These live here rather than in their own file because `Mattermost/Core` is a hand-registered
// group in the project (only `UI/Native`, `Core/Calls` and the test trees are synchronized), so a new
// file there needs a `project.pbxproj` entry — and this is navigation policy, which is this file's
// subject.

// Where the app opens.
//
// The shell used to land on "No channel selected": a reader had to find the channel they were in
// yesterday, every morning. Upstream restores the last **thread**, else the last **channel**, and
// otherwise routes to the channel list with `setLoadTarget('HOME')`
// (`mattermost-mobile` v2.45.0 = `162f2560`, `app/init/launch.ts:245-262`, `:290-294`) — there is no
// town-hall or first-channel fallback in the pinned client. This does the last-channel half of that,
// with one rule the naive version gets wrong: a saved channel that no longer exists (archived, left,
// deleted) must not be opened blindly, because the pane would then show an error instead of a
// conversation. With nothing saved the launch lands on the channel list, which is upstream's
// `HOME` (decision record: `docs/t95-shell-tab-bar-decision.md` §3).


/// The channel the reader was last in, on one server.
struct LastChannel: Codable, Equatable, Sendable {
    var serverID: UUID
    var teamID: String?
    var teamName: String?
    var channelID: String?
    var channelName: String?
    var openedAt: Date

    /// The navigation request that re-opens it.
    var request: NativeChannelRequest {
        NativeChannelRequest(serverID: serverID,
                             teamID: teamID,
                             teamName: teamName,
                             channelID: channelID,
                             channelName: channelName)
    }
}

/// One saved destination, in `UserDefaults`.
///
/// One entry, not a list: "last opened" is a single fact, and a per-server map would grow forever
/// with servers the reader stopped using. The server id inside the entry is what stops a stale
/// record from one server being opened against another.
final class LastChannelStore {
    static let defaultsKey = "mm.native.lastChannel"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = LastChannelStore.defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    func save(_ channel: LastChannel) {
        guard let data = try? JSONEncoder().encode(channel) else { return }
        defaults.set(data, forKey: key)
    }

    func last(for serverID: UUID) -> LastChannel? {
        guard let data = defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode(LastChannel.self, from: data),
              saved.serverID == serverID else { return nil }
        return saved
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}

/// Chooses what to open when the shell starts with nowhere to go.
///
/// Upstream's cold start restores the last **thread**, else the last **channel**, else routes to the
/// channel list (`app/init/launch.ts:245-262`, `:290-294`). It has **no** town-hall or first-channel
/// fallback: "nothing saved" means "show the list". Inventing a conversation there was our deviation,
/// and on the phone layout it also raced the first tab tap — a reset launch has nothing saved, so the
/// fabricated push landed on top of the tabs the test was about to press
/// (`docs/t95-shell-tab-bar-decision.md` §3).
enum LaunchDestination {
    /// - Parameters:
    ///   - saved: the last channel, if it was on this server.
    ///   - available: the channel ids the sidebar actually knows about, when that is known. Empty
    ///     means "not loaded yet": the saved destination is then trusted, and the pane is the judge.
    ///   - teamID, teamName: the team the shell is launching into, used only to complete a saved
    ///     record that was written before its team was known. The record's own team always wins.
    /// - Returns: the saved channel's request when it is still in `available` (or `available` has not
    ///   loaded), `nil` otherwise. A saved channel that is gone must not be opened blindly.
    static func request(saved: LastChannel?,
                        available: Set<String> = [],
                        serverID: UUID,
                        teamID: String?,
                        teamName: String?) -> NativeChannelRequest? {
        guard let saved, saved.serverID == serverID,
              saved.channelID != nil || saved.channelName != nil else { return nil }
        let stillThere = available.isEmpty
            || saved.channelID.map(available.contains) == true
            || saved.channelName.map { name in available.contains(name) } == true
        guard stillThere else { return nil }
        var request = saved.request
        if request.teamID == nil { request.teamID = teamID }
        if request.teamName == nil { request.teamName = teamName }
        return request
    }
}
