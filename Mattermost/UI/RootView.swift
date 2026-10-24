import SwiftUI

/// Multi-server root: mounts one scene per configured server, shows the active one, and offers
/// the server switcher in the navigation bar. Native counterpart of desktop `MainWindow` +
/// `TabManager` + `ServerDropdownButton`.
/// Parity rows: `MainWindow` -> `RootView`, `TabManager` -> mounted server scenes,
/// `ServerDropdownButton` -> toolbar `Menu`. Status: native, P1.1/P1.3.
struct RootView: View {
    @ObservedObject var serverStore: ServerStore
    @ObservedObject var viewStore: ViewStore
    @EnvironmentObject var appSettings: AppSettings
    @EnvironmentObject var sessionStore: SessionStore
    /// The single render-mode decision point. `RootView` is the **only** caller of
    /// `ViewStore.release(...)` (T26-R R4, `docs/dual-render.md` §12.5) and therefore has to
    /// observe the pane surface's resolution itself.
    @EnvironmentObject private var resolver: SurfaceModeResolver
    /// T30: the native shell's navigation model. `RootView` owns the **push** stack binding and the
    /// destination for a native channel/thread route, because that stack is the one the shell's
    /// compact layout pushes onto (a channel view is a push on a phone, a detail column on a wide
    /// layout — see `NativeShellView`'s layout decision).
    @EnvironmentObject private var navigation: NativeNavigation
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    @State private var isPresentingServerForm = false
    @State private var isPresentingSettings = false
    @State private var isPresentingDownloads = false
    /// Non-nil when the form edits an existing server.
    @State private var editingServer: ServerConfig?
    @State private var serverPendingRemoval: ServerConfig?

    /// Server currently on screen; every other server's scene stays mounted but hidden.
    private var activeServer: ServerConfig? {
        if let id = viewStore.primaryServerID ?? serverStore.initialServer?.id {
            return serverStore.servers.first { $0.id == id }
        }
        return nil
    }

    /// The surface the one-per-server webview maps to, resolved right now.
    private var paneMode: SurfaceRenderMode {
        resolver.resolvedMode(for: SurfaceDefaults.paneHostSurface)
    }

    /// The push stack binding. A compact layout pushes the channel view; a regular-width layout
    /// renders the same `NativeLocation` in its detail column and must never push (the same split
    /// upstream draws between `channel_list.tsx` and `AdditionalTabletView`). Binding a constant on
    /// regular width also means a rotation from compact → regular pops the pushed pane while
    /// `NativeNavigation.location` keeps the selection, so nothing is lost either way.
    private var panePath: Binding<[NativeLocation]> {
        horizontalSizeClass == .compact ? $navigation.path : .constant([])
    }

    /// The shell's trailing chrome (downloads / settings / add server), shared by the navigation
    /// stack's root and by every native destination it pushes. T30: a pushed pane gets its own
    /// navigation bar, so declaring the chrome only on the root would take the server switcher and
    /// Settings away the moment a user opens a channel in the native shell.
    @ToolbarContentBuilder
    private var shellToolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                isPresentingDownloads = true
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .accessibilityLabel("Downloads")
            .accessibilityIdentifier("downloadsToolbarButton")

            Button {
                isPresentingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("settingsToolbarButton")

            Button {
                editingServer = nil
                isPresentingServerForm = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add server")
            .accessibilityIdentifier("addServerToolbarButton")
        }
    }

