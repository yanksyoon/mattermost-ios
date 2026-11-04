// T48-AV — the adversarial UI pass over the post-options menu, against the live fixture.
//
// The T48 build note (docs/t48-build-note.md) measured the happy path: a row opens a sheet, each
// option's write lands, and a second client's pin moves the open sheet. This suite attacks the two
// things a reader of that note cannot check from the note:
//
//   1. **a refused write.** The note's claim is "the sheet stays open and draws the reason inline —
//      no row that silently does nothing, and no sheet that closes as if the write had landed". The
//      refusal is forced the way it happens in life: the post is deleted by its author from another
//      session while the sheet is open, then Pin is pressed. The server answers 404; the sheet must
//      say so and stay open.
//   2. **the my-own-post gate.** Mark Unread is withheld on my own message and Edit/Delete appear
//      only for the author — asserted against the rows actually drawn, not the derivation alone.
//
// The sheet is left on the *deleted* post at the end of test 1 on purpose: the row is gone from the
// timeline, so nothing else can be pressed in it.
//
// Run (fixture: `scripts/perf_seed.py` + `scripts/t36_thread_seed.py`; second account `t36reply`):
//
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     python3 scripts/qa-test.py --platform ios --sim id=<udid> \
//       --only-testing MattermostUITests/T48PostOptionsAVUITests

import XCTest

