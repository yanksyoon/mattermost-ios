// T44d — the native calls surface against a **real** Mattermost server with the real Calls plugin.
//
// Why live: the surface's whole job is to make a *server-side* thing happen. A stub could show that
// a sheet opens; only the real plugin can say whether the app's `join` created a call, and only the
// real plugin can say whether leaving ended it. So every assertion here is checked twice: once in
// the accessibility tree (what the reader sees) and once over REST
// (`GET /plugins/com.mattermost.calls/calls/{id}/active` — the same route the join button's own gate
// reads, measured on 0.29.8 in docs/t44d-build-note.md §3).
//
// Run (fixture with the Calls plugin installed; same accounts as T34/T39/T40/T41/T42):
//
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     python3 scripts/qa-test.py --platform ios --sim "name=iPhone 16 Pro" \
//       --only-testing MattermostUITests/T44DCallsUITests
//
// The surface is **not** native-by-default (`.calls` is absent from
// `SurfaceDefaults.nativeApprovedSurfaces` until its `-AV` card passes), so the app is launched with
// `-surfaceMode calls=native` — the same flag every other screen card's live suite uses to put its
// own surface on show without touching the release default.
//
// What this suite deliberately does **not** assert: that remote audio arrives, and that a second
// participant's tile appears. Both need a second WebRTC peer, and this card's peer-oracle work
// belongs to the `-AV` pass (a peer that offers SDP from the test process would duplicate the
// engine's own signalling). The transition to "In call" is asserted but tolerated as a skip when
// ICE cannot complete on the runner host — see `waitForLiveState`.
//
// Each test skips — never fails — when the environment or the server is missing, and attaches
// screenshots so a run leaves visual evidence next to the machine verdict.

import XCTest

final class T44DCallsUITests: XCTestCase {

    /// One admin session per test process: the server rate-limits logins by IP (as in T40/T41/T42).
    private static var cachedSession: (server: String, token: String, userID: String)?
    private static let restSession = URLSession(configuration: .ephemeral)

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var userID: String!
    private var teamID: String!

    private let channelName = "t44-calls"

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live calls test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        try ping()
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

    // MARK: - 1. Start a call from the channel header

    /// The header button starts a call and the **server** agrees one exists; leaving ends it and the
    /// server agrees about that too.
    ///
    /// This is the flow that was broken by construction in the first cut of this card: an entry
    /// point that only appeared when a call already existed could never start one.
    func testStartCallCreatesTheCallOnTheServerAndLeaveEndsIt() throws {
        let channel = try ensureCallChannel()
        try endAnyCall(in: channel.id)

        let app = launchApp()
        openChannel(app, id: channel.id, name: channel.displayName)

        let button = element(app, "calls.joinButton")
        XCTAssertTrue(button.waitForExistence(timeout: 30),
                      "the channel header must offer Calls when the surface is native:\n"
                      + "\(app.debugDescription)")
        XCTAssertEqual(button.value as? String, "idle",
                       "with no call running the button starts one")
        XCTAssertEqual(button.label, "Start call")
        attach(app, "01-header-start")

        button.tap()
        XCTAssertTrue(element(app, "callsSurface").waitForExistence(timeout: 30),
                      "tapping Start call must mount the call surface:\n\(app.debugDescription)")
        attach(app, "02-surface-joining")

        // The reader's own tile exists, marked as theirs.
        let myTile = element(app, "calls.tile.\(userID!)")
        XCTAssertTrue(myTile.waitForExistence(timeout: 30),
                      "the reader's own session must be drawn:\n\(app.debugDescription)")
        XCTAssertTrue((myTile.label).contains("(you)"), "own tile reads \"(you)\": \(myTile.label)")
        XCTAssertEqual(element(app, "calls.participants").exists, true)

        // The server-side truth: the app's join created a call in this channel.
        XCTAssertTrue(try waitForServerActiveCall(channel.id, timeout: 20),
                      "the plugin must report an active call after the app joined "
                      + "(`GET …/calls/\(channel.id)/active`)")

        // The state line advances past the first beat, wherever ICE lands on this host.
        let live = try waitForLiveState(app)
        attach(app, "03-surface-\(live.replacingOccurrences(of: " ", with: "-"))")

        // Leaving ends it: the surface goes, and so does the server's call (nothing else is in it).
        element(app, "calls.leaveButton").tap()
        XCTAssertTrue(waitUntil(timeout: 25) { !element(app, "callsSurface").exists },
                      "leaving must dismiss the call surface:\n\(app.debugDescription)")
        XCTAssertTrue(try waitForServerActiveCall(channel.id, timeout: 20, expected: false),
                      "leaving the last participant must end the call on the server")
        attach(app, "04-after-leave")
    }

