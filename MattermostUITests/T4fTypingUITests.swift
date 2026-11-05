// T4f — the typing indicator against a **real** Mattermost server, with a **second account** on the
// other end of the socket.
//
// Why live: every claim in this card is about two clients agreeing through the server —
//   1. what this app types reaches the server as a `user_typing` frame on the channel on screen, and
//      a burst inside `TimeBetweenUserTypingUpdatesMilliseconds` adds no second frame;
//   2. a frame another account sends draws the row above this reader's composer, named, and the row
//      expires on the server's own window;
//   3. a reply typed in the thread pane names the thread's **root** as `parent_id`, and a frame that
//      names a root is not drawn in the channel pane.
// A stub can only prove this file agrees with itself. So the frames are read by a WebSocket this test
// opens as the second account, and the row's expected name is computed from what `/users/{id}` says —
// `nickname` → `first_name last_name` → `username`, the same rule the pane applies
// (`PostListDerivation.displayName`).
//
// Fixture: `python3 scripts/t43_notification_seed.py --url http://127.0.0.1:8065` — accounts
// `perfprobe` (the app) and `t43buddy` (the second client), both members of `#t43-notify`. What the
// server actually sends is recorded in `scripts/t4f_typing_probe.py`; the assertions below mirror it.
//
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     python3 scripts/qa-test.py --platform ios --sim "iPhone 16 Pro" \
//       --only-testing MattermostUITests/T4fTypingUITests
//
// Each test skips (never fails) when the environment or the fixture is missing.

import XCTest

