// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/home/channel_list/channel_list.tsx (phone: Servers rail + TeamSidebar +
//        CategoriesList, channel screen pushed on top),
//        app/screens/home/channel_list/additional_tablet_view/additional_tablet_view.tsx
//        (wide: the sidebar list stays and the detail pane swaps between Channel / GlobalThreads),
//        app/screens/home/tab_bar/index.tsx (bottom tab bar: Home / Search / Mentions / Saved / Account).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §3; no
// upstream source copied. SwiftUI decomposition is this repo's own (docs/component-map.md §1).

import SwiftUI

/// The native workspace shell: the native counterpart of the webview's workspace chrome, hosting
/// the channel sidebar, the channel view and the thread pane as **placeholders** until each screen
/// card (S08/T32-T33, S11/T34, S13/T36) plugs into it.
///
/// ## Layout decision (phone first)
///
/// Upstream answers this per size class, and the answer is worth copying rather than inventing:
///  - **phone**: the channel list is a *tab* (its own tab bar: Home/Search/Mentions/Saved/Account),
///    and the channel screen is a **push** on top of it (`channel_list.tsx` + `AdditionalTabletView`
///    split);
///  - **tablet/desktop**: the list stays on screen and a **detail column** swaps between channel,
///    global threads and drafts (`AdditionalTabletView`) — i.e. a split view, not a push.
///
/// So the sidebar is **a tab, not a drawer**: a drawer would make the channel list a modal that has
/// to be dismissed before a conversation can be read, and would need a gesture no other Mattermost
/// client teaches. This shell therefore renders
///  - `.compact` → `TabView` (Channels, Threads) where a channel destination is pushed onto
///    `RootView`'s navigation stack (`NativeNavigation.path`),
///  - `.regular` → `NavigationSplitView` (sidebar + detail) where a destination *selects* the
///    detail column and nothing is pushed.
///
/// Both layouts render **one value** — `NativeNavigation.location` — so a deep link, a notification
/// tap and a sidebar tap produce the same *server and pane* in either layout (the channel identity
/// inside that value is only fully resolved once a channel directory exists — S08/T32-T33, see
/// `NativeLocation`); only the presentation differs.
///
/// Nothing here is a screen: every pane is an explicit stand-in that names the card which ships it.
/// A blank pane would be indistinguishable from a broken one.
struct NativeShellView: View {
    let server: ServerConfig
    @ObservedObject var navigation: NativeNavigation

    @EnvironmentObject private var resolver: SurfaceModeResolver
    /// T31: the app-level auth owner. The signed-out branch is `AuthSurfaceView`, which renders the
    /// native sign-in screen behind `SurfaceHost(.auth)` and falls back to the T30 stand-in while
    /// that surface still resolves web (the shipping configuration until T31-AV approves it).
    @EnvironmentObject private var auth: AuthCoordinator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// T39: the lookup screens (search, saved) in the **regular** layout.
    ///
    /// The compact layout reaches them as tabs. The split layout has no tab bar, and
    /// `NativeTarget` has no search/saved case, so without this a Pad/desktop window could not open
    /// the two screens at all — the surfaces would exist and be unreachable. One sheet holds either,
    /// so only one `.sheet` modifier is attached to a given view (SwiftUI applies several unreliably).
    @State private var lookupSheet: LookupSheet?

    private enum LookupSheet: String, Identifiable {
        case search
        case saved
        var id: String { rawValue }
        var title: String { self == .search ? "Search" : "Saved messages" }
    }

    /// An unauthenticated server shows the auth surface instead of a workspace (scope §2).
    ///
    /// Keyed on the *location's* server: `NativeNavigation.authState` describes the active
    /// destination, so an inactive mounted scene (a second server, hidden by `RootView`) must not
    /// borrow another server's state.
    private var showsAuthSurface: Bool {
        navigation.location.serverID == server.id && navigation.authState == .signedOut
    }

