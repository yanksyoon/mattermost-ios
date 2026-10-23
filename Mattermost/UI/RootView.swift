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

    var body: some View {
        NavigationStack {
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
            .toolbar {
                // The switcher/add chrome only belongs once at least one server exists;
                // over the welcome/empty state there is nothing to switch.
                if !serverStore.servers.isEmpty {
                    ToolbarItem(placement: .principal) { serverSwitcher }

                    // History chrome follows the *active* server's webview only.
                    if let activeStore = activeServer.map({ viewStore.view(for: $0) }) {
                        WebNavToolbar(store: activeStore)
                    }
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
                    .onAppear(perform: startUp)
            .onChange(of: scenePhase) { _, newPhase in
                // Desktop hides/shows window web contents; iOS backgrounding is the analogue.
                guard let active = activeServer,
                      let store = viewStore.view(forServerID: active.id) else { return }
                if newPhase == .background {
                    store.stopLoading()
                } else if newPhase == .active, store.url == nil {
                    store.load(active.url)
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
        ContentView(server: server, store: viewStore.view(for: server))
            // Keep inactive servers mounted so their webview (and session) survives a switch.
            .opacity(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
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
        if let initial = serverStore.initialServer {
            activate(initial)
        }
    }

    private func activate(_ server: ServerConfig) {
        serverStore.switchTo(id: server.id)
        viewStore.setPrimary(server.id)
        let store = viewStore.view(for: server)
        if store.url == nil {
            store.load(server.url)
        }
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