    /// Mute is a round trip to the plugin, and the control reflects what the app believes: a tap
    /// flips it, and it stays flipped across the next snapshot read (the state is not a local
    /// toggle that the engine's poll immediately overwrites).
    ///
    /// The round trip is checked **on the server side**, not from the app's own state: a second
    /// socket for the same account watches the plugin's broadcasts and must see
    /// `user_unmuted` / `user_muted` carrying this channel and this user. Measured on 0.29.8
    /// (`docs/t44d-build-note.md` §2.1); the names are `user_muted` / `user_unmuted`, not
    /// `user_mute` / `user_unmute`.
    func testMuteSurvivesTheSnapshotAndLeaveEndsTheCall() throws {
        let channel = try ensureCallChannel()
        try endAnyCall(in: channel.id)

        let app = launchApp()
        openChannel(app, id: channel.id, name: channel.displayName)
        let button = element(app, "calls.joinButton")
        XCTAssertTrue(button.waitForExistence(timeout: 30), "the header must offer Calls")
        button.tap()
        XCTAssertTrue(element(app, "callsSurface").waitForExistence(timeout: 30))

        let mute = element(app, "calls.muteButton")
        XCTAssertTrue(mute.waitForExistence(timeout: 30), "the control bar must offer mute")
        XCTAssertEqual(mute.value as? String, "muted",
                       "a session joins muted (measured: `unmuted: false`)")
        XCTAssertEqual(mute.label, "Unmute")

        // The oracle: the plugin's own words, watched from a socket the app does not own.
        let observer = CallsSocketObserver(server: serverURL, token: token)
        observer.start()
        defer { observer.stop() }

        mute.tap()
        XCTAssertTrue(waitUntil(timeout: 15) { (mute.value as? String) == "unmuted" },
                      "the mute control must flip to unmuted:\n\(app.debugDescription)")
        XCTAssertEqual(mute.label, "Mute")
        XCTAssertTrue(observer.wait(for: "user_unmuted", channelID: channel.id, userID: userID,
                                    timeout: 20),
                      "the server must broadcast `user_unmuted` for this channel/user — saw "
                      + "\(observer.names())\n\(app.debugDescription)")
        attach(app, "05-unmuted")

        // And back: the other direction is a round trip too, not a local flip. Done immediately
        // after the first direction: the two taps belong to one observation.
        mute.tap()
        XCTAssertTrue(waitUntil(timeout: 15) { (mute.value as? String) == "muted" },
                      "the control must flip back to muted:\n\(app.debugDescription)")
        XCTAssertTrue(observer.wait(for: "user_muted", channelID: channel.id, userID: userID,
                                    timeout: 20),
                      "the server must broadcast `user_muted` for this channel/user — saw "
                      + "\(observer.names())\n\(app.debugDescription)")

        // Still muted after the engine's next few snapshots: the server's `user_muted` is not being
        // clobbered by a stale `call_state` (the defect the T44d live run measured, now folded in
        // the engine — `CallsEngine.fold`).
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertEqual(mute.value as? String, "muted",
                       "the mute state must survive the snapshot refresh")

        element(app, "calls.leaveButton").tap()
        XCTAssertTrue(waitUntil(timeout: 25) { !element(app, "callsSurface").exists },
                      "leaving must dismiss the surface")
        XCTAssertTrue(try waitForServerActiveCall(channel.id, timeout: 20, expected: false),
                      "the server must agree the call ended")
    }

    // MARK: - Surface state

