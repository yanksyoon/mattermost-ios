import XCTest

/// XCUITest suite for the Mattermost iOS shell (native chrome: onboarding pager,
/// add-server form, server switcher, settings, downloads, cert prompt).
///
/// Determinism model — each test launches the app with `-uiTestResetPersistedState`,
/// a DEBUG-gated seam in `MattermostApp.init()` that wipes the UserDefaults-backed shell
/// stores (servers, settings, download journal, onboarding flag) so every test starts from
/// a genuine fresh-first-run. Keychain creds are deliberately not touched.
///
/// Accessibility note: the Welcome pager's container carries `accessibilityIdentifier
/// "welcomeView"`, which SwiftUI propagates down to every descendant (the pager becomes a
/// CollectionView, and the prev/next/Get-started buttons all surface with that inherited
/// identifier rather than their own). So tests match the pager by element *type +
/// "welcomeView"*, and the buttons by their stable *labels* ("Previous page", "Next page",
/// "Get started", "Page N").
///
/// Network strategy — deterministic flows target local stub Mattermost servers
/// (`build/uitest-server/mm_stub.py`), reachable from the simulator because it shares the
/// host's loopback stack and ATS exempts loopback connections. The community.mattermost.com
/// login-through-webview flow is a *separate, network-gated* test and is flagged as such.
///
/// Stubs (see build/uitest-server/):
///   8111 HTTP  "Local Mattermost Test"            -> add/switcher/settings/downloads
///   8443 HTTPS self-signed "Self Signed Test"     -> cert prompt (untrusted TLS challenge)
final class MattermostUITests: XCTestCase {

    static let stubHTTP = "http://127.0.0.1:8111"
    /// Distinct hostname string so ServerStore's duplicate-host guard treats it as a second
    /// server; resolves to loopback like 8111.
    static let stubHTTP2 = "http://localhost:8111"
    static let stubTLS = "https://127.0.0.1:8443"
    /// Stub whose `GET /` stalls mid-body (`--stall-html`): the document commits, the navigation
    /// stays in flight. Fixture for the T26-R R6 mid-load toggle repro.
    static let stubStalledHTTP = "http://127.0.0.1:8112"

    static let resetArg = "-uiTestResetPersistedState"
    static let webLoadWait: TimeInterval = 20
    /// Stub whose `GET /` plants a session cookie on the first load and serves a signed-in
    /// workspace page (3 s late) on later loads — the T26-R R4a release/reopen fixture.
    static let stubSession = "http://127.0.0.1:8113"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launch with a wiped store so every test starts at the Welcome/first-run pager.
    @discardableResult
    func launchFresh() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [Self.resetArg, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    // MARK: - Onboarding → add server

    func testOnboardingPagerGetStartedOpensAddServerForm() {
        let app = launchFresh()

        // The pager surfaces as a CollectionView with the inherited "welcomeView" identifier.
        let welcome = app.collectionViews["welcomeView"]
        XCTAssertTrue(welcome.waitForExistence(timeout: 10),
                      "Fresh install must land on the Welcome onboarding pager")

        // Next chevron steps through slides (matches the pager's inherited id).
        let next = app.buttons["Next page"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.tap()
        XCTAssertTrue(app.buttons["Previous page"].exists)

        let getStarted = app.buttons["Get started"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 5))
        getStarted.tap()

        let nameField = app.textFields["Display name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Server URL"].exists)
        let save = app.buttons["Save"]
        XCTAssertTrue(save.exists)
        XCTAssertFalse(save.isEnabled, "Save disabled until a name + validated URL")
    }

    /// Add server via the local stub; the webview loads the stub's login HTML → login-through-webview.
    func testAddServerThroughFormThenWebviewLoad() {
        let app = launchFresh()
        addFirstServer(app: app, name: "Local", url: Self.stubHTTP)

        // The webview now presents the stub login page.
        let webview = app.webViews.firstMatch
        XCTAssertTrue(webview.waitForExistence(timeout: Self.webLoadWait),
                      "Webview should load the stub login page after adding a server")
    }

