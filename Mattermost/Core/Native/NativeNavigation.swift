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

/// The shell's top-level sections (upstream `app/screens/home/tab_bar`, trimmed to the two the
/// skeleton renders: the channel list/Home tab and global threads).
enum NativeTab: String, Hashable, CaseIterable {
    case channels
    case threads

    var title: String {
        switch self {
        case .channels: return "Channels"
        case .threads: return "Threads"
        }
    }

    var systemImage: String {
        switch self {
        case .channels: return "bubble.left.and.bubble.right"
        case .threads: return "text.bubble"
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
/// Layout-agnostic on purpose: the value here is *where*, and the compact/regular layouts decide
/// *how* (a push on a phone, a detail column on a wide layout). See `NativeShellView`.
@MainActor
final class NativeNavigation: ObservableObject {

    // MARK: Wiring

    weak var serverStore: ServerStore?
    weak var viewStore: ViewStore?
    /// The one render-mode decision (T26). The shell is the native branch of
    /// `SurfaceDefaults.paneHostSurface`, so routing only diverts here while that surface resolves
    /// `native`.
    private let resolver: SurfaceModeResolver?
    /// Name ⇄ id resolution; `nil` until S08/T36 supply data (see `NativeChannelDirectory`).
    var directory: NativeChannelDirectory?
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
        guard location.hasChannel || location.pane == .threads else {
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
    private func apply(_ newLocation: NativeLocation) {
        // Remembering the location per server here (not only in `activate`) keeps a deep link that
        // lands on server B from overwriting what server A was showing.
        if let id = location.serverID, id != newLocation.serverID {
            lastLocations[id] = location
        }
        location = newLocation

        guard newLocation.hasChannel else {
            // The workspace root: the sidebar is the screen again.
            path = []
            return
        }
        // A thread opens *on top of* its channel, so Back returns to the conversation.
        if newLocation.pane == .threads,
           let last = path.last,
           last.pane == .channel,
           last.channelKey == newLocation.channelKey,
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
