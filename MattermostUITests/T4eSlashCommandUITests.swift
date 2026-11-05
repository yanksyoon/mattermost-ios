import XCTest

/// T4e — slash commands against a **real** Mattermost server, read back through that server's own API.
///
/// Why live: three of the card's statements are about what a running server does, and none can be
/// proved by a fixture —
///   1. `/` opens the team's command list (the list comes from `GET /commands?team_id=`), with the
///      server's own argument hints in the rows;
///   2. `/help` is **executed**: its answer arrives as an `ephemeral_message` socket row and the
///      composer clears — and, negatively, the literal line `/help` never becomes a post;
///   3. a refused command shows the **server's** sentence ("Command with a trigger of … not found")
///      and keeps the words in the input, without a pending post row.
///
/// Fixture: `scripts/t35_composer_seed.py` (channel `t35-composer` in team `perf`) — the same one the
/// T35 composer suite uses; a slash command needs no extra data.
///
/// Run (local throwaway server, credentials in `scripts/perf_seed.py`):
///
///     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
///     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
///     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
///     python3 scripts/qa-test.py --platform ios --sim "iPhone 16 Pro" \
///       --only-testing MattermostUITests/T4eSlashCommandUITests
///
/// Each test skips (never fails) when the environment or the fixture is missing.
final class T4eSlashCommandUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var userID: String!
    private var teamID: String!

    private let channelName = "t35-composer"

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live slash test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        try ping()
        let session = try authenticate(login: loginID, password: password)
        token = session.token
        userID = session.userID
        let teams = try teamsForMe()
        guard let team = teams.first(where: { $0.name == "perf" }) else {
            throw XCTSkip("team #perf is missing — run scripts/t35_composer_seed.py")
        }
        teamID = team.id
    }

    // MARK: - 1. `/` opens the server's command list

    func testSlashOffersTheServersCommandsWithTheirArgumentHints() throws {
        let channel = try channel(named: channelName, in: teamID)

        // The oracle: the list this test expects to see must be the one the server answers with.
        let commands = try serverCommands()
        let triggers = commands.compactMap { $0["trigger"] as? String }
        guard let invite = commands.first(where: { $0["trigger"] as? String == "invite" }) else {
            throw XCTSkip("this server does not ship the `invite` command; it lists \(triggers.count): \(triggers.sorted())")
        }
        let hint = (invite["auto_complete_hint"] as? String) ?? ""
        XCTAssertFalse(hint.isEmpty, "the fixture server must carry an argument hint for /invite")

        let app = launchAndOpen(channelName: channelName, teamID: teamID)
        let input = composerInput(app)
        input.tap()
        input.typeText("/")

        let list = element(app, "composerSuggestions")
        XCTAssertTrue(list.waitForExistence(timeout: 20),
                      "typing / must open the command list:\n\(app.debugDescription)")
        attach(app, "t4e-01-slash-list")

        // The list is long (this server ships 33 commands) and only the rows in its 200 pt window are
        // drawn, so the test narrows to the command it is about rather than scrolling to it.
        input.typeText("inv")
        let inviteRow = element(app, "composerSuggestion.slash-invite")
        XCTAssertTrue(inviteRow.waitForExistence(timeout: 15),
                      "the server's /invite must be offered:\n\(app.debugDescription)")
        XCTAssertTrue(inviteRow.label.contains(hint),
                      "the row must carry the server's argument hint \(hint); it read \(inviteRow.label)")

        // Completing inserts `/<trigger> ` and closes the list.
        inviteRow.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { ((input.value as? String) ?? "") == "/invite " },
                      "choosing a command must insert /invite + a space, was \((input.value as? String) ?? "")")
        attach(app, "t4e-02-slash-completed")

        // Upstream hides the commands the mobile client has no screen for. `settings` is on this
        // server (asserted above), so typing its exact trigger must produce no rows at all — a row
        // that could only answer "not found" is worse than no row.
        if triggers.contains("settings") {
            input.tap()
            input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12))
            input.typeText("/settings")
            XCTAssertFalse(element(app, "composerSuggestion.slash-settings").waitForExistence(timeout: 5),
                           "a desktop-only command must not be offered on mobile")
            XCTAssertFalse(element(app, "composerSuggestions").exists,
                           "the list must have nothing to draw for a command it hides")
        }

        // Nothing was sent: the channel's newest post is not this command.
        let posts = try channelPosts(channel.id)
        XCTAssertFalse(posts.contains { (($0["message"] as? String) ?? "").hasPrefix("/invite") },
                       "completing a suggestion must not execute it")
    }

    // MARK: - 2. `/help` is executed, its answer is drawn, the composer clears

    func testHelpPostsTheServersAnswerAndClearsTheComposer() throws {
        let channel = try channel(named: channelName, in: teamID)
        // The answer is the server's, so the *oracle* for the text is the server's own response for
        // this channel. (It also pushes an ephemeral row to the app's socket, which the test's
        // predicate is deliberately about: the same sentence must appear in the pane.)
        let answer = try executeCommand("/help", channelID: channel.id)
        XCTAssertEqual(answer.responseType, "ephemeral",
                       "/help answers the caller alone on this server; got \(answer.responseType)")
        let words = answer.text
        // A substring that survives markdown parsing and is long enough to be this answer only.
        let needle = String(words.prefix(48))
        XCTAssertFalse(needle.isEmpty, "the server's /help answer was empty")

        let app = launchAndOpen(channelName: channelName, teamID: teamID)
        let input = composerInput(app)

        // Precondition, stated as an assertion rather than assumed: the answer below arrives over the
        // **socket**, so the socket has to be live for this channel first. A plain post made through
        // the REST API must show up in the pane without any refresh — if it does not, the ephemeral
        // failure that follows would be misread as a slash-command defect.
        let liveProbe = "t4e socket probe \(Int(Date().timeIntervalSince1970))"
        _ = try postJSON("/api/v4/posts", body: ["channel_id": channel.id, "message": liveProbe])
        let probeRow = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", liveProbe)).firstMatch
        XCTAssertTrue(probeRow.waitForExistence(timeout: 30),
                      "the socket must deliver a plain post into this pane before the answer is judged:\n\(app.debugDescription)")

        input.tap()
        input.typeText("/help")

        let helpRow = element(app, "composerSuggestion.slash-help")
        XCTAssertTrue(helpRow.waitForExistence(timeout: 20),
                      "/help must be offered:\n\(app.debugDescription)")

        let send = element(app, "channelComposer.send")
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        send.tap()

        // The answer arrives on the socket as an `ephemeral_message` row and is drawn as markdown.
        // A row appended below the fold is not materialised by the lazy stack, so the pane is nudged
        // to its newest message first — the same gesture the reader would make.
        let answerText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", needle)).firstMatch
        if !answerText.waitForExistence(timeout: 15) {
            revealNewest(app)
        }
        XCTAssertTrue(answerText.waitForExistence(timeout: 15),
                      "the server's answer must be posted into the pane:\n\(app.debugDescription)")
        attach(app, "t4e-03-help-answer")

        XCTAssertTrue(app.staticTexts["Only visible to you"].waitForExistence(timeout: 5),
                      "an ephemeral answer must say that only the reader can see it")

        XCTAssertTrue(waitUntil(timeout: 15) { ((input.value as? String) ?? "") == "" },
                      "a successful command clears the composer, was \((input.value as? String) ?? "")")
        XCTAssertFalse(element(app, "channelComposer.failure").exists,
                       "a successful command must not leave a failure banner")

        // The negative half: the line itself was executed, not posted.
        let posts = try channelPosts(channel.id)
        XCTAssertFalse(posts.contains { (($0["message"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == "/help" },
                       "`/help` must never become a message in the channel")
        attach(app, "t4e-04-help-cleared")
    }

    // MARK: - 3. A refused command keeps the words and shows the server's sentence

    func testAnUnknownCommandShowsTheServersSentenceAndKeepsTheWords() throws {
        let channel = try channel(named: channelName, in: teamID)
        let refusal = try executeCommandRaw("/nosuchcommand", channelID: channel.id)
        try XCTSkipUnless(refusal.status == 404, "this server answers an unknown command differently")
        let sentence = try XCTUnwrap(refusal.message, "the 404 carried no message")
        XCTAssertTrue(sentence.contains("nosuchcommand"),
                      "the sentence must name the trigger; it read \(sentence)")

        let app = launchAndOpen(channelName: channelName, teamID: teamID)
        let input = composerInput(app)
        input.tap()
        input.typeText("/nosuchcommand")

        let send = element(app, "channelComposer.send")
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        send.tap()

        let error = element(app, "channelComposer.error")
        XCTAssertTrue(error.waitForExistence(timeout: 30),
                      "a refused command must show the server's sentence:\n\(app.debugDescription)")
        XCTAssertTrue(error.label.contains("nosuchcommand"),
                      "the banner must carry the server's sentence, it read \(error.label)")
        XCTAssertFalse(error.label.isEmpty)
        XCTAssertTrue(element(app, "channelComposer.retry").exists,
                      "a refused command must offer Retry")
        attach(app, "t4e-05-command-refused")

        // The words survive the refusal, and no optimistic row was ever drawn for it.
        XCTAssertEqual((input.value as? String) ?? "", "/nosuchcommand",
                       "the refused line stays in the input")
        let pending = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'post.pending:'"))
        XCTAssertEqual(pending.count, 0, "a command must not draw a pending post row")

        let posts = try channelPosts(channel.id)
        XCTAssertFalse(posts.contains { (($0["message"] as? String) ?? "").contains("/nosuchcommand") },
                       "a refused command must not be posted as a message")
    }

    // MARK: - Launch

    private func launchAndOpen(channelName: String, teamID: String) -> XCUIApplication {
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
        openChannel(app, channelID: (try? channel(named: channelName, in: teamID).id) ?? "", term: channelName)
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
        ShellSettle.revealChannelList(app)
    }

    /// Open a channel the way a person finds one on a long team: the sidebar's quick switcher. The
    /// sidebar rows themselves are lazily materialised, and the fixture team carries a few hundred
    /// probe channels, so the row for `t35-composer` is often not in the tree at all — the switcher
    /// searches the loaded channel list instead of relying on what happens to be on screen.
    private func openChannel(_ app: XCUIApplication, channelID: String, term: String) {
        let opener = element(app, "channelSidebar.quickSwitcher")
        XCTAssertTrue(opener.waitForExistence(timeout: 30),
                      "the sidebar must offer the quick switcher:\n\(app.debugDescription)")
        opener.tap()
        let field = app.textFields["channelSidebar.quickSwitcher.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 15),
                      "the quick switcher must focus a field:\n\(app.debugDescription)")
        field.tap()
        field.typeText(term)
        let result = element(app, "channelSidebar.quickSwitcher.result.\(channelID)")
        XCTAssertTrue(result.waitForExistence(timeout: 20),
                      "the quick switcher must find #\(term):\n\(app.debugDescription)")
        result.tap()
        XCTAssertTrue(element(app, "channelPostList").waitForExistence(timeout: 40),
                      "the channel pane must mount:\n\(app.debugDescription)")
    }

    private func composerInput(_ app: XCUIApplication) -> XCUIElement {
        let identifier = "channelComposer.input"
        let textView = app.textViews[identifier]
        if textView.waitForExistence(timeout: 30) { return textView }
        return element(app, identifier)
    }

    // MARK: - Server access (the test is its own API client)

    private struct Team {
        let id: String
        let name: String
    }

    private struct Channel {
        let id: String
        let name: String
    }

    private struct Session {
        let token: String
        let userID: String
    }

    private struct CommandAnswer {
        let responseType: String
        let text: String
    }

    private struct CommandRefusal {
        let status: Int
        let message: String?
    }

    /// Reachability only: this runs **before** login, so it must not carry a token.
    private func ping() throws {
        let endpoint = url("/api/v4/system/ping")
        var request = URLRequest(url: endpoint)
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        do {
            let (_, response) = try synchronous(request)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            try XCTSkipUnless(http.statusCode == 200,
                              "\(serverURL.absoluteString) did not answer /system/ping")
        } catch {
            throw XCTSkip("no server at \(serverURL.absoluteString): \(error)")
        }
    }

    private func authenticate(login: String, password: String) throws -> Session {
        var request = URLRequest(url: url("/api/v4/users/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["login_id": login,
                                                                       "password": password])
        let (data, response) = try synchronous(request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        let header = http.value(forHTTPHeaderField: "Token") ?? ""
        guard http.statusCode == 200, !header.isEmpty else {
            throw XCTSkip("login failed with \((http as AnyObject).description)")
        }
        let user = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let id = (user?["id"] as? String) ?? ""
        guard !id.isEmpty else { throw XCTSkip("login returned no user id") }
        return Session(token: header, userID: id)
    }

    private func teamsForMe() throws -> [Team] {
        let json = try getJSON("/api/v4/users/me/teams")
        return (json as? [[String: Any]] ?? []).compactMap { object in
            guard let id = object["id"] as? String, let name = object["name"] as? String else { return nil }
            return Team(id: id, name: name)
        }
    }

    private func channel(named name: String, in team: String) throws -> Channel {
        let json = try getJSON("/api/v4/users/me/teams/\(team)/channels")
        let channels = (json as? [[String: Any]] ?? []).compactMap { object -> Channel? in
            guard let id = object["id"] as? String, let n = object["name"] as? String else { return nil }
            return Channel(id: id, name: n)
        }
        guard let match = channels.first(where: { $0.name == name }) else {
            throw XCTSkip("channel #\(name) is missing — run scripts/t35_composer_seed.py")
        }
        return match
    }

    private func serverCommands() throws -> [[String: Any]] {
        let json = try getJSON("/api/v4/commands?team_id=\(teamID!)")
        return json as? [[String: Any]] ?? []
    }

    private func executeCommand(_ command: String, channelID: String) throws -> CommandAnswer {
        let json = try postJSON("/api/v4/commands/execute",
                                body: ["command": command, "channel_id": channelID,
                                       "team_id": teamID!])
        let object = json as? [String: Any] ?? [:]
        return CommandAnswer(responseType: (object["response_type"] as? String) ?? "",
                             text: (object["text"] as? String) ?? "")
    }

    /// The refusal path: the status **and** the body's sentence, which is what the app must show.
    private func executeCommandRaw(_ command: String, channelID: String) throws -> CommandRefusal {
        var request = authorizedRequest("/api/v4/commands/execute", method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "command": command, "channel_id": channelID, "team_id": teamID!,
        ])
        let (data, response) = try synchronous(request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return CommandRefusal(status: http.statusCode, message: object?["message"] as? String)
    }

    private func channelPosts(_ channelID: String, perPage: Int = 200) throws -> [[String: Any]] {
        let json = try getJSON("/api/v4/channels/\(channelID)/posts?per_page=\(perPage)")
        let page = json as? [String: Any]
        let posts: [String: [String: Any]] = (page?["posts"] as? [String: [String: Any]]) ?? [:]
        let order: [String] = (page?["order"] as? [String]) ?? []
        return order.compactMap { (id: String) -> [String: Any]? in posts[id] }
    }

    /// A path (with its query string, if any) against the server. Concatenation, not
    /// `appendingPathComponent`: the latter percent-encodes `?`, which silently turns
    /// `/commands?team_id=…` into one long path segment and makes every list call return 0 rows.
    private func url(_ path: String) -> URL {
        URL(string: serverURL.absoluteString + path)!
    }

    private func authorizedRequest(_ path: String, method: String) -> URLRequest {
        var request = URLRequest(url: url(path))
        request.httpMethod = method
        request.setValue("Bearer \(token ?? "")", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        return request
    }

    private func getJSON(_ pathWithQuery: String) throws -> Any {
        let (data, _) = try synchronous(authorizedRequest(pathWithQuery, method: "GET"))
        return try JSONSerialization.jsonObject(with: data)
    }

    private func postJSON(_ path: String, body: [String: Any]) throws -> Any {
        var request = authorizedRequest(path, method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try synchronous(request)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func synchronous(_ request: URLRequest) throws -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<(Data, URLResponse), Error>?
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let data, let response {
                result = .success((data, response))
            } else {
                result = .failure(URLError(.badServerResponse))
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 30)
        switch result {
        case .success(let value): return value
        case .failure(let error): throw error
        case nil: throw URLError(.timedOut)
        }
    }

    // MARK: - Element helpers

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Nudge the timeline to its newest row: the lazy stack does not materialise what is below the
    /// fold, and an ephemeral answer is appended at the bottom.
    private func revealNewest(_ app: XCUIApplication) {
        let list = element(app, "channelPostList")
        guard list.exists else { return }
        for _ in 0..<3 { list.swipeUp(velocity: .slow) }
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
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
