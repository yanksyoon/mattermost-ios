// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/home/channel_list/categories_list/ (sidebar list shape),
//        app/screens/channel/channel_post_list/channel_post_list.tsx (channel pane header + list),
//        app/screens/thread/ (thread pane), app/screens/home/recent_mentions/ (activity tab).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §3; no
// upstream source copied.

import SwiftUI

// MARK: - Sidebar

/// The channel sidebar placeholder: what `CategoriesList` + `ChannelListRow` will fill in S08
/// (T32/T33). It renders **only facts the shell actually has** — the server, the resolved team, the
/// selected channel — and says so when it has none.
///
/// The selected-channel row is a real control: tapping it routes back through
/// `NativeNavigation.openChannel`, which is the manual-navigation entry point (the third path that
/// must land where a deep link and a mention tap land).
struct NativeChannelSidebarPane: View {
    let server: ServerConfig
    @ObservedObject var navigation: NativeNavigation

    /// The always-usable escape hatch (`docs/dual-render.md` §3/§8): T26's guarantee was that a
    /// pane resolving native can always be returned to the webview without a relaunch, whatever
    /// routed it native. `UnportedSurfaceView` used to be that stand-in for this surface; now that
    /// the shell is the pane's native card, the shell has to carry the affordance.
    @EnvironmentObject private var resolver: SurfaceModeResolver
    /// T32: the app-level owner of the team rail (one model + one socket per server).
    @EnvironmentObject private var teams: TeamSidebarCoordinator
    /// T33: the app-level owner of the channel list (one model per server, no second socket).
    @EnvironmentObject private var channels: ChannelSidebarCoordinator

    /// The location, but only while it belongs to this server (an inactive mounted scene shows
    /// nothing selected rather than another server's channel).
    private var location: NativeLocation? {
        navigation.location.serverID == server.id ? navigation.location : nil
    }

    /// T32: the sidebar surface's own gate. `sidebar=native` puts the team rail in front of the
    /// channel list; `sidebar=web` (the default until T32-AV approves) keeps exactly the T30
    /// placeholder that shipped, so the rail cannot appear without its own flag.
    private var showsNativeTeams: Bool {
        resolver.resolvedMode(for: .sidebar) == .native
    }

    var body: some View {
        if showsNativeTeams {
            NativeTeamSidebarPane(server: server,
                                  navigation: navigation,
                                  model: teams.model(for: server)) {
                // T33 (S08): once the `sidebar` surface is native, the pane's content is the real
                // channel list — categories, unread, mute, favourites — not T30's placeholder. The
                // placeholder stays below (`sidebarList`) for `sidebar=web`, and it is also what the
                // list replaces *inside* the team region, so T32's rail and this list share one
                // lifetime exactly as upstream mounts them.
                NativeChannelSidebarContent(server: server,
                                            navigation: navigation,
                                            model: channels.model(for: server),
                                            teamModel: teams.model(for: server))
            }
        } else {
            sidebarList
        }
    }

