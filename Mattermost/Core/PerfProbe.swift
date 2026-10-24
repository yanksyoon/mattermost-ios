#if DEBUG || PERF_PROBE
import Foundation
import os
import UIKit
import WebKit

/// T27 — measurement seam for the Path A -> Path B memory claim.
///
/// **Inert unless launched with `-perfProbe <dir>`.** It exists because "the web engine is too
/// heavy" has to become a number measured on this host, before and after, and because a scripted
/// sequence inside the app is the only way to drive the same steps on Mac Catalyst and in the iOS
/// Simulator without a second tool (XCUITest drives the *chrome* fine, but a fixed
/// launch → load → open channel → scroll → open thread sequence needs to run at a known instant
/// while an external sampler watches the process tree).
///
/// What it does, exactly:
///  1. Seeds one server into the shell (unless `mode == .shell`), so the run starts from a known
///     workspace with no hand-typed state.
///  2. Waits for the webview's first commit, then drives a fixed DOM sequence through
///     `callAsyncJavaScript` — log in, open the named channel, scroll the post list N steps, open
///     the thread on the newest post's comment link.
///  3. Records every stage boundary to two places: `os_signpost` intervals on subsystem
///     `com.mattermost.ios.perf` (so `xctrace` can attribute them) and an append-only JSONL journal
///     in the probe directory (so the external sampler can align its samples without a trace).
///  4. Writes `probe-result.json` and touches `probe.done`.
///
/// It is not a test double and it does not paper over failure: a stage that does not complete is
/// recorded with `"ok": false` and whatever diagnostic the page could give (`dom.json`). The
/// sampler reports memory for exactly the stages that ran.
///
/// Build gate: compiled under `DEBUG` or the `PERF_PROBE` compilation condition, which the
/// harness passes explicitly (`SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) PERF_PROBE'`) so
/// the measured binary is a Release-optimised build. A shipping Release build has no probe.
@MainActor
final class PerfProbe {

    // MARK: - Configuration

    enum Mode: String {
        /// Server seeded, channel view rendered by the WKWebView (today's Path A default).
        case web
        /// Server seeded, channel view is the native stand-in (`-surfaceMode channelView=native`).
        /// **Warm**: the webview is created, logged in and left alive behind the pane.
        case native
        /// No server at all: the shell alone, no webview, no WebContent process.
        case shell
        /// Server seeded, then the pane's webview is **released** (`ViewStore.release`) and no DOM
        /// stage runs — `docs/dual-render.md` §12.6's arm: what the shell costs once a pane-owning
        /// native card owns the work area. Its evidence is the WebContent process count
        /// (`run.json` → `pids.webcontent == []`) and the shell-relative footprint ceiling, not a
        /// comparison with the warm `web`/`native` arms.
        case nativeEvicted
    }

    struct Config {
        let directory: URL
        let mode: Mode
        let serverURL: URL?
        let channelName: String
        let scrollSteps: Int
        let loginID: String?
        let password: String?
        /// Absolute deadline for the whole sequence, seconds after start.
        let budget: TimeInterval
    }

    static let subsystem = "com.mattermost.ios.perf"
    static let journalName = "probe-journal.jsonl"
    static let resultName = "probe-result.json"
    static let doneMarker = "probe.done"

