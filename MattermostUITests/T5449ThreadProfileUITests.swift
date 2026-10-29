// t_07216319 (C1 of t_8f9f5449) — the live test for the profile popover on the **thread** host.
//
// The parent card fixed the author tap for the channel timeline only; the thread pane draws the same
// `PostRowView` (same `post.<id>.author` and `post.<id>.avatar` affordances) but never passed
// `onShowProfile` into it, so a reply's author was inert there. The card wires the callback and folds
// the profile into the one sheet slot the thread list already owns (`ChannelListSheet.profile`), so:
//
//   * nothing here launches with `-surfaceMode profile=native`: T429's lesson is that the flag hides
//     exactly this class of defect — the shipped default (`.profile` = web) must offer the tap;
//   * the fixture is a **root by perfprobe plus a reply by t41buddy**, because a reply by the same
//     author inside the grouping window draws a grouped row with no header — no avatar, no name — and
//     the test would pass vacuously or fail for the wrong reason;
//   * the assertion is the **server's** username for the reply's author (`GET /users/{authorID}`),
//     and the author must not be the signed-in account, so a sheet that opened the wrong account (or
//     the reader's own profile) cannot pass;
//   * the fixture lives in `#t429-tap`, never `#t41-profile`: T429 §5.1 records that posting there
//     pushed T41's own seed post out of the pane's window and reddened T41's DM test.
//
// Run:
//
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     python3 scripts/qa-test.py --platform ios --sim "name=iPhone 17 Pro" \
//       --only-testing MattermostUITests/T5449ThreadProfileUITests
//
// Skips — never fails — when the environment, the server, the buddy account or its membership in the
// fixture channel is missing, like every live test in this target.

import XCTest

