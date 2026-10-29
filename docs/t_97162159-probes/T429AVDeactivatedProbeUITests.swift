// t_97162159 (QA probe, NOT part of the shipped change): the **deactivated account** row of the
// action matrix, measured live instead of only against the pure function.
//
// The build note (§6) says the deactivated case is unit-only because the local server has no
// deactivated fixture. `t429_deactivated_fixture.py` creates one: the account `t429gone` posts into
// `#t429-tap` and is then deactivated, so its post is a row whose author the server reports as
// deactivated. This probe taps that row's avatar on the **shipped defaults** (`.profile` = web, pane
// host native) and asserts the sheet offers no Message row and says why.
//
// Run: TEST_RUNNER_MM_AUTH_SERVER/_LOGIN/_PASSWORD as for T429ProfileTapUITests.

import XCTest

final class T429AVDeactivatedProbeUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var teamID: String!
    private var channelID: String!
    private var postID: String!

    private let channelName = "t429-tap"
    private let goneUsername = "t429gone"

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "probe: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        serverURL = try XCTUnwrap(URL(string: raw))
        let session = try authenticate(login: loginID, password: password)
        token = session.token

        let teams = try getJSON("/api/v4/users/me/teams") as? [[String: Any]] ?? []
        teamID = try XCTUnwrap(teams.first { ($0["name"] as? String) == "perf" }?["id"] as? String)
        let channel = try getJSON("/api/v4/teams/\(teamID!)/channels/name/\(channelName)") as? [String: Any] ?? [:]
        channelID = try XCTUnwrap(channel["id"] as? String)

        // The fixture script's post: the newest post in the channel, and it must be by t429gone.
        let page = try getJSON("/api/v4/channels/\(channelID!)/posts?per_page=1") as? [String: Any] ?? [:]
        let order = page["order"] as? [String] ?? []
        let posts = page["posts"] as? [String: Any] ?? [:]
        let newestID = try XCTUnwrap(order.first)
        let newest = posts[newestID] as? [String: Any] ?? [:]
        let authorID = try XCTUnwrap(newest["user_id"] as? String)
        let author = try getJSON("/api/v4/users/\(authorID)") as? [String: Any] ?? [:]
        try XCTSkipUnless((author["username"] as? String) == goneUsername,
                          "the newest post in #\(channelName) is not the deactivated fixture — "
                          + "run t429_deactivated_fixture.py first")
        try XCTSkipUnless((author["delete_at"] as? Int ?? 0) > 0,
                          "t429gone is not deactivated on the server")
        postID = newestID
    }

    func testADeactivatedAuthorOffersNoMessageRowAndSaysWhy() throws {
        let app = launchApp()
        openChannel(app)

        let avatar = element(app, "post.\(postID!).avatar")
        XCTAssertTrue(avatar.waitForExistence(timeout: 60),
                      "the deactivated author's avatar must still be an affordance:\n\(app.debugDescription)")
        avatar.tap()

        let username = element(app, "profile.username")
        XCTAssertTrue(username.waitForExistence(timeout: 20),
                      "the profile sheet must mount for a deactivated account:\n\(app.debugDescription)")
        XCTAssertEqual(username.label, "@\(goneUsername)")
        XCTAssertFalse(element(app, "profile.message").exists,
                       "a deactivated account offers no Message row:\n\(app.debugDescription)")
        let reason = element(app, "profile.messageReason")
        XCTAssertTrue(reason.exists, "the sheet must say why instead of a silent gap")
        XCTAssertEqual(reason.label,
                       "This account has been deactivated, so it cannot be messaged.")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "t429av-deactivated"
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Attack 3: one presentation under a re-render

    /// A socket-driven re-render while the sheet is open must neither stack a second sheet nor swap
    /// the account on screen. The trigger is a real event: another account posts in the channel the
    /// pane is drawing (the pane's `@State profilePopover` is what the sheet's binding reads).
    func testANewPostDoesNotStackOrSwapTheOpenProfile() throws {
        let buddyLogin = ProcessInfo.processInfo.environment["MM_AUTH_BUDDY_LOGIN"] ?? "t41buddy"
        let buddyPassword = ProcessInfo.processInfo.environment["MM_AUTH_BUDDY_PASSWORD"]
            ?? "T41-Buddy-Not-A-Real-Secret-1"
        let buddy = try authenticate(login: buddyLogin, password: buddyPassword)

        // The newest post by the buddy: tap its avatar so the open profile is not the deactivated one.
        let page = try getJSON("/api/v4/channels/\(channelID!)/posts?per_page=40") as? [String: Any] ?? [:]
        let order = page["order"] as? [String] ?? []
        let posts = page["posts"] as? [String: Any] ?? [:]
        let buddyPost = try XCTUnwrap(order.first { postID in
            (posts[postID] as? [String: Any])?["user_id"] as? String == buddy.userID
        }, "the channel holds no post by \(buddyLogin)")

        let app = launchApp()
        openChannel(app)
        let avatar = element(app, "post.\(buddyPost).avatar")
        XCTAssertTrue(avatar.waitForExistence(timeout: 60),
                      "the buddy's avatar must be on screen:\n\(app.debugDescription)")
        avatar.tap()
        let username = element(app, "profile.username")
        XCTAssertTrue(username.waitForExistence(timeout: 20), "the profile must mount")
        let openedAs = username.label

        // Re-render trigger: a post from the account whose profile is open.
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/posts"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(buddy.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "channel_id": channelID!,
            "message": "t_42968927 re-render trigger \(UUID().uuidString.prefix(8))"])
        let (_, response) = try synchronous(request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201,
                       "the re-render trigger post must land")

        // Give the socket time to land and the pane time to redraw.
        RunLoop.current.run(until: Date().addingTimeInterval(8))

        let sheets = app.descendants(matching: .any).matching(identifier: "profileSheet")
        XCTAssertEqual(sheets.count, 1,
                       "one post arriving must not stack a second sheet:\n\(app.debugDescription)")
        XCTAssertEqual(element(app, "profile.username").label, openedAs,
                       "the open profile must not be swapped by a redraw")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "t429av-rerender-open-profile"
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - App driving (same launch as T429ProfileTapUITests: shipped defaults)

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

    private func signIn(_ app: XCUIApplication) {
        let field = app.textFields["loginIDField"]
        XCTAssertTrue(field.waitForExistence(timeout: 30),
                      "the native sign-in must mount:\n\(app.debugDescription)")
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

    private func openChannel(_ app: XCUIApplication) {
        let teamRow = element(app, "teamSidebar.team.\(teamID!)")
        XCTAssertTrue(teamRow.waitForExistence(timeout: 40), "the team rail must list #perf")
        if !(teamRow.value as? String ?? "").contains("Selected") { teamRow.tap() }
        let switcher = app.buttons["channelSidebar.quickSwitcher"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 30), "the quick switcher must exist")
        switcher.tap()
        let field = app.textFields["channelSidebar.quickSwitcher.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the quick switcher must mount")
        field.tap()
        field.typeText(channelName)
        let result = element(app, "channelSidebar.quickSwitcher.result.\(channelID!)")
        XCTAssertTrue(result.waitForExistence(timeout: 30), "the quick switcher must offer #\(channelName)")
        result.tap()
        XCTAssertTrue(element(app, "channelPostList").waitForExistence(timeout: 90),
                      "the channel pane must mount:\n\(app.debugDescription)")
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    // MARK: - Server

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
            throw XCTSkip("could not sign in as \(login)")
        }
        return (session, id)
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
            throw NSError(domain: "T429AVProbe", code: status, userInfo: [
                NSLocalizedDescriptionKey: "GET \(path) -> HTTP \(status)"])
        }
        return try JSONSerialization.jsonObject(with: data)
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
}
