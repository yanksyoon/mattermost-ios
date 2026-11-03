// T54 — the in-app mention banner against a **real** Mattermost server, driven through the app itself.
//
// Why live: the card's criteria are statements about what a reader sees — "with the app foreground in
// channel A, another user posts a mention in channel B → a banner appears with the author and the
// channel, tapping lands on that post, and the same mention does not produce a second banner". A stub
// would only prove that this file's fixture agrees with itself, so the mention is posted by a *second
// account* through `POST /posts` while the app is running, exactly as a colleague would.
//
// Fixture: `python3 scripts/t43_notification_seed.py --url http://127.0.0.1:8065` (accounts
// perfprobe/t43buddy, channels `t43-notify` and `t43-muted`). The app is launched with
// `-notificationPath socket` because the native input is what feeds the banner (T43's gate); the mention
// path, the policy and the ledger are then the shipped ones.
//
// What is *not* asserted here, stated honestly: the absence of a **system** notification is not
// observable from XCUITest (the system's banner is outside the app). The evidence for "no duplicate" is
// what the app itself reports — exactly one delivery, `surface=in-app banner`, and the T43 read-out —
// plus the unit double-path test that drives the same mention twice through the real feed and ledger.
//
// Run (local throwaway server; credentials are the throwaway dev account in `scripts/perf_seed.py`):
//
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     python3 scripts/qa-test.py --platform ios --sim "iPhone 16 Pro" \
//       --only-testing MattermostUITests/T54MentionBannerUITests
//
// Every test skips (never fails) when the environment or the fixture is missing.

import XCTest

