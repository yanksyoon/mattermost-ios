// T47 — creating a channel, live, against a **real** Mattermost server (S10 create, S09 create menu).
//
// Why live: every acceptance criterion is a statement about a running server's data —
//   1. the sidebar's `+` opens the create menu, and the menu is what the server's permissions allow;
//   2. the form creates a **private** channel through `POST /channels` — the request that made the row,
//      not a list refresh that happened to include it;
//   3. the app lands **in** the new channel (the pane's title is the display name the reader typed);
//   4. the row is in the sidebar (the channel list re-read from the server);
//   5. the channel is still there after a relaunch, because it came from the server's channel list.
//
// The oracle for 2–5 is the server, read back through its own API with the same account the app signs in
// as: `GET /teams/{tid}/channels/name/{name}` answers 404 **before** the tap and the created channel
// afterwards, with `creator_id` = the signed-in user, `type` = `P` and the `display_name` typed into the
// app. A name that did not exist before and carries a per-run token cannot arrive from a refresh.
//
// The suite carries both halves of the card:
//
//   * `testTheCreateMenuSendsPostChannelsAndTheNewChannelSurvivesRelaunch` — the private-channel form,
//     `POST /channels`, landing in the pane, the sidebar row, and the row surviving a relaunch;
//   * `testTheCreateMenuStartsADirectMessageWithATeammate` — the picker, its search, one tap, and the
//     server's record of the pair (`POST /channels/direct`, type `D`, name `<id>__<id>`). Its oracle
//     call is create-or-find, so it reads the conversation the tap opened rather than writing a new one.
//
// Run (local throwaway server; same credentials as T34/T39/T40):
//
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     python3 scripts/qa-test.py --platform ios --sim <sim> \
//       --only-testing MattermostUITests/T47CreateChannelUITests
//
// Point it at the server **directly** for the verdict. The wire witness that the app itself issued
// `POST /channels` is a second run through `scripts/t47_logging_relay.py` (the app pointed at
// `http://127.0.0.1:8066`), whose request log carries the line — see
// `docs/t47-relay-witness-2026-10-27.log`. That run is evidence, not a second verdict (the same split
// T40 documents for its relay). One caveat learned the hard way: the relay's first version split each
// read on CRLF, so when a read ended mid-header the next request line arrived glued to that header and
// was dropped from the log (`Authorization: Bearer …POST /api/v4/channels HTTP/1.1`). The log that
// missed the create was the relay's bug, not the app's behaviour; the script now searches each
// connection's stream for request lines instead.
//
// The suite creates one channel per run and archives it at the end; a name is never recycled by the
// server, so every run uses a fresh one.

import XCTest

final class T47CreateChannelUITests: XCTestCase {

    /// One admin session per test process: the server rate-limits `/users/login` per IP.
    private static var cachedSession: (server: String, token: String, userID: String)?

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var userID: String!
    private var teamID: String!

    /// The channels this run created, archived in `tearDown` (a channel name is not reusable after an
    /// archive, so a leftover would poison the next run's name space).
    private var createdChannelIDs: [String] = []

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live create-channel test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
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

    override func tearDownWithError() throws {
        for channelID in createdChannelIDs {
            _ = try? sendJSON("DELETE", "/api/v4/channels/\(channelID)", body: nil, allowFailure: true)
        }
    }

    // MARK: - The test

    func testTheCreateMenuSendsPostChannelsAndTheNewChannelSurvivesRelaunch() throws {
        // A per-run name: the server never recycles one, and a token makes "this row came from a list
        // refresh" impossible — the name did not exist when the list was last read.
        let stamp = Int(Date().timeIntervalSince1970)
        let displayName = "T47 UI \(stamp)"
        let urlName = "t47-ui-\(stamp)"
        let startedAt = Int(Date().timeIntervalSince1970 * 1000)

        // The premise, measured: the channel does not exist yet.
        XCTAssertEqual(try statusOfChannelNamed(urlName), 404,
                       "the fixture must not already have \(urlName)")

        let app = launchApp()
        showSidebar(app)

        // 1. The create menu, from the `+` in the channel list header.
        let plus = control(app, "nativeSidebarCreateMenu")
        XCTAssertTrue(plus.waitForExistence(timeout: 30),
                      "the create menu must be offered to an account that may create channels:"
                      + "\n\(app.debugDescription)")
        plus.tap()
        attach(app, "01-create-menu")
        openCreateMenuRow(app, "nativeSidebarCreate.createChannel")

        // 2. The form. The display name drives the URL name (the derivation is unit-tested; here it is
        //    measured against what the server then stores).
        let nameField = app.textFields["createChannel.displayName"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 20),
                      "the create form must mount:\n\(app.debugDescription)")
        nameField.tap()
        nameField.typeText(displayName)

