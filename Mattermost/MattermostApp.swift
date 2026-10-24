import SwiftUI
import Combine
import UIKit
import WebKit

/// App entry: builds the shell's long-lived stores and hosts `RootView`.
///
/// `@StateObject` keeps the stores — and through `ViewStore`, every server's `WKWebView` and its
/// isolated data store — alive for the whole app lifetime, which is what preserves each server's
/// signed-in session across view updates and server switches.
@main
struct MattermostApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var serverStore: ServerStore
    @StateObject private var viewStore: ViewStore
    @StateObject private var downloadWorker: DownloadWorker
    @StateObject private var appSettings: AppSettings
    @StateObject private var deepLinkRouter: DeepLinkRouter
    @StateObject private var sessionStore: SessionStore
    @StateObject private var notificationWorker: NotificationWorker
    /// T26 dual-render: the per-surface webview/native decision point for the whole shell.
    @StateObject private var surfaceModeResolver: SurfaceModeResolver
    /// T30: the native shell's navigation model — the one funnel deep links, notification taps and
    /// manual taps go through. Owned here so it outlives any single server's scene.
    @StateObject private var nativeNavigation: NativeNavigation
    /// T31: the app-level auth owner — one live `AuthSession` per server, restore at launch, and
    /// the shell's `NativeAuthGate`. The sign-in surface talks to this object; nothing else may.
    @StateObject private var authCoordinator: AuthCoordinator
    /// T32: the app-level owner of the team rail — one model and **one socket** per server, plus the
    /// team scope that socket delivers through. Owned here for the same reason `AuthCoordinator` is:
    /// the sidebar view is re-created by SwiftUI (tab switch, size-class change), and a model or a
    /// WebSocket owned by the view would be re-created with it.
    @StateObject private var teamSidebarCoordinator: TeamSidebarCoordinator
    /// T33: the app-level owner of the channel sidebar — one model per server, fed by the team rail's
    /// single socket (no second connection). Owned here for the same reason the rail is.
    @StateObject private var channelSidebarCoordinator: ChannelSidebarCoordinator

    /// Keeps the Settings Stepper and the live journal in lock-step.
    @State private var historyCapCancellable: AnyCancellable?

    /// T30 debug-only screenshot probe state (`-nativeShellSnapshot <dir>`): the appearance and text
    /// size the probe forces for one capture. `nil` means "the system's own".
    @State private var snapshotColorScheme: SwiftUI.ColorScheme?
    @State private var snapshotDynamicTypeSize: DynamicTypeSize?

    #if DEBUG || PERF_PROBE
    /// T27 measurement seam: non-nil only when launched with `-perfProbe <dir>`.
    /// See `PerfProbe` — it drives a fixed sequence and writes its stage journal for the
    /// external sampler in `scripts/perf_probe.sh`.
    @State private var perfProbe: PerfProbe?
    @State private var perfServerID: UUID?
    #endif

    #if DEBUG
    /// Debug-only evidence probe (T26): launch with `-surfaceInspectorSnapshot <path>` to
    /// present the Surface inspector and write a PNG of it. Inert without the argument.
    @State private var surfaceInspectorSnapshotPath: String?
    @State private var isPresentingSurfaceInspectorProbe = false
    #endif

    /// Debug-only render-proof (T20 Catalyst): when launched with `-shellSnapshot <path>`,
    /// writes two PNGs after the primary server's webview finishes its first load:
    /// `<path>` (web content, via `WKWebView.takeSnapshot`) and `<path>.window.png` (the whole
    /// window, via `drawHierarchy`). This is the only way to prove the shell renders from a
    /// non-GUI session — `screencapture` needs Screen Recording TCC which headless agents lack.
    /// The argument is never present in normal use.
    @State private var shellSnapshotTask: Task<Void, Never>?

    init() {
        // UI-test seam: `xcodebuild test`/XCUITest launches the app with
        // `-uiTestResetPersistedState` to wipe the shell's persisted stores so each test
        // starts from a genuine fresh-first-run. This branch is inert in normal use (the
        // argument is never present) and is the standard XCUITest way to make launch state
        // deterministic. It only clears UserDefaults-backed shell state (servers, settings,
        // download journal, onboarding); Keychain credentials are a deliberate no-touch.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-uiTestResetPersistedState") {
            let domain = Bundle.main.bundleIdentifier ?? "com.mattermost.ios"
            UserDefaults.standard.removePersistentDomain(forName: domain)
            UserDefaults.standard.synchronize()
        }
        _serverStore = StateObject(wrappedValue: ServerStore())
        _viewStore = StateObject(wrappedValue: ViewStore())
        _downloadWorker = StateObject(wrappedValue: DownloadWorker(history: DownloadHistory()))
        _appSettings = StateObject(wrappedValue: AppSettings())
        _deepLinkRouter = StateObject(wrappedValue: DeepLinkRouter())
        _sessionStore = StateObject(wrappedValue: SessionStore())
        // T14: the shell shares ONE NotificationWorker between the foreground bridge path
        // and the background poller (single UNUserNotificationCenter delegate), so both
        // routes schedule/tap-route through the same object.
        _notificationWorker = StateObject(wrappedValue: NotificationWorker.shared)
        // T26: surface render-mode resolver. Reads the persisted override + `-surfaceMode`
        // launch args (debug-only) into one decision point for every surface.
        _surfaceModeResolver = StateObject(wrappedValue: SurfaceModeResolver())
        // T30: the native shell's navigation model, built from the same resolver instance the views
        // observe (so "is the pane native?" has exactly one answer). Its *store* seams are bound in
        // `bindShellStores()` on first use, **not** here: reading a `@StateObject`'s `wrappedValue`
        // before it is installed hands back a throwaway instance, so a `weak` reference taken in
        // `init` points at an object the views never see.
        let navigation = NativeNavigation(resolver: _surfaceModeResolver.wrappedValue)
        _nativeNavigation = StateObject(wrappedValue: navigation)
        // T31: the auth owner is created before any view exists, so the shell's gate and the sign-in
        // surface always talk to the same object. Its `serverStore`/`onChange` seams are bound in
        // `bindShellStores()` for the same reason the navigator's are (see that method).
        _authCoordinator = StateObject(wrappedValue: AuthCoordinator())
        // T32: the team rail's owner. Its `auth`/`navigation` seams are bound in `bindShellStores()`
        // for the same `@StateObject` reason as the two above.
        _teamSidebarCoordinator = StateObject(wrappedValue: TeamSidebarCoordinator())
        // T33: the channel list's owner. Created before any view exists; its seams are bound in
        // `bindShellStores()` for the same `@StateObject` reason as the three above.
        _channelSidebarCoordinator = StateObject(wrappedValue: ChannelSidebarCoordinator())
        #if DEBUG
        // UI-test seam: `-uiTestAssumeSignedIn` makes the native shell render as if the seeded
        // server had a session, so its panes can be exercised against a stub server that has no
        // real login. It substitutes the *gate*, never the routing: the auth surface, the deep-link
        // funnel and the panes all run their production code paths.
        if args.contains("-uiTestAssumeSignedIn") {
            navigation.authGate = AssumedSignedInAuthGate()
        }
        #endif
        // UI-test seam: `-uiTestForgetCertTrust <url>` deletes any recorded certificate-trust
        // decision for that origin before the seeded server loads, so a flow that must exercise
        // the **first-time** certificate prompt stays deterministic on a port that an earlier run
        // already trusted. The trust bag is Keychain-backed and `-uiTestResetPersistedState`
        // deliberately leaves the Keychain alone, so without this a second run of the
        // prompt→Trust flow would silently skip the prompt and prove nothing.
        //
        // DEBUG-only, like every other test affordance here: it can only *remove* a trust
        // decision (never grant one), and it is inert in a shipping build because the argument
        // branch does not exist there.
        #if DEBUG
        if let idx = args.firstIndex(of: "-uiTestForgetCertTrust"),
           args.indices.contains(idx + 1),
           let url = URL(string: args[idx + 1]) {
            try? CertTrust().remove(for: url)
            // `CertTrust.add` also mirrors every decision onto the same host's `wss://` origin
            // (desktop parity), so a mirror record outlives a plain `remove`. Leaving it behind
            // would carry an old `dontTrust` — or hide a would-be first-time prompt — across runs,
            // so forget it too. Removals only, and only for the https origin the argument names.
            if url.scheme?.lowercased() == "https",
               var mirrorComponents = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                mirrorComponents.scheme = "wss"
                if let mirror = mirrorComponents.url { try? CertTrust().remove(for: mirror) }
            }
            Logger.info("CertPrompt", "uiTest: cleared recorded trust for \(url.absoluteString)")
        }
        #endif
        // UI-test seam: `-uiTestSeedSelfSignedServer <url>` pre-populates the (fresh) store
        // with one self-signed server so the webview loads it, hits the server-trust
        // challenge, and presents the CertPromptSheet. The add-server form can't reach this
        // path because ServerURLValidator's URLSession rejects self-signed TLS during the
        // probe — this seed is the only way to exercise the cert-prompt UI on a simulator.
        if let idx = args.firstIndex(of: "-uiTestSeedSelfSignedServer"),
           args.indices.contains(idx + 1),
           let url = URL(string: args[idx + 1]) {
            let config = ServerConfig(name: "Self-signed", url: url)
            _serverStore.wrappedValue.add(config)
            _serverStore.wrappedValue.switchTo(id: config.id)
            _viewStore.wrappedValue.setPrimary(config.id)
        }
        #if DEBUG
        // UI-test seam: `-uiTestSeedServer <url>` adds one plain server so a test can reach the
        // native shell without driving the add-server form (the form validates the URL over the
        // network, which the native shell does not need). Debug-only and inert in normal use.
        // `-uiTestSeedServerName <name>` optionally names it (evidence runs against a real server
        // read better as that server's name; the default keeps every existing test's fixture).
        if let idx = args.firstIndex(of: "-uiTestSeedServer"), args.indices.contains(idx + 1),
           let url = URL(string: args[idx + 1]) {
            var name = "UI Test Server"
            if let nameIdx = args.firstIndex(of: "-uiTestSeedServerName"),
               args.indices.contains(nameIdx + 1), !args[nameIdx + 1].isEmpty {
                name = args[nameIdx + 1]
            }
            let config = ServerConfig(name: name, url: url)
            _serverStore.wrappedValue.add(config)
            _serverStore.wrappedValue.switchTo(id: config.id)
            _viewStore.wrappedValue.setPrimary(config.id)
        }
        // UI-test seam: `-uiTestForgetSession <url>` starts that server signed *out* by deleting its
        // stored credential. Without it a suite that signs in once would start every later test in
        // the signed-in shell (the gate reads the vault before it reads the network, by design) and
        // the sign-in tests would only pass on a clean device. Processed *before* the token seam
        // below, so "forget, then seed a token" means what it reads as.
        if let idx = args.firstIndex(of: "-uiTestForgetSession"), args.indices.contains(idx + 1),
           let url = URL(string: args[idx + 1]) {
            let vault = SecureVault()
            try? vault.deleteSecret(.authToken, serverURL: url)
            try? vault.deleteSecret(.userID, serverURL: url)
        }
        // UI-test seam: `-uiTestSeedStoredToken <token>` puts a session token in the vault for the
        // seeded server, so the relaunch/expiry paths can be exercised without a real sign-in
        // (there is no way to make a stub server mint one). It writes a *fake* string the stub never
        // accepts; it never reads or logs a real credential, and it does not exist in Release.
        if let idx = args.firstIndex(of: "-uiTestSeedStoredToken"), args.indices.contains(idx + 1),
           let server = _serverStore.wrappedValue.servers.last {
            try? SecureVault().setSecret(args[idx + 1], key: .authToken, serverURL: server.url)
        }
        #endif
        #if DEBUG || PERF_PROBE
        // T27: the perf harness seeds the workspace it is about to measure, so the run starts
        // from a known server with no hand-typed state. `mode == .shell` seeds nothing — that
        // run measures the shell with no webview at all.
        if let perfConfig = PerfProbe.requested(arguments: args) {
            _perfProbe = State(initialValue: PerfProbe(config: perfConfig))
            if let url = perfConfig.serverURL {
                let config = ServerConfig(name: "Perf", url: url)
                _serverStore.wrappedValue.add(config)
                _serverStore.wrappedValue.switchTo(id: config.id)
                _viewStore.wrappedValue.setPrimary(config.id)
                _perfServerID = State(initialValue: config.id)
            }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView(serverStore: serverStore, viewStore: viewStore)
                .environmentObject(deepLinkRouter)
                .environmentObject(downloadWorker)
                .environmentObject(appSettings)
                .environmentObject(sessionStore)
                .environmentObject(notificationWorker)
                .environmentObject(surfaceModeResolver)
                .environmentObject(nativeNavigation)
                // T31: the auth owner is app-wide state (the shell's gate, the sign-in surface, the
                // SSO hand-off and Settings' sign-out all read it).
                .environmentObject(authCoordinator)
                // T32: the team rail owner is app-wide for the same reason (one socket per server).
                .environmentObject(teamSidebarCoordinator)
                // T33: the channel list owner is app-wide for the same reason.
                .environmentObject(channelSidebarCoordinator)
                // T31: the SSO hand-off mounts the server's existing webview inside a sheet, so the
                // store owner has to be reachable from the environment too (the pane's web branch
                // still receives it as a parameter).
                .environmentObject(viewStore)
                // T30 debug-only screenshot probe: force one appearance / text size per capture.
                // Inert (and never touches the user's own Dynamic Type) unless the probe is running.
                .modifier(NativeShellSnapshotEnvironment(scheme: snapshotColorScheme,
                                                          typeSize: snapshotDynamicTypeSize))
                .onOpenURL { url in
                    // Deep-link entry point (native counterpart of desktop `second-instance` /
                    // `open-url` → `NavigationManager.openLinkInPrimaryTab`).
                    bindShellStores()
                    deepLinkRouter.ready()
                    _ = deepLinkRouter.handle(url)
                }
                .task {
                    // Bind the notification worker to the shell stores and drop per-server
                    // mention state when a server is removed (desktop: AppState reacts to
                    // SERVER_LOGGED_IN_CHANGED/SERVER_REMOVED; the shell owns that binding).
                    bindShellStores()
                    notificationWorker.activate()
                    sessionStore.observeServerRemovals(from: serverStore)

                    // T14: bind the background mention poller to the live stores. Without
                    // this (pure background launch) the poller falls back to fresh stores
                    // over the standard defaults / logged no-ops.
                    MentionPoller.shared.serverStore = serverStore
                    MentionPoller.shared.sessionStore = sessionStore
                    // T31-AV F3: the poller owns its own `URLSession` (background task, no scene), so
                    // its 401s never reached `AuthSession.onUnauthorized`. Report them into the one
                    // re-auth path instead of leaving the shell "signed in" on a revoked token.
                    MentionPoller.shared.unauthorizedReporter = { [weak authCoordinator] server in
                        await authCoordinator?.reportUnauthorized(server)
                    }

                    // SettingsView's download-history Stepper writes `AppSettings`; re-trim the
                    // open journal live so the UI and the persisted cap never diverge.
                    historyCapCancellable = appSettings.$downloadHistoryLimit
                        .removeDuplicates()
                        .sink { limit in
                            downloadWorker.history.setMaxRecords(limit)
                        }

                    #if DEBUG
                    // T30: replay a deep link the test could not deliver through the system.
                    openUITestDeepLinkIfRequested()
                    #endif

                    // T31: restore every stored session now that the shell is up. This is the
                    // relaunch path: a vault token is validated with `GET /users/me` before it is
                    // trusted, and only a server's rejection turns the shell to re-auth (a 401 →
                    // `AuthCoordinator.Phase.expired` → the sign-in surface with its banner). An
                    // unreachable server leaves the stored session alone, so an offline launch is not
                    // a login prompt.
                    await authCoordinator.restoreAll(serverStore.servers)
                }
                .task { runShellSnapshotIfRequested() }
                #if DEBUG
                // T30 evidence probe: `-nativeShellSnapshot <dir>` writes light/dark PNGs of the
                // shell (plus an accessibility text size pair). Inert without the argument.
                .task { runNativeShellSnapshotIfRequested() }
                // T31-R evidence probe: `-authSurfaceSnapshot <dir>` — the four captures for the
                // auth screens (light/dark × normal/AX3). Inert without the argument.
                .task { runAuthSurfaceSnapshotIfRequested() }
                #endif
                #if DEBUG || PERF_PROBE
                .task { runPerfProbeIfRequested() }
                #endif
                #if DEBUG
                .task { runSurfaceInspectorProbeIfRequested() }
                .sheet(isPresented: $isPresentingSurfaceInspectorProbe) {
                    SurfaceInspector()
                        .environmentObject(surfaceModeResolver)
                        .onAppear {
                            // Once the sheet is actually on screen (SwiftUI fires `.onAppear`),
                            // capture the whole window to the requested path. Only native chrome
                            // is present, so `drawHierarchy` captures it fully.
                            guard let path = surfaceInspectorSnapshotPath else { return }
                            let renderer = UIGraphicsImageRenderer(bounds: Self.keyWindow()?.bounds ?? .zero)
                            let image = renderer.image { _ in
                                Self.keyWindow()?.drawHierarchy(in: Self.keyWindow()?.bounds ?? .zero,
                                                                afterScreenUpdates: true)
                            }
                            try? image.pngData()?.write(to: URL(fileURLWithPath: path))
                        }
                }
                #endif
        }
    }

    #if DEBUG
    /// Parse the `-surfaceInspectorSnapshot <path>` launch argument, or nil.
    private func surfaceInspectorSnapshotRequested() -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-surfaceInspectorSnapshot"),
              args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    /// Delayed present of the inspector so the sheet is captured after the window settles.
    private func runSurfaceInspectorProbeIfRequested() {
        guard let path = surfaceInspectorSnapshotRequested() else { return }
        surfaceInspectorSnapshotPath = path
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            isPresentingSurfaceInspectorProbe = true
        }
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows }
            .joined()
            .first(where: \.isKeyWindow) ?? UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows }
            .joined()
            .first
    }

    #endif

    /// Bind the app-level stores into the pass-through routers (deep links, notification taps, the
    /// native shell's navigator).
    ///
    /// Called from the scene's `.task` and from `onOpenURL` — i.e. **after** the `@StateObject`s are
    /// installed, whichever of the two runs first. Wiring these `weak` seams in `init` did not hold:
    /// the first version of T30 set `deepLinkRouter.nativeNavigation` there, and by the time the
    /// views ran the property was nil, so a native deep link silently took the webview path (see
    /// `docs/t30-build-note.md` §9.1 — the observable fact; the exact `@StateObject`
    /// read-before-install semantics that produced it are not something to depend on either way).
    /// Idempotent: re-assigning the same objects is a no-op, so every entry point can call it.
    private func bindShellStores() {
        deepLinkRouter.serverStore = serverStore
        deepLinkRouter.viewStore = viewStore
        deepLinkRouter.nativeNavigation = nativeNavigation
        notificationWorker.serverStore = serverStore
        notificationWorker.viewStore = viewStore
        notificationWorker.nativeNavigation = nativeNavigation
        nativeNavigation.serverStore = serverStore
        nativeNavigation.viewStore = viewStore
        // T31: the shell's auth gate is the live coordinator (one `AuthSession` per server), and a
        // phase change — a finished sign-in, a sign-out, a 401 from any native call — re-asks the
        // shell. `-uiTestAssumeSignedIn` keeps its substituted gate: that seam exists precisely to
        // exercise the shell against a server that has no session.
        #if DEBUG
        if !ProcessInfo.processInfo.arguments.contains("-uiTestAssumeSignedIn") {
            nativeNavigation.authGate = authCoordinator
        }
        #else
        nativeNavigation.authGate = authCoordinator
        #endif
        // T32: the rail reads the current team from `NativeNavigation.location` (one source of
        // truth) and owns one socket per server. Bound here, with the other shell seams.
        teamSidebarCoordinator.bind(auth: authCoordinator,
                                    navigation: nativeNavigation,
                                    serverStore: serverStore)
        // T33: the channel list reads the same location and is **fed by the rail's socket**, so the
        // app keeps exactly one WebSocket per server. The rail's channel-scoped events are handed to
        // the list's coordinator, which debounces them into one counter refresh.
        channelSidebarCoordinator.bind(auth: authCoordinator,
                                       navigation: nativeNavigation,
                                       serverStore: serverStore,
                                       teams: teamSidebarCoordinator)
        teamSidebarCoordinator.onTeamEvent = { [weak channelSidebarCoordinator] serverID, event in
            guard let channelSidebarCoordinator else { return }
            Task { await channelSidebarCoordinator.handle(event, serverID: serverID) }
        }
        // T30 reserved this seam for S08: with a channel list loaded, a deep link's channel *name*
        // and a tapped mention's channel *id* resolve to the same `NativeLocation`.
        nativeNavigation.directory = channelSidebarCoordinator
        authCoordinator.onChange = { [weak nativeNavigation, weak teamSidebarCoordinator,
                                      weak channelSidebarCoordinator] serverID in
            nativeNavigation?.refreshAuthState()
            // A sign-out/expiry must take the rail's socket down with the credential it was built
            // with; a finished sign-in is what lets it come up.
            teamSidebarCoordinator?.authPhaseChanged(serverID)
            // …and the channel list (and its channel→team map) must not outlive that credential.
            channelSidebarCoordinator?.authPhaseChanged(serverID)
        }
    }

    #if DEBUG
    /// `-uiTestOpenDeepLink <url>`: hand a URL to the same `DeepLinkRouter` entry `onOpenURL` uses.
    ///
    /// XCUITest cannot deliver a system `mattermost://` open on this toolchain (there is no
    /// `XCUIApplication.open(_:)`, and the Safari round trip is flaky), so the test substitutes the
    /// **delivery**, not the handling: the URL still goes through `DeepLinkRouter.handle` →
    /// `DeepLinkRouter`'s native seam → `NativeNavigation`.
    private func openUITestDeepLinkIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-uiTestOpenDeepLink"), args.indices.contains(i + 1),
              let url = URL(string: args[i + 1]) else { return }
        bindShellStores()
        deepLinkRouter.ready()
        let outcome = deepLinkRouter.handle(url)
        Logger.info("T30", "uiTest deep link \(url.absoluteString) -> \(outcome)")
    }

    /// `-nativeShellSnapshot <dir>`: write four window PNGs of the native shell — light, dark, and
    /// each again at the `accessibility3` text size — so Dynamic Type and dark mode are evidence
    /// rather than claims. Needs no Screen Recording consent (`drawHierarchy` on the app's own
    /// window), which is why the shell has this instead of `screencapture`.
    private func runNativeShellSnapshotIfRequested() {
        runSnapshotProbe(argument: "-nativeShellSnapshot", prefix: "native-shell", tag: "T30")
    }

    /// `-authSurfaceSnapshot <dir>`: the same four captures for whatever is on screen, used by T31-R
    /// to record the **auth** screens at normal and AX3 text sizes in light and dark mode (launch it
    /// with `-surfaceMode auth=native` and a seeded, signed-out server). Same mechanism, same reason:
    /// a capture the app takes itself needs no Screen Recording TCC, so an unattended run can make it.
    private func runAuthSurfaceSnapshotIfRequested() {
        runSnapshotProbe(argument: "-authSurfaceSnapshot", prefix: "auth-surface", tag: "T31")
    }

    private func runSnapshotProbe(argument: String, prefix: String, tag: String) {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: argument), args.indices.contains(i + 1) else { return }
        let dir = args[i + 1]
        Task { @MainActor in
            // Let the first frame, the (seeded) server activation and the shell settle.
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let captures: [(String, SwiftUI.ColorScheme, DynamicTypeSize)] = [
                ("light", .light, .large),
                ("dark", .dark, .large),
                ("light-ax3", .light, .accessibility3),
                ("dark-ax3", .dark, .accessibility3),
            ]
            for (name, scheme, size) in captures {
                snapshotColorScheme = scheme
                snapshotDynamicTypeSize = size
                // A text-size change is a relayout, not a redraw: give SwiftUI a full second before
                // capturing so the picture is of the settled layout, not a half-applied one.
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                writeWindowImage(to: dir + "/" + prefix + "-" + name + ".png")
            }
            Logger.info(tag, "\(prefix) snapshots written to \(dir)")
        }
    }

    @MainActor
    private func writeWindowImage(to path: String) {
        guard let window = Self.keyWindow() else { return }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: URL(fileURLWithPath: path))
    }
    #endif

    #if DEBUG || PERF_PROBE
    // MARK: - T27 measurement seam

    /// Start the scripted perf sequence once the first frame is on screen. The store is fetched
    /// eagerly (`ensureStore` creates it on first use) so a nil store means the shell genuinely
    /// never built a webview — which the probe records as such rather than silently skipping.
    ///
    /// The probe also gets the `ViewStore` itself, because the `nativeEvicted` arm has to release
    /// the store (`docs/dual-render.md` §12.6) — the one thing no view can do on its behalf.
    private func runPerfProbeIfRequested() {
        guard let probe = perfProbe else { return }
        let store: WebViewStore?
        if let perfServerID, let cfg = serverStore.servers.first(where: { $0.id == perfServerID }) {
            store = viewStore.ensureStore(for: cfg)
        } else {
            store = nil
        }
        Task { @MainActor in
            // Let the first frame, toolbar and (for `web`/`native`) the first navigation start
            // before the sequence begins, so the sampler sees a real launch phase.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await probe.run(store: store, viewStore: viewStore, serverID: perfServerID)
        }
    }
    #endif

    // MARK: Debug-only render proof (T20 Catalyst)

    /// Parse the `-shellSnapshot <path>` launch argument, or nil.
    private var shellSnapshotPath: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-shellSnapshot"), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    /// Debounced capture: wait until the primary server's webview has committed a URL and
    /// finished *rendering* (network `isLoading` goes false before the SPA paints, so also wait
    /// until `document.body.innerText` has real length), then write the web-content snapshot,
    /// the full-window snapshot, and a diagnostics text file. Fails silently on missing
    /// webview / write errors — it is a probe.
    private func runShellSnapshotIfRequested() {
        guard let path = shellSnapshotPath else { return }
        shellSnapshotTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            var target: WebViewStore?
            for _ in 0..<60 {
                if let id = viewStore.primaryServerID ?? serverStore.activeServerID,
                   let store = viewStore.view(forServerID: id),
                   store.url != nil,
                   !store.isLoading {
                    target = store
                    break
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard let store = target else { return }

            // Wait for the SPA to paint: poll until the DOM has meaningful text (≤30s).
            var pageInfo: PageInfo = PageInfo()
            for _ in 0..<30 {
                pageInfo = (try? await store.webView.evaluateJSObject()) ?? PageInfo()
                if pageInfo.bodyTextLength > 100 { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }

            // DOM diagnostics: which layout containers exist, what they paint, and the scheme.
            // Added while chasing "the workspace UI renders broken inside the shell"; the text
            // sample alone cannot tell a skeleton from a styled-but-empty pane.
            let domProbe = """
            (() => {
              const probe = (sel) => {
                const e = document.querySelector(sel);
                if (!e) { return null; }
                const r = e.getBoundingClientRect();
                const cs = getComputedStyle(e);
                return { sel, w: Math.round(r.width), h: Math.round(r.height),
                         bg: cs.backgroundColor, opacity: cs.opacity, display: cs.display,
                         color: cs.color, kids: e.children.length };
              };
              const root = document.getElementById('root');
              const describe = (e) => {
                if (!e) { return null; }
                const r = e.getBoundingClientRect();
                const cs = getComputedStyle(e);
                return { cls: (e.className || '').toString().slice(0, 80), w: Math.round(r.width),
                         h: Math.round(r.height), bg: cs.backgroundColor,
                         text: (e.innerText || '').slice(0, 80) };
              };
              const mw = document.querySelector('.main-wrapper');
              const appBar = document.querySelector('.app-bar');
              return JSON.stringify({
                href: location.href,
                bodyTextLen: document.body.innerText.length,
                nodes: document.querySelectorAll('*').length,
                rootKids: root ? [...root.children].map(c => (c.className || '').toString().slice(0, 70)) : [],
                probes: ['.app__body', '.app__content', '.channel-view', '.post-list', '.post-list__table',
                         '.sidebar--left', '.loading-screen', '.MultiTeamSidebar', '.product-switcher-menu',
                         '.channel-header', '.center-channel'].map(probe),
                bodyBg: getComputedStyle(document.body).backgroundColor,
                htmlClass: document.documentElement.className.slice(0, 120),
                themeFlag: document.documentElement.dataset.mattermostTheme || null,
                colorScheme: getComputedStyle(document.documentElement).colorScheme,
                pathname: location.pathname + location.search,
                mainWrapperKids: mw ? [...mw.children].map(describe) : null,
                mainWrapperHtml: mw ? mw.innerHTML.slice(0, 400) : null,
                appBarKids: appBar ? [...appBar.children].map(describe) : null,
                modals: document.querySelectorAll('.modal, .Modal, [role=dialog]').length,
                loadingish: [...document.querySelectorAll('[class*=load], [class*=Load], [class*=skeleton]')].map(describe).slice(0, 6),
                errors: (window.__mmErrorLog || []).slice(0, 30),
                online: navigator.onLine,
                apiCalls: performance.getEntriesByType('resource')
                    .filter(r => r.name.indexOf('/api/') !== -1)
                    .slice(-30)
                    .map(r => r.name.replace(location.origin, '') + ' d=' + Math.round(r.duration)
                              + ' size=' + r.transferSize + ' ' + r.initiatorType)
              }, null, 1);
            })()
            """
            // WebSocket probe: the web app treats itself as offline (and never asks for posts)
            // when its socket cannot connect, which shows up as a permanent "Loading" pane.
            let wsProbe = """
            (() => {
              window.__wsProbe = 'pending';
              try {
                const url = (location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/api/v4/websocket';
                const ws = new WebSocket(url);
                ws.onopen = () => { window.__wsProbe = 'open'; ws.close(); };
                ws.onerror = () => { window.__wsProbe = 'error'; };
                ws.onclose = (e) => { window.__wsProbe = (window.__wsProbe === 'open' ? 'opened-then-closed' : 'closed:' + e.code); };
              } catch (e) { window.__wsProbe = 'threw:' + e.message; }
              return 'started';
            })()
            """
            _ = try? await store.webView.evaluateJavaScript(wsProbe)
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if let ws = try? await store.webView.evaluateJavaScript("window.__wsProbe || 'unset'") as? String {
                try? ws.write(to: URL(fileURLWithPath: path + ".ws.txt"), atomically: true, encoding: .utf8)
            }

            if let dom = try? await store.webView.evaluateJavaScript(domProbe) as? String {
                try? dom.write(to: URL(fileURLWithPath: path + ".dom.json"), atomically: true, encoding: .utf8)
            }

            // Diagnostics dump — the *text* proof of what the page rendered.
            let diag = """
            url=\(store.url?.absoluteString ?? "nil")
            title=\(store.title ?? "nil")
            bodyTextLength=\(pageInfo.bodyTextLength)
            sample=\(String(pageInfo.sample.prefix(400)))
            """
            try? diag.write(to: URL(fileURLWithPath: path + ".txt"), atomically: true, encoding: .utf8)

            // 1. Web-content snapshot — the ground truth for "the chat UI renders".
            let snapshot = await store.webView.snapshotImage()
            if let snapshot {
                try? snapshot.pngData()?.write(to: URL(fileURLWithPath: path))
            }

            // 2. Whole-window snapshot (native chrome; note WKWebView content is rendered in a
            // separate process, so `drawHierarchy` shows the chrome but often blanks the webview).
            let windows = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.windows }
                .joined()
            if let window = windows.first(where: \.isKeyWindow) ?? windows.first {
                let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
                let image = renderer.image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                try? image.pngData()?.write(to: URL(fileURLWithPath: path + ".window.png"))
            }
        }
    }
}

