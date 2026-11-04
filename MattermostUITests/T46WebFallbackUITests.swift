// T46 — the permanent-web escape hatch, driven against a **real** Mattermost server.
//
// Why live: every claim the card makes is about a running server.
//   1. "a working webview of exactly that surface" — the page has to be the server's own
//      `/admin_console` / `/playbooks`, not a fixture this file could render itself;
//   2. "shares the server's session (no second login)" — the app signs in **natively**, so there is
//      no web cookie before the first fallback; the page must still land on the surface instead of
//      `/login` (`SurfaceMode`'s fallback publishes `sessionSource` and the committed URL);
//   3. "torn down and recreated without leaking a webview" — twenty open/close cycles, each one a new
//      presentation (`webFallbackSheet`'s item identity), with the last cycle still rendering.
//
// Run (local throwaway server; same fixture account as T34/T39/T40/T41/T42):
//
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     python3 scripts/qa-test.py --platform mac \
//       --only-testing MattermostUITests/T46WebFallbackUITests
//
// `scripts/t46_leak_probe.py` runs the twenty-cycle test with an external sampler on the app's
// WebContent children — that is the process-level half of the memory claim.
//
// Every test skips (never fails) when the environment or the server is missing, like every live
// test here. Screenshots are attached so a run leaves visual evidence next to the machine verdict.

import XCTest

