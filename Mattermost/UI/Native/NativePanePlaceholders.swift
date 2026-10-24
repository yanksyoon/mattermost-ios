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

    /// The location, but only while it belongs to this server (an inactive mounted scene shows
    /// nothing selected rather than another server's channel).
    private var location: NativeLocation? {
        navigation.location.serverID == server.id ? navigation.location : nil
    }

    var body: some View {
        List {
            Section {
                row(server.name, systemImage: "server.rack")
                if let team = location?.teamName {
                    row(team, systemImage: "person.3")
                } else if location?.teamID != nil {
                    row(location?.teamID ?? "", systemImage: "person.3")
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
        .accessibilityIdentifier("nativeSidebar")
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

// MARK: - Channel pane

/// The channel view placeholder: the region S11 (T34) renders the post list into, with the header a
/// real channel header will keep (`#channel` + the Threads affordance).
struct NativeChannelPaneView: View {
    let location: NativeLocation
    @ObservedObject var navigation: NativeNavigation

    private var title: String {
        location.channelDisplayName ?? "Channel"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if location.hasChannel {
                        NativePaneNote(
                            systemImage: "text.bubble",
                            title: "Post list — S11 (T34)",
                            body: "The post list, date separators, new-message line and message "
                                + "markdown all land in S11 (T34). The shell renders the channel "
                                + "header and the navigation around it so that card has somewhere "
                                + "to plug in."
                        )
                    } else {
                        NativePaneNote(
                            systemImage: "clock.arrow.circlepath",
                            title: "Resolving this permalink…",
                            body: "This URL names a post (#\(location.postID ?? "?")) but not its "
                                + "channel, so the pane cannot open a conversation yet. Resolving a "
                                + "post to its channel is S12 (T36); until then the shell shows this "
                                + "state instead of guessing a channel."
                        )
                        ProgressView()
                            .progressViewStyle(.linear)
                            .accessibilityIdentifier("nativePermalinkProgress")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nativeChannelPane")
    }

    private var header: some View {
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
            .disabled(!location.hasChannel)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}

// MARK: - Threads

/// Per-channel thread pane placeholder (RHS in the web app; a pushed screen upstream).
struct NativeThreadsPaneView: View {
    let location: NativeLocation
    @ObservedObject var navigation: NativeNavigation

    var body: some View {
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
                    title: "Thread replies — S13 (T36)",
                    body: "Follow/unfollow state, reply pagination and the thread options menu land "
                        + "in S13 (T36)."
                        + (location.channelDisplayName.map { " This pane is already scoped to #\($0)." } ?? "")
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
        ScrollView {
            NativePaneNote(
                systemImage: "text.bubble",
                title: "Global threads — S13 (T36)",
                body: "All followed threads across \(server.name)'s teams land in S13 (T36). "
                    + "A thread opened from a channel pushes the per-channel pane instead, so Back "
                    + "returns to that channel."
            )
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nativeThreadsList")
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
                // `UnportedSurfaceView`'s, because it is the same guarantee: a native pane can
                // always be handed back to the webview without relaunching.
                resolver.forceWebForThisRun(SurfaceDefaults.paneHostSurface)
            } label: {
                Label("Use the web view to sign in", systemImage: "safari")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("revertToWeb\(SurfaceDefaults.paneHostSurface.rawValue)")
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