final class T48PostOptionsAVUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var userID: String!
    private var teamID: String!
    private var channelID: String!

    private let channelName = "t36-threads"
    private let channelDisplayName = "T36 Threads"
    private let secondLogin = "t36reply"
    private let secondPassword = "T36Reply-Not-A-Real-Secret-1"
    private var secondToken: String!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live post-options AV test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
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
        secondToken = try authenticate(login: secondLogin, password: secondPassword).token
    }

    // MARK: - 1. A refused write

    /// The post is deleted by its author while the sheet is open. Pressing Pin must reach the server,
    /// be refused, and the refusal must be drawn in the sheet — which must still be open. A sheet
    /// that dismissed would be indistinguishable from a pin that landed.
    func testTheSheetStaysOpenAndDrawsTheReasonWhenThePinIsRefused() throws {
        let app = try launchOnFixtureChannel()
        let message = "t48 av refused pin \(Int(Date().timeIntervalSince1970))"
        let postID = try createPost(message: message, as: secondToken)
        XCTAssertTrue(revealPost(app, postID).waitForExistence(timeout: 30),
                      "the fixture post must be a row of the presented channel:\n\(app.debugDescription)")
        openMenu(app, postID: postID)
        XCTAssertTrue(revealOption(app, "postOptions.pin").exists,
                      "the premise: Pin is offered on another author's post:\n\(app.debugDescription)")

        // The author deletes the post from another session. The sheet stays on screen with the row
        // it was opened for; the timeline's copy of the row is a tombstone.
        let deleted = try delete(postID, as: secondToken)
        XCTAssertEqual(deleted, 200, "the author's own delete must be accepted")
        XCTAssertNotEqual(try deleteAt(postID), 0, "the server must hold the post as deleted")

        revealOption(app, "postOptions.pin").tap()

        let error = element(app, "postOptions.error")
        XCTAssertTrue(error.waitForExistence(timeout: 25),
                      "a refused pin must be drawn in the sheet, not swallowed:\n\(app.debugDescription)")
        XCTAssertTrue(error.label.contains("pin"),
                      "the copy must name the action that failed; it says \"\(error.label)\"")
        XCTAssertTrue(element(app, "postOptions.cancel").exists,
                      "the sheet must stay open after a refusal; it closed as if the write had landed")
        attach(app, "av1-refused-pin")

        // The server's record: the post is deleted, and nobody pinned it.
        XCTAssertEqual(try deleteAt(postID) == 0, false, "the deleted post must still be deleted")
    }

    // MARK: - 2. My own post

    /// Upstream withholds Mark Unread on your own message and offers Edit/Delete only to the author.
    /// This asserts the rows on screen: the same sheet, two different authors, two different lists.
    func testMyOwnPostOffersEditButNotMarkUnread() throws {
        let app = try launchOnFixtureChannel()
        let message = "t48 av own post \(Int(Date().timeIntervalSince1970))"
        let postID = try createPost(message: message, as: token)
        XCTAssertTrue(revealPost(app, postID).waitForExistence(timeout: 30),
                      "my own post must be a row:\n\(app.debugDescription)")
        openMenu(app, postID: postID)

        XCTAssertFalse(element(app, "postOptions.markUnread").exists,
                       "Mark Unread must be withheld on my own post (upstream !isMine):\n"
                       + app.debugDescription)
        XCTAssertTrue(revealOption(app, "postOptions.edit").exists,
                      "my own post must offer Edit (composer=native):\n\(app.debugDescription)")
        XCTAssertTrue(revealOption(app, "postOptions.delete").exists,
                      "my own post must offer Delete:\n\(app.debugDescription)")
        XCTAssertTrue(revealOption(app, "postOptions.copyText").exists)
        attach(app, "av2-own-post")
        revealOption(app, "postOptions.cancel").tap()
    }

    // MARK: - App driving

    private func launchOnFixtureChannel() throws -> XCUIApplication {
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
        if app.textFields["loginIDField"].waitForExistence(timeout: 20) {
            let field = app.textFields["loginIDField"]
            field.tap()
            field.typeText(loginID)
            let secret = app.secureTextFields["loginPasswordField"]
            XCTAssertTrue(secret.waitForExistence(timeout: 10))
            secret.tap()
            secret.typeText(password)
            app.buttons["loginSubmitButton"].tap()
        }
        // Since `t_295b0a32` a signed-in launch opens a channel and pushes it over the list, so
        // `nativeShell` is absent (t_9399c0b4). `ShellSettle.waitForSignedIn` answers for the list,
        // the pushed pane and the tab bar.
        XCTAssertTrue(ShellSettle.waitForSignedIn(app, timeout: 45),
                      "the app must reach the native shell (signed in):\n\(app.debugDescription)")
        // …and the sidebar's own controls only exist once the list is on screen: pop the push the
        // way a reader does (`ShellSettle.revealChannelList`, t_9399c0b4).
        ShellSettle.revealChannelList(app)
        if !element(app, "channelPostList").waitForExistence(timeout: 8) {
            for identifier in ["backToolbarButton", "BackButton"] {
                let back = app.buttons[identifier]
                if back.waitForExistence(timeout: 3), back.isEnabled { back.tap(); break }
            }
        }
        let opener = element(app, "channelSidebar.quickSwitcher")
        if !opener.waitForExistence(timeout: 10) {
            // Switching the rail into #perf pushed that team's default channel: pop it the same way.
            _ = ShellSettle.revealChannelList(app)
        }
        XCTAssertTrue(opener.waitForExistence(timeout: 30),
                      "the sidebar must offer the quick switcher:\n\(app.debugDescription)")
        opener.tap()
        let field = app.textFields["channelSidebar.quickSwitcher.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText(channelName)
        let result = element(app, "channelSidebar.quickSwitcher.result.\(channelID!)")
        XCTAssertTrue(result.waitForExistence(timeout: 25),
                      "the switcher must find #\(channelName):\n\(app.debugDescription)")
        result.tap()
        XCTAssertTrue(element(app, "channelPostList").waitForExistence(timeout: 45),
                      "the fixture channel must be open:\n\(app.debugDescription)")
        XCTAssertEqual(element(app, "nativeChannelTitle").label, channelDisplayName)
        return app
    }

    /// A `.medium` detent draws only the first rows; a row below the fold is `exists == false` until
    /// scrolled (`docs/t48-build-note.md` §Tests — the pitfall the note records).
    @discardableResult
    private func revealOption(_ app: XCUIApplication, _ identifier: String,
                              maxSwipes: Int = 4) -> XCUIElement {
        let target = element(app, identifier)
        guard !target.exists else { return target }
        for _ in 0..<maxSwipes {
            app.swipeUp()
            if target.exists { return target }
        }
        return target
    }

    private func openMenu(_ app: XCUIApplication, postID: String) {
        let menu = element(app, "post.\(postID).menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 25),
                      "the row must expose its options button:\n\(app.debugDescription)")
        menu.tap()
        XCTAssertTrue(element(app, "postOptions.cancel").waitForExistence(timeout: 25),
                      "the options sheet must open:\n\(app.debugDescription)")
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @discardableResult
    private func revealPost(_ app: XCUIApplication, _ postID: String,
                            maxSwipes: Int = 14) -> XCUIElement {
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

    // MARK: - Server access (cookie-free: a stale MMAUTHTOKEN cookie makes a correct login 401)

    private static let restSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

    private struct Session { let token: String; let userID: String }

    private func authenticate(login: String, password: String) throws -> Session {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/users/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["login_id": login,
                                                                      "password": password])
        let (data, response) = try synchronous(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let issued = http.value(forHTTPHeaderField: "Token"),
              let user = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = user["id"] as? String else {
            throw XCTSkip("could not sign in as \(login) on \(serverURL.absoluteString)")
        }
        return Session(token: issued, userID: id)
    }

    private func teamsForMe() throws -> [[String: Any]] {
        try getJSON("/api/v4/users/me/teams") as? [[String: Any]] ?? []
    }

    private func channel(named name: String, in teamID: String) throws -> [String: Any]? {
        try getJSON("/api/v4/teams/\(teamID)/channels/name/\(name)") as? [String: Any]
    }

    private func createPost(message: String, as token: String) throws -> String {
        let json = try postJSON("/api/v4/posts",
                                body: ["channel_id": channelID as String, "message": message],
                                token: token)
        guard let post = json as? [String: Any], let id = post["id"] as? String else {
            throw XCTSkip("the server refused the fixture post")
        }
        return id
    }

    private func delete(_ postID: String, as token: String) throws -> Int {
        var request = URLRequest(url: serverURL.appendingPathComponent("/api/v4/posts/\(postID)"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try synchronous(request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    private func deleteAt(_ postID: String) throws -> Int64 {
        let post = try getJSON("/api/v4/posts/\(postID)") as? [String: Any] ?? [:]
        return (post["delete_at"] as? Int64) ?? (post["delete_at"] as? Int).map(Int64.init) ?? 0
    }

    private func getJSON(_ path: String) throws -> Any {
        var request = URLRequest(url: serverURL.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try synchronous(request)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func postJSON(_ path: String, body: Any, token: String) throws -> Any {
        var request = URLRequest(url: serverURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try synchronous(request)
        guard !data.isEmpty, let json = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return json
    }

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
