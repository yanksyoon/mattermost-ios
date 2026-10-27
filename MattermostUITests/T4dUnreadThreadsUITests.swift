// t_4dfdf856 — unread threads must be reachable, and counted, from the rail (upstream Threads >
// Unreads), against a **real** Mattermost server.
//
// The reported defect: "no place in the left panel to see unread threads / messages". The pane has had
// All / Unreads tabs since T36, but on the wide layout nothing in the sidebar, the team rail or the
// toolbar opened it, and no surface said how many threads were waiting; on a phone the Threads tab
// carried no count either. This suite proves the reader-visible property end to end, with the server's
// own numbers as the oracle:
//
//   1. the channel list draws an unread-thread count **while the Threads pane is closed**;
//   2. reading that thread **on the server** (another client) moves the number in the left panel with
//      the pane still closed, and without a relaunch — the count is live state, not a snapshot;
//   3. one tap on that row opens the Threads pane (the row is not inert on a Mac, and not a no-op on a
//      phone);
//   4. the fixture thread is a row of the pane's All tab, and gone from Unreads once read;
//   5. the pane's own counter line reports the same number the rail does (one derivation, one model).
//
// Fixture: the suite creates its own thread (root by me, reply by the second account, follow written
// explicitly — before the reply, because on this server following a thread marks it read) in a channel
// it does **not** open: opening a channel marks that channel's threads read (measured in T36) and would
// clear the very state under test.
//
// Run (local throwaway server, credentials in `scripts/perf_seed.py`):
//
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     python3 scripts/qa-test.py --platform ios --sim "iPhone 16 Pro" \
//       --only-testing MattermostUITests/T4dUnreadThreadsUITests
//
// Each test skips (never fails) when the environment or the fixture is missing, like every live test
// here. Nothing is fabricated: a skipped test is reported as skipped.

import XCTest

