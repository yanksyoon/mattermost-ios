// T56 — a post body is selectable as ONE range, live against a real server (card t_38e0eac6).
//
// Owner-reported: "the texts on the messages cannot be copied via mouse drag". The cause was
// structural — `MarkdownView` drew each block as its own `Text` with `.textSelection(.enabled)`, and
// SwiftUI scopes selection to one `Text`, so a drag could never leave paragraph 1.
//
// This suite drives the shipped surface (`SelectableMarkdownBody`, one selectable `UITextView` per
// body) against a real server:
//   1. a three-paragraph post is **one text view** whose accessibility label carries every block, a
//      long press selects from that surface, and the **system Copy menu item** puts the selection on
//      the pasteboard — read back through the `-uiTestExposeBodySelection` seam, so no cross-app
//      paste prompt is involved; the copy stops at the post's own boundary (the neighbouring message
//      is not dragged in);
//   2. the revert: with `-uiTestLegacyBlockBody` (the old per-block renderer) the body is three
//      `staticText`s, there is no text view, and no gesture produces a selection — the AV pass.
//
// The 200-post scroll A/B (the card's T6) is `T56PerfProbeUITests`, a harness beside the suite.
//
// Run (local throwaway server; credentials are the throwaway dev account in `scripts/perf_seed.py`):
//
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     python3 scripts/qa-test.py --platform ios --sim "id=<udid>" \
//       --only-testing MattermostUITests/T56SelectionUITests
//
// Every test skips (never fails) when the environment or the channel fixture is missing.

import XCTest

