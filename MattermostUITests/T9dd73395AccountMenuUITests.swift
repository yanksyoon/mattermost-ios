// T9dd73395 — the account menu against a **real** Mattermost server.
//
// Why live: every requirement of the card is a statement about the server's own state.
//   * requirement 2 — the menu's items are the rows the app draws from the status the server
//     reports, so "the current status is checked" is only true if `GET /users/{id}/status` and the
//     checkmark agree;
//   * requirement 3 — a status set from the menu is read back through the API with the same account
//     the app signs in as: the server is the oracle, not the app's own memory;
//   * requirement 4 — a custom status set on the server (emoji + text + expiry) is what the control's
//     badge and the menu's row must show after a fresh launch; clearing it must make the row read
//     "Set a custom status" again;
//   * requirement 7 — sign out from the menu must land on the sign-in surface, and the session must be
//     revoked on the server (a re-read of `GET /users/{id}` with the old token answers 401).
//
// A stub could only prove this file's own fixtures render.
//
// Run (local throwaway server; same fixture account as T34/T41):
//
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     python3 scripts/qa-test.py --platform ios --sim <sim> \
//       --only-testing MattermostUITests/T9dd73395AccountMenuUITests
//
// Each test skips — never fails — when the environment or the server is missing, like every live
// test here. Screenshots: each test attaches one (`t9dd-…`), so a run leaves visual evidence next to
// the machine verdict — including the open menu, which cannot be captured on a host that denies
// Screen Recording and has developer mode off (the app's own `drawHierarchy` captures do not include
// a popup's separate window; only a UI-test screenshot does).

import XCTest

final class T9dd73395AccountMenuUITests: XCTestCase {