    private var sidebarList: some View {
        List {
            Section {
                NativeSidebarAnchorRow(server: server)
                if location?.teamName != nil || location?.teamID != nil {
                    row(teamTitle(name: location?.teamName, id: location?.teamID) ?? "", systemImage: "person.3")
                        // T32: the one stable read-out of "which team is current" for a UI test and
                        // for VoiceOver (the rail's icons carry their own label, but the rail is
                        // hidden when there is a single team).
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("sidebarCurrentTeam")
                }
                Button {
                    resolver.forceWebForThisRun(SurfaceDefaults.paneHostSurface)
                } label: {
                    Label("Use web view", systemImage: "safari")
                }
                .accessibilityIdentifier("revertToWeb\(SurfaceDefaults.paneHostSurface.rawValue)")
            } header: {
                Text("Workspace")
            }

            Section {
                if let location, let channel = location.channelDisplayName {
                    Button {
                        // Manual navigation: same funnel as the deep link and the mention tap.
                        navigation.openChannel(location.request)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: channelSymbol(for: location))
                                .foregroundStyle(.secondary)
                            Text(channel)
                                .lineLimit(2)
                            Spacer(minLength: 4)
                            if navigation.path.last == location || navigation.location.channelKey == location.channelKey {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .accessibilityIdentifier("nativeSidebarSelectedChannel")
                } else {
                    Text("No channel selected")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Channels")
            } footer: {
                Text("Channel list and categories — S08 (T32/T33). This skeleton lists only the "
                     + "channel the router resolved, so a deep link or a mention tap is visible here.")
                    .font(.footnote)
            }

            Section {
                Button {
                    navigation.select(tab: .threads)
                } label: {
                    Label("All threads", systemImage: "text.bubble")
                }
                .accessibilityIdentifier("nativeSidebarAllThreads")
            } header: {
                Text("Threads")
            } footer: {
                Text("Global threads — S13 (T36).")
                    .font(.footnote)
            }
        }
        // T32-R (F2): the identifier deliberately does **not** sit on this `List`.
        //
        // `nativeSidebar` used to be the `List`'s own identifier, and `NativeTeamSidebarPane` wraps
        // this list in `.accessibilityElement(children: .contain)` + `nativeTeamSidebar`. When the
        // wrapper's subtree resolves to a single element — the one-team and loading states, where
        // the rail is not built — SwiftUI applies the wrapper's identifier to the child, so
        // `nativeSidebar` vanished exactly where the shipped T30 assertion needs it
        // (`MattermostUITests.swift`: "the shell's sidebar hosts the channel list placeholder").
        // The identifier now lives on `NativeSidebarAnchorRow`, which is a *leaf* (a row), present in
        // every state of the pane including the team region's own empty/failure screens, so no
        // container wrapper can shadow it.
    }

    /// The current team as a human reads it. `NativeLocation.teamName` carries the team's URL name
    /// (`ops`), because that is what a deep link names; the rail knows the display name
    /// (`Operations`), so prefer that and fall back to whatever the location has.
    private func teamTitle(name: String?, id: String?) -> String? {
        let entries = teams.model(for: server).entries
        if let name, let match = entries.first(where: { $0.name == name }) { return match.displayName }
        if let id, let match = entries.first(where: { $0.id == id }) { return match.displayName }
        if let name, !name.isEmpty { return name }
        if let id, !id.isEmpty { return id }
        return nil
    }

    private func row(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(title)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
    }

    private func channelSymbol(for location: NativeLocation) -> String {
        // DMs/GMs have no `#`; the shell cannot tell yet (no channel-type data), so it says so
        // honestly by only using `#` for named public-looking channels.
        (location.channelName?.contains("__") ?? false) ? "person.crop.circle" : "number"
    }
}

// MARK: - The pane's anchor row

/// The sidebar pane's **anchor row**: the server this pane belongs to, and the element that carries
/// the pane's `nativeSidebar` identifier.
///
/// Why a row and not the pane/`List` (T32-R, F2): the team region wraps the pane in a container
/// identified `nativeTeamSidebar`, and SwiftUI gives a container's identifier to its child whenever
/// the subtree resolves to a single element — which is exactly the one-team and loading states (no
/// rail) and the team region's empty/failure screens (no channel list). A *leaf* keeps its own
/// identifier no matter what wraps it, so `nativeSidebar` is resolvable in every state of the pane,
/// with the `sidebar` flag off (this row is inside T30's list) and on (the team region draws it in
/// the states that replace the list). `MattermostUITests.swift`'s shipped assertion and
/// `T32-SidebarIdentifiersTests` both depend on that.
struct NativeSidebarAnchorRow: View {
    let server: ServerConfig

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "server.rack")
                .foregroundStyle(.secondary)
                // Decorative: the combined element's label must read "Local Mattermost", not
                // "server.rack, Local Mattermost" (an SF Symbol with no explicit label is named by
                // its symbol name).
                .accessibilityHidden(true)
            Text(server.name)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("nativeSidebar")
    }
}

// MARK: - Channel pane

/// The channel pane: the region S11 (T34) renders the post list into.
///
/// T34 replaced the middle (the "Post list — S11" note) with `ChannelPaneContent`, which owns the
/// header, the post list, the load-earlier sentinel and the composer stand-in. The permalink branch
/// is unchanged: a URL that names a post but not its channel still cannot open a conversation
/// (resolving a post to its channel is S12/T36).
///
/// `server` is optional because the pane is reachable from two places: the regular layout's detail
/// column (which has the shell's server) and `RootView`'s push (which resolves it from the server
/// list). A pane whose server was removed mid-route gets the stale-route view instead.
struct NativeChannelPaneView: View {
    let location: NativeLocation
    @ObservedObject var navigation: NativeNavigation
    var server: ServerConfig? = nil