final class T4dUnreadThreadsUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var userID: String!
    private var teamID: String!

    /// The second author: its reply is what makes a thread unread for me.
    private let secondLogin = "t36reply"
    private let secondPassword = "T36Reply-Not-A-Real-Secret-1"
    private var secondToken: String!

    /// The channel the fixture thread lives in. The app never opens a channel at all: opening one marks
    /// that channel's threads read on this server (measured in T36), which would clear the very state
    /// under test — and on a phone it would push the channel pane over the sidebar the rail lives in.
    private var fixtureChannelID: String!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live unread-threads test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        try ping()
        let session = try authenticate(login: loginID, password: password)
        token = session.token
        userID = session.userID
        guard let team = try teamsForMe().first(where: { $0["name"] as? String == "perf" }) else {
            throw XCTSkip("team #perf is missing — run scripts/perf_seed.py")
        }
        teamID = team["id"] as? String
        secondToken = try authenticate(login: secondLogin, password: secondPassword).token

        // A channel of my own to hold the fixture thread; the API's own membership list, so it is a
        // channel the app's sidebar will draw.
        let mine = try myChannels().filter { ($0["type"] as? String) == "O" || ($0["type"] as? String) == "P" }
        guard let fixture = mine.first(where: { ($0["name"] as? String) == "t36-threads" }) ?? mine.first else {
            throw XCTSkip("need a joined channel in #perf for this fixture, found \(mine.count)")
        }
        fixtureChannelID = fixture["id"] as? String
    }

    // MARK: - The rail entry

    func testTheRailCountsUnreadThreadsAndOpensTheThreadPane() throws {
        // A fixture thread of this run's own, with one unread reply for me by another account.
        //
        // Order matters and it is measured, not guessed (`scripts/t4d_thread_unread_probe.py`):
        // `PUT …/threads/{id}/following` sets `last_viewed_at` and **clears** the thread's unread
        // replies, so a fixture that replies first and follows second ends up with nothing unread
        // (observed: `unread_replies` 1 before the follow, 0 after it). So the follow is written
        // first — the thread has no replies yet, there is nothing to read — and *then* the other
        // account replies.
        let stamp = Int(Date().timeIntervalSince1970)
        let root = try post(message: "t4d rail fixture \(stamp)", channelID: fixtureChannelID, as: token)
        XCTAssertEqual(root["user_id"] as? String, userID, "the fixture root must be mine")
        let rootID = try XCTUnwrap(root["id"] as? String)
        try follow(rootID)
        let totalsBefore = try XCTUnwrap(try teamUnreadThreads())
        Thread.sleep(forTimeInterval: 0.35)
        let reply = try post(message: "t4d unread reply \(stamp)", channelID: fixtureChannelID,
                             rootID: rootID, as: secondToken)
        XCTAssertNotEqual(reply["user_id"] as? String, userID,
                          "the unread reply must be somebody else's")
        // Oracle before launch: the server counts this thread as unread for me, and its team counter
        // moved with it (a fixture that never became unread would make every later assertion vacuous).
        var fixture: ThreadEntry?
        XCTAssertTrue(waitUntil(timeout: 20) {
            fixture = try? fetchThread(rootID)
            return fixture?.unreadReplies == 1
        }, "the fixture leaves exactly one unread reply, the server said \(String(describing: fixture))")
        XCTAssertEqual(fixture?.unreadMentions, 0, "the fixture reply names nobody")
        XCTAssertEqual(try teamUnreadThreads(), totalsBefore + 1,
                       "the team's own unread-thread counter must move with the fixture")

        let app = launchShell()

        // 1. The count is drawn with the pane closed.
        //
        // The number is read from the row's **accessibility value**, not from a nested element: a
        // `Button` merges its label's children into one accessibility element, which is why this
        // client's channel rows put their badge copy on the row's value (and hide the badge itself).
        let railRow = revealThreadsRow(app)
        XCTAssertTrue(railRow.exists,
                      "the rail must offer a Threads entry:\n\(app.debugDescription)")
        var railCount = 0
        XCTAssertTrue(waitUntil(timeout: 40) {
            guard let value = railValue(app), firstInteger(in: value) != nil else { return false }
            railCount = firstInteger(in: value) ?? 0
            return true
        }, "the channel list must draw an unread-thread count without the pane being open, the row "
           + "said \(String(describing: railRow.value)):\n\(app.debugDescription)")
        XCTAssertGreaterThan(railCount, 0, "the fixture left a thread unread, so the rail must count it")
        XCTAssertTrue(railValue(app)?.contains("unread thread") == true,
                      "the row must say what it counts, said \(String(describing: railRow.value))")
        attach(app, "t4d-01-rail-badge")

        // 2. Live, with the pane still closed: reading the thread on the *server* (another client) must
        //    move the left panel's number. This is the reported complaint measured end to end — a count
        //    that only appears after opening the pane would still leave the rail silent.
        try markRead(rootID)
        XCTAssertTrue(waitUntil(timeout: 40) {
            (firstInteger(in: railValue(app) ?? "") ?? 0) == railCount - 1
        }, "after the server reports the thread read, the rail must count \(railCount - 1) unread "
           + "threads and still said \(String(describing: railValue(app))):\n\(app.debugDescription)")
        attach(app, "t4d-02-rail-after-server-read")

        // 3. One tap opens the pane — the wide layout's detail column, or a push on a phone.
        railRow.tap()
        XCTAssertTrue(element(app, "nativeThreadsList").waitForExistence(timeout: 40),
                      "the rail's Threads row must open the Threads pane:\n\(app.debugDescription)")

        // 4. The thread is still a row of the pane's All tab (a read thread is still a thread) …
        let row = element(app, "globalThreads.row.\(rootID)")
        XCTAssertTrue(row.waitForExistence(timeout: 30),
                      "the fixture thread has the newest activity and must be a row of the list:\n"
                      + "\(app.debugDescription)")
        attach(app, "t4d-03-pane-all-tab")

        // … and gone from Unreads, with the pane's own counter line agreeing with the rail: one model,
        // one number. The comparison is against the value read in step 2, because on a phone the pane
        // covers the channel list and both cannot be read at the same moment (measured: the row is not
        // in the tree while the pane is open).
        XCTAssertTrue(element(app, "globalThreads.tabs").waitForExistence(timeout: 20),
                      "the pane must offer its All / Unreads tabs:\n\(app.debugDescription)")
        element(app, "globalThreads.tabs").buttons["Unreads"].tap()
        let subtitle = element(app, "globalThreads.subtitle")
        XCTAssertTrue(subtitle.waitForExistence(timeout: 30),
                      "the pane must draw its counter line:\n\(app.debugDescription)")
        XCTAssertFalse(row.waitForExistence(timeout: 5),
                       "a read thread must not be a row of the Unreads tab:\n\(app.debugDescription)")
        XCTAssertTrue(waitUntil(timeout: 20) {
            firstInteger(in: subtitle.label) == railCount - 1
        }, "the pane must count the same \(railCount - 1) unread threads the rail does, and said "
           + "\(subtitle.label.debugDescription)")
        attach(app, "t4d-04-unreads-tab")
    }

    // MARK: - Server helpers

    struct ThreadEntry {
        let id: String
        let unreadReplies: Int
        let unreadMentions: Int
    }

    private func ping() throws {
        let (_, response) = try synchronous(URLRequest(url: serverURL.appendingPathComponent(
            "api/v4/system/ping")))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200,
                       "the server at \(serverURL.absoluteString) must answer its ping")
    }

    private func authenticate(login: String, password: String) throws -> (token: String, userID: String) {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/users/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["login_id": login,
                                                                       "password": password])
        let (data, response) = try synchronous(request)
        let http = response as? HTTPURLResponse
        guard http?.statusCode == 200 else {
            throw XCTSkip("could not sign in as \(login): HTTP \(http?.statusCode ?? -1)")
        }
        guard let header = http?.value(forHTTPHeaderField: "Token"),
              let me = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = me["id"] as? String else {
            throw XCTSkip("the login answer carried no token")
        }
        return (header, id)
    }

    private func teamsForMe() throws -> [[String: Any]] {
        try getJSON("/api/v4/users/me/teams") as? [[String: Any]] ?? []
    }

    /// `GET /users/me/teams/{team}/channels` — the channels I am a member of, in the server's order.
    private func myChannels() throws -> [[String: Any]] {
        try getJSON("/api/v4/users/me/teams/\(teamID!)/channels") as? [[String: Any]] ?? []
    }

    /// `PUT /users/me/teams/{team}/threads/{id}/following` — write the follow this suite asserts about.
    private func follow(_ threadID: String) throws {
        var request = URLRequest(url: serverURL.appendingPathComponent(
            "api/v4/users/me/teams/\(teamID!)/threads/\(threadID)/following"))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "XMLHttpRequest")
        request.httpBody = Data("{}".utf8)
        let (_, response) = try synchronous(request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200,
                       "the fixture's explicit follow must be accepted")
    }

    /// `PUT …/threads/{id}/read/{ts}` — the server's own read path, i.e. what another client's read does.
    private func markRead(_ threadID: String) throws {
        let stamp = Int64(Date().timeIntervalSince1970 * 1000)
        var request = URLRequest(url: serverURL.appendingPathComponent(
            "api/v4/users/me/teams/\(teamID!)/threads/\(threadID)/read/\(stamp)"))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "XMLHttpRequest")
        let (_, response) = try synchronous(request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200,
                       "marking the fixture thread read must be accepted")
        // The server's counter is the oracle for the read taking effect at all.
        XCTAssertTrue(waitUntil(timeout: 20) { self.serverUnreadReplies(threadID) == 0 },
                      "the server must report the thread read before the app is asserted about")
    }

    /// The server's unread-reply count for one thread, or nil when it does not answer (unfollowed).
    private func serverUnreadReplies(_ threadID: String) -> Int? {
        guard let entry = try? fetchThread(threadID) else { return nil }
        return entry.unreadReplies
    }

    /// `GET …/threads?totalsOnly=true` — the team's own unread-thread counter.
    private func teamUnreadThreads() throws -> Int? {
        let json = try getJSON("/api/v4/users/me/teams/\(teamID!)/threads?per_page=1&totalsOnly=true")
        return (json as? [String: Any])?["total_unread_threads"] as? Int
    }

    /// `GET …/threads/{id}` answers 200 for a followed thread and 404 once unfollowed (measured).
    private func fetchThread(_ threadID: String) throws -> ThreadEntry? {
        var request = URLRequest(url: serverURL.appendingPathComponent(
            "api/v4/users/me/teams/\(teamID!)/threads/\(threadID)"))
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? synchronous(request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = entry["id"] as? String else { return nil }
        return ThreadEntry(id: id,
                           unreadReplies: entry["unread_replies"] as? Int ?? 0,
                           unreadMentions: entry["unread_mentions"] as? Int ?? 0)
    }

    private func post(message: String, channelID: String, rootID: String? = nil,
                      as token: String) throws -> [String: Any] {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/posts"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "XMLHttpRequest")
        var body: [String: Any] = ["channel_id": channelID, "message": message]
        if let rootID { body["root_id"] = rootID }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try synchronous(request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201,
                       "the server must accept the fixture post")
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func getJSON(_ pathWithQuery: String) throws -> Any {
        let parts = pathWithQuery.split(separator: "?", maxSplits: 1,
                                        omittingEmptySubsequences: false)
        var components = URLComponents(url: serverURL.appendingPathComponent(String(parts[0])),
                                       resolvingAgainstBaseURL: false)
        if parts.count > 1 { components?.query = String(parts[1]) }
        let url = try XCTUnwrap(components?.url)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        let (data, response) = try synchronous(request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200,
                       "GET \(pathWithQuery) must answer 200")
        return try JSONSerialization.jsonObject(with: data)
    }

    private func synchronous(_ request: URLRequest) throws -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Data, URLResponse)?
        var failure: Error?
        Self.fixtureSession.dataTask(with: request) { data, response, error in
            if let error { failure = error }
            if let data, let response { result = (data, response) }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 20)
        if let failure { throw failure }
        guard let result else { throw URLError(.timedOut) }
        return result
    }

    /// The fixture's own session: no cookies at all, so `Authorization` is the only identity a fixture
    /// call can have (T36-AV F2: a shared cookie jar silently re-attributed the fixture's posts).
    private static let fixtureSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    // MARK: - App helpers

    /// Launch, sign in, and wait for the channel list — the state the reader is in when they look for
    /// unread threads. No channel is opened: that would mark its threads read, and on a phone it would
    /// push the channel pane over the sidebar.
    private func launchShell() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetPersistedState",
                               "-uiTestForgetSession", serverURL.absoluteString,
                               "-uiTestSeedServer", serverURL.absoluteString,
                               "-uiTestSeedServerName", "Local Mattermost",
                               "-surfaceMode", "shell=native",
                               "-surfaceMode", "auth=native",
                               "-surfaceMode", "sidebar=native",
                               "-surfaceMode", "composer=native",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
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
        XCTAssertTrue(element(app, "nativeShell").waitForExistence(timeout: 40),
                      "signing in must reach the shell:\n\(app.debugDescription)")
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The rail row's accessibility value ("12 unread threads, 11 mentions"), or nil when the row is
    /// absent or says nothing. The badge itself is decoration inside the row: a `Button` merges the
    /// children of its label into one accessibility element, so the sentence lives on the row's value
    /// (the same split `ChannelSidebarRow` uses for its mention badges).
    private func railValue(_ app: XCUIApplication) -> String? {
        let row = element(app, "nativeSidebarAllThreads")
        guard row.exists else { return nil }
        guard let value = row.value as? String, !value.isEmpty else { return nil }
        return value
    }

    /// Scroll the channel list until the rail's Threads row is drawn, then return it.
    ///
    /// A `List` only builds the rows it is showing, so "the row exists in the view's body" and "the row
    /// is in the accessibility tree" are different claims (measured: the test saw only the rows above
    /// its scroll position). The row sits above the categories now, so the search starts by scrolling
    /// back up; the downward sweep keeps the helper honest if the order ever changes.
    @discardableResult
    private func revealThreadsRow(_ app: XCUIApplication) -> XCUIElement {
        let row = element(app, "nativeSidebarAllThreads")
        if row.waitForExistence(timeout: 25) { return row }
        let list = app.collectionViews.firstMatch
        guard list.waitForExistence(timeout: 20) else { return row }
        for _ in 0..<6 {
            list.swipeDown(velocity: .fast)
            if row.exists { return row }
        }
        for _ in 0..<20 {
            list.swipeUp(velocity: .fast)
            if row.exists { return row }
        }
        return row
    }

    /// The first whole number in a label ("12 unread threads, 11 mentions" → 12).
    private func firstInteger(in text: String) -> Int? {
        var digits = ""
        for character in text {
            if character.isNumber {
                digits.append(character)
            } else if !digits.isEmpty {
                break
            }
        }
        return Int(digits)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    /// Keep a screenshot in the result bundle (exported to `docs/t4d-shots/` after a run).
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