final class T54MentionBannerUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String?
    private var teamID: String?
    private var onScreenChannel: (id: String, name: String, displayName: String)!
    private var mentionChannel: (id: String, name: String, displayName: String)!

    private static let buddyLogin = "t43buddy"
    private static let buddyPassword = "T43-Buddy-Not-A-Real-Secret-1"
    private static var cachedBuddySession: (server: String, token: String, userID: String)?

    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let raw = environment["MM_AUTH_SERVER"] ?? ""
        loginID = environment["MM_AUTH_LOGIN"] ?? ""
        password = environment["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live banner test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        try ping()
        let session = try authenticate(login: loginID, password: password)
        token = session.token
        teamID = try firstTeamID()
        onScreenChannel = try channel(named: "t43-muted")
        mentionChannel = try channel(named: "t43-notify")
    }

    // MARK: - 1. The card's headline case

    func testAForegroundMentionInAnotherChannelIsABannerThatOpensThePost() throws {
        let app = launchApp(launchArguments(bannerDuration: 60))
        signIn(app)
        openChannel(app, channelID: onScreenChannel.id, name: onScreenChannel.name)

        // A reader typing in channel A. The banner must arrive *around* this draft, not instead of it.
        let input = composerInput(app)
        XCTAssertTrue(input.waitForExistence(timeout: 30),
                      "the composer must mount in the channel pane:\n\(app.debugDescription)")
        input.tap()
        input.typeText("T54 draft")
        XCTAssertTrue(waitUntil(timeout: 10) { (input.value as? String)?.contains("T54 draft") == true },
                      "the draft must be in the composer before the mention arrives, reads "
                      + "'\(String(describing: input.value))'")

        // Another account mentions me — in a *different* channel.
        let mention = try seedMention(in: mentionChannel.id, marker: "banner")

        let banner = element(app, "mentionBanner")
        XCTAssertTrue(banner.waitForExistence(timeout: 45),
                      "a foreground mention in another channel must produce an in-app banner:\n\(app.debugDescription)")
        dismissNotificationPermissionAlertIfPresent()
        let label = banner.label
        XCTAssertTrue(label.contains(mentionChannel.displayName),
                      "the banner must name the channel it came from (\(mentionChannel.displayName)), reads '\(label)'")
        XCTAssertTrue(label.contains("@\(Self.buddyLogin)"),
                      "and the author who named the reader, reads '\(label)'")
        attach(app, "t54-banner-over-channel-a")

        // Focus: the banner is a transient overlay and must not take the keyboard.
        input.typeText(" stays")
        XCTAssertTrue(waitUntil(timeout: 10) { (input.value as? String)?.contains("T54 draft stays") == true },
                      "the banner must not steal the composer's focus — composer reads "
                      + "'\(String(describing: input.value))'")

        // Exactly one banner element: the slot takes one, never a stack.
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "mentionBanner").count, 1,
                       "at most one banner is visible")

        // Tap -> the same funnel a system-notification tap uses: that channel, that post focused.
        banner.tap()
        XCTAssertTrue(element(app, "postFocus.\(mention.id)").waitForExistence(timeout: 45),
                      "tapping the banner must land on the mention's own post (\(mention.id)):\n\(app.debugDescription)")
        XCTAssertTrue(waitUntil(timeout: 20) {
            element(app, "nativeChannelTitle").label.contains(self.mentionChannel.displayName)
        }, "the opened channel must be the mention's channel (\(mentionChannel.displayName)), header reads "
        + "'\(element(app, "nativeChannelTitle").label)'")
        XCTAssertFalse(element(app, "mentionBanner").exists, "the banner goes away when it is used")
        attach(app, "t54-landed-on-the-post")

        // No second banner, and one delivery with the in-app surface — the duplicate path.
        RunLoop.current.run(until: Date().addingTimeInterval(8))
        XCTAssertFalse(element(app, "mentionBanner").exists, "one mention, one banner")

        openSettings(app)
        let last = readOut(app, "notificationPath.lastMention")
        XCTAssertTrue(last.contains("post=\(mention.id)"),
                      "the read-out must name the mention that arrived, reads '\(last)'")
        XCTAssertTrue(last.contains("surface=in-app banner"),
                      "the foreground surface is the banner, not a system notification, reads '\(last)'")
        XCTAssertTrue(last.contains("outcome=delivered"), "and it was delivered, reads '\(last)'")
        let counters = parseCounters(readOut(app, "notificationPath.socket"))
        XCTAssertEqual(counters["delivered"], 1, "exactly one delivery for one mention, reads "
                       + "'\(readOut(app, "notificationPath.socket"))'")
        XCTAssertEqual(counters["suppressed"], 0, "nothing in this window should have been suppressed")
        attach(app, "t54-readout")
    }

    // MARK: - 2. The conversation on screen does not banner

    /// The suppression half, live: the very same kind of mention, in the channel the reader is reading,
    /// produces no banner at all — and the read-out says why.
    func testAMentionInTheChannelOnScreenProducesNoBanner() throws {
        let app = launchApp(launchArguments(bannerDuration: 60))
        signIn(app)
        openChannel(app, channelID: mentionChannel.id, name: mentionChannel.name)

        let mention = try seedMention(in: mentionChannel.id, marker: "onscreen")

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            XCTAssertFalse(element(app, "mentionBanner").exists,
                           "the reader is looking at this channel: no banner may appear")
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }

        openSettings(app)
        let last = readOut(app, "notificationPath.lastMention")
        XCTAssertTrue(last.contains("post=\(mention.id)"), "the read-out must name the mention, reads '\(last)'")
        XCTAssertTrue(last.contains("outcome=you are looking at this channel"),
                      "and say why it was not shown, reads '\(last)'")
        let counters = parseCounters(readOut(app, "notificationPath.socket"))
        XCTAssertEqual(counters["delivered"] ?? 0, 0)
        XCTAssertEqual(counters["suppressed"], 1)
        attach(app, "t54-on-screen-suppressed")
    }

    // MARK: - 3. The banner is time-bounded

    func testTheBannerHidesItselfAfterItsBound() throws {
        let app = launchApp(launchArguments(bannerDuration: 4))
        signIn(app)
        openChannel(app, channelID: onScreenChannel.id, name: onScreenChannel.name)

        _ = try seedMention(in: mentionChannel.id, marker: "timeout")
        let banner = element(app, "mentionBanner")
        XCTAssertTrue(banner.waitForExistence(timeout: 45),
                      "the banner must appear first:\n\(app.debugDescription)")
        dismissNotificationPermissionAlertIfPresent()

        // 4 s bound from its own presentation; 15 s is slack for the simulator's scheduling.
        XCTAssertTrue(waitUntil(timeout: 15) { !self.element(app, "mentionBanner").exists },
                      "an untouched banner must hide itself:\n\(app.debugDescription)")
        attach(app, "t54-auto-dismissed")
    }

    // MARK: - 4. Swipe dismisses it

    func testSwipingTheBannerHidesIt() throws {
        let app = launchApp(launchArguments(bannerDuration: 60))
        signIn(app)
        openChannel(app, channelID: onScreenChannel.id, name: onScreenChannel.name)

        _ = try seedMention(in: mentionChannel.id, marker: "swipe")
        let banner = element(app, "mentionBanner")
        XCTAssertTrue(banner.waitForExistence(timeout: 45),
                      "the banner must appear before it can be swiped:\n\(app.debugDescription)")
        dismissNotificationPermissionAlertIfPresent()
        banner.swipeUp()
        XCTAssertTrue(waitUntil(timeout: 10) { !self.element(app, "mentionBanner").exists },
                      "a swipe on the banner must hide it:\n\(app.debugDescription)")
        attach(app, "t54-swiped-away")
    }

    // MARK: - App driving

    private func launchArguments(bannerDuration: Double) -> [String] {
        ["-uiTestResetPersistedState",
         "-uiTestForgetSession", serverURL.absoluteString,
         "-uiTestSeedServer", serverURL.absoluteString,
         "-uiTestSeedServerName", "Local Mattermost",
         "-surfaceMode", "shell=native",
         "-surfaceMode", "auth=native",
         "-surfaceMode", "sidebar=native",
         "-surfaceMode", "composer=native",
         "-uiTestBannerDuration", String(bannerDuration),
         "-notificationPath", "socket",
         "-uiTestLogLevel", "error",
         "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    }

    private func launchApp(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"
        app.launch()
        return app
    }

    private func signIn(_ app: XCUIApplication) {
        let field = app.textFields["loginIDField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20),
                      "the native sign-in must mount against \(serverURL.absoluteString):\n\(app.debugDescription)")
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

    /// Open a channel the way a person does: the quick switcher (the fixture sidebar carries every channel
    /// the server has, and the row's position is not the test's business).
    private func openChannel(_ app: XCUIApplication, channelID: String, name: String) {
        let quick = element(app, "channelSidebar.quickSwitcher")
        if !quick.waitForExistence(timeout: 20) {
            // Regular layout (iPad): the sidebar is its own `NavigationSplitView` column and iOS opens the
            // split view collapsed in portrait, so the list is not in the tree until it is shown. This is
            // the layout's own affordance — the same channel list, reached the way a reader reaches it.
            let toggle = app.navigationBars.buttons["ToggleSidebar"]
            if toggle.waitForExistence(timeout: 10) { toggle.tap() }
        }
        XCTAssertTrue(quick.waitForExistence(timeout: 40),
                      "the sidebar must offer the quick switcher:\n\(app.debugDescription)")
        quick.tap()
        let field = element(app, "channelSidebar.quickSwitcher.field")
        XCTAssertTrue(field.waitForExistence(timeout: 15),
                      "the quick switcher must mount:\n\(app.debugDescription)")
        field.tap()
        field.typeText(name)
        let result = element(app, "channelSidebar.quickSwitcher.result.\(channelID)")
        XCTAssertTrue(result.waitForExistence(timeout: 25),
                      "the quick switcher must find channel \(channelID):\n\(app.debugDescription)")
        result.tap()
        XCTAssertTrue(element(app, "channelPostList").waitForExistence(timeout: 45),
                      "the channel pane must mount:\n\(app.debugDescription)")
    }

    private func composerInput(_ app: XCUIApplication) -> XCUIElement {
        let identifier = "channelComposer.input"
        let textView = app.textViews[identifier]
        if textView.waitForExistence(timeout: 10) { return textView }
        return element(app, identifier)
    }

    /// A fresh install asks for notification permission on its first mention (T8's rule, kept by the banner
    /// path — the ask is fired *after* the banner is on screen). The alert belongs to SpringBoard, sits above
    /// the app and is modal: the banner is there, but a tap would land on the alert. Answer it (either answer
    /// is fine — this suite is about the banner, not about the permission) and carry on.
    private func dismissNotificationPermissionAlertIfPresent() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "Don’t Allow", "Don't Allow"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 2) {
                button.tap()
                return
            }
        }
    }

    private func openSettings(_ app: XCUIApplication) {
        let button = app.buttons["settingsToolbarButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 25),
                      "the shell must offer Settings:\n\(app.debugDescription)")
        button.tap()
        XCTAssertTrue(element(app, "settingsView").waitForExistence(timeout: 15),
                      "Settings must open:\n\(app.debugDescription)")
    }

    /// The read-out section is at the bottom of a `Form`; only what is on screen is in the accessibility
    /// tree, so every read scrolls to its row first.
    @discardableResult
    private func reveal(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        let target = element(app, identifier)
        if target.exists { return target }
        for _ in 0..<6 {
            app.swipeUp()
            if target.exists { return target }
        }
        for _ in 0..<10 {
            app.swipeDown()
            if target.exists { return target }
        }
        return target
    }

    private func readOut(_ app: XCUIApplication, _ identifier: String) -> String {
        let row = reveal(app, identifier)
        guard row.exists else { return "" }
        if let value = row.value as? String, value != "0", !value.isEmpty, value != identifier {
            return value
        }
        return row.label
    }

    private func parseCounters(_ value: String) -> [String: Int] {
        var result: [String: Int] = [:]
        for pair in value.split(separator: " ") {
            let parts = pair.split(separator: "=")
            guard parts.count == 2, let number = Int(parts[1]) else { continue }
            result[String(parts[0])] = number
        }
        return result
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Fixture (through the server, as another account)

    private struct Post { let id: String }

    private func stamp() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

    private func channel(named name: String) throws -> (id: String, name: String, displayName: String) {
        let body = try getJSON("/api/v4/teams/\(teamID!)/channels/name/\(name)")
            as? [String: Any] ?? [:]
        guard let id = body["id"] as? String else {
            throw XCTSkip("#\(name) is missing — run scripts/t43_notification_seed.py")
        }
        return (id: id, name: name, displayName: body["display_name"] as? String ?? name)
    }

    private func buddySession() throws -> (token: String, userID: String) {
        if let cached = Self.cachedBuddySession, cached.server == serverURL.absoluteString {
            return (cached.token, cached.userID)
        }
        let session = try authenticate(login: Self.buddyLogin, password: Self.buddyPassword)
        Self.cachedBuddySession = (server: serverURL.absoluteString, token: session.token,
                                   userID: session.userID)
        return session
    }

    /// A fresh mention of the signed-in account, posted by the buddy — the only way to produce one.
    private func seedMention(in channelID: String, marker: String) throws -> Post {
        let buddy = try buddySession()
        let body = try sendJSON("POST", "/api/v4/posts",
                                body: ["channel_id": channelID,
                                       "message": "T54 UI \(stamp()) \(marker): @\(loginID!) you were named"],
                                as: buddy.token) as? [String: Any] ?? [:]
        guard let id = body["id"] as? String else {
            throw XCTSkip("the fixture channel did not accept a post")
        }
        return Post(id: id)
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
            throw XCTSkip("the fixture account has no team — run scripts/t43_notification_seed.py")
        }
        return id
    }

    private func getJSON(_ path: String) throws -> Any {
        var request = URLRequest(url: serverURL.appendingPathComponent(path))
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        let (data, response) = try synchronous(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NSError(domain: "T54Oracle", code: status, userInfo: [
                NSLocalizedDescriptionKey: "GET \(path) -> HTTP \(status)"])
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func sendJSON(_ method: String, _ path: String, body: Any?,
                          as session: String? = nil) throws -> Any {
        var request = URLRequest(url: serverURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(session ?? token!)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try synchronous(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw XCTSkip("\(method) \(path) answered \(status) — the fixture is not in the state this test needs")
        }
        guard !data.isEmpty, let json = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return json
    }

    /// The REST oracle's own session — **no cookie store** (a stale `MMAUTHTOKEN` cookie makes the server
    /// answer `session_expired` before it looks at the request; see T40's note).
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