    var body: some View {
        Group {
            if location.hasChannel, let channelID = location.channelID, let server {
                ChannelPaneContent(server: server,
                                   channelID: channelID,
                                   channelName: location.channelDisplayName,
                                   navigation: navigation,
                                   // T39: a route that names a post lands on it (a search result, a
                                   // saved/pinned message, a permalink). Before this the pane opened
                                   // the channel at its newest message and the post was never shown.
                                   focusPostID: location.postID)
            } else if location.hasChannel, let channelID = location.channelID {
                // A channel without a resolvable server cannot make a request; say so rather than
                // render a list that would spin forever.
                VStack(spacing: 0) {
                    header(title: location.channelDisplayName ?? "Channel", isEnabled: false)
                    Divider()
                    NativePaneNote(systemImage: "server.rack",
                                   title: "This server is not configured",
                                   body: "The channel #\(channelID) belongs to a server this app no "
                                       + "longer has. Add it again to read this conversation.")
                        .padding()
                    Spacer(minLength: 0)
                }
            } else if location.postID != nil {
                VStack(spacing: 0) {
                    header(title: "Channel", isEnabled: false)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            NativePaneNote(
                                systemImage: "clock.arrow.circlepath",
                                title: "Resolving this permalink…",
                                body: "This URL names a post (#\(location.postID ?? "?")) but not its "
                                    + "channel, so the pane cannot open a conversation yet. Resolving "
                                    + "a post to its channel is S12 (T36); until then the shell shows "
                                    + "this state instead of guessing a channel."
                            )
                            ProgressView()
                                .progressViewStyle(.linear)
                                .accessibilityIdentifier("nativePermalinkProgress")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    }
                }
            } else {
                NativeEmptyDestinationView(serverName: location.serverName)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nativeChannelPane")
    }

    private func header(title: String, isEnabled: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "number")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .lineLimit(2)
                .accessibilityIdentifier("nativeChannelTitle")
            Spacer(minLength: 8)
            Button {
                navigation.openThreads(location.request)
            } label: {
                Label("Threads", systemImage: "text.bubble")
                    .labelStyle(.iconOnly)
            }
            .accessibilityLabel("Threads")
            .accessibilityIdentifier("nativeChannelThreadsButton")
            .disabled(!isEnabled)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}

// MARK: - Threads

/// Per-channel thread pane (RHS in the web app; a pushed screen upstream).
///
/// Two shapes, exactly as upstream's routes are:
///  - a **thread** (`/{team}/threads` reached with a post — a reply line, a permalink, a notification)
///    renders `ThreadPaneContent`;
///  - the **thread list** (`/{team}/threads`, the channel header's Threads button) renders the global
///    list — upstream's `threads_button` navigates to `GLOBAL_THREADS`, not to a channel-filtered
///    list, and the server has no channel-scoped threads endpoint (measured: `?channel_id=` is
///    ignored, `GET /channels/{id}/threads` is 404).
///
/// With no resolved server (a preview, a route whose server was removed) the pane keeps saying what
/// it cannot do instead of rendering a spinner for a request it will never send.
struct NativeThreadsPaneView: View {
    let location: NativeLocation
    @ObservedObject var navigation: NativeNavigation
    /// The configured server this route belongs to. Nil for callers that cannot resolve it.
    var server: ServerConfig? = nil

    var body: some View {
        if let server, let postID = location.postID {
            ThreadPaneContent(server: server,
                              rootID: postID,
                              channelID: location.channelID ?? "",
                              navigation: navigation)
        } else if let server {
            GlobalThreadsPaneContent(server: server, navigation: navigation)
        } else {
            unresolvedPane
        }
    }

    private var unresolvedPane: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "text.bubble")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Threads")
                    .font(.headline)
                Spacer(minLength: 8)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                NativePaneNote(
                    systemImage: "text.bubble",
                    title: "This server isn't configured",
                    body: "Threads belong to a server, and the route names one this device doesn't "
                        + "have configured (yet)."
                        + (location.channelDisplayName.map { " The route was scoped to #\($0)." } ?? "")
                )
                .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nativeThreadsPane")
    }
}

