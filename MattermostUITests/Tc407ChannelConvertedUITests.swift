// t_c407645a — "a conversion on another client leaves the sidebar and pane stale".
//
// Why this is a **live** test and not a UI-only one: the card's scenario needs a *second client*. The
// test signs the app in, opens a group message, and then converts that conversation from its own REST
// session — the app is never touched again. Everything asserted after the POST therefore came over the
// socket: if the frame is not routed, nothing on screen can change, and the test fails.
//
// Measured first (`scripts/tc407_channel_converted_probe.py`, Case A): on the pinned 9.11.19 server a
// group-message conversion publishes **`channel_updated`** carrying the whole converted record. That is
// the frame this test's oracle watches even though the card names `channel_converted`; the probe's Case
// B (a privacy conversion) is the shape that sends `channel_converted`, and both are routed by the
// client (unit: `MattermostTests/Tc407ChannelConvertedTests.swift`).
//
// What it asserts:
//   1. the pane title becomes the converted channel's display name with no interaction;
//   2. the sidebar row's label (its `entry.displayName`, the row's accessibility label) becomes that
//      same name — the card's stale-sidebar symptom;
//   3. the server really holds a private channel with the conversation's id (the oracle, so a title that
//      changed for some other reason cannot pass).
//
// Run (same fixture and credentials as T088):
//
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     python3 scripts/qa-test.py --platform ios --sim "iPhone 16 Pro" \
//       --only-testing MattermostUITests/Tc407ChannelConvertedUITests
//
// The test skips — never fails — when the environment or the server is missing, like every live test
// here.

import XCTest

final class Tc407ChannelConvertedUITests: XCTestCase {