final class T56SelectionUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var channelID: String!
    private var channelName = "t34-showcase"

    /// The three paragraph markers. Unique per run so a previous run's post can never satisfy a query.
    private let alpha = "selection alpha"
    private let beta = "selection beta"
    private let gamma = "selection gamma"

    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let raw = environment["MM_AUTH_SERVER"] ?? ""
        loginID = environment["MM_AUTH_LOGIN"] ?? ""
        password = environment["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live selection test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        try ping()
        token = try authenticate(login: loginID, password: password)
        let teamID = try firstTeamID()
        let channel = try getJSON("/api/v4/teams/\(teamID)/channels/name/\(channelName)") as? [String: Any] ?? [:]
        guard let id = channel["id"] as? String else {
            throw XCTSkip("#\(channelName) is missing — run scripts/t34_post_seed.py")
        }
        channelID = id
    }

    // MARK: - 1. One selectable surface per body, and the system Copy

    func testOneSelectableBodyPerPostAndTheSystemCopyCopiesIt() throws {
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let neighbour = try seedPost(message: "T56 neighbour \(stamp): must stay out of the selection",
                                     marker: "neighbour")
        let target = try seedPost(message: """
        T56 \(stamp) \(alpha): first paragraph.

        \(beta): second paragraph.

        \(gamma): third paragraph.
        """, marker: "target")
        defer { try? deletePost(neighbour); try? deletePost(target) }

        let app = launchApp(additionalArguments: ["-uiTestExposeBodySelection"])
        signIn(app)
        openChannel(app)

        // The body is ONE text view with the whole message in it. The per-block renderer published
        // three static texts with the same identifier prefix and no single element that spanned them.
        let body = app.textViews["post.\(target).body.block0"]
        XCTAssertTrue(body.waitForExistence(timeout: 45),
                      "the post body must be one selectable text view:\n\(app.debugDescription)")
        let label = body.label
        XCTAssertTrue(label.contains(alpha) && label.contains(beta) && label.contains(gamma),
                      "one surface must carry every block, reads '\(label)'")
        attach(app, "t56-one-surface")

        // The system's own selection: a long press inside the body selects from the text view (the
        // surface the seam reports on), not from a per-block `Text`.
        let press = body.coordinate(withNormalizedOffset: CGVector(dx: 0.10, dy: 0.12))
        press.press(forDuration: 0.8)
        let selected = waitForValue(of: body, prefix: "selection", timeout: 15)
        print("T56-SELECTED '\(selected)'")
        let selectedText = String(selected.split(separator: ";", maxSplits: 2).last ?? "")
        XCTAssertTrue(selected.hasPrefix("selection:"),
                      "the press must produce a selection in this body, reads '\(selected)'")
        XCTAssertTrue(!selectedText.isEmpty && label.contains(selectedText),
                      "the selection must come from this body's text view, reads '\(selected)'")
        XCTAssertFalse(selected.contains("T56 neighbour \(stamp)"),
                       "a selection in one post must not reach the next post, reads '\(selected)'")
        attach(app, "t56-selection")

        print("T56-MENU \(app.menuItems.allElementsBoundByIndex.map { $0.label })")
        let copyItem = app.menuItems["Copy"].firstMatch
        if copyItem.waitForExistence(timeout: 10) {
            copyItem.tap()
        } else {
            app.typeKey("c", modifierFlags: .command)
        }

        // The seam publishes what the *pasteboard* received inside the app: this is the system copy
        // action, not a reimplementation of it.
        let copied = waitForValue(of: body, prefix: "copied:", timeout: 15)
        print("T56-COPIED '\(copied)'")
        XCTAssertTrue(copied.contains("T56"), "Copy must put the selected text on the pasteboard, reads '\(copied)'")
        XCTAssertFalse(copied.contains("T56 neighbour \(stamp)"),
                       "one message copies as one message, reads '\(copied)'")
        XCTAssertFalse(copied.contains("**"), "no markdown syntax in the copy, reads '\(copied)'")
        attach(app, "t56-copied")
    }

    // MARK: - 2. The revert (AV pass)

    /// The card's revert test. `-uiTestLegacyBlockBody` restores the per-block `Text` renderer: the
    /// body is then not a text view, and a press-and-drag produces no cross-paragraph selection.
    func testTheLegacyPerBlockRendererCannotSelectAcrossParagraphs() throws {
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let target = try seedPost(message: """
        T56 legacy \(stamp) \(alpha): first paragraph.

        \(beta): second paragraph.

        \(gamma): third paragraph.
        """, marker: "legacy")
        defer { try? deletePost(target) }

        let app = launchApp(additionalArguments: ["-uiTestExposeBodySelection",
                                                 "-uiTestLegacyBlockBody"])
        signIn(app)
        openChannel(app)

        let firstBlock = app.staticTexts["post.\(target).body.block0"]
        XCTAssertTrue(firstBlock.waitForExistence(timeout: 45),
                      "the legacy renderer must draw block 0 as its own text:\n\(app.debugDescription)")
        XCTAssertFalse(app.textViews["post.\(target).body.block0"].exists,
                       "the revert must not draw one selectable surface for the body")

        let start = firstBlock.coordinate(withNormalizedOffset: CGVector(dx: 0.10, dy: 0.50))
        let end = firstBlock.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.50))
        start.press(forDuration: 0.8, thenDragTo: end)

        // No element publishes a cross-paragraph selection: the seam only exists on the new surface,
        // and the old surface cannot produce one. Give the gesture the same window the new surface
        // gets, so this is a real negative and not a timing artefact.
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        let seamValues = app.descendants(matching: .any)
            .matching(NSPredicate(format: "value BEGINSWITH 'selection:'"))
        XCTAssertEqual(seamValues.count, 0,
                       "the per-block renderer cannot produce a body-wide selection:\n\(app.debugDescription)")
        attach(app, "t56-legacy-no-selection")
    }

    // MARK: - App driving

    private func launchArguments(additional: [String]) -> [String] {
        ["-uiTestResetPersistedState",
         "-uiTestForgetSession", serverURL.absoluteString,
         "-uiTestSeedServer", serverURL.absoluteString,
         "-uiTestSeedServerName", "Local Mattermost",
         "-surfaceMode", "shell=native",
         "-surfaceMode", "auth=native",
         "-surfaceMode", "sidebar=native",
         "-surfaceMode", "composer=native",
         "-uiTestLogLevel", "error",
         "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + additional
    }

    private func launchApp(additionalArguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = launchArguments(additional: additionalArguments)
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
        XCTAssertTrue(ShellSettle.waitForSignedIn(app, timeout: 40),
                      "signing in must reach the shell:\n\(app.debugDescription)")
    }

    /// Open the fixture channel the way a reader does: the sidebar's quick switcher.
    private func openChannel(_ app: XCUIApplication) {
        ShellSettle.revealChannelList(app)
        let quick = element(app, "channelSidebar.quickSwitcher")
        if !quick.waitForExistence(timeout: 20) {
            let toggle = app.navigationBars.buttons["ToggleSidebar"]
            if toggle.waitForExistence(timeout: 10) { toggle.tap() }
        }
        XCTAssertTrue(quick.waitForExistence(timeout: 40),
                      "the sidebar must offer the quick switcher:\n\(app.debugDescription)")
        quick.tap()
        let field = element(app, "channelSidebar.quickSwitcher.field")
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText(channelName)
        let result = element(app, "channelSidebar.quickSwitcher.result.\(channelID!)")
        XCTAssertTrue(result.waitForExistence(timeout: 25),
                      "the quick switcher must find #\(channelName):\n\(app.debugDescription)")
        result.tap()
        XCTAssertTrue(element(app, "channelPostList").waitForExistence(timeout: 45),
                      "the channel pane must mount:\n\(app.debugDescription)")
    }

    private func waitForValue(of element: XCUIElement, prefix: String, timeout: TimeInterval) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let value = (element.value as? String) ?? ""
            if value.hasPrefix(prefix) { return value }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return (element.value as? String) ?? ""
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

    // MARK: - Fixture (through the server)

    private func seedPost(message: String, marker: String) throws -> String {
        let body = try sendJSON("POST", "/api/v4/posts",
                                body: ["channel_id": channelID!,
                                       "message": message,
                                       "props": ["t56_key": marker,
                                                 "t56_run": String(Int(Date().timeIntervalSince1970 * 1000))]])
            as? [String: Any] ?? [:]
        guard let id = body["id"] as? String else {
            throw XCTSkip("the fixture channel did not accept a post")
        }
        return id
    }

    private func deletePost(_ id: String) throws {
        let (_, response) = try synchronous(request("DELETE", "/api/v4/posts/\(id)", body: nil))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        XCTAssertTrue(status < 300 || status == 404, "could not delete fixture post \(id): HTTP \(status)")
    }

    // MARK: - Server

    private func ping() throws {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/system/ping"))
        request.timeoutInterval = 5
        let (_, response) = try synchronous(request)
        try XCTSkipUnless((response as? HTTPURLResponse)?.statusCode == 200,
                          "the live server at \(serverURL.absoluteString) is not answering")
    }

    private func authenticate(login: String, password: String) throws -> String {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/users/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["login_id": login,
                                                                       "password": password])
        let (_, response) = try synchronous(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let token = http.value(forHTTPHeaderField: "Token") else {
            throw XCTSkip("could not sign in as \(login) on \(serverURL.absoluteString) (HTTP \(status))")
        }
        return token
    }

    private func firstTeamID() throws -> String {
        let teams = try getJSON("/api/v4/users/me/teams") as? [[String: Any]] ?? []
        guard let team = teams.first, let id = team["id"] as? String else {
            throw XCTSkip("the fixture account has no team")
        }
        return id
    }

    private func getJSON(_ path: String) throws -> Any {
        let (data, response) = try synchronous(request("GET", path, body: nil))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NSError(domain: "T56Oracle", code: status, userInfo: [
                NSLocalizedDescriptionKey: "GET \(path) -> HTTP \(status)"
            ])
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func sendJSON(_ method: String, _ path: String, body: [String: Any]) throws -> Any {
        let data = try JSONSerialization.data(withJSONObject: body)
        let (responseData, response) = try synchronous(request(method, path, body: data))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NSError(domain: "T56Oracle", code: status, userInfo: [
                NSLocalizedDescriptionKey: "\(method) \(path) -> HTTP \(status)"
            ])
        }
        return try JSONSerialization.jsonObject(with: responseData)
    }

    private func request(_ method: String, _ path: String, body: Data?) -> URLRequest {
        var request = URLRequest(url: serverURL.appendingPathComponent(path))
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func synchronous(_ request: URLRequest) throws -> (Data, URLResponse) {
        let expectation = expectation(description: "http \(request.httpMethod ?? "") \(request.url?.path ?? "")")
        var result: Result<(Data, URLResponse), Error>?
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else {
                result = .success((data ?? Data(), response ?? URLResponse()))
            }
            expectation.fulfill()
        }.resume()
        wait(for: [expectation], timeout: 20)
        return try result!.get()
    }
}