/// The Threads **tab** (global threads, upstream `global_threads`).
struct NativeThreadsPlaceholderView: View {
    let server: ServerConfig
    @ObservedObject var navigation: NativeNavigation

    var body: some View {
        GlobalThreadsPaneContent(server: server, navigation: navigation)
    }
}

// MARK: - Empty destination

/// Nothing selected yet — the wide layout's detail column before a channel is resolved. Built like
/// the shell's existing empty state (`RootView.noServersState`): icon, headline, one explanation.
struct NativeEmptyDestinationView: View {
    let serverName: String?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(serverName.map { "No channel selected on \($0)" } ?? "No channel selected")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Pick a channel from the sidebar, or open one through a link or a mention.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nativeEmptyDestination")
    }
}

// MARK: - Stale route

/// A routed destination whose server is no longer configured on this device.
///
/// This is the shell's one genuine error state, and it is rendered with the app's existing
/// `ErrorStateView` (scope §4: empty/loading/error states reuse the existing patterns) rather than a
/// new screen: same warning glyph, headline, explanation and retry affordance as the webview's
/// connection failure, with copy that says what actually happened. The retry is "go back to the
/// shell", because there is nothing on this server left to retry — the server is gone.
struct NativeStaleRouteView: View {
    let location: NativeLocation
    var onReturn: () -> Void

    var body: some View {
        ErrorStateView(
            error: NativeStaleRouteError(serverName: location.serverName, channel: location.channelDisplayName),
            url: nil,
            title: "This server is no longer on this device",
            detail: "The link you followed points at \(location.serverName ?? "a server")"
                + (location.channelDisplayName.map { " (\($0))" } ?? "")
                + ", which has been removed from this app. Nothing is lost on the server itself.",
            onRetry: onReturn
        )
        .accessibilityIdentifier("nativeStaleRoute")
    }
}

/// The technical line `ErrorStateView` prints under the explanation (`error.localizedDescription`).
struct NativeStaleRouteError: LocalizedError {
    let serverName: String?
    let channel: String?

    var errorDescription: String? {
        let where_ = [serverName, channel].compactMap { $0 }.joined(separator: " / ")
        return "Route target not configured on this device\(where_.isEmpty ? "" : ": \(where_)")"
    }
}

// MARK: - Auth surface

/// The unauthenticated-server surface (scope §2).
///
/// It is **not** a login form: native login/MFA/SSO is S01–S03, card T31. Until that card lands the
/// honest route to a signed-in session is the web view, which is why this surface offers exactly
/// that (through the always-usable escape hatch `forceWebForThisRun`, which also works in Release).
struct NativeAuthPlaceholderView: View {
    let server: ServerConfig
    @ObservedObject var resolver: SurfaceModeResolver

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("Sign in to \(server.name)")
                .font(.headline)
                .multilineTextAlignment(.center)

            Text("This server has no session on this device. Native login, MFA and SSO are "
                 + "S01–S03 (T31); until that card lands, sign-in runs in the web view, which stays "
                 + "the reference for the auth flow (SSO included).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Button {
                // The escape hatch: returns this surface's pane to the webview for the rest of the
                // run, whatever routed it native. Same identifier as the sidebar's escape hatch and
                // the old `UnportedSurfaceView`'s, because it is the same guarantee: a native pane
                // can always be handed back to the webview without relaunching.
                resolver.forceWebForThisRun(SurfaceDefaults.paneHostSurface)
            } label: {
                Label("Use the web view to sign in", systemImage: "safari")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("revertToWeb\(SurfaceDefaults.paneHostSurface.rawValue)")
            // (No second identifier here: SwiftUI keeps one identifier per element, and the last
            // one wins — the T26 escape-hatch tests need `revertToWeb…` exactly where it is.)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nativeAuthSurface")
    }
}

// MARK: - Shared note

/// One placeholder note: the card that ships this region, and what it will render. Used by every
/// pane so "not ported" reads the same everywhere (and so no pane is ever a blank rectangle).
struct NativePaneNote: View {
    let systemImage: String
    let title: String
    let message: String

    /// `body:` on purpose: call sites read like the sentence they render, while the stored property
    /// stays `message` (a property called `body` would collide with `View.body`).
    init(systemImage: String, title: String, body: String) {
        self.systemImage = systemImage
        self.title = title
        self.message = body
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}