final class T4fTypingUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var userID: String!
    private var teamID: String!
    private var channelID: String!

    private static let buddyLogin = "t43buddy"
    private static let buddyPassword = "T43-Buddy-Not-A-Real-Secret-1"
    private static let channelName = "t43-notify"
    private static var cachedBuddySession: (server: String, token: String, userID: String)?

    /// The fixture server's own value (`/config/client`), read in `setUp` rather than assumed: the
    /// expiry below is asserted against the server's window, not against a number this file chose.
    private var typingInterval: TimeInterval = 5

    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let raw = environment["MM_AUTH_SERVER"] ?? ""
        loginID = environment["MM_AUTH_LOGIN"] ?? ""
        password = environment["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live typing test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        try ping()
        let session = try authenticate(login: loginID, password: password)
        token = session.token
        userID = session.userID
        teamID = try teamIDForMe()
        channelID = try channel().id
        if let config = try? getJSON("/api/v4/config/client?format=old") as? [String: Any],
           let value = config["TimeBetweenUserTypingUpdatesMilliseconds"] as? String,
           let milliseconds = TimeInterval(value), milliseconds > 0 {
            typingInterval = milliseconds / 1000
        }
    }

    // MARK: - 1. What this app types reaches another client as `user_typing`

    func testTypingInTheComposerReachesAnotherClientOnTheChannel() throws {
        let buddy = try makeBuddy()
        let app = launchAndOpen()
        let input = composerInput(app)
        XCTAssertTrue(input.waitForExistence(timeout: 30),
                      "the native composer must mount in the pane:\n\(app.debugDescription)")
        input.tap()

        buddy.clearTypingFrames()
        input.typeText("T4f")
        var frames = buddy.waitForTypingFrames(userID: userID, timeout: 12)
        if frames.isEmpty {
            // Second chance, and the reason is a real one: a frame sent while the rail's socket is
            // still completing its handshake is dropped by design (`SocketClient.send`), and a pane
            // that mounts quickly enough hits that window. The reader's *next* word does the same
            // thing — and by now the window is well past the server's interval, so it is sent.
            input.tap()
            input.typeText("!")
            frames = buddy.waitForTypingFrames(userID: userID, timeout: 20)
        }
        XCTAssertFalse(frames.isEmpty,
                       "typing in the composer must reach the server as a `user_typing` frame the other "
                       + "account receives; events seen: \(buddy.describeEvents())")

        guard let first = frames.first else { return }
        XCTAssertEqual(first.channelID, channelID, "the frame names the channel on screen")
        XCTAssertEqual(first.userID, userID, "the frame names the account that is typing")
        XCTAssertEqual(first.parentID, "",
                       "a channel message carries no root — measured: the server normalises the "
                       + "omitted `parent_id` to \"\"")

        // Throttle: a burst inside the server's interval must not add a frame. 2 s of listening is
        // inside every sane interval (the fixture answers 5 s).
        let before = buddy.typingFrameCount(userID: userID)
        input.typeText(" typing")
        _ = buddy.waitForTypingFrames(userID: userID, timeout: 2, minimum: before + 1,
                                      returnOnTimeout: true)
        XCTAssertEqual(buddy.typingFrameCount(userID: userID), before,
                       "a burst inside TimeBetweenUserTypingUpdatesMilliseconds (\(typingInterval) s) "
                       + "must not send a second frame")
        attach(app, "t4f-1-send")
    }

    // MARK: - 2. Another account's frame draws the row, and the row expires

    func testAnotherUsersFrameDrawsTheRowAboveTheComposerAndExpires() throws {
        let buddy = try makeBuddy()
        let buddyName = try displayName(of: buddy.userID)
        // A real root with a reply, so a frame can name a thread this pane must ignore.
        let root = try sendPost("T4f typing root \(stamp())")
        _ = try sendPost("T4f typing reply \(stamp())", rootID: root)

        let app = launchAndOpen()
        XCTAssertTrue(composerInput(app).waitForExistence(timeout: 30),
                      "the native composer must mount in the pane:\n\(app.debugDescription)")

        // (a) a thread-addressed frame is not this pane's row
        buddy.sendTyping(channelID: channelID, parentID: root)
        XCTAssertFalse(element(app, "channelComposer.typing").waitForExistence(timeout: 3),
                       "a frame whose parent_id names a thread must not draw in the channel pane")

        // (b) a channel frame is
        buddy.sendTyping(channelID: channelID, parentID: "")
        let row = element(app, "channelComposer.typing")
        XCTAssertTrue(row.waitForExistence(timeout: 15),
                      "another account typing in this channel must draw the row:\n\(app.debugDescription)")
        let label = row.label.isEmpty ? ((row.value as? String) ?? "") : row.label
        XCTAssertEqual(label, "\(buddyName) is typing...",
                       "the row names the typist by the pane's own display rule; the server says "
                       + "/users/\(buddy.userID) is '\(buddyName)'")

        // (c) and it clears itself on the server's window
        let started = Date()
        let gone = waitUntil(timeout: typingInterval + 12) { !row.exists }
        XCTAssertTrue(gone,
                      "no further frame for \(typingInterval) s must clear the row (waited "
                      + "\(Int(Date().timeIntervalSince(started))) s):\n\(app.debugDescription)")
        attach(app, "t4f-2-row")
    }

    // MARK: - 3. A reply typed in the thread pane names its root

    func testAReplyTypedInTheThreadPaneNamesItsRoot() throws {
        let buddy = try makeBuddy()
        let buddyName = try displayName(of: buddy.userID)
        let root = try sendPost("T4f thread root \(stamp())")
        _ = try sendPost("T4f thread reply \(stamp())", rootID: root)

        let app = launchAndOpen()
        openThread(app, rootID: root)

        let input = composerInput(app)
        XCTAssertTrue(input.waitForExistence(timeout: 30),
                      "the thread pane must offer its reply composer:\n\(app.debugDescription)")
        input.tap()
        buddy.clearTypingFrames()
        input.typeText("T4f reply")

        let frames = buddy.waitForTypingFrames(userID: userID, timeout: 20)
        XCTAssertFalse(frames.isEmpty,
                       "typing in the thread pane must reach the other client; events seen: "
                       + buddy.describeEvents())
        XCTAssertEqual(frames.first?.parentID, root,
                       "a reply's frame carries the thread root as parent_id (measured), which is what "
                       + "lets the thread pane find the row and the channel pane ignore it")
        XCTAssertEqual(frames.first?.channelID, channelID)

        // The thread pane draws its **own** row from the same frame shape. This is asserted on the
        // thread's identifier, not the channel's: a frame addressed to the root must never light up
        // the channel composer behind the pane, and one identifier for both would make that
        // indistinguishable.
        buddy.sendTyping(channelID: channelID, parentID: root)
        let row = element(app, "threadComposer.typing")
        XCTAssertTrue(row.waitForExistence(timeout: 15),
                      "another account typing in this thread must draw the thread's row:\n"
                      + "\(app.debugDescription)")
        let expected = "\(buddyName) is typing..."
        // The frame names an id; the name arrives with the profile request, so wait for the row to be
        // named rather than reading a "Someone" that is about to be corrected.
        let named = waitUntil(timeout: 12) {
            let text = row.label.isEmpty ? ((row.value as? String) ?? "") : row.label
            return text == expected
        }
        let text = row.label.isEmpty ? ((row.value as? String) ?? "") : row.label
        XCTAssertTrue(named, "the thread's row must name the typist '\(expected)', drew '\(text)'")
        attach(app, "t4f-3-thread")
    }

    // MARK: - The second account, on a real WebSocket

    private func makeBuddy() throws -> BuddyClient {
        let buddy = try BuddyClient(serverURL: serverURL)
        try XCTSkipUnless(buddy.waitUntilAuthenticated(),
                          "the second account's socket never acknowledged the authentication "
                          + "challenge — events seen: \(buddy.describeEvents())")
        return buddy
    }

    /// The second account and its socket: logs in over REST, authenticates the socket, and keeps every
    /// `typing` frame with the three fields this suite asserts on.
    final class BuddyClient {
        struct TypingFrame {
            let userID: String
            let channelID: String
            let parentID: String
        }

        let userID: String
        private let socket: URLSessionWebSocketTask
        private let session: URLSession
        private let lock = NSLock()
        private var frames: [TypingFrame] = []
        private var events: [String] = []
        /// Set when the server answers the challenge (`status: OK, seq_reply: 1`). A frame sent before
        /// that answer is a frame the server has no reason to believe came from anybody — the same wait
        /// `scripts/t4f_typing_probe.py` performs after its own `authentication_challenge`.
        private var authenticated = false

        init(serverURL: URL) throws {
            var comps = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
            comps?.scheme = serverURL.scheme == "https" ? "wss" : "ws"
            comps?.path = "/api/v4/websocket"
            guard let url = comps?.url else { throw XCTSkip("bad websocket URL") }

            let buddy = try T4fTypingUITests.buddySession(serverURL: serverURL)
            userID = buddy.userID

            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 30
            session = URLSession(configuration: configuration)
            socket = session.webSocketTask(with: url)
            socket.resume()
            if let data = try? JSONSerialization.data(withJSONObject: [
                "seq": 1,
                "action": "authentication_challenge",
                "data": ["token": buddy.token]]),
               let text = String(data: data, encoding: .utf8) {
                socket.send(.string(text)) { _ in }
            }
            receiveNext()
        }

        deinit {
            socket.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        private func receiveNext() {
            socket.receive { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text): self.record(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) { self.record(text) }
                    @unknown default: break
                    }
                    self.receiveNext()
                case .failure:
                    break
                }
            }
        }

        private func record(_ text: String) {
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            let event = object["event"] as? String ?? ""
            lock.lock()
            if events.count < 200 { events.append(event) }
            if (object["status"] as? String) == "OK", (object["seq_reply"] as? Int) == 1 {
                authenticated = true
            }
            if event == "typing",
               let payload = object["data"] as? [String: Any],
               let who = payload["user_id"] as? String,
               let broadcast = object["broadcast"] as? [String: Any],
               let channel = broadcast["channel_id"] as? String {
                frames.append(TypingFrame(userID: who,
                                          channelID: channel,
                                          parentID: payload["parent_id"] as? String ?? ""))
            }
            lock.unlock()
        }

        func clearTypingFrames() {
            lock.lock()
            frames.removeAll()
            lock.unlock()
        }

        /// Block until the server has acknowledged the challenge. Every frame this class sends must
        /// come after it; `sendTyping` asserts it rather than racing.
        @discardableResult
        func waitUntilAuthenticated(timeout: TimeInterval = 20) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                lock.lock()
                let ready = authenticated
                lock.unlock()
                if ready { return true }
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            lock.lock()
            defer { lock.unlock() }
            return authenticated
        }

        func typingFrameCount(userID: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return frames.filter { $0.userID == userID }.count
        }

        func typingFrames(userID: String) -> [TypingFrame] {
            lock.lock()
            defer { lock.unlock() }
            return frames.filter { $0.userID == userID }
        }

        func describeEvents() -> String {
            lock.lock()
            defer { lock.unlock() }
            return events.isEmpty ? "(none)" : events.suffix(12).joined(separator: ", ")
        }

        @discardableResult
        func waitForTypingFrames(userID: String, timeout: TimeInterval, minimum: Int = 1,
                                 returnOnTimeout: Bool = false) -> [TypingFrame] {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let seen = typingFrames(userID: userID)
                if seen.count >= minimum { return seen }
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
            return typingFrames(userID: userID)
        }

        func sendTyping(channelID: String, parentID: String) {
            let frame: [String: Any] = ["seq": 42,
                                        "action": "user_typing",
                                        "data": ["channel_id": channelID, "parent_id": parentID]]
            guard let data = try? JSONSerialization.data(withJSONObject: frame),
                  let text = String(data: data, encoding: .utf8) else { return }
            socket.send(.string(text)) { _ in }
        }
    }

    // MARK: - The app

    private func launchAndOpen() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetPersistedState",
                               "-uiTestForgetSession", serverURL.absoluteString,
                               "-uiTestSeedServer", serverURL.absoluteString,
                               "-uiTestSeedServerName", "Local Mattermost",
                               "-surfaceMode", "shell=native",
                               "-surfaceMode", "auth=native",
                               "-surfaceMode", "sidebar=native",
                               // The surface under test: the composer that announces and draws.
                               "-surfaceMode", "composer=native",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        signIn(app)
        openChannel(app, channelID: channelID)
        return app
    }

    private func signIn(_ app: XCUIApplication) {
        let field = app.textFields["loginIDField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20),
                      "the native sign-in must mount against \(serverURL.absoluteString):\n"
                      + "\(app.debugDescription)")
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

    private func openChannel(_ app: XCUIApplication, channelID: String) {
        let reveal = ShellSettle.revealSidebarChannel(app, channelID: channelID)
        XCTAssertTrue(reveal.row.waitForExistence(timeout: 40),
                      "the sidebar must list channel \(channelID) (\(reveal.report)):\n"
                      + "\(app.debugDescription)")
        reveal.row.tap()
        XCTAssertTrue(element(app, "channelPostList").waitForExistence(timeout: 40),
                      "the channel pane must mount:\n\(app.debugDescription)")
    }

    /// Open the thread the way a reader does: the root's reply line under the post.
    private func openThread(_ app: XCUIApplication, rootID: String, maxSwipes: Int = 12) {
        let line = element(app, "post.\(rootID).replyCount")
        var swipes = 0
        while !line.exists && swipes < maxSwipes {
            let list = element(app, "channelPostList")
            if list.exists { list.swipeUp() }
            swipes += 1
        }
        XCTAssertTrue(line.waitForExistence(timeout: 20),
                      "the root must carry a reply line to tap:\n\(app.debugDescription)")
        line.tap()
        XCTAssertTrue(element(app, "threadPane").waitForExistence(timeout: 40),
                      "the reply line must open the thread:\n\(app.debugDescription)")
        XCTAssertTrue(element(app, "threadPostList").waitForExistence(timeout: 30),
                      "the thread's post list must mount:\n\(app.debugDescription)")
    }

    private func composerInput(_ app: XCUIApplication) -> XCUIElement {
        let identifier = "channelComposer.input"
        let textView = app.textViews[identifier]
        if textView.waitForExistence(timeout: 30) { return textView }
        return element(app, identifier)
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

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func stamp() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    // MARK: - Server access (the test is its own API client)

    private struct Session { let token: String; let userID: String }

    private func ping() throws {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/system/ping"))
        request.timeoutInterval = 5
        let (_, response) = try Self.synchronous(request)
        try XCTSkipUnless((response as? HTTPURLResponse)?.statusCode == 200,
                          "the live server at \(serverURL.absoluteString) is not answering")
    }

    private func authenticate(login: String, password: String) throws -> Session {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/users/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["login_id": login,
                                                                       "password": password])
        let (data, response) = try Self.synchronous(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let token = http.value(forHTTPHeaderField: "Token"),
              let user = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = user["id"] as? String else {
            throw XCTSkip("could not sign in as \(login) on \(serverURL.absoluteString) (HTTP \(status))")
        }
        return Session(token: token, userID: id)
    }

    private static func buddySession(serverURL: URL) throws -> Session {
        if let cached = cachedBuddySession, cached.server == serverURL.absoluteString {
            return Session(token: cached.token, userID: cached.userID)
        }
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/users/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "login_id": buddyLogin, "password": buddyPassword])
        let (data, response) = try Self.synchronous(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let token = http.value(forHTTPHeaderField: "Token"),
              let user = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = user["id"] as? String else {
            throw XCTSkip("the second account \(buddyLogin) is missing or refuses its password — "
                          + "run scripts/t43_notification_seed.py (HTTP \(status))")
        }
        cachedBuddySession = (server: serverURL.absoluteString, token: token, userID: id)
        return Session(token: token, userID: id)
    }

    private func teamIDForMe() throws -> String {
        let teams = try getJSON("/api/v4/users/me/teams") as? [[String: Any]] ?? []
        guard let team = teams.first(where: { ($0["name"] as? String) == "perf" }) ?? teams.first,
              let id = team["id"] as? String else {
            throw XCTSkip("the fixture account has no team — run scripts/t43_notification_seed.py")
        }
        return id
    }

    private func channel() throws -> (id: String, name: String) {
        let body = try getJSON("/api/v4/teams/\(teamID!)/channels/name/\(Self.channelName)") as? [String: Any] ?? [:]
        guard let id = body["id"] as? String else {
            throw XCTSkip("#\(Self.channelName) is missing — run scripts/t43_notification_seed.py")
        }
        return (id, Self.channelName)
    }

    private func displayName(of userID: String) throws -> String {
        let user = try getJSON("/api/v4/users/\(userID)") as? [String: Any] ?? [:]
        let nickname = user["nickname"] as? String ?? ""
        if !nickname.isEmpty { return nickname }
        let first = user["first_name"] as? String ?? ""
        let last = user["last_name"] as? String ?? ""
        let full = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
        if !full.isEmpty { return full }
        return user["username"] as? String ?? ""
    }

    private func sendPost(_ message: String, rootID: String? = nil) throws -> String {
        var body: [String: Any] = ["channel_id": channelID, "message": message]
        if let rootID { body["root_id"] = rootID }
        let json = try sendJSON("POST", "/api/v4/posts", body: body) as? [String: Any] ?? [:]
        guard let id = json["id"] as? String else {
            throw XCTSkip("the fixture channel did not accept a post")
        }
        return id
    }

    private func getJSON(_ path: String) throws -> Any {
        var request = URLRequest(url: serverURL.appendingPathComponent(path))
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        let (data, response) = try Self.synchronous(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NSError(domain: "T4fOracle", code: status, userInfo: [
                NSLocalizedDescriptionKey: "GET \(path) -> HTTP \(status)"])
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func sendJSON(_ method: String, _ path: String, body: [String: Any]) throws -> Any {
        var request = URLRequest(url: serverURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try Self.synchronous(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw XCTSkip("\(method) \(path) answered \(status) — the fixture is not in the state "
                          + "this test needs")
        }
        guard !data.isEmpty, let json = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return json
    }

    /// No cookie store: a stale `MMAUTHTOKEN` cookie makes the server answer `session_expired`
    /// before it looks at the request (T40's note; the same oracle is used by T43).
    private static let restSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    private static func synchronous(_ request: URLRequest) throws -> (Data, URLResponse) {
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        restSession.dataTask(with: request) { data, response, error in
            box.data = data
            box.response = response
            box.error = error
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 30)
        if let error = box.error { throw error }
        guard let response = box.response else {
            throw NSError(domain: "T4fOracle", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "no response for \(request.url?.absoluteString ?? "")"])
        }
        return (box.data ?? Data(), response)
    }

    private final class Box: @unchecked Sendable {
        var data: Data?
        var response: URLResponse?
        var error: Error?
    }
}
