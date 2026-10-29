// t_42968927 — the live tap test for the profile popover (card: "tapping an author's name or avatar
// opens nothing"). This is a **regression** test, not a re-run of T41:
//
//   * T41's suite launches with `-surfaceMode profile=native`, which is exactly the flag that hides
//     the defect. This suite launches the **shipped defaults**: `.channelView` native (approved) and
//     `.profile` web (not approved). That pair is the state the reader reported — the native pane
//     draws the conversation, so the webview's own popover cannot answer a tap on it.
//   * It taps BOTH affordances upstream offers: the avatar (`post.<id>.avatar`) and the author's
//     name (`post.<id>.author`), and asserts the sheet that opens is *that account's* profile, read
//     from the server.
//   * It also asserts the pane header's own profile control exists in that state, because it was
//     removed by the same `.profile`-surface gate.
//
// The fixture: `perfprobe` (system admin) opens `#t41-profile` in #perf; the setUp posts a fresh
// message **as another account** (`t41buddy`, the T41 seed's second user) so the row is the newest
// post in the channel and therefore on screen without scrolling. Nothing is fabricated: the author's
// username in the assertion comes from the server.
//
// Run (same fixture as T41):
//
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     python3 scripts/qa-test.py --platform ios --sim "iPhone 16 Pro" \
//       --only-testing MattermostUITests/T429ProfileTapUITests
//
// Skips — never fails — when the environment, the server, the buddy account or the channel is
// missing, like every live test in this target.

import XCTest

