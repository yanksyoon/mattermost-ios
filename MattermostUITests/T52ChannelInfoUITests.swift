// T52 — the channel-info completeness rows against a **real** Mattermost server.
//
// Why live: every acceptance criterion of this half of the card is a statement about a running
// server's data, and the T40-AV suite already proved that a UI-only assertion can pass while no
// request is sent (F1/F2):
//   1. a notification level changed on this screen is **on the wire** — the server's own
//      `GET …/members/{uid}` answers it — and it survives a relaunch (the screen re-reads it);
//   2. the pinned row opens T39's pinned sheet with this channel's pins;
//   3. the files list matches what `POST /teams/{tid}/files/search` answers for this channel.
// The oracle for each is the server, read through its own API with the account the app signs in as.
//
// **Bookmarks (scope 3) are not tested because the fixture refuses them** — measured, not assumed:
// `GET /config` answers `FeatureFlags.ChannelBookmarks = false`, and every `/channels/{id}/bookmarks`
// route answers 404 `api.context.404.app_error` (`scripts/t52_channel_probe.py`). The split the card
// allows is taken: the half is carded separately and the build note carries the measurement.
//
// Run (same fixture and credentials as T40/T51):
//
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     python3 scripts/qa-test.py --platform ios --sim <sim> \
//       --only-testing MattermostUITests/T52ChannelInfoUITests
//
// Each test skips — never fails — when the environment or the server is missing, like every live test
// here. Nothing is fabricated: a skipped test is reported as skipped.

import XCTest

final class T52ChannelInfoUITests: XCTestCase {

    /// One admin session per test process: the server rate-limits logins by IP.
    private static var cachedAdminSession: (server: String, token: String, userID: String)? = nil

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var userID: String!
    private var teamID: String!

