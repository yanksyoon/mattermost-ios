// t_8f9f5449 C3 — the live tests for the two write rows: **Call** and **Add to a channel**.
//
// Why live: both rows are routes into server-side writes (a direct channel + a real Calls join; a
// channel membership), and both assertions are made against the **server's** answer rather than the
// app's own word:
//
//   * Call — after `Leave`, `GET /plugins/com.mattermost.calls/calls/{dm}/active` must answer
//     `{"active":false}`;
//   * Add to a channel — after `addToChannel.submit`, `GET /channels/{id}/members/{buddy}` must
//     answer 200 for a channel the buddy was provably **not** in before.
//
// Run (same fixture accounts as T41/T429/T44d):
//
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     python3 scripts/qa-test.py --platform ios --sim "name=iPhone 17 Pro" \
//       --only-testing MattermostUITests/T5449ProfileActionsUITests
//
// **Run this suite alone on a quiet host.** `testCallOpensTheDirectChannelAndJoins` starts a real
// calls session, and T44d §4.2 records the measured hazard: an `AURemoteIO::Initialize` abort under
// host load, which kills the runner rather than the test.
//
// The third row of the card's acceptance list — "the Call row is absent while a call is live" — is
// **unit-pinned**, not live-tapped: starting a second concurrent call to prove the row disappears is
// exactly the fragile flow the card allows to be pinned in `T5449ProfileActionMatrixTests`
// (`testTheCallRowIsAbsentWhileACallIsLiveElsewhere`). `docs/t_8f9f5449-c3-build-note.md` §4 says so.
//
// Skips — never fails — when the environment, the server or the fixture accounts are missing.

import XCTest

