import XCTest

/// T51 (S26) — the global drafts list against a **real** Mattermost server, with the draft's
/// durability proved by relaunching the app, not by reading the UI back to itself.
///
/// Why live: the list's rows are **local** (the `draft` table in the per-server SQLite file), so the
/// only oracle that can say "this draft is really stored" is a **new process** reading the same file.
/// The channel, the composer, the sign-in and the channel labels all come from the live server. What
/// these tests assert:
///
///   1. a draft typed in channel A is found in the drafts list after leaving the channel, and tapping
///      its row opens that channel's composer with the text;
///   2. deleting the row removes it, and it is still gone after a relaunch (the delete was a store
///      delete, not a redraw);
///   3. a draft survives a relaunch and is reachable from the list alone — the defect this card
///      closes, in one sentence.
///
/// Scheduling (S40) has **no live half on this fixture**: every scheduled-post route answers 404
/// `api.context.404.app_error` (measured, `docs/t51-build-note.md` §6), so this build ships no
/// scheduling request and the follow-up card owns that half.
///
/// Run (credentials in `scripts/perf_seed.py`; the test creates its own channel if missing):
///
///     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
///     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
///     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
///     python3 scripts/qa-test.py --platform ios --sim "name=iPhone 17 Pro,OS=26.5" \
///       --only-testing MattermostUITests/T51GlobalDraftsUITests
///
/// Each test skips (never fails) when the environment or the fixture is missing.
final class T51GlobalDraftsUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var teamID: String!
    private var channelID: String!

    /// A channel of its own, so a draft left by another suite cannot be mistaken for this one's.
    private let channelName = "t51-drafts"

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live drafts test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        try ping()
        let session = try authenticate(login: loginID, password: password)
        token = session.token
        teamID = try ensureTeam().id
        channelID = try ensureChannel(named: channelName, in: teamID)
    }

    // MARK: - 1. Found, opened, deleted

    func testADraftIsFoundInTheListOpenedInItsChannelAndDeleted() throws {
        let draft = "t51 draft \(Int(Date().timeIntervalSince1970)) — never sent"
        let app = launch(reset: true)
        openTeamAndChannel(app)
        typeDraft(draft, in: app)

        // Leave the channel the way a person does, then find the draft without reopening it.
        showSidebar(app)
        openDrafts(app)
        let row = element(app, "globalDrafts.row.\(channelID!)")
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "a draft typed in #\(channelName) must be listed:\n\(app.debugDescription)")
        attach(app, "t51-01-draft-listed")
        let snippet = element(app, "globalDrafts.row.\(channelID!).snippet")
        XCTAssertTrue(snippet.waitForExistence(timeout: 5))
        XCTAssertTrue(snippet.label.contains(draft),
                      "the row must show the draft's own words, was \(snippet.label)")

        // Tap the row: the sheet closes and the channel opens with the draft in its composer.
        row.tap()
        let input = composerInput(app)
        XCTAssertTrue(element(app, "channelPostList").waitForExistence(timeout: 40),
                      "a draft row must open its channel:\n\(app.debugDescription)")
        XCTAssertTrue(waitUntil(timeout: 30) { (input.value as? String) == draft },
                      "the composer must hold the draft's text, was \((input.value as? String) ?? "")")
        attach(app, "t51-02-composer-restored")

        // Delete it from the list.
        showSidebar(app)
        openDrafts(app)
        let delete = element(app, "globalDrafts.row.\(channelID!).delete")
        XCTAssertTrue(delete.waitForExistence(timeout: 20),
                      "the row must offer Delete:\n\(app.debugDescription)")
        delete.tap()
        XCTAssertTrue(waitUntil(timeout: 20) {
            !self.element(app, "globalDrafts.row.\(self.channelID!)").exists
        }, "the row must leave the list once the store deleted it:\n\(app.debugDescription)")
        attach(app, "t51-03-row-deleted")
        element(app, "globalDrafts.close").tap()

        // …and it stays gone in a new process: the delete reached the store, not just the screen.
        app.terminate()
        let relaunched = launch(reset: false)
        showSidebar(relaunched)
        pickTeam(relaunched)
        openDrafts(relaunched)
        XCTAssertFalse(element(relaunched, "globalDrafts.row.\(channelID!)").exists,
                       "a deleted draft must not come back from disk:\n\(relaunched.debugDescription)")
        attach(relaunched, "t51-04-still-gone-after-relaunch")
    }

    // MARK: - 2. Reachable after a relaunch, from the list alone

    func testADraftSurvivesARelaunchAndIsReachableFromTheList() throws {
        let draft = "t51 relaunch \(Int(Date().timeIntervalSince1970)) — never sent"
        let app = launch(reset: true)
        openTeamAndChannel(app)
        typeDraft(draft, in: app)

        // Kill the app. The next launch has no reset flag, so it reuses the same server row (and
        // therefore the same per-server draft database) and the same session.
        showSidebar(app)
        app.terminate()
        let relaunched = launch(reset: false)

        showSidebar(relaunched)
        pickTeam(relaunched)
        openDrafts(relaunched)
        let row = element(relaunched, "globalDrafts.row.\(channelID!)")
        XCTAssertTrue(row.waitForExistence(timeout: 25),
                      "a draft must survive a relaunch and be listed:\n\(relaunched.debugDescription)")
        let snippet = element(relaunched, "globalDrafts.row.\(channelID!).snippet")
        XCTAssertTrue(snippet.waitForExistence(timeout: 5))
        XCTAssertTrue(snippet.label.contains(draft),
                      "the listed draft must be the one typed before the relaunch, was \(snippet.label)")
        attach(relaunched, "t51-05-listed-after-relaunch")

        // Opening it lands on a **fresh** composer (this process never opened the channel), so the
        // text can only have come from the store.
        row.tap()
        let input = composerInput(relaunched)
        XCTAssertTrue(element(relaunched, "channelPostList").waitForExistence(timeout: 40),
                      "the row must open its channel:\n\(relaunched.debugDescription)")
        XCTAssertTrue(waitUntil(timeout: 30) { (input.value as? String) == draft },
                      "a fresh composer must restore from the store, was \((input.value as? String) ?? "")")
        attach(relaunched, "t51-06-restored-after-relaunch")

        // Leave the fixture clean for the next run.
        showSidebar(relaunched)
        openDrafts(relaunched)
        element(relaunched, "globalDrafts.row.\(channelID!).delete").tap()
    }

    // MARK: - Launch / navigation

    private func launch(reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["-surfaceMode", "shell=native",
                         "-surfaceMode", "auth=native",
                         "-surfaceMode", "sidebar=native",
                         "-surfaceMode", "composer=native",
                         "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if reset {
            arguments += ["-uiTestResetPersistedState",
                          "-uiTestForgetSession", serverURL.absoluteString,
                          "-uiTestSeedServer", serverURL.absoluteString,
                          "-uiTestSeedServerName", "Local Mattermost"]
        }
        app.launchArguments = arguments
        app.launch()
        if reset {
            signIn(app)
        } else {
            // A relaunch may restore the last channel (a push) or the channel list; ShellSettle
            // answers for both.
            ShellSettle.waitForSignedIn(app)
        }
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

    private func openTeamAndChannel(_ app: XCUIApplication) {
        showSidebar(app)
        pickTeam(app)
        openViaQuickSwitcher(app)
    }

    /// Return to the channel sidebar. On a phone the channel view is pushed over the tabs, so Back
    /// is the only way to it (T35's helper, same reasoning).
    private func showSidebar(_ app: XCUIApplication) {
        if element(app, "channelSidebar.quickSwitcher").waitForExistence(timeout: 3) { return }
        let back = app.navigationBars.buttons["Back"]
        XCTAssertTrue(back.waitForExistence(timeout: 25),
                      "a pushed screen must offer Back:\n\(app.debugDescription)")
        back.tap()
        XCTAssertTrue(element(app, "channelSidebar.quickSwitcher").waitForExistence(timeout: 30),
                      "Back must land on the channel sidebar:\n\(app.debugDescription)")
    }

    private func pickTeam(_ app: XCUIApplication) {
        let rail = element(app, "teamSidebar.team.\(teamID!)")
        guard rail.waitForExistence(timeout: 20) else { return }
        rail.tap()
        XCTAssertTrue(element(app, "channelSidebar.quickSwitcher").waitForExistence(timeout: 30),
                      "the team's sidebar must mount:\n\(app.debugDescription)")
    }

    private func openViaQuickSwitcher(_ app: XCUIApplication) {
        let opener = element(app, "channelSidebar.quickSwitcher")
        XCTAssertTrue(opener.waitForExistence(timeout: 20),
                      "the sidebar must offer the quick switcher:\n\(app.debugDescription)")
        opener.tap()
        let field = app.textFields["channelSidebar.quickSwitcher.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(channelName)
        let result = element(app, "channelSidebar.quickSwitcher.result.\(channelID!)")
        XCTAssertTrue(result.waitForExistence(timeout: 20),
                      "the quick switcher must find #\(channelName):\n\(app.debugDescription)")
        result.tap()
        XCTAssertTrue(element(app, "channelPostList").waitForExistence(timeout: 40),
                      "the channel must mount:\n\(app.debugDescription)")
    }

    private func openDrafts(_ app: XCUIApplication) {
        let row = element(app, "channelSidebar.drafts")
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "the sidebar must offer Drafts:\n\(app.debugDescription)")
        row.tap()
        XCTAssertTrue(element(app, "globalDrafts").waitForExistence(timeout: 20),
                      "the drafts sheet must open:\n\(app.debugDescription)")
    }

    private func typeDraft(_ text: String, in app: XCUIApplication) {
        let input = composerInput(app)
        XCTAssertTrue(input.waitForExistence(timeout: 30),
                      "the channel composer must mount:\n\(app.debugDescription)")
        input.tap()
        // A fresh per-server draft database (the reset launch seeds a new server UUID) means the
        // composer should be empty; assert it so a leftover draft can never make this test lie.
        XCTAssertEqual((input.value as? String) ?? "", "", "the composer must start empty")
        input.typeText(text)
        XCTAssertTrue(waitUntil(timeout: 20) { (self.composerInput(app).value as? String) == text },
                      "the composer must hold the typed draft")
    }

    private func composerInput(_ app: XCUIApplication) -> XCUIElement {
        let identifier = "channelComposer.input"
        let textView = app.textViews[identifier]
        if textView.waitForExistence(timeout: 10) { return textView }
        return element(app, identifier)
    }

    // MARK: - Fixture (the test is its own API client)

    private struct Team { let id: String; let name: String }

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
              let token = http.value(forHTTPHeaderField: "Token"),
              let user = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = user["id"] as? String else {
            throw XCTSkip("could not sign in as \(login) on the live server")
        }
        return (token, id)
    }

    /// The fixture's `perf` team, or the account's first team, or a team this test creates.
    private func ensureTeam() throws -> Team {
        let rows = try getJSON("/api/v4/users/me/teams") as? [[String: Any]] ?? []
        let teams = rows.compactMap { row -> Team? in
            guard let id = row["id"] as? String, let name = row["name"] as? String else { return nil }
            return Team(id: id, name: name)
        }
        if let perf = teams.first(where: { $0.name == "perf" }) { return perf }
        if let first = teams.first { return first }
        let created = try sendJSON("POST", "/api/v4/teams",
                                   body: ["name": "t51", "display_name": "T51", "type": "O"])
        guard let id = created["id"] as? String else {
            throw XCTSkip("the fixture account has no team and cannot create one")
        }
        return Team(id: id, name: "t51")
    }

    private func ensureChannel(named name: String, in team: String) throws -> String {
        if let row = try? getJSON("/api/v4/teams/\(team)/channels/name/\(name)") as? [String: Any],
           let id = row["id"] as? String {
            return id
        }
        let created = try sendJSON("POST", "/api/v4/channels",
                                   body: ["team_id": team, "name": name,
                                          "display_name": "T51 Drafts", "type": "O"])
        guard let id = created["id"] as? String else {
            throw XCTSkip("could not create #\(name) on the fixture")
        }
        return id
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
        let (data, _) = try synchronous(request)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func sendJSON(_ method: String, _ path: String,
                          body: [String: Any]) throws -> [String: Any] {
        var request = URLRequest(url: serverURL.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try synchronous(request)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func synchronous(_ request: URLRequest) throws -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Data, URLResponse)?
        var failure: Error?
        URLSession.shared.dataTask(with: request) { data, response, error in
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
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