/// T30: applies the screenshot probe's forced appearance / text size **only when the probe set
/// one**. With no probe running (`typeSize == nil`) the app keeps the user's own Dynamic Type — a
/// blanket `.environment(\.dynamicTypeSize, …)` would have been an accessibility regression shipped
/// for the sake of a screenshot.
private struct NativeShellSnapshotEnvironment: ViewModifier {
    let scheme: SwiftUI.ColorScheme?
    let typeSize: DynamicTypeSize?

    func body(content: Content) -> some View {
        if let typeSize {
            content
                .environment(\.dynamicTypeSize, typeSize)
                .preferredColorScheme(scheme)
        } else {
            content.preferredColorScheme(scheme)
        }
    }
}

/// Minimal page-state snapshot pulled via `evaluateJavaScript` (debug render-probe).
fileprivate struct PageInfo {
    var bodyTextLength: Int = -1
    var sample: String = ""
}

private extension WKWebView {
    /// Runs a tiny probe script and decodes the result dictionary.
    func evaluateJSObject() async throws -> PageInfo {
        let js = """
        (() => {
            const t = document.body ? document.body.innerText : '';
            return { bodyTextLength: t.length, sample: t.slice(0, 400) };
        })();
        """
        let value = try await evaluateJavaScript(js)
        guard let dict = value as? [String: Any] else { return PageInfo() }
        var info = PageInfo()
        info.bodyTextLength = (dict["bodyTextLength"] as? Int) ?? -1
        info.sample = (dict["sample"] as? String) ?? ""
        return info
    }
}

/// Small async bridge over the callback-only `WKWebView.takeSnapshot(with:)` API
/// (used by the debug-only `-shellSnapshot` probe).
private extension WKWebView {
    func snapshotImage() async -> UIImage? {
        await withCheckedContinuation { continuation in
            takeSnapshot(with: nil) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}
