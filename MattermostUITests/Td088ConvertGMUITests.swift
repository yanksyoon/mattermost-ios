// t_d088f075 — "convert a group message to a private channel" against a **real** Mattermost server.
//
// Why live: the card's acceptance asks for a conversion to be performed and for the server to hold the
// result ("asserting the new channel exists on the server with the requested name"). A UI-only assertion
// can pass while nothing was sent (the T40-AV F1/F2 failure mode), so the oracle here is the server's own
// `GET /teams/{tid}/channels/name/{name}` and `GET /channels/{id}`.
//
// What the test does:
//   1. creates a group message with two other fixture accounts (`POST /channels/group`, measured: a bare
//      array of user ids) and posts one message into it, so the row sorts to the head of Direct Messages;
//   2. signs in through the native sign-in, opens the conversation, opens channel info;
//   3. asserts the conversion row is offered (the gate: type `G`, a member, server ≥ 9.1);
//   4. taps it, types a name, submits;
//   5. asserts the server now holds a **private** channel with the derived URL name and the **same id**,
//      and that the app landed on it.
//
// Run (same fixture and credentials as T40/T52):
//
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     python3 scripts/qa-test.py --platform ios --sim <sim> \
//       --only-testing MattermostUITests/Td088ConvertGMUITests
//
// The test skips — never fails — when the environment or the server is missing, like every live test
// here. Nothing is fabricated: a skipped test is reported as skipped.

import XCTest

final class Td088ConvertGMUITests: XCTestCase {

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
    /// The display name typed into the form, and the URL name the app must derive from it.
    private var typedName = ""
    private var expectedURLName = ""
    /// What to type into the quick switcher — a chosen member's username, which is part of the group's
    /// generated title.
    private var searchTerm = "t088"

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live convert-GM test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        do {
            try ping()
        } catch {
            // An overloaded host or a stopped container is "no live environment", not a product failure.
            throw XCTSkip("Live convert-GM test: \(raw) is unreachable (\(error.localizedDescription))")
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

    func testConvertingAGroupMessageCreatesAPrivateChannelWithTheRequestedName() throws {
        let conversation = try makeGroupMessage()
        conversationID = conversation.id

        // The name is typed into the form and the URL name is what the app derives — the same rule the
        // create form uses, so this assertion is about the app's derivation being the one it sends.
        let stamp = Int(Date().timeIntervalSince1970)
        typedName = "T088 Live \(stamp)"
        expectedURLName = "t088-live-\(stamp)"

        let app = launchApp()
        openConversation(app, channelID: conversation.id)
        openChannelInfo(app)

        // 3. The gate: a group message on this server offers the row.
        let row = element(app, "channelInfo.action.convertToChannel")
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "a group message must offer the conversion row:\n\(app.debugDescription)")
        row.tap()

        XCTAssertTrue(element(app, "convertGM.screen").waitForExistence(timeout: 25),
                      "the conversion screen must mount:\n\(app.debugDescription)")
        XCTAssertTrue(element(app, "convertGM.warning.header").exists,
                      "the warning is drawn above the form:\n\(app.debugDescription)")

        let nameField = app.textFields["convertGM.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10),
                      "the name field must exist:\n\(app.debugDescription)")
        nameField.tap()
        nameField.typeText(typedName)

        let submit = app.buttons["convertGM.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 10))
        XCTAssertTrue(submit.isEnabled,
                      "a named draft must enable the button; a disabled one is the F2 failure mode")
        // The keyboard covers the submit row after typing; a tap on a covered element lands on the
        // keyboard and nothing is sent (observed: the sheet stayed up and no request was recorded).
        dismissKeyboard(app)
        XCTAssertTrue(submit.isHittable, "the submit row must be reachable after the keyboard closes")
        submit.tap()

        // 4/5. The server holds the conversion: the name resolves to a **private** channel whose id is
        // the conversation's own (measured: the id survives the conversion).
        let converted = try waitForChannel(named: expectedURLName)
        XCTAssertEqual(converted["type"] as? String, "P",
                       "the server must hold a private channel: \(converted)")
        XCTAssertEqual(converted["id"] as? String, conversation.id,
                       "the conversion keeps the conversation's id: \(converted)")
        XCTAssertEqual(converted["display_name"] as? String, typedName,
                       "the server must hold the name that was typed")

        // The app landed on the converted conversation: the info sheet is gone and the pane is the
        // channel, titled with its display name (or its URL name on a narrow title).
        let sheet = element(app, "channelInfo.sheet")
        XCTAssertTrue(waitUntilGone(sheet, timeout: 20),
                      "the info sheet must close after a conversion:\n\(app.debugDescription)")
        let title = element(app, "nativeChannelTitle")
        XCTAssertTrue(title.waitForExistence(timeout: 25),
                      "the app must land on the converted conversation:\n\(app.debugDescription)")
        // The header is refetched after navigation (the id is unchanged, so the pane has to be told the
        // channel itself changed) — poll the label instead of reading it the instant the old one is
        // still on screen.
        XCTAssertTrue(waitForLabel(title, containing: typedName, timeout: 20)
                      || title.label.contains(expectedURLName),
                      "the pane title must name the converted channel, got: \(title.label)")

        attach(app, "td088-converted")
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
    /// account has hundreds of rows in — so the quick switcher is tried first (it searches every row,
    /// including DMs), and the group header is the fallback.
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
            // The row is the newest activity in Direct messages, so it is the group's first row.
            let group = element(app, "channelSidebar.category.direct_messages")
            if group.waitForExistence(timeout: 15) {
                group.tap()
            }
            let row = element(app, "channelSidebar.channel.\(channelID)")
            XCTAssertTrue(row.waitForExistence(timeout: 20),
                          "the sidebar must list the group message:\n\(app.debugDescription)")
            row.tap()
        }

        XCTAssertTrue(element(app, "nativeChannelTitle").waitForExistence(timeout: 30),
                      "the channel pane must mount:\n\(app.debugDescription)")
    }