final class T46WebFallbackUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live web-fallback test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        try ping()
    }

    // MARK: - 1. The System Console opens in a webview, signed in

    /// The acceptance criterion, both halves in one run: from native chrome, the System Console
    /// renders the server's own admin console — and it does so with the **native** sign-in's
    /// session, which is the only session this launch has.
    func testTheSystemConsoleOpensSignedInAndReturnsToTheShell() throws {
        let app = launchApp()

        let pane = openSurface(app, row: "webFallbackRow.systemConsole", surface: "/admin_console")
        // `observableState` is `pageLoadState|sessionSource|committedURL`.
        let value = String(describing: pane.value ?? "")
        XCTAssertTrue(value.contains("|installed|"),
                      "a natively signed-in session is not a web cookie yet: the fallback must "
                      + "install the shell's token (state: \(value))")
        XCTAssertFalse(value.contains("/login"),
                       "the fallback must not land on the login page (state: \(value))")
        attachment(app, named: "t46-system-console-native-session")

        // Back navigation returns to the native stack — the sheet is the only thing the fallback
        // adds, so closing it must put the shell back, not a stale webview.
        app.buttons["webFallbackClose"].tap()
        XCTAssertTrue(element(app, "nativeShell").waitForExistence(timeout: 20),
                      "closing the fallback must return to the native shell")
        XCTAssertFalse(pane.exists, "the fallback webview must be gone after closing")
    }

    /// The second permanent surface on this fixture: Playbooks (the plugin is installed and serves
    /// `/playbooks`). Same contract, different route — so the catalogue is not a one-row special case.
    func testPlaybooksOpensAtItsOwnRoute() throws {
        let app = launchApp()
        _ = openSurface(app, row: "webFallbackRow.playbooks", surface: "/playbooks")
        attachment(app, named: "t46-playbooks")
        app.buttons["webFallbackClose"].tap()
        XCTAssertTrue(element(app, "nativeShell").waitForExistence(timeout: 20))
    }

    /// **T46-R R1** — the Boards row must never present a blank page.
    ///
    /// T46 had no test that opened this row, and `docs/dual-render.md` §13.6 claimed one existed.
    /// The audit ran it by hand: a natively signed-in session, the row tapped, 75 s of watching —
    /// and `loaded|installed|http://127.0.0.1:8065/boards|chars=61`, the "Preview Mode" banner and
    /// a blank navy page (`docs/t46-av-verdict.md` §F1). Boards is a **product plugin**
    /// (`focalboard`); this fixture does not install it, so `/boards` is the web app's HTML shell
    /// with no bundle to mount.
    ///
    /// Two outcomes are acceptable, and both are measured here:
    ///  * the server serves Boards → the webview paints it (`chars >= 120` at a `/boards…` URL);
    ///  * the server does not → the sheet says "Boards is not enabled on this server." and **no
    ///    webview is created at all** (a statement, not a page that happens to be empty).
    ///
    /// The third outcome — a webview at `/boards` with too little text and no statement — is the
    /// finding this test exists to fail on.
    func testBoardsIsEitherPaintedOrSaysItIsNotEnabled() throws {
        let app = launchApp()

        let row = element(app, "webFallbackRow.boards")
        XCTAssertTrue(scrollTo(app, element: row), "the Boards row must be reachable")
        row.tap()

        let statement = app.staticTexts["Boards is not enabled on this server."]
        let pane = element(app, "webFallbackPane")
        let deadline = Date().addingTimeInterval(90)
        var outcome = "none"
        var observed = ""

        while Date() < deadline {
            if statement.exists {
                outcome = "notEnabled"
                observed = statement.label
                break
            }
            if pane.exists {
                let value = String(describing: pane.value ?? "")
                observed = value
                if value.hasPrefix("loaded|"),
                   let committed = committedURL(in: value),
                   committed.contains("/boards"),
                   let painted = paintedCharacters(in: value),
                   painted >= 120 {
                    outcome = "painted"
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        print("T46 boards outcome: \(outcome) — \(observed)")
        attachment(app, named: "t46-boards-\(outcome)")
        XCTAssertNotEqual(outcome, "none",
                          "the Boards row must paint Boards or say the server does not enable it "
                          + "within 90 s; it did neither (last pane state: \(observed)) — a webview "
                          + "with no text and no statement is T46-AV's F1")
        if outcome == "notEnabled" {
            // The webview stays mounted so the navigation delegate is installed before any load,
            // but it is hidden and — the decisive fact — it never navigated: the page never went
            // past `idle` and nothing was committed. (`requested=` is the route the sheet *would*
            // ask for, set in `init`, so it is not evidence of a load.) A "not enabled" state that
            // had loaded `/boards` would be the blank page T46-AV found, with a caption over it.
            //
            // T46-AV-R F4: **unconditional**. This used to be `if pane.exists { … }`, so if the
            // pane stopped being exposed at all the decisive assertions would silently skip and
            // the test would still pass — the same "green suite over the wrong observation" shape
            // as the plugin row's label (F1). The mount is deliberate (the delegate-install rule,
            // `docs/dual-render.md` §13.6), so its absence is a failure of this card's own design,
            // not a reason to say nothing. Measured on the fixed build:
            // `idle|none|-|requested=http://…/boards`.
            XCTAssertTrue(pane.exists,
                          "the not-enabled sheet must keep its webview mounted (it installs the "
                          + "navigation delegate) and expose its state")
            let paneState = String(describing: pane.value ?? "")
            XCTAssertTrue(paneState.hasPrefix("idle|"),
                          "a not-enabled surface must not have started a navigation "
                          + "(pane state: \(paneState))")
            XCTAssertEqual(committedURL(in: paneState), "-",
                           "a not-enabled surface must not have committed a page")
            XCTAssertTrue(element(app, "webFallbackUnavailable").exists,
                          "the not-enabled state is the sheet's own 'cannot be opened' state")
        } else {
            XCTAssertTrue(app.staticTexts["Boards is not enabled on this server."].exists == false,
                          "a painted Boards surface must not also claim to be disabled")
        }

        app.buttons["webFallbackClose"].tap()
        XCTAssertTrue(element(app, "nativeShell").waitForExistence(timeout: 20),
                      "closing the Boards sheet returns to the native shell")
    }

    // MARK: - 2. Teardown and recreation

    /// Twenty presentations. Each one is a fresh `WebFallbackModel` (the sheet's item identity
    /// carries a token), and each must reach a loaded page — a leaked webview does not fail a tap,
    /// so the assertion is that the *twentieth* one still renders. `scripts/t46_leak_probe.py` watches
    /// the app's WebContent children while this runs and reports the count returning to baseline.
    func testTwentyOpenCloseCyclesEachRender() throws {
        let app = launchApp()
        let cycles = 20
        var decisions: [String] = []
        for cycle in 0..<cycles {
            let pane = openSurface(app, row: "webFallbackRow.systemConsole",
                                   surface: "/admin_console", timeout: 60,
                                   screenshot: cycle == 0 || cycle == cycles - 1)
            // Printed per cycle (T46-R R4): the session decision is the thing the "no second
            // login" claim rests on, and a log that only shows the first presentation cannot say
            // whether the store's session was reused or re-installed. `|cookies=` lists names.
            let state = String(describing: pane.value ?? "")
            print("T46 cycle \(cycle + 1) state: \(state)")
            // What the card claims, asserted: every cycle is a **signed-in** presentation of the
            // console, and none of them is a second login. `.installed` and `.shared` are both
            // legitimate — the shell installs its own token when the store's cookie jar has
            // nothing readable (measured: presentations 1-4 of this run), and reuses the store's
            // session when it does (5-20). `.none` (no session at all) or a `/login` URL would
            // break the claim.
            let decision = sessionDecision(in: state)
            XCTAssertNotNil(decision, "every cycle must report a session decision (state: \(state))")
            XCTAssertNotEqual(decision, "none",
                              "cycle \(cycle + 1): the shell holds a token for this server, so a "
                              + "fallback presentation is never signed out (state: \(state))")
            XCTAssertFalse(state.contains("/login"),
                           "cycle \(cycle + 1) must not land on the login page (state: \(state))")
            decisions.append(decision ?? "?")
            app.buttons["webFallbackClose"].tap()
            let gone = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: pane)
            XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 30), .completed,
                           "cycle \(cycle): the fallback webview must go away when its sheet closes")
        }
        // The sequence, not just a count: T46-AV's F4 said `shared` never happened in the app, and
        // what this run measures is *when* it starts happening. Printed so the log carries the
        // answer, and asserted only insofar as the claim needs it (never `none`, above).
        let installed = decisions.filter { $0 == "installed" }.count
        let shared = decisions.filter { $0 == "shared" }.count
        print("T46 session decisions over \(cycles) presentations: installed=\(installed) "
              + "shared=\(shared) (sequence: \(decisions.joined(separator: ",")))")

        // T46-R R5 — the "at rest" sample must be taken while this app is **still alive**.
        //
        // `scripts/t46_leak_probe.py` used to take its final count after `xcodebuild` had exited,
        // i.e. after XCTest terminated the app: a leaked `WKWebView` and an app exit are the same
        // observation at that point (T46-AV F5: run 1 counted one `WebContent` pid that was still
        // alive 12 minutes later with no client app; run 2 counted zero). So the last thing this
        // test does is hold the app open and idle with nothing presented, and print a marker pair
        // the probe samples between. Twenty seconds is longer than WebKit needs to retire the
        // content process it was using (measured: under 2 s after a close).
        print("T46_AT_REST_BEGIN")
        XCTAssertTrue(element(app, "nativeShell").exists,
                      "nothing is presented at the at-rest sample: the native shell is on screen")
        Thread.sleep(forTimeInterval: 20)
        print("T46_AT_REST_END")
        XCTAssertTrue(element(app, "nativeShell").exists,
                      "the app must still be alive at the end of the at-rest window, or the sample "
                      + "measured an app exit rather than a released webview")
    }

    // MARK: - 3. Plugin routes

    /// **T46-R R2** — a plugin **route**, not a plugin screen.
    ///
    /// `/plugins/<id>` answers `301 → /` on 9.11.19 for every installed plugin (calls 301,
    /// playbooks 301, focalboard 404 — `docs/t46-build-note.md` §7.4), so what the reader gets is
    /// the workspace. T46's row called itself "Plugin screen" and shipped
    /// `docs/t46-shots/t46-plugin-screen.png` as evidence for "a plugin screen" — the picture was
    /// of Town Square. The repair renames the row and the sheet to "Plugin route…", says in the
    /// prompt what the path actually addresses, and this test asserts exactly what is true:
    /// the shell asked for `/plugins/com.mattermost.calls`, the page it rendered is the server's
    /// web app (signed in), and the sheet's own title says "route".
    func testAPluginRouteIsAddressableByID() throws {
        let app = launchApp()

        let row = element(app, "webFallbackRow.plugin")
        XCTAssertTrue(scrollTo(app, element: row), "the Plugin route row must be reachable")

        // T46-AV-R F1 — **the row's own label**, which is what the reader taps and reads.
        //
        // T46 and T46-R both renamed the thing (`rowTitle`, the sheet's title, the prompt) and this
        // suite opened the row and asserted the prompt's and the sheet's title — so the shipped row
        // could still say "Plugin screen…" and a green suite said nothing about it. Measured on the
        // Measured on the repaired build: `PROBE row webFallbackRow.plugin label=Plugin route…`.
        print("PROBE row webFallbackRow.plugin: exists=\(row.exists) label=\(row.label)")
        XCTAssertEqual(row.label, "Plugin route…",
                       "the plugin row must render the catalogue's `rowTitle` — a literal in "
                       + "`ChannelSidebarView` is how it shipped as \"Plugin screen…\" while the "
                       + "unit test pinned `rowTitle`")
        XCTAssertFalse(row.label.contains("Plugin screen"),
                       "the row is a route into the plugin namespace, not a promised screen")
        row.tap()

        // The prompt is titled for what it does, not for what it cannot promise.
        XCTAssertTrue(app.navigationBars["Plugin route"].waitForExistence(timeout: 20),
                      "the plugin prompt must name the route it opens")
        let field = element(app, "webFallbackPluginField")
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the plugin-id prompt must appear")
        let open = app.buttons["webFallbackPluginOpen"]
        XCTAssertFalse(open.isEnabled, "an empty id is not a route")

        field.tap()
        field.typeText("com.mattermost.calls")
        XCTAssertTrue(open.isEnabled, "a plugin id is one path segment under /plugins/")
        open.tap()

        // The sheet is titled "Plugin route: <id>" — the label the repair is about.
        XCTAssertTrue(app.navigationBars["Plugin route: com.mattermost.calls"]
                        .waitForExistence(timeout: 30),
                      "the sheet must say it opened a route, not a plugin screen")

        // The prompt closes and the surface opens; the route is what it says it is. Waited for, not
        // read once: the sheet exists before its first navigation commits, and the state carries the
        // shell's URL until then (`loading|installed|http://127.0.0.1:8065/` — measured when this
        // assertion raced the load, `build/logs/t46-leak-r2.log`).
        //
        // What this fixture actually answers: `/plugins/<id>` is a **301 to `/`** for every installed
        // plugin, so the committed page is the web app, not a page at the plugin path. Both facts are
        // asserted: the shell asked for exactly `/plugins/com.mattermost.calls`, and the answer that
        // came back is a rendered page (the server's, signed in) rather than a white rectangle.
        let pane = element(app, "webFallbackPane")
        XCTAssertTrue(pane.waitForExistence(timeout: 30),
                      "a plugin route must open a webview")
        let routed = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                let value = String(describing: (object as? XCUIElement)?.value ?? "")
                guard value.hasPrefix("loaded|"),
                      value.contains("|requested=\(self.serverURL.absoluteString)/plugins/com.mattermost.calls"),
                      let painted = self.paintedCharacters(in: value) else { return false }
                return painted >= 120
            },
            object: pane)
        let reached = XCTWaiter().wait(for: [routed], timeout: 90)
        let value = String(describing: pane.value ?? "")
        XCTAssertEqual(reached, .completed,
                       "the fallback must address exactly the plugin root (state: \(value))")
        print("T46 plugin route state: \(value)")
        // Named for the evidence it is (T46-R R2): the request, not "the plugin's screen".
        attachment(app, named: "t46-plugin-route-request")
        app.buttons["webFallbackClose"].tap()
        XCTAssertTrue(element(app, "nativeShell").waitForExistence(timeout: 20))
    }

    // MARK: - Helpers

    private func ping() throws {
        let url = serverURL.appendingPathComponent("api/v4/system/ping")
        let semaphore = DispatchSemaphore(value: 0)
        var reachable = false
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { _, response, _ in
            reachable = (response as? HTTPURLResponse)?.statusCode == 200
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 10)
        try XCTSkipUnless(reachable, "no Mattermost server at \(serverURL.absoluteString)")
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetPersistedState",
                               "-uiTestForgetSession", serverURL.absoluteString,
                               "-uiTestSeedServer", serverURL.absoluteString,
                               "-uiTestSeedServerName", "Local Mattermost",
                               "-surfaceMode", "shell=native",
                               "-surfaceMode", "auth=native",
                               "-surfaceMode", "sidebar=native",
                               "-uiTestLogLevel", "error",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"
        app.launch()
        signIn(app)
        return app
    }

    /// The native sign-in (S01/S02). Deliberately the native form: it leaves the server's webview
    /// store **empty**, which is the state the fallback has to bridge.
    private func signIn(_ app: XCUIApplication) {
        let field = app.textFields["loginIDField"]
        XCTAssertTrue(field.waitForExistence(timeout: 30),
                      "the native sign-in must mount against \(serverURL.absoluteString):\n"
                      + "\(app.debugDescription)")
        field.tap()
        field.typeText(loginID)
        let secret = app.secureTextFields["loginPasswordField"]
        XCTAssertTrue(secret.exists)
        secret.tap()
        secret.typeText(password)
        // The keyboard covers the button on a phone. `LoginView` submits from the password field's
        // `onSubmit` (`submitLabel(.go)`), so the keyboard's Go key is the person-shaped way in;
        // a covered button reports a {−1,−1} hit point and taps nothing at all — which is exactly
        // how this test failed the first time (see build/logs/t46-ui-sim2.log, t=10.38s).
        let submit = app.buttons["loginSubmitButton"]
        if submit.isHittable {
            submit.tap()
        } else {
            let go = app.keyboards.buttons["Go"]
            if go.waitForExistence(timeout: 5) {
                go.tap()
            } else {
                submit.tap()
            }
        }
        // Not `nativeShell`: since `t_295b0a32` a signed-in launch opens a channel and pushes it
        // **over** the list, so the shell container is absent until `Back` (t_9399c0b4).
        XCTAssertTrue(ShellSettle.waitForSignedIn(app, timeout: 60),
                      "signing in must reach the shell:\n\(app.debugDescription)")
        // Every test here taps rows in the sidebar's own sections, and those only exist while the
        // channel list is on screen: pop the pane the launch pushed first
        // (`ShellSettle.revealChannelList`). It also keeps the `nativeShell` waits later in each test
        // (after a fallback closes) honest, because the root stays the root.
        ShellSettle.revealChannelList(app)
    }

    /// Tap a row in the sidebar's "Web view" section and wait for a **painted** page whose committed
    /// URL carries `surface`.
    ///
    /// "Painted" is the part that is not the navigation's opinion: `didFinish` fires on the web app's
    /// HTML shell, and on the System Console that shell is a white rectangle for the ~1 s its bundle
    /// takes to route to `/admin_console/about/license`. The pane's value carries the page's own
    /// `document.body.innerText` count (`|chars=N`), so this waits for the server's content, and the
    /// attachment taken afterwards is a picture of it (`docs/t46-build-note.md` §7.3).
    private func openSurface(_ app: XCUIApplication,
                             row: String,
                             surface: String,
                             timeout: TimeInterval = 90,
                             // The same threshold as `WebFallbackModel.paintedSurfaceThreshold`
                             // (the UI bundle does not link the app module, so the number is
                             // repeated here; the model's doc comment is where it is justified).
                             minPainted: Int = 120,
                             screenshot: Bool = false) -> XCUIElement {
        let button = element(app, row)
        XCTAssertTrue(scrollTo(app, element: button),
                      "the \(row) row must be reachable in the native sidebar")
        button.tap()

        let pane = element(app, "webFallbackPane")
        XCTAssertTrue(pane.waitForExistence(timeout: 30),
                      "the fallback webview must mount for \(surface)")
        let loaded = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                let value = String(describing: (object as? XCUIElement)?.value ?? "")
                // The committed URL is the only thing the web content reports reliably here (its
                // accessibility tree is a platform document, not the page's buttons), so it carries
                // the claim: a *loaded* page, at this surface, not the web app's first-visit landing
                // page — and, once the page has answered the paint probe, how much the server's own
                // content has drawn.
                guard value.hasPrefix("loaded|"),
                      let committed = self.committedURL(in: value),
                      committed.contains(surface),
                      !committed.contains("/landing#") else { return false }
                guard minPainted > 0 else { return true }
                guard let painted = self.paintedCharacters(in: value) else { return false }
                return painted >= minPainted
            },
            object: pane)
        let result = XCTWaiter().wait(for: [loaded], timeout: timeout)
        if let state = pane.value as? String {
            // Printed, not only attached: the run's log then carries the measured character count, so
            // "it rendered" is a number in `build/logs/` and not only a picture.
            print("T46 \(row) state: \(state)")
        }
        attachment(app, named: result == .completed
                   ? "t46-\(row)-loaded"
                   : "t46-\(row)-not-loaded")
        XCTAssertEqual(result, .completed,
                       "\(row) must render \(surface) with the server's own content (state: "
                       + "\(String(describing: pane.value)); a blank page or `chars=0` here is the "
                       + "WebViewContainer/teardown or the paint failure mode)")
        if screenshot { attachment(app, named: "t46-cycle-\(row)") }
        return pane
    }

    /// `loaded|installed|https://host/path|chars=1234|requested=https://host/x` -> 1234, or nil when
    /// the page has not answered.
    private func paintedCharacters(in state: String) -> Int? {
        guard let range = state.range(of: "|chars=") else { return nil }
        let digits = state[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    /// The **committed** URL field (the third pipe-separated field), or nil when the app has not
    /// committed a page yet.
    private func committedURL(in state: String) -> String? {
        let parts = state.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        return String(parts[2])
    }

    /// The session decision (the second field): `installed`, `shared`, `none` or `unavailable`.
    private func sessionDecision(in state: String) -> String? {
        let parts = state.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 2, !parts[1].isEmpty else { return nil }
        return String(parts[1])
    }

    /// The sidebar's own scroll surface (`ShellSettle.channelSidebarScroll`): rows below the fold are
    /// not built at all (T8f), so a test has to scroll the list it is looking at.
    private func scrollTo(_ app: XCUIApplication, element: XCUIElement, attempts: Int = 8) -> Bool {
        if element.exists { return true }
        let scroll = app.descendants(matching: .any)
            .matching(identifier: "channelSidebar.scroll").firstMatch
        guard scroll.waitForExistence(timeout: 10) else { return element.exists }
        for _ in 0..<attempts {
            scroll.swipeUp()
            if element.exists { return true }
        }
        return element.exists
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func attachment(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