final class T429ProfileTapUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var myUserID: String!
    private var teamID: String!
    private var channelID: String!
    private var postID: String!
    private var authorUsername: String!

    /// This card's **own** channel, created on first run. Deliberately not `#t41-profile`: posting
    /// the fixture into T41's channel pushed T41's own seed post out of the pane's visible window and
    /// reddened `T41ProfileUITests.testSendMessageOpensTheDirectChannelWithTheAuthor` (measured — the
    /// seed post ended up 38 posts above the bottom). A tap fixture must not degrade another card's
    /// fixture.
    private let channelName = "t429-tap"

    private var buddyLogin: String {
        ProcessInfo.processInfo.environment["MM_AUTH_BUDDY_LOGIN"] ?? "t41buddy"
    }

    private var buddyPassword: String {
        ProcessInfo.processInfo.environment["MM_AUTH_BUDDY_PASSWORD"] ?? "T41-Buddy-Not-A-Real-Secret-1"
    }

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live profile-tap test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        try ping()

        let session = try authenticate(login: loginID, password: password)
        token = session.token
        myUserID = session.userID

        let teams = try getJSON("/api/v4/users/me/teams") as? [[String: Any]] ?? []
        guard let team = teams.first(where: { ($0["name"] as? String) == "perf" }) else {
            throw XCTSkip("#perf is missing — run scripts/perf_seed.py and scripts/t41_profile_seed.py")
        }
        teamID = try XCTUnwrap(team["id"] as? String)

        let channel = try ensureChannel(teamID: teamID!, name: channelName)

        // A fresh post by somebody else, so the row is the newest one in the pane. A separator post
        // from *this* account goes first: two posts by the same author inside the grouping window
        // would draw the buddy's message as a grouped row, which has no header (no avatar, no name)
        // and would make the tap test pass vacuously or fail for the wrong reason.
        _ = try sendJSON("POST", "/api/v4/posts",
                         body: ["channel_id": channelID,
                                "message": "t_42968927 separator \(UUID().uuidString.prefix(8))"],
                         as: token) as? [String: Any] ?? [:]
        let buddy = try authenticate(login: buddyLogin, password: buddyPassword)
        authorUsername = try buddyUsername(buddy.userID)
        try ensureMember(userID: buddy.userID, channelID: channelID)
        let marker = "t_42968927 tap fixture \(UUID().uuidString.prefix(8))"
        let created = try sendJSON("POST", "/api/v4/posts",
                                   body: ["channel_id": channelID, "message": marker],
                                   as: buddy.token) as? [String: Any] ?? [:]
        guard let createdID = created["id"] as? String else {
            throw XCTSkip("the buddy's fixture post was not accepted by the server")
        }
        postID = createdID

        // The pane opens at the newest message; make sure it is the one this test just wrote (a
        // second client could post in between).
        try XCTSkipUnless(try isNewestPost(createdID), "another client posted after the fixture post")
    }

    // MARK: - 1. The avatar

    func testTappingTheAvatarOpensThatAuthorsProfile() throws {
        let app = launchApp()
        openChannel(app)

        let avatar = element(app, "post.\(postID!).avatar")
        XCTAssertTrue(avatar.waitForExistence(timeout: 60),
                      "the author's avatar must be an affordance on the shipped defaults — this is "
                      + "the reported defect:\n\(app.debugDescription)")
        avatar.tap()

        assertProfileOfTheFixtureAuthor(app)
        attach(app, "t429-avatar-tap")
    }

    // MARK: - 2. The name

    func testTappingTheAuthorNameOpensTheSameProfile() throws {
        let app = launchApp()
        openChannel(app)

        let name = element(app, "post.\(postID!).author")
        XCTAssertTrue(name.waitForExistence(timeout: 60),
                      "the author's name must be an affordance, as it is upstream:\n\(app.debugDescription)")
        name.tap()

        assertProfileOfTheFixtureAuthor(app)
        attach(app, "t429-name-tap")
    }

    // MARK: - 3. One popover, both affordances, and the pane header's entry

    /// Name and avatar lead to the same sheet, one at a time: dismiss, re-open from the other
    /// affordance, and the tree still holds exactly one profile sheet.
    func testBothAffordancesOpenOnePopoverAtATime() throws {
        let app = launchApp()
        openChannel(app)

        let avatar = element(app, "post.\(postID!).avatar")
        XCTAssertTrue(avatar.waitForExistence(timeout: 60),
                      "avatar affordance missing:\n\(app.debugDescription)")
        avatar.tap()
        XCTAssertTrue(element(app, "profileSheet").waitForExistence(timeout: 20))
        XCTAssertEqual(elements(app, "profileSheet").count, 1,
                       "the pane must present one profile, not a stack:\n\(app.debugDescription)")
        element(app, "profile.done").tap()
        XCTAssertTrue(waitUntil(timeout: 15) { !element(app, "profileSheet").exists },
                      "Done must dismiss the sheet:\n\(app.debugDescription)")

        let name = element(app, "post.\(postID!).author")
        XCTAssertTrue(name.waitForExistence(timeout: 20), "the row must be back after dismissal")
        name.tap()
        XCTAssertTrue(element(app, "profileSheet").waitForExistence(timeout: 20))
        XCTAssertEqual(elements(app, "profileSheet").count, 1)
        attach(app, "t429-one-popover")
    }

    /// The header's own avatar was hidden by the same `.profile` gate; while the pane is native it
    /// must be offered too (the web client's account menu is not on screen either).
    func testThePanesOwnProfileEntryIsOfferedWhileProfileResolvesWeb() throws {
        let app = launchApp()
        openChannel(app)

        let button = element(app, "nativeProfileButton")
        XCTAssertTrue(button.waitForExistence(timeout: 20),
                      "the pane header must offer the signed-in profile:\n\(app.debugDescription)")
        button.tap()

        let username = element(app, "profile.username")
        XCTAssertTrue(username.waitForExistence(timeout: 20),
                      "my profile must mount:\n\(app.debugDescription)")
        XCTAssertEqual(username.label, "@\(loginID!)",
                       "the header opened the signed-in account, not somebody else")
        attach(app, "t429-header-profile")
    }

    // MARK: - Assertions

    private func assertProfileOfTheFixtureAuthor(_ app: XCUIApplication) {
        let username = element(app, "profile.username")
        XCTAssertTrue(username.waitForExistence(timeout: 20),
                      "the profile sheet must mount:\n\(app.debugDescription)")
        XCTAssertEqual(username.label, "@\(authorUsername!)",
                       "the popover must be about the tapped author, read from the server")
        // The rows upstream draws on another member: a Message action (this account is messageable
        // and not deactivated) and no own-profile entries.
        XCTAssertTrue(element(app, "profile.message").exists,
                      "another member's popover offers Message:\n\(app.debugDescription)")
        XCTAssertFalse(element(app, "profile.setStatus").exists,
                       "somebody else's popover must not offer my own status controls")
        XCTAssertTrue(element(app, "profile.localTime").exists,
                      "the local-time row is part of the popover")
    }

    // MARK: - App driving

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        // NOTE: no `-surfaceMode profile=native`. The shipped default (`.profile` = web) is the
        // state this test exists to cover; adding it would hide the defect again.
        app.launchArguments = ["-uiTestResetPersistedState",
                               "-uiTestForgetSession", serverURL.absoluteString,
                               "-uiTestSeedServer", serverURL.absoluteString,
                               "-uiTestSeedServerName", "Local Mattermost",
                               "-surfaceMode", "shell=native",
                               "-surfaceMode", "auth=native",
                               "-surfaceMode", "sidebar=native",
                               "-uiTestLogLevel", "error",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // Same XCTest/os_log crash guard as T41 (see that file's note).
        app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"
        app.launch()
        signIn(app)
        return app
    }

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
        app.buttons["loginSubmitButton"].tap()
        XCTAssertTrue(element(app, "nativeShell").waitForExistence(timeout: 60),
                      "signing in must reach the shell:\n\(app.debugDescription)")
    }

    /// Open `#t41-profile` through the quick switcher, the way a person would on a workspace whose
    /// sidebar is far longer than one screen (T70's measured reason).
    private func openChannel(_ app: XCUIApplication) {
        let teamRow = element(app, "teamSidebar.team.\(teamID!)")
        XCTAssertTrue(teamRow.waitForExistence(timeout: 40),
                      "the team rail must list #perf:\n\(app.debugDescription)")
        if !(teamRow.value as? String ?? "").contains("Selected") { teamRow.tap() }

        let switcher = app.buttons["channelSidebar.quickSwitcher"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 30),
                      "the sidebar must offer the quick switcher:\n\(app.debugDescription)")
        switcher.tap()
        let field = app.textFields["channelSidebar.quickSwitcher.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the quick switcher must mount")
        field.tap()
        field.typeText(channelName)
        let result = element(app, "channelSidebar.quickSwitcher.result.\(channelID!)")
        XCTAssertTrue(result.waitForExistence(timeout: 30),
                      "the quick switcher must offer #\(channelName):\n\(app.debugDescription)")
        result.tap()
        XCTAssertTrue(element(app, "channelPostList").waitForExistence(timeout: 90),
                      "the channel pane must mount:\n\(app.debugDescription)")
        // The row itself is asserted by each test, with its own message.
    }

    // MARK: - Server

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
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let session = http.value(forHTTPHeaderField: "Token"),
              let user = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = user["id"] as? String else {
            throw XCTSkip("could not sign in as \(login) on \(serverURL.absoluteString) — run "
                          + "scripts/t41_profile_seed.py")
        }
        return (session, id)
    }

    /// The card's own channel, created on first run and rejoined by id afterwards.
    private func ensureChannel(teamID: String, name: String) throws -> String {
        if let existing = try? getJSON("/api/v4/teams/\(teamID)/channels/name/\(name)") as? [String: Any],
           let id = existing["id"] as? String {
            channelID = id
            return id
        }
        let created = try sendJSON("POST", "/api/v4/channels",
                                   body: ["team_id": teamID, "name": name,
                                          "display_name": "T429 tap fixture", "type": "O"],
                                   as: token) as? [String: Any] ?? [:]
        guard let id = created["id"] as? String else {
            throw XCTSkip("the fixture could not create #\(name)")
        }
        channelID = id
        return id
    }

    /// The buddy must be able to post in the card's channel; membership is added by the admin once.
    private func ensureMember(userID: String, channelID: String) throws {
        if (try? getJSON("/api/v4/channels/\(channelID)/members/\(userID)")) != nil { return }
        _ = try sendJSON("POST", "/api/v4/channels/\(channelID)/members",
                         body: ["user_id": userID], as: token)
    }

    private func buddyUsername(_ id: String) throws -> String {
        let user = try getJSON("/api/v4/users/\(id)") as? [String: Any] ?? [:]
        guard let username = user["username"] as? String, !username.isEmpty else {
            throw XCTSkip("the buddy account has no username")
        }
        return username
    }

    private func isNewestPost(_ id: String) throws -> Bool {
        let page = try getJSON("/api/v4/channels/\(channelID!)/posts?per_page=1") as? [String: Any] ?? [:]
        return (page["order"] as? [String] ?? []).first == id
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
            throw NSError(domain: "T429Oracle", code: status, userInfo: [
                NSLocalizedDescriptionKey:
                    "GET \(path) -> HTTP \(status) \(String(decoding: data.prefix(200), as: UTF8.self))"])
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func sendJSON(_ method: String, _ path: String, body: Any?, as session: String) throws -> Any {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = method
        request.setValue("Bearer \(session)", forHTTPHeaderField: "Authorization")
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

    /// No cookie store (a stale `MMAUTHTOKEN` cookie makes the server answer `session_expired`).
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

    // MARK: - Element helpers

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The whole query, for the "only one on screen" assertions.
    private func elements(_ app: XCUIApplication, _ identifier: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: identifier)
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
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
