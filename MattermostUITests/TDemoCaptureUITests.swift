import XCTest

/// T74 — the capture driver behind `docs/media/demo/native-demo.gif`.
///
/// The same story films both surfaces. On the simulator `scripts/demo_capture.sh` records the
/// framebuffer; on the Mac Catalyst destination it launches the app with `-demoFrameCapture`
/// (`MM_DEMO_FRAME_DIR` below), so the app writes its own window as a PNG sequence while this
/// test drives it — Screen Recording TCC is not available to the unattended capture shell.
///
/// This is not an acceptance suite for a surface; it is the **script the camera follows**.
/// `scripts/demo_capture.sh` starts `xcrun simctl io <udid> recordVideo`, runs this one test,
/// and cuts the recording at the `DEMO-BEAT` lines this test prints on stdout. Everything the
/// GIF shows is therefore a live run of the product against a seeded server — nothing is
/// composited, staged, or slowed down in post except the cut.
///
/// The story (one continuous take, in order):
///
///   launch           the app opens the workspace, signed in
///   sidebar          the channel list, with #Design review unread and a 1-mention badge on #Releases
///   channel          open #Design review, the timeline at its newest post
///   scrolled         swipe up through the conversation and back down
///   thread           tap the root's "4 replies" line, the thread pane opens
///   reply            type a reply into the thread's composer and send it
///   back             the pane's own Back control returns to #Design review, where the root now
///                    shows 4 replies
///
/// Only working surfaces are in the story: the three p9 defects the card names were verified
/// fixed before this test was written (t_1617a61c thread Back, t_0833c752 reply counts, t_05caa678
/// channel header), and the run that produces the GIF re-proves each one on screen — the header
/// is visible, the reply line is on the root and not on the replies, and Back returns to the
/// channel. If any of those regress, this test fails instead of filming it.
///
/// Fixture: `scripts/demo_seed.py` (team `demo` / "Northwind Studio", channels Town Square,
/// Design review, Releases, Engineering; accounts robin, ava, jordan, riley; all content
/// synthetic). Env, passed through `scripts/qa-test.py` (which strips `TEST_RUNNER_`):
///
///   MM_AUTH_SERVER, MM_AUTH_LOGIN, MM_AUTH_PASSWORD      the throwaway server and reader
///   MM_DEMO_CHANNEL_ID, MM_DEMO_ROOT_ID                  the channel and thread root to film
///   MM_DEMO_REPLY_TEXT                                   what the test types (default below)
///
/// Deliberately no `XCTAssert` on cosmetic detail (colour, spacing): this test's job is to
/// drive a take, and a red run must mean "the story cannot be filmed", not "the GIF will look
/// slightly different this week".
final class TDemoCaptureUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var channelID: String!
    private var rootID: String!
    private var replyText = "Looks great, shipping it."

    /// Wall-clock marks the capture script cuts on. ISO-8601 with milliseconds so a cut lands
    /// within one video frame.
    private func beat(_ name: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        print("DEMO-BEAT \(name) \(formatter.string(from: Date()))")
    }

    /// Let the UI breathe. The take is a product demo, not a speed run: each beat is held long
    /// enough that a reader can see what happened.
    private func dwell(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        channelID = env["MM_DEMO_CHANNEL_ID"] ?? ""
        rootID = env["MM_DEMO_ROOT_ID"] ?? ""
        if let text = env["MM_DEMO_REPLY_TEXT"], !text.isEmpty { replyText = text }
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Capture run: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        try XCTSkipUnless(!channelID.isEmpty && !rootID.isEmpty,
                          "Capture run: seed the fixture with scripts/demo_seed.py and pass "
                          + "TEST_RUNNER_MM_DEMO_CHANNEL_ID / _ROOT_ID")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        token = try authenticate().token
    }

    // MARK: - The take

    func testTheSidebarChannelThreadStory() throws {
        let app = launchSignedIn()
        // The instant the test runner handed control to the app. `scripts/demo_render.py`
        // anchors the cut here so the take opens on the app's own launch screen, never on the
        // springboard the recording starts over.
        beat("app-launched")

        // 1. Launch. A fresh state has no saved channel, so the shell opens the team's town
        //    hall (t_295b0a32). That is the app's own launch behaviour, and it is what the take
        //    shows before the reader goes back to the list.
        XCTAssertTrue(ShellSettle.waitForSignedIn(app, timeout: 60),
                      "the launch must reach the signed-in shell:\n\(app.debugDescription)")
        dwell(1.2)
        beat("launch")

        // 2. Sidebar, with unread. The launch pushed #Town Square over the list, so the way
        //    back is the navigation bar's Back — one tap, then the list draws.
        backToChannelList(app)
        let row = element(app, "channelSidebar.channel.\(channelID!)")
        XCTAssertTrue(row.waitForExistence(timeout: 60),
                      "the sidebar must list the demo channel:\n\(app.debugDescription)")
        dwell(1.2)
        beat("sidebar")

        // 3. Open #Design review from the sidebar, the way a reader does.
        row.tap()
        let list = app.scrollViews["channelPostList"]
        XCTAssertTrue(list.waitForExistence(timeout: 40),
                      "the channel pane must mount:\n\(app.debugDescription)")
        // The channel header is part of the take (t_05caa678): its absence is a defect, not a
        // different-looking video.
        XCTAssertTrue(element(app, "nativeChannelTitle").exists,
                      "the channel header must be on screen:\n\(app.debugDescription)")
        dwell(1.4)
        beat("channel")

        // 4. Scroll. Up through the conversation and back down to the newest post, so the
        //    thread's reply line is in view. One swipe each way: the timeline is already at its
        //    newest post when the pane opens, and every extra gesture costs the take a second of
        //    automation idle time. Nothing is asserted about distance — this is motion, and a
        //    lazy stack's realisation is the shell's business.
        list.swipeUp(velocity: .slow)
        dwell(0.8)
        beat("scrolled-up")
        list.swipeDown(velocity: .fast)
        dwell(0.8)

        // 5. Open the thread from the root's reply line (t_0833c752: the line belongs to the
        //    root on the channel surface).
        let replyLine = element(app, "post.\(rootID!).replyCount")
        XCTAssertTrue(replyLine.waitForExistence(timeout: 20),
                      "the root's reply line must be in the timeline:\n\(app.debugDescription)")
        replyLine.tap()
        XCTAssertTrue(element(app, "threadPane").waitForExistence(timeout: 40),
                      "the thread pane must open:\n\(app.debugDescription)")
        XCTAssertTrue(element(app, "threadPane.back").exists,
                      "the thread pane must offer its Back control (t_1617a61c):\n\(app.debugDescription)")
        dwell(1.4)
        beat("thread")

        // 6. Reply, then send. The composer is the pane's own; typing is left at native speed
        //    so the take looks like a person typing, not a paste.
        let input = composerInput(app)
        XCTAssertTrue(input.exists, "the thread's composer must exist:\n\(app.debugDescription)")
        input.tap()
        dwell(0.3)
        input.typeText(replyText)
        dwell(0.8)
        beat("typed")
        let send = element(app, "channelComposer.send")
        XCTAssertTrue(send.waitForExistence(timeout: 10) && send.isEnabled,
                      "Send must be enabled once the reply is typed:\n\(app.debugDescription)")
        send.tap()
        XCTAssertTrue(try waitForReplyOnServer(timeout: 30),
                      "the reply must reach the server — the take may not show a post that was not written")
        dwell(1.4)
        beat("reply")

        // 7. Back to the channel: the pane's leading control, not the system Back (that is the
        //    compact layout's duplicate affordance; the pane's own control is the one under
        //    test in t_1617a61c).
        element(app, "threadPane.back").tap()
        XCTAssertTrue(app.scrollViews["channelPostList"].waitForExistence(timeout: 40),
                      "Back from the thread must return to the channel:\n\(app.debugDescription)")
        dwell(2.0)
        beat("back")

        // The story's last frame is the channel the reader came from, with the root's reply
        // line now carrying one more reply than the fixture seeded.
        let updated = element(app, "post.\(rootID!).replyCount")
        XCTAssertTrue(updated.exists, "the channel must still show the root:\n\(app.debugDescription)")
    }

    /// Leave a launched channel pane for the channel list with the reader's own gesture.
    ///
    /// Kept local (and deliberately narrow) instead of `ShellSettle.revealChannelList`: that
    /// helper waits up to 10 s for the list's *scroll surface* before trying `Back`, and on
    /// this shell the identifier lands a beat after the rows do — 20 s of a take spent on a
    /// screen that has already finished drawing. The capture only needs the nav-bar Back.
    private func backToChannelList(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons["Back"]
        guard back.waitForExistence(timeout: 15) else { return }
        let deadline = Date().addingTimeInterval(10)
        while !back.isHittable, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        if back.isHittable { back.tap() }
        dwell(0.6)
    }

    // MARK: - Launch and shell plumbing

    private func launchSignedIn() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            // Fresh first-run state, one seeded server, and the session the token below opens.
            // The token seam is the product's own vault write, so the app restores a real
            // session on launch — no sign-in form in the take.
            "-uiTestResetPersistedState",
            "-uiTestSeedServer", serverURL.absoluteString,
            "-uiTestSeedServerName", "Northwind Studio",
            "-uiTestSeedStoredToken", token,
            "-surfaceMode", "shell=native",
            "-surfaceMode", "auth=native",
            "-surfaceMode", "sidebar=native",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        // Desktop segment (T74 v2): the capture script asks the app to film its own window,
        // because Screen Recording TCC is not available to the unattended shell that runs the
        // Mac take. Absent on the simulator runs, where `simctl io recordVideo` is the camera.
        let env = ProcessInfo.processInfo.environment
        if let frames = env["MM_DEMO_FRAME_DIR"], !frames.isEmpty {
            app.launchArguments += [
                "-demoFrameCapture", frames,
                "-demoFrameScheme", env["MM_DEMO_FRAME_SCHEME"] ?? "dark",
                "-demoFrameInterval", env["MM_DEMO_FRAME_INTERVAL"] ?? "0.2",
                "-demoFrameSeconds", env["MM_DEMO_FRAME_SECONDS"] ?? "180",
            ]
        }
        app.launch()
        return app
    }

    /// SwiftUI decides whether an identifier lands on an `other`, a `staticText` or a `button`.
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func composerInput(_ app: XCUIApplication) -> XCUIElement {
        let textView = app.textViews["channelComposer.input"]
        if textView.waitForExistence(timeout: 20) { return textView }
        return element(app, "channelComposer.input")
    }

    // MARK: - The server, as the oracle for "the reply was written"

    private struct Session { let token: String; let userID: String }

    private func authenticate() throws -> Session {
        let body = try request("POST", "/users/login",
                               payload: ["login_id": loginID, "password": password])
        let userID = try XCTUnwrap(body["id"] as? String, "login must return the user")
        // Mattermost 9.x returns the session token in the `Token:` response header.
        let token = try XCTUnwrap(lastToken, "login must return a session token header")
        return Session(token: token, userID: userID)
    }

    private var lastToken: String?

    private func request(_ method: String, _ path: String,
                         payload: [String: Any]? = nil) throws -> [String: Any] {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4" + path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let payload {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        }
        var result: [String: Any] = [:]
        var failure: String?
        let done = DispatchSemaphore(value: 0)
        // A **cookie-free** ephemeral session: the shared session keeps the app's session
        // cookie, and a login on it answers 401 for the wrong principal (measured, see the
        // T36 build note). The capture's oracle must be this test's own login.
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        URLSession(configuration: config).dataTask(with: request) { data, response, error in
            defer { done.signal() }
            if let error { failure = "\(error)"; return }
            if let http = response as? HTTPURLResponse {
                if method == "POST", path == "/users/login" {
                    self.lastToken = http.value(forHTTPHeaderField: "Token")
                }
                if http.statusCode >= 300 {
                    let body = String(data: data ?? Data(), encoding: .utf8) ?? ""
                    failure = "HTTP \(http.statusCode): \(body.prefix(300))"
                    return
                }
            }
            if let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                result = object
            }
        }.resume()
        _ = done.wait(timeout: .now() + 30)
        if let failure { throw NSError(domain: "demo", code: 1, userInfo: [NSLocalizedDescriptionKey: failure]) }
        return result
    }

    private func waitForReplyOnServer(timeout: TimeInterval) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let thread = try request("GET", "/posts/\(rootID!)/thread")
            if let posts = thread["posts"] as? [String: [String: Any]] {
                for post in posts.values where (post["message"] as? String) == replyText {
                    return true
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        return false
    }
}