final class T5449ProfileActionsUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var myUserID: String!
    private var buddyID: String!
    private var buddyToken: String!
    private var teamID: String!
    private var channelID: String!
    private var postID: String!
    private var dmChannelID: String!

    /// T429's channel: its two accounts already exist and its own fixture posts are cheap. **Never**
    /// `#t41-profile` — posting there pushed T41's seed post out of the pane's window (T429 §5.1).
    private let channelName = "t429-tap"
    /// This card's own throwaway channel, created on first run and never reused for anything else.
    private let pickerChannelName = "t5449-add"

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
                          "Live profile-actions test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
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

        channelID = try ensureChannel(teamID: teamID!, name: channelName,
                                      displayName: "T429 tap fixture")

        // A fresh post by somebody else, so the row is the newest one in the pane: a separator from
        // this account first, or two posts by the same author inside the grouping window would draw
        // the buddy's message as a grouped row with no header (no avatar, no name).
        _ = try sendJSON("POST", "/api/v4/posts",
                         body: ["channel_id": channelID,
                                "message": "t_5449 separator \(UUID().uuidString.prefix(8))"],
                         as: token) as? [String: Any] ?? [:]

        let buddy = try authenticate(login: buddyLogin, password: buddyPassword)
        buddyID = buddy.userID
        buddyToken = buddy.token
        try ensureMember(userID: buddyID, channelID: channelID)
        let marker = "t_5449 tap fixture \(UUID().uuidString.prefix(8))"
        let created = try sendJSON("POST", "/api/v4/posts",
                                   body: ["channel_id": channelID, "message": marker],
                                   as: buddyToken) as? [String: Any] ?? [:]
        guard let createdID = created["id"] as? String else {
            throw XCTSkip("the buddy's fixture post was not accepted by the server")
        }
        postID = createdID
        try XCTSkipUnless(try isNewestPost(createdID), "another client posted after the fixture post")

        // The direct conversation exists before the Call row is tapped, so the assertion after
        // `Leave` can name the channel the call ran in. `POST /channels/direct` is idempotent.
        let direct = try sendJSON("POST", "/api/v4/channels/direct",
                                  body: [myUserID, buddyID], as: token) as? [String: Any] ?? [:]
        guard let directID = direct["id"] as? String else {
            throw XCTSkip("the direct conversation could not be created")
        }
        dmChannelID = directID
    }

    // MARK: - 1. Call

    /// `profile.call` on somebody else's profile: the sheet goes, **their DM** opens, the call
    /// surface mounts from the pane (never from the sheet), and leaving ends the call on the server.
    func testCallOpensTheDirectChannelAndJoins() throws {
        try endAnyCall(in: dmChannelID)

        let app = launchApp()
        openChannel(app)
        openTheAuthorsProfile(app, affordance: "post.\(postID!).avatar")

        let callRow = element(app, "profile.call")
        XCTAssertTrue(callRow.waitForExistence(timeout: 30),
                      "another human on a Calls-enabled server must be offered the Call row:\n"
                      + "\(app.debugDescription)")
        attach(app, "01-call-row")

        callRow.tap()
        XCTAssertTrue(waitUntil(timeout: 30) { !element(app, "profileSheet").exists },
                      "tapping Call must dismiss the profile sheet — the call surface is never "
                      + "presented from inside it:\n\(app.debugDescription)")

        XCTAssertTrue(element(app, "callsSurface").waitForExistence(timeout: 60),
                      "the pane's Calls entry must join the DM's call:\n\(app.debugDescription)")
        XCTAssertFalse(element(app, "profileSheet").exists, "and the sheet must stay dismissed")
        attach(app, "02-in-call")

        // The server's own answer: a call exists in the **direct** channel.
        XCTAssertTrue(try waitForServerActiveCall(dmChannelID, timeout: 30),
                      "`GET …/calls/\(dmChannelID!)/active` must answer active — the DM the profile "
                      + "opened, not the channel the profile was opened from")

        // The surface mounts while the join is still in flight (`joining`/`connecting` draw no Leave
        // control), so wait for the control rather than tapping the instant `callsSurface` exists —
        // measured as `Failed to tap "calls.leaveButton": No matches found` 0.2 s after the surface
        // appeared, with the server already answering `active` (`build/logs/t5449-c3-r3-ui-final.log`).
        let leave = element(app, "calls.leaveButton")
        XCTAssertTrue(leave.waitForExistence(timeout: 60),
                      "the joined call must draw its Leave control:\n\(app.debugDescription)")
        leave.tap()
        XCTAssertTrue(waitUntil(timeout: 30) { !element(app, "callsSurface").exists },
                      "leaving must dismiss the call surface:\n\(app.debugDescription)")
        XCTAssertTrue(try waitForServerActiveCall(dmChannelID, timeout: 30, expected: false),
                      "the profile's Call row created a real call: leaving it must end it on the server")
        attach(app, "03-after-leave")
    }

    // MARK: - 2. Add to a channel

    /// `profile.addToChannel` → picker → the throwaway channel → `.submit`: the **server** must then
    /// say the buddy is a member, for a channel it provably was not in before.
    func testAddToChannelAddsTheAuthorToTheChosenChannel() throws {
        let pickerChannel = try ensureChannel(teamID: teamID, name: pickerChannelName,
                                              displayName: "T5449 picker fixture")
        // The precondition the assertion rests on: the buddy is not in it.
        try removeMemberIfPresent(userID: buddyID, channelID: pickerChannel)

        let app = launchApp()
        openChannel(app)
        openTheAuthorsProfile(app, affordance: "post.\(postID!).avatar")

        let addRow = element(app, "profile.addToChannel")
        XCTAssertTrue(addRow.waitForExistence(timeout: 30),
                      "a team member I administer channels in must be offered Add to a channel:\n"
                      + "\(app.debugDescription)")
        attach(app, "04-add-row")
        addRow.tap()

        XCTAssertTrue(element(app, "addToChannel.picker").waitForExistence(timeout: 30),
                      "the row pushes the team-scoped picker:\n\(app.debugDescription)")

        // Narrow the list with the picker's own search field, so the row is on screen and the field
        // is exercised — the same way a person finds a channel among dozens.
        let search = element(app, "addToChannel.search")
        XCTAssertTrue(search.waitForExistence(timeout: 20), "the picker offers a search field")
        search.tap()
        search.typeText("T5449 picker fixture")

        let row = element(app, "addToChannel.row.\(pickerChannel)")
        XCTAssertTrue(row.waitForExistence(timeout: 30),
                      "the throwaway channel must be offered — I created it, so I administer it:\n"
                      + "\(app.debugDescription)")
        row.tap()

        let submit = element(app, "addToChannel.submit")
        XCTAssertTrue(submit.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil(timeout: 20) { submit.isEnabled },
                      "Add enables once the server confirms the account is not a member:\n"
                      + "\(app.debugDescription)")
        XCTAssertFalse(element(app, "addToChannel.alreadyMember").exists,
                       "the account was removed from this channel in setUp")
        attach(app, "05-picker-ready")

        submit.tap()

        // The server's own answer — not the UI's word.
        var status = 0
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            status = try statusCode("GET", "/api/v4/channels/\(pickerChannel)/members/\(buddyID!)")
            if status == 200 { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertEqual(status, 200,
                       "`GET /channels/\(pickerChannel)/members/\(buddyID!)` must answer 200 after Add")
        attach(app, "06-after-add")

        // And the picker's own row says so (the optimistic insert is what the reader sees).
        XCTAssertTrue(waitUntil(timeout: 20) { (row.value as? String) == "Member" },
                      "the row must show the membership the server accepted — saw "
                      + "\(String(describing: row.value))")
    }

    // MARK: - App driving

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        // No `-surfaceMode calls=…`: `.calls` is native by default since T44d-AV, and no
        // `-surfaceMode profile=…`: the sheet is not gated (T429's lesson — the flag hid the defect).
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

    /// Open `#t429-tap` through the quick switcher (the sidebar is far longer than one screen).
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

    /// Tap the fixture post's avatar and wait for that author's profile sheet.
    private func openTheAuthorsProfile(_ app: XCUIApplication, affordance: String) {
        let target = element(app, affordance)
        XCTAssertTrue(target.waitForExistence(timeout: 60),
                      "the author must be an affordance in the native pane:\n\(app.debugDescription)")
        target.tap()
        XCTAssertTrue(element(app, "profile.username").waitForExistence(timeout: 30),
                      "the profile sheet must mount:\n\(app.debugDescription)")
        XCTAssertEqual(element(app, "profile.username").label, "@\(buddyLogin)",
                       "the sheet must be about the fixture author, not somebody else")
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

    /// A channel by name on the team, created on first run and rejoined by name afterwards.
    private func ensureChannel(teamID: String, name: String, displayName: String) throws -> String {
        if let existing = try? getJSON("/api/v4/teams/\(teamID)/channels/name/\(name)") as? [String: Any],
           let id = existing["id"] as? String {
            return id
        }
        let created = try sendJSON("POST", "/api/v4/channels",
                                   body: ["team_id": teamID, "name": name,
                                          "display_name": displayName, "type": "O"],
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

    private func removeMemberIfPresent(userID: String, channelID: String) throws {
        guard (try? getJSON("/api/v4/channels/\(channelID)/members/\(userID)")) != nil else { return }
        _ = try sendJSON("DELETE", "/api/v4/channels/\(channelID)/members/\(userID)", body: nil, as: token)
    }

    private func isNewestPost(_ id: String) throws -> Bool {
        let page = try getJSON("/api/v4/channels/\(channelID!)/posts?per_page=1") as? [String: Any] ?? [:]
        return (page["order"] as? [String] ?? []).first == id
    }

    private func activeCall(channelID: String) throws -> Bool {
        let path = "/plugins/com.mattermost.calls/calls/\(channelID)/active"
        let body = try getJSON(path) as? [String: Any] ?? [:]
        return body["active"] as? Bool ?? false
    }

    private func waitForServerActiveCall(_ channelID: String, timeout: TimeInterval,
                                         expected: Bool = true) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? activeCall(channelID: channelID)) == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return (try? activeCall(channelID: channelID)) == expected
    }

    private func endAnyCall(in channelID: String) throws {
        guard (try? activeCall(channelID: channelID)) == true else { return }
        // Leaving the last participant ends the call; the app is not running yet, so the plugin's own
        // REST route is not available to a plain member — a second join/leave is not needed here
        // because the call can only be this fixture's own leftover.
        throw XCTSkip("a call is already live in the direct channel — run the suite on a quiet host")
    }

    private func statusCode(_ method: String, _ path: String) throws -> Int {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = method
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        let (_, response) = try synchronous(request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
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
