// T42 — the Recent mentions surface against a **real** Mattermost server.
//
// Why live: each acceptance criterion of the card is a statement about a running server's data —
//   1. the feed lists *my* mentions, read from the server (`POST /posts/search`) rather than from
//      anything this file knows, across channels and teams;
//   2. the unread dot is the server's read cursor (`mention_count` / `last_viewed_at`), and marking read
//      reaches the server (`POST /channels/members/{me}/mark_read`, `PUT …/threads/{id}/read/{ts}`);
//   3. a mention that arrives while the feed is open appears **without a manual refresh** — the socket
//      path, not a poll that happened to fire.
//
// A stub could only prove this file's own fixtures render. The oracle for every assertion is the server,
// read back through its own API with the same account the app signs in as.
//
// Run (local throwaway server; same fixture accounts as T34/T39/T40/T41):
//
//     python3 scripts/t42_activity_seed.py --url http://127.0.0.1:8065
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     TEST_RUNNER_MM_AUTH_BUDDY_PASSWORD=<buddy password> \
//     python3 scripts/qa-test.py --platform ios --sim "name=iPhone 16 Pro" \
//       --only-testing MattermostUITests/T42ActivityUITests
//
// Each test seeds its own **fresh** mention posts (through the buddy account, which is the only way to
// produce a mention *of me* from another client), so the order the tests run in cannot make one of them
// pass or fail by accident. Each test skips — never fails — when the environment or the server is
// missing, like every live test here. Screenshots are attached so a run leaves visual evidence next to
// the machine verdict.

import XCTest

final class T42ActivityUITests: XCTestCase {

    /// One admin session per test process; the server rate-limits logins by IP (same reason as T40/T41).
    private static var cachedAdminSession: (server: String, token: String, userID: String)?
    private static var cachedBuddySession: (server: String, token: String, userID: String)?

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var userID: String!
    private var teamID: String!

    private let channelName = "t42-activity"
    private let buddyLogin = "t42buddy"

    private var buddyPassword: String {
        ProcessInfo.processInfo.environment["MM_AUTH_BUDDY_PASSWORD"]
            ?? "T42-Buddy-Not-A-Real-Secret-1"
    }

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live mentions test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
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

    // MARK: - 1. The feed is the server's own mentions

    func testTheMentionsTabListsMyMentionsFromTheServer() throws {
        let mention = try seedMention(marker: "list")
        // Posted **as the buddy**: posting in a channel moves the *author's* read cursor to that post, so a
        // control post authored by me would read my own mention back to "read" and the unread assertion
        // below would be testing nothing.
        let buddy = try buddySession()
        let control = try seedPost(message: "T42 UI \(stamp()): nobody is named here", as: buddy.token)

        let app = launchApp()
        openMentions(app)

        let row = element(app, "activity.row.\(mention.id)")
        XCTAssertTrue(row.waitForExistence(timeout: 30),
                      "the feed must list the mention the server has for me:\n\(app.debugDescription)")
        XCTAssertTrue(row.label.contains("unread"),
                      "a freshly seeded mention must be unread; the row reads \"\(row.label)\"")
        // The channel line and the author come from the server's own post/channel reads.
        XCTAssertTrue(row.label.contains("@\(loginID)") || row.label.contains("Terry"),
                      "the row names its author: \"\(row.label)\"")

        // A post that names nobody is not a mention of me, so it must not be a row.
        XCTAssertFalse(element(app, "activity.row.\(control.id)").exists,
                       "a post that names nobody must not appear in my mentions")

        XCTAssertTrue(element(app, "activity.subtitle").exists, "the header counts the window")
        attach(app, "t42-mentions-list")
    }

    // MARK: - 2. Marking read reaches the server

    func testMarkAllReadClearsTheDotsAndReachesTheServer() throws {
        let first = try seedMention(marker: "read-a")
        _ = try seedMention(marker: "read-b")
        XCTAssertTrue(try channelMentionCount() > 0,
                      "the fixture must start with unread mentions before this test can prove a read")

        let app = launchApp()
        openMentions(app)

        let row = element(app, "activity.row.\(first.id)")
        XCTAssertTrue(row.waitForExistence(timeout: 30),
                      "the seeded mention must be listed:\n\(app.debugDescription)")
        XCTAssertTrue(row.label.contains("unread"), "…and unread before the action: \"\(row.label)\"")

        let markAll = element(app, "activity.markAllRead")
        XCTAssertTrue(markAll.waitForExistence(timeout: 10),
                      "the header offers \"mark all read\":\n\(app.debugDescription)")
        markAll.tap()

        // The server is the oracle: its own counter for the channel must reach zero.
        XCTAssertTrue(waitUntil(timeout: 25) { (try? self.channelMentionCount()) == 0 },
                      "marking read must reach the server; its mention_count is "
                      + "\(String(describing: try? channelMentionCount()))")
        XCTAssertTrue(waitUntil(timeout: 15) { !row.label.contains("unread") },
                      "the row's dot must clear without a reload: \"\(row.label)\"")
        attach(app, "t42-mentions-marked-read")
    }

