import SwiftUI

/// Multi-server root: mounts one scene per configured server, shows the active one, and offers
/// the server switcher in the navigation bar. Native counterpart of desktop `MainWindow` +
/// `TabManager` + `ServerDropdownButton`.
/// Parity rows: `MainWindow` -> `RootView`, `TabManager` -> mounted server scenes,
/// `ServerDropdownButton` -> toolbar `Menu`. Status: native, P1.1/P1.3.
struct RootView: View {
    @ObservedObject var serverStore: ServerStore
    @ObservedObject var viewStore: ViewStore
    /// T43: the mention-input switch and the native input's read-out, handed to Settings. Optional so a
    /// host that builds `RootView` without the shell's notification objects still renders; the app always
    /// passes them (`MattermostApp`).
    var notificationPath: NotificationPathStore? = nil
    var notificationFeed: NativeNotificationFeed? = nil
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

    /// T8g §4 — the compact shell's bar draws **material**, so a list can never render its rows among
    /// the toolbar's own controls.
    ///
    /// Measured before this change (card `t_560103f6`, T33's chrome test on the 347-channel fixture,
    /// `build/logs/t8g/before-shots/t8g-02-sidebar-scrolled.png`): the bar is
    /// `{{0.0, 56.3}, {402.0, 96.0}}` while `channelSidebar.scroll` is `{{64.0, 0.0}, {338.0, 874.0}}`
    /// — the list runs the full window height and scrolls *under* the bar. iOS 18's scroll-edge
    /// effect never fires for a scroll view nested in the `TabView`'s tab content, so the bar kept its
    /// transparent (scroll-edge) appearance permanently: scrolling the list moved **66.7 %** of the
    /// bar strip's pixels, and the screenshot has a channel row drawn straight through
    /// "Local Mattermost".
    ///
    /// The fix paints the bar with the surface the compact sidebar is itself drawn on
    /// (`Color(.systemGroupedBackground)`, `ChannelSidebarView.body`), so the bar is opaque and the
    /// same 402 × 94 pt strip reads **0.0 %** differing between the list at rest and scrolled. Three
    /// properties this must keep:
    ///  * it is scoped to `.compact`, so the regular/iPad layout's `NavigationSplitView` column keeps
    ///    its own native bar appearance (acceptance 2 — measured as an unchanged iPad screenshot);
    ///  * it applies only while the **native** pane is on screen (`applies`). The webview pane is the
    ///    shipping configuration and is not what this card measured: its page is inset below the bar by
    ///    WKWebView's own content-inset adjustment, so an opaque bar would only restyle the strip over
    ///    the page's background (measured: `build/logs/t8g/web-mode-*.png`). Native chrome is painted;
    ///    the webview keeps the bar it has;
    ///  * it adds no accessibility identifier and no element per row (T8e/T8f's per-row cost stays 1);
    ///    `toolbarBackground` paints, it does not build a view in the content.
    private struct CompactToolbarMaterial: ViewModifier {
        /// `compact layout && native pane` — computed by the caller, which is where both facts live.
        let applies: Bool

        func body(content: Content) -> some View {
            if applies {
                content
                    .toolbarBackground(Color(.systemGroupedBackground), for: .navigationBar)
                    .toolbarBackground(.visible, for: .navigationBar)
            } else {
                content
            }
        }
    }