    /// One admin session per test process: the server rate-limits logins by IP.
    private static var cachedSession: (server: String, token: String, userID: String)? = nil

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var userID: String!
    private var teamID: String!
    /// The group message this test created; archived in `tearDown`.
    private var conversationID: String?
    private var searchTerm = "t088"

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live channel-converted test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        do {
            try ping()
        } catch {
            throw XCTSkip("Live channel-converted test: \(raw) is unreachable (\(error.localizedDescription))")
        }
        if let cached = Self.cachedSession, cached.server == raw {
            token = cached.token
            userID = cached.userID
        } else {
            let session = try authenticate(login: loginID, password: password)
            token = session.token
            userID = session.userID
            Self.cachedSession = (server: raw, token: session.token, userID: session.userID)
        }
        teamID = try firstTeamID()
    }

    override func tearDownWithError() throws {
        // Archive whatever this test created — a run must not grow the fixture.
        if let id = conversationID {
            _ = try? sendJSON("DELETE", "/api/v4/channels/\(id)", body: nil)
            conversationID = nil
        }
    }

    func testAConversionOnAnotherClientUpdatesTheOpenPaneAndTheSidebarRow() throws {
        let conversation = try makeGroupMessage()
        conversationID = conversation.id

        let stamp = Int(Date().timeIntervalSince1970)
        let displayName = "T088 Remote \(stamp)"
        let urlName = "t088-remote-\(stamp)"

        let app = launchApp()

        // 2. The list holds this conversation **as a group message** before anything happens — and it is
        //    read from the list, not from the chat: the quick switcher's result label is
        //    `entry.displayName` from the same `ChannelListViewModel` the rows are drawn from (the DM
        //    category itself sits far below the fold in this fixture account — hundreds of conversations —
        //    and is not in the accessibility tree without a scroll, so the switcher is how to read it).
        let labelBefore = try switcherResultLabel(app, channelID: conversation.id)
        XCTAssertFalse(labelBefore.contains(displayName),
                       "the list cannot already name a channel that does not exist: \(labelBefore)")

        openConversation(app, channelID: conversation.id)
        let title = element(app, "nativeChannelTitle")
        XCTAssertTrue(title.waitForExistence(timeout: 25),
                      "the pane must be open before the conversion:\n\(app.debugDescription)")
        let titleBefore = title.label

        // 3. **Another client** converts it. The body is the one the app itself sends
        //    (`ConvertGMToChannelDraft.body`): the route reads `team_id` from the **body** — a query
        //    parameter alone answers 403 `api.context.permissions.app_error` (measured, see
        //    `scripts/tc407_convert_403_probe.py`). From here on the test touches nothing in the app:
        //    every change below is the socket's.
        let converted = try sendJSON("POST",
                                     "/api/v4/channels/\(conversation.id)/convert_to_channel",
                                     body: ["channel_id": conversation.id,
                                            "team_id": teamID!,
                                            "display_name": displayName,
                                            "name": urlName]) as? [String: Any]
        XCTAssertEqual(converted?["type"] as? String, "P",
                       "the server must hold a private channel: \(String(describing: converted))")
        XCTAssertEqual(converted?["id"] as? String, conversation.id,
                       "the conversion keeps the conversation's id")

        // 4. The open pane's header follows the frame — no relaunch, no tap, no navigation.
        XCTAssertTrue(waitForLabel(title, containing: displayName, timeout: 30),
                      "the open pane must follow a conversion performed on another client;"
                      + " title was \"\(titleBefore)\", is now \"\(title.label)\"")

        // 5. The sidebar's row follows the same frame: its label was the member-derived group title and
        //    must now be the converted channel's name. Nothing in the app is tapped between the POST and
        //    this read except opening the list/switcher, which is how the label is observable.
        XCTAssertTrue(waitForSwitcherLabel(app, channelID: conversation.id,
                                           containing: displayName, timeout: 30),
                      "the sidebar must stop showing the stale group-message title;"
                      + " it was \"\(labelBefore)\"")

        attach(app, "tc407-converted-remotely")
    }

    // MARK: - Reading the list's own labels

    /// Open the quick switcher and return the result row's label for `channelID`.
    private func switcherResultLabel(_ app: XCUIApplication, channelID: String) throws -> String {
        _ = ShellSettle.revealChannelList(app)
        let switcher = app.buttons["channelSidebar.quickSwitcher"]
        guard switcher.waitForExistence(timeout: 20), switcher.isHittable else {
            throw XCTSkip("the fixture's sidebar did not draw its quick switcher")
        }
        switcher.tap()
        let field = app.textFields["channelSidebar.quickSwitcher.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 15),
                      "the quick switcher must mount:\n\(app.debugDescription)")
        field.tap()
        field.typeText(searchTerm)
        let result = element(app, "channelSidebar.quickSwitcher.result.\(channelID)")
        XCTAssertTrue(result.waitForExistence(timeout: 20),
                      "the switcher must find the conversation \(channelID) by \"\(searchTerm)\":"
                      + "\n\(app.debugDescription)")
        let label = result.label
        closeSwitcher(app)
        return label
    }

    /// Poll the switcher's result label until it contains `text` (re-opening the switcher each pass: the
    /// list can change while the panel is closed, and a closed panel is not in the accessibility tree).
    private func waitForSwitcherLabel(_ app: XCUIApplication, channelID: String,
                                      containing text: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        while Date() < deadline {
            if let label = try? switcherResultLabel(app, channelID: channelID) {
                last = label
                if label.contains(text) { return true }
            }
            usleep(500_000)
        }
        XCTContext.runActivity(named: "last switcher label: \(last)") { _ in }
        return false
    }

    private func closeSwitcher(_ app: XCUIApplication) {
        let clear = app.buttons["Clear search"]
        if clear.exists, clear.isHittable {
            clear.tap()
        }
        let cancel = app.buttons["Cancel"]
        if cancel.exists, cancel.isHittable {
            cancel.tap()
            return
        }
        // No cancel affordance in the narrow title: swipe the sheet away.
        app.swipeDown()
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
                               "-surfaceMode", "channelInfo=native",
                               "-uiTestLogLevel", "error",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"
        app.launch()
        signIn(app)
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
        XCTAssertTrue(ShellSettle.waitForSignedIn(app),
                      "the shell must mount:\n\(app.debugDescription)")
    }

    /// Open the conversation. A group message lives in the **Direct messages** group, which this fixture
    /// account has hundreds of rows in — so the quick switcher (it searches every row) is tried first,
    /// and the group header is the fallback.
    private func openConversation(_ app: XCUIApplication, channelID: String) {
        _ = ShellSettle.revealChannelList(app)

        let switcher = app.buttons["channelSidebar.quickSwitcher"]
        if switcher.waitForExistence(timeout: 15), switcher.isHittable {
            switcher.tap()
            let field = app.textFields["channelSidebar.quickSwitcher.field"]
            if field.waitForExistence(timeout: 10) {
                field.tap()
                field.typeText(searchTerm)
                let result = element(app, "channelSidebar.quickSwitcher.result.\(channelID)")
                if result.waitForExistence(timeout: 10) {
                    result.tap()
                }
            }
        }

        if !element(app, "nativeChannelTitle").waitForExistence(timeout: 15) {
            let group = element(app, "channelSidebar.category.direct_messages")
            if group.waitForExistence(timeout: 15) {
                group.tap()
            }
            let row = sidebarRow(app, channelID: channelID)
            XCTAssertTrue(row.waitForExistence(timeout: 20),
                          "the sidebar must list the group message:\n\(app.debugDescription)")
            row.tap()
        }

        XCTAssertTrue(element(app, "nativeChannelTitle").waitForExistence(timeout: 30),
                      "the channel pane must mount:\n\(app.debugDescription)")
    }

    private func sidebarRow(_ app: XCUIApplication, channelID: String) -> XCUIElement {
        element(app, "channelSidebar.channel.\(channelID)")
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Poll an element's label — a socket-driven update never lands in the same frame as the write.
    private func waitForLabel(_ element: XCUIElement, containing text: String,
                              timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.label.contains(text) { return true }
            usleep(250_000)
        }
        return element.exists && element.label.contains(text)
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Fixture and oracle

    private struct Conversation {
        let id: String
    }

    /// A group message of me + two other active team members, with one post in it.
    ///
    /// `POST /channels/group` takes a **bare array** of user ids (measured: a `{user_ids: …}` object
    /// answers `api.payload.parse.error`). A group message needs three accounts.
    private func makeGroupMessage() throws -> Conversation {
        let people = try getJSON("/api/v4/users?in_team=\(teamID!)&per_page=100") as? [[String: Any]] ?? []
        let others = people.filter {
            ($0["delete_at"] as? Int ?? 0) == 0 && ($0["id"] as? String) != userID
        }
        let candidates = others.compactMap { $0["id"] as? String }
        guard candidates.count >= 2 else {
            throw XCTSkip("the fixture team needs two other active accounts for a group message")
        }
        let members = [userID!] + candidates.prefix(2)
        searchTerm = others.first.map { ($0["username"] as? String) ?? "t088" } ?? "t088"

        let created = try sendJSON("POST", "/api/v4/channels/group", body: members) as? [String: Any]
        guard let id = created?["id"] as? String else {
            throw XCTSkip("the fixture refused to create a group message: \(String(describing: created))")
        }
        _ = try? sendJSON("POST", "/api/v4/posts",
                          body: ["channel_id": id, "message": "tc407 fixture \(Date())"])
        return Conversation(id: id)
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
        let halves = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let base = serverURL.appendingPathComponent(String(halves[0]))
        guard halves.count == 2, !halves[1].isEmpty,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return base
        }
        components.percentEncodedQuery = String(halves[1])
        return components.url ?? base
    }

    private func request(_ method: String, _ path: String, body: Any? = nil) -> URLRequest {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private func getJSON(_ path: String) throws -> Any {
        let (data, response) = try synchronous(request("GET", path))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NSError(domain: "Tc407Oracle", code: status, userInfo: [
                NSLocalizedDescriptionKey:
                    "GET \(path) -> HTTP \(status) \(String(decoding: data.prefix(200), as: UTF8.self))"])
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    @discardableResult
    private func sendJSON(_ method: String, _ path: String, body: Any?) throws -> Any {
        let (data, response) = try synchronous(request(method, path, body: body))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NSError(domain: "Tc407Oracle", code: status, userInfo: [
                NSLocalizedDescriptionKey:
                    "\(method) \(path) -> HTTP \(status) \(String(decoding: data.prefix(200), as: UTF8.self))"])
        }
        return (try? JSONSerialization.jsonObject(with: data)) ?? [:]
    }

    private func synchronous(_ request: URLRequest) throws -> (Data, URLResponse) {
        let box = Tc407ResponseBox()
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            box.data = data
            box.response = response
            box.error = error
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 30)
        if let error = box.error { throw error }
        guard let data = box.data, let response = box.response else {
            throw NSError(domain: "Tc407Oracle", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "no answer from \(request.url?.absoluteString ?? "?")"])
        }
        return (data, response)
    }
}

/// Mutable box so the completion closure can write to it without a captured `var`.
private final class Tc407ResponseBox: @unchecked Sendable {
    var data: Data?
    var response: URLResponse?
    var error: Error?
}