    // MARK: - Server switch

    func testServerSwitchBetweenTwoServers() {
        let app = launchFresh()
        addFirstServer(app: app, name: "Alpha", url: Self.stubHTTP)

        // Add a second server from the toolbar (visible because ≥1 server exists).
        let addButton = app.buttons["addServerToolbarButton"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()
        addServerInForm(app: app, name: "Beta", url: Self.stubHTTP2)

        // Switcher shows the active server (most recently added → Beta is primary).
        let switcher = app.buttons["serverSwitcher"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 5))

        // Open the switcher and select Alpha.
        switcher.tap()
        let alphaOption = app.buttons["Alpha"]
        XCTAssertTrue(alphaOption.waitForExistence(timeout: 5))
        alphaOption.tap()

        // Switcher label reflects the active server name.
        let switcherAfter = app.buttons["serverSwitcher"]
        XCTAssertTrue(switcherAfter.waitForExistence(timeout: 5))
        XCTAssertTrue(switcherAfter.label.contains("Alpha"),
                      "Switcher should show Alpha as active, got '\(switcherAfter.label)'")
    }

    // MARK: - Settings persist

    func testSettingsDownloadHistoryLimitPersists() {
        let app = launchFresh()
        addFirstServer(app: app, name: "Local", url: Self.stubHTTP)

        app.buttons["settingsToolbarButton"].tap()
        XCTAssertTrue(app.otherElements["settingsView"].waitForExistence(timeout: 5))

        let keepLabel = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Keep up to'")).firstMatch
        XCTAssertTrue(keepLabel.waitForExistence(timeout: 5))
        let original = keepLabel.label

        let stepper = app.steppers.firstMatch
        XCTAssertTrue(stepper.waitForExistence(timeout: 5))
        let increment = stepper.buttons["Increment"]
        XCTAssertTrue(increment.exists, "Stepper must expose an increment control")
        increment.tap()

        app.buttons["Done"].tap()

        // Reopen Settings in the same session — value must have persisted in AppSettings.
        app.buttons["settingsToolbarButton"].tap()
        let reopened = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Keep up to'")).firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 5))
        XCTAssertNotEqual(reopened.label, original, "Stepper change should persist across a reopen")
        app.buttons["Done"].tap()
    }

    // MARK: - Downloads

