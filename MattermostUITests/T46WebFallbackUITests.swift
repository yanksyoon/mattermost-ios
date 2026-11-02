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

    // MARK: - 2. Teardown and recreation

    /// Twenty presentations. Each one is a fresh `WebFallbackModel` (the sheet's item identity
    /// carries a token), and each must reach a loaded page — a leaked webview does not fail a tap,
    /// so the assertion is that the *twentieth* one still renders. `scripts/t46_leak_probe.py` watches
    /// the app's WebContent children while this runs and reports the count returning to baseline.
    func testTwentyOpenCloseCyclesEachRender() throws {
        let app = launchApp()
        let cycles = 20
        for cycle in 0..<cycles {
            let pane = openSurface(app, row: "webFallbackRow.systemConsole",
                                   surface: "/admin_console", timeout: 60,
                                   screenshot: cycle == 0 || cycle == cycles - 1)
            app.buttons["webFallbackClose"].tap()
            let gone = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: pane)
            XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 30), .completed,
                           "cycle \(cycle): the fallback webview must go away when its sheet closes")
        }
    }

    // MARK: - 3. Plugin screens

    /// A plugin screen is `/plugins/<id>`; the prompt refuses an id that is not one path segment
    /// until it is valid, and then opens exactly that route.
    func testAPluginScreenIsAddressableByID() throws {
        let app = launchApp()

        let row = element(app, "webFallbackRow.plugin")
        XCTAssertTrue(scrollTo(app, element: row), "the Plugin screen row must be reachable")
        row.tap()

        let field = element(app, "webFallbackPluginField")
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the plugin-id prompt must appear")
        let open = app.buttons["webFallbackPluginOpen"]
        XCTAssertFalse(open.isEnabled, "an empty id is not a route")

        field.tap()
        field.typeText("com.mattermost.calls")
        XCTAssertTrue(open.isEnabled, "a plugin id is one path segment under /plugins/")
        open.tap()

        // The prompt closes and the surface opens; the route is what it says it is. Waited for, not
        // read once: the sheet exists before its first navigation commits, and the state carries the
        // shell's URL until then (`loading|installed|http://127.0.0.1:8065/` — measured when this
        // assertion raced the load, `build/logs/t46-leak-r2.log`).
        //
        // What this fixture actually answers: `/plugins/<id>` is a **301 to `/`** for every installed
        // plugin (measured: calls 301, playbooks 301, focalboard 404 — `docs/t46-build-note.md` §7.4),
        // so the committed page is the web app, not a page at the plugin path. Both facts are
        // asserted: the shell asked for exactly `/plugins/com.mattermost.calls`, and the answer that
        // came back is a rendered page (the server's, signed in) rather than a white rectangle.
        let pane = element(app, "webFallbackPane")
        XCTAssertTrue(pane.waitForExistence(timeout: 30),
                      "a plugin screen must open a webview")
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
        attachment(app, named: "t46-plugin-screen")
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
        XCTAssertTrue(element(app, "nativeShell").waitForExistence(timeout: 60),
                      "signing in must reach the shell:\n\(app.debugDescription)")
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
