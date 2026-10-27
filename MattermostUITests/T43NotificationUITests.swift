// T43 — the native mention input against a **real** Mattermost server.
//
// What these tests are for, and what they are not: the notification banner itself is a system surface
// XCUITest cannot see, so the shell publishes the same facts the banner was built from — which input is
// live, how many socket mentions were delivered or suppressed, and the last mention's post id, channel and
// outcome — in Settings → Mention notifications. That read-out is fed by the same code path that schedules
// the banner, so a green run here means "the socket's mention reached NotificationWorker and produced one
// delivery", not "a label was on screen".
//
//   1. `-notificationPath socket` (the native input, behind the flag): the rail's socket comes up, a mention
//      posted by another account while the app is **foreground on another channel** arrives with no refresh,
//      and the read-out shows exactly one delivery for that post.
//   2. the shipped default (no flag): the input is the web bridge, and the socket path stays silent — the
//      flip is the `-AV` claim, and this test is what keeps the default honest until then.
//   3. dual-render (web app mounted + socket live): T43-R (F2) rewrote this to assert the configuration's
//      **premises** — the page cannot report (`notificationPath.pageBridge` = "not installed"), so the
//      socket being gated out *before* the policy and the page never being refused are what "one source"
//      means here. The rule itself is unit-tested at the real `handleNotifyMention` call site.
//   4. the same mount with `-desktopBridge`: the page *can* report, and the read-out says so — otherwise
//      the "accepted=0" in (3) could be a constant rather than a measured fact.
//
// Fixture: `python3 scripts/t43_notification_seed.py` (accounts perfprobe/t43buddy, channels t43-notify and
// t43-muted). Environment as for the other live suites: TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD.

import XCTest