    /// Parse the probe arguments. Returns nil when `-perfProbe` is absent, which is the only
    /// state a real user's launch is ever in.
    static func requested(arguments: [String] = ProcessInfo.processInfo.arguments,
                          environment: [String: String] = ProcessInfo.processInfo.environment) -> Config? {
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), arguments.indices.contains(i + 1) else { return nil }
            return arguments[i + 1]
        }
        guard let dir = value("-perfProbe") else { return nil }
        let mode = Mode(rawValue: value("-perfProbeMode") ?? "web") ?? .web
        let serverURL = value("-perfProbeServer").flatMap { URL(string: $0) }
        // Credentials can never ride in argv: `ps` shows arguments to every local user. They come
        // from the environment the harness sets on the launched process.
        return Config(
            directory: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath),
            mode: mode,
            serverURL: serverURL,
            channelName: value("-perfProbeChannel") ?? "perf-feed",
            scrollSteps: Int(value("-perfProbeScrollSteps") ?? "") ?? 12,
            loginID: environment["MM_PERF_LOGIN"],
            password: environment["MM_PERF_PASSWORD"],
            budget: Double(value("-perfProbeBudget") ?? "") ?? 240
        )
    }

    // MARK: - State

    let config: Config
    private let signposter: OSSignposter
    private var journalHandle: FileHandle?
    private var stageStart: Date?
    private var stages: [[String: Any]] = []
    private let startDate = Date()
    private var signpostStates: [String: OSSignpostIntervalState] = [:]

    init(config: Config) {
        self.config = config
        self.signposter = OSSignposter(subsystem: Self.subsystem, category: "probe")
        // The harness creates this directory too; creating it here keeps a bare `open --args` run
        // working without the wrapper script. A failure is fatal for the *measurement* (the journal
        // is how the sampler aligns stages and learns the probe finished), so it is logged rather
        // than swallowed — the wrapper script fails the run when no journal appears at all.
        do {
            try FileManager.default.createDirectory(at: config.directory,
                                                   withIntermediateDirectories: true)
        } catch {
            Logger.error("perf", "cannot create probe directory \(config.directory.path): "
                                 + error.localizedDescription)
        }
    }

    // MARK: - Journal

    private func appendJournal(_ event: [String: Any]) {
        var record = event
        record["schema"] = 1
        record["wall"] = Date().timeIntervalSince1970
        record["uptime"] = ProcessInfo.processInfo.systemUptime
        record["since_start"] = Date().timeIntervalSince(startDate)
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let nl = "\n".data(using: .utf8) else { return }
        if journalHandle == nil {
            let path = config.directory.appendingPathComponent(Self.journalName).path
            FileManager.default.createFile(atPath: path, contents: nil)
            journalHandle = FileHandle(forWritingAtPath: path)
        }
        journalHandle?.write(data)
        journalHandle?.write(nl)
        journalHandle?.synchronizeFile()
    }

    /// Begin a stage: journal + signpost interval + optional DOM sample.
    private func beginStage(_ name: String, _ detail: [String: Any] = [:]) {
        stageStart = Date()
        let id = OSSignpostID(log: .init(subsystem: Self.subsystem, category: "probe"))
        switch name {
        case "login": signpostStates[name] = signposter.beginInterval("login", id: id)
        case "openChannel": signpostStates[name] = signposter.beginInterval("openChannel", id: id)
        case "scrollPosts": signpostStates[name] = signposter.beginInterval("scrollPosts", id: id)
        case "openThread": signpostStates[name] = signposter.beginInterval("openThread", id: id)
        case "workspaceLoad": signpostStates[name] = signposter.beginInterval("workspaceLoad", id: id)
        default: signposter.emitEvent("stage")
        }
        appendJournal(["stage": name, "phase": "begin", "detail": detail])
    }

    private func endStage(_ name: String, ok: Bool, detail: [String: Any] = [:]) {
        let duration = stageStart.map { Date().timeIntervalSince($0) } ?? 0
        if let state = signpostStates.removeValue(forKey: name) {
            switch name {
            case "login": signposter.endInterval("login", state, "ok=\(ok, privacy: .public)")
            case "openChannel": signposter.endInterval("openChannel", state, "ok=\(ok, privacy: .public)")
            case "scrollPosts": signposter.endInterval("scrollPosts", state, "ok=\(ok, privacy: .public)")
            case "openThread": signposter.endInterval("openThread", state, "ok=\(ok, privacy: .public)")
            case "workspaceLoad": signposter.endInterval("workspaceLoad", state, "ok=\(ok, privacy: .public)")
            default: break
            }
        }
        var record: [String: Any] = ["name": name, "ok": ok,
                                     "duration_s": (duration * 1000).rounded() / 1000,
                                     "detail": detail]
        if let stageStart {
            record["started_offset_s"] = ((stageStart.timeIntervalSince(startDate)) * 1000).rounded() / 1000
            record["ended_offset_s"] = ((Date().timeIntervalSince(startDate)) * 1000).rounded() / 1000
        }
        stages.append(record)
        appendJournal(["stage": name, "phase": "end", "ok": ok, "duration_s": record["duration_s"] ?? 0,
                       "detail": detail])
    }

    // MARK: - Driver

    /// Run the whole scripted sequence against `store`'s webview and write the result files.
    /// Never throws: every failure is recorded as a failed stage.
    ///
    /// - Parameters:
    ///   - store: the pane's live webview store, when the launch created one.
    ///   - viewStore: the shell's store owner. Only the `nativeEvicted` arm needs it (it is what
    ///     `release(serverID:)` acts on); every DOM-driving arm ignores it.
    ///   - serverID: the seeded server's id, paired with `viewStore`.
    func run(store: WebViewStore?,
             viewStore: ViewStore? = nil,
             serverID: UUID? = nil) async {
        appendJournal(["stage": "probe", "phase": "begin",
                       "mode": config.mode.rawValue,
                       "server": config.serverURL?.absoluteString ?? "none",
                       "channel": config.channelName,
                       "scroll_steps": config.scrollSteps,
                       "os": ProcessInfo.processInfo.operatingSystemVersionString,
                       "device_model": Self.hardwareModel()])

        if config.mode == .nativeEvicted {
            await runReleasedPane(store: store, viewStore: viewStore, serverID: serverID)
            return
        }

        guard config.mode != .shell else {
            // Shell-only run: nothing to drive. Sit still long enough for the sampler to record a
            // steady state, then finish.
            appendJournal(["stage": "shell", "phase": "end", "ok": true])
            await finish(store: store, extra: ["note": "no server seeded (shell baseline)"])
            return
        }

        guard let store else {
            appendJournal(["stage": "probe", "phase": "aborted", "reason": "no webview store"])
            await finish(store: nil, extra: ["aborted": "no webview store for the seeded server"])
            return
        }

        beginStage("workspaceLoad")
        // First launch on a fresh web-view profile: the web app bounces `/` to its own linking
        // landing page ("View in Browser") once per profile. That is a real part of the first
        // run, so the probe takes the same exit a user takes instead of hiding the page.
        let landing = await dismissLandingPageIfNeeded(store: store)
        let workspace = await waitForWorkspace(store: store)
        endStage("workspaceLoad", ok: workspace.ok,
                 detail: workspace.detail.merging(["landing_page": landing]) { $1 })
        guard workspace.ok else {
            await finish(store: store, extra: ["aborted": "workspace never rendered"])
            return
        }

        // Log in when the web app asked for credentials. A pre-authenticated store (a rerun
        // against the same per-server data store) skips straight to the channel stage.
        let state = await pageState(store.webView)
        if state?["loginForm"] as? Bool == true {
            guard let loginID = config.loginID, let password = config.password else {
                endStageAbsent("login")
                await finish(store: store, extra: ["aborted": "login form present but MM_PERF_LOGIN/MM_PERF_PASSWORD not set"])
                return
            }
            beginStage("login")
            let result = await login(store.webView, loginID: loginID, password: password)
            endStage("login", ok: result.ok, detail: result.detail)
            guard result.ok else {
                await finish(store: store, extra: ["aborted": "login failed"])
                return
            }
        } else {
            appendJournal(["stage": "login", "phase": "skipped", "detail": ["reason": "already authenticated"]])
        }

        if config.mode == .native {
            // The native stand-in has no post list to drive. Measure the app with the workspace
            // surface unmounted, then stop — this is the "native" data point of the baseline.
            //
            // Honest limit, recorded in the result rather than hidden: the webview is alive and
            // authenticated but *not mounted*, so its virtualised post list has no height and
            // renders little to nothing (the observed count is in `login.detail.posts`). This arm
            // therefore answers "what does the shell still pay for the web engine while a native
            // surface owns the pane", not "native costs the same as web".
            await finish(store: store, extra: [
                "note": "native surface: webview authenticated but unmounted; no DOM sequence run",
                "warm_state": "authenticated; the post list is not driven (pane unmounted)",
            ])
            return
        }

        beginStage("openChannel")
        let opened = await openChannel(store.webView, channel: config.channelName)
        endStage("openChannel", ok: opened.ok, detail: opened.detail)
        guard opened.ok else {
            await finish(store: store, extra: ["aborted": "channel open failed"])
            return
        }

        beginStage("scrollPosts")
        let scrolled = await scrollPosts(store.webView, steps: config.scrollSteps)
        endStage("scrollPosts", ok: scrolled.ok, detail: scrolled.detail)

        beginStage("openThread")
        let thread = await openThread(store.webView)
        endStage("openThread", ok: thread.ok, detail: thread.detail)

        await finish(store: store, extra: [:])
    }

    private func endStageAbsent(_ name: String) {
        appendJournal(["stage": name, "phase": "skipped", "detail": ["reason": "no credentials"]])
    }

    /// The `nativeEvicted` arm (`docs/dual-render.md` §12.6).
    ///
    /// It calls `ViewStore.release(serverID:)` — the production teardown — and then drives nothing:
    /// there is no page left to script. Like `shell`, it finishes immediately and lets the
    /// sampler's steady-state window run over the released state.
    ///
    /// Why it does not go through `WebViewReleasePolicy`: the predicate's third condition
    /// (`paneOwningSurfaces`) is an `-AV` claim about a *card*. A measurement arm must not fake
    /// one — it measures the mechanism (destroy the webview, keep the data store) before any card
    /// has been approved, and says so in its own result. The sanctioned `allowUnapproved` bypass
    /// belongs to real callers (a DEBUG UI-test launch), not to this instrument.
    private func runReleasedPane(store: WebViewStore?, viewStore: ViewStore?, serverID: UUID?) async {
        beginStage("releasePane", ["had_store": store != nil])
        var detail: [String: Any] = ["had_store": store != nil]
        var released = false
        if let viewStore, let serverID {
            viewStore.release(serverID: serverID)
            released = viewStore.view(forServerID: serverID) == nil
            detail["last_url"] = viewStore.lastURLs[serverID]?.absoluteString ?? "none"
        } else {
            detail["reason"] = "no ViewStore/server id handed to the probe"
        }
        detail["released"] = released
        endStage("releasePane", ok: released, detail: detail)

        await finish(store: nil, extra: [
            "note": "pane released, no webview",
            "webview": "none — the store was released before sampling; no DOM stage runs in this arm",
        ])
    }

    /// Wait until the web app has rendered *the thing we measure* — a login form or the
    /// workspace — rather than merely committed a URL. Waiting on the first commit was wrong: it
    /// caught the linking landing page's commit and declared the workspace loaded.
    private func waitForWorkspace(store: WebViewStore) async -> (ok: Bool, detail: [String: Any]) {
        let deadline = Date().addingTimeInterval(60)
        var last: [String: Any] = [:]
        while Date() < deadline {
            if let state = await pageState(store.webView) {
                last = state
                if state["loginForm"] as? Bool == true || state["postList"] as? Bool == true {
                    return (true, state)
                }
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        var detail = last
        detail["reason"] = "neither a login form nor a post list within 60s"
        detail["store_url"] = store.url?.absoluteString ?? "nil"
        return (false, detail)
    }

    /// The web app redirects a first-time browser profile to `/landing` (its "get the app" page).
    /// Click its "View in Browser" link — the same exit the user has — and wait for the reload.
    /// Returns a small record for the report; `nil` when the page was already the workspace.
    private func dismissLandingPageIfNeeded(store: WebViewStore) async -> [String: Any]? {
        guard let state = await pageState(store.webView),
              let href = state["href"] as? String, href.contains("/landing") else { return nil }
        appendJournal(["stage": "landingPage", "phase": "begin", "detail": ["href": href]])
        // Fire-and-forget: clicking the link starts a full navigation, which tears down the page
        // context the call runs in, so there is no reply worth waiting for.
        store.webView.callAsyncJavaScript(Self.dismissLandingJS, arguments: [:],
                                          in: nil, in: .page) { _ in }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let url = store.url, !url.absoluteString.contains("/landing"), !store.isLoading {
                appendJournal(["stage": "landingPage", "phase": "end", "ok": true,
                               "detail": ["after": url.absoluteString]])
                return ["dismissed": true, "from": href, "to": url.absoluteString]
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        appendJournal(["stage": "landingPage", "phase": "end", "ok": false,
                       "detail": ["reason": "still on /landing after clicking View in Browser"]])
        return ["dismissed": false, "from": href]
    }

    // MARK: - Result

    private func finish(store: WebViewStore?, extra: [String: Any]) async {
        var result: [String: Any] = [
            "schema": 1,
            "mode": config.mode.rawValue,
            "channel": config.channelName,
            "scroll_steps": config.scrollSteps,
            "started_wall": startDate.timeIntervalSince1970,
            "finished_wall": Date().timeIntervalSince1970,
            "total_s": ((Date().timeIntervalSince(startDate)) * 1000).rounded() / 1000,
            "device_model": Self.hardwareModel(),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "bundle_id": Bundle.main.bundleIdentifier ?? "",
            "stages": stages,
            "completed_stages": stages.filter { ($0["ok"] as? Bool) == true }.map { $0["name"] as? String ?? "" },
            "failed_stages": stages.filter { ($0["ok"] as? Bool) == false }.map { $0["name"] as? String ?? "" },
        ]
        if let server = config.serverURL { result["server"] = server.absoluteString }
        for (k, v) in extra { result[k] = v }
        var webViewPointer = "none"
        if let store {
            webViewPointer = store.url?.absoluteString ?? "nil"
            result["webview_url"] = webViewPointer
            result["webview_title"] = store.title ?? ""
            if let dom = await pageState(store.webView) { result["final_dom"] = dom }
            if let dump = await domDump(store.webView) {
                try? dump.write(to: config.directory.appendingPathComponent("dom.json"),
                                atomically: true, encoding: .utf8)
            }
        }
        let path = config.directory.appendingPathComponent(Self.resultName)
        if let data = try? JSONSerialization.data(withJSONObject: result,
                                                 options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: path)
        }
        appendJournal(["stage": "probe", "phase": "end"])
        FileManager.default.createFile(
            atPath: config.directory.appendingPathComponent(Self.doneMarker).path, contents: Data())
    }

    // MARK: - JS helpers

    private struct StepResult {
        let ok: Bool
        let detail: [String: Any]
    }

    /// One-shot gate so a JS reply that arrives after the timeout (or after a navigation killed
    /// the frame) can never resume the continuation twice.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        func take() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if resumed { return false }
            resumed = true
            return true
        }
    }

    private func evaluate(_ webView: WKWebView, body: String,
                          arguments: [String: Any] = [:],
                          timeout: TimeInterval = 120) async -> Any? {
        let once = ResumeOnce()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Any?, Never>) in
            webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
                guard once.take() else { return }
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure: continuation.resume(returning: nil)
                }
            }
            // A navigation (the landing page's "View in Browser" link) can tear down the frame
            // before WebKit calls the handler; a bounded wait keeps the probe moving and is
            // recorded as a nil (failed) step rather than hanging the whole run.
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                guard once.take() else { return }
                continuation.resume(returning: nil)
            }
        }
    }

    private func pageState(_ webView: WKWebView) async -> [String: Any]? {
        await callJSON(webView, body: Self.stateJS)
    }

    private func callJSON(_ webView: WKWebView, body: String,
                          arguments: [String: Any] = [:]) async -> [String: Any]? {
        guard let raw = await evaluate(webView, body: body, arguments: arguments) else { return nil }
        if let dict = raw as? [String: Any] { return dict }
        if let string = raw as? String,
           let data = string.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        return nil
    }

    private func login(_ webView: WKWebView, loginID: String, password: String) async -> StepResult {
        guard let result = await callJSON(webView, body: Self.loginJS,
                                          arguments: ["loginId": loginID, "password": password,
                                                      "requirePostList": config.mode != .native]) else {
            return StepResult(ok: false, detail: ["reason": "JS login threw or returned nothing"])
        }
        return StepResult(ok: result["ok"] as? Bool == true, detail: result)
    }

    private func openChannel(_ webView: WKWebView, channel: String) async -> StepResult {
        guard let result = await callJSON(webView, body: Self.openChannelJS,
                                          arguments: ["channel": channel]) else {
            return StepResult(ok: false, detail: ["reason": "JS openChannel threw or returned nothing"])
        }
        return StepResult(ok: result["ok"] as? Bool == true, detail: result)
    }

    private func scrollPosts(_ webView: WKWebView, steps: Int) async -> StepResult {
        guard let result = await callJSON(webView, body: Self.scrollJS,
                                          arguments: ["steps": steps]) else {
            return StepResult(ok: false, detail: ["reason": "JS scroll threw or returned nothing"])
        }
        return StepResult(ok: result["ok"] as? Bool == true, detail: result)
    }

    private func openThread(_ webView: WKWebView) async -> StepResult {
        guard let result = await callJSON(webView, body: Self.openThreadJS) else {
            return StepResult(ok: false, detail: ["reason": "JS openThread threw or returned nothing"])
        }
        return StepResult(ok: result["ok"] as? Bool == true, detail: result)
    }

    private func domDump(_ webView: WKWebView) async -> String? {
        await evaluate(webView, body: Self.domDumpJS) as? String
    }

    static func hardwareModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    // MARK: - Scripts
    //
    // These run INSIDE the web app's page, as the app, in the app's own webview — the same trust
    // domain the shell already has (the shell drives `evaluateJavaScript` for its own bridge).
    // They are selector-tolerant on purpose: the Mattermost web app's class names are not a
    // public API, so each step takes the first selector that matches and records which one it
    // used, and a step that cannot find its target reports failure instead of guessing.

    private static let dismissLandingJS = """
    const link = [...document.querySelectorAll('a')]
      .find(a => /view in browser|continue in your web browser/i.test(a.innerText || ''));
    if (link) {
      link.click();
      return JSON.stringify({ ok: true, clicked: true, text: (link.innerText || '').trim().slice(0, 60) });
    }
    // No link (a different web app version): go to the location the landing page wrapped.
    location.replace(location.href.replace('/landing#', '/').replace('/landing', '/'));
    return JSON.stringify({ ok: true, clicked: false });
    """

    private static let stateJS = """
    return (() => {
      const q = (s) => document.querySelector(s);
      const postEls = document.querySelectorAll('[id^="post_"]');
      return JSON.stringify({
        href: location.href,
        title: document.title,
        loginForm: !!q('#input_loginId') || !!q('#loginId') || !!q('input[name="loginId"]'),
        sidebar: !!q('.sidebar--left') || !!q('[data-testid="channelSidebar"]') || !!q('a[href*="/channels/"]'),
        modal: !!q('.modal, [role="dialog"]'),
        postList: !!q('.post-list__dynamic') || !!q('.post-list') || !!q('.postList'),
        posts: postEls.length,
        rhsOpen: !!q('.post-right__container') || !!q('.sidebar--right--width-holder'),
        bodyTextLen: document.body ? document.body.innerText.length : -1,
        nodes: document.querySelectorAll('*').length,
        // Diagnostics that make "why did the web app render X instead of the workspace"
        // answerable from the journal alone.
        ua: navigator.userAgent,
        maxTouchPoints: navigator.maxTouchPoints || 0
      });
    })();
    """

    private static let loginJS = """
    const sleep = (ms) => new Promise(r => setTimeout(r, ms));
    const set = (el, value) => {
      const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      const desc = Object.getOwnPropertyDescriptor(proto, 'value');
      if (desc && desc.set) { desc.set.call(el, value); } else { el.value = value; }
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    };
    // The login document can still be settling (the web app re-navigates /login once), so wait
    // for the form instead of failing on the first look.
    let user = null;
    let pass = null;
    let inputsBy = Date.now() + 15000;
    while (Date.now() < inputsBy) {
      user = document.querySelector('#input_loginId') || document.querySelector('#loginId')
        || document.querySelector('input[name="loginId"]');
      pass = document.querySelector('#input_password-input') || document.querySelector('#loginPassword')
        || document.querySelector('input[name="password-input"]') || document.querySelector('input[type="password"]');
      if (user && pass) { break; }
      await sleep(250);
    }
    if (!user || !pass) { return JSON.stringify({ ok: false, reason: 'login inputs not found within 15s', href: location.href }); }
    set(user, loginId);
    set(pass, password);
    await sleep(120);
    const button = document.querySelector('#saveSetting') || document.querySelector('#loginButton')
      || document.querySelector('button[type="submit"]')
      || [...document.querySelectorAll('button')].find(b => /sign in|log in/i.test(b.innerText));
    if (!button) { return JSON.stringify({ ok: false, reason: 'login button not found' }); }
    button.click();
    // What "logged in" means depends on the arm: the web arm must reach a rendered post list,
    // while the native arm's webview is *not mounted* (the native stand-in owns the pane), so its
    // virtualised post list has no height to render into. There, an authenticated channel URL
    // (no login form, the channel chrome painted) is the furthest state the page can reach.
    const authed = () => {
      if (document.querySelector('#loginId') || document.querySelector('#input_loginId')) { return false; }
      const posts = document.querySelectorAll('[id^="post_"]').length;
      if (posts > 0) { return true; }
      if (requirePostList) { return false; }
      return location.pathname.indexOf('/channels/') !== -1 &&
        (!!document.querySelector('.app__body') || /write to|toggle sidebar/i.test(document.body.innerText || ''));
    };
    const started = Date.now();
    while (Date.now() - started < 60000) {
      await sleep(250);
      if (authed()) {
        return JSON.stringify({ ok: true, waited_ms: Date.now() - started,
          href: location.href, posts: document.querySelectorAll('[id^="post_"]').length,
          post_list: !!document.querySelector('.post-list, .post-list__dynamic'),
          authenticated_only: requirePostList ? false : document.querySelectorAll('[id^="post_"]').length === 0 });
      }
      if (document.querySelector('#loginId')) {
        const err = document.querySelector('.alert-danger, .Input___error, [role="alert"]');
        if (err && err.innerText && err.innerText.trim().length > 0) {
          return JSON.stringify({ ok: false, reason: 'login rejected: ' + err.innerText.slice(0, 200) });
        }
      }
    }
    return JSON.stringify({ ok: false, reason: 'no post list 60s after submitting login',
                            href: location.href, bodyText: (document.body.innerText || '').slice(0, 300) });
    """

    private static let openChannelJS = """
    const sleep = (ms) => new Promise(r => setTimeout(r, ms));
    // First-run overlays (the web app's "Welcome to Mattermost" onboarding modal) sit above the
    // channel list and swallow clicks. Dismiss the same way a user does.
    for (let i = 0; i < 3; i++) {
      const close = document.querySelector('.modal .close, .modal-header .close, button[aria-label="Close"], .GenericModal__button--cancel');
      if (!close) { break; }
      close.click();
      await sleep(300);
    }
    const target = '/channels/' + channel;
    if (location.pathname.endsWith(target)) {
      return JSON.stringify({ ok: true, already: true, href: location.href,
                              posts: document.querySelectorAll('[id^="post_"]').length });
    }
    const before = document.querySelectorAll('[id^="post_"]').length;
    const link = [...document.querySelectorAll('a[href]')]
      .find(a => (a.getAttribute('href') || '').indexOf(target) !== -1);
    if (link) {
      link.click();
    } else {
      // The channel is joined but not pinned in the sidebar (a channel joined before the first
      // sign-in has no sidebar category yet). Use the same in-page history navigation the shell's
      // bridge uses for notification taps — no page reload, so no second SPA bootstrap.
      window.history.pushState({}, '', location.pathname.replace(/\\/channels\\/[^/]+$/, '') + target);
      window.dispatchEvent(new PopStateEvent('popstate'));
    }
    const started = Date.now();
    while (Date.now() - started < 30000) {
      await sleep(250);
      const posts = document.querySelectorAll('[id^="post_"]').length;
      if (location.pathname.indexOf(target) !== -1 && posts > 0 && (posts !== before || !link)) {
        return JSON.stringify({ ok: true, via: link ? 'sidebar-link' : 'history', waited_ms: Date.now() - started,
                                href: location.href, posts: posts });
      }
    }
    return JSON.stringify({ ok: false, reason: 'channel did not render posts within 30s', href: location.href,
                            posts: document.querySelectorAll('[id^="post_"]').length,
                            links: [...document.querySelectorAll('a[href*="/channels/"]')].map(a => a.getAttribute('href')).slice(0, 20) });
    """

    private static let scrollJS = """
    const sleep = (ms) => new Promise(r => setTimeout(r, ms));
    const scroller = () => {
      const candidates = [document.querySelector('.post-list__dynamic'),
                          document.querySelector('.post-list'),
                          document.querySelector('.postList'),
                          document.querySelector('.post-list-holder-by-time')];
      for (const c of candidates) {
        if (c && c.scrollHeight > c.clientHeight + 40) { return c; }
      }
      // Fall back to any scrolled ancestor of the post list.
      let el = document.querySelector('[id^="post_"]');
      while (el) {
        if (el.scrollHeight > el.clientHeight + 40) { return el; }
        el = el.parentElement;
      }
      return null;
    };
    const el = scroller();
    if (!el) { return JSON.stringify({ ok: false, reason: 'no scrollable post list' }); }
    const startPosts = document.querySelectorAll('[id^="post_"]').length;
    const startScroll = el.scrollTop;
    let stepsDone = 0;
    for (let i = 0; i < steps; i++) {
      el.scrollBy(0, -Math.max(200, Math.round(el.clientHeight * 0.85)));
      el.dispatchEvent(new Event('scroll', { bubbles: true }));
      stepsDone++;
      await sleep(180);
    }
    await sleep(800);
    return JSON.stringify({ ok: stepsDone === steps, steps: stepsDone,
                            start_scroll_top: Math.round(startScroll),
                            end_scroll_top: Math.round(el.scrollTop),
                            posts_before: startPosts,
                            posts_after: document.querySelectorAll('[id^="post_"]').length });
    """

    private static let openThreadJS = """
    const sleep = (ms) => new Promise(r => setTimeout(r, ms));
    const scroller = () => {
      const candidates = [document.querySelector('.post-list__dynamic'), document.querySelector('.post-list'),
                          document.querySelector('.post-list-holder-by-time'), document.querySelector('.postList')];
      for (const c of candidates) {
        if (c && c.scrollHeight > c.clientHeight + 40) { return c; }
      }
      let el = document.querySelector('[id^="post_"]');
      while (el) {
        if (el.scrollHeight > el.clientHeight + 40) { return el; }
        el = el.parentElement;
      }
      return null;
    };
    // The RHS is a container plus a width holder; both spellings have shipped (`#sidebar-right`
    // with `.sidebar--right` today, `.post-right__container` in older versions), so accept any.
    const rhsOpen = () => document.querySelector('#sidebar-right')
      || document.querySelector('.sidebar--right')
      || document.querySelector('.post-right__container')
      || document.querySelector('.sidebar--right--width-holder')
      || document.querySelector('[data-testid="rhs"], .ThreadPane');
    const waitRHS = async (ms) => {
      const started = Date.now();
      while (Date.now() - started < ms) {
        await sleep(250);
        const rhs = rhsOpen();
        if (rhs) { return { ok: true, waited_ms: Date.now() - started,
                            rhs_posts: rhs.querySelectorAll('[id^="post_"]').length }; }
      }
      return null;
    };

    // The thread root is the newest post and the virtualised list only renders what is near the
    // viewport, so go back to the bottom before looking for its "N replies" affordance.
    const el = scroller();
    if (el) { el.scrollTop = el.scrollHeight; await sleep(900); }

    const describe = (e, i) => ({ i, id: e.id || null,
      cls: (e.getAttribute('class') || '').toString().slice(0, 80),
      aria: e.getAttribute('aria-label'),
      testid: e.getAttribute('data-testid'),
      text: (e.innerText || '').trim().slice(0, 40),
      visible: !!(e.offsetWidth || e.offsetHeight) });

    // 1. The reply-count affordance ("N replies" / the reply glyph) on a root post. The web app
    //    renders it as `button#center_commentIcon_<postid>` / `.post-menu__item[aria-label=reply]`
    //    for a root that has replies (it is hover-only for posts without any), plus the older
    //    `.post__reply` / `[data-testid="post-comment"]` spellings. Take the newest match.
    const iconSelectors = ['button[id*="commentIcon"]',
                           '.post-menu__item[aria-label*="reply" i]',
                           'button[aria-label*="reply" i]',
                           '.post__reply',
                           '[class*="post__reply"]',
                           '[data-testid="post-comment"]',
                           '[data-testid^="reply_to_post_"]'];
    let icons = [];
    for (const sel of iconSelectors) {
      icons = [...document.querySelectorAll(sel)].filter(e => e.offsetWidth || e.offsetHeight);
      if (icons.length) {
        icons[icons.length - 1].click();
        const opened = await waitRHS(20000);
        if (opened) {
          return JSON.stringify(Object.assign({ via: 'comment-icon', selector: sel,
                                               candidates: icons.length }, opened));
        }
        break;
      }
    }

    // 2. Same affordance, but the post has to look hovered first: the reply glyph is rendered by
    //    React state on mouseover, so fire the events a pointer would.
    const views = [...document.querySelectorAll('[data-testid="postView"], .post')];
    const last = views[views.length - 1];
    if (last) {
      for (const type of ['mouseover', 'mouseenter', 'mousemove']) {
        last.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, view: window }));
      }
      await sleep(600);
      const hoverIcon = last.querySelector('button[aria-label*="reply" i], .post-menu__item[aria-label*="reply" i]');
      if (hoverIcon) {
        hoverIcon.click();
        const opened = await waitRHS(20000);
        if (opened) { return JSON.stringify(Object.assign({ via: 'hover-reply-icon' }, opened)); }
      }
    }

    // 3. Fall back to the post's dot menu → "Reply", the same path a user takes
    //    (`[data-testid="PostDotMenu-Button-<postid>"]` → `[data-testid="reply_to_post_<postid>"]`).
    const dotButtons = [...document.querySelectorAll('[data-testid^="PostDotMenu-Button-"]')];
    const menu = dotButtons[dotButtons.length - 1];
    if (menu) {
      menu.click();
      await sleep(500);
      const reply = document.querySelector('[data-testid^="reply_to_post_"]')
        || [...document.querySelectorAll('[role="menuitem"], button')]
          .find(e => /^(reply|reply to thread)$/i.test((e.innerText || '').trim()));
      if (reply) {
        reply.click();
        const opened = await waitRHS(20000);
        if (opened) { return JSON.stringify(Object.assign({ via: 'post-menu' }, opened)); }
      }
    }
    return JSON.stringify({ ok: false,
      reason: 'no reply affordance found and the thread panel did not open',
      href: location.href,
      postViews: views.length,
      commentIcons: icons.length,
      dotMenuButtons: dotButtons.length,
      lastPostControls: last ? [...last.querySelectorAll('button, a[href], [role="button"]')]
        .slice(0, 12).map(describe) : [],
      rhs: !!rhsOpen() });
    """

    private static let domDumpJS = """
    return (() => {
      const describe = (e) => {
        if (!e) { return null; }
        const r = e.getBoundingClientRect();
        const cs = getComputedStyle(e);
        return { cls: (e.className || '').toString().slice(0, 90), w: Math.round(r.width),
                 h: Math.round(r.height), display: cs.display,
                 text: (e.innerText || '').slice(0, 120) };
      };
      const attrs = (e) => ({ tag: e.tagName.toLowerCase(), id: e.id || null,
                              name: e.getAttribute('name'), type: e.getAttribute('type'),
                              aria: e.getAttribute('aria-label'), placeholder: e.getAttribute('placeholder'),
                              text: (e.innerText || '').trim().slice(0, 60),
                              visible: !!(e.offsetWidth || e.offsetHeight) });
      return JSON.stringify({
        href: location.href,
        title: document.title,
        nodes: document.querySelectorAll('*').length,
        bodyTextLen: document.body ? document.body.innerText.length : -1,
        bodyText: (document.body ? document.body.innerText : '').slice(0, 600),
        inputs: [...document.querySelectorAll('input, textarea')].map(attrs),
        buttons: [...document.querySelectorAll('button, a[role="button"]')].slice(0, 25).map(attrs),
        anchors: [...document.querySelectorAll('a[href]')].slice(0, 25)
                   .map(a => ({ href: a.getAttribute('href'), text: (a.innerText || '').trim().slice(0, 60) })),
        probes: ['.app__body', '.app__content', '.channel-view', '.post-list', '.post-list__dynamic',
                 '.sidebar--left', '.post-right__container', '.loading-screen', '.login-body',
                 '#loginId', '#loginPassword', '#loginButton']
                 .map(s => ({ sel: s, el: describe(document.querySelector(s)) })),
        postCount: document.querySelectorAll('[id^="post_"]').length,
        // Scroll-container and thread-affordance forensics: the web app's DOM is not a public API,
        // so when a step cannot find its target the report has to say what was actually there.
        scrollables: [...document.querySelectorAll('*')]
          .filter(e => (e.scrollHeight - e.clientHeight) > 100)
          .slice(0, 12)
          .map(e => ({ tag: e.tagName.toLowerCase(), cls: (e.className || '').toString().slice(0, 80),
                       id: e.id || null, scrollHeight: e.scrollHeight, clientHeight: e.clientHeight,
                       overflowY: getComputedStyle(e).overflowY })),
        replyCandidates: [...document.querySelectorAll('button, a')]
          .filter(e => /repl|comment|thread/i.test((e.className || '') + ' ' + (e.getAttribute('aria-label') || '')
                   + ' ' + (e.getAttribute('data-testid') || '') + ' ' + (e.className || '')))
          .slice(0, 15)
          .map(attrs),
        postRowClasses: [...new Set([...document.querySelectorAll('[id^="post_"]')].slice(0, 6)
          .map(e => (e.className || '').toString() + ' / ' + (e.getAttribute('data-testid') || '')))],
        postControls: [...document.querySelectorAll('[data-testid="postView"] button, [data-testid="postView"] a[href]')]
          .slice(0, 30).map(attrs),
        errors: (window.__mmErrorLog || []).slice(0, 20)
      }, null, 1);
    })();
    """
}
#endif
