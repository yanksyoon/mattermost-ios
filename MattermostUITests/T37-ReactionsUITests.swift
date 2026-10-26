// T37 — emoji reactions and the picker against a **real** Mattermost server, with every expectation
// read back from that server through its own API.
//
// Why live: the acceptance criteria are statements about two things at once — what the reader sees on
// the native list, and what the server ends up storing. A stub can only prove the first, and it would
// prove it against this file's own fixture rather than against `POST /reactions`.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0, app/actions/remote/reactions.ts.
//
// Fixture: the `perf` team's `t36-threads` channel (`scripts/t36_thread_seed.py`) — reused rather than
// seeded again because a reaction needs a post by *another* author, which that fixture already has (the
// `t36reply` account). Each test makes its own post, so a run never consumes the fixture.
//
// Run (local throwaway server; credentials are the throwaway dev account in `scripts/perf_seed.py`):
//
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     python3 scripts/qa-test.py --platform ios --sim "iPhone 17 Pro" \
//       --only-testing MattermostUITests/T37ReactionsUITests
//
// Every test skips (never fails) when the environment or the fixture is missing.

import XCTest

final class T37ReactionsUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var userID: String!
    private var teamID: String!
    private var channelID: String!

    /// The second author the T36 fixture creates: its posts are the ones this app did not make.
    private let secondLogin = "t36reply"
    private let secondPassword = "T36Reply-Not-A-Real-Secret-1"
    private var secondToken: String!
    private var secondUserID: String!

    private let channelName = "t36-threads"

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live reaction test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
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
        guard let channel = try channel(named: channelName, in: teamID) else {
            throw XCTSkip("channel #\(channelName) is missing — run scripts/t36_thread_seed.py")
        }
        channelID = try XCTUnwrap(channel["id"] as? String)
        let second = try authenticate(login: secondLogin, password: secondPassword)
        secondToken = second.token
        secondUserID = second.userID
    }

    // MARK: - 1. The pill is the server's, and a tap writes back

    /// The card's first criterion, in one run: a reaction another reader left is drawn as a pill, a tap
    /// on it adds **my** reaction on the server, a second tap removes it — and the pill never shows a
    /// count the server does not agree with.
    func testTappingAPillWritesTheReactionToTheServerAndTappingAgainRemovesIt() throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let post = try post(message: "t37 reaction target \(stamp)", rootID: nil, as: secondToken)
        let postID = try XCTUnwrap(post["id"] as? String)
        // The other reader's reaction is what puts a pill on the row without the app doing anything.
        try addReaction(postID: postID, emoji: "smile", as: secondToken)

        let app = launchAndOpenChannel()
        XCTAssertTrue(revealPost(app, postID, maxSwipes: 10).exists,
                      "the fixture post must be a row of the channel:\n\(app.debugDescription)")

        let pill = element(app, "post.\(postID).reaction.smile")
        XCTAssertTrue(pill.waitForExistence(timeout: 30),
                      "a reaction the server holds must be drawn as a pill:\n\(app.debugDescription)")
        XCTAssertEqual(pill.label, "smile 1", "one reactor, named by the pill")

        // 1. A tap adds mine, and the server says so.
        pill.tap()
        XCTAssertTrue(waitUntil(timeout: 25) { self.reactionUserIDs(postID, emoji: "smile").contains(self.userID) },
                      "the tap must reach POST /reactions; the server holds "
                      + "\(reactionUserIDs(postID, emoji: "smile"))")
        XCTAssertTrue(waitUntil(timeout: 15) {
            self.element(app, "post.\(postID).reaction.smile").label == "smile 2"
        }, "the pill must follow the server's count; it reads "
           + "\"\(element(app, "post.\(postID).reaction.smile").label)\"")
        attach(app, "t37-01-pill-added")

        // 2. A second tap removes it again.
        element(app, "post.\(postID).reaction.smile").tap()
        XCTAssertTrue(waitUntil(timeout: 25) { !self.reactionUserIDs(postID, emoji: "smile").contains(self.userID) },
                      "the second tap must reach DELETE …/reactions; the server holds "
                      + "\(reactionUserIDs(postID, emoji: "smile"))")
        XCTAssertTrue(waitUntil(timeout: 15) { self.element(app, "post.\(postID).reaction.smile").label
            == "smile 1" },
                      "the pill must follow the server's count:\n\(app.debugDescription)")
        attach(app, "t37-02-pill-removed")
    }

    // MARK: - 2. The picker reaches the same write

    /// The card's second criterion: a reader who has not reacted yet can open the picker from the row
    /// menu, search, pick an emoji, and the server ends up holding exactly that reaction — under the
    /// canonical shortcode (`thumbsup` is stored as the alias group's canonical name).
    func testThePickerFromTheRowMenuAddsTheReactionTheServerStores() throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let post = try post(message: "t37 picker target \(stamp)", rootID: nil, as: secondToken)
        let postID = try XCTUnwrap(post["id"] as? String)

        let app = launchAndOpenChannel()
        XCTAssertTrue(revealPost(app, postID, maxSwipes: 10).exists,
                      "the fixture post must be a row of the channel:\n\(app.debugDescription)")

        let menu = element(app, "post.\(postID).menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 20),
                      "the row must offer its menu:\n\(app.debugDescription)")
        menu.tap()
        let react = element(app, "postOptions.react")
        XCTAssertTrue(react.waitForExistence(timeout: 20),
                      "the menu must offer React:\n\(app.debugDescription)")
        react.tap()

        XCTAssertTrue(element(app, "emojiPicker").waitForExistence(timeout: 20),
                      "React must open the picker:\n\(app.debugDescription)")
        // The first category's first cell: a deterministic, on-screen emoji. (Search and its ranking
        // are pinned by T37ReactionTests; a live run here is about the write path, not the ranking.)
        let cell = element(app, "emojiPicker.emoji.grinning")
        XCTAssertTrue(cell.waitForExistence(timeout: 20),
                      "the picker must draw the system categories:\n\(app.debugDescription)")
        attach(app, "t37-03-picker-search")
        cell.tap()

        XCTAssertTrue(waitUntil(timeout: 25) { self.reactionUserIDs(postID, emoji: "tada").contains(self.userID) },
                      "picking must write POST /reactions; the server holds "
                      + "\(reactionUserIDs(postID, emoji: "tada"))")
        XCTAssertTrue(waitUntil(timeout: 20) {
            self.element(app, "post.\(postID).reaction.tada").exists
        }, "the new pill must appear on the row:\n\(app.debugDescription)")
        attach(app, "t37-04-picker-pill")
    }

    // MARK: - 3. The alias rule, on the wire

    /// `thumbsup` and `+1` are two rows on the server (measured on 9.11.19) and must be one pill to the
    /// reader. This test leaves *both* spellings on the post as the second reader, and checks that the
    /// row draws a single pill with the full count — then that removing it from this account clears
    /// only this account's rows.
    func testAliasSpellingsAreOnePillAndOneRemoveClearsEveryRowIHold() throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let post = try post(message: "t37 alias target \(stamp)", rootID: nil, as: secondToken)
        let postID = try XCTUnwrap(post["id"] as? String)
        try addReaction(postID: postID, emoji: "+1", as: secondToken)
        try addReaction(postID: postID, emoji: "thumbsup", as: secondToken)

        let app = launchAndOpenChannel()
        XCTAssertTrue(revealPost(app, postID, maxSwipes: 10).exists,
                      "the fixture post must be a row of the channel:\n\(app.debugDescription)")

        // One pill, both spellings: the count is the group's, not the canonical alias's.
        let canonicalPill = element(app, "post.\(postID).reaction.+1")
        XCTAssertTrue(canonicalPill.waitForExistence(timeout: 30),
                      "the alias group must be drawn under its canonical name:\n\(app.debugDescription)")
        XCTAssertEqual(canonicalPill.label, "+1 2",
                       "both spellings are one pill with both reactors")
        XCTAssertFalse(element(app, "post.\(postID).reaction.thumbsup").exists,
                       "the second spelling must not get its own pill")
        attach(app, "t37-05-alias-pill")
    }

    // MARK: - Server helpers

    private func ping() throws {
        let url = serverURL.appendingPathComponent("api/v4/system/ping")
        let (_, response) = try synchronous(URLRequest(url: url))
        try XCTSkipUnless((response as? HTTPURLResponse)?.statusCode == 200,
                          "no Mattermost at \(serverURL.absoluteString)")
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

    private func channel(named name: String, in teamID: String) throws -> [String: Any]? {
        var request = URLRequest(url: serverURL.appendingPathComponent(
            "api/v4/teams/\(teamID)/channels/name/\(name)"))
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        let (data, response) = try synchronous(request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func post(message: String, rootID: String?, as token: String) throws -> [String: Any] {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/posts"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        var body: [String: Any] = ["channel_id": channelID, "message": message]
        if let rootID { body["root_id"] = rootID }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try synchronous(request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201,
                       "the server must accept the fixture post")
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func addReaction(postID: String, emoji: String, as token: String) throws {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/reactions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        guard let me = try getJSON("/api/v4/users/me", as: token) as? [String: Any],
              let uid = me["id"] as? String else {
            throw XCTSkip("could not read the fixture user")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["user_id": uid,
                                                                      "post_id": postID,
                                                                      "emoji_name": emoji])
        let (_, response) = try synchronous(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        XCTAssertTrue(status == 201 || status == 200,
                      "POST /reactions for \(emoji) must be accepted (HTTP \(status))")
    }

    /// The user ids the server holds for one emoji name on one post — the oracle for every write here.
    private func reactionUserIDs(_ postID: String, emoji: String) -> [String] {
        guard let json = try? getJSON("/api/v4/posts/\(postID)"),
              let post = json as? [String: Any],
              let metadata = post["metadata"] as? [String: Any],
              let reactions = metadata["reactions"] as? [[String: Any]] else { return [] }
        return reactions.filter { $0["emoji_name"] as? String == emoji }
            .compactMap { $0["user_id"] as? String }
    }

    private func getJSON(_ path: String, as token: String? = nil) throws -> Any {
        var request = URLRequest(url: serverURL.appendingPathComponent(path))
        request.setValue("Bearer \(token ?? self.token!)", forHTTPHeaderField: "Authorization")
        let (data, _) = try synchronous(request)
        return try JSONSerialization.jsonObject(with: data)
    }

    /// An ephemeral session with cookies off: the `Authorization` header is then the only identity a
    /// fixture call can carry, so a fixture post cannot silently belong to the app's session.
    private static let fixtureSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    private func synchronous(_ request: URLRequest) throws -> (Data, URLResponse) {
        var result: Result<(Data, URLResponse), Error>?
        let semaphore = DispatchSemaphore(value: 0)
        Self.fixtureSession.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else {
                result = .success((data ?? Data(), response ?? URLResponse()))
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 30)
        switch result {
        case .success(let value): return value
        case .failure(let error): throw error
        case nil: throw XCTSkip("the fixture request timed out")
        }
    }

    // MARK: - App helpers

    private func launchAndOpenChannel() -> XCUIApplication {
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
        openChannel(app)
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

    private func openChannel(_ app: XCUIApplication) {
        let row = element(app, "channelSidebar.channel.\(channelID!)")
        XCTAssertTrue(row.waitForExistence(timeout: 40),
                      "the sidebar must list channel \(channelID ?? ""):\n\(app.debugDescription)")
        row.tap()
        XCTAssertTrue(element(app, "channelPostList").waitForExistence(timeout: 40),
                      "the channel pane must mount:\n\(app.debugDescription)")
    }

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

    /// A channel row that may be outside the viewport (`LazyVStack`: an off-screen row is not in the
    /// tree at all).
    @discardableResult
    private func revealPost(_ app: XCUIApplication, _ postID: String,
                            maxSwipes: Int = 12) -> XCUIElement {
        let target = element(app, "post.\(postID)")
        guard !target.exists else { return target }
        let list = element(app, "channelPostList")
        var swipes = 0
        while !target.exists, swipes < maxSwipes {
            list.swipeUp(velocity: .fast)
            swipes += 1
        }
        return target
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
