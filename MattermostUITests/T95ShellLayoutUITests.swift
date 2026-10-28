// T95-A — the phone shell's launch shape, asserted as **parity** rather than as a bug.
//
// Two claims, both from the decision record `docs/t95-shell-tab-bar-decision.md` (§2 D1, §3 D2):
//
//   1. a launch with nothing saved lands on the channel list, with its tab bar — upstream's cold
//      start restores the last thread, else the last channel, else `HOME`
//      (`mattermost-mobile` v2.45.0 = `162f2560`, `app/init/launch.ts:245-262`, `:290-294`). There is
//      no town-hall or first-channel fallback, so a reset launch (`-uiTestResetPersistedState` wipes
//      `mm.native.lastChannel`) must show the tabs and **not** a pushed channel pane;
//   2. opening a channel from the sidebar **covers** the tab bar (a `Back` chevron instead), and
//      `Back` brings the bar back — upstream keeps its `Stack` above the `Tabs`, so a channel is a
//      sibling route pushed over the tab navigator, and the Mobile v2 design slides the bar off in a
//      channel on phone.
//
// This test is the falsifier for both halves: reinstating the town-hall push makes step 1 red
// (a `nativeChannelPane` at launch, no tab bar), and a future "keep the tab bar in a channel" change
// makes step 2 red (tab bar still on screen under the pane).
//
// Run (local fixture server; credentials come from the environment, never from this file):
//
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     python3 scripts/qa-test.py --platform ios --sim id=81A7F251-8B31-4945-8783-5A264C14B8D5 \
//       --only-testing MattermostUITests/T95ShellLayoutUITests
//
// Skips (never fails) when the environment, the server or the fixture is missing, like every live
// test here.

import XCTest