    var body: some View {
        // The auth surface is deliberately **outside** the shell's accessibility container.
        //
        // T30-AV F2: with the `Group` + `.accessibilityElement(children: .contain)` +
        // `nativeShell` wrapper around *both* branches, SwiftUI applied those modifiers to the
        // auth child and its own `nativeAuthSurface` identifier was shadowed — the element in the
        // tree carried `nativeShell` and "Sign in to …", and no `nativeAuthSurface` node existed
        // in any configuration. That made the flag-off UI assertion
        // (`XCTAssertFalse(element(app, "nativeAuthSurface").exists)`) unfalsifiable. Two things
        // fix it: the signed-out state is not the workspace shell, so it gets its own top-level
        // branch (and its own identifier, which T31's sign-in screen will keep), and the
        // `nativeShell` container only wraps the shell it actually names.
        if showsAuthSurface {
            // T31: the sign-in screen is its own surface card (`SurfaceHost(.auth)` inside), so it
            // stays behind the dual-render switch; it is still outside the shell's accessibility
            // container so its `nativeAuthSurface` identifier reaches the tree (T30-AV F2).
            AuthSurfaceView(server: server, coordinator: auth)
        } else {
            workspaceShell
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))
                // One accessibility container for the whole shell: UI tests identify the shell,
                // then the panes inside it, without depending on SwiftUI's element-type choices.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("nativeShell")
        }
    }

    /// The workspace shell itself (signed in): one `NativeLocation` rendered by whichever layout
    /// the size class calls for.
    @ViewBuilder
    private var workspaceShell: some View {
        if horizontalSizeClass == .regular {
            regularLayout
        } else {
            compactLayout
        }
    }

    /// Wide layout: sidebar + detail (upstream `AdditionalTabletView` behaviour).
    private var regularLayout: some View {
        NavigationSplitView {
            NativeChannelSidebarPane(server: server, navigation: navigation)
                // The column holds T32's 64 pt team rail *and* T33's channel list (upstream mounts
                // them the same way). 260 ideal left the list ~196 pt, where "Off-Topic" truncated to
                // "Off-…"; 320 gives the list the ~256 pt upstream's sidebar has.
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        } detail: {
            NativeDestinationPaneView(location: navigation.location, navigation: navigation,
                                      server: server)
                // T39: the two lookup surfaces, reachable from the detail column's toolbar. They are
                // gated on the `search` surface inside their own panes, so with the flag off they
                // explain that rather than drawing a screen the dual-render switch called web.
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            lookupSheet = .search
                        } label: {
                            Label("Search", systemImage: "magnifyingglass")
                        }
                        .accessibilityIdentifier("shellSearchButton")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            lookupSheet = .saved
                        } label: {
                            Label("Saved messages", systemImage: "bookmark")
                        }
                        .accessibilityIdentifier("shellSavedButton")
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(item: $lookupSheet) { which in
            NavigationStack {
                Group {
                    switch which {
                    case .search:
                        SearchPaneContent(server: server, navigation: navigation)
                    case .saved:
                        SavedPaneContent(server: server, navigation: navigation)
                    }
                }
                .navigationTitle(which.title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { lookupSheet = nil }
                            .accessibilityIdentifier("\(which.rawValue)SheetClose")
                    }
                }
            }
        }
    }

    /// Phone layout: the sidebar is a tab, the channel view is a push (see the type comment).
    private var compactLayout: some View {
        TabView(selection: $navigation.tab) {
            NativeChannelSidebarPane(server: server, navigation: navigation)
                .tabItem {
                    Label(NativeTab.channels.title, systemImage: NativeTab.channels.systemImage)
                }
                .tag(NativeTab.channels)

            NativeThreadsPlaceholderView(server: server, navigation: navigation)
                .tabItem {
                    Label(NativeTab.threads.title, systemImage: NativeTab.threads.systemImage)
                }
                .tag(NativeTab.threads)

            // T39 (S19/S20): the lookup tabs. Both are gated on the `search` surface inside their own
            // pane (see `SearchPaneContent`), so with the flag off they say so instead of drawing a
            // screen the dual-render switch says is not native.
            SearchPaneContent(server: server, navigation: navigation)
                .tabItem {
                    Label(NativeTab.search.title, systemImage: NativeTab.search.systemImage)
                }
                .tag(NativeTab.search)

            SavedPaneContent(server: server, navigation: navigation)
                .tabItem {
                    Label(NativeTab.saved.title, systemImage: NativeTab.saved.systemImage)
                }
                .tag(NativeTab.saved)
        }
    }
}

// MARK: - Destination

/// Renders whatever `NativeLocation` currently names. Used **twice** on purpose:
///  - as the regular layout's detail column (selection-driven), and
///  - as `RootView`'s `navigationDestination` (the compact push, `NativeNavigation.path`).
///
/// Same view, same value in both — that is what keeps a push and a detail column from drifting.
struct NativeDestinationPaneView: View {
    let location: NativeLocation
    @ObservedObject var navigation: NativeNavigation

    /// The configured server this route belongs to, when the caller can resolve it.
    ///
    /// T34's channel pane needs it to build its request: a `NativeLocation` carries the server's
    /// *id*, and only the shell's server list can turn that into a base URL. Callers that cannot
    /// resolve it (a hover/preview) may pass `nil`; the channel pane then says so instead of spinning.
    var server: ServerConfig? = nil

    /// Whether the location's server is still in the shell's server list. A route outlives the server
    /// it names — the user can remove that server from the switcher (or Settings) while its channel
    /// is open — so the pane has to say what happened instead of rendering a conversation for a
    /// server this device no longer has. Defaults to `true` for callers that only ever pass a
    /// configured server (the regular layout's detail column).
    var serverIsConfigured: Bool = true

    var body: some View {
        Group {
            if !serverIsConfigured {
                NativeStaleRouteView(location: location) { navigation.popToRoot() }
            } else if location.pane == .threads {
                NativeThreadsPaneView(location: location, navigation: navigation, server: server)
            } else if location.hasChannel || location.postID != nil {
                NativeChannelPaneView(location: location, navigation: navigation, server: server)
            } else {
                NativeEmptyDestinationView(serverName: location.serverName)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