final class T5449ThreadProfileUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var myUserID: String!
    private var teamID: String!
    private var channelID: String!

    /// The thread this test builds: one root by the signed-in account, one reply by the buddy.
    private var rootPostID: String!
    private var replyPostID: String!
    /// The reply author's username, read from the server — never a local string.
    private var replyAuthorUsername: String!

    /// T429's channel, reused on purpose: its two accounts exist and its fixtures are cheap. It is
    /// **not** `#t41-profile` (see the note at the top of this file).
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
                          "Live thread-profile test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
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

        channelID = try ensureChannel(teamID: teamID, name: channelName)

        let buddy = try authenticate(login: buddyLogin, password: buddyPassword)
        try ensureMember(userID: buddy.userID, channelID: channelID)
        replyAuthorUsername = try username(of: buddy.userID)
        try XCTSkipIf(replyAuthorUsername == loginID,
                      "the buddy account is the signed-in account — the header would group the reply")

        // Root as **this** account so the buddy's reply is a different author and therefore draws a
        // header (avatar + name). Both posts carry a stamp: the channel is shared with T429's suite.
        let stamp = UUID().uuidString.prefix(8)
        let root = try sendJSON("POST", "/api/v4/posts",
                                body: ["channel_id": channelID,
                                       "message": "t_07216319 thread fixture root \(stamp)"],
                                as: token) as? [String: Any] ?? [:]
        guard let rootID = root["id"] as? String else {
            throw XCTSkip("the root post was not accepted by the server")
        }
        rootPostID = rootID

        let reply = try sendJSON("POST", "/api/v4/posts",
                                 body: ["channel_id": channelID,
                                        "root_id": rootID,
                                        "message": "t_07216319 thread fixture reply \(stamp)"],
                                 as: buddy.token) as? [String: Any] ?? [:]
        guard let replyID = reply["id"] as? String else {
            throw XCTSkip("the reply was not accepted by the server")
        }
        replyPostID = replyID

        // The server must agree the reply is in the thread before the UI is asked to draw it.
        let thread = try getJSON("/api/v4/posts/\(rootID)/thread") as? [String: Any] ?? [:]
        let order = thread["order"] as? [String] ?? []
        try XCTSkipUnless(order.contains(replyID),
                          "the server's thread does not list the reply — answered \(order)")
    }

    // MARK: - The test

    /// A reply's author, tapped in the thread pane, opens **that author's** profile.
    ///
    /// The tap goes through the reply's **avatar** (`post.<id>.avatar`), one of the two affordances
    /// upstream offers; the avatar and the name share **one** callback, so this exercises the same
    /// route. In this build the reply row's name button is wired and addressable
    /// (`post.<id>.author`, asserted below) but draws empty — the thread pane resolves no profile for
    /// that reply's author, so the name is a 0×0 target and cannot be tapped. That is a separate defect
    /// from this card's (the popover opens either way) and is recorded, measured, in
    /// `docs/t_8f9f5449-c1-build-note.md` §5.
    func testTheAuthorOfAThreadReplyOpensTheirProfile() throws {
        let app = launchApp()
        openChannel(app)
        openThread(app)

        // The wiring itself: both affordances are addressable in this host. `PostRowView` keeps its own
        // identifiers inside the thread row's container, which T36 measured (the tombstone marker still
        // resolves as `post.<id>.deleted` under `thread.post.<id>`) — so the element is
        // `post.<replyID>.author`, not the card's assumed `thread.post.<replyID>.author`.
        let name = element(app, "post.\(replyPostID!).author")
        XCTAssertTrue(name.waitForExistence(timeout: 60),
                      "a reply's author name must be wired in the thread pane — this is the defect this "
                      + "card fixes:\n\(app.debugDescription)")
        let avatar = element(app, "post.\(replyPostID!).avatar")
        XCTAssertTrue(avatar.waitForExistence(timeout: 20),
                      "a reply's author avatar must be an affordance in the thread pane:\n"
                      + "\(app.debugDescription)")
        avatar.tap()

        XCTAssertTrue(element(app, "profileSheet").waitForExistence(timeout: 20),
                      "the author tap must open the profile from the thread host:\n"
                      + "\(app.debugDescription)")
        let username = element(app, "profile.username")
        XCTAssertTrue(username.waitForExistence(timeout: 20),
                      "the profile sheet must mount:\n\(app.debugDescription)")
        XCTAssertEqual(username.label, "@\(replyAuthorUsername!)",
                       "the popover must be about the tapped reply's author, read from the server, "
                       + "not the root's author and not the signed-in account")

        attach(app, "t5449-thread-reply-profile")
    }

    // MARK: - App driving

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        // NOTE: no `-surfaceMode profile=native`. The shipped default (`.profile` = web) is the state
        // this test exists to cover; adding it would hide the defect the card is about (T429's lesson).
        app.launchArguments = ["-uiTestResetPersistedState",
                               "-uiTestForgetSession", serverURL.absoluteString,
                               "-uiTestSeedServer", serverURL.absoluteString,
                               "-uiTestSeedServerName", "Local Mattermost",
                               "-surfaceMode", "shell=native",
                               "-surfaceMode", "auth=native",
                               "-surfaceMode", "sidebar=native",
                               "-uiTestLogLevel", "error",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // Same XCTest/os_log crash guard as T41/T429.
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

    /// Open the fixture channel through the quick switcher, the way a person would on a workspace
    /// whose sidebar is longer than one screen (T70's measured reason).
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
    }

    /// Open the fixture's thread from the channel timeline (the root's reply line).
    private func openThread(_ app: XCUIApplication) {
        let line = element(app, "post.\(rootPostID!).replyCount")
        XCTAssertTrue(revealPost(app, rootPostID!).exists && line.waitForExistence(timeout: 30),
                      "the fixture root must carry a reply line to tap:\n\(app.debugDescription)")
        line.tap()
        XCTAssertTrue(element(app, "threadPane").waitForExistence(timeout: 40),
                      "the reply line must open the thread:\n\(app.debugDescription)")
        XCTAssertTrue(element(app, "threadPostList").waitForExistence(timeout: 40),
                      "the thread's post list must mount:\n\(app.debugDescription)")
    }

    /// Scroll the channel timeline until a post row is drawn. The pane opens at the newest message, so
    /// the fixture is normally on screen; a concurrent client posting can push it up.
    private func revealPost(_ app: XCUIApplication, _ postID: String, maxSwipes: Int = 12) -> XCUIElement {
        let target = element(app, "post.\(postID)")
        guard !target.exists else { return target }
        let list = element(app, "channelPostList")
        var swipes = 0
        while !target.exists, swipes < maxSwipes {
            list.swipeUp(velocity: .fast)
            swipes += 1
        }
        while !target.exists, swipes < maxSwipes * 2 {
            list.swipeDown(velocity: .fast)
            swipes += 1
        }
        return target
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

    /// T429's channel, created on first run and rejoined by name afterwards.
    private func ensureChannel(teamID: String, name: String) throws -> String {
        if let existing = try? getJSON("/api/v4/teams/\(teamID)/channels/name/\(name)") as? [String: Any],
           let id = existing["id"] as? String {
            return id
        }
        let created = try sendJSON("POST", "/api/v4/channels",
                                   body: ["team_id": teamID, "name": name,
                                          "display_name": "T429 tap fixture", "type": "O"],
                                   as: token) as? [String: Any] ?? [:]
        guard let id = created["id"] as? String else {
            throw XCTSkip("the fixture could not create #\(name)")
        }
        return id
    }

    private func ensureMember(userID: String, channelID: String) throws {
        if (try? getJSON("/api/v4/channels/\(channelID)/members/\(userID)")) != nil { return }
        _ = try sendJSON("POST", "/api/v4/channels/\(channelID)/members",
                         body: ["user_id": userID], as: token)
    }

    /// The reply author's username, read from the server — never a local string.
    private func username(of userID: String) throws -> String {
        let user = try getJSON("/api/v4/users/\(userID)") as? [String: Any] ?? [:]
        guard let username = user["username"] as? String, !username.isEmpty else {
            throw XCTSkip("the reply's author has no username")
        }
        return username
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
            throw NSError(domain: "T5449Oracle", code: status, userInfo: [
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

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
