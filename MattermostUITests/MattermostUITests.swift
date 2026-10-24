import XCTest
import Network

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

    /// t_ca6db268 regression: **first-time** "Trust" must render the page.
    ///
    /// A first navigation to a self-signed server dies inside the TLS handshake, so nothing
    /// commits and `WKWebView.url` stays nil. `WebViewStore.retry()` used to be
    /// `if let url { load(url) }`, so answering the prompt recorded the decision, dismissed the
    /// sheet and issued *no* navigation — the pane stayed blank forever (measured by T26-R R4-AV
    /// on four fresh origins: `webStaticTexts=0`, no prompt, no error state, 45 s).
    ///
    /// The flow asserted here is the whole user story, on a genuinely fresh trust record:
    /// prompt → Trust → the stub's sign-in page renders, no second prompt, no error overlay; then
    /// a *relaunch* of the same origin (same Keychain trust record, fresh shell state) must not
    /// prompt and must still render — the "trust survives" half that already worked, kept honest.
    ///
    /// `-uiTestForgetCertTrust <url>` (DEBUG-only seam, `MattermostApp.init`) clears any recorded
    /// decision for the origin first: the trust bag is Keychain-backed and
    /// `-uiTestResetPersistedState` deliberately leaves the Keychain alone, so without it a second
    /// run on this port would silently skip the prompt and prove nothing.
    func testCertificateTrustOnFirstLaunchRendersThePage() throws {
        try XCTSkipUnless(Self.isTLSPortOpen(Self.stubTLS),
                          "self-signed TLS stub not running — start it with: python3 "
                          + "build/uitest-server/mm_stub.py --port 8443 --tls cert.pem,key.pem "
                          + "--name \"Self Signed Test\"")
        let app = XCUIApplication()
        app.launchArguments = [Self.resetArg,
                               "-uiTestForgetCertTrust", Self.stubTLS,
                               "-uiTestSeedSelfSignedServer", Self.stubTLS,
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        // 1. A fresh origin prompts (precondition — otherwise nothing below means anything).
        let prompt = app.otherElements["certPromptSheet"]
        XCTAssertTrue(prompt.waitForExistence(timeout: Self.webLoadWait),
                      "a never-decided self-signed origin must present the certificate prompt")
        app.buttons["Trust"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !prompt.exists }, "Trust must dismiss the prompt")

        // 2. The page actually renders. This is the assertion that failed before the fix.
        let webview = app.webViews.firstMatch
        XCTAssertTrue(webview.waitForExistence(timeout: Self.webLoadWait),
                      "the webview pane must be mounted")
        let rendered = webview.buttons["Sign in"].waitForExistence(timeout: Self.webLoadWait)
        XCTAssertTrue(rendered,
                      "trusting a certificate the first time must load the page, not strand a blank pane")
        XCTAssertFalse(app.buttons["errorRetryButton"].exists,
                       "the failure overlay must not be the thing that renders")
        XCTAssertFalse(prompt.exists, "a recorded trust decision must not prompt again")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "cert-trust-first-time-page-rendered"
        shot.lifetime = .keepAlways
        add(shot)

        // 3. A later launch of the same origin honours the record: no prompt, still renders.
        app.terminate()
        app.launchArguments = [Self.resetArg,
                               "-uiTestSeedSelfSignedServer", Self.stubTLS,
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        XCTAssertFalse(app.otherElements["certPromptSheet"].waitForExistence(timeout: 5),
                       "a previously-trusted origin must not prompt again")
        let relaunched = app.webViews.firstMatch
        XCTAssertTrue(relaunched.waitForExistence(timeout: Self.webLoadWait))
        XCTAssertTrue(relaunched.buttons["Sign in"].waitForExistence(timeout: Self.webLoadWait),
                      "the recorded trust decision must be honoured on the next launch")

        // Leave the shared fixture clean: this suite's other certificate test expects a *fresh*
        // origin on the same stub port, and the trust bag outlives the app (Keychain).
        clearRecordedTrust(Self.stubTLS)
    }

    /// The other half of the prompt contract: "Don't Trust and Don't Ask Again" is an explicit
    /// refusal, so it must hard-reject — no re-prompt now or on a later launch — and must leave the
    /// honest connection-error state rather than a silent blank pane.
    func testExplicitlyUntrustedCertificateHardRejectsWithoutPrompt() throws {
        try XCTSkipUnless(Self.isTLSPortOpen(Self.stubTLS),
                          "self-signed TLS stub not running — start it with: python3 "
                          + "build/uitest-server/mm_stub.py --port 8443 --tls cert.pem,key.pem "
                          + "--name \"Self Signed Test\"")
        let app = XCUIApplication()
        app.launchArguments = [Self.resetArg,
                               "-uiTestForgetCertTrust", Self.stubTLS,
                               "-uiTestSeedSelfSignedServer", Self.stubTLS,
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let prompt = app.otherElements["certPromptSheet"]
        XCTAssertTrue(prompt.waitForExistence(timeout: Self.webLoadWait))
        app.buttons["Don't Trust and Don't Ask Again"].tap()

        let refused = app.staticTexts["Couldn't connect to this server"]
        XCTAssertTrue(refused.waitForExistence(timeout: Self.webLoadWait),
                      "a refused certificate must surface the connection-error state")
        XCTAssertFalse(prompt.exists, "an explicit refusal must not re-prompt")

        // A later launch re-consults the recorded refusal: still no prompt, still rejected.
        app.terminate()
        app.launchArguments = [Self.resetArg,
                               "-uiTestSeedSelfSignedServer", Self.stubTLS,
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        XCTAssertFalse(app.otherElements["certPromptSheet"].waitForExistence(timeout: 5),
                       "an explicitly-untrusted origin must never prompt again")
        XCTAssertTrue(app.staticTexts["Couldn't connect to this server"]
                        .waitForExistence(timeout: Self.webLoadWait),
                      "the refusal must still be enforced after a relaunch")
        XCTAssertFalse(app.webViews.firstMatch.buttons["Sign in"].waitForExistence(timeout: 5),
                       "a hard-rejected certificate must not deliver the page")

        // Leave no refusal behind: the trust bag is Keychain-backed and outlives the app, and the
        // suite's other certificate test needs a fresh origin on this port.
        clearRecordedTrust(Self.stubTLS)
    }

    /// Forget a recorded certificate decision for `origin` through the DEBUG launch seam
    /// (`MattermostApp`'s `-uiTestForgetCertTrust`), so a test cannot leak trust state into the
    /// next one. Launch-and-terminate: nothing is asserted here.
    private func clearRecordedTrust(_ origin: String) {
        let app = XCUIApplication()
        app.launchArguments = [Self.resetArg,
                               "-uiTestForgetCertTrust", origin,
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        app.terminate()
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

        let standIn = element(app, "nativeShell")
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

        XCTAssertTrue(element(app, "nativeShell").waitForExistence(timeout: 10),
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
        XCTAssertFalse(element(app, "nativeShell").exists)
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
        XCTAssertTrue(element(app, "nativeShell").waitForExistence(timeout: 10),
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

        XCTAssertTrue(element(app, "nativeShell").waitForExistence(timeout: 10),
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

    /// TCP-only "is a process listening here?" probe for the **self-signed** TLS stub.
    ///
    /// `isFixtureReachable` goes through `URLSession`, which correctly refuses a self-signed
    /// certificate — so it can never see that fixture, and using it as the guard would silently
    /// skip the certificate flows. Here the fixture's whole point is that its chain is invalid, so
    /// the probe must be transport-level: connect, then drop the connection.
    static func isTLSPortOpen(_ base: String, timeout: TimeInterval = 3) -> Bool {
        guard let url = URL(string: base), let host = url.host, let port = url.port,
              let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let semaphore = DispatchSemaphore(value: 0)
        var open = false
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: open = true; semaphore.signal()
            case .failed, .cancelled, .waiting: semaphore.signal()
            default: break
            }
        }
        connection.start(queue: .global())
        _ = semaphore.wait(timeout: .now() + timeout)
        connection.cancel()
        return open
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

    // MARK: - T30 native shell

    /// T30 acceptance: `-surfaceMode shell=native` mounts the native chrome — sidebar, placeholder
    /// panes, working server switcher — and a `mattermost://<server>/<team>/channels/<name>` deep
    /// link lands on that server **and channel inside the native stack** (the channel pane is
    /// pushed onto the shell's stack), with no webview pane mounted at all.
    ///
    /// Three DEBUG seams stand in for what a UI test cannot produce, and none of them touch the
    /// code under test: `-uiTestSeedServer` adds a server without driving the add-server form (which
    /// validates the URL over the network), `-uiTestAssumeSignedIn` substitutes the *auth gate* so
    /// the panes render for a stub server that has no real session (native login is T31), and
    /// `-uiTestOpenDeepLink` substitutes the *delivery* of the URL — XCTest cannot send a system
    /// `mattermost://` open on this toolchain. The handling is the production path:
    /// `DeepLinkRouter.handle` → `NativeNavigation` → the shell's push.
    func testNativeShellDeepLinkLandsOnTheChannelInTheNativeStack() {
        let app = XCUIApplication()
        app.launchArguments = [Self.resetArg,
                               "-surfaceMode", "shell=native",
                               "-uiTestSeedServer", "https://mm.example",
                               "-uiTestAssumeSignedIn",
                               "-uiTestOpenDeepLink", "mattermost://mm.example/acme/channels/general",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let shell = element(app, "nativeShell")

        // The deep link landed: the channel pane is on top of the shell, showing the linked channel.
        // (A pushed destination replaces the shell's root in the accessibility hierarchy, so the
        // pane — not `nativeShell` — is what is visible at launch with a link.)
        let pane = element(app, "nativeChannelPane")
        XCTAssertTrue(pane.waitForExistence(timeout: 15),
                      "a channel deep link must push the native channel pane")
        let title = element(app, "nativeChannelTitle")
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "general",
                       "the pane must show the channel the link named, got '\(title.label)'")

        // ...and it was pushed *onto the native shell*, not onto a webview.
        XCTAssertFalse(app.webViews.firstMatch.exists,
                       "no webview pane may be mounted while the native shell owns the pane")

        // The window's chrome survives the surface decision (it is shell chrome, not the pane) —
        // and it must still *work* over a pushed pane: Settings opens from the destination's own
        // toolbar, not from a bar the push has hidden.
        XCTAssertTrue(app.buttons["serverSwitcher"].waitForExistence(timeout: 10),
                      "the server switcher must still be there while the native shell is mounted")
        app.buttons["settingsToolbarButton"].tap()
        XCTAssertTrue(element(app, "settingsView").waitForExistence(timeout: 8),
                      "Settings must open from the pushed pane's chrome")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(pane.waitForExistence(timeout: 8),
                      "closing Settings must return to the pushed channel pane")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "t30-native-shell-deeplink"
        shot.lifetime = .keepAlways
        add(shot)

        // Popping back lands on the shell itself — sidebar, placeholder panes and all.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(shell.waitForExistence(timeout: 10),
                      "the pane was pushed on the native shell: back must reveal it")
        XCTAssertTrue(element(app, "nativeSidebar").exists,
                      "the shell's sidebar hosts the channel list placeholder")
    }

    /// The other half of the same acceptance criterion: **no flag, no change**. With the pane
    /// resolving `web` (the shipping default) the app is today's app — the webview pane mounts and
    /// the native shell (including its auth surface) is never constructed.
    func testWebPaneIsUnchangedWithoutTheSurfaceFlag() throws {
        try XCTSkipUnless(Self.isFixtureReachable(Self.stubHTTP),
                          "stub not running — start it with: python3 build/uitest-server/mm_stub.py "
                          + "--port 8111 --name \"Local Mattermost Test\"")
        let app = XCUIApplication()
        app.launchArguments = [Self.resetArg,
                               "-uiTestSeedServer", Self.stubHTTP,
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let webview = app.webViews.firstMatch
        XCTAssertTrue(webview.waitForExistence(timeout: Self.webLoadWait),
                      "without -surfaceMode the webview pane must mount exactly as before")
        XCTAssertFalse(element(app, "nativeShell").exists,
                       "the native shell must not be constructed while the pane resolves web")
        // T30-AV F2 made this half of the test honest. Before the fix the auth surface's identifier
        // never reached the accessibility tree (the shell container shadowed it), so this assertion
        // could not fail in any configuration — a green that proved nothing. The surface now has
        // its own top-level branch, its identifier survives, and
        // `testSignedOutServerShowsTheIdentifiableAuthSurface` proves the same queries *do* find it
        // when the pane resolves native. Both halves are now falsifiable.
        XCTAssertFalse(element(app, "nativeAuthSurface").exists,
                       "the native auth surface belongs to the native pane only")
        XCTAssertFalse(app.buttons["Use the web view to sign in"].exists,
                       "the native auth surface's control must not render in the webview pane")
    }

    /// T30-AV F2 (regression): a signed-out server on the native pane renders an **identifiable**
    /// auth surface.
    ///
    /// Without `-uiTestAssumeSignedIn` the production `VaultAuthGate` decides: a server with no
    /// stored session is signed out, so the deep link must land on the auth surface instead of a
    /// channel behind a sign-in wall. The point of asserting the *identifier* (rather than only the
    /// visible button) is that the identifier is the hook T31's native sign-in screen and its tests
    /// will use; an identifier that never reaches the tree is a defective seam even when the view
    /// renders.
    func testSignedOutServerShowsTheIdentifiableAuthSurface() {
        let app = XCUIApplication()
        app.launchArguments = [Self.resetArg,
                               "-surfaceMode", "shell=native",
                               "-uiTestSeedServer", "https://mm.example",
                               "-uiTestOpenDeepLink", "mattermost://mm.example/acme/channels/general",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let surface = element(app, "nativeAuthSurface")
        XCTAssertTrue(surface.waitForExistence(timeout: 20),
                      "the signed-out auth surface must be identifiable as `nativeAuthSurface`. "
                      + "Hierarchy:\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["Use the web view to sign in"].exists,
                      "the auth surface offers the documented escape hatch to the webview")
        XCTAssertFalse(app.webViews.firstMatch.exists,
                       "the native pane stays native while the auth surface is shown")
        XCTAssertFalse(element(app, "nativeShell").exists,
                       "the signed-out state is not the workspace shell; `nativeShell` names the "
                       + "rendered shell, and conflating them is what hid the identifier (F2)")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "t30r-auth-surface-identifiable"
        shot.lifetime = .keepAlways
        add(shot)
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

    // MARK: - T31 native auth & session surface (S01–S03)

    /// Auth-fixture stubs (`build/uitest-server/mm_stub.py`):
    ///   8114 — `POST /users/login` (wrong password / MFA challenge), `/users/login/mfa`, `/users/logout`,
    ///          and `GET /users/me` → 200, so a stored token restores.
    ///   8115 — same, but `GET /users/me` → 401 `api.context.session_expired`, i.e. a relaunch whose
    ///          stored session the server has since revoked.
    static let stubAuth = "http://127.0.0.1:8114"
    static let stubAuthExpired = "http://127.0.0.1:8115"

    /// Launch straight into the native shell's sign-in surface, against an auth stub.
    private func launchNativeAuth(server: String = MattermostUITests.stubAuth,
                                  extra: [String] = []) throws -> XCUIApplication {
        try XCTSkipUnless(Self.isTLSPortOpen(server),
                          "auth stub not running — start it with: python3 build/uitest-server/mm_stub.py --port 8114")
        let app = XCUIApplication()
        app.launchArguments = [Self.resetArg,
                               "-uiTestSeedServer", server,
                               "-uiTestSeedServerName", "Auth Test Server",
                               // Start signed out even on a device where an earlier test signed in
                               // (the gate trusts the vault before the network, by design).
                               "-uiTestForgetSession", server,
                               "-surfaceMode", "shell=native",
                               "-surfaceMode", "auth=native",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extra
        app.launch()
        return app
    }

    private func attachShot(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        // Optional on-disk copy for the card's evidence bundle.
        guard let dir = ProcessInfo.processInfo.environment["MM_AUTH_SHOT_DIR"], !dir.isEmpty else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: url)
    }

    private func signInThroughTheNativeForm(_ app: XCUIApplication,
                                           loginID: String,
                                           password: String) {
        let idField = app.textFields["loginIDField"]
        XCTAssertTrue(idField.waitForExistence(timeout: 20),
                      "the native sign-in surface must mount:\n\(app.debugDescription)")
        idField.tap()
        idField.typeText(loginID)
        let passwordField = app.secureTextFields["loginPasswordField"]
        XCTAssertTrue(passwordField.exists)
        passwordField.tap()
        passwordField.typeText(password)
        app.buttons["loginSubmitButton"].tap()
    }

    /// Type the MFA code into the numeric field. `typeText` goes through the HID path, which the
    /// iOS 26 simulator's numeric keypad does not always accept; if the field is still empty
    /// afterwards, press the keypad keys the way a person would. Either way the field is asserted
    /// to hold the code before the test continues, so a silent no-op cannot pass.
    private func enterMFACode(_ app: XCUIApplication, _ code: String) {
        let field = app.textFields["mfaCodeField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10),
                      "the token field must be on screen:\n\(app.debugDescription)")
        field.tap()
        field.typeText(code)
        if (field.value as? String) != code {
            for digit in code {
                let key = app.keys[String(digit)]
                XCTAssertTrue(key.waitForExistence(timeout: 3),
                              "numeric keypad has no key \(digit):\n\(app.debugDescription)")
                key.tap()
            }
        }
        XCTAssertEqual(field.value as? String, code, "the code must reach the field")
    }

    /// S01 — the sign-in screen is native (form, not a webview), and it is a real surface card:
    /// it only appears because `-surfaceMode auth=native` asked for it, and its submit stays
    /// disabled until both fields carry input.
    func testNativeSignInSurfaceIsAFormNotAWebview() throws {
        let app = try launchNativeAuth()

        XCTAssertTrue(element(app, "nativeAuthSurface").waitForExistence(timeout: 20),
                      "the native auth surface must mount:\n\(app.debugDescription)")
        XCTAssertTrue(app.textFields["loginIDField"].exists)
        XCTAssertTrue(app.secureTextFields["loginPasswordField"].exists)
        let submit = app.buttons["loginSubmitButton"]
        XCTAssertTrue(submit.exists)
        XCTAssertFalse(submit.isEnabled, "mobile's form enables Sign in only when both fields have input")
        XCTAssertFalse(app.webViews.firstMatch.exists,
                       "the sign-in surface is native; the webview is not what renders it")
        XCTAssertFalse(app.buttons["Use the web view to sign in"].exists,
                       "the native form replaces the placeholder's escape hatch")

        attachShot(app, named: "t31-01-native-signin")
    }

    /// S01b — a rejected credential is an inline error on the same screen, in the server's own
    /// words (the stub answers with Mattermost's real `invalid_credentials` sentence).
    func testRejectedPasswordIsAnInlineErrorOnTheNativeForm() throws {
        let app = try launchNativeAuth()
        signInThroughTheNativeForm(app, loginID: "ada@example.com", password: "wrong-password")

        let error = element(app, "loginErrorText")
        XCTAssertTrue(error.waitForExistence(timeout: 20),
                      "the rejection must surface inline:\n\(app.debugDescription)")
        XCTAssertTrue(error.label.contains("Enter a valid email or username and/or password."),
                      "expected the server's sentence, got: \(error.label)")
        XCTAssertTrue(app.textFields["loginIDField"].exists, "a wrong password does not navigate away")
        XCTAssertFalse(element(app, "nativeShell").exists, "nor does it sign the shell in")

        attachShot(app, named: "t31-02-native-signin-rejected")
    }

    /// S02 — the MFA step: the server's challenge moves the screen to the token form, a wrong code
    /// stays there with its own message, the right code lands in the signed-in shell.
    func testMFAChallengeThenAcceptedCodeSignsIn() throws {
        let app = try launchNativeAuth()
        signInThroughTheNativeForm(app, loginID: "mfa@example.com", password: "correct-horse")

        XCTAssertTrue(element(app, "mfaView").waitForExistence(timeout: 20),
                      "an mfa_required answer must move to the token step:\n\(app.debugDescription)")
        enterMFACode(app, "000000")
        app.buttons["mfaSubmitButton"].tap()

        let error = element(app, "mfaErrorText")
        XCTAssertTrue(error.waitForExistence(timeout: 20),
                      "a rejected code must say so on the token step:\n\(app.debugDescription)")
        XCTAssertTrue(error.label.contains("not accepted"), "got: \(error.label)")
        XCTAssertTrue(element(app, "mfaView").exists, "still on the token step")
        attachShot(app, named: "t31-03-mfa-rejected")

        XCTAssertEqual(app.textFields["mfaCodeField"].value as? String, "Enter MFA Token",
                       "the rejected digits are cleared, so they cannot be resent by mistake")
        enterMFACode(app, "123456")
        app.buttons["mfaSubmitButton"].tap()

        XCTAssertTrue(element(app, "nativeShell").waitForExistence(timeout: 25),
                      "an accepted code signs the shell in:\n\(app.debugDescription)")
        XCTAssertFalse(element(app, "nativeAuthSurface").exists)
        attachShot(app, named: "t31-04-mfa-signed-in")
    }

    /// S03 — a relaunch whose stored session the server no longer honours shows the sign-in screen
    /// with the "session expired" banner (not a bare form, and not a signed-in shell).
    func testRevokedStoredSessionShowsTheSessionExpiredBanner() throws {
        let app = try launchNativeAuth(server: Self.stubAuthExpired,
                                       extra: ["-uiTestSeedStoredToken", "stale-stub-token"])

        XCTAssertTrue(element(app, "sessionExpiredBanner").waitForExistence(timeout: 25),
                      "a 401 on restore must explain itself:\n\(app.debugDescription)")
        XCTAssertTrue(app.textFields["loginIDField"].waitForExistence(timeout: 10),
                      "and offer the form again")
        XCTAssertFalse(element(app, "nativeShell").exists,
                       "a revoked session must not be left looking signed in")

        attachShot(app, named: "t31-05-session-expired")
    }

    /// S03b — sign-out from Settings: confirmation, then the shell returns to the sign-in surface.
    func testSignOutFromSettingsReturnsToTheSignInSurface() throws {
        let app = try launchNativeAuth()
        signInThroughTheNativeForm(app, loginID: "ada@example.com", password: "correct-horse")
        XCTAssertTrue(element(app, "nativeShell").waitForExistence(timeout: 25),
                      "sign-in must reach the shell first:\n\(app.debugDescription)")

        app.buttons["settingsToolbarButton"].tap()
        XCTAssertTrue(element(app, "settingsView").waitForExistence(timeout: 10))

        // The Session section sits below General/Notifications/Language, after Servers — scroll to it
        // the way a person would (the form is lazy, so an off-screen row does not exist yet).
        let signOut = app.buttons["signOutButton"]
        var scrolls = 0
        while !(signOut.exists && signOut.isHittable) && scrolls < 8 {
            app.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(signOut.waitForExistence(timeout: 5),
                      "Settings offers sign-out for a server with a native session:\n\(app.debugDescription)")
        attachShot(app, named: "t31-06-settings-session")
        signOut.tap()

        let confirm = app.buttons["Sign out"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5),
                      "sign-out is confirmed, not one-tap")
        attachShot(app, named: "t31-07-signout-confirm")
        confirm.tap()

        let done = app.buttons["Done"]
        if done.waitForExistence(timeout: 5) { done.tap() }

        XCTAssertTrue(app.textFields["loginIDField"].waitForExistence(timeout: 20),
                      "after sign-out the shell shows the sign-in surface again:\n\(app.debugDescription)")
        XCTAssertFalse(element(app, "nativeShell").exists)
        attachShot(app, named: "t31-08-signed-out")
    }

    // MARK: - T31 against a real server (network-gated)

    /// Wrong password against a **real** Mattermost server: the sentence on screen is the server's
    /// own `invalid_credentials` message, which is evidence the form round-trips through
    /// `POST /api/v4/users/login` rather than a local check.
    ///
    ///     TEST_RUNNER_MM_AUTH_SERVER=https://chat.example.com xcodebuild test …
    ///
    /// Needs no credentials — only a reachable server.
    func testRealServerRejectsAWrongPasswordWithItsOwnSentence() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        try XCTSkipUnless(!raw.isEmpty, "Live auth test: set TEST_RUNNER_MM_AUTH_SERVER to run")
        guard let url = URL(string: raw), let host = url.host else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }

        let app = XCUIApplication()
        app.launchArguments = [Self.resetArg,
                               "-uiTestSeedServer", raw,
                               "-uiTestSeedServerName", "Local Mattermost",
                               "-uiTestForgetSession", raw,
                               "-surfaceMode", "shell=native",
                               "-surfaceMode", "auth=native",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        signInThroughTheNativeForm(app, loginID: "no-such-user@\(host)", password: "definitely-not-the-password")

        let error = element(app, "loginErrorText")
        XCTAssertTrue(error.waitForExistence(timeout: 40),
                      "a real server must answer:\n\(app.debugDescription)")
        XCTAssertFalse(error.label.isEmpty)
        XCTAssertTrue(app.textFields["loginIDField"].exists)
        attachShot(app, named: "t31-20-real-server-rejection")
    }

    /// The card's S01/S03 evidence: sign in on the native form against a real server, then kill the
    /// app and relaunch — no reset, so the stored session is what does the signing in.
    ///
    ///     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
    ///     TEST_RUNNER_MM_AUTH_LOGIN=<throwaway user> \
    ///     TEST_RUNNER_MM_AUTH_PASSWORD=<its password> \
    ///     TEST_RUNNER_MM_AUTH_SHOT_DIR=/abs/path xcodebuild test …
    ///
    /// Credentials come from the environment and are never printed or attached.
    func testRealServerSignInThenRelaunchRestoresTheSession() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        let login = env["MM_AUTH_LOGIN"] ?? ""
        let password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !login.isEmpty && !password.isEmpty,
                          "Live sign-in test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }

        let first = XCUIApplication()
        let launchArgs = ["-uiTestSeedServer", url.absoluteString,
                          "-uiTestSeedServerName", "Local Mattermost",
                          "-surfaceMode", "shell=native",
                          "-surfaceMode", "auth=native",
                          "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        first.launchArguments = [Self.resetArg, "-uiTestForgetSession", raw] + launchArgs
        first.launch()

        signInThroughTheNativeForm(first, loginID: login, password: password)
        XCTAssertTrue(element(first, "nativeShell").waitForExistence(timeout: 40),
                      "a real sign-in must reach the shell:\n\(first.debugDescription)")
        attachShot(first, named: "t31-21-real-server-signed-in")

        // Relaunch with no reset and no seed: the server entry and the vault token are what the
        // second launch has to work with.
        first.terminate()
        let second = XCUIApplication()
        second.launchArguments = launchArgs
        second.launch()

        XCTAssertTrue(element(second, "nativeShell").waitForExistence(timeout: 40),
                      "the stored session must restore on relaunch:\n\(second.debugDescription)")
        XCTAssertFalse(second.textFields["loginIDField"].exists,
                       "a restored session must not show the sign-in form")

        // Give the restore call time to come back: if the token were rejected, the banner and the
        // form would appear here — that is exactly what this sleep makes observable.
        Thread.sleep(forTimeInterval: 6)
        XCTAssertTrue(element(second, "nativeShell").exists,
                      "the restore must still be signed in, not flipped to re-auth")
        XCTAssertFalse(element(second, "sessionExpiredBanner").exists,
                       "a token the server accepted must not raise the expired banner")
        attachShot(second, named: "t31-22-real-server-restored")
    }
}