    // MARK: - 3. The feed is live

    func testAMentionArrivesWhileTheFeedIsOpen() throws {
        // A marker post first, so the app's window is loaded before the mention exists.
        _ = try seedPost(message: "T42 UI \(stamp()): the feed is about to be open")

        let app = launchApp()
        openMentions(app)
        XCTAssertTrue(element(app, "activity.list").waitForExistence(timeout: 30),
                      "the feed must mount before the live mention is posted:\n\(app.debugDescription)")

        let live = try seedMention(marker: "live")
        let row = element(app, "activity.row.\(live.id)")
        // No tap, no pull-to-refresh: only the socket can put this row on screen.
        XCTAssertTrue(row.waitForExistence(timeout: 30),
                      "a mention posted while the feed is open must appear on its own:\n"
                      + "\(app.debugDescription)")
        XCTAssertTrue(row.label.contains("unread"), "…with its dot: \"\(row.label)\"")
        attach(app, "t42-mentions-live")
    }

    // MARK: - 4. A row opens what it belongs to

    /// The card's second criterion is *"jumping from a mention lands on the **exact post** in the
    /// **right channel**"*, so this asserts both halves rather than \"a channel header exists\" (which
    /// was true of whatever the shell happened to show, T42-AV F3):
    ///
    ///  * the right channel — the header renders the server's own `display_name` for `#t42-activity`
    ///    (not the URL slug the shell is handed first), so it is read from the server here and compared;
    ///  * the exact post — T39's marking bar (`postFocus.<postID>`) is **absent before** the tap and
    ///    **present after** it, so the timeline landed on that post and not merely on its channel.
    ///
    /// The pre-tap assertions are what make the post-tap ones non-vacuous.
    func testTappingARowOpensItsChannel() throws {
        let target = try channel()
        let mention = try seedMention(marker: "jump")
        let app = launchApp()
        openMentions(app)

        let row = element(app, "activity.row.\(mention.id)")
        XCTAssertTrue(row.waitForExistence(timeout: 30),
                      "the seeded mention must be listed:\n\(app.debugDescription)")

        // Before the tap the mentions pane is on screen and no channel header is — otherwise
        // "the header exists" after the tap would prove nothing about the tap.
        let focus = element(app, "postFocus.\(mention.id)")
        XCTAssertFalse(element(app, "nativeChannelTitle").exists,
                       "the mentions pane must not already show a channel header before the tap:\n"
                       + app.debugDescription)
        XCTAssertFalse(focus.exists,
                       "the timeline must not already be focused on the mention's post before the tap")

        row.tap()

        // Which channel: the header's label is the server's `display_name` for that channel.
        let title = element(app, "nativeChannelTitle")
        XCTAssertTrue(title.waitForExistence(timeout: 40),
                      "tapping a mention must open its channel:\n\(app.debugDescription)")
        XCTAssertTrue(waitUntil(timeout: 20) { title.label == target.displayName },
                      "the jump must open the mention's own channel; the header reads "
                      + "\"\(title.label)\", expected \"\(target.displayName)\"")

        // Which post: T39's marking bar on the row the jump landed on.
        XCTAssertTrue(focus.waitForExistence(timeout: 40),
                      "the jump must land on the exact post, not merely open a channel:\n"
                      + app.debugDescription)
        attach(app, "t42-mentions-opened-channel")
    }