final class T43NotificationUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String?
    private var userID: String?
    private var teamID: String?

    private static let buddyLogin = "t43buddy"
    private static let buddyPassword = "T43-Buddy-Not-A-Real-Secret-1"
    private static let channelName = "t43-notify"
    private static var cachedBuddySession: (server: String, token: String, userID: String)?

    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let raw = environment["MM_AUTH_SERVER"] ?? ""
        loginID = environment["MM_AUTH_LOGIN"] ?? ""
        password = environment["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live mention test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        try ping()
        let session = try authenticate(login: loginID, password: password)
        token = session.token
        userID = session.userID
        teamID = try firstTeamID()
    }

    // MARK: - 1. The native input delivers a live mention (and only one)

    func testASocketMentionReachesTheShellOnce() throws {
        let app = launchApp(nativeInput: true)
        signIn(app)

        // The rail's socket must be up: that is what makes this input authoritative (and what would make
        // the web bridge refuse). Waiting for it here also proves the assertion below cannot be a poller.
        openSettings(app)
        XCTAssertTrue(waitForLabel(app, "notificationPath.mode", equals: "Native socket", timeout: 20),
                      "the launch flag must select the native input:\n\(app.debugDescription)")
        XCTAssertTrue(waitForValue(app, "notificationPath.liveSockets", equals: "1", timeout: 40),
                      "the server's socket must be live for the native input to be authoritative:\n\(app.debugDescription)")
        XCTAssertTrue(waitForValue(app, "notificationPath.webPanes", equals: "0", timeout: 15),
                      "this is the native pane: no web view may be mounted for it:\n\(app.debugDescription)")

        // Another account mentions me while this app is in the foreground, on another channel.
        let mention = try seedMention(marker: "live")
        let targetChannel = try channel()

        XCTAssertTrue(reveal(app, "notificationPath.lastMention").exists,
                      "the read-out must show the mention the socket delivered:\n\(app.debugDescription)")
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            let value = readOut(app, "notificationPath.lastMention")
            if value.contains("post=\(mention.id)") && value.contains("outcome=delivered") { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        let value = readOut(app, "notificationPath.lastMention")
        XCTAssertTrue(value.contains("post=\(mention.id)"),
                      "the delivered mention must be the one the buddy posted, read-out reads '\(value)'")
        XCTAssertTrue(value.contains("channel=\(targetChannel.id)"),
                      "and it must resolve the mention's own channel, read-out reads '\(value)'")
        XCTAssertTrue(value.contains("outcome=delivered"),
                      "the banner must have been scheduled, read-out reads '\(value)'")

        // Exactly one: the counter is incremented once per scheduled banner, and the ring refuses a replay.
        let counters = parseCounters(readOut(app, "notificationPath.socket"))
        XCTAssertEqual(counters["delivered"], 1,
                       "one mention, one delivery — read-out reads '\(readOut(app, "notificationPath.socket"))'")
        XCTAssertEqual(counters["suppressed"], 0,
                       "nothing else in this window should have been suppressed")

        attach(app, "t43-native-mention")
    }

    // MARK: - 2. The shipped default is unchanged and the socket input stays silent

    func testTheDefaultStillUsesTheWebViewInput() throws {
        let app = launchApp(nativeInput: false)
        signIn(app)
        openSettings(app)

        XCTAssertTrue(waitForLabel(app, "notificationPath.mode", equals: "Web view bridge", timeout: 20),
                      "without the flag the shipped input must still be the web view:\n\(app.debugDescription)")

        let mention = try seedMention(marker: "default")
        // Give the socket time to deliver if the gate leaked: it must not.
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            let value = readOut(app, "notificationPath.lastMention")
            XCTAssertFalse(value.contains("post=\(mention.id)"),
                           "in bridge mode the socket input must deliver nothing, read-out reads '\(value)'")
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        let counters = parseCounters(readOut(app, "notificationPath.socket"))
        XCTAssertEqual(counters["delivered"] ?? 0, 0,
                       "the native input must be inert until the flip")
    }

    // MARK: - 3. Dual-render: the webview mounted *and* the native socket live

    /// The card's second acceptance criterion, measured in the configuration this host can actually
    /// mount with both inputs present: the pane host stays on the web app (`app.webViews` non-empty)
    /// while the native socket is live.
    ///
    /// **T43-R (F2) — what this test can and cannot show.** `window.desktop.notifyMention` is installed
    /// only with `-desktopBridge`, which this configuration does not pass (and must not: advertising it
    /// sends the web app down its Electron path, where the channel view never loads — README "What is
    /// not there yet"). So the page **cannot report** here, `accepted` is 0 for that structural reason,
    /// and a passing `accepted <= 1` would have been vacuous — the T43 version asserted exactly that and
    /// proved nothing. This version asserts the premises instead: the page has no shim, the socket was
    /// gated out *before* the policy (0 delivered **and** 0 suppressed), the page was never refused, and
    /// therefore zero banners is what this configuration can produce by construction.
    ///
    /// The one-source rule itself is proven where a page report exists: the unit tests drive the real
    /// `WebViewContainer.Coordinator.handleNotifyMention` (`testAMountedWebPaneSilencesTheSocketAndLetsThePageDeliver`,
    /// `testTheWebViewPathIsRefusedWhileTheSocketIsLive`), and `testThePageBridgeIsInstalledOnlyWhenAsked`
    /// measures the shim's presence the live run depends on.
    func testDualRenderKeepsOneSourceAndNeverRefusesThePage() throws {
        let app = launchWebviewApp()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 60),
                      "the web app must be mounted for this configuration:\n\(app.debugDescription)")

        openSettings(app)
        XCTAssertTrue(waitForLabel(app, "notificationPath.mode", equals: "Native socket", timeout: 20),
                      "the flag still selects the native input:\n\(app.debugDescription)")
        XCTAssertTrue(waitForValue(app, "notificationPath.liveSockets", equals: "1", timeout: 40),
                      "the rail's socket must be live in this configuration:\n\(app.debugDescription)")
        XCTAssertTrue(waitForValue(app, "notificationPath.webPanes", equals: "1", timeout: 20),
                      "and the shell must know the pane is the web app:\n\(app.debugDescription)")
        XCTAssertTrue(waitForLabel(app, "notificationPath.pageBridge", equals: "not installed", timeout: 10),
                      "T43-R F2: this run does not install `window.desktop`, so the page structurally "
                      + "cannot emit notify_mention — every 'accepted=0' below is that fact, not a refusal")

        let mention = try seedMention(marker: "dualrender")
        // Let the socket event land (and, if the page could report, its bridge frame too).
        RunLoop.current.run(until: Date().addingTimeInterval(10))

        let counters = parseCounters(readOut(app, "notificationPath.socket"))
        XCTAssertEqual(counters["delivered"] ?? 0, 0,
                       "with the web app drawing the pane the socket must not deliver — reads "
                       + "'\(readOut(app, "notificationPath.socket"))'")
        XCTAssertEqual(counters["suppressed"] ?? 0, 0,
                       "and it must not record a suppression either: the gate stops it before the policy, "
                       + "so no delivery decision was made for that post in this process")
        XCTAssertFalse(readOut(app, "notificationPath.lastMention").contains("post=\(mention.id)"),
                       "and it must not record a delivery for that post")
        let bridge = parseCounters(readOut(app, "notificationPath.bridge"))
        XCTAssertEqual(bridge["accepted"] ?? 0, 0,
                       "zero accepted is structural in this configuration (the page cannot report — see "
                       + "notificationPath.pageBridge), reads '\(readOut(app, "notificationPath.bridge"))'")
        XCTAssertEqual(bridge["refused"] ?? 0, 0,
                       "the page must never be refused while it is the input: no frame was ever sent — reads "
                       + "'\(readOut(app, "notificationPath.bridge"))'")
        attach(app, "t43-dual-render")
    }

    /// T43-R (F2): the other half of the premise, measured live — with `-desktopBridge` the page really
    /// can report, and the shell says so. Without this, `notificationPath.pageBridge` could be a constant
    /// and the dual-render run above would still pass.
    ///
    /// The shipped configuration does not pass the flag because of the render consequence (README), so
    /// this test only measures the shim's presence + the web pane, not a banner.
    func testThePageBridgeIsInstalledOnlyWhenAsked() throws {
        let app = launchWebviewApp(desktopBridge: true)
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 60),
                      "the pane host must mount with the shim installed:\n\(app.debugDescription)")
        openSettings(app)
        XCTAssertTrue(waitForLabel(app, "notificationPath.pageBridge", equals: "installed", timeout: 20),
                      "with -desktopBridge the page can call window.desktop.notifyMention; the read-out "
                      + "must report that, or the dual-render 'accepted=0' means nothing:\n\(app.debugDescription)")
        XCTAssertTrue(waitForValue(app, "notificationPath.webPanes", equals: "1", timeout: 20),
                      "and it is still a web pane:\n\(app.debugDescription)")
        attach(app, "t43-page-bridge-installed")
    }

    // MARK: - App driving

    private func launchApp(nativeInput: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["-uiTestResetPersistedState",
                         "-uiTestForgetSession", serverURL.absoluteString,
                         "-uiTestSeedServer", serverURL.absoluteString,
                         "-uiTestSeedServerName", "Local Mattermost",
                         "-surfaceMode", "shell=native",
                         "-surfaceMode", "auth=native",
                         "-surfaceMode", "sidebar=native",
                         "-uiTestLogLevel", "error",
                         "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if nativeInput {
            arguments += ["-notificationPath", "socket"]
        }
        app.launchArguments = arguments
        app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"
        app.launch()
        return app
    }

    /// The webview configuration: the pane host stays on the web app (`channelView` unset ⇒ `.web`),
    /// the native input is still selected by the flag. No `shell=native`, so no native rail.
    ///
    /// The session is seeded into the vault (the seam the shell's own tests use) so the app opens
    /// straight into the pane instead of a login form the webview would have to be driven through.
    ///
    /// - Parameter desktopBridge: install `window.desktop` (`-desktopBridge`). Off for the shipped
    ///   configuration, because the web app then takes its Electron path (README); on only for the
    ///   test that measures the shim's presence. T43-R F2.
    private func launchWebviewApp(desktopBridge: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["-uiTestResetPersistedState",
                         "-uiTestForgetSession", serverURL.absoluteString,
                         "-uiTestSeedServer", serverURL.absoluteString,
                         "-uiTestSeedServerName", "Local Mattermost",
                         "-uiTestSeedStoredToken", token ?? "",
                         "-notificationPath", "socket",
                         "-uiTestLogLevel", "error",
                         "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if desktopBridge { arguments += ["-desktopBridge"] }
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

    private func openSettings(_ app: XCUIApplication) {
        let button = app.buttons["settingsToolbarButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 25),
                      "the shell must offer Settings:\n\(app.debugDescription)")
        button.tap()
        XCTAssertTrue(element(app, "settingsView").waitForExistence(timeout: 15),
                      "Settings must open:\n\(app.debugDescription)")
    }

    /// The read-out section is at the bottom of a `Form`; only what is on screen is in the accessibility
    /// tree, so every read scrolls to its row first (down, then back up if it was above).
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

    /// `label` for a value row, `value` for an `accessibilityValue` row: read whichever is there.
    private func readOut(_ app: XCUIApplication, _ identifier: String) -> String {
        let row = reveal(app, identifier)
        guard row.exists else { return "" }
        if let value = row.value as? String, value != "0", !value.isEmpty, value != identifier {
            return value
        }
        return row.label
    }

    private func waitForLabel(_ app: XCUIApplication, _ identifier: String,
                              equals expected: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if readOut(app, identifier) == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return false
    }

    private func waitForValue(_ app: XCUIApplication, _ identifier: String,
                              equals expected: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if readOut(app, identifier) == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return false
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

    // MARK: - Fixture seeding (through the server, as another account)

    private struct Post { let id: String }

    private func stamp() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

    private func channel() throws -> (id: String, displayName: String) {
        let body = try getJSON("/api/v4/teams/\(teamID!)/channels/name/\(Self.channelName)")
            as? [String: Any] ?? [:]
        guard let id = body["id"] as? String else {
            throw XCTSkip("#\(Self.channelName) is missing — run scripts/t43_notification_seed.py")
        }
        return (id: id, displayName: body["display_name"] as? String ?? Self.channelName)
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
    private func seedMention(marker: String) throws -> Post {
        let buddy = try buddySession()
        let body = try sendJSON("POST", "/api/v4/posts",
                                body: ["channel_id": try channel().id,
                                       "message": "T43 UI \(stamp()) \(marker): @\(loginID!) you were named"],
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
        let base = serverURL.appendingPathComponent(path)
        var request = URLRequest(url: base)
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        let (data, response) = try synchronous(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NSError(domain: "T43Oracle", code: status, userInfo: [
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

    // MARK: - Element helpers

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