        let urlField = app.textFields["createChannel.urlName"]
        XCTAssertTrue(urlField.waitForExistence(timeout: 10))
        XCTAssertEqual(urlField.value as? String, urlName,
                       "the URL name must be derived from the display name")

        // Private, deliberately: the card's live criterion names a private channel, and it is the kind
        // whose row only the creator can see — the sharpest form of "it came from the server for me".
        selectKind(app, "Private channel")

        let submit = assertButton(app, "createChannel.submit")
        XCTAssertTrue(waitUntil(timeout: 10) { submit.isEnabled },
                      "Create must enable on a valid draft:\n\(app.debugDescription)")
        attach(app, "02-create-form")
        submit.tap()

        // 3. The oracle: `POST /channels` happened. The channel exists, it is mine, it is private, and it
        //    carries the display name typed into the app.
        let channel = try waitForChannel(named: urlName, timeout: 30)
        let channelID = channel["id"] as? String ?? ""
        XCTAssertFalse(channelID.isEmpty, "the server must answer the created channel")
        createdChannelIDs.append(channelID)
        XCTAssertEqual(channel["creator_id"] as? String, userID,
                       "the creator is the signed-in user — the server's record of who sent POST /channels")
        XCTAssertEqual(channel["type"] as? String, "P", "the form asked for a private channel")
        XCTAssertEqual(channel["display_name"] as? String, displayName)
        XCTAssertEqual(channel["team_id"] as? String, teamID)
        let createdAt = channel["create_at"] as? Int ?? 0
        XCTAssertGreaterThanOrEqual(createdAt, startedAt - 1000,
                                    "the channel must have been created by this run, not found in it")

        // 4. The app lands in it: the pane's title is the display name, not the URL slug (the T40-R
        //    defect a stale channel list produced), which also proves the list was reloaded before the
        //    route resolved.
        let title = element(app, "nativeChannelTitle")
        XCTAssertTrue(title.waitForExistence(timeout: 30),
                      "creating must land in the new channel:\n\(app.debugDescription)")
        XCTAssertTrue(waitUntil(timeout: 20) { title.label.contains(displayName) },
                      "the pane must be titled with the channel's display name; it says \"\(title.label)\"")
        attach(app, "03-created-pane")

        // 5. …and the sidebar lists it (the channel list is a server read, so the row is the server's).
        showSidebar(app)
        let row = revealSidebarRow(app, identifier: "channelSidebar.channel.\(channelID)")
        XCTAssertTrue(row.waitForExistence(timeout: 30),
                      "the sidebar must list the channel that was just created:\n\(app.debugDescription)")
        attach(app, "04-sidebar-row")

        // 6. Relaunch. No `-uiTestForgetSession` and no `-uiTestResetPersistedState` this time, so the
        //    app comes back with its stored credential, and the row it draws can only come from
        //    `GET /users/me/teams/{tid}/channels`.
        app.terminate()
        let relaunched = launchApp(keepingState: true)
        showSidebar(relaunched)
        let rowAfterRelaunch = revealSidebarRow(relaunched,
                                                identifier: "channelSidebar.channel.\(channelID)")
        XCTAssertTrue(rowAfterRelaunch.waitForExistence(timeout: 40),
                      "the created channel must survive a relaunch (it lives on the server):"
                      + "\n\(relaunched.debugDescription)")
        attach(relaunched, "05-after-relaunch")

