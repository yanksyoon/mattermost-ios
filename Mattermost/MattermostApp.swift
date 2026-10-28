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

    /// T41: the app's own foreground/background state, which drives presence (auto-away). Read here
    /// rather than in a screen because it must apply with no screen open.
    @Environment(\.scenePhase) private var scenePhase

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
    /// T34: the app-level owner of the channel panes — one post-list model per open channel (bounded
    /// LRU) and one attachment cache per server, fed by the same rail socket as the sidebar.
    @StateObject private var channelPaneCoordinator: ChannelPaneCoordinator
    /// T36: the app-level owner of the thread panes and the Threads list — one thread model per open
    /// root (bounded LRU), one global list per team, and the reply composer of each open thread. Owned
    /// here for the same two reasons as the channel panes: SwiftUI re-creates views, and the thread
    /// events arrive on the rail's single socket. It also carries a reply's new count back to the
    /// channel model that draws the root row, which is why it holds a reference to the channel panes.
    @StateObject private var threadCoordinator: ThreadCoordinator
    /// T39: the search / saved / pinned owner (one model per server+team, fed by the rail's socket).
    @StateObject private var searchCoordinator: SearchCoordinator
    /// T40: the channel-info owner — one info model per open channel (bounded LRU) and one channel
    /// browser per team, fed by the same rail socket. Owned here for the same two reasons as the channel
    /// panes: SwiftUI re-creates views on every sheet presentation, and `user_added` / `user_removed` /
    /// `channel_updated` arrive on the rail's single socket, which a view cannot subscribe to.
    @StateObject private var channelInfoCoordinator: ChannelInfoCoordinator
    /// T41: the profile owner — one model per (server, user) with a bounded LRU, the per-server presence
    /// memory, and the auto-away pass. Owned here because the profile sheet is re-created on every
    /// presentation, `status_change` / `user_updated` arrive on the rail's single socket, and auto-away
    /// has to happen with no profile open at all.
    @StateObject private var profileCoordinator: ProfileCoordinator
    /// T42: the activity feed's owner — one mentions model per server (the window is cross-team, so
    /// there is no team key), fed by the rail's single socket, and the one object that hands the
    /// server's counters to `SessionStore`. Owned here because a tab switch re-creates the view and
    /// because a `posted` frame arrives on a socket no view owns.
    @StateObject private var activityCoordinator: ActivityCoordinator
    /// T43: the mention-input switch (which of the two inputs is live). Owned here because Settings reads
    /// it, the shell writes it and the gate must be one object for the process.
    @StateObject private var notificationPath: NotificationPathStore
    /// T43: the native mention input — socket `posted` → policy → `NotificationWorker`, with the ledger and
    /// the badge hand-off. Owned here for the same reason every coordinator above is: it is fed by the
    /// rail's single socket, which no view can subscribe to, and it must outlive a view re-creation.
    @StateObject private var notificationFeed: NativeNotificationFeed
    /// T44d: the calls surface's owner — the "is there a call here" fact the channel header renders,
    /// and the one live call's model. App-scoped because a rotation, a channel switch or a sheet must
    /// not drop a call, and because the transport it uses is the rail's single socket per server.
    @StateObject private var callsCoordinator: CallsCoordinator

    /// T43: keeps `NotificationInputRouting.shared` on the store's mode when the debug switch changes at
    /// runtime (the Settings row) without a relaunch.
    @State private var notificationPathCancellable: AnyCancellable?

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
        // UI-test seam: `-uiTestLogLevel <desktop level>` (error/warn/info/verbose) raises the `os_log`
        // floor for a test run.
        //
        // Why: the simulator's tracing layer quarantines a *process* whose log volume is high, and
        // once quarantined the next `os_log` taken during an accessibility snapshot faults through
        // XCTest's `runtime_issue_os_log_fault_callback`, which dereferences a NULL — SIGSEGV — in
        // **the app under test** (`docs/t8d-build-note.md` §1: the archived reports say
        // `Mattermost`, faulting thread 0, `_platform_strcmp` ← `runtime_issue_os_log_fault_callback`
        // ← `__LIBTRACE_CLIENT_QUARANTINED_DUE_TO_HIGH_LOGGING_VOLUME__`, and `launchd_sim` logs
        // `exited due to SIGSEGV` for the app; the earlier note here said "the test process", which
        // the reports contradict — the runner can die separately but is not what this class kills).
        //
        // What this seam can and cannot do: T8d measured a single 8-test batch at **79.5 MB** of app
        // log, of which **78 %** is XCUITest's own accessibility serialiser (`com.apple.dt.xctest`,
        // running inside this process) and ~0.1 % is `Logger`. So this gate — which only filters
        // `Logger` — is correct to keep (it is the app's desktop log-level setting anyway) but it
        // does not address the trigger. The volume is cut where it is produced: a smaller
        // accessibility tree (decorative glyphs hidden) and type-scoped/fewer XCUITest queries in
        // the suites, not by turning app logging off.
        if let idx = args.firstIndex(of: "-uiTestLogLevel"), args.indices.contains(idx + 1) {
            Logger.setMinimumLevel(args[idx + 1])
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
        // The shell opens where the reader left off, so the destination outlives the process.
        navigation.lastChannels = LastChannelStore()
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
        // T34: the channel panes' owner. Its `auth`/`navigation` seams are bound in
        // `bindShellStores()` for the same `@StateObject` reason as the four above.
        _channelPaneCoordinator = StateObject(wrappedValue: ChannelPaneCoordinator())
        // T36: the thread panes' and Threads list's owner, bound in `bindShellStores()` like the rest.
        _threadCoordinator = StateObject(wrappedValue: ThreadCoordinator())
        // T39: the search / saved / pinned owner. Its seams are bound in `bindShellStores()` for the
        // same `@StateObject` reason as the five above, and it is fed by the rail's one socket.
        _searchCoordinator = StateObject(wrappedValue: SearchCoordinator())
        // T40: the channel-info and channel-browser owner, bound in `bindShellStores()` like the rest.
        _channelInfoCoordinator = StateObject(wrappedValue: ChannelInfoCoordinator())
        _profileCoordinator = StateObject(wrappedValue: {
            let coordinator = ProfileCoordinator()
            #if DEBUG
            // UI-test seam: `-uiTestProfilePresenceInterval <seconds>` sets how often an open profile
            // re-reads presence. The live socket test holds its status-change window well under this,
            // so a green socket assertion cannot be a poll that happened to fire at the right moment.
            if let idx = args.firstIndex(of: "-uiTestProfilePresenceInterval"),
               args.indices.contains(idx + 1),
               let seconds = Double(args[idx + 1]) {
                coordinator.presenceInterval = seconds
            }
            #endif
            return coordinator
        }())
        // T42: the activity feed's owner, bound in `bindShellStores()` like the rest.
        _activityCoordinator = StateObject(wrappedValue: ActivityCoordinator())
        // T43: the mention-input switch and the native input that reads the rail's socket. Both are built
        // here so the gate, the Settings read-out and the feed are the same objects the views see; their
        // store seams are bound in `bindShellStores()`.
        _notificationPath = StateObject(wrappedValue: NotificationPathStore())
        _notificationFeed = StateObject(wrappedValue: NativeNotificationFeed())
        // T44d: the calls surface's owner, bound in `bindShellStores()` like the rest.
        _callsCoordinator = StateObject(wrappedValue: CallsCoordinator())
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
            RootView(serverStore: serverStore, viewStore: viewStore,
                     notificationPath: notificationPath, notificationFeed: notificationFeed)
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
                // T34: the channel panes' owner is app-wide for the same reason (a pane must outlive
                // the view that shows it, and it is fed by the rail's socket).
                .environmentObject(channelPaneCoordinator)
                // T36: the thread panes' and Threads list's owner — same reason, and it has to be the
                // object that sees the rail's socket so a thread updates while it is open.
                .environmentObject(threadCoordinator)
                // T39: the search / saved / pinned owner — app-wide for the same reasons (a tab switch
                // must not lose a result set, and the saved list is patched by the rail's socket).
                .environmentObject(searchCoordinator)
                // T40: the channel-info and channel-browser owner — app-wide for the same reasons (a
                // sheet re-presentation must not lose a member list, and membership changes are patched
                // by the rail's socket).
                .environmentObject(channelInfoCoordinator)
                // T41: the profile owner — app-wide for the same reasons, plus auto-away: it has to act
                // on the app's background/foreground transitions whether or not a profile is open.
                .environmentObject(profileCoordinator)
                // T42: the activity feed's owner — app-wide for the same reasons (a tab switch must not
                // lose the window, and it is fed by the rail's socket).
                .environmentObject(activityCoordinator)
                // T43: the mention-input switch (Settings reads it, and the diagnostics row shows which
                // input is live) and the native input's own read-out (last mention, delivered/dropped).
                .environmentObject(notificationPath)
                .environmentObject(notificationFeed)
                .environmentObject(callsCoordinator)
                // T31: the SSO hand-off mounts the server's existing webview inside a sheet, so the
                // store owner has to be reachable from the environment too (the pane's web branch
                // still receives it as a parameter).
                .environmentObject(viewStore)
                // T30 debug-only screenshot probe: force one appearance / text size per capture.
                // Inert (and never touches the user's own Dynamic Type) unless the probe is running.
                .modifier(NativeShellSnapshotEnvironment(scheme: snapshotColorScheme,
                                                          typeSize: snapshotDynamicTypeSize))
                // T41: presence follows the app's lifecycle. Backgrounding ages a server-derived
                // `online` to `away`; coming back puts the reader's own status back. The decision is
                // pure (`AutoAwayRule`); this is only the trigger, and it is app-level because presence
                // is not a screen's business.
                //
                // Only `.background` ages, never `.inactive`: the latter fires for the app switcher, a
                // system prompt or a Control Centre swipe, and ageing on those would tell colleagues a
                // reader is away because they glanced at their notifications.
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active || phase == .background else { return }
                    let servers = serverStore.servers
                    Task { await profileCoordinator.sceneChanged(isActive: phase == .active,
                                                                 servers: servers) }
                }
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
                    //
                    // A server whose login lives **only** in the webview (the SPA's own sign-in, or
                    // SSO/SAML) is adopted inside `restore` — see `adoptExistingWebSessionIfPresent`.
                    // The DEBUG cookie seam below runs first so a run can start in exactly that state.
                    #if DEBUG
                    await seedWebviewSessionCookieIfRequested()
                    #endif
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
        // T93B follow-up (`t_065c8753`): the escape hatch hands the pane back to the webview, so the
        // store that branch renders has to exist **before** the branch mounts. Creating it from inside
        // the mount publishes store membership (`storeGeneration`) in the very SwiftUI transaction that
        // swaps `SurfaceHost`'s branch; the enclosing `NavigationStack` then rebuilds its content
        // mid-flip, installs a second `WebViewContainer` for the one webview and destroys the first —
        // and the escape hatch's page ends up blank even though it loaded (`didFinish` fired). This
        // hook runs in the button's own turn instead, so the flip's first body pass already has the
        // store and nothing publishes during the swap.
        let wiredServerStore = serverStore
        let wiredViewStore = viewStore
        surfaceModeResolver.willForceWeb = { surface in
            guard surface == SurfaceDefaults.paneHostSurface else { return }
            let activeID = wiredViewStore.primaryServerID ?? wiredServerStore.initialServer?.id
            guard let activeID,
                  let server = wiredServerStore.servers.first(where: { $0.id == activeID })
            else { return }
            _ = wiredViewStore.ensureStore(for: server)
        }
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
        // T34: the channel panes read the same location and resolve their service from the same
        // session; nothing here opens a socket of its own.
        channelPaneCoordinator.bind(auth: authCoordinator,
                                    navigation: nativeNavigation,
                                    serverStore: serverStore)
        // T36: the thread panes resolve their service from the same session, and hold the channel
        // panes so a reply's count reaches the row it belongs to. No socket of its own.
        threadCoordinator.bind(auth: authCoordinator,
                               navigation: nativeNavigation,
                               serverStore: serverStore,
                               channelPanes: channelPaneCoordinator)
        // T39: the search / saved / pinned models resolve their service from the same session and are
        // fed by the rail's socket; nothing here opens a socket of its own.
        searchCoordinator.bind(auth: authCoordinator, serverStore: serverStore)
        // T40: the channel-info models and the channel browser resolve their service from the same
        // session and are fed by the rail's socket (a member added from another device must appear).
        channelInfoCoordinator.bind(auth: authCoordinator,
                                    navigation: nativeNavigation,
                                    serverStore: serverStore)
        // T41: the profile models, the presence memory and the auto-away pass resolve their service
        // from the same session and are fed by the rail's socket (a colleague's status, a custom status
        // set from another client).
        profileCoordinator.bind(auth: authCoordinator, serverStore: serverStore)
        // T42: the activity feed resolves its service from the same session, is fed by the rail's socket,
        // and hands the server's own counters to `SessionStore` (the badge's single source of truth).
        activityCoordinator.bind(auth: authCoordinator,
                                 serverStore: serverStore,
                                 sessionStore: sessionStore)
        // T43: the native mention input. It resolves the same session every other native service does
        // (per call, so a service built before the session restored is not permanently signed out), is fed
        // by the rail's single socket below, and shares **one** high-water mark with the T14 poller.
        notificationFeed.bind(serverStore: serverStore, sessionStore: sessionStore)
        // T44d: the calls surface resolves its service from the same session, sends and reads on the
        // rail's **one** socket per server (never a second connection), and is fed by the rail below.
        callsCoordinator.bind(auth: authCoordinator, serverStore: serverStore)
        callsCoordinator.transportProvider = { [weak teamSidebarCoordinator] server in
            guard let teamSidebarCoordinator else { return nil }
            return await teamSidebarCoordinator.callsTransport(for: server)
        }
        notificationFeed.serviceFactory = { [weak authCoordinator] server in
            SessionActivityService {
                guard let authCoordinator,
                      let session = try? authCoordinator.session(for: server) else { return nil }
                return session.client
            }
        }
        // One ledger object for both inputs: the poller merges what it notified into it, the socket records
        // what it handled, and neither can deliver the other's mention a second time.
        MentionPoller.shared.ledger = notificationFeed.ledger
        // The gate the webview consults before it delivers a `notify_mention` frame. One mode per process,
        // kept in step with the store so the Settings row and a `-notificationPath` launch flag both land
        // on the same object.
        NotificationInputRouting.shared.setMode(notificationPath.mode)
        notificationPathCancellable = notificationPath.$mode
            .removeDuplicates()
            .sink { mode in NotificationInputRouting.shared.setMode(mode) }
        // The worker's foreground rule compares the channel on screen, when the shell can say which one it
        // is. A webview-rendered pane answers `.unknown`, which keeps T8's whole-server rule for Path A.
        notificationWorker.visibleChannel = { [weak nativeNavigation] serverID -> VisibleChannel in
            guard let nativeNavigation, nativeNavigation.acceptsNativeRouting else { return .unknown }
            let location = nativeNavigation.location
            guard location.serverID == serverID else { return .noChannel }
            guard let channelID = location.channelID, !channelID.isEmpty else { return .noChannel }
            return .channel(channelID)
        }
        teamSidebarCoordinator.onTeamEvent = { [weak channelSidebarCoordinator, weak channelPaneCoordinator,
                                                weak threadCoordinator, weak searchCoordinator,
                                                weak channelInfoCoordinator,
                                                weak profileCoordinator,
                                                weak activityCoordinator,
                                                weak callsCoordinator] serverID, event in
            // T33's list debounces its own refresh; T34's open channels apply the event directly (a
            // posted message must appear without a refetch — that is what a socket is for).
            Task { await channelPaneCoordinator?.handle(event, serverID: serverID) }
            // T36: an open thread and the Threads list apply the thread_* events on the same pass.
            Task { await threadCoordinator?.handle(event, serverID: serverID) }
            // T39: the saved/pinned lists are live (a preference change or a pin from another client).
            Task { @MainActor in searchCoordinator?.handle(event, serverID: serverID) }
            // T40: an open channel-info screen is live (a member added or removed elsewhere, a rename,
            // an archive).
            Task { @MainActor in channelInfoCoordinator?.handle(event, serverID: serverID) }
            // T41: presence and profile updates are live (a colleague's status dot, a custom status set
            // from another client — the server publishes `user_updated` for it).
            Task { @MainActor in profileCoordinator?.handle(event, serverID: serverID) }
            // T42: an open mentions feed inserts a mention that arrives while it is on screen, and follows
            // read state that moved in another client of mine.
            Task { @MainActor in activityCoordinator?.handle(event, serverID: serverID) }
            // T44d: a Calls frame names a channel, not a team — it is accepted by the scope (`.plugin`)
            // and lands here so the header's join button can react to `call_state` / `call_end`. The
            // REST check on pane appearance is what makes the button appear in the first place.
            Task { @MainActor in callsCoordinator?.handle(event, serverID: serverID) }
            guard let channelSidebarCoordinator else { return }
            Task { await channelSidebarCoordinator.handle(event, serverID: serverID) }
        }
        // T34-R5: a socket that dropped and came back missed whatever the server published while it was
        // down — the server does not replay it on the new connection, so without this the miss is
        // permanent until relaunch (measured: a `posted` that reached no pane in five of eight T34-R5
        // runs; the rail's `SocketClient` had carried a `resync` seam nothing passed).
        //
        // Only the channel pane resyncs today: it is the surface T34 owns the window of, and
        // `ChannelViewModel.resyncAfterReconnect` is the merge rule that keeps a reader's older pages.
        // The thread pane, the mentions feed and channel info still repair only on their next appearance
        // — a documented limit (docs/parity.md, T34 row) rather than a claim that they are live-correct.
        teamSidebarCoordinator.onSocketResync = { [weak channelPaneCoordinator] serverID in
            Task { await channelPaneCoordinator?.resync(serverID: serverID) }
        }
        // T34-R5 follow-up: the delivery watchdog (`SocketClient.StallWatchdog`) has to know whether
        // anybody is looking at data this socket feeds, because a socket that is open, pingable and
        // silent is only a *fault* when a reader is staring at the stale window it should be updating.
        // The shell answers with the facts it owns: the app is in the foreground, the location names a
        // channel on **this** server, the native pane is the one rendering it, and that pane holds a
        // loaded window for it. Anything else answers `false`, which keeps the watchdog from spending a
        // page fetch on an idle-but-healthy socket — the limit the card asks for.
        teamSidebarCoordinator.isSurfaceVisible = { [weak nativeNavigation, weak channelPaneCoordinator] serverID in
            guard UIApplication.shared.applicationState == .active else { return false }
            guard let nativeNavigation, nativeNavigation.acceptsNativeRouting else { return false }
            let location = nativeNavigation.location
            guard location.serverID == serverID,
                  let channelID = location.channelID, !channelID.isEmpty else { return false }
            return channelPaneCoordinator?.hasLoadedWindow(serverID: serverID, channelID: channelID) ?? false
        }
        // T30 reserved this seam for S08: with a channel list loaded, a deep link's channel *name*
        // and a tapped mention's channel *id* resolve to the same `NativeLocation`.
        nativeNavigation.directory = channelSidebarCoordinator
        // T43: the rail's socket is the **one** socket per server, so the native mention input reads that
        // same stream — and it reads it *before* the team scope, because a mention in another team is still
        // a mention of the reader (`onTeamEvent` below would drop exactly those).
        teamSidebarCoordinator.onServerEvent = { [weak notificationFeed, weak serverStore] serverID, event in
            guard let server = serverStore?.servers.first(where: { $0.id == serverID }) else { return }
            Task { @MainActor in
                await notificationFeed?.handle(event, server: server)
            }
        }
        // T43: and it learns which servers' sockets are live, which is what makes the bridge refuse (and
        // therefore what makes a dual-render run produce one banner, not two).
        teamSidebarCoordinator.onSocketStateChange = { [weak notificationFeed] serverID, live in
            notificationFeed?.socketStateChanged(serverID: serverID, live: live)
        }
        authCoordinator.onChange = { [weak nativeNavigation, weak teamSidebarCoordinator,
                                      weak channelSidebarCoordinator, weak channelPaneCoordinator,
                                      weak threadCoordinator, weak searchCoordinator,
                                      weak channelInfoCoordinator,
                                      weak profileCoordinator] serverID in
            nativeNavigation?.refreshAuthState()
            // A sign-out/expiry must take the rail's socket down with the credential it was built
            // with; a finished sign-in is what lets it come up.
            teamSidebarCoordinator?.authPhaseChanged(serverID)
            // …and the channel list (and its channel→team map) must not outlive that credential.
            channelSidebarCoordinator?.authPhaseChanged(serverID)
            // …and neither must an open channel's window: its posts were fetched with that session.
            channelPaneCoordinator?.authPhaseChanged(serverID)
            // …and a thread's window and its drafts were fetched with that credential too.
            threadCoordinator?.authPhaseChanged(serverID)
            // …and so were a team's search results and its saved/pinned lists (T39).
            searchCoordinator?.authPhaseChanged(serverID)
            // …and a channel's info screen and its member list (T40): those rows were fetched with it.
            channelInfoCoordinator?.authPhaseChanged(serverID)
            // …and the profiles, the presence memory and any auto-away bookkeeping (T41).
            profileCoordinator?.authPhaseChanged(serverID)
            // …and the mentions window, which was fetched with that credential (T42).
            activityCoordinator.authPhaseChanged(serverID)
            // …and the mention input's cached profile keys and channel rows (T43).
            notificationFeed.authPhaseChanged(serverID)
            // …and any live call on that server, plus the "is there a call here" facts and the
            // plugin build remembered for it (T44d): a new session must re-ask the server.
            callsCoordinator.authPhaseChanged(serverID)
        }
    }

    #if DEBUG
    /// `-uiTestSeedWebSessionCookie <token>`: plant an `MMAUTHTOKEN` in the **seeded** server's
    /// isolated website-data store — the copy a *webview* sign-in leaves behind — so a run can start
    /// in the one state this card is about: the webview is signed in and the vault holds nothing.
    ///
    /// Why a seam instead of a real web login in the test: `WKWebsiteDataStore(forIdentifier:)` is
    /// container-scoped, so an XCUITest runner writing it would populate a *different* container's
    /// store than the app reads. Driving the SPA's login form in the webview instead would make the
    /// evidence depend on the web app's markup, which is exactly the thing this shell does not own.
    ///
    /// Debug-only and inert in Release, exactly like `-uiTestSeedStoredToken` (which writes the same
    /// kind of credential into the vault). It never logs the value, and it writes nothing unless both
    /// the argument and a seeded server are present.
    @MainActor
    private func seedWebviewSessionCookieIfRequested() async {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "-uiTestSeedWebSessionCookie"),
              args.indices.contains(idx + 1),
              !args[idx + 1].isEmpty,
              let server = serverStore.servers.last,
              let host = server.url.host, !host.isEmpty,
              let cookie = HTTPCookie(properties: [
                  .name: SessionCookiePolicy.authCookieName,
                  .value: args[idx + 1],
                  .domain: host,
                  .path: "/",
                  .expires: Date().addingTimeInterval(3600),
              ])
        else { return }
        // The store `ViewStore.ensureStore(for:)` gives the server's webview, so the reader the
        // auth coordinator uses at launch reads exactly what a webview login would have written.
        await WKWebsiteDataStore(forIdentifier: server.id).httpCookieStore.setCookie(cookie)
        Logger.info("T31", "uiTest: planted a webview session cookie for \(server.name)")
    }

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

            // A native pane has no web content, and this probe used to return before writing
            // anything when no store had committed — which made every native run look like a
            // silent failure. Capture the window and the surface map first, unconditionally.
            let earlyWindows = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.windows }.joined()
            let surfacesLine = Surface.allCases
                .map { "\($0.rawValue):\(surfaceModeResolver.resolvedMode(for: $0).rawValue)" }
                .joined(separator: ",")
            if let window = earlyWindows.first(where: \.isKeyWindow) ?? earlyWindows.first {
                let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
                let image = renderer.image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                try? image.pngData()?.write(to: URL(fileURLWithPath: path + ".window.png"))
            }

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
            guard let store = target else {
                let nativeDiag = """
                url=nil (no committed webview: the pane is native)
                debugAffordances=\(SurfaceModeResolver.debugAffordancesEnabled)
                arguments=\(ProcessInfo.processInfo.arguments.joined(separator: " "))
                location=\(String(describing: nativeNavigation.location))
                surfaces=\(surfacesLine)
                sidebar=\(serverStore.servers.map { channelSidebarCoordinator.diagnosticSummary(for: $0) }.joined(separator: " | "))
                auth=\(serverStore.servers.map { "\($0.name):\(String(describing: authCoordinator.phase(for: $0))):token=\(authCoordinator.hasStoredToken(for: $0))" }.joined(separator: ","))
                """
                try? nativeDiag.write(to: URL(fileURLWithPath: path + ".txt"), atomically: true, encoding: .utf8)
                // The early capture above is five seconds in, before channels and posts exist. Take a
                // second one here, after the pane has had its time, so the image and the state agree.
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                let settled = UIApplication.shared.connectedScenes
                    .compactMap { ($0 as? UIWindowScene)?.windows }.joined()
                if let window = settled.first(where: \.isKeyWindow) ?? settled.first {
                    let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
                    let image = renderer.image { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    }
                    try? image.pngData()?.write(to: URL(fileURLWithPath: path + ".late.png"))
                    let lateState = """
                    location=\(String(describing: nativeNavigation.location))
                    sidebar=\(serverStore.servers.map { channelSidebarCoordinator.diagnosticSummary(for: $0) }.joined(separator: " | "))
                    """
                    try? lateState.write(to: URL(fileURLWithPath: path + ".late.txt"),
                                         atomically: true, encoding: .utf8)
                }
                return
            }

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
            debugAffordances=\(SurfaceModeResolver.debugAffordancesEnabled)
            arguments=\(ProcessInfo.processInfo.arguments.joined(separator: " "))
            surfaces=\(Surface.allCases.map { "\($0.rawValue):\(surfaceModeResolver.resolvedMode(for: $0).rawValue)" }.joined(separator: ","))
            """
            try? diag.write(to: URL(fileURLWithPath: path + ".txt"), atomically: true, encoding: .utf8)

            // Window snapshot first: with a native pane there is no web content to snapshot, and the
            // window is the only evidence of what the native branch actually draws.
            let scenes = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.windows }.joined()
            if let window = scenes.first(where: \.isKeyWindow) ?? scenes.first {
                let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
                let image = renderer.image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                try? image.pngData()?.write(to: URL(fileURLWithPath: path + ".window.png"))
            }

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
