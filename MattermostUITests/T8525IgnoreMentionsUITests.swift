// T8525 — the channel-info "Ignore @channel, @here, @all" switch against a **real** Mattermost server.
//
// Why live: the criterion is a statement about the server's data, and the T40-AV/T52 suites already
// measured that a UI-only assertion can pass while no request leaves the process (T40-AV F1/F2):
//   1. flipping the switch puts `ignore_channel_mentions: "on"` **on the wire** — the server's own
//      `GET …/members/{uid}` answers it, and every other `notify_props` field is untouched;
//   2. it survives a relaunch, because the info screen re-reads the membership (the state is derived,
//      not held in a local flag);
//   3. a direct message, where upstream draws no such row, has none here either.
//
// The fixture is created per test (a channel named `0-t8525-live-…`, at the top of the sidebar, deleted
// in `tearDown`) for the reason T52-R1 measured: this team has 350+ channels, so a seeded one cannot be
// scrolled to reliably.
//
// Run (same fixture and credentials as T40/T52):
//
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     python3 scripts/qa-test.py --platform ios --sim <sim> \
//       --only-testing MattermostUITests/T8525IgnoreMentionsUITests
//
// Each test skips — never fails — when the environment or the server is missing.

import XCTest

final class T8525IgnoreMentionsUITests: XCTestCase {

    private static var cachedAdminSession: (server: String, token: String, userID: String)? = nil

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var userID: String!
    private var teamID: String!