    /// The fixture channel these tests read: `t38-files` carries 16 files in live posts
    /// (`scripts/t38_attachment_seed.py`), which is what the files assertion compares against.
    ///
    /// **T52-R1: the suite no longer navigates to it.** Measured: the account is in 358 channels on this
    /// fixture team, so `t38-files` sits far below the sidebar's viewport, and scrolling for it is a
    /// 25-swipe gamble (measured: the row never entered the tree, two tests failed on the scroll, not on
    /// the feature). Each test now **creates** its own channel, posts one file to it and pins that post,
    /// so the row is the newest activity on the team and therefore at the top of the sidebar. The
    /// channel is deleted in `tearDown`, so a run leaves the fixture as it found it.
    /// The name every test channel carries.
    ///
    /// The `0` is deliberate: the sidebar sorts by display name, and this fixture team has 358 channels
    /// whose names start with `t`/`t8`/`town`; a leading digit puts the row the test just created at the
    /// **top** of the list, which is where a screen reader would find it too.
    private let channelNamePrefix = "0-t52-live-"
    /// The channel a test created; deleted in `tearDown`.
    private var createdChannelID: String?

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live channel-info test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
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
        // Delete the channel this test created — a run must not grow the fixture, and its notification
        // preferences would otherwise be the next run's starting state.
        if let id = createdChannelID {
            _ = try? sendJSON("DELETE", "/api/v4/channels/\(id)", body: nil)
            createdChannelID = nil
        }
    }

    // MARK: - 1. Notification preferences reach the server and survive a relaunch

    func testANotificationLevelIsWrittenAndSurvivesARelaunch() throws {
        let fixture = try makeChannelWithFile()
        let channel = fixture.channel
        // Start from a state this test owns: the account default, unmuted.
        _ = try putJSON("/api/v4/channels/\(channel.id)/members/\(userID!)/notify_props",
                        body: ["desktop": "default",
                               "mark_unread": "all",
                               "ignore_channel_mentions": "default"])

        let app = launchApp()
        openChannel(app, channel: channel)
        openChannelInfo(app)
        tapControl(app, "channelInfo.action.notifications")
        XCTAssertTrue(element(app, "channelInfo.notifications.form").waitForExistence(timeout: 20),
                      "the notification screen must mount:\n\(app.debugDescription)")

        // The level rows are the server's vocabulary; pick one that is not the baseline.
        tapControl(app, "channelInfo.notifications.desktop.mention")
        let save = assertButton(app, "channelInfo.notifications.save")
        XCTAssertTrue(save.isEnabled,
                      "changing a level must enable Save; a disabled Save is the F2 failure mode")
        save.tap()
        XCTAssertTrue(element(app, "channelInfo.notifications.saved").waitForExistence(timeout: 15),
                      "the save must answer with the server's read-back:\n\(app.debugDescription)")

        // The server's answer, not the screen's: `mention` stored, every other field untouched.
        let props = try notifyProps(channelID: channel.id)
        XCTAssertEqual(props["desktop"], "mention", "PUT …/notify_props must have carried the level")
        XCTAssertEqual(props["mark_unread"], "all", "only the changed field travels")

        // Relaunch without resetting persisted state: the level must come back from the server. A
        // relaunch restores the last channel as a **pushed pane** (measured T52-R3: `nativeChannelPane`
        // with this channel's title, and no tab bar at all), so the info button is already on screen.
        app.terminate()
        let relaunched = relaunchApp()
        openInfoAfterRelaunch(relaunched, channel: channel)
        let row = element(relaunched, "channelInfo.action.notifications")
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        XCTAssertTrue(row.label.contains("Mentions and keywords"),
                      "the info row must show the server's level after a relaunch, got: \(row.label)")
    }

    // MARK: - 2. The pinned row opens the pinned sheet with this channel's pins

    func testThePinnedRowOpensTheChannelsPinnedSheet() throws {
        let fixture = try makeChannelWithFile()
        let channel = fixture.channel
        // The post this test made is a regular post with one file — pinnable, and it is what the sheet
        // must list (measured: the newest post of a seeded channel is a system message, which the pin
        // route refuses with `api.post.update_post.system_message.app_error`).
        let pinnedPostID = try pin(postID: fixture.postID, in: channel)

        let app = launchApp()
        openChannel(app, channel: channel)
        openChannelInfo(app)
        tapControl(app, "channelInfo.action.pinned")

        XCTAssertTrue(element(app, "pinnedSheet").waitForExistence(timeout: 20),
                      "the pinned row must open T39's sheet:\n\(app.debugDescription)")
        XCTAssertTrue(element(app, "pinnedPosts.row.\(pinnedPostID)").waitForExistence(timeout: 25),
                      "the sheet must list the channel's pinned post \(pinnedPostID):"
                      + "\n\(app.debugDescription)")
        attach(app, "t52-pinned-sheet")
    }

    // MARK: - 3. The files list matches the server's answer

    func testTheFilesListMatchesTheServersFilesForThisChannel() throws {
        let fixture = try makeChannelWithFile()
        let channel = fixture.channel
        let expected = try channelFileIDs(channelName: channel.name)
        XCTAssertEqual(expected, [fixture.fileID],
                       "the oracle must see exactly the file this test posted")

        let app = launchApp()
        openChannel(app, channel: channel)
        openChannelInfo(app)
        tapControl(app, "channelInfo.action.files")

        // The count line is the list's own answer to "how many files"; it must equal the server's.
        // Its label is uppercased by the grouped-list section-header styling (`1 FILE`), so compare
        // case-insensitively — T52-R4 measured the exact-case query finding nothing while the row was
        // right there.
        let count = element(app, "channelInfo.files.count")
        XCTAssertTrue(count.waitForExistence(timeout: 25),
                      "the files list must mount:\n\(app.debugDescription)")
        let expectedCountText = expected.count == 1 ? "1 file" : "\(expected.count) files"
        XCTAssertTrue(count.label.lowercased().contains(expectedCountText),
                      "expected \(expectedCountText) from the server, the list says: \(count.label)")

        // And the first rows are the server's own (the list draws them in the server's order).
        for fileID in expected.prefix(3) {
            XCTAssertTrue(element(app, "channelInfo.files.row.\(fileID)").waitForExistence(timeout: 10),
                          "the list must draw the server's file \(fileID):\n\(app.debugDescription)")
        }
        attach(app, "t52-files-list")
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
        // A launch **with** reset lands on the channel list ("nativeShell"); a launch **without** it
        // restores the last channel and shows the pushed pane, where `nativeShell` is not in the tree at
        // all (ShellSettle.waitForSignedIn's note). Asking for `nativeShell` alone would fail on the very
        // configuration the relaunch test sets up — measured in T52-R2.
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
        // The launch pushes a channel pane over the list (t_295b0a32): `teamSidebar.team.*` and
        // `channelSidebar.*` only exist while the list is on screen, so pop it first
        // (`ShellSettle.revealChannelList`, t_9399c0b4). Idempotent on a launch that already
        // landed on the list.
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

    /// Reach the info sheet on a **relaunch**, where the shell restores the last channel as a pushed
    /// pane. The pane is used when it is the channel this test opened; otherwise the test goes back to
    /// the sidebar and opens the row (the name sorts first on this fixture team).
    private func openInfoAfterRelaunch(_ app: XCUIApplication, channel: Channel) {
        let title = element(app, "nativeChannelTitle")
        if title.waitForExistence(timeout: 15) {
            XCTAssertTrue(title.label.contains("T52 live"),
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
        // Measured (T52-R1): the sidebar's channel list is a `ScrollView` identified
        // `channelSidebar.scroll`, **not** a collection view — `app.collectionViews.firstMatch` matched
        // nothing, so the earlier version of this helper returned without ever scrolling.
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

    private func assertButton(_ app: XCUIApplication, _ identifier: String,
                              timeout: TimeInterval = 10) -> XCUIElement {
        let typed = app.buttons.matching(identifier: identifier).firstMatch
        XCTAssertTrue(typed.waitForExistence(timeout: timeout),
                      "\(identifier) must exist as a button, not just a container:"
                      + "\n\(app.debugDescription)")
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
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])??["id"] as? String
            throw XCTSkip("could not sign in as \(login) on \(serverURL.absoluteString)"
                          + " (HTTP \(status), \(reason ?? "no error id"))")
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
            throw NSError(domain: "T52Oracle", code: status, userInfo: [
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

    /// Create a channel whose sidebar row is at the top of the list, post one file to it, and hand back
    /// the ids the assertions compare against.
    ///
    /// Measured (T52-R1) on this fixture: the account is in 358 channels on the team, so a channel
    /// seeded by an older suite is far below the sidebar's viewport; a channel created now carries the
    /// team's newest activity and is therefore drawn first. `createdChannelID` is deleted in `tearDown`.
    private struct ChannelFixture {
        let channel: Channel
        let postID: String
        let fileID: String
    }

    private func makeChannelWithFile() throws -> ChannelFixture {
        // A name the file-search `in:` term can carry: lowercase, digits and hyphens only.
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        let name = channelNamePrefix + suffix
        let created = try postJSON("/api/v4/channels",
                                   body: ["team_id": teamID!,
                                          "name": name,
                                          "display_name": "0 T52 live " + suffix,
                                          "type": "O"]) as? [String: Any] ?? [:]
        guard let id = created["id"] as? String, created["name"] as? String == name else {
            throw XCTSkip("could not create the live test channel \(name)")
        }
        createdChannelID = id
        // Membership is implicit for the creator, but the notification write needs it to exist; read it
        // so a membership that is missing fails here rather than as an opaque 404 later.
        _ = try getJSON("/api/v4/channels/\(id)/members/\(userID!)")

        let fileID = try uploadTextFile(channelID: id)
        let post = try postJSON("/api/v4/posts",
                                body: ["channel_id": id,
                                       "message": "T52 live fixture post",
                                       "file_ids": [fileID]]) as? [String: Any] ?? [:]
        guard let postID = post["id"] as? String else {
            throw XCTSkip("could not post the live test file into \(name)")
        }
        return ChannelFixture(channel: Channel(id: id, name: name), postID: postID, fileID: fileID)
    }

    /// `POST /files` as `multipart/form-data` — the only shape this server accepts for an upload.
    private func uploadTextFile(channelID: String) throws -> String {
        let boundary = "t52-" + UUID().uuidString
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"files\"; filename=\"t52-live.txt\"\r\n"
                        .data(using: .utf8)!)
        body.append("Content-Type: text/plain\r\n\r\n".data(using: .utf8)!)
        body.append("T52 channel-files fixture.\r\n".data(using: .utf8)!)
        field("channel_id", channelID)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/files"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try synchronous(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let infos = json["file_infos"] as? [[String: Any]],
              let id = infos.first?["id"] as? String else {
            throw XCTSkip("POST /files answered \(status) — the fixture refuses uploads")
        }
        return id
    }

    private func notifyProps(channelID: String) throws -> [String: String] {
        let json = try getJSON("/api/v4/channels/\(channelID)/members/\(userID!)") as? [String: Any]
        let props = json?["notify_props"] as? [String: String] ?? [:]
        XCTAssertFalse(props.isEmpty, "the server must answer the membership's notify_props")
        return props
    }

    /// Pin the post this test made and assert the server's own `pinned` list reports it.
    private func pin(postID: String, in channel: Channel) throws -> String {
        _ = try postJSON("/api/v4/posts/\(postID)/pin", body: nil)
        let pinned = try getJSON("/api/v4/channels/\(channel.id)/pinned") as? [String: Any] ?? [:]
        let pinnedOrder = pinned["order"] as? [String] ?? []
        XCTAssertTrue(pinnedOrder.contains(postID),
                      "the server must report the pin this test made: \(pinnedOrder)")
        return postID
    }

    /// The server's own answer to "this channel's files" — the list the screen draws must equal it.
    private func channelFileIDs(channelName: String) throws -> [String] {
        let answer = try postJSON("/api/v4/teams/\(teamID!)/files/search",
                                  body: ["terms": "in:\(channelName)",
                                         "page": 0,
                                         "per_page": 50]) as? [String: Any] ?? [:]
        let infos = answer["file_infos"] as? [String: Any] ?? [:]
        let order = answer["order"] as? [String] ?? []
        if !order.isEmpty { return order.filter { infos[$0] != nil } }
        // The server's order array is authoritative when present; fall back to the map's keys so a
        // server that omits it still gives this test something to compare (deterministically sorted).
        return infos.keys.sorted()
    }
}
