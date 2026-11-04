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
    /// T54: the app's one in-app mention banner slot (inventory S25). App-scoped because a mention can
    /// arrive while any screen — or none — is on screen, and `RootView` mounts the slot above the whole
    /// navigation stack; it holds at most the banner currently visible, never a notification ledger.
    @StateObject private var mentionBanner: InAppMentionBannerCenter
    /// T44d: the calls surface's owner — the "is there a call here" fact the channel header renders,
    /// and the one live call's model. App-scoped because a rotation, a channel switch or a sheet must
    /// not drop a call, and because the transport it uses is the rail's single socket per server.
    @StateObject private var callsCoordinator: CallsCoordinator

    /// T43: keeps `NotificationInputRouting.shared` on the store's debug override when it changes at
    /// runtime (the Settings row) without a relaunch. `nil` — the shipped state — leaves the input
    /// derived from the pane that is rendering.
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
        // T54: the one in-app banner slot. Created here (not in a view) because a mention can arrive while
        // no shell view is on screen — a pushed channel, a sheet, a background fetch finishing as the app
        // foregrounds — and `RootView` mounts the slot over the whole navigation stack. Its `onOpen` funnel
        // is bound in `bindShellStores()` for the same `@StateObject` reason as every other owner here.
        _mentionBanner = StateObject(wrappedValue: {
            let center = InAppMentionBannerCenter()
            #if DEBUG
            // UI-test seam: `-uiTestBannerDuration <seconds>` widens (or shortens) how long a banner stays.
            // A live test has to interact with the banner — type into the composer, then tap it — and the
            // shipping six seconds are not a reliable window on a loaded simulator. The bound itself is
            // unit-tested (`testTheBannerHidesItselfAfterABoundedTime`); this only moves the window.
            if let idx = args.firstIndex(of: "-uiTestBannerDuration"),
               args.indices.contains(idx + 1),
               let seconds = Double(args[idx + 1]) {
                center.visibleDuration = seconds
            }
            #endif
            return center
        }())
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
                // T54: the one in-app banner slot; `RootView` mounts it over the whole navigation stack.
                .environmentObject(mentionBanner)
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
                    // The DEBUG session seam below arms first so a run can start in exactly that state.
                    #if DEBUG
                    seedWebviewSessionIfRequested()
                    #endif
                    await authCoordinator.restoreAll(serverStore.servers)
                }
                .task { runShellSnapshotIfRequested() }
                // T1617 evidence probe: `-threadBackSnapshot <dir> -threadBackTarget <channel>,<root>`
                // photographs the thread pane and the screen its leading control returns to, on a
                // Release product (outside `#if DEBUG` on purpose). Inert without the arguments.
                .task { runThreadBackSnapshotIfRequested() }
                // t_3b2f313a evidence probe: `-sidebarGroupSnapshot <dir>` photographs the native
                // sidebar with one **collapsed** category whose rows are unread, so the group header's
                // bold + dot is visible where the rows are not. Release product (outside `#if DEBUG`
                // on purpose), inert without the argument.
                .task { runSidebarGroupSnapshotIfRequested() }
                // t_8d539b3f evidence probe: `-dmPagingSnapshot <dir>` photographs the Direct
                // messages group's page — 20 rows + the "Load more" row with its remaining count —
                // and what one/two activations do. Release product (outside `#if DEBUG` on purpose),
                // inert without the argument.
                .task { runDMPagingSnapshotIfRequested() }
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
        // T49: the terms-of-service gate's live reader. Wired here, next to the gate itself, so
        // the production app is the object that checks the server; a host that never calls
        // `bindShellStores()` (the unit suites) keeps the pre-T49 behaviour.
        authCoordinator.makeTermsOfService = { _, session in
            ServerTermsOfServiceAPI(session: session)
        }
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
        notificationFeed.bind(serverStore: serverStore, sessionStore: sessionStore, viewStore: viewStore)
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
        // The gate the webview consults before it delivers a `notify_mention` frame, and the feed
        // before it acts on a `posted` event. Which input is live is **derived per server from the pane
        // that is rendering** (`NotificationInputGate.mode(for:)`); the store contributes only the
        // debug override, which a Release build never has (`t_ba355551` — shipping `.bridge` as a
        // constant left a native Release workspace with no input at all).
        NotificationInputRouting.shared.setOverride(notificationPath.overrideMode)
        notificationPathCancellable = notificationPath.$overrideMode
            .removeDuplicates()
            .sink { mode in NotificationInputRouting.shared.setOverride(mode) }
        // The worker's foreground rule compares the channel on screen, when the shell can say which one it
        // is. A webview-rendered pane answers `.unknown`, which keeps T8's whole-server rule for Path A.
        let visibleChannel: (UUID) -> VisibleChannel = { [weak nativeNavigation] serverID -> VisibleChannel in
            guard let nativeNavigation, nativeNavigation.acceptsNativeRouting else { return .unknown }
            let location = nativeNavigation.location
            guard location.serverID == serverID else { return .noChannel }
            guard let channelID = location.channelID, !channelID.isEmpty else { return .noChannel }
            return .channel(channelID)
        }
        notificationWorker.visibleChannel = visibleChannel
        // T54: the in-app banner reads the **same** answer, so the system path and the in-app path cannot
        // disagree about "the conversation the reader is looking at" (that is the whole reason one surface
        // can suppress where the other notifies). The app-active reading is shared the same way.
        let appIsActive: () -> Bool = { UIApplication.shared.applicationState == .active }
        notificationFeed.visibleChannel = visibleChannel
        notificationFeed.isAppActive = appIsActive
        notificationWorker.isAppActive = appIsActive
        notificationFeed.bannerCenter = mentionBanner
        // A banner schedules nothing, but the first-mention permission prompt still has to happen (T8):
        // otherwise an install whose mentions are all foreground would never be authorized, and its first
        // backgrounded mention would be dropped. Same object, same once-per-install rule.
        let worker = notificationWorker
        notificationFeed.askForNotificationPermission = { await worker.prepareAuthorization() }
        // The banner's tap goes through the **same funnel** a system-notification tap uses
        // (`NativeNavigation.routeMention`), post id included, so a banner lands on the message that named
        // the reader — a channel route with the post focused.
        let navigation = nativeNavigation
        mentionBanner.onOpen = { banner in
            navigation.routeMention(serverID: banner.serverID,
                                    channelID: banner.channelID,
                                    teamID: banner.teamID,
                                    postID: banner.postID)
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
        // T34-R5b: three panes now repair on a gap, each with its own **merge** — never a `reload()`,
        // which would blank the reader's list to a spinner and drop the older pages it holds:
        //  * the channel pane's warm windows (`ChannelViewModel.resyncAfterReconnect`);
        //  * the open thread panes and the threads lists (`ThreadCoordinator.resync` →
        //    `ThreadViewModel`/`GlobalThreadsViewModel.resyncAfterGap`);
        //  * the mentions feed (`ActivityCoordinator.resync` → `MentionsViewModel.resyncAfterGap`).
        //
        // Each pane gets **its own `Task`** on purpose: `SocketClient` awaits this handler on its open
        // path, before the receive loop reads the next frame, so the handler must return promptly and
        // never hold the socket up on a page request. Nothing here awaits another pane either — one slow
        // feed must not delay the channel window's repair.
        teamSidebarCoordinator.onSocketResync = { [weak channelPaneCoordinator, weak threadCoordinator,
                                                   weak activityCoordinator] serverID in
            Task { await channelPaneCoordinator?.resync(serverID: serverID) }
            Task { await threadCoordinator?.resync(serverID: serverID) }
            Task { @MainActor in await activityCoordinator?.resync(serverID: serverID) }
        }
        // T34-R5 follow-up: the delivery watchdog (`SocketClient.StallWatchdog`) has to know whether
        // anybody is looking at data this socket feeds, because a socket that is open, pingable and
        // silent is only a *fault* when a reader is staring at the stale window it should be updating.
        // The shell answers with the facts it owns: the app is in the foreground, native routing is on,
        // and the visible surface — the mentions feed, a thread pane, the threads list, or the channel
        // pane — holds a **loaded** window for *this* server. Anything else answers `false`, which keeps
        // the watchdog from spending page fetches on an idle-but-healthy socket.
        //
        // T34-R5b moved the rule into `NativeSurfaceVisibility` so the unit target can exercise it: this
        // closure is now one literal binding, and the rules themselves are tested
        // (`T34LivePaneResyncTests`).
        let surfaceVisibility = NativeSurfaceVisibility(
            appIsActive: { UIApplication.shared.applicationState == .active },
            acceptsNativeRouting: { [weak nativeNavigation] in
                nativeNavigation?.acceptsNativeRouting ?? false
            },
            location: { [weak nativeNavigation] in nativeNavigation?.location ?? NativeLocation() },
            channelWindowLoaded: { [weak channelPaneCoordinator] serverID, channelID in
                channelPaneCoordinator?.hasLoadedWindow(serverID: serverID, channelID: channelID) ?? false
            },
            threadLoaded: { [weak threadCoordinator] serverID, rootID in
                threadCoordinator?.hasLoadedThread(serverID: serverID, rootID: rootID) ?? false
            },
            threadListLoaded: { [weak threadCoordinator] serverID in
                threadCoordinator?.hasLoadedThreadList(serverID: serverID) ?? false
            },
            feedOnScreen: { [weak activityCoordinator] serverID in
                activityCoordinator?.hasLoadedFeedOnScreen(serverID: serverID) ?? false
            })
        teamSidebarCoordinator.isSurfaceVisible = { serverID in
            surfaceVisibility.isVisible(serverID: serverID)
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
    /// `-uiTestSeedWebSessionToken <token>`: make the **webview-held session** exist for the seeded
    /// server, so a run can start in the one state this card is about: the webview is signed in and
    /// the vault holds nothing.
    ///
    /// ## Why a seam, and why it arms the harvest's reader rather than writing a cookie
    ///
    /// A seam is needed because the state under test is a session in **WebKit's** store: the test
    /// runner cannot write it (`WKWebsiteDataStore(forIdentifier:)` is container-scoped), and
    /// driving the SPA's login form in the webview would make the evidence depend on the web app's
    /// markup, which is exactly the thing this shell does not own.
    ///
    /// The first version of this seam did write the real `MMAUTHTOKEN` into
    /// `WKWebsiteDataStore(forIdentifier: server.id)`. Two measurements (2026-11-04, iPhone 16 Pro /
    /// iOS 18.3.1, `http://127.0.0.1:8065`, `t_4528b67e`) retired that approach:
    ///
    ///  1. **the write was silently dropped.** A store's WebKit *Networking* process is launched
    ///     lazily at first use, and a `setCookie` issued while it comes up completes and keeps
    ///     nothing: `allCookies()` answered `[]` immediately *and* `[]` two seconds later, while the
    ///     same write issued once the process was up stayed (`["MMAUTHTOKEN@127.0.0.1"]`) and the
    ///     harvest then adopted it ("signed in as perfprobe", "adopted the webview session"). That is
    ///     why the T31 suite was red for four runs: its session never existed, so the launch resolved
    ///     as signed out and the native sign-in surface appeared. `WebSessionCookieInstaller` now
    ///     read-back-verifies such writes (and `WebFallbackModel`'s T46 install uses it), but for a
    ///     launch seam it is still a WebKit process launch in the middle of a UI run;
    ///  2. **and that process launch kills the app under XCUITest on this host.** When it takes more
    ///     than a second, WebKit records it with `RELEASE_LOG_FAULT("Networking process … took N
    ///     seconds to launch")`; a fault-level `os_log` taken while XCTest is snapshotting
    ///     dereferences NULL in XCTest's own `runtime_issue_os_log_fault_callback`, and the app dies
    ///     with `SIGSEGV` in `_platform_strcmp` (`Mattermost-2026-11-04-063031.ips` — the failure
    ///     that replaced the assertion failure once the installer landed). It is the host pathology
    ///     `docs/t8d-build-note.md` §1 and `docs/t635-build-note.md` describe: less log volume shrinks
    ///     it, nothing in the app removes it.
    ///
    /// So this seam substitutes the **delivery** of the webview's session, not its handling — the
    /// same choice `-uiTestOpenDeepLink` makes for a URL XCUITest cannot hand to the app. What the
    /// suite then measures is unchanged and entirely production code: `AuthCoordinator.restore` with
    /// no vault token, the harvest (`adoptWebSession`), the `GET /users/me` verification, the vault
    /// write, the gate and every native pane that authenticates from it. The reader that answers is
    /// `SeededWebSessionCookieReader`; the real WebKit read is pinned by unit tests against a real
    /// store (`T31WebSessionHarvestTests.testTheProductionReaderFindsTheSessionInTheServersOwnWebsiteDataStore`,
    /// `T31HarvestCookieInstallTests.testARealStoreKeepsTheInstalledCookieAndTheProductionReaderFindsIt`).
    ///
    /// Debug-only and inert in Release, exactly like `-uiTestSeedStoredToken` (which writes the same
    /// kind of credential into the vault). It logs no value and seeds nothing unless both the
    /// argument and a seeded server are present.
    @MainActor
    private func seedWebviewSessionIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "-uiTestSeedWebSessionToken"),
              args.indices.contains(idx + 1),
              !args[idx + 1].isEmpty,
              let server = serverStore.servers.last
        else { return }
        authCoordinator.seedWebSession(token: args[idx + 1], for: server.id)
        Logger.info("T31", "uiTest: the webview holds a session for \(server.name)")
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
            // T45 extended this list: the card's criterion is Dynamic Type "up to
            // AX5", so the evidence set is the shell at each accessibility size
            // (AX1, AX3, AX5) plus dark mode at the size the criterion names.
            // `large` stays first and keeps its name so the existing T30/T31
            // captures and their notes still resolve.
            let captures: [(String, SwiftUI.ColorScheme, DynamicTypeSize)] = [
                ("light", .light, .large),
                ("dark", .dark, .large),
                ("light-ax1", .light, .accessibility1),
                ("light-ax3", .light, .accessibility3),
                ("light-ax5", .light, .accessibility5),
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
                channels=\(serverStore.servers.map { channelPaneCoordinator.diagnosticSummary(for: $0.id) }.joined(separator: " | "))
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
                    channels=\(serverStore.servers.map { channelPaneCoordinator.diagnosticSummary(for: $0.id) }.joined(separator: " | "))
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

    // MARK: Thread-pane back evidence (T1617 — ships in Release)

    /// Parse `-threadBackSnapshot <dir>` and `-threadBackTarget <channelID>,<rootID>`, or nil.
    private var threadBackProbe: (dir: String, channelID: String, rootID: String)? {
        let args = ProcessInfo.processInfo.arguments
        guard let d = args.firstIndex(of: "-threadBackSnapshot"), args.indices.contains(d + 1),
              let t = args.firstIndex(of: "-threadBackTarget"), args.indices.contains(t + 1)
        else { return nil }
        let parts = args[t + 1].split(separator: ",").map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (args[d + 1], parts[0], parts[1])
    }

    /// Evidence probe for the thread pane's leading control **on a Release product**.
    ///
    /// It opens the channel, opens the thread the way a reply line does, captures the pane, then
    /// calls `closeThread()` — the exact function the `threadPane.back` control calls — and captures
    /// what is on screen afterwards. It exists because the XCUITest bundle cannot run on this host's
    /// Catalyst destination (its generated deployment target, macOS 26.5, is newer than the host,
    /// 26.3.1), so a Release screenshot cannot come from a test. The behaviour itself is covered by
    /// `MattermostTests/NativeNavigationTests` and `MattermostUITests/T36ThreadsUITests`; this only
    /// photographs it. Inert without the two arguments.
    private func runThreadBackSnapshotIfRequested() {
        guard let probe = threadBackProbe else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let serverID = serverStore.activeServerID ?? serverStore.servers.first?.id else {
                writeThreadBackNote(probe.dir + "/back.txt", ["error": "no server"])
                return
            }

            nativeNavigation.openChannel(NativeChannelRequest(serverID: serverID, channelID: probe.channelID))
            try? await Task.sleep(nanoseconds: 8_000_000_000)

            nativeNavigation.openThreads(NativeChannelRequest(serverID: serverID,
                                                             channelID: probe.channelID,
                                                             postID: probe.rootID))
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            writeWindowSnapshot(to: probe.dir + "/thread.png")
            writeThreadBackNote(probe.dir + "/thread.txt", [
                "pane": "\(nativeNavigation.location.pane)",
                "post": nativeNavigation.location.postID ?? "none",
                "channel": nativeNavigation.location.channelID ?? "none",
                "entry": "\(String(describing: nativeNavigation.threadEntryPoint))",
                "path": "\(nativeNavigation.path.count)",
            ])

            nativeNavigation.closeThread()
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            writeWindowSnapshot(to: probe.dir + "/back.png")
            writeThreadBackNote(probe.dir + "/back.txt", [
                "pane": "\(nativeNavigation.location.pane)",
                "post": nativeNavigation.location.postID ?? "none",
                "channel": nativeNavigation.location.channelID ?? "none",
                "entry": "\(String(describing: nativeNavigation.threadEntryPoint))",
                "path": "\(nativeNavigation.path.count)",
            ])
        }
    }

    // MARK: Category-header marker evidence (t_3b2f313a — ships in Release)

    /// `-sidebarGroupSnapshot <dir> [-sidebarGroupName <displayName>]`: where the sidebar probe
    /// writes its PNGs + note, and which category to photograph (by default the first unread one).
    private var sidebarGroupProbe: (dir: String, name: String?)? {
        let args = ProcessInfo.processInfo.arguments
        guard let d = args.firstIndex(of: "-sidebarGroupSnapshot"), args.indices.contains(d + 1)
        else { return nil }
        var name: String?
        if let n = args.firstIndex(of: "-sidebarGroupName"), args.indices.contains(n + 1) {
            name = args[n + 1]
        }
        return (args[d + 1], name)
    }

    /// Evidence probe for the category header's unread marker **on a Release product**.
    ///
    /// The XCUITest bundle cannot run on this host's Catalyst destination, so the screenshot of a
    /// collapsed, unread group header cannot come from a test. This waits for the native sidebar to
    /// load, picks the named category (or the first one a row makes unread), collapses it (restoring
    /// the previous state after the capture, so the account's own layout is left as it was), and
    /// photographs the window. It also writes the **facts the marker was drawn from** — the group's
    /// own roll-up — so the picture can be checked against the model rather than trusted. Inert
    /// without the argument, and no `#if DEBUG`: it exists in the shipped configuration.
    private func runSidebarGroupSnapshotIfRequested() {
        guard let probe = sidebarGroupProbe else { return }
        let dir = probe.dir
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let server = serverStore.servers.first(where: { $0.id == serverStore.activeServerID })
                    ?? serverStore.servers.first else {
                writeThreadBackNote(dir + "/sidebar-group.txt", ["error": "no server"])
                return
            }
            let model = channelSidebarCoordinator.model(for: server)
            var waited = 0
            while model.groups.isEmpty && waited < 40 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                waited += 1
            }
            let chosen = probe.name.flatMap { name in
                model.groups.first { $0.displayName.caseInsensitiveCompare(name) == .orderedSame }
            } ?? model.groups.first(where: { $0.hasUnread }) ?? model.groups.first
            guard let group = chosen else {
                writeThreadBackNote(dir + "/sidebar-group.txt", [
                    "error": "no groups",
                    "phase": "\(model.phase)",
                    "team": model.teamID ?? "none",
                ])
                writeWindowSnapshot(to: dir + "/sidebar-group.png")
                return
            }

            let wasCollapsed = model.isCollapsed(categoryID: group.id)
            if !wasCollapsed {
                await model.setCollapsed(true, categoryID: group.id)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            let collapsed = model.isCollapsed(categoryID: group.id)

            writeWindowSnapshot(to: dir + "/sidebar-group.png")
            writeThreadBackNote(dir + "/sidebar-group.txt", [
                "server": server.url.absoluteString,
                "team": model.teamID ?? "none",
                "phase": "\(model.phase)",
                "category": group.identifier,
                "name": group.displayName,
                "wasCollapsed": "\(wasCollapsed)",
                "collapsed": "\(collapsed)",
                "unreadChannels": "\(group.unreadChannels)",
                "mentions": "\(group.mentions)",
                "hasUnread": "\(group.hasUnread)",
                "headerBadge": "\(group.headerBadge)",
                "headerValue": group.accessibilityValue,
                "rows": group.entries.map {
                    "\($0.id):unread=\($0.unreadCount),mentions=\($0.mentionCount),emphasis=\($0.showsUnreadEmphasis)"
                }.joined(separator: " | "),
            ])

            // The chosen category can be below the fold (this account's sidebar is long), and a
            // `LazyVStack` does not build a section it has not scrolled to. Walk the sidebar's own
            // scroll view (the element the UI suites swipe) and capture the column at each step, so
            // the picture of the header is a real scroll position rather than a claim.
            if let scroll = sidebarScrollView(note: dir + "/sidebar-scroll.txt") {
                let limit = max(0, scroll.contentSize.height - scroll.bounds.height)
                var offset: CGFloat = 0
                var step = 0
                while true {
                    scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    writeSidebarCrop(to: String(format: "%@/sidebar-group-%02d.png", dir, step),
                                     of: scroll)
                    step += 1
                    if offset >= limit { break }
                    offset = min(limit, offset + 160)
                }
                scroll.setContentOffset(.zero, animated: false)
                if let handle = FileHandle(forWritingAtPath: dir + "/sidebar-scroll.txt") {
                    handle.seekToEndOfFile()
                    handle.write(Data("steps=\(step)\n".utf8))
                    try? handle.close()
                }
            }

            // Leave the account's layout as it was found.
            if !wasCollapsed {
                await model.setCollapsed(false, categoryID: group.id)
            }

            // Every group's roll-up, so the picture (which shows more than one marked header) can be
            // checked against the model in one place. Read after the layout was restored.
            let lines = model.groups.map { candidate in
                [
                    candidate.identifier,
                    "name=\(candidate.displayName)",
                    "collapsed=\(model.isCollapsed(categoryID: candidate.id))",
                    "unreadChannels=\(candidate.unreadChannels)",
                    "mentions=\(candidate.mentions)",
                    "hasUnread=\(candidate.hasUnread)",
                    "badge=\(candidate.headerBadge)",
                    "value=\(candidate.accessibilityValue)",
                ].joined(separator: "|")
            }
            try? (lines.joined(separator: "\n") + "\n")
                .write(to: URL(fileURLWithPath: dir + "/sidebar-groups.txt"),
                       atomically: true, encoding: .utf8)
        }
    }

    // MARK: Direct-messages page evidence (t_8d539b3f — ships in Release)

    /// `-dmPagingSnapshot <dir>`: where the Direct messages page probe writes its PNGs + notes.
    private var dmPagingProbeDir: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let d = args.firstIndex(of: "-dmPagingSnapshot"), args.indices.contains(d + 1)
        else { return nil }
        return args[d + 1]
    }

    /// Evidence probe for the Direct messages page ("the 20 most recent, then Load more") **on a
    /// Release product**.
    ///
    /// It expands the group if it is collapsed (restoring that at the end, because collapse is
    /// persisted on the server), captures the drawn page, activates the Load more control and
    /// captures again, and writes the **model's own page facts** next to every picture — total rows,
    /// revealed, visible, hidden, the control's identifier and its accessibility value — so the
    /// screenshot can be checked against what it was drawn from instead of trusted.
    ///
    /// Activation goes through the drawn accessibility element first (the real control) and falls
    /// back to the model only if no such element is reachable; which path ran, and whether the page
    /// actually moved, is recorded in the note rather than assumed.
    private func runDMPagingSnapshotIfRequested() {
        guard let dir = dmPagingProbeDir else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let server = serverStore.servers.first(where: { $0.id == serverStore.activeServerID })
                    ?? serverStore.servers.first else {
                writeThreadBackNote(dir + "/dm-paging.txt", ["error": "no server"])
                return
            }
            let model = channelSidebarCoordinator.model(for: server)
            var waited = 0
            while model.groups.isEmpty && waited < 40 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                waited += 1
            }
            guard let direct = model.groups.first(where: { $0.kind == .directMessages }) else {
                writeThreadBackNote(dir + "/dm-paging.txt", [
                    "error": "no direct_messages group",
                    "phase": "\(model.phase)",
                    "groups": model.groups.map { "\($0.displayName)=\($0.entries.count)" }
                        .joined(separator: " | "),
                ])
                writeWindowSnapshot(to: dir + "/dm-paging.png")
                return
            }
            let wasCollapsed = model.isCollapsed(categoryID: direct.id)
            if wasCollapsed {
                await model.setCollapsed(false, categoryID: direct.id)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }

            // Plain values captured once: the local write helper touches no main-actor state, so it
            // cannot trip the isolation checker inside this task.
            let teamName = model.teamID ?? "none"
            let serverURL = server.url.absoluteString
            let writeNote: (String, ChannelSidebarGroup, [String: String]) -> Void = { suffix, group, extra in
                var fields: [String: String] = [
                    "server": serverURL,
                    "team": teamName,
                    "category": group.identifier,
                    "wasCollapsed": "\(wasCollapsed)",
                    "entries": "\(group.entries.count)",
                    "revealed": "\(group.revealed)",
                    "visible": "\(group.visibleEntries.count)",
                    "hidden": "\(group.hiddenCount)",
                    "showsLoadMore": "\(group.showsLoadMore)",
                    "loadMoreIdentifier": group.loadMoreIdentifier,
                    "loadMoreValue": group.showsLoadMore
                        ? ChannelSidebarLoadMoreRow(remaining: group.hiddenCount,
                                                    identifier: group.loadMoreIdentifier) {}.accessibilityValue
                        : "none",
                    "unreadChannels": "\(group.unreadChannels)",
                    "mentions": "\(group.mentions)",
                    "ids": group.visibleEntries.map(\.id).joined(separator: ","),
                ]
                for (key, value) in extra { fields[key] = value }
                writeThreadBackNote(dir + "/dm-paging\(suffix).txt", fields)
            }

            var group = model.groups.first(where: { $0.category.id == direct.id }) ?? direct
            writeNote("", group, [:])
            await captureDirectMessagesPage(dir: dir, suffix: "-01-page")

            // The row only exists in the view tree while the `LazyVStack` has realised it, so put
            // the group's tail (where the control sits) on screen before looking for it.
            if let scroll = sidebarScrollView(note: dir + "/dm-paging-scroll.txt") {
                scroll.setContentOffset(CGPoint(x: 0,
                                                y: max(0, scroll.contentSize.height - scroll.bounds.height)),
                                        animated: false)
                try? await Task.sleep(nanoseconds: 900_000_000)
            }
            let diagnostic = accessibilityDiagnostic(identifier: group.loadMoreIdentifier)
            var activated = await activateLoadMore(identifier: group.loadMoreIdentifier,
                                                   categoryID: group.id,
                                                   model: model)
            group = model.groups.first(where: { $0.category.id == direct.id }) ?? direct
            writeNote("-02-after-one", group, ["activatedVia": activated, "a11y": diagnostic])
            await captureDirectMessagesPage(dir: dir, suffix: "-02-after-one")

            if group.showsLoadMore {
                if let scroll = sidebarScrollView(note: dir + "/dm-paging-scroll.txt") {
                    scroll.setContentOffset(CGPoint(x: 0,
                                                    y: max(0, scroll.contentSize.height - scroll.bounds.height)),
                                            animated: false)
                    try? await Task.sleep(nanoseconds: 900_000_000)
                }
                activated = await activateLoadMore(identifier: group.loadMoreIdentifier,
                                                   categoryID: group.id,
                                                   model: model)
                group = model.groups.first(where: { $0.category.id == direct.id }) ?? direct
                writeNote("-03-after-two", group, ["activatedVia": activated])
                await captureDirectMessagesPage(dir: dir, suffix: "-03-after-two")
            }

            group = model.groups.first(where: { $0.category.id == direct.id }) ?? direct
            writeNote("-04-final", group, [:])

            // Leave the account's layout as it was found: the revealed page is session-only and
            // dies with this launch, but the collapse state is persisted on the server.
            if wasCollapsed {
                await model.setCollapsed(true, categoryID: direct.id)
            }
        }
    }

    /// Activate the drawn Load more control.
    ///
    /// Returns which path ran — `"a11y-element"` (the real control answered and the page moved),
    /// `"model"` (no reachable element, or it did not move the page, so the model call was used) —
    /// so the note states what happened instead of implying a tap that never happened.
    @MainActor
    private func activateLoadMore(identifier: String,
                                  categoryID: String,
                                  model: ChannelListViewModel) async -> String {
        func visibleCount() -> Int {
            model.groups.first(where: { $0.category.id == categoryID })?.visibleEntries.count ?? -1
        }
        let before = visibleCount()
        if let element = accessibleObject(identifier: identifier) {
            // On Catalyst `accessibilityActivate()` is an `NSObject` category method (UIKit's
            // `NSObject (UIAccessibilityAction)`), not a protocol requirement — so it is called
            // directly on the element.
            let answered = element.accessibilityActivate()
            if answered {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if visibleCount() != before { return "a11y-element" }
                model.loadMore(categoryID: categoryID)
                return "a11y-element(no page change) -> model"
            }
        }
        model.loadMore(categoryID: categoryID)
        return "model"
    }

    /// What this process can see of the drawn accessibility tree: how many objects were walked, how
    /// many carry the requested identifier, and which sidebar identifiers are visible at all.
    ///
    /// Written into the note because "the control is in the tree" is exactly the claim a screenshot
    /// cannot make, and because a fallback activation has to say why it fell back.
    @MainActor
    private func accessibilityDiagnostic(identifier: String) -> String {
        var objects = 0
        var matches = 0
        var sidebarIdentifiers: [String] = []
        func walk(_ object: NSObject, depth: Int) {
            guard depth < 40, objects < 50_000 else { return }
            objects += 1
            if let identified = object as? UIAccessibilityIdentification,
               let value = identified.accessibilityIdentifier, !value.isEmpty {
                if value == identifier { matches += 1 }
                if value.hasPrefix("channelSidebar") && sidebarIdentifiers.count < 12 {
                    sidebarIdentifiers.append(value)
                }
            }
            if let view = object as? UIView {
                for child in view.subviews { walk(child, depth: depth + 1) }
                for child in view.accessibilityElements ?? [] {
                    if let node = child as? NSObject { walk(node, depth: depth + 1) }
                }
            }
        }
        let windows = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows }.joined()
        for window in windows { walk(window, depth: 0) }
        return "objects=\(objects) matches=\(matches) sidebarIds="
            + (sidebarIdentifiers.isEmpty ? "none" : sidebarIdentifiers.joined(separator: ","))
    }

    /// The accessibility element drawn with `identifier`, searched through the window's view tree
    /// (views first, then their `accessibilityElements`). SwiftUI's `.accessibilityRepresentation`
    /// gives a row one element; this is how the probe finds the one that actually exists, rather than
    /// assuming an identifier reached the tree.
    @MainActor
    private func accessibleObject(identifier: String) -> NSObject? {
        var visited = 0
        func search(_ object: NSObject, depth: Int) -> NSObject? {
            guard depth < 40, visited < 20_000 else { return nil }
            visited += 1
            if let identified = object as? UIAccessibilityIdentification,
               identified.accessibilityIdentifier == identifier {
                return object
            }
            if let view = object as? UIView {
                for child in view.subviews {
                    if let found = search(child, depth: depth + 1) { return found }
                }
                for child in view.accessibilityElements ?? [] {
                    if let node = child as? NSObject, let found = search(node, depth: depth + 1) {
                        return found
                    }
                }
            }
            return nil
        }
        let windows = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows }.joined()
        for window in windows {
            if let found = search(window, depth: 0) { return found }
        }
        return nil
    }

    /// Capture the Direct messages page: a whole-window shot plus four crops of the sidebar column,
    /// walking up from the bottom (the DM group is the last one, so the control sits at the end of
    /// the list) far enough to include the twenty drawn rows.
    @MainActor
    private func captureDirectMessagesPage(dir: String, suffix: String) async {
        writeWindowSnapshot(to: dir + "/dm-paging\(suffix)-window.png")
        guard let scroll = sidebarScrollView(note: dir + "/dm-paging-scroll.txt") else { return }
        let limit = max(0, scroll.contentSize.height - scroll.bounds.height)
        var offset = limit
        var step = 0
        while step < 4 {
            scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            try? await Task.sleep(nanoseconds: 500_000_000)
            writeSidebarCrop(to: String(format: "%@/dm-paging%@-crop%d.png", dir, suffix, step),
                             of: scroll)
            step += 1
            if offset <= 0 { break }
            offset = max(0, offset - 220)
        }
        scroll.setContentOffset(.zero, animated: false)
    }

    /// The sidebar's own scroll view.
    ///
    /// `channelSidebar.scroll` is a SwiftUI accessibility identifier and reaches the a11y tree, not
    /// the backing `UIScrollView` (measured here: the identifier query found no UIKit scroll view),
    /// so the fallback is a geometric pick — the **narrowest** vertically scrolling view in the
    /// window's left half, which is the channel column. The choice is written to the note so the
    /// capture states which view was walked instead of implying it.
    @MainActor
    private func sidebarScrollView(note: String) -> UIScrollView? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows }.joined()
        func collect(_ view: UIView, into found: inout [UIScrollView]) {
            if let scroll = view as? UIScrollView { found.append(scroll) }
            for subview in view.subviews { collect(subview, into: &found) }
        }
        var candidates: [UIScrollView] = []
        for window in windows { collect(window, into: &candidates) }
        let described = candidates.map {
            "x=\(Int($0.frame.minX)),w=\(Int($0.frame.width)),h=\(Int($0.bounds.height)),content=\(Int($0.contentSize.height)),id=\($0.accessibilityIdentifier ?? "-")"
        }
        let named = candidates.first {
            $0.accessibilityIdentifier == NativeChannelSidebarContent.scrollIdentifier
        }
        let geometric = candidates
            .filter { $0.frame.minX < 0.5 * ($0.window?.bounds.width ?? 0)
                        && $0.contentSize.height > $0.bounds.height
                        && $0.frame.width > 100 }
            .min { $0.frame.width < $1.frame.width }
        let chosen = named ?? geometric
        let text = "chosen=\(chosen.map { "w=\(Int($0.frame.width)),content=\(Int($0.contentSize.height))" } ?? "none")"
            + "\ncandidates=" + described.joined(separator: " | ")
        try? (text + "\n").write(to: URL(fileURLWithPath: note), atomically: true, encoding: .utf8)
        return chosen
    }

    /// The sidebar column as it is drawn, cropped out of a window capture (`drawHierarchy`, so no
    /// Screen Recording permission is needed). The crop is the scroll view's own frame plus a little
    /// headroom, which is where a pinned category header sits.
    @MainActor
    private func writeSidebarCrop(to path: String, of scroll: UIScrollView) {
        guard let window = scroll.window else { return }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let full = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let inWindow = scroll.convert(scroll.bounds, to: window)
        let crop = inWindow.insetBy(dx: -8, dy: -64)
            .intersection(CGRect(origin: .zero, size: window.bounds.size))
        guard !crop.isEmpty, let cg = full.cgImage else { return }
        let scaled = crop.applying(CGAffineTransform(scaleX: full.scale, y: full.scale))
        guard let cropped = cg.cropping(to: scaled) else { return }
        try? UIImage(cgImage: cropped, scale: full.scale, orientation: .up)
            .pngData()?.write(to: URL(fileURLWithPath: path))
    }

    /// `drawHierarchy` renders the native hierarchy, so this works without Screen Recording.
    @MainActor
    private func writeWindowSnapshot(to path: String) {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows }.joined()
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { return }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: URL(fileURLWithPath: path))
    }

    private func writeThreadBackNote(_ path: String, _ fields: [String: String]) {
        let text = fields.keys.sorted().map { "\($0)=\(fields[$0] ?? "none")" }.joined(separator: "\n")
        try? (text + "\n").write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
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