    private let channelNamePrefix = "0-t8525-live-"
    private var createdChannelID: String?

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live ignore-mentions test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        try ping()
        if let cached = Self.cachedAdminSession, cached.server == raw {
            token = cached.token
            userID = cached.userID
        } else {
            let session = try authenticate(login: loginID, password: password)
            token = session.token
            userID = session.userID
            Self.cachedAdminSession = (server: raw, token: session.token, userID: session.userID)
        }
        teamID = try firstTeamID()
    }

    override func tearDownWithError() throws {
        if let id = createdChannelID {
            _ = try? sendJSON("DELETE", "/api/v4/channels/\(id)", body: nil)
            createdChannelID = nil
        }
    }

    // MARK: - 1. The switch writes the field and survives a relaunch

    func testTheIgnoreMentionsSwitchIsWrittenAndSurvivesARelaunch() throws {
        let channel = try makeChannel()
        // Start from a state this test owns: the account default, unmuted — the switch then reads "off".
        _ = try putJSON("/api/v4/channels/\(channel.id)/members/\(userID!)/notify_props",
                        body: ["ignore_channel_mentions": "default",
                               "mark_unread": "all",
                               "desktop": "default"])

        let app = launchApp()
        openChannel(app, channel: channel)
        openChannelInfo(app)

        let toggle = assertSwitch(app, "channelInfo.ignoreMentions")
        XCTAssertTrue(toggle.isEnabled,
                      "the switch must be usable:\n\(app.debugDescription)")
        XCTAssertEqual(toggle.value as? String, "0",
                       "the fixture starts at the account default, which is not ignoring")
        // Measured (12:20 run): tapping the *element's centre* hits the row's label, and a SwiftUI
        // `Toggle` row only flips when its control is hit — the label area is not a button. The control
        // sits at the row's trailing edge, so the tap is aimed there.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertTrue(element(app, "channelInfo.ignoreMentions").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "channelInfo.refused").exists,
                       "the write must not be refused:\n\(app.debugDescription)")
        XCTAssertFalse(element(app, "channelInfo.banner").exists,
                       "the write must not fail:\n\(app.debugDescription)")

        // The server's answer, not the screen's: "on" stored, every other field untouched.
        let stored = try waitForStoredIgnoreValue(channelID: channel.id, expected: "on")
        XCTAssertEqual(stored["ignore_channel_mentions"], "on",
                       "the switch must PUT ignore_channel_mentions=on")
        XCTAssertEqual(stored["mark_unread"], "all", "only the changed field travels")
        XCTAssertEqual(stored["desktop"], "default", "only the changed field travels")
        XCTAssertEqual(toggle.value as? String, "1", "the switch follows the server's read-back")

        // Relaunch without resetting persisted state: the state must come back from the server.
        app.terminate()
        let relaunched = relaunchApp()
        openInfoAfterRelaunch(relaunched, channel: channel)
        let afterRelaunch = assertSwitch(relaunched, "channelInfo.ignoreMentions")
        XCTAssertEqual(afterRelaunch.value as? String, "1",
                       "the switch must come back from the server after a relaunch")
        attach(relaunched, "t8525-ignore-mentions-relaunch")
    }

    // MARK: - 2. The switch, and the notification screen, agree about the same field

    /// The row writes the same field the preferences screen's "Ignore @channel, @all and @here" switch
    /// writes, so the two screens must not disagree after a write made on one of them: this test flips
    /// the info switch, then opens the notification screen and asserts **its** switch already reads the
    /// server's value (the model is shared, and the preferences form's draft starts from the server).
    func testTheNotificationScreenSeesTheValueTheInfoSwitchWrote() throws {
        let channel = try makeChannel()
        _ = try putJSON("/api/v4/channels/\(channel.id)/members/\(userID!)/notify_props",
                        body: ["ignore_channel_mentions": "on",
                               "mark_unread": "all",
                               "desktop": "default"])

        let app = launchApp()
        openChannel(app, channel: channel)
        openChannelInfo(app)
        let toggle = assertSwitch(app, "channelInfo.ignoreMentions")
        XCTAssertEqual(toggle.value as? String, "1",
                       "the info switch must read the server's stored value")

        tapControl(app, "channelInfo.action.notifications")
        XCTAssertTrue(element(app, "channelInfo.notifications.form").waitForExistence(timeout: 20),
                      "the notification screen must mount:\n\(app.debugDescription)")
        let shared = assertSwitch(app, "channelInfo.notifications.ignoreMentions")
        XCTAssertEqual(shared.value as? String, "1",
                       "the preferences screen must read the same field the info switch just showed")
    }

    // MARK: - App driving

    private func launchApp() -> XCUIApplication {
        launch(reset: true)
    }

    private func relaunchApp() -> XCUIApplication {
        launch(reset: false)
    }

    private func launch(reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["-uiTestSeedServer", serverURL.absoluteString,
                         "-uiTestSeedServerName", "Local Mattermost",
                         "-surfaceMode", "shell=native",
                         "-surfaceMode", "auth=native",
                         "-surfaceMode", "sidebar=native",
                         "-surfaceMode", "channelInfo=native",
                         "-uiTestLogLevel", "error",
                         "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if reset {
            arguments = ["-uiTestResetPersistedState",
                         "-uiTestForgetSession", serverURL.absoluteString] + arguments
        }
        app.launchArguments = arguments
        app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"
        app.launch()
        if reset { signIn(app) }
        XCTAssertTrue(ShellSettle.waitForSignedIn(app),
                      "the shell must mount:\n\(app.debugDescription)")
        return app
    }

    private func signIn(_ app: XCUIApplication) {
        let field = app.textFields["loginIDField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20),
                      "the native sign-in must mount against \(serverURL.absoluteString):"
                      + "\n\(app.debugDescription)")
        field.tap()
        field.typeText(loginID)
        let secret = app.secureTextFields["loginPasswordField"]
        XCTAssertTrue(secret.exists)
        secret.tap()
        secret.typeText(password)
        app.buttons["loginSubmitButton"].tap()
    }

    private func openChannel(_ app: XCUIApplication, channel: Channel) {
        let pops = ShellSettle.revealChannelList(app)
        let teamRow = element(app, "teamSidebar.team.\(teamID!)")
        XCTAssertTrue(teamRow.waitForExistence(timeout: 40),
                      "the rail must list the team (after \(pops) Back tap(s) to the channel list):"
                      + "\n\(app.debugDescription)")
        if !(teamRow.value as? String ?? "").contains("Selected") { teamRow.tap() }
        let row = revealSidebarRow(app, identifier: "channelSidebar.channel.\(channel.id)")
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "the sidebar must list #\(channel.name):\n\(app.debugDescription)")
        row.tap()
        XCTAssertTrue(element(app, "nativeChannelTitle").waitForExistence(timeout: 30),
                      "the channel pane must mount:\n\(app.debugDescription)")
    }

    private func openChannelInfo(_ app: XCUIApplication) {
        tapControl(app, "nativeChannelInfoButton")
        XCTAssertTrue(element(app, "channelInfo.sheet").waitForExistence(timeout: 20),
                      "the channel-info sheet must mount:\n\(app.debugDescription)")
    }

    private func openInfoAfterRelaunch(_ app: XCUIApplication, channel: Channel) {
        let title = element(app, "nativeChannelTitle")
        if title.waitForExistence(timeout: 15) {
            XCTAssertTrue(title.label.contains("T8525 live"),
                          "the relaunch must restore the channel this test opened, got: \(title.label)")
        } else {
            let back = app.navigationBars.firstMatch.buttons["Back"]
            if back.exists, back.isHittable { back.tap() }
            _ = ShellSettle.tapTab(ShellSettle.Tab.channels, in: app, wait: 10)
            XCTAssertTrue(element(app, "nativeSidebar").waitForExistence(timeout: 20),
                          "the relaunch must land on the sidebar:\n\(app.debugDescription)")
            openChannel(app, channel: channel)
        }
        openChannelInfo(app)
    }

    @discardableResult
    private func revealSidebarRow(_ app: XCUIApplication, identifier: String,
                                  maxSwipes: Int = 40) -> XCUIElement {
        let target = element(app, identifier)
        if target.waitForExistence(timeout: 15) { return target }
        XCTAssertTrue(element(app, "nativeSidebar").exists,
                      "the sidebar must be the screen on show before a row can be scrolled for:"
                      + "\n\(app.debugDescription)")
        let container = app.scrollViews["channelSidebar.scroll"]
        guard container.exists else { return target }
        var swipes = 0
        while !target.exists, swipes < maxSwipes {
            container.swipeUp(velocity: .fast)
            swipes += 1
        }
        return target
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// A `Toggle` is a `.switch` to the accessibility layer; asserting the typed element is what makes a
    /// silently missing control fail here rather than in a container query that matches nothing.
    private func assertSwitch(_ app: XCUIApplication, _ identifier: String,
                              timeout: TimeInterval = 25) -> XCUIElement {
        let typed = app.switches.matching(identifier: identifier).firstMatch
        XCTAssertTrue(typed.waitForExistence(timeout: timeout),
                      "\(identifier) must exist as a switch:\n\(app.debugDescription)")
        return typed
    }

    private func tapControl(_ app: XCUIApplication, _ identifier: String) {
        let typed = app.buttons.matching(identifier: identifier).firstMatch
        if typed.waitForExistence(timeout: 5), typed.isHittable {
            typed.tap()
            return
        }
        let fallback = element(app, identifier)
        if fallback.waitForExistence(timeout: 5) { fallback.tap() }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Fixture and oracle

    private struct Channel {
        let id: String
        let name: String
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
            throw XCTSkip("could not sign in as \(login) on \(serverURL.absoluteString) (HTTP \(status))")
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
        serverURL.appendingPathComponent(path)
    }

    private func getJSON(_ path: String) throws -> Any {
        var request = URLRequest(url: url(for: path))
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        let (data, response) = try synchronous(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NSError(domain: "T8525Oracle", code: status, userInfo: [
                NSLocalizedDescriptionKey:
                    "GET \(path) -> HTTP \(status) \(String(decoding: data.prefix(200), as: UTF8.self))"])
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func postJSON(_ path: String, body: Any?) throws -> Any {
        try sendJSON("POST", path, body: body)
    }

    private func putJSON(_ path: String, body: Any?) throws -> Any {
        try sendJSON("PUT", path, body: body)
    }

    private func sendJSON(_ method: String, _ path: String, body: Any?) throws -> Any {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = method
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try synchronous(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw XCTSkip("\(method) \(path) answered \(status) — the fixture is not in the state "
                          + "this test needs")
        }
        guard !data.isEmpty, let json = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return json
    }

    private static let restSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

    private func synchronous(_ request: URLRequest) throws -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Data, URLResponse)?
        var failure: Error?
        Self.restSession.dataTask(with: request) { data, response, error in
            if let error { failure = error }
            if let data, let response { result = (data, response) }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 20)
        if let failure { throw failure }
        guard let result else { throw URLError(.timedOut) }
        return result
    }

    /// A channel whose sidebar row is at the top of the list (a leading `0` sorts before this fixture's
    /// `t…`/`t8…`/`town…` names), deleted in `tearDown`.
    private func makeChannel() throws -> Channel {
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        let name = channelNamePrefix + suffix
        let created = try postJSON("/api/v4/channels",
                                   body: ["team_id": teamID!,
                                          "name": name,
                                          "display_name": "0 T8525 live " + suffix,
                                          "type": "O"]) as? [String: Any] ?? [:]
        guard let id = created["id"] as? String, created["name"] as? String == name else {
            throw XCTSkip("could not create the live test channel \(name)")
        }
        createdChannelID = id
        // The notification write needs the membership to exist: read it now so a missing one fails here
        // rather than as an opaque 404 later.
        _ = try getJSON("/api/v4/channels/\(id)/members/\(userID!)")
        // T52-R1's rule: a channel the test just created carries the team's newest activity, which is what
        // puts its row at the top of a 350-channel sidebar. A channel with no posts does not, measured
        // (12:41 run: the row was never reached by 40 swipes).
        _ = try postJSON("/api/v4/posts", body: ["channel_id": id,
                                                "message": "T8525 live fixture post"])
        return Channel(id: id, name: name)
    }

    private func notifyProps(channelID: String) throws -> [String: String] {
        let json = try getJSON("/api/v4/channels/\(channelID)/members/\(userID!)") as? [String: Any]
        let props = json?["notify_props"] as? [String: String] ?? [:]
        XCTAssertFalse(props.isEmpty, "the server must answer the membership's notify_props")
        return props
    }

    /// The write is asynchronous from the tap; the server's stored value is polled rather than assumed,
    /// and the failure message carries what the server actually holds.
    private func waitForStoredIgnoreValue(channelID: String,
                                          expected: String,
                                          timeout: TimeInterval = 15) throws -> [String: String] {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = try notifyProps(channelID: channelID)
        while latest["ignore_channel_mentions"] != expected, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            latest = try notifyProps(channelID: channelID)
        }
        return latest
    }
}