    func testDownloadsOpensToEmptyState() {
        let app = launchFresh()
        addFirstServer(app: app, name: "Local", url: Self.stubHTTP)

        app.buttons["downloadsToolbarButton"].tap()
        XCTAssertTrue(app.otherElements["downloadsView"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No Downloads"].exists,
                      "Fresh journal should render the empty Downloads state")
        app.buttons["Close"].tap()
    }

    // MARK: - Cert prompt

    /// The add-server form cannot save a self-signed server (URLSession rejects its TLS during
    /// validation), so the cert-prompt UI is reached by seeding the store with a server aimed
    /// at the self-signed TLS stub; the webview then present an untrusted-certificate challenge
    /// and CertPromptSheet must appear.
    func testCertPromptShownForSelfSignedServer() {
        let app = XCUIApplication()
        app.launchArguments = [Self.resetArg,
                               "-uiTestSeedSelfSignedServer", Self.stubTLS,
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let prompt = app.otherElements["certPromptSheet"]
        XCTAssertTrue(prompt.waitForExistence(timeout: Self.webLoadWait),
                      "Loading a self-signed server should present the certificate prompt")
        XCTAssertTrue(app.buttons["Trust"].exists)
        XCTAssertTrue(app.buttons["Cancel"].exists)
        let dontAsk = app.buttons["Don't Trust and Don't Ask Again"]
        XCTAssertTrue(dontAsk.exists)
        // Declining for now dismisses the prompt.
        app.buttons["Cancel"].tap()
    }

    // MARK: - Dual-render harness (T26)

    /// Acceptance criterion: launching with `-surfaceMode channelView=native` while every other
    /// surface keeps its `web` default must still render a working app — the workspace pane is the
    /// native stand-in (no webview mounted), and the shell chrome (switcher, settings, downloads,
    /// history) is untouched. "Use web view" then returns a *rendered* webview (the stub's sign-in
    /// form), not a blank one.
    func testLaunchArgumentRendersNativeChannelViewWithChromeIntact() {
        let app = XCUIApplication()
        app.launchArguments = [Self.resetArg,
                               "-surfaceMode", "channelView=native",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        addFirstServer(app: app, name: "Local", url: Self.stubHTTP)

        let standIn = element(app, "unportedSurface.channelView")
        XCTAssertTrue(standIn.waitForExistence(timeout: Self.webLoadWait),
                      "channelView=native must render the native stand-in")

        // Negative evidence: the webview pane is not mounted at all, so it cannot be blank-but-
        // present (that is the failure mode a "still renders" check has to exclude).
        XCTAssertFalse(app.webViews.firstMatch.exists,
                       "no webview pane may be mounted for a native surface")

        // Shell chrome is independent of the surface decision.
        XCTAssertTrue(app.buttons["serverSwitcher"].exists, "server switcher must survive")
        XCTAssertTrue(app.buttons["settingsToolbarButton"].exists)
        XCTAssertTrue(app.buttons["downloadsToolbarButton"].exists)
        XCTAssertTrue(app.buttons["backToolbarButton"].exists)

        // Settings still opens over the native pane.
        app.buttons["settingsToolbarButton"].tap()
        XCTAssertTrue(app.otherElements["settingsView"].waitForExistence(timeout: 5),
                      "settings must still open while the surface is native")
        app.buttons["Done"].tap()

        // Always-usable escape hatch: back to a *loaded* webview.
        let useWeb = app.buttons["revertToWebchannelView"]
        XCTAssertTrue(useWeb.waitForExistence(timeout: 5))
        useWeb.tap()

        let webview = app.webViews.firstMatch
        XCTAssertTrue(webview.waitForExistence(timeout: Self.webLoadWait),
                      "returning to web must mount the webview again")
        XCTAssertTrue(webview.buttons["Sign in"].waitForExistence(timeout: Self.webLoadWait),
                      "the returning webview must actually render the stub's sign-in page")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "dual-render-web-restored"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Acceptance criterion: toggling a surface at runtime returns to a working state — no blank
    /// screen, no duplicated webview — driven through the debug Surface inspector the way a
    /// developer would.
    func testSurfaceInspectorTogglesChannelViewAndReturnsToWorkingState() {
        let app = launchFresh()
        addFirstServer(app: app, name: "Local", url: Self.stubHTTP)

        let webview = app.webViews.firstMatch
        XCTAssertTrue(webview.waitForExistence(timeout: Self.webLoadWait))
        XCTAssertTrue(webview.buttons["Sign in"].waitForExistence(timeout: Self.webLoadWait))

        openSurfaceInspector(app)

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "surface-inspector"
        shot.lifetime = .keepAlways
        add(shot)

        let picker = channelViewPicker(app)
        XCTAssertTrue(picker.waitForExistence(timeout: 5),
                      "the inspector must expose a renderer picker per surface")
        picker.buttons["Native"].tap()
        dismissSurfaceInspectorAndSettings(app)

        XCTAssertTrue(element(app, "unportedSurface.channelView").waitForExistence(timeout: 10),
                      "toggling channelView to Native must swap the pane to the native stand-in")
        XCTAssertFalse(app.webViews.firstMatch.exists,
                       "the webview pane must be unmounted, not stacked under the stand-in")

        // Toggle back through the same UI: the webview returns, rendered, exactly once.
        openSurfaceInspector(app)
        let pickerAgain = channelViewPicker(app)
        XCTAssertTrue(pickerAgain.waitForExistence(timeout: 5))
        pickerAgain.buttons["Web view"].tap()
        dismissSurfaceInspectorAndSettings(app)

        let restored = app.webViews.firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: Self.webLoadWait),
                      "toggling back must restore the webview")
        XCTAssertTrue(restored.buttons["Sign in"].waitForExistence(timeout: Self.webLoadWait),
                      "the restored webview must still render (session re-attached, not blank)")
        // NOTE: `app.webViews.count` is deliberately not asserted here — a full webview
        // enumeration hangs XCUITest's accessibility snapshot on this host (measured: wedged
        // >4 min at "Get number of matches for: Descendants matching type WebView"). The
        // one-webview-per-server invariant is pinned deterministically in the unit suite instead
        // (`SurfaceModeResolverTests.testWebViewInstanceIsStableAcrossSurfaceToggles`), and the
        // `firstMatch` + rendered "Sign in" assertions above cover the visible half here.
        XCTAssertFalse(element(app, "unportedSurface.channelView").exists)
    }

    /// T26-R R6 [investigate]: a surface toggle that dismantles the web branch **while the
    /// webview's main-frame navigation is still in flight** must not strand a stopped page.
    ///
    /// The fixture is the slow stub (`http://127.0.0.1:8112`, `--stall-image 45`): `GET /` is a
    /// normal page that commits immediately, but its `<img src="/slow.png">` is trickled over 45 s
    /// and the `Sign in` button is hidden until that image's `onload` fires. So when the toggle
    /// below dismantles the web branch, the document is committed (`url != nil`) and the load is
    /// unfinished — exactly the state in which `dismantleUIView` → `stopLoading()` used to leave a
    /// page that `loadIfNeeded()` then refused to resume. The button can only appear if the load
    /// completes, and after an interruption that requires the shell to resume the navigation.
    ///
    /// Note: WebKit exposes web-content accessibility only once a load settles, so the test cannot
    /// assert on the page mid-load; "no `Sign in`" is the incomplete-load precondition, and the
    /// pre-fix failure of this test is what proved the bug.
    func testMidLoadSurfaceToggleResumesTheInterruptedWebview() throws {
        // The slow stub is a gitignored fixture (`build/uitest-server/mm_stub.py`), like every stub
        // this suite uses. Skip with the exact command instead of failing the suite on a host where
        // it is not running — a red suite for a missing fixture hides real regressions.
        try XCTSkipUnless(Self.isFixtureReachable(Self.stubStalledHTTP),
                          "slow stub not running — start it with: python3 build/uitest-server/mm_stub.py "
                          + "--port 8112 --stall-image 45 --name \"Slow Test\"")
        let app = launchFresh()
        addFirstServer(app: app, name: "Stalled", url: Self.stubStalledHTTP)

        let webview = app.webViews.firstMatch
        XCTAssertTrue(webview.waitForExistence(timeout: Self.webLoadWait),
                      "the slow server's page must mount")
        XCTAssertFalse(webview.buttons["Sign in"].exists,
                       "precondition: the body is still incomplete, so nothing has finished the load")

        // Dismantle the web branch mid-load, then bring it back through the same UI.
        openSurfaceInspector(app)
        channelViewPicker(app).buttons["Native"].tap()
        dismissSurfaceInspectorAndSettings(app)
        XCTAssertTrue(element(app, "unportedSurface.channelView").waitForExistence(timeout: 10),
                      "the native stand-in must mount (this dismantles the webview view)")

        openSurfaceInspector(app)
        let pickerAgain = channelViewPicker(app)
        XCTAssertTrue(pickerAgain.waitForExistence(timeout: 5))
        pickerAgain.buttons["Web view"].tap()
        dismissSurfaceInspectorAndSettings(app)

        let restored = app.webViews.firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 10),
                      "returning to web must re-mount the webview")
        // The stub's image needs 45 s, and a resumed navigation re-fetches it: 75 s leaves room
        // for a resume but not for "the original transfer finished late" (it was stopped).
        XCTAssertTrue(restored.buttons["Sign in"].waitForExistence(timeout: 75),
                      "the load interrupted by the toggle must be resumed, not left stranded")
    }

