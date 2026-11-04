// T53 — video and audio against a **real** Mattermost server, driven through the app itself.
//
// Why live: the card's criteria are statements about real bytes ("the video plays past 1 s", "the
// audio player advances"). A stub would only prove that this file's own fixture agrees with itself.
// The fixture is `scripts/t53_media_seed.py` (channel #t53-media, one post, one mp4 and one mp3,
// both uploaded through `POST /files` and attached through `POST /posts`).
//
// What each assertion is *not*: not a screenshot. The video test taps Play and then reads the
// player's own accessibility value until it reports a position past one second — a playback-state
// transition produced by AVFoundation, not by the test's own timer. The audio test does the same
// against the row's progress line.
//
// Run (local throwaway server; credentials are the throwaway dev account in `scripts/perf_seed.py`):
//
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     python3 scripts/qa-test.py --platform ios --sim "iPhone 16 Pro" \
//       --only-testing MattermostUITests/T53MediaPlaybackUITests
//
// Every test skips (never fails) when the environment or the fixture is missing.

import XCTest

final class T53MediaPlaybackUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var teamID: String!
    private var channelID: String!
    private var postID: String!
    private var videoID: String!
    private var audioID: String!
    private var videoName: String!
    private var audioName: String!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live media test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        let token = try authenticate()
        try loadFixture(token: token)
    }

    // MARK: - Fixture

    private func authenticate() throws -> String {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/users/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["login_id": loginID!,
                                                                      "password": password!])
        let (status, _, headers) = try synchronous(request)
        guard status == 200, let token = headers["token"] else {
            throw XCTSkip("the fixture login answered \(status)")
        }
        return token
    }

    private func loadFixture(token: String) throws {
        guard let team = try getJSON(serverURL.appendingPathComponent("api/v4/teams/name/perf"),
                                     token: token) else {
            throw XCTSkip("team #perf is missing — run scripts/perf_seed.py")
        }
        teamID = try XCTUnwrap(team["id"] as? String)
        guard let channel = try getJSON(serverURL.appendingPathComponent(
            "api/v4/teams/name/perf/channels/name/t53-media"), token: token) else {
            throw XCTSkip("channel #t53-media is missing — run scripts/t53_media_seed.py")
        }
        channelID = try XCTUnwrap(channel["id"] as? String)
        var postsURL = serverURL.appendingPathComponent("api/v4/channels/\(channelID!)/posts")
        var components = URLComponents(url: postsURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "per_page", value: "60")]
        postsURL = try XCTUnwrap(components?.url)
        let posts = try XCTUnwrap(try getJSON(postsURL, token: token))
        let map = try XCTUnwrap(posts["posts"] as? [String: Any])
        let order = try XCTUnwrap(posts["order"] as? [String])

        for candidate in order {
            guard let post = map[candidate] as? [String: Any],
                  let props = post["props"] as? [String: Any], props["t53_key"] as? String == "t53-media",
                  let fileIDs = post["file_ids"] as? [String] else { continue }
            postID = candidate
            for fileID in fileIDs {
                let info = try XCTUnwrap(try getJSON(serverURL.appendingPathComponent("api/v4/files/\(fileID)/info"),
                                                     token: token))
                let name = info["name"] as? String ?? ""
                if name.hasSuffix(".mp4") { videoID = fileID; videoName = name }
                if name.hasSuffix(".mp3") { audioID = fileID; audioName = name }
            }
        }
        try XCTSkipUnless(videoID != nil && audioID != nil,
                          "the T53 fixture post is missing its mp4/mp3 — run scripts/t53_media_seed.py")
    }

    private func getJSON(_ url: URL, token: String) throws -> [String: Any]? {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        let (status, data, _) = try synchronous(request)
        guard status == 200 else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func synchronous(_ request: URLRequest) throws -> (Int, Data, [String: String]) {
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        Self.fixtureSession.dataTask(with: request) { data, response, error in
            var headers: [String: String] = [:]
            if let http = response as? HTTPURLResponse {
                for (key, value) in http.allHeaderFields {
                    headers[String(describing: key).lowercased()] = String(describing: value)
                }
            }
            box.status = (response as? HTTPURLResponse)?.statusCode ?? 0
            box.data = data ?? Data()
            box.headers = headers
            box.error = error
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 30)
        if let error = box.error { throw error }
        return (box.status, box.data, box.headers)
    }

    private static let fixtureSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    private final class ResultBox: @unchecked Sendable {
        var status = 0
        var data = Data()
        var headers: [String: String] = [:]
        var error: Error?
    }

    // MARK: - 1. Video: the poster, then a playback-state transition past one second

    func testAVideoPlaysPastOneSecondAndReleasesWhenDismissed() throws {
        let app = launchAndOpenChannel()
        let cell = element(app, "post.\(postID!).attachment.\(videoID!)")
        XCTAssertTrue(cell.waitForExistence(timeout: 30),
                      "the video attachment must draw a cell:\n\(app.debugDescription)")

        // The poster is the file's first frame, decoded from the staged bytes. Before it lands the
        // value says "Loading poster."; "Poster unavailable" would mean the client fell back to a
        // glyph — the thing the card rules out for a file this client can stage.
        XCTAssertTrue(waitUntil(timeout: 25) {
            let value = (cell.value as? String) ?? ""
            return !value.contains("Loading poster.") && !value.contains("Poster unavailable")
        }, "the video row must draw a first frame, not a generic glyph: \(String(describing: cell.value))")
        attach(app, "t53-video-poster")
        cell.tap()

        let player = element(app, "attachmentPreview.video")
        XCTAssertTrue(player.waitForExistence(timeout: 20),
                      "tapping the video must open the player:\n\(app.debugDescription)")
        let play = element(app, "attachmentPreview.video.play")
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil(timeout: 25) { play.isEnabled },
                      "the play button must become enabled once the file is staged")

        // No autoplay with sound: the position stays at zero until the reader asks for playback.
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(positionSeconds(element(app, "attachmentPreview.video.time")), 0,
                       "the video must not start by itself")

        play.tap()
        let time = element(app, "attachmentPreview.video.time")
        var reached = 0
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            reached = max(reached, positionSeconds(time) ?? 0)
            if reached >= 1 { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        attach(app, "t53-video-playing")
        XCTAssertGreaterThanOrEqual(reached, 1,
                                    "AVFoundation must report a position past one second, got \(reached) "
                                    + "(value=\(String(describing: time.value)))")

        // Dismiss and let the reader go back to the post: the player must be gone.
        element(app, "attachmentPreview.close").tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !player.exists }, "closing the sheet must tear the player down")
        XCTAssertTrue(cell.exists)
    }

    // MARK: - 2. Audio: the row's own player advances, with no sheet

    func testTheAudioPlayerAdvancesInsideTheRowWithoutTakingOverTheScreen() throws {
        let app = launchAndOpenChannel()
        let play = element(app, "post.\(postID!).attachment.\(audioID!).play")
        XCTAssertTrue(play.waitForExistence(timeout: 30),
                      "the audio attachment must draw an in-row player:\n\(app.debugDescription)")
        XCTAssertFalse(element(app, "attachmentPreview").exists,
                       "audio must not take over the screen before it is played")

        let time = element(app, "post.\(postID!).attachment.\(audioID!).time")
        play.tap()
        XCTAssertTrue(time.waitForExistence(timeout: 20),
                      "playing must stage the file and reveal the row's position line")

        var readings: [Int] = []
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let value = positionSeconds(time) { readings.append(value) }
            if (readings.last ?? 0) >= 1 { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        attach(app, "t53-audio-playing")
        XCTAssertGreaterThanOrEqual(readings.last ?? 0, 1,
                                    "the audio player must advance, readings=\(readings)")
        XCTAssertFalse(element(app, "attachmentPreview").exists,
                       "the audio player stays in the row; no sheet may appear")

        // Pause: the same control toggles, and its label says what the next tap will do.
        play.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { (play.label).hasPrefix("Play") },
                      "the toggled button must offer Play again, label=\(play.label)")
    }

    // MARK: - App driving

    private func launchArguments() -> [String] {
        var args: [String] = ["-uiTestResetPersistedState",
                              "-uiTestSeedServer", serverURL.absoluteString,
                              "-uiTestSeedServerName", "Local Mattermost",
                              "-uiTestForgetSession", serverURL.absoluteString]
        // `shell=native` is the pane host surface (the channel view), which draws the post list and
        // therefore the attachments.
        args.append(contentsOf: ["-surfaceMode", "shell=native",
                                 "-surfaceMode", "auth=native",
                                 "-surfaceMode", "sidebar=native",
                                 "-surfaceMode", "composer=native",
                                 "-AppleLanguages", "(en)", "-AppleLocale", "en_US"])
        return args
    }

    private func launchAndOpenChannel() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = launchArguments()
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
        // Not `nativeShell`: since `t_295b0a32` a signed-in launch opens a channel and pushes it
        // **over** the list, so `nativeShell` is absent and `channelSidebar.*` is gone until `Back`
        // (t_9399c0b4). `ShellSettle.waitForSignedIn` answers for both landings.
        XCTAssertTrue(ShellSettle.waitForSignedIn(app, timeout: 40),
                      "signing in must reach the shell:\n\(app.debugDescription)")
    }

    private func openChannel(_ app: XCUIApplication) {
        // The sidebar and its quick switcher are only in the tree while the channel list is on
        // screen: pop the pane the launch pushed first (`ShellSettle.revealChannelList`, t_9399c0b4).
        let pops = ShellSettle.revealChannelList(app)
        // The sidebar lists its channels lazily and the fixture server carries hundreds; the quick
        // switcher is the app's own "find a channel by name" path, so the test uses it rather than
        // scrolling a list whose order is not the test's business.
        let quick = element(app, "channelSidebar.quickSwitcher")
        if !quick.waitForExistence(timeout: 20) {
            let team = element(app, "teamSidebar.team.\(teamID!)")
            if team.waitForExistence(timeout: 10) { team.tap() }
        }
        XCTAssertTrue(quick.waitForExistence(timeout: 30),
                      "the sidebar must offer the quick switcher (after \(pops) Back tap(s) to the "
                      + "channel list):\n\(app.debugDescription)")
        quick.tap()

        let field = element(app, "channelSidebar.quickSwitcher.field")
        XCTAssertTrue(field.waitForExistence(timeout: 10),
                      "the quick switcher must mount:\n\(app.debugDescription)")
        field.tap()
        field.typeText("t53-media")
        let result = element(app, "channelSidebar.quickSwitcher.result.\(channelID!)")
        XCTAssertTrue(result.waitForExistence(timeout: 20),
                      "the quick switcher must find channel \(channelID ?? ""):\n\(app.debugDescription)")
        result.tap()
        XCTAssertTrue(element(app, "channelPostList").waitForExistence(timeout: 40),
                      "the channel pane must mount:\n\(app.debugDescription)")
        _ = element(app, "post.\(postID!)").waitForExistence(timeout: 25)
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// "2 of 8 seconds" → 2. Nil when the element has not rendered a position yet.
    private func positionSeconds(_ element: XCUIElement) -> Int? {
        guard let value = element.value as? String else { return nil }
        guard let first = value.split(separator: " ").first, let seconds = Int(first) else { return nil }
        return seconds
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