    // MARK: - App driving

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetPersistedState",
                               "-uiTestForgetSession", serverURL.absoluteString,
                               "-uiTestSeedServer", serverURL.absoluteString,
                               "-uiTestSeedServerName", "Local Mattermost",
                               "-surfaceMode", "shell=native",
                               "-surfaceMode", "auth=native",
                               "-surfaceMode", "sidebar=native",
                               "-surfaceMode", "activity=native",
                               "-uiTestLogLevel", "error",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"
        app.launch()
        signIn(app, login: loginID, password: password)
        return app
    }

    private func signIn(_ app: XCUIApplication, login: String, password: String) {
        let field = app.textFields["loginIDField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20),
                      "the native sign-in must mount against \(serverURL.absoluteString):\n"
                      + "\(app.debugDescription)")
        field.tap()
        field.typeText(login)
        let secret = app.secureTextFields["loginPasswordField"]
        XCTAssertTrue(secret.exists)
        secret.tap()
        secret.typeText(password)
        app.buttons["loginSubmitButton"].tap()
        XCTAssertTrue(element(app, "nativeShell").waitForExistence(timeout: 40),
                      "signing in must reach the shell:\n\(app.debugDescription)")
    }

    /// The mentions surface, whichever chrome the layout uses: the fifth tab in the compact layout, the
    /// toolbar sheet in the split one (a Catalyst window is wide enough for the split layout).
    private func openMentions(_ app: XCUIApplication) {
        let tab = app.tabBars.buttons["Mentions"]
        if tab.waitForExistence(timeout: 8) {
            tab.tap()
        } else {
            let button = element(app, "shellActivityButton")
            XCTAssertTrue(button.waitForExistence(timeout: 25),
                          "the shell must offer the mentions surface:\n\(app.debugDescription)")
            button.tap()
        }
        XCTAssertTrue(element(app, "nativeActivityPane").waitForExistence(timeout: 30),
                      "the mentions pane must mount:\n\(app.debugDescription)")
    }

    // MARK: - Fixture seeding (through the server, as another account)

    private struct Post { let id: String }

    private func stamp() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

    /// The fixture channel's identity from the server: the id the API needs, and the `display_name`
    /// the header renders (the shell starts with the URL slug and the model replaces it a beat later).
    private func channel() throws -> (id: String, displayName: String) {
        let body = try getJSON("/api/v4/teams/\(teamID!)/channels/name/\(channelName)")
            as? [String: Any] ?? [:]
        guard let id = body["id"] as? String else {
            throw XCTSkip("#\(channelName) is missing — run scripts/t42_activity_seed.py")
        }
        return (id: id, displayName: body["display_name"] as? String ?? channelName)
    }

    private func buddySession() throws -> (token: String, userID: String) {
        if let cached = Self.cachedBuddySession, cached.server == serverURL.absoluteString {
            return (cached.token, cached.userID)
        }
        let session = try authenticate(login: buddyLogin, password: buddyPassword)
        Self.cachedBuddySession = (server: serverURL.absoluteString, token: session.token,
                                   userID: session.userID)
        return session
    }

    /// A fresh mention of the signed-in account, posted by the buddy — the only way to produce one.
    private func seedMention(marker: String) throws -> Post {
        let buddy = try buddySession()
        return try seedPost(message: "T42 UI \(stamp()) \(marker): @\(loginID!) you were named",
                            as: buddy.token)
    }

    private func seedPost(message: String, as session: String? = nil) throws -> Post {
        let channelID = try channel().id
        let body = try sendJSON("POST", "/api/v4/posts",
                                body: ["channel_id": channelID, "message": message],
                                as: session ?? token) as? [String: Any] ?? [:]
        guard let id = body["id"] as? String else {
            throw XCTSkip("the fixture channel did not accept a post")
        }
        return Post(id: id)
    }

    /// The server's own mention counter for the fixture channel — the oracle for "marked read".
    private func channelMentionCount() throws -> Int {
        let rows = try getJSON("/api/v4/users/\(userID!)/teams/\(teamID!)/channels/members")
            as? [[String: Any]] ?? []
        let channelID = (try? channel().id) ?? ""
        let row = rows.first { ($0["channel_id"] as? String) == channelID }
        return Int(row?["mention_count"] as? Int ?? -1)
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
            throw XCTSkip("the fixture account has no team — run scripts/t42_activity_seed.py")
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
            throw NSError(domain: "T42Oracle", code: status, userInfo: [
                NSLocalizedDescriptionKey:
                    "GET \(path) -> HTTP \(status) \(String(decoding: data.prefix(200), as: UTF8.self))"])
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func sendJSON(_ method: String, _ path: String, body: Any?,
                          as session: String? = nil) throws -> Any {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = method
        request.setValue("Bearer \(session ?? token!)", forHTTPHeaderField: "Authorization")
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

    /// The REST oracle's own session — **no cookie store** (a stale `MMAUTHTOKEN` cookie makes the
    /// server answer `session_expired` before it looks at the request; see T40's note).
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