        // The server's own list agrees, one more time, after the relaunch.
        let mine = try getJSON("/api/v4/users/me/teams/\(teamID!)/channels") as? [[String: Any]] ?? []
        XCTAssertTrue(mine.contains { $0["id"] as? String == channelID },
                      "the channel is in my team list, which is what the sidebar draws")
    }

    // MARK: - The direct-message half of the card

    /// The second entry in the `+` menu: *Create a direct message* → the people picker → one tap opens
    /// the conversation.
    ///
    /// The oracle is the server's own record of the pair: `POST /channels/direct` is create-or-find
    /// (measured: `201` on both paths, the same channel id either way), so asking it after the tap is a
    /// read of "this DM exists" rather than a second write. Its `name` is the two user ids sorted and
    /// joined by `__`, which is exactly what the app's tap asked the server for.
    func testTheCreateMenuStartsADirectMessageWithATeammate() throws {
        let teammate = try teammateOnTheTeam()
        let teammateID = teammate["id"] as? String ?? ""
        let username = teammate["username"] as? String ?? ""
        let person = teammate["nickname"] as? String ?? ""
        XCTAssertFalse(teammateID.isEmpty, "a team with one member cannot exercise the picker")

        let app = launchApp()
        showSidebar(app)

        // 1. The `+` → the DM entry. The row exists only if the reader may create direct channels.
        let plus = control(app, "nativeSidebarCreateMenu")
        XCTAssertTrue(plus.waitForExistence(timeout: 30),
                      "the create menu must be offered:\n\(app.debugDescription)")
        plus.tap()
        openCreateMenuRow(app, "nativeSidebarCreate.createDirectMessage")

        // 2. The picker, and the person in it. Typing exercises the search path; an untyped picker's
        //    list is a `GET /users?in_team` read, and either way the row carries the user's id.
        let sheet = element(app, "newDM.sheet")
        if !sheet.waitForExistence(timeout: 20) {
            // Second attempt at the same two taps: a dialog that is still dismissing when its row is
            // tapped can swallow the selection (measured under a relay hop, see the file header). The
            // assertion below is unchanged — the sheet still has to mount.
            openCreateMenuRow(app, "nativeSidebarCreate.createDirectMessage")
            XCTAssertTrue(sheet.waitForExistence(timeout: 20),
                          "the create-a-direct-message sheet must mount:\n\(app.debugDescription)")
        }
        let search = app.searchFields.firstMatch
        if search.waitForExistence(timeout: 10) {
            search.tap()
            search.typeText(username)
        }
        let row = element(app, "newDM.row.\(teammateID)")
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "the picker must list @\(username):\n\(app.debugDescription)")
        attach(app, "06-dm-picker")
        row.tap()

        // 3. The conversation is on show, titled with the person.
        let title = element(app, "nativeChannelTitle")
        XCTAssertTrue(title.waitForExistence(timeout: 30),
                      "starting a DM must land in the conversation:\n\(app.debugDescription)")
        let wanted = [username, person].filter { !$0.isEmpty }.map { $0.lowercased() }
        XCTAssertTrue(waitUntil(timeout: 20) {
            let label = title.label.lowercased()
            return wanted.contains { label.contains($0) }
        }, "the DM pane must be titled with the person (@\(username)); it says \"\(title.label)\"")
        attach(app, "07-dm-open")

        // 4. The server's record of the pair.
        let channel = try directChannel(with: teammateID)
        let channelID = channel["id"] as? String ?? ""
        XCTAssertFalse(channelID.isEmpty, "the server must answer the DM channel")
        XCTAssertEqual(channel["type"] as? String, "D", "a direct message is type D")
        XCTAssertEqual(channel["name"] as? String, directChannelName(with: teammateID),
                       "the DM channel is named after both users")
        let members = try getJSON("/api/v4/channels/\(channelID)/members") as? [[String: Any]] ?? []
        let memberIDs = Set(members.compactMap { $0["user_id"] as? String })
        XCTAssertTrue(memberIDs.contains(teammateID) && memberIDs.contains(userID!),
                      "the conversation has exactly the two people in it: \(memberIDs)")

        // 5. …and it is in the sidebar, read back from the server after the relaunch-free refresh.
        showSidebar(app)
        let sidebarRow = revealSidebarRow(app, identifier: "channelSidebar.channel.\(channelID)")
        XCTAssertTrue(sidebarRow.waitForExistence(timeout: 30),
                      "the sidebar must list the conversation that was just opened:"
                      + "\n\(app.debugDescription)")
        attach(app, "08-dm-sidebar-row")
    }

    // MARK: - App driving

    /// Launch the app against the fixture.
    ///
    /// - Parameter keepingState: `false` (first launch) wipes the shell's persisted stores and forgets the
    ///   session so the run starts from the sign-in screen; `true` (the relaunch) keeps them, which is the
    ///   only way "it survived a relaunch" means anything.
    private func launchApp(keepingState: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["-uiTestSeedServer", serverURL.absoluteString,
                         "-uiTestSeedServerName", "Local Mattermost",
                         "-surfaceMode", "shell=native",
                         "-surfaceMode", "auth=native",
                         "-surfaceMode", "sidebar=native",
                         "-surfaceMode", "channelInfo=native",
                         "-uiTestLogLevel", "error",
                         "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if !keepingState {
            arguments = ["-uiTestResetPersistedState",
                         "-uiTestForgetSession", serverURL.absoluteString] + arguments
        }
        app.launchArguments = arguments
        // libtrace quarantines an app process that logs too much (see T40's note); this is the volume knob
        // that stops the mid-run snapshot crash. Test-only.
        app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"
        app.launch()
        if !keepingState || app.textFields["loginIDField"].waitForExistence(timeout: 10) {
            signIn(app, login: loginID, password: password)
        }
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

    /// The segmented Public/Private control. Its segments are ordinary buttons carrying the type's label.
    private func selectKind(_ app: XCUIApplication, _ label: String) {
        let segment = app.buttons[label]
        if segment.waitForExistence(timeout: 10), segment.isHittable {
            segment.tap()
            return
        }
        // A one-kind account draws the fixed `LabeledContent` instead of a picker; then there is nothing
        // to choose and the test says so rather than tapping a control that does not exist.
        XCTAssertTrue(element(app, "createChannel.kindFixed").exists,
                      "the form must offer a kind (a picker or a fixed value):\n\(app.debugDescription)")
    }

    /// Leave the pushed channel pane and show the channel sidebar again (T40's rule: a sidebar row can
    /// only be asserted when the sidebar is the screen on show).
    ///
    /// On compact the channel is a push above the tab bar (`docs/t95-shell-tab-bar-decision.md` §2 D1),
    /// so the reader's route back is `Back`, then the `Channels` tab; the split layout has no bar and
    /// nothing to pop. `ShellSettle.tapTab` is both shapes in one call (T95-B).
    private func showSidebar(_ app: XCUIApplication) {
        if element(app, "nativeSidebar").exists { return }
        if !ShellSettle.tapTab(ShellSettle.Tab.channels, in: app, wait: 5) {
            let back = app.navigationBars.firstMatch.buttons.element(boundBy: 0)
            if back.exists, back.isHittable { back.tap() }
        }
        XCTAssertTrue(element(app, "nativeSidebar").waitForExistence(timeout: 20),
                      "the shell must be back on the channel sidebar:\n\(app.debugDescription)")
    }

    /// Scroll the sidebar until `identifier` exists (a lazy `List` only builds its viewport).
    @discardableResult
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

    // MARK: - Server

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
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let issued = http.value(forHTTPHeaderField: "Token"),
              let user = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = user["id"] as? String else {
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])??["id"] as? String
            throw XCTSkip("could not sign in as \(login) on \(serverURL.absoluteString) "
                          + "(HTTP \(status), \(reason ?? "no error id"))")
        }
        return (issued, id)
    }

    private func firstTeamID() throws -> String {
        let teams = try getJSON("/api/v4/users/me/teams") as? [[String: Any]] ?? []
        guard let team = teams.first, let id = team["id"] as? String else {
            throw XCTSkip("the fixture account has no team")
        }
        return id
    }

    /// The status of `GET /teams/{tid}/channels/name/{name}`: 404 before the tap, 200 after.
    private func statusOfChannelNamed(_ name: String) throws -> Int {
        var request = URLRequest(url: url(for: "/api/v4/teams/\(teamID!)/channels/name/\(name)"))
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        let (_, response) = try synchronous(request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    /// Wait for the channel to exist, then answer its server record.
    private func waitForChannel(named name: String, timeout: TimeInterval) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let channel = try? getJSON("/api/v4/teams/\(teamID!)/channels/name/\(name)") as? [String: Any],
               let id = channel["id"] as? String, !id.isEmpty {
                return channel
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTFail("no channel named \(name) appeared within \(Int(timeout))s — POST /channels never landed")
        return [:]
    }

    /// A teammate the picker can offer: on the team, not me, not a bot, not deactivated.
    private func teammateOnTheTeam() throws -> [String: Any] {
        let users = try getJSON("/api/v4/users?in_team=\(teamID!)&page=0&per_page=60") as? [[String: Any]] ?? []
        let candidate = users.first { user in
            (user["id"] as? String) != userID
                && (user["delete_at"] as? Int ?? 0) == 0
                && (user["is_bot"] as? Bool ?? false) == false
        }
        guard let candidate else {
            throw XCTSkip("the fixture team has no second member to start a DM with")
        }
        return candidate
    }

    /// The DM channel for a pair — create-or-find, so this answers the existing conversation unchanged.
    private func directChannel(with otherID: String) throws -> [String: Any] {
        let answer = try sendJSON("POST", "/api/v4/channels/direct", body: [userID!, otherID])
        return answer as? [String: Any] ?? [:]
    }

    /// `POST /channels/direct` names the pair's channel `<id>__<id>`, ids sorted (measured).
    private func directChannelName(with otherID: String) -> String {
        [userID, otherID].sorted().joined(separator: "__")
    }

    private func url(for path: String) -> URL {
        let halves = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let base = serverURL.appendingPathComponent(String(halves[0]))
        guard halves.count == 2, !halves[1].isEmpty,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return base
        }
        components.percentEncodedQuery = String(halves[1])
        return components.url ?? base
    }

    private func getJSON(_ path: String) throws -> Any {
        var request = URLRequest(url: url(for: path))
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        let (data, response) = try synchronous(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NSError(domain: "T47Oracle", code: status, userInfo: [
                NSLocalizedDescriptionKey:
                    "GET \(path) -> HTTP \(status) \(String(decoding: data.prefix(200), as: UTF8.self))"])
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    @discardableResult
    private func sendJSON(_ method: String, _ path: String, body: Any?,
                          allowFailure: Bool = false) throws -> Any {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = method
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try synchronous(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !allowFailure, !(200...299).contains(status) {
            throw XCTSkip("\(method) \(path) answered \(status)")
        }
        guard !data.isEmpty, let json = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return json
    }

    /// The oracle's own session — no cookie store (a stale `MMAUTHTOKEN` cookie makes a correct login
    /// read as `session_expired`, measured in T40).
    private static let restSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

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

    // MARK: - Element helpers

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func control(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        let typed = app.buttons.matching(identifier: identifier).firstMatch
        return typed.exists ? typed : element(app, identifier)
    }

    private func assertButton(_ app: XCUIApplication, _ identifier: String,
                              timeout: TimeInterval = 10) -> XCUIElement {
        let typed = app.buttons.matching(identifier: identifier).firstMatch
        XCTAssertTrue(typed.waitForExistence(timeout: timeout),
                      "\(identifier) must exist as a button, not just a container:\n\(app.debugDescription)")
        return typed
    }

    /// Open a row of the `+` menu, re-opening the menu if it was not up yet. A confirmation dialog
    /// takes a moment to mount (measured: it misses a 5 s `tapControl` under a relay hop), so the row is
    /// waited for, not tapped blind.
    private func openCreateMenuRow(_ app: XCUIApplication, _ identifier: String) {
        let row = app.buttons.matching(identifier: identifier).firstMatch
        for _ in 0..<3 {
            if row.waitForExistence(timeout: 10), row.isHittable {
                row.tap()
                return
            }
            let plus = control(app, "nativeSidebarCreateMenu")
            if plus.waitForExistence(timeout: 10), plus.isHittable { plus.tap() }
        }
        XCTFail("the create menu must offer \(identifier):\n\(app.debugDescription)")
    }

    private func tapControl(_ app: XCUIApplication, _ identifier: String) {
        let typed = app.buttons.matching(identifier: identifier).firstMatch
        if typed.waitForExistence(timeout: 5), typed.isHittable {
            typed.tap()
            return
        }
        let fallback = element(app, identifier)
        if fallback.waitForExistence(timeout: 5) { fallback.tap() }
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