    /// Whether the shell's compact bar should be painted: compact width **and** the pane resolving
    /// native (the shell the card measured).
    private var paintsCompactChrome: Bool {
        horizontalSizeClass == .compact && paneMode == .native
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
                                          server: serverStore.servers.first { $0.id == location.serverID },
                                          serverIsConfigured: serverStore.servers.contains { $0.id == location.serverID })
                    .toolbar {
                        if !serverStore.servers.isEmpty {
                            ToolbarItem(placement: .principal) { serverSwitcher }
                            shellToolbarItems
                        }
                    }
                    // T8g §4: a pushed native pane gets its own bar, so the shell's material is
                    // declared here too — otherwise the chrome would be opaque on the list and
                    // transparent one push away.
                    .modifier(CompactToolbarMaterial(applies: paintsCompactChrome))
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
                                     sessionStore: sessionStore,
                                     notificationPath: notificationPath,
                                     notificationFeed: notificationFeed)
                    }
            }
            .toolbar {
                // The switcher/add chrome only belongs once at least one server exists;
                // over the welcome/empty state there is nothing to switch.
                if !serverStore.servers.isEmpty {
                    // T36: a thread is a pane route, not a pushed destination, so the regular-width
                    // layout has no stack chevron. Without this the only way out of a thread was to
                    // tap the channel again.
                    if navigation.location.postID != nil || navigation.location.pane == .threads {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                navigation.closeThread()
                            } label: {
                                Label("Back", systemImage: "chevron.left")
                            }
                            .accessibilityLabel("Back to the channel")
                            .accessibilityIdentifier("nativeBackButton")
                        }
                    }

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
            // T8g §4 — the compact shell's bar material (see `CompactToolbarMaterial`).
            .modifier(CompactToolbarMaterial(applies: paintsCompactChrome))
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
                             sessionStore: sessionStore,
                             notificationPath: notificationPath,
                             notificationFeed: notificationFeed)
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
                        // T31-R: these two stores are what `open(_:)` needs to resolve a route, and
                        // the app's `.task` used to be the only thing that bound them. `.task` can
                        // start after this appearance, and when it did the first route came back
                        // `.unsupported("no server store is bound")`: no location was written, so a
                        // signed-out server showed the workspace skeleton instead of the auth
                        // surface (reproduced on the T31 tree, on an erased device).
                        navigation.bind(serverStore: serverStore, viewStore: viewStore)
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
                    // The shell just took the pane. Nothing has routed into it yet (the model is
                    // left empty while the pane is web — T30-AV F4), so the appearance-gated
                    // activation would not have happened: do it here, or the shell mounts with an
                    // empty location and its auth gate unread. Guarded on the model still being
                    // empty so a route that landed first is never reset by the flip.
                    if navigation.location.serverID == nil, let active = activeServer {
                        navigation.activateIfRouting(serverID: active.id)
                    }
                case .web:
                    // T93B follow-up (`t_065c8753`): neither of these writes belongs *inside* this
                    // update. `navigation.path` is `NavigationStack`-owned state and `ensureStore`
                    // publishes store membership (`storeGeneration`); doing either in the very
                    // transaction that swaps `SurfaceHost`'s branch made SwiftUI's stack answer
                    // "Update NavigationRequestObserver tried to update multiple times per frame"
                    // (`com.apple.SwiftUI:Invalid Configuration`, measured) and re-run its root
                    // content — building a second `WebViewContainer` for the one webview and
                    // dismantling the first.
                    //
                    // The store itself is created *before* the flip on the escape hatch's path
                    // (`SurfaceModeResolver.willForceWeb` → `MattermostApp`), which is what removed the
                    // measured fault. This deferral is the ordering rule that keeps the remaining
                    // write — the T30 pop — out of the transition; it also covers the routes that
                    // flip the pane without the hatch (the Debug surface inspector), where the store
                    // is created here because `WebPaneHost`'s own appearance runs before this task.
                    Task { @MainActor in
                        // T30: leaving the native shell pops any native route it pushed — otherwise
                        // a channel pane would stay on the stack above the webview that replaced it.
                        // Guarded so a hatch tapped from the sidebar root (path already empty) does
                        // not ask the stack to pop for nothing.
                        if !navigation.path.isEmpty { navigation.path = [] }
                        // Returning to the webview: the active server's store must exist for its
                        // branch to mount (inactive scenes do the same from their own appearance).
                        // Idempotent, so on the hatch's path this is a no-op — the hook above already
                        // created it. The load itself belongs to the branch — `WebPaneHost` calls
                        // `loadIfNeeded` with the remembered URL, the honest return trip of §12.4.
                        if let active = activeServer {
                            _ = viewStore.ensureStore(for: active)
                        }
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
                    // Only a pane that *is* the webview has a page to (re)start: under a native pane
                    // the store is created but deliberately unloaded (T36-AV F7), and loading here
                    // would boot the web app as a second same-user client on every foreground.
                    if paneMode == .web, store.url == nil {
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

    /// Keep today's warmth: a mounted server's store exists, so switching to it is instant and its
    /// session is live **except** when the policy allows this pane to be released, in which case
    /// nothing is created. Both registries are empty today, so this is exactly the pre-R4 behaviour.
    ///
    /// **T36-AV F7 — a native pane must not boot the web app.** This used to call
    /// `loadIfNeeded(server.url)` while the pane was native, on the theory that "no web branch exists
    /// to do it". Measured consequence (`build/proxy.log` of the T36-AV run): with
    /// `-surfaceMode shell=native` the app still fetched ~60 `/static/*` bundles,
    /// `/api/v4/config/client`, `/api/v4/plugins/webapp`, the calls/playbooks/nps plugin bundles and
    /// opened 3+ `/api/v4/websocket` connections — i.e. the whole web app running as a **second,
    /// same-user client** behind the native shell, while the pane the reader sees is native. The store
    /// is still *created* (cheap: a detached `WKWebView` with no navigation, which the surface toggles
    /// and the release policy reason about), but nothing is loaded: the moment the pane resolves
    /// `.web`, `WebPaneHost`'s appearance owns the load (`docs/dual-render.md` §12.4's return trip), so
    /// flipping the surface still shows the page instead of a blank pane.
    private func warmUpStore(for server: ServerConfig) {
        guard !paneMayBeReleased() else { return }
        _ = viewStore.ensureStore(for: server)
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
        //
        // Gated on the pane resolving native (T30-AV F4): before this, the model was populated in
        // *both* render modes, which made `startUp()`'s "already routed" guard one-shot and let the
        // model go stale relative to the active server in web mode. With the flag off nothing here
        // touches the model at all, so the webview path is the pre-T30 path.
        navigation.activateIfRouting(serverID: server.id)
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