final class T95ShellLayoutUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var teamID: String!

    /// The team's default channel, as the server names it: `town-square` on Mattermost's own
    /// defaults, `town-hall` on the measured fixture (renamed by the admins). Read from the server,
    /// never hard-coded — and falling back to any public channel so a renamed default still runs.
    private var townHall: (id: String, name: String, displayName: String)!

    /// A cookie-free session for the fixture reads: `URLSession.shared` carries a stale
    /// `MMAUTHTOKEN` in its cookie jar, which makes `POST /users/login` answer 401 `api.context.*`
    /// on this host (T39-R2 measured it).
    private lazy var api: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live shell-layout test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        try ping()
        let session = try authenticate()
        teamID = try firstTeamID(token: session.token)
        townHall = try defaultChannel(token: session.token)
    }

    // MARK: - The test

    func testALaunchWithNothingSavedShowsTheTabBarAndAChannelPushCoversIt() throws {
        let app = launchAndSignIn()

        // 1. Nothing saved → the channel list and its tab bar; no channel is invented.
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(waitUntil(timeout: 60) { tabBar.exists },
                      "a launch with nothing saved must land on the channel list, whose tab bar is "
                      + "on screen (upstream routes to HOME with no conversation saved):\n"
                      + app.debugDescription)
        attach(app, "t95a-1-launch-nothing-saved")
        XCTAssertTrue(app.tabBars.buttons["Search"].exists,
                      "the bar must be the shell's own five tabs, not an empty container:\n"
                      + app.debugDescription)
        XCTAssertFalse(element(app, "nativeChannelPane").waitForExistence(timeout: 5),
                       "a launch with nothing saved must NOT open a channel — LaunchDestination "
                       + "restores the last channel and nothing else, so no town hall may be pushed "
                       + "(this is the assertion a reinstated fallback breaks):\n"
                       + app.debugDescription)

        // 2. Open the team's default channel the way a reader does: tap its sidebar row.
        let row = revealSidebarRow(app, identifier: "channelSidebar.channel.\(townHall.id)")
        XCTAssertTrue(row.waitForExistence(timeout: 40),
                      "the sidebar must list #\(townHall.name) so the test can open it:\n"
                      + app.debugDescription)
        row.tap()

        let pane = element(app, "nativeChannelPane")
        XCTAssertTrue(pane.waitForExistence(timeout: 40),
                      "tapping a sidebar row must push the channel pane:\n" + app.debugDescription)
        let title = element(app, "nativeChannelTitle")
        XCTAssertTrue(title.waitForExistence(timeout: 10),
                      "the pushed pane must name the channel it opened:\n" + app.debugDescription)
        // The header starts as the slug the shell was handed and `loadChannelHeader()` replaces it
        // with the server's display name a beat later (T40's `ChannelPaneTitle`), so either spelling
        // is the right channel; a different channel is not.
        XCTAssertTrue(waitUntil(timeout: 30) {
            let label = title.exists ? title.label : ""
            return label == self.townHall.displayName || label == self.townHall.name
        }, "the pane must show the channel whose row was tapped (#\(townHall.name) / "
           + "#\(townHall.displayName)), got '\(title.exists ? title.label : "nil")'")

        // ...and the push covers the tab bar: the compact layout's stack sits above the TabView,
        // exactly as upstream's `Stack` wraps `Tabs` (design doc: the bar slides off in a channel).
        let back = app.navigationBars.buttons["Back"]
        XCTAssertTrue(back.waitForExistence(timeout: 10),
                      "a pushed channel offers Back — on upstream too, its phone channel header "
                      + "carries the chevron:\n" + app.debugDescription)
        XCTAssertTrue(waitUntil(timeout: 10) { app.tabBars.count == 0 },
                      "the pushed pane covers the tab bar (upstream parity, D1); a tab bar still on "
                      + "screen here means someone changed the shell's structure — that is a "
                      + "deviation card, not a bug fix:\n" + app.debugDescription)
        attach(app, "t95a-2-channel-covers-the-bar")

        // 3. Back → the bar is back, and no channel pane is left behind.
        back.tap()
        XCTAssertTrue(waitUntil(timeout: 30) { app.tabBars.firstMatch.exists },
                      "Back must return to the channel list with its tab bar:\n" + app.debugDescription)
        XCTAssertFalse(element(app, "nativeChannelPane").exists,
                       "the popped destination must not stay in the hierarchy:\n" + app.debugDescription)
        attach(app, "t95a-3-back-restores-the-bar")
    }

    // MARK: - Launch

    private func launchAndSignIn() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetPersistedState",
                               "-uiTestForgetSession", serverURL.absoluteString,
                               "-uiTestSeedServer", serverURL.absoluteString,
                               "-uiTestSeedServerName", "Local Mattermost",
                               "-surfaceMode", "shell=native",
                               "-surfaceMode", "auth=native",
                               "-surfaceMode", "sidebar=native",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let field = app.textFields["loginIDField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20),
                      "the native sign-in must mount against \(serverURL.absoluteString):\n"
                      + app.debugDescription)
        field.tap()
        field.typeText(loginID)
        let secret = app.secureTextFields["loginPasswordField"]
        XCTAssertTrue(secret.exists)
        secret.tap()
        secret.typeText(password)
        app.buttons["loginSubmitButton"].tap()
        // "Signed in" is the shell **or** a destination pushed over it: a restored channel pane
        // removes `nativeShell` from the accessibility tree (T37-R2 F-1b), so waiting on the shell
        // alone would decide this test's outcome inside its own launch helper.
        let shell = element(app, "nativeShell")
        let pane = element(app, "nativeChannelPane")
        XCTAssertTrue(waitUntil(timeout: 60) {
            !field.exists && (shell.exists || pane.exists || app.tabBars.firstMatch.exists)
        }, "signing in must reach the shell (the channel list, or a channel pane pushed over it):\n"
           + app.debugDescription)
        return app
    }

    // MARK: - Fixture (the test is its own API client; nothing is assumed)

    private func ping() throws {
        let (_, response) = try synchronous(get: "/api/v4/system/ping")
        guard response?.statusCode == 200 else {
            throw XCTSkip("the fixture server at \(serverURL.absoluteString) does not answer ping "
                          + "(status \(response?.statusCode ?? -1)); start it with: docker start mm-perf")
        }
    }

    private func authenticate() throws -> (token: String, userID: String) {
        let (data, response) = try synchronous(path: "/api/v4/users/login",
                                               method: "POST",
                                               body: ["login_id": loginID, "password": password])
        guard response?.statusCode == 200,
              let token = response?.value(forHTTPHeaderField: "Token"),
              !token.isEmpty else {
            throw XCTSkip("the fixture server did not issue a token for \(loginID!) "
                          + "(status \(response?.statusCode ?? -1))")
        }
        let user = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (token, user["id"] as? String ?? "")
    }

    private func firstTeamID(token: String) throws -> String {
        let (data, _) = try synchronous(get: "/api/v4/users/me/teams", token: token)
        let teams = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        guard let id = teams.first?["id"] as? String else {
            throw XCTSkip("the fixture account is in no team")
        }
        return id
    }

    /// The team's default channel: `town-square`/`town-hall` when the server has one, else its first
    /// public channel — so a fixture whose default was renamed still exercises the same row.
    private func defaultChannel(token: String) throws -> (id: String, name: String, displayName: String) {
        let (data, _) = try synchronous(get: "/api/v4/users/me/teams/\(teamID!)/channels", token: token)
        let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        let channels = rows.compactMap { row -> (id: String, name: String, displayName: String, type: String)? in
            guard let id = row["id"] as? String, let name = row["name"] as? String else { return nil }
            let display = (row["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
            return (id, name, display, row["type"] as? String ?? "")
        }
        let pickup = channels.first { $0.name == "town-square" || $0.name == "town-hall" }
            ?? channels.first { $0.type == "O" }
        guard let pickup else { throw XCTSkip("the fixture team has no channel to open") }
        return (pickup.id, pickup.name, pickup.displayName)
    }

    private func synchronous(get path: String, token: String? = nil) throws -> (Data, HTTPURLResponse?) {
        try synchronous(path: path, method: "GET", token: token, body: nil)
    }

    private func synchronous(path: String,
                             method: String,
                             token: String? = nil,
                             body: [String: Any]? = nil) throws -> (Data, HTTPURLResponse?) {
        guard let url = URL(string: path, relativeTo: serverURL) else {
            throw XCTSkip("cannot build \(path) against \(serverURL.absoluteString)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let done = DispatchSemaphore(value: 0)
        var payload = Data()
        var http: HTTPURLResponse?
        api.dataTask(with: request) { data, response, _ in
            payload = data ?? Data()
            http = response as? HTTPURLResponse
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 25)
        return (payload, http)
    }

    // MARK: - Small helpers

    /// Any element type carrying `identifier`: SwiftUI decides whether an identifier lands on an
    /// `other`, a `staticText` or a `button`, and that changes across OS versions.
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Scroll the channel list until `identifier` exists (a lazy `List` builds only its viewport).
    @discardableResult
    private func revealSidebarRow(_ app: XCUIApplication, identifier: String,
                                  maxSwipes: Int = 20) -> XCUIElement {
        let target = element(app, identifier)
        guard !target.exists else { return target }
        var swipes = 0
        while !target.exists, swipes < maxSwipes {
            app.swipeUp(velocity: .fast)
            swipes += 1
        }
        return target
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
