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

    /// Keeps the Settings Stepper and the live journal in lock-step.
    @State private var historyCapCancellable: AnyCancellable?

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
                .onOpenURL { url in
                    // Deep-link entry point (native counterpart of desktop `second-instance` /
                    // `open-url` → `NavigationManager.openLinkInPrimaryTab`).
                    deepLinkRouter.serverStore = serverStore
                    deepLinkRouter.viewStore = viewStore
                    deepLinkRouter.ready()
                    _ = deepLinkRouter.handle(url)
                }
                .task {
                    // Bind the notification worker to the shell stores and drop per-server
                    // mention state when a server is removed (desktop: AppState reacts to
                    // SERVER_LOGGED_IN_CHANGED/SERVER_REMOVED; the shell owns that binding).
                    notificationWorker.serverStore = serverStore
                    notificationWorker.viewStore = viewStore
                    notificationWorker.activate()
                    sessionStore.observeServerRemovals(from: serverStore)

                    // T14: bind the background mention poller to the live stores. Without
                    // this (pure background launch) the poller falls back to fresh stores
                    // over the standard defaults / logged no-ops.
                    MentionPoller.shared.serverStore = serverStore
                    MentionPoller.shared.sessionStore = sessionStore

                    // SettingsView's download-history Stepper writes `AppSettings`; re-trim the
                    // open journal live so the UI and the persisted cap never diverge.
                    historyCapCancellable = appSettings.$downloadHistoryLimit
                        .removeDuplicates()
                        .sink { limit in
                            downloadWorker.history.setMaxRecords(limit)
                        }
                }
                .task { runShellSnapshotIfRequested() }
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