    /// T26-R R4a acceptance: a pane whose webview was **released** must come back honestly — a
    /// visible blocking "Reopening web view…" state, then the web app signed in, without a second
    /// tap and without a re-login.
    ///
    /// Fixture: `mm_stub.py --port 8113 --cookie-session 3` (gitignored, like every stub here).
    /// The stub plants an `MMAUTHTOKEN` cookie on the first page load and serves a signed-in
    /// workspace page (`Workspace`, no login form) — three seconds late — on every later request
    /// that carries the cookie. The assertions therefore cover three distinct claims at once:
    ///   * the released store really was destroyed: `webPaneReopening` only exists while there is no
    ///     committed page, i.e. after a brand-new store/WebContent process started loading;
    ///   * the session survived the release: the reopened page renders the workspace, not the
    ///     sign-in form, because the cookie came back out of the persistent per-server data store
    ///     (`docs/dual-render.md` §12.3);
    ///   * the webview-only chrome returns with the webview (Back/Reload are absent while released).
    ///
    /// `-releaseWebViewForTesting` arms the policy's `allowUnapproved` bypass for this run only:
    /// DEBUG builds, and only when `debugAffordancesEnabled` is true. Both shipping registries stay
    /// empty, so no shipping configuration can take this path.
    func testReleasedPaneReopensWebViewWithSessionAndHonestState() throws {
        try XCTSkipUnless(Self.isFixtureReachable(Self.stubSession),
                          "session stub not running — start it with: python3 build/uitest-server/mm_stub.py "
                          + "--port 8113 --cookie-session 3 --name \"Session Test\"")
        try XCTSkipUnless(Self.sessionFixtureDelay(Self.stubSession) >= 2,
                          "the stub at \(Self.stubSession) is not the cookie-session fixture (or its "
                          + "delay is under 2 s, which makes the reopening state unobservable) — "
                          + "restart it with: python3 build/uitest-server/mm_stub.py --port 8113 "
                          + "--cookie-session 3 --name \"Session Test\"")

        let app = XCUIApplication()
        app.launchArguments = [Self.resetArg,
                               "-releaseWebViewForTesting",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        addFirstServer(app: app, name: "Session", url: Self.stubSession)

        // 1. The first load plants the session cookie and shows the sign-in form.
        let webview = app.webViews.firstMatch
        XCTAssertTrue(webview.waitForExistence(timeout: Self.webLoadWait),
                      "the added server's page must mount")
        XCTAssertTrue(webview.buttons["Sign in"].waitForExistence(timeout: Self.webLoadWait),
                      "the first load is the stub's sign-in page (it is what plants the cookie)")
        XCTAssertTrue(app.buttons["backToolbarButton"].exists,
                      "a live webview offers history chrome")

        // 2. Flip the pane native through the debug inspector — the release policy now applies.
        openSurfaceInspector(app)
        channelViewPicker(app).buttons["Native"].tap()
        dismissSurfaceInspectorAndSettings(app)

        XCTAssertTrue(element(app, "unportedSurface.channelView").waitForExistence(timeout: 10),
                      "the native stand-in must mount")
        XCTAssertFalse(app.webViews.firstMatch.exists,
                       "the released webview is not mounted — it is destroyed, not parked")
        XCTAssertTrue(waitUntil(timeout: 5) { !app.buttons["backToolbarButton"].exists },
                      "a released pane has no webview history, so the history chrome must be gone")

        // 3. "Use web view": honest state first, then the signed-in web app.
        let useWeb = app.buttons["revertToWebchannelView"]
        XCTAssertTrue(useWeb.waitForExistence(timeout: 5))
        useWeb.tap()

        let reopening = app.descendants(matching: .any)
            .matching(identifier: "webPaneReopening").firstMatch
        let stateShown = reopening.waitForExistence(timeout: 5)
        if !stateShown {
            // Diagnostics only on the failure path: what the pane actually exposed to XCUITest.
            print("PANETREE-BEGIN\n\(app.debugDescription)\nPANETREE-END")
        }
        XCTAssertTrue(stateShown,
                      "a released pane must show the blocking 'Reopening web view…' state")
        let reopeningShot = XCTAttachment(screenshot: app.screenshot())
        reopeningShot.name = "released-pane-reopening"
        reopeningShot.lifetime = .keepAlways
        add(reopeningShot)

        let restored = app.webViews.firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: Self.webLoadWait),
                      "the webview must re-mount")
        XCTAssertTrue(restored.staticTexts["Workspace"].waitForExistence(timeout: Self.webLoadWait),
                      "the reopened pane renders the signed-in workspace")
        XCTAssertFalse(restored.buttons["Sign in"].exists,
                       "…and not the login form: the session survived the release (§12.3)")
        XCTAssertTrue(app.buttons["backToolbarButton"].waitForExistence(timeout: 5),
                      "webview-only chrome comes back with the webview")