    /// Wait for the state line to stop saying "Joining…", and return what it says.
    ///
    /// "In call" needs ICE to complete against the plugin's SFU. On a runner where that cannot
    /// happen (no route to the SFU's UDP port — the T44b spike measured this host's behaviour), the
    /// honest outcome is a skip that names the state actually reached, not a failure that blames the
    /// surface for the network.
    private func waitForLiveState(_ app: XCUIApplication) throws -> String {
        let state = element(app, "calls.state")
        XCTAssertTrue(state.waitForExistence(timeout: 20), "the state line must be drawn")
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            let text = (state.value as? String) ?? state.label
            if text == "In call" { return text }
            if text.hasPrefix("Call failed") || text == "Call ended" {
                throw XCTSkip("the call did not come up on this host — state: \(text)")
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        let observed = (state.value as? String) ?? state.label
        throw XCTSkip("ICE did not complete within 60 s on this host — state: \(observed)")
    }

    // MARK: - Launch

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetPersistedState",
                               "-uiTestForgetSession", serverURL.absoluteString,
                               "-uiTestSeedServer", serverURL.absoluteString,
                               "-uiTestSeedServerName", "Local Mattermost",
                               "-surfaceMode", "shell=native",
                               "-surfaceMode", "auth=native",
                               "-surfaceMode", "sidebar=native",
                               "-surfaceMode", "calls=native",
                               // The join button re-asks the server this often; the live test needs
                               // the flip from Start to Join to be quick, a person never sets it.
                               "-uiTestCallsPollInterval", "3",
                               "-uiTestLogLevel", "error",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"
        app.launch()
        signIn(app, login: loginID, password: password)
        return app
    }

    private func signIn(_ app: XCUIApplication, login: String, password: String) {
        let field = app.textFields["loginIDField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20),
                      "the native sign-in must mount against \(serverURL.absoluteString):\n"
                      + "\(app.debugDescription)")
        field.tap()
        field.typeText(login)
        let secret = app.secureTextFields["loginPasswordField"]
        XCTAssertTrue(secret.exists)
        secret.tap()
        secret.typeText(password)
        app.buttons["loginSubmitButton"].tap()
        XCTAssertTrue(element(app, "nativeShell").waitForExistence(timeout: 40),
                      "signing in must reach the shell:\n\(app.debugDescription)")
    }

    /// The channel, opened from the sidebar by its own id — the row is what a reader taps.
    private func openChannel(_ app: XCUIApplication, id: String, name: String) {
        let row = revealSidebarRow(app, identifier: "channelSidebar.channel.\(id)")
        XCTAssertTrue(row.waitForExistence(timeout: 40),
                      "#\(name) must be listed in the sidebar:\n\(app.debugDescription)")
        row.tap()
        XCTAssertTrue(element(app, "nativeChannelTitle").waitForExistence(timeout: 30),
                      "the channel pane must mount:\n\(app.debugDescription)")
    }

    private func revealSidebarRow(_ app: XCUIApplication, identifier: String,
                                  maxSwipes: Int = 25) -> XCUIElement {
        let target = element(app, identifier)
        if target.waitForExistence(timeout: 15) { return target }
        let container = app.collectionViews.firstMatch
        guard container.exists else { return target }
        var swipes = 0
        while !target.exists, swipes < maxSwipes {
            container.swipeUp(velocity: .fast)
            swipes += 1
        }
        return target
    }

    // MARK: - Fixtures

    private struct Channel { let id: String; let displayName: String }

    /// The channel the suite calls in, created if the fixture does not have it yet.
    private func ensureCallChannel() throws -> Channel {
        var row = (try? getJSON("/api/v4/teams/\(teamID!)/channels/name/\(channelName)"))
            as? [String: Any]
        if row == nil {
            _ = try? postJSON("/api/v4/channels", body: ["team_id": teamID!,
                                                         "name": channelName,
                                                         "display_name": "T44 Calls",
                                                         "type": "O"])
            row = (try? getJSON("/api/v4/teams/\(teamID!)/channels/name/\(channelName)"))
                as? [String: Any]
        }
        guard let id = row?["id"] as? String else {
            throw XCTSkip("could not create or read #\(channelName) on \(serverURL.absoluteString)")
        }
        return Channel(id: id, displayName: row?["display_name"] as? String ?? channelName)
    }

    /// Whether the plugin says a call is running in `channelID` (`{"active": bool}`).
    private func serverCallActive(_ channelID: String) throws -> Bool {
        let body = try getJSON("/plugins/com.mattermost.calls/calls/\(channelID)/active")
        guard let object = body as? [String: Any], let active = object["active"] as? Bool else {
            throw XCTSkip("the Calls plugin did not answer the active-call route — is it installed?")
        }
        return active
    }

    private func waitForServerActiveCall(_ channelID: String, timeout: TimeInterval,
                                         expected: Bool = true) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var last = false
        while Date() < deadline {
            last = try serverCallActive(channelID)
            if last == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return last == expected
    }

    /// A previous run that was killed leaves its session in the call (the server only drops it on a
    /// clean leave), which would make "the app started this call" unfalsifiable. There is no REST
    /// route to end a call on 0.29.8, so a stuck call is a skip with the reason, not a failure.
    private func endAnyCall(in channelID: String) throws {
        if try serverCallActive(channelID) {
            throw XCTSkip("#\(channelName) already has a call from an earlier run "
                          + "(it has no REST route to end it on Calls 0.29.8) — "
                          + "restart the fixture or leave the call in another client")
        }
    }