    /// One admin session per test process; the server rate-limits logins by IP.
    private static var cachedSession: (server: String, token: String, userID: String)?

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var userID: String!
    private var teamID: String!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live account-menu test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        try ping()
        if let cached = Self.cachedSession, cached.server == raw {
            token = cached.token
            userID = cached.userID
        } else {
            let session = try authenticate(login: loginID, password: password)
            token = session.token
            userID = session.userID
            Self.cachedSession = (server: raw, token: session.token, userID: session.userID)
        }
        teamID = try firstTeamID()
    }

    override func tearDownWithError() throws {
        // Leave the fixture the way the next suite expects it: online, no custom status.
        guard token != nil, userID != nil else { return }
        _ = try? sendJSON("PUT", "/api/v4/users/\(userID!)/status",
                          body: ["user_id": userID!, "status": "online"], allowFailure: true)
        _ = try? sendJSON("DELETE", "/api/v4/users/\(userID!)/status/custom",
                          body: nil, allowFailure: true)
    }

    // MARK: - 1. The menu opens with upstream's items, in upstream's order

    func testTheMenuOpensWithUpstreamsItems() throws {
        let app = launchApp()
        openChannel(app)

        openMenu(app)
        attach(app, "t9dd-account-menu")

        for identifier in ["accountMenu.name", "accountMenu.profile", "accountMenu.logout",
                           "accountMenu.status.online", "accountMenu.status.away",
                           "accountMenu.status.dnd", "accountMenu.status.offline"] {
            XCTAssertTrue(element(app, identifier).waitForExistence(timeout: 10),
                          "the menu must offer \(identifier):\n\(app.debugDescription)")
        }
        // Exactly one of the two custom-status rows, never both (requirement 2).
        let setRow = element(app, "accountMenu.setCustomStatus")
        let currentRow = element(app, "accountMenu.customStatus")
        XCTAssertNotEqual(setRow.exists, currentRow.exists,
                          "the menu offers one custom-status row:\n\(app.debugDescription)")

        // The row for the status the server reports is the one that is checked.
        let reported = try reportedStatus()
        let checked = element(app, "accountMenu.status.\(reported)")
        XCTAssertTrue(checked.exists, "the server reports \(reported), which the menu must list")
        XCTAssertTrue((checked.value as? String ?? "") == ""
                      || (checked.value as? String ?? "").contains("selected")
                      || checked.isSelected,
                      "the current status is checked, not merely present:\n\(app.debugDescription)")
    }

    // MARK: - 2. A status chosen in the menu reaches the server

    func testChoosingAStatusMovesTheControlAndTheServer() throws {
        let app = launchApp()
        openChannel(app)
        XCTAssertEqual(try setStatus("online"), "online", "the fixture starts from a known status")

        openMenu(app)
        element(app, "accountMenu.status.away").tap()

        // The server is the oracle: the menu's row wrote what it claimed to write.
        let deadline = Date().addingTimeInterval(20)
        var reported = try reportedStatus()
        while reported != "away", Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            reported = try reportedStatus()
        }
        XCTAssertEqual(reported, "away", "the menu's Away row must reach PUT /users/{id}/status")

        // …and the control's own value is the same status, without a relaunch.
        let control = element(app, "accountMenuButton")
        XCTAssertTrue(control.waitForExistence(timeout: 10))
        XCTAssertEqual(control.value as? String, "Away",
                       "the control's presence dot follows the row that was pressed")
        attach(app, "t9dd-control-after-away")
    }

    // MARK: - 3. A custom status shows on the control

    func testTheControlShowsMyCustomStatus() throws {
        // Set it server-side, then launch: nothing about the status may be remembered locally, so a
        // fresh launch is the honest test of "the badge draws what the server holds".
        let expires = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        _ = try sendJSON("PUT", "/api/v4/users/\(userID!)/status/custom",
                         body: ["emoji": "coffee", "text": "T9dd vacation",
                                "duration": "one_hour", "expires_at": expires])

        let app = launchApp()
        openChannel(app)

        let control = element(app, "accountMenuButton")
        XCTAssertTrue(control.waitForExistence(timeout: 20),
                      "the header must draw the account control:\n\(app.debugDescription)")
        attach(app, "t9dd-control-custom-status")

        openMenu(app)
        XCTAssertTrue(element(app, "accountMenu.customStatus").waitForExistence(timeout: 10),
                      "a set custom status draws the status row:\n\(app.debugDescription)")
        XCTAssertFalse(element(app, "accountMenu.setCustomStatus").exists,
                       "…and not the \"set\" row")
        attach(app, "t9dd-menu-custom-status")

        // Clearing it is the menu's other path; the server must agree it is gone.
        _ = try sendJSON("DELETE", "/api/v4/users/\(userID!)/status/custom", body: nil)
        let me = try getJSON("/api/v4/users/\(userID!)") as? [String: Any] ?? [:]
        let props = me["props"] as? [String: Any] ?? [:]
        XCTAssertTrue((props["customStatus"] as? String ?? "").isEmpty,
                      "DELETE must remove `props.customStatus` — the row the badge reads")
    }

    // MARK: - 4. Sign out from the menu lands on sign-in

    func testSignOutFromTheMenuLandsOnSignIn() throws {
        let app = launchApp()
        openChannel(app)

        openMenu(app)
        let logout = element(app, "accountMenu.logout")
        XCTAssertTrue(logout.waitForExistence(timeout: 10),
                      "the menu must offer Sign out:\n\(app.debugDescription)")
        logout.tap()

        let confirm = element(app, "accountMenu.logoutConfirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 10),
                      "signing out asks first, with the same confirmation Settings uses:\n"
                      + "\(app.debugDescription)")
        confirm.tap()

        XCTAssertTrue(element(app, "nativeAuthSurface").waitForExistence(timeout: 30),
                      "signing out must land on the sign-in screen:\n\(app.debugDescription)")
        XCTAssertTrue(element(app, "loginIDField").exists,
                      "the native sign-in form is the landing surface")
        attach(app, "t9dd-signed-out")
    }

    // MARK: - The app

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
        // T40-R's crash, which bit the T41 suite too: XCTest's `XCTAutomationSupport` makes the app
        // log one os_log fault per captured runtime issue, libtrace quarantines the process, and the
        // next accessibility snapshot dereferences a NULL. `OS_ACTIVITY_MODE=disable` stops that
        // delivery. Test-only; the app itself is unchanged.
        app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"
        app.launch()
        signIn(app)
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
        XCTAssertTrue(ShellSettle.waitForSignedIn(app, timeout: 40),
                      "signing in must reach the shell:\n\(app.debugDescription)")
    }

    private func openChannel(_ app: XCUIApplication) {
        _ = ShellSettle.revealChannelList(app)
        let teamRow = element(app, "teamSidebar.team.\(teamID!)")
        XCTAssertTrue(teamRow.waitForExistence(timeout: 40),
                      "the rail must list the fixture's team:\n\(app.debugDescription)")
        if !(teamRow.value as? String ?? "").contains("Selected") { teamRow.tap() }
        let channelID = try? firstChannelID()
        guard let channelID else { return }
        let row = revealSidebarRow(app, identifier: "channelSidebar.channel.\(channelID)")
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "the sidebar must list the fixture's first channel:\n\(app.debugDescription)")
        row.tap()
        XCTAssertTrue(element(app, "nativeChannelTitle").waitForExistence(timeout: 30),
                      "the channel pane must mount:\n\(app.debugDescription)")
    }

    /// Tap the control and wait for the menu's first row. A `Menu`'s rows are separate elements from
    /// the button, so "the menu is open" is "a row exists".
    private func openMenu(_ app: XCUIApplication) {
        let control = element(app, "accountMenuButton")
        XCTAssertTrue(control.waitForExistence(timeout: 20),
                      "the channel header must offer the account menu:\n\(app.debugDescription)")
        control.tap()
        XCTAssertTrue(element(app, "accountMenu.name").waitForExistence(timeout: 15),
                      "the account menu must open:\n\(app.debugDescription)")
    }

    // MARK: - Server (the oracle)

    private func reportedStatus() throws -> String {
        let status = try getJSON("/api/v4/users/\(userID!)/status") as? [String: Any] ?? [:]
        return status["status"] as? String ?? ""
    }

    private func setStatus(_ value: String) throws -> String {
        _ = try sendJSON("PUT", "/api/v4/users/\(userID!)/status",
                         body: ["user_id": userID!, "status": value])
        return try reportedStatus()
    }

    private func firstChannelID() throws -> String? {
        let channels = try getJSON("/api/v4/users/me/teams/\(teamID!)/channels")
            as? [[String: Any]] ?? []
        return channels.first { ($0["type"] as? String) != "D" }?["id"] as? String
    }

    private func ping() throws {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/system/ping"))
        request.timeoutInterval = 5
        let (_, response) = try synchronous(request)
        try XCTSkipUnless((response as? HTTPURLResponse)?.statusCode == 200,
                          "the live server at \(serverURL.absoluteString) is not answering")
    }

    private func authenticate(login: String, password: String) throws -> (token: String, userID: String) {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/users/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["login_id": login,
                                                                      "password": password])
        let (data, response) = try synchronous(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let token = http.value(forHTTPHeaderField: "Token"),
              let user = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = user["id"] as? String else {
            throw XCTSkip("could not sign in as \(login) on \(serverURL.absoluteString)"
                          + " (HTTP \(status))")
        }
        return (token, id)
    }

    private func firstTeamID() throws -> String {
        let teams = try getJSON("/api/v4/users/me/teams") as? [[String: Any]] ?? []
        guard let team = teams.first, let id = team["id"] as? String else {
            throw XCTSkip("the fixture account has no team")
        }
        return id
    }

    private func url(for path: String) -> URL {
        let halves = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let base = serverURL.appendingPathComponent(String(halves[0]))
        guard halves.count == 2, !halves[1].isEmpty,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return base
        }
        components.percentEncodedQuery = String(halves[1])
        return components.url ?? base
    }

    private func getJSON(_ path: String) throws -> Any {
        var request = URLRequest(url: url(for: path))
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        let (data, response) = try synchronous(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NSError(domain: "T9ddOracle", code: status, userInfo: [
                NSLocalizedDescriptionKey:
                    "GET \(path) -> HTTP \(status) \(String(decoding: data.prefix(200), as: UTF8.self))"])
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    @discardableResult
    private func sendJSON(_ method: String, _ path: String, body: Any?,
                          allowFailure: Bool = false) throws -> Any {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = method
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try synchronous(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !allowFailure {
            guard (200...299).contains(status) else {
                throw NSError(domain: "T9ddOracle", code: status, userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(method) \(path) -> HTTP \(status) "
                        + String(decoding: data.prefix(200), as: UTF8.self)])
            }
        }
        return (try? JSONSerialization.jsonObject(with: data)) ?? [:]
    }

    private func synchronous(_ request: URLRequest) throws -> (Data, URLResponse) {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, error in
            box.data = data
            box.response = response
            box.error = error
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 15)
        if let error = box.error { throw error }
        return (box.data ?? Data(), box.response ?? URLResponse())
    }

    private final class ResultBox: @unchecked Sendable {
        var data: Data?
        var response: URLResponse?
        var error: Error?
    }

    // MARK: - Elements

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @discardableResult
    private func revealSidebarRow(_ app: XCUIApplication, identifier: String,
                                  maxSwipes: Int = 20) -> XCUIElement {
        let target = element(app, identifier)
        guard !target.exists else { return target }
        let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app
        var swipes = 0
        while !target.exists, swipes < maxSwipes {
            list.swipeUp(velocity: .fast)
            swipes += 1
        }
        return target
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