    var body: some View {
        NavigationStack(path: panePath) {
            ZStack {
                if serverStore.servers.isEmpty {
                    // Genuine first run → the Welcome/onboarding carousel (desktop `WelcomeScreen`).
                    // Once the user has ever configured a server, fall back to a plain empty state.
                    onboardingOrEmptyState
                } else {
                    ForEach(serverStore.servers) { server in
                        scene(for: server)
                    }
                }
            }
            // T30: the native channel/thread route the shell's compact layout pushes. Declared on
            // the stack's content (not inside a lazy container) so it registers with this stack.
            //
            // A pushed destination gets its own navigation bar, which would otherwise hide the
            // shell chrome behind it — and then a user sitting in a native channel could not switch
            // servers, reach Settings or add a server, an ability the webview pane keeps for free.
            // The destination therefore re-declares the same chrome (`shellToolbarItems`), so the
            // chrome is a property of the *shell*, not of whichever pane is on top.
            .navigationDestination(for: NativeLocation.self) { location in
                NativeDestinationPaneView(location: location, navigation: navigation,
                                          serverIsConfigured: serverStore.servers.contains { $0.id == location.serverID })
                    .toolbar {
                        if !serverStore.servers.isEmpty {
                            ToolbarItem(placement: .principal) { serverSwitcher }
                            shellToolbarItems
                        }
                    }
                    .sheet(isPresented: $isPresentingServerForm) {
                        ServerFormView(serverStore: serverStore, viewStore: viewStore, editing: editingServer)
                    }
                    .sheet(isPresented: $isPresentingDownloads) {
                        DownloadsView()
                    }
                    .sheet(isPresented: $isPresentingSettings) {
                        SettingsView(serverStore: serverStore,
                                     viewStore: viewStore,
                                     appSettings: appSettings,
                                     sessionStore: sessionStore)
                    }
            }
            .toolbar {
                // The switcher/add chrome only belongs once at least one server exists;
                // over the welcome/empty state there is nothing to switch.
                if !serverStore.servers.isEmpty {
                    ToolbarItem(placement: .principal) { serverSwitcher }

                    // History chrome follows the *active* server's webview only — and only while
                    // that webview exists. Reads go through the non-creating accessor: a released
                    // pane has no Back/Reload to offer and must not be resurrected by a body pass
                    // (`docs/dual-render.md` §12.4, "the resurrection trap").
                    if let active = activeServer,
                       let activeStore = viewStore.view(forServerID: active.id) {
                        WebNavToolbar(store: activeStore)
                    }
                    shellToolbarItems
                }
            }
            .sheet(isPresented: $isPresentingServerForm) {
                ServerFormView(serverStore: serverStore, viewStore: viewStore, editing: editingServer)
            }
            .sheet(isPresented: $isPresentingDownloads) {
                DownloadsView()
            }
            .sheet(isPresented: $isPresentingSettings) {
                SettingsView(serverStore: serverStore,
                             viewStore: viewStore,
                             appSettings: appSettings,
                             sessionStore: sessionStore)
            }
                    .confirmationDialog(
                        "Remove \(serverPendingRemoval?.name ?? "this server")?",
                        isPresented: Binding(get: { serverPendingRemoval != nil }, set: { if !$0 { serverPendingRemoval = nil } }),
                        titleVisibility: .visible
                    ) {
                        Button("Remove", role: .destructive) {
                            if let server = serverPendingRemoval {
                                remove(server)
                            }
                            serverPendingRemoval = nil
                        }
                        Button("Cancel", role: .cancel) { serverPendingRemoval = nil }
                    } message: {
                        Text("This clears the server's signed-in session on this device.")
                    }
                    .onAppear {
                        startUp()
                        // Any server mounted before this appearance (a relaunch with servers
                        // already configured) is a release candidate under the policy.
                        sweepReleases()
                    }
            .onChange(of: paneMode) { _, newMode in
                // The pane's renderer changed. This is the runtime path a user takes ("Use web
                // view", the debug inspector, `-surfaceMode`) and it is where the release policy
                // actually bites (§12.1): every mounted server's webview is released the moment
                // an approved, pane-owning native card owns the pane.
                switch newMode {
                case .native:
                    sweepReleases()
                case .web:
                    // T30: leaving the native shell pops any native route it pushed — otherwise a
                    // channel pane would stay on the stack above the webview that just replaced it.
                    navigation.path = []
                    // Returning to the webview: the active server's store must exist for its branch
                    // to mount (inactive scenes do the same from their own appearance). The load
                    // itself belongs to the branch — `WebPaneHost` calls `loadIfNeeded` with the
                    // remembered URL, which is the honest return trip of §12.4.
                    if let active = activeServer {
                        _ = viewStore.ensureStore(for: active)
                    }
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                // Desktop hides/shows window web contents; iOS backgrounding is the analogue.
                guard let active = activeServer,
                      let store = viewStore.view(forServerID: active.id) else { return }
                if newPhase == .background {
                    store.stopLoading()
                    // T14: hand the system a BGAppRefreshTask slot for the mention poller
                    // (fires minutes later while suspended; iOS decides exactly when).
                    BackgroundRefreshScheduler.scheduleNextRefresh()
                } else if newPhase == .active {
                    // Live webviews own mention delivery while active — a scheduled refresh
                    // (which the OS would only run in the background anyway) is stale.
                    BackgroundRefreshScheduler.cancelPending()
                    if store.url == nil {
                        store.load(active.url)
                    }
                }
            }
        }
    }

    // MARK: Scenes

    private struct WebNavToolbar: ToolbarContent {
        @ObservedObject var store: WebViewStore

        var body: some ToolbarContent {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button {
                    store.goBack()
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .disabled(!store.canGoBack)
                .accessibilityLabel("Back")
                .accessibilityIdentifier("backToolbarButton")

                Button {
                    store.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Reload")
                .accessibilityIdentifier("reloadToolbarButton")
            }
        }
    }

    @ViewBuilder
    private func scene(for server: ServerConfig) -> some View {
        let isActive = server.id == activeServer?.id
        ContentView(server: server, viewStore: viewStore)
            // Keep inactive servers mounted so their webview (and session) survives a switch.
            .opacity(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
            // Warming on *appearance* rather than while building the body: creating a store from
            // a body pass is the resurrection trap (`docs/dual-render.md` §12.4), and this
            // callback is also where a scene that was mounted while the pane was released gets its
            // webview back the moment the pane returns to `.web`.
            .onAppear { warmUpStore(for: server) }
    }

    // MARK: Webview lifecycle (T26-R R4, docs/dual-render.md §12)

    /// Every mounted server, one policy decision each.
    private func sweepReleases() {
        for server in serverStore.servers {
            releaseIfNeeded(server)
        }
    }

    /// Whether the pane *could* be released right now, ignoring a navigation that happens to be in
    /// flight. Drives the one question the shell must answer before it creates anything: is this
    /// pane allowed to be reclaimed? (When it is, creating a store would immediately undo the
    /// release.)
    private func paneMayBeReleased() -> Bool {
        WebViewReleasePolicy.shouldRelease(
            paneSurfaceResolved: paneMode,
            approved: SurfaceDefaults.nativeApprovedSurfaces.contains(SurfaceDefaults.paneHostSurface),
            paneOwning: SurfaceDefaults.paneOwningSurfaces.contains(SurfaceDefaults.paneHostSurface),
            navigationInFlight: false)
    }

    /// Keep today's warmth: a mounted server's store exists (and, behind a native pane, has begun
    /// loading) so switching to it is instant and its session is live **except** when the policy
    /// allows this pane to be released, in which case nothing is created. Both registries are empty
    /// today, so this is exactly the pre-R4 behaviour.
    ///
    /// The load is issued here only while the pane is **native** (where no web branch exists to do
    /// it). While the pane is the webview, `WebPaneHost`'s appearance owns the navigation — loading
    /// from both places issued the same request twice and cancelled the first one.
    private func warmUpStore(for server: ServerConfig) {
        guard !paneMayBeReleased() else { return }
        let store = viewStore.ensureStore(for: server)
        guard paneMode == .native else { return }
        // `loadIfNeeded`, not `load`: a page the surface toggle stopped mid-flight is resumed
        // (T26-R R6) rather than restarted, and a live/finished page is left alone.
        store.loadIfNeeded(server.url)
    }

    /// The single release decision: read the pane state, ask the pure policy, and release only if
    /// it says yes. `view(forServerID:)` is the **non-creating** accessor on purpose — a released
    /// store must stay released.
    private func releaseIfNeeded(_ server: ServerConfig, retryIfNavigationInFlight: Bool = true) {
        let pane = SurfaceDefaults.paneHostSurface
        let store = viewStore.view(forServerID: server.id)
        let approved = SurfaceDefaults.nativeApprovedSurfaces.contains(pane)
        let paneOwning = SurfaceDefaults.paneOwningSurfaces.contains(pane)
        let inFlight = store?.isLoading ?? false

        if WebViewReleasePolicy.shouldRelease(paneSurfaceResolved: paneMode,
                                              approved: approved,
                                              paneOwning: paneOwning,
                                              navigationInFlight: inFlight) {
            viewStore.release(serverID: server.id)
            return
        }

        // One bounded retry. This sweep can run in the very update that dismantles the web branch,
        // and `WKWebView.isLoading` flips asynchronously (KVO), so the only condition standing
        // between an approved pane and its release can be a stale `true`. Re-asking the same
        // predicate after the load has settled keeps that race from silently leaving the webview
        // warm; a navigation that is genuinely still loading (a login / SSO hop) still refuses,
        // because the predicate — not this retry — decides.
        guard retryIfNavigationInFlight, store != nil, inFlight,
              WebViewReleasePolicy.shouldRelease(paneSurfaceResolved: paneMode,
                                                 approved: approved,
                                                 paneOwning: paneOwning,
                                                 navigationInFlight: false) else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            releaseIfNeeded(server, retryIfNavigationInFlight: false)
        }
    }

    // MARK: Server switcher

    private var serverSwitcher: some View {
        Menu {
            ForEach(serverStore.servers) { server in
                Button {
                    activate(server)
                } label: {
                    if server.id == activeServer?.id {
                        Label(server.name, systemImage: "checkmark")
                    } else {
                        Text(server.name)
                    }
                }
            }
            Divider()
            Button {
                editingServer = nil
                isPresentingServerForm = true
            } label: {
                Label("Add Server…", systemImage: "plus")
            }
            // Per-server edit (desktop `ConfigureServer` / `editServer`): opens ServerFormView
            // in edit mode for that server.
            ForEach(serverStore.servers) { server in
                Button {
                    editingServer = server
                    isPresentingServerForm = true
                } label: {
                    Label("Edit \(server.name)…", systemImage: "pencil")
                }
            }
            ForEach(serverStore.servers) { server in
                Button(role: .destructive) {
                    serverPendingRemoval = server
                } label: {
                    Label("Remove \(server.name)", systemImage: "trash")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(activeServer?.name ?? "Mattermost")
                    .font(.headline)
                if serverStore.servers.count > 1 {
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
            }
        }
        // The button's accessible label naturally reads the active server name (the chevron
        // image contributes no text), which is how VoiceOver announces the current selection;
        // the `serverSwitcher` identifier keeps it discoverable to UI tests.
        .accessibilityIdentifier("serverSwitcher")
    }

    @ViewBuilder
    private var onboardingOrEmptyState: some View {
        if !serverStore.hasEverConfiguredServers {
            // First-run onboarding carousel (port of desktop `WelcomeScreen`). "Get started"
            // hands off to the add-server form; once that first server is saved the list is no
            // longer empty and RootView switches to the real scenes, dismissing this pager.
            WelcomeView(slides: WelcomeSlide.defaultSlides) {
                editingServer = nil
                isPresentingServerForm = true
            }
        } else {
            noServersState
        }
    }

    private var noServersState: some View {
        VStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No servers configured")
                .font(.headline)
            Button {
                editingServer = nil
                isPresentingServerForm = true
            } label: {
                Label("Add your first server", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Lifecycle

    private func startUp() {
        // No auto-seeded server on first run: desktop parity shows the Welcome/onboarding pager
        // (via `onboardingOrEmptyState`) on a genuine first launch, and the user adds their first
        // server through it ("Get started" → add-server form). Once a server exists we simply
        // surface the last-active / first-by-order server from `ServerStore.initialServer`.
        //
        // T30: unless something already routed. A deep link / notification tap delivered before this
        // appearance has picked a server (and possibly a channel) deliberately; activating the
        // *initial* server here would override that decision — the cold-launch race the card calls
        // out as "the seam that breaks first".
        guard navigation.location.serverID == nil else { return }
        if let initial = serverStore.initialServer {
            activate(initial)
        }
    }

    private func activate(_ server: ServerConfig) {
        serverStore.switchTo(id: server.id)
        viewStore.setPrimary(server.id)
        // T30: the native shell follows the shell's active server (and restores where the user was
        // on that server). A no-op for the webview's behaviour: the model only decides what the
        // native branch renders.
        navigation.activate(serverID: server.id)
        // Warm this server's webview so the switch is instant (session intact) — unless the pane
        // may be released, in which case creating one here would resurrect exactly what
        // `release(...)` just dropped (`docs/dual-render.md` §12.4).
        warmUpStore(for: server)
    }

    private func remove(_ server: ServerConfig) {
        // Purge from the registry and tear down its webview + isolated data store.
        _ = serverStore.remove(id: server.id)
        viewStore.remove(serverID: server.id)
        // Activate the best remaining candidate so the UI doesn't dangle.
        if activeServer == nil, let next = serverStore.initialServer {
            activate(next)
        }
    }
}