    // MARK: - REST

    private func url(for path: String) -> URL { serverURL.appendingPathComponent(path) }

    private func ping() throws {
        var request = URLRequest(url: url(for: "api/v4/system/ping"))
        request.timeoutInterval = 10
        let (_, response) = try synchronous(request)
        try XCTSkipUnless((response as? HTTPURLResponse)?.statusCode == 200,
                          "no Mattermost server at \(serverURL.absoluteString)")
    }

    private func authenticate(login: String, password: String) throws -> (token: String,
                                                                          userID: String) {
        var request = URLRequest(url: url(for: "api/v4/users/login"))
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
            throw XCTSkip("could not sign in as \(login) on \(serverURL.absoluteString) "
                          + "(HTTP \(status))")
        }
        return (token, id)
    }

    private func firstTeamID() throws -> String {
        let body = try getJSON("/api/v4/users/me/teams")
        guard let teams = body as? [[String: Any]],
              let id = teams.first?["id"] as? String else {
            throw XCTSkip("\(loginID!) is not a member of a team on this server")
        }
        return id
    }

    private func getJSON(_ path: String) throws -> Any {
        var request = URLRequest(url: url(for: path))
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        let (data, response) = try synchronous(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NSError(domain: "T44dOracle", code: status, userInfo: [
                NSLocalizedDescriptionKey: "GET \(path) -> HTTP \(status) "
                    + String(decoding: data.prefix(200), as: UTF8.self)])
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func postJSON(_ path: String, body: Any?) throws -> Any {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try synchronous(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw XCTSkip("POST \(path) answered \(status)")
        }
        guard !data.isEmpty, let json = try? JSONSerialization.jsonObject(with: data) else {
            return [:]
        }
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

    // MARK: - Element plumbing

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
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// A websocket the **test** owns, for the same account the app is signed in as.
///
/// This is the only honest way to assert that a control reached the server: the app's own state
/// could be an optimistic local flip, so the oracle has to be the plugin's broadcast. Measured on
/// Calls 0.29.8 (`docs/t44d-build-note.md` §2.1): participation events are
/// `custom_com.mattermost.calls_user_muted` / `…_user_unmuted` with
/// `{channelID, session_id, userID}`, and a second socket of the same account receives them.
final class CallsSocketObserver {

    private static let prefix = "custom_com.mattermost.calls_"

    private let task: URLSessionWebSocketTask
    private let session: URLSession
    private let lock = NSLock()
    private var events: [(name: String, channelID: String?, userID: String?)] = []
    private var loop: Task<Void, Never>?

    init(server: URL, token: String) {
        var components = URLComponents(url: server.appendingPathComponent("api/v4/websocket"),
                                       resolvingAgainstBaseURL: false)!
        components.scheme = (server.scheme == "https") ? "wss" : "ws"
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        session = URLSession(configuration: .ephemeral)
        task = session.webSocketTask(with: request)
    }

    func start() {
        task.resume()
        loop = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    switch try await self.task.receive() {
                    case .string(let text): self.ingest(text)
                    case .data(let data): self.ingest(String(decoding: data, as: UTF8.self))
                    @unknown default: break
                    }
                } catch {
                    return  // closed or failed: the run's assertions report what was seen
                }
            }
        }
    }

    private func ingest(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["event"] as? String,
              raw.hasPrefix(Self.prefix) else { return }
        let payload = object["data"] as? [String: Any] ?? [:]
        lock.lock()
        events.append((name: String(raw.dropFirst(Self.prefix.count)),
                       channelID: payload["channelID"] as? String
                           ?? payload["channel_id"] as? String,
                       userID: payload["userID"] as? String ?? payload["user_id"] as? String))
        lock.unlock()
    }

    /// Plugin event names seen so far, prefix stripped — part of the failure message, so a wrong
    /// name reads as "saw user_mute" instead of a bare timeout.
    func names() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return events.map(\.name)
    }

    /// Wait for one event by name, optionally narrowed to a channel and user.
    func wait(for name: String, channelID: String, userID: String,
              timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let hit = events.contains {
                $0.name == name
                    && ($0.channelID == nil || $0.channelID == channelID)
                    && ($0.userID == nil || $0.userID == userID)
            }
            lock.unlock()
            if hit { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    func stop() {
        loop?.cancel()
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }
}
