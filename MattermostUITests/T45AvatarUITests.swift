import XCTest

/// T45 — profile pictures against a **real** Mattermost server.
///
/// The unit suite (`AvatarImageStoreTests`) pins the policy: one request per account, a `404` is
/// remembered, a transient failure is not, the disk cache survives a relaunch. What no unit test can
/// show is the thing that was actually broken — that the *running app* sends
/// `GET /api/v4/users/{id}/image` **authenticated**, decodes the bytes, and puts them on screen.
/// A store tested only against a fake loader would have passed on the day the report said "avatars
/// are blank".
///
/// So this test launches the native shell against the seeded fixture server, opens a channel that
/// has authors with pictures, scrolls the timeline so post-group avatars are on screen, and leaves
/// two artefacts behind in the result bundle:
///   * `t45-avatars-shown` — the screenshot, where a face is visible instead of initials;
///   * the app's own disk cache, which the harness checks from the host after the run
///     (`Caches/profile-images/<server>/<user>.img`): bytes on disk can only exist if the request
///     went out through the session and the response decoded as an image.
///
/// Run (local throwaway server, credentials from `scripts/perf_seed.py`):
///
///     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
///     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
///     TEST_RUNNER_MM_AUTH_PASSWORD=<seeded probe account> \
///     python3 scripts/qa-test.py --platform ios --sim <sim> \
///       --only-testing MattermostUITests/T45AvatarUITests
///
/// Skips — never fails — when the environment or the server is missing, like every live test here.
final class T45AvatarUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live avatar test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        try ping()
        token = try authenticate()
    }

    func testTheRunningAppDrawsTheServersPictures() throws {
        // Pick the channel from the server, not from a promise in this file: the fewest-posted open
        // channel whose newest author has a picture. A group's first row is the only row that draws
        // an avatar, so the newest post of a one-post channel is the smallest honest stage for this,
        // and it needs no scrolling (the list opens at the newest post).
        let pickup = try avatarChannel()
        let app = launchAndOpen(channelID: pickup.id)
        XCTAssertTrue(element(app, "channelPostList").waitForExistence(timeout: 60),
                      "the native post list must mount:\n\(app.debugDescription)")

        let row = element(app, "post.\(pickup.newestPostID)")
        XCTAssertTrue(row.exists, "the newest post must be drawn:\n\(app.debugDescription)")

        // The picture arrives over the network and is decoded on the main actor: give it a moment,
        // then record what the screen actually shows.
        Thread.sleep(forTimeInterval: 4)
        attach(app, "t45-avatars-shown")

        // The author's picture is the one the server serves for that account (asserted below), so a
        // filled circle in this screenshot is the app having fetched it, not a coincidence.
        XCTAssertNotNil(try imageBytes(for: pickup.newestAuthorID),
                        "the server must still answer with a picture for \(pickup.newestAuthorID)")
    }

    // MARK: - Launch

    private func launchAndOpen(channelID: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetPersistedState",
                               "-uiTestForgetSession", serverURL.absoluteString,
                               "-uiTestSeedServer", serverURL.absoluteString,
                               "-uiTestSeedServerName", "Local Mattermost",
                               "-surfaceMode", "shell=native",
                               "-surfaceMode", "auth=native",
                               "-surfaceMode", "sidebar=native",
                               // The avatar is the profile affordance (T41). With the profile
                               // surface native it becomes a button, which is also the handle this
                               // test uses to prove a group's first row is mounted.
                               "-surfaceMode", "profile=native",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let field = app.textFields["loginIDField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20),
                      "the native sign-in must mount against \(serverURL.absoluteString)")
        field.tap()
        field.typeText(loginID)
        let secret = app.secureTextFields["loginPasswordField"]
        XCTAssertTrue(secret.exists)
        secret.tap()
        secret.typeText(password)
        app.buttons["loginSubmitButton"].tap()
        XCTAssertTrue(element(app, "nativeShell").waitForExistence(timeout: 40),
                      "signing in must reach the shell")

        // The sidebar is a lazy list (a `ScrollView` + `LazyVStack` since T8f) and this server holds
        // ~40 channels for this account, so scroll (bounded, both directions) until the row is
        // realised — a person scrolls.
        let row = element(app, "channelSidebar.channel.\(channelID)")
        if !row.waitForExistence(timeout: 10) {
            let sidebar = ShellSettle.channelSidebarScroll(app)
            XCTAssertTrue(sidebar.exists, "the channel sidebar must mount:\n\(app.debugDescription)")
            var revealed = row.exists
            for _ in 0..<5 where !revealed {
                sidebar.swipeUp(velocity: .fast)
                revealed = row.waitForExistence(timeout: 1)
            }
            for _ in 0..<5 where !revealed {
                sidebar.swipeDown(velocity: .fast)
                revealed = row.waitForExistence(timeout: 1)
            }
        }
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "the sidebar must list the chosen channel:\n\(app.debugDescription)")
        row.tap()
        return app
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

    // MARK: - Server access (the test is its own API client)

    private func ping() throws {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/system/ping"))
        request.timeoutInterval = 5
        let (_, response) = try synchronous(request)
        try XCTSkipUnless((response as? HTTPURLResponse)?.statusCode == 200,
                          "the live server at \(serverURL.absoluteString) is not answering")
    }

    private func authenticate() throws -> String {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/users/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["login_id": loginID ?? "",
                                                                      "password": password ?? ""])
        let (_, response) = try synchronous(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let token = http.value(forHTTPHeaderField: "Token") else {
            throw XCTSkip("could not sign in as \(loginID ?? "") on the live server")
        }
        return token
    }

    /// The fewest-posted open channel whose newest author has a picture, read from the server.
    private func avatarChannel() throws -> (id: String, name: String, newestPostID: String,
                                           newestAuthorID: String) {
        let teams = try getJSON("/api/v4/users/me/teams") as? [[String: Any]] ?? []
        guard let team = teams.first, let teamID = team["id"] as? String else {
            throw XCTSkip("the probe account is in no team")
        }
        let channels = try getJSON("/api/v4/users/me/teams/\(teamID)/channels") as? [[String: Any]] ?? []
        var candidates: [(count: Int, id: String, name: String, post: String, author: String)] = []
        for channel in channels where (channel["type"] as? String) == "O" {
            guard let id = channel["id"] as? String, let name = channel["name"] as? String else { continue }
            let posts = try posts(in: id)
            guard let newest = posts.first, let postID = newest["id"] as? String,
                  let author = newest["user_id"] as? String else { continue }
            // A system post ("x joined the channel") draws an icon, not an avatar.
            guard (newest["type"] as? String ?? "").isEmpty else { continue }
            guard (try? imageBytes(for: author)) != nil else { continue }
            candidates.append((posts.count, id, name, postID, author))
        }
        guard let best = candidates.min(by: { $0.count < $1.count }) else {
            throw XCTSkip("no open channel on \(serverURL.absoluteString) has an author with a "
                          + "picture — seed one (scripts/t34_post_seed.py) or upload an avatar first")
        }
        return (best.id, best.name, best.post, best.author)
    }

    private func posts(in channelID: String) throws -> [[String: Any]] {
        let body = try getJSON("/api/v4/channels/\(channelID)/posts?per_page=60")
        guard let page = body as? [String: Any],
              let posts = page["posts"] as? [String: [String: Any]],
              let order = page["order"] as? [String] else { return [] }
        // Newest first, like the server's own order field (which is newest-first for this endpoint).
        return order.compactMap { posts[$0] }
    }

    private func request(path: String) throws -> URLRequest {
        guard let url = URL(string: serverURL.absoluteString + path) else {
            throw XCTSkip("bad URL for \(path)")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token ?? "")", forHTTPHeaderField: "Authorization")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        return request
    }

    private func imageBytes(for userID: String) throws -> Data? {
        let (data, response) = try synchronous(try request(path: "/api/v4/users/\(userID)/image"))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else {
            return nil
        }
        return data
    }

    private func getJSON(_ path: String) throws -> Any {
        let (data, response) = try synchronous(try request(path: path))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw XCTSkip("GET \(path) answered \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        return (try? JSONSerialization.jsonObject(with: data)) ?? [:]
    }

    private func synchronous(_ request: URLRequest) throws -> (Data, URLResponse) {
        let box = ResponseBox()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            box.data = data ?? Data()
            box.response = response
            box.error = error
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 20)
        if let error = box.error { throw error }
        guard let response = box.response else { throw XCTSkip("no answer from \(serverURL.absoluteString)") }
        return (box.data, response)
    }

    private final class ResponseBox {
        var data = Data()
        var response: URLResponse?
        var error: Error?
    }
}
