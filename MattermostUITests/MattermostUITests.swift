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

    static let resetArg = "-uiTestResetPersistedState"
    static let webLoadWait: TimeInterval = 20

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
}