        let restoredShot = XCTAttachment(screenshot: app.screenshot())
        restoredShot.name = "released-pane-reopened-session-intact"
        restoredShot.lifetime = .keepAlways
        add(restoredShot)
    }

    // MARK: - Dual-render helpers

    /// Seconds the cookie-session stub stalls the authenticated page, or 0 when the endpoint says
    /// this stub is not that fixture (3 s budget). Same guard-rail as `isFixtureReachable`: a
    /// fixture mismatch must skip the flow, not fail it.
    static func sessionFixtureDelay(_ base: String) -> Double {
        guard let url = URL(string: base + "/__session-fixture") else { return 0 }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let semaphore = DispatchSemaphore(value: 0)
        var delay = 0.0
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let value = object["delay_s"] as? Double {
                delay = value
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 5)
        return delay
    }

    /// Whether a stub fixture answers `/api/v4/system/ping` (3 s budget).
    /// Every stub this suite uses lives in `build/uitest-server/` (gitignored), so a flow that needs
    /// a *specific* stub invocation must be able to tell "fixture missing" from "behaviour broken".
    static func isFixtureReachable(_ base: String, timeout: TimeInterval = 3) -> Bool {
        guard let url = URL(string: base + "/api/v4/system/ping") else { return false }
        let semaphore = DispatchSemaphore(value: 0)
        var reachable = false
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        URLSession.shared.dataTask(with: request) { _, response, _ in
            reachable = (response as? HTTPURLResponse)?.statusCode == 200
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 2)
        return reachable
    }

    /// Settings → Developer → "Surface render modes…", scrolling the form to the developer
    /// section (it is the last one).
    private func openSurfaceInspector(_ app: XCUIApplication) {
        app.buttons["settingsToolbarButton"].tap()
        XCTAssertTrue(app.otherElements["settingsView"].waitForExistence(timeout: 5))

        let button = app.buttons["surfaceInspectorButton"]
        var attempts = 0
        while !(button.exists && button.isHittable) && attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(button.waitForExistence(timeout: 5),
                      "a DEBUG build must expose Settings → Developer → Surface render modes")
        button.tap()

        XCTAssertTrue(app.navigationBars["Surface Inspector"].waitForExistence(timeout: 5),
                      "the Surface inspector sheet must present")
    }

    private func dismissSurfaceInspectorAndSettings(_ app: XCUIApplication) {
        let done = app.buttons["surfaceInspectorDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        let settingsDone = app.buttons["Done"]
        XCTAssertTrue(settingsDone.waitForExistence(timeout: 5))
        settingsDone.tap()
    }

    /// The `channelView` row's segmented renderer picker. SwiftUI hosts a `.segmented` `Picker` as
    /// a `segmentedControl`, but the identifier lands on the control only if it propagates; fall
    /// back to the option buttons inside the row container.
    private func channelViewPicker(_ app: XCUIApplication) -> XCUIElement {
        let byIdentifier = app.segmentedControls.matching(identifier: "surfaceMode.channelView").firstMatch
        if byIdentifier.exists { return byIdentifier }
        let scoped = element(app, "surfaceRow.channelView")
            .descendants(matching: .segmentedControl).firstMatch
        if scoped.exists { return scoped }
        // Last resort: auth/sidebar/channelView are the first three rows of the inspector list.
        return app.segmentedControls.element(boundBy: 2)
    }

    /// Any element type carrying `identifier`. SwiftUI decides whether an identifier lands on an
    /// `other`, a `staticText` or a `button` (and that changes across OS versions), so tests must
    /// not assume a type.
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    // MARK: - Helpers

    /// Add the first server, expecting to start from the Welcome pager ("Get started").
    private func addFirstServer(app: XCUIApplication, name: String, url: String) {
        let getStarted = app.buttons["Get started"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 10),
                      "First server is added from the Welcome screen's Get started")
        getStarted.tap()
        addServerInForm(app: app, name: name, url: url)
    }

    private func addServerInForm(app: XCUIApplication, name: String, url: String) {
        let nameField = app.textFields["Display name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText(name)

        let urlField = app.textFields["Server URL"]
        urlField.tap()
        urlField.typeText(url)

        // Save enables only after the stub validates the URL (ping + site name probe).
        let save = app.buttons["Save"]
        let enabled = NSPredicate(format: "isEnabled == true")
        expectation(for: enabled, evaluatedWith: save)
        waitForExpectations(timeout: Self.webLoadWait)
        save.tap()
        // The add sheet dismisses once saved.
        XCTAssertTrue(waitUntil(timeout: 5) { !nameField.exists })
    }

    /// Poll a predicate with a timeout (no XCTest expectation needed).
    private func waitUntil(timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return cond()
    }

    // MARK: - Live SSO (network-gated)

    /// Live SSO check against a real workspace. The server URL comes from the environment so no
    /// private host is baked into this repository:
    ///
    ///     TEST_RUNNER_MM_LIVE_SSO_URL=https://chat.example.com xcodebuild test ...
    ///
    /// Loads the workspace's SAML entry point and asserts the identity provider's form renders
    /// with no certificate sheet. The button-click path is covered by the preload's SSO entry
    /// guard (`Bridge.preloadJavascript`), which forces a document load for /login/sso/ links.
    ///
    /// Network-gated: skipped unless `TEST_RUNNER_MM_LIVE_SSO_URL` is set.
    func testSSOReachesIdentityProviderWithoutCertificatePrompt() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_LIVE_SSO_URL"] ?? ""
        try XCTSkipUnless(!raw.isEmpty, "Live SSO test: set TEST_RUNNER_MM_LIVE_SSO_URL to run")
        guard let url = URL(string: raw), let host = url.host else {
            throw XCTSkip("MM_LIVE_SSO_URL is not a URL")
        }

        let app = XCUIApplication()
        app.launchArguments = [Self.resetArg,
                               "-uiTestSeedSelfSignedServer", "https://\(host)/login/sso/saml",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let webview = app.webViews.firstMatch
        XCTAssertTrue(webview.waitForExistence(timeout: Self.webLoadWait),
                      "the SAML entry point must render")

        XCTAssertFalse(app.otherElements["certPromptSheet"].waitForExistence(timeout: 5),
                       "an identity provider's public certificate must never raise the trust sheet")

        let idp = webview.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Ubuntu One"))
            .firstMatch
        XCTAssertTrue(idp.waitForExistence(timeout: Self.webLoadWait),
                      "SSO must reach the identity provider instead of an empty page")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "sso-identity-provider"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