    private func openChannelInfo(_ app: XCUIApplication) {
        let button = app.buttons["nativeChannelInfoButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 20),
                      "the header's info button must exist:\n\(app.debugDescription)")
        button.tap()
        XCTAssertTrue(element(app, "channelInfo.sheet").waitForExistence(timeout: 20),
                      "the channel-info sheet must mount:\n\(app.debugDescription)")
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Close the software keyboard so a row beneath it can be tapped.
    private func dismissKeyboard(_ app: XCUIApplication) {
        guard app.keyboards.count > 0 else { return }
        let returnKey = app.keyboards.buttons["return"].firstMatch
        if returnKey.exists, returnKey.isHittable {
            returnKey.tap()
        } else {
            element(app, "convertGM.warning.header").tap()
        }
        let deadline = Date().addingTimeInterval(5)
        while app.keyboards.count > 0, Date() < deadline {
            usleep(200_000)
        }
    }

    /// Poll an element's label — an asynchronously refetched header does not change in the same frame as
    /// the navigation that caused it.
    private func waitForLabel(_ element: XCUIElement, containing text: String,
                              timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.label.contains(text) { return true }
            usleep(250_000)
        }
        return element.exists && element.label.contains(text)
    }

    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while element.exists, Date() < deadline {
            usleep(200_000)
        }
        return !element.exists
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
        // The quick switcher searches the sidebar's own labels (a group message is titled by its
        // members), so the search term is the first chosen member's username — "t088" appears in the
        // fixture post, not in any channel title.
        searchTerm = others.first.map { ($0["username"] as? String) ?? "t088" } ?? "t088"

        let created = try sendJSON("POST", "/api/v4/channels/group", body: members) as? [String: Any]
        guard let id = created?["id"] as? String else {
            throw XCTSkip("the fixture refused to create a group message: \(String(describing: created))")
        }
        _ = try? sendJSON("POST", "/api/v4/posts",
                          body: ["channel_id": id, "message": "t088 fixture \(Date())"])
        return Conversation(id: id)
    }

    /// Poll `GET /teams/{tid}/channels/name/{name}` until the server answers it.
    ///
    /// The conversion is a POST the UI test cannot observe directly; the server's own by-name route is
    /// the same resolution a deep link uses, so a 200 here means the channel really exists under that
    /// name on that team.
    private func waitForChannel(named name: String) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(30)
        var lastStatus = 0
        while Date() < deadline {
            let (data, response) = try synchronous(request("GET", "/api/v4/teams/\(teamID!)/channels/name/\(name)"))
            lastStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            if lastStatus == 200,
               let channel = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                return channel
            }
            usleep(500_000)
        }
        XCTFail("the server never answered GET /teams/\(teamID!)/channels/name/\(name)"
                + " (last status \(lastStatus)) — the conversion did not land")
        throw XCTSkip("unreachable")
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
            throw NSError(domain: "Td088Oracle", code: status, userInfo: [
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
            throw NSError(domain: "Td088Oracle", code: status, userInfo: [
                NSLocalizedDescriptionKey:
                    "\(method) \(path) -> HTTP \(status) \(String(decoding: data.prefix(200), as: UTF8.self))"])
        }
        return (try? JSONSerialization.jsonObject(with: data)) ?? [:]
    }

    private func synchronous(_ request: URLRequest) throws -> (Data, URLResponse) {
        let box = ResponseBox()
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
            throw NSError(domain: "Td088Oracle", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "no answer from \(request.url?.absoluteString ?? "?")"])
        }
        return (data, response)
    }
}

/// Mutable box so the completion closure can write to it without a captured `var`.
private final class ResponseBox: @unchecked Sendable {
    var data: Data?
    var response: URLResponse?
    var error: Error?
}
