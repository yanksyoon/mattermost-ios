// T39ea6115 F5' (t_a7432eab) — the three in-pane lookup notes must name the *flag*, not a web app.
//
// Why live and not a unit test: the strings are drawn inside `SearchPaneContent`,
// `SavedPaneContent` and `MentionsPaneContent`, and their containers carry the identifiers the
// build notes and earlier suites reference (`searchWebFallback`, `savedWebFallback`,
// `activityWebFallback`). Before this card no suite touched them at all (measured: `grep -rn
// "WebFallback" MattermostUITests MattermostTests` was empty), so nothing pinned the copy that
// claimed "rendered by the web app" over a per-server WKWebView the release policy destroys.
//
// The launch forces `search=web` and `activity=web` explicitly instead of leaning on the compile
// default, so the same test is true both before and after the lookup surfaces' native-by-default
// flip (`t_aa211ff6`): after it, these notes are reachable from a DEBUG configuration only, which is
// exactly what a `-surfaceMode` launch is.
//
// Run (local throwaway server; credentials as for T34/T39):
//
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     python3 scripts/qa-test.py --platform ios --sim <sim> \
//       --only-testing MattermostUITests/TA7432FallbackCopyUITests
//
// Skips (never fails) when the environment or the server is missing, like every live test here.

import XCTest

final class TA7432FallbackCopyUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!

    /// The sentence the titles used to carry, and the reason this card exists: it named a web app
    /// that pane ownership had already released. No note may say it again.
    private let releasedWebAppClaim = "rendered by the web app"

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live fallback-copy test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
    }

    // MARK: - The three notes

    func testEachLookupNoteNamesItsFlagAndNotAWebApp() throws {
        let app = launchApp()
        signIn(app)

        assertNote(app,
                   tab: ShellSettle.Tab.search,
                   toolbarButton: "shellSearchButton",
                   identifier: "searchWebFallback",
                   title: "Search is off for this run (`search=web`)")
        assertNote(app,
                   tab: ShellSettle.Tab.saved,
                   toolbarButton: "shellSavedButton",
                   identifier: "savedWebFallback",
                   title: "Saved messages are off for this run (`search=web`)")
        assertNote(app,
                   tab: ShellSettle.Tab.activity,
                   toolbarButton: "shellActivityButton",
                   identifier: "activityWebFallback",
                   title: "Mentions are off for this run (`activity=web`)")
    }

    // MARK: - Reaching a note

    /// Open one lookup screen (tab in the compact layout, detail-toolbar button in the regular
    /// split layout), then assert its note: the container's identifier still exists, its title is the
    /// flag's own name, and no text in the note still claims a web app is drawing the content.
    private func assertNote(_ app: XCUIApplication,
                            tab: String,
                            toolbarButton: String,
                            identifier: String,
                            title: String) {
        if !ShellSettle.tapTab(tab, in: app, wait: 20) {
            let button = element(app, toolbarButton)
            XCTAssertTrue(button.waitForExistence(timeout: 20),
                          "neither the tab bar nor \(toolbarButton) opens \(tab):\n"
                          + "\(app.debugDescription)")
            button.tap()
        }

        let note = element(app, identifier)
        XCTAssertTrue(note.waitForExistence(timeout: 30),
                      "\(tab) must draw its note (\(identifier)) while the surface resolves web:\n"
                      + "\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10),
                      "\(tab)'s note must be titled \"\(title)\":\n\(app.debugDescription)")
        let falseClaim = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", releasedWebAppClaim))
        XCTAssertEqual(falseClaim.count, 0,
                       "\(tab)'s note must not claim the web app is drawing it — the pane owns the "
                       + "screen and the webview is released behind it (§5 of the dispositions doc)")
    }

    // MARK: - Launch and sign-in, as T39/T42 do it

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetPersistedState",
                               "-uiTestForgetSession", serverURL.absoluteString,
                               "-uiTestSeedServer", serverURL.absoluteString,
                               "-uiTestSeedServerName", "Local Mattermost",
                               "-surfaceMode", "shell=native",
                               "-surfaceMode", "auth=native",
                               "-surfaceMode", "sidebar=native",
                               "-surfaceMode", "search=web",
                               "-surfaceMode", "activity=web",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    private func signIn(_ app: XCUIApplication) {
        let field = app.textFields["loginIDField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20),
                      "the native sign-in must mount against \(serverURL.absoluteString):\n"
                      + "\(app.debugDescription)")
        field.tap()
        field.typeText(loginID)
        let secret = app.secureTextFields["loginPasswordField"]
        XCTAssertTrue(secret.exists)
        secret.tap()
        secret.typeText(password)
        app.buttons["loginSubmitButton"].tap()
        XCTAssertTrue(element(app, "nativeShell").waitForExistence(timeout: 40),
                      "signing in must reach the shell:\n\(app.debugDescription)")
    }

    /// Any element type carrying `identifier`: SwiftUI decides whether an identifier lands on an
    /// `other`, a `staticText` or a `button`, and that changes across OS versions.
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
