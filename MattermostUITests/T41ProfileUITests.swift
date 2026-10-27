// T41 — the profile / presence / custom-status surface against a **real** Mattermost server.
//
// Why live: every acceptance criterion of the card is a statement about a running server's data —
//   1. the popover shows *that* account's identity (display name, username, local time, member since),
//      read from `GET /users/{id}`, not from anything this file knows;
//   2. choosing a presence writes it (`PUT /users/{id}/status`), and the server then reports it;
//   3. a custom status round-trips through `PUT /users/{id}/status/custom` and survives a re-read of
//      `GET /users/{id}` (the account's own profile is *not* sanitised, so `props.customStatus` is the
//      oracle), and clearing it removes it;
//   4. "Send message" creates/opens the direct channel and lands in it — the server's channel list is
//      the oracle for "a DM between these two accounts now exists".
//
// A stub could only prove this file's own fixtures render. The oracle for each assertion is the server,
// read back through its own API with the same account the app signs in as.
//
// Run (local throwaway server; same fixture account as T34/T39/T40):
//
//     python3 scripts/t41_profile_seed.py --url http://127.0.0.1:8065
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     python3 scripts/qa-test.py --platform ios --sim <sim> \
//       --only-testing MattermostUITests/T41ProfileUITests
//
// `scripts/t41_profile_seed.py` puts the fixture in the state these tests need (a second account
// `t41buddy`, a shared channel `t41-profile`, one post by that account, and the probe account back to
// online with no custom status). Each test skips — never fails — when the environment or the server is
// missing, like every live test here. Nothing is fabricated: a skipped test is reported as skipped.
//
// Screenshots: each test attaches one, so a run leaves visual evidence next to the machine verdict.

import XCTest

final class T41ProfileUITests: XCTestCase {

    /// One admin session per test process; the server rate-limits logins by IP (same reason as T40).
    private static var cachedAdminSession: (server: String, token: String, userID: String)?

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var userID: String!
    private var teamID: String!

    private let channelName = "t41-profile"
    private let buddyLogin = "t41buddy"
    private let buddyPostText = "Hello from t41buddy — tap my avatar."

    /// The buddy's fixture password. `scripts/t41_profile_seed.py` creates the account with it; the
    /// live test signs in as the buddy to change **that account's** status, which is the only way to
    /// produce a `status_change` frame from another client without a second simulator.
    private var buddyPassword: String {
        ProcessInfo.processInfo.environment["MM_AUTH_BUDDY_PASSWORD"] ?? "T41-Buddy-Not-A-Real-Secret-1"
    }

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live profile test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        try ping()
        if let cached = Self.cachedAdminSession, cached.server == raw {
            token = cached.token
            userID = cached.userID
        } else {
            let session = try authenticate(login: loginID, password: password)
            token = session.token
            userID = session.userID
            Self.cachedAdminSession = (server: raw, token: session.token, userID: session.userID)
        }
        teamID = try firstTeamID()
    }

    // MARK: - 1. The popover shows the server's own identity

    func testProfilePopoverShowsTheServersOwnIdentity() throws {
        let me = try getJSON("/api/v4/users/\(userID!)") as? [String: Any] ?? [:]
        let expectedName = [me["first_name"] as? String ?? "", me["last_name"] as? String ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let expectedUsername = me["username"] as? String ?? ""
        try XCTSkipUnless(!expectedName.isEmpty && !expectedUsername.isEmpty,
                          "the fixture account has no name of its own to display")

        let app = launchApp()
        openChannel(app, channelID: try channelID())
        openMyProfile(app)

        let name = element(app, "profile.name")
        XCTAssertTrue(name.waitForExistence(timeout: 20),
                      "the profile sheet must mount:\n\(app.debugDescription)")
        XCTAssertEqual(name.label, expectedName, "the name comes from the server, not from the app")
        XCTAssertEqual(element(app, "profile.username").label, "@\(expectedUsername)")
        XCTAssertTrue(element(app, "profile.presence").exists,
                      "a presence line is part of the card")
        // The zone line is derived from `timezone.automaticTimezone`, which the fixture has.
        let localTime = element(app, "profile.localTime")
        XCTAssertTrue(localTime.exists, "the local-time row was expected:\n\(app.debugDescription)")
        XCTAssertFalse(element(app, "profile.message").exists,
                       "your own profile offers no message shortcut")
        XCTAssertTrue(element(app, "profile.messageReason").exists,
                      "…it says why instead of showing nothing")

        attach(app, "t41-my-profile")
    }

    // MARK: - 2. Presence reaches the server

    func testChoosingDoNotDisturbReachesTheServer() throws {
        let app = launchApp()
        openChannel(app, channelID: try channelID())
        openMyProfile(app)

        let setStatus = element(app, "profile.setStatus")
        XCTAssertTrue(setStatus.waitForExistence(timeout: 20),
                      "the profile offers a status control:\n\(app.debugDescription)")
        setStatus.tap()

        let dnd = element(app, "statusSetter.option.dnd")
        XCTAssertTrue(dnd.waitForExistence(timeout: 20),
                      "the status setter must mount:\n\(app.debugDescription)")
        dnd.tap()

        // The oracle: the server's own status record for this account.
        let confirmed = waitUntil(timeout: 25) {
            let status = (try? self.getJSON("/api/v4/users/\(self.userID!)/status") as? [String: Any]) ?? nil
            return status?["status"] as? String == "dnd"
        }
        XCTAssertTrue(confirmed,
                      "the server must report dnd after the tap; it reports "
                      + "\((try? getJSON("/api/v4/users/\(userID!)/status")) ?? "nothing")")

        // …and a manual flag: the account chose it, the client did not age into it.
        let status = try getJSON("/api/v4/users/\(userID!)/status") as? [String: Any] ?? [:]
        XCTAssertEqual(status["manual"] as? Bool, true, "a chosen status is manual on the server")

        // Put the fixture back so the next test starts from a known presence.
        _ = try? sendJSON("PUT", "/api/v4/users/\(userID!)/status",
                          body: ["user_id": userID!, "status": "online"], allowFailure: true)
        attach(app, "t41-presence-dnd")
    }

    // MARK: - 3. A custom status round-trips and clears

    func testCustomStatusIsStoredThenClearedOnTheServer() throws {
        // Start from no status: the assertion below is about this test's write, not a leftover.
        _ = try? sendJSON("DELETE", "/api/v4/users/\(userID!)/status/custom", body: nil,
                          allowFailure: true)

        let app = launchApp()
        openChannel(app, channelID: try channelID())
        openMyProfile(app)

        let editor = element(app, "profile.customStatusRow")
        XCTAssertTrue(editor.waitForExistence(timeout: 20),
                      "the profile offers a custom-status row:\n\(app.debugDescription)")
        editor.tap()

        let emoji = element(app, "customStatus.emoji.coffee")
        XCTAssertTrue(emoji.waitForExistence(timeout: 10),
                      "the palette must offer the coffee emoji:\n\(app.debugDescription)")
        emoji.tap()

        let field = app.textFields["customStatus.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 20),
                      "the custom-status editor must mount:\n\(app.debugDescription)")
        field.tap()
        let wanted = "Reviewing T41"
        field.typeText(wanted)
        element(app, "customStatus.save").tap()

        // The oracle is the account's own profile: `props.customStatus` is the stored JSON, and it is
        // *not* sanitised for the account itself (measured on 9.11.19).
        let stored = waitUntil(timeout: 25) {
            let profile = (try? self.getJSON("/api/v4/users/\(self.userID!)") as? [String: Any]) ?? nil
            let raw = profile?["props"] as? [String: Any]
            return (raw?["customStatus"] as? String ?? "").contains(wanted)
        }
        var observedProps = "none"
        if let profile = try? getJSON("/api/v4/users/\(userID!)") as? [String: Any] {
            observedProps = "\(profile["props"] ?? "none")"
        }
        XCTAssertTrue(stored,
                      "the server must hold the custom status; props were \(observedProps)")

        let raw = try XCTUnwrap(((try getJSON("/api/v4/users/\(userID!)") as? [String: Any])?["props"]
                                 as? [String: Any])?["customStatus"] as? String)
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["text"] as? String, wanted)
        XCTAssertEqual(parsed["emoji"] as? String, "coffee",
                       "the picked emoji is what the server stored: \(raw)")
        XCTAssertTrue((parsed["expires_at"] as? String)?.hasPrefix("0001-01-01") ?? false,
                      "\"Don't clear\" is the Go zero time on the wire: \(raw)")

        // Clear it again, through the app. Saving dismissed the editor, so the profile screen is the
        // screen that offers the clear control now.
        let clear = element(app, "profile.clearStatus")
        XCTAssertTrue(clear.waitForExistence(timeout: 15),
                      "the profile offers a way to clear the status it now holds:\n\(app.debugDescription)")
        clear.tap()
        let cleared = waitUntil(timeout: 25) {
            let profile = (try? self.getJSON("/api/v4/users/\(self.userID!)") as? [String: Any]) ?? nil
            let props = profile?["props"] as? [String: Any]
            let value = props?["customStatus"] as? String ?? ""
            return value.isEmpty || value == "{}"
        }
        var observedAfterClear = "none"
        if let profile = try? getJSON("/api/v4/users/\(userID!)") as? [String: Any] {
            observedAfterClear = "\(profile["props"] ?? "none")"
        }
        XCTAssertTrue(cleared,
                      "the server must no longer hold the custom status; props were \(observedAfterClear)")
        attach(app, "t41-custom-status")
    }

    // MARK: - 4. Send message opens the DM

    func testSendMessageOpensTheDirectChannelWithTheAuthor() throws {
        let buddy = try buddyAccount()
        let channel = try channelID()
        let postID = try buddyPostID(channelID: channel, buddyID: buddy.id)

        let app = launchApp()
        openChannel(app, channelID: channel)

        let avatar = element(app, "post.\(postID).avatar")
        XCTAssertTrue(avatar.waitForExistence(timeout: 30),
                      "the buddy's post must be on screen to tap:\n\(app.debugDescription)")
        avatar.tap()

        let message = element(app, "profile.message")
        XCTAssertTrue(message.waitForExistence(timeout: 20),
                      "another account's profile offers Send message:\n\(app.debugDescription)")
        message.tap()

        // The app navigates into the conversation; the channel header names the other account.
        XCTAssertTrue(waitUntil(timeout: 30) {
            let title = self.element(app, "nativeChannelTitle")
            return title.exists && title.label.contains(self.buddyDisplayName(buddy))
        }, "the DM must open after Send message:\n\(app.debugDescription)")

        // The oracle: a direct channel between the two accounts exists on the server.
        let channels = try getJSON("/api/v4/users/\(userID!)/channels") as? [[String: Any]] ?? []
        let direct = channels.first { channel in
            (channel["type"] as? String) == "D" && (channel["name"] as? String ?? "").contains(buddy.id)
        }
        XCTAssertNotNil(direct, "the server must hold a DM between the two accounts")
        attach(app, "t41-send-message")
    }

    // MARK: - 5. Presence: a colleague's change (batched read) and my own (socket)

    /// Acceptance criterion 1, first half: an open profile follows **another account's** presence
    /// change without being reopened.
    ///
    /// The oracle is the buddy's own session writing that account's status, so the app did not cause
    /// the change. The transport is deliberately *not* assumed: measured on 9.11.19
    /// (`scripts/t41_profile_probe.py` §5) the server addresses `status_change` to the account that
    /// changed, so a peer's presence reaches a client through `POST /users/status/ids` — the same
    /// batched read the web client uses. This test asserts the observable behaviour (the row changes
    /// while the sheet stays open) and the next one isolates the socket for *my own* account.
    func testPresenceFollowsAnotherClientsChangeWhileTheProfileIsOpen() throws {
        let buddy = try buddyAccount()
        let buddySession = try authenticate(login: buddyLogin, password: buddyPassword)
        // A known starting point: the buddy is online and has not chosen anything manually.
        _ = try sendJSON("PUT", "/api/v4/users/\(buddy.id)/status",
                         body: ["user_id": buddy.id, "status": "online"],
                         as: buddySession.token, allowFailure: true)

        let channel = try channelID()
        let postID = try buddyPostID(channelID: channel, buddyID: buddy.id)

        // A 3-second poll for this launch: the property under test is "the open profile follows the
        // server's change", not how often it looks. Keeping the wait short also keeps the run honest —
        // a long hunt through accessibility snapshots is what made this test the slowest in the suite.
        let app = launchApp(presenceInterval: "3")
        openChannel(app, channelID: channel)
        let avatar = element(app, "post.\(postID).avatar")
        XCTAssertTrue(avatar.waitForExistence(timeout: 30),
                      "the buddy's post must be on screen to tap:\n\(app.debugDescription)")
        avatar.tap()

        let presence = element(app, "profile.presence")
        XCTAssertTrue(presence.waitForExistence(timeout: 20),
                      "the buddy's profile must mount:\n\(app.debugDescription)")
        XCTAssertTrue(waitUntil(timeout: 15) { presence.label == "Online" },
                      "the initial presence is the server's: it reads \"\(presence.label)\"")

        try sendJSON("PUT", "/api/v4/users/\(buddy.id)/status",
                     body: ["user_id": buddy.id, "status": "dnd"], as: buddySession.token)
        XCTAssertTrue(waitUntil(timeout: 15) { presence.label == "Do not disturb" },
                      "the open profile must follow the server's change; it reads "
                      + "\"\(presence.label)\" (server: \(oracleStatus(userID: buddy.id)))")

        // A second, different value: one lucky read at open time cannot pass this pair by accident.
        try sendJSON("PUT", "/api/v4/users/\(buddy.id)/status",
                     body: ["user_id": buddy.id, "status": "away"], as: buddySession.token)
        XCTAssertTrue(waitUntil(timeout: 15) { presence.label == "Away" },
                      "a second change must also land; it reads \"\(presence.label)\" "
                      + "(server: \(oracleStatus(userID: buddy.id)))")

        attach(app, "t41-presence-follows-server")

        // Put the buddy back so the next run starts from a known presence.
        _ = try sendJSON("PUT", "/api/v4/users/\(buddy.id)/status",
                         body: ["user_id": buddy.id, "status": "online"],
                         as: buddySession.token, allowFailure: true)
    }

    /// Acceptance criterion 1, second half: **my own** presence is driven by the socket.
    ///
    /// The batch poll is pushed out to two minutes for this launch (`-uiTestProfilePresenceInterval
    /// 120`), so an update inside ten seconds can only have come from `status_change` — the frame the
    /// server *does* address to my own connections. Another session of the same account performs the
    /// write, which is exactly the "changed on another device" case.
    func testMyOwnPresenceFollowsTheSocketImmediately() throws {
        _ = try sendJSON("PUT", "/api/v4/users/\(userID!)/status",
                         body: ["user_id": userID!, "status": "online"], allowFailure: true)

        let app = launchApp(presenceInterval: "120")
        openChannel(app, channelID: try channelID())
        openMyProfile(app)

        let presence = element(app, "profile.presence")
        XCTAssertTrue(waitUntil(timeout: 15) { presence.label == "Online" },
                      "my profile must start from the server's status: it reads \"\(presence.label)\"")

        // A second session of my own account: the server broadcasts this to my connections.
        try sendJSON("PUT", "/api/v4/users/\(userID!)/status",
                     body: ["user_id": userID!, "status": "dnd"])
        XCTAssertTrue(waitUntil(timeout: 10) { presence.label == "Do not disturb" },
                      "the socket's status_change must land well inside one poll interval; it reads "
                      + "\"\(presence.label)\" (server: \(oracleStatus(userID: userID)))")
        attach(app, "t41-presence-socket")

        _ = try sendJSON("PUT", "/api/v4/users/\(userID!)/status",
                         body: ["user_id": userID!, "status": "online"], allowFailure: true)
    }

    // MARK: - 6. Auto-away on background, restore on foreground

    /// Acceptance criterion 3: "auto-away on background/foreground works; the status reverts".
    ///
    /// Measured against the server, not the screen: the status row is the oracle. The app is
    /// backgrounded with `press(.home)` and brought back with `activate()`, which is exactly the
    /// `scenePhase` transition `MattermostApp` turns into `ProfileCoordinator.sceneChanged`.
    func testBackgroundingAgesMyPresenceAndForegroundRestoresIt() throws {
        // Start online and not manual: the rule only ages a server-derived `online`.
        _ = try sendJSON("PUT", "/api/v4/users/\(userID!)/status",
                         body: ["user_id": userID!, "status": "online"], allowFailure: true)

        let app = launchApp()
        openChannel(app, channelID: try channelID())
        XCTAssertTrue(waitUntil(timeout: 20) { oracleStatus(userID: self.userID) == "online" },
                      "the fixture must start online; the server says "
                      + "\(oracleStatus(userID: userID))")

        #if targetEnvironment(macCatalyst)
        // `XCUIDevice.press(.home)` does not exist on Mac Catalyst, and there is no equivalent way to
        // drive a Catalyst window to the background from XCTest. Skipped, not faked: the iOS run is
        // where this criterion is measured.
        throw XCTSkip("background/foreground transitions are driven on iOS (XCUIDevice.press(.home))")
        #else
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(waitUntil(timeout: 25) { oracleStatus(userID: self.userID) == "away" },
                      "backgrounding must age my presence to away on the server; it says "
                      + "\(oracleStatus(userID: userID))")
        let aged = try getJSON("/api/v4/users/\(userID!)/status") as? [String: Any] ?? [:]
        XCTAssertEqual(aged["manual"] as? Bool, true,
                       "the auto-away write is a manual `away` on the server: \(aged)")

        app.activate()
        XCTAssertTrue(element(app, "nativeChannelTitle").waitForExistence(timeout: 30),
                      "the app must come back to the channel it was on:\n\(app.debugDescription)")
        XCTAssertTrue(waitUntil(timeout: 30) { oracleStatus(userID: self.userID) == "online" },
                      "coming back must restore the status this client changed; the server says "
                      + "\(oracleStatus(userID: userID))")
        attach(app, "t41-auto-away-returned")
        #endif
    }

    // MARK: - App driving

    private func launchApp(presenceInterval: String = "15") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetPersistedState",
                               "-uiTestForgetSession", serverURL.absoluteString,
                               "-uiTestSeedServer", serverURL.absoluteString,
                               "-uiTestSeedServerName", "Local Mattermost",
                               "-surfaceMode", "shell=native",
                               "-surfaceMode", "auth=native",
                               "-surfaceMode", "sidebar=native",
                               "-surfaceMode", "profile=native",
                               "-uiTestProfilePresenceInterval", presenceInterval,
                               "-uiTestLogLevel", "error",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // T40-R's crash, and it bit this suite too: XCTest injects `XCTAutomationSupport` into the app
        // process and a UI run makes it log one os_log *fault* per captured runtime issue; libtrace then
        // quarantines the app process and the next accessibility snapshot dereferences a NULL
        // (`runtime_issue_os_log_fault_callback` -> `_platform_strcmp`). Measured here as
        // `lost connection to the application` with launchd reporting SIGSEGV and no crash report at
        // all, twice, only in the test that polls the tree hardest. `OS_ACTIVITY_MODE=disable` stops
        // os_log delivery in the app process, which is the volume the quarantine reacts to. Test-only:
        // the app itself is unchanged, and `-uiTestLogLevel error` is what a normal run keeps.
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

    private func openChannel(_ app: XCUIApplication, channelID: String) {
        let teamRow = element(app, "teamSidebar.team.\(teamID!)")
        XCTAssertTrue(teamRow.waitForExistence(timeout: 40),
                      "the rail must list the team this fixture seeds:\n\(app.debugDescription)")
        if !(teamRow.value as? String ?? "").contains("Selected") { teamRow.tap() }
        let row = revealSidebarRow(app, identifier: "channelSidebar.channel.\(channelID)")
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "the sidebar must list #\(channelName):\n\(app.debugDescription)")
        row.tap()
        XCTAssertTrue(element(app, "nativeChannelTitle").waitForExistence(timeout: 30),
                      "the channel pane must mount:\n\(app.debugDescription)")
    }

    /// The header's own avatar is the entry point to the signed-in account's profile (T41).
    private func openMyProfile(_ app: XCUIApplication) {
        let button = element(app, "nativeProfileButton")
        XCTAssertTrue(button.waitForExistence(timeout: 20),
                      "the channel header must offer the profile:\n\(app.debugDescription)")
        button.tap()
        XCTAssertTrue(element(app, "profileSheet").waitForExistence(timeout: 20),
                      "the profile sheet must mount:\n\(app.debugDescription)")
    }

    // MARK: - Server

    private struct Account { let id: String; let first: String; let last: String }

    private func buddyAccount() throws -> Account {
        let buddy = try getJSON("/api/v4/users/username/\(buddyLogin)") as? [String: Any] ?? [:]
        guard let id = buddy["id"] as? String else {
            throw XCTSkip("@\(buddyLogin) is missing — run scripts/t41_profile_seed.py")
        }
        return Account(id: id,
                       first: buddy["first_name"] as? String ?? "",
                       last: buddy["last_name"] as? String ?? "")
    }

    private func buddyDisplayName(_ account: Account) -> String {
        let name = [account.first, account.last].filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? buddyLogin : name
    }

    private func channelID() throws -> String {
        let channel = try getJSON("/api/v4/teams/\(teamID!)/channels/name/\(channelName)")
            as? [String: Any] ?? [:]
        guard let id = channel["id"] as? String else {
            throw XCTSkip("#\(channelName) is missing — run scripts/t41_profile_seed.py")
        }
        return id
    }

    /// The id of the buddy's post, so the row's avatar can be addressed by identifier.
    private func buddyPostID(channelID: String, buddyID: String) throws -> String {
        let posts = try getJSON("/api/v4/channels/\(channelID)/posts?per_page=60") as? [String: Any] ?? [:]
        let byID = posts["posts"] as? [String: Any] ?? [:]
        for (id, value) in byID {
            guard let post = value as? [String: Any] else { continue }
            if (post["user_id"] as? String) == buddyID,
               (post["message"] as? String ?? "").contains(buddyPostText) {
                return id
            }
        }
        throw XCTSkip("the buddy's post is missing — run scripts/t41_profile_seed.py")
    }

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
              let token = http.value(forHTTPHeaderField: "Token"),
              let user = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = user["id"] as? String else {
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])??["id"] as? String
            throw XCTSkip("could not sign in as \(login) on \(serverURL.absoluteString) "
                          + "(HTTP \(status), \(reason ?? "no error id"))")
        }
        return (token, id)
    }

    private func firstTeamID() throws -> String {
        let teams = try getJSON("/api/v4/users/me/teams") as? [[String: Any]] ?? []
        guard let team = teams.first, let id = team["id"] as? String else {
            throw XCTSkip("the fixture account has no team")
        }
        return id
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
            throw NSError(domain: "T41Oracle", code: status, userInfo: [
                NSLocalizedDescriptionKey:
                    "GET \(path) -> HTTP \(status) \(String(decoding: data.prefix(200), as: UTF8.self))"])
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func sendJSON(_ method: String, _ path: String, body: Any?,
                          as session: String? = nil,
                          allowFailure: Bool = false) throws -> Any {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = method
        request.setValue("Bearer \(session ?? token!)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try synchronous(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !allowFailure {
            guard (200...299).contains(status) else {
                throw XCTSkip("\(method) \(path) answered \(status) — the fixture is not in the state "
                              + "this test needs")
            }
        }
        guard !data.isEmpty, let json = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return json
    }

    /// The REST oracle's own session — **no cookie store** (a stale `MMAUTHTOKEN` cookie makes the
    /// server answer `session_expired` before it looks at the request; see T40's note).
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

    /// The server's own answer for an account's presence — the oracle the presence tests assert on.
    /// Reads through the admin session; a failure is reported as "unreadable" rather than thrown, so
    /// an assertion message says what the server said instead of failing inside a helper.
    private func oracleStatus(userID: String?) -> String {
        guard let userID, !userID.isEmpty,
              let row = try? getJSON("/api/v4/users/\(userID)/status") as? [String: Any] else {
            return "unreadable"
        }
        return row["status"] as? String ?? "unreadable"
    }

    // MARK: - Element helpers

    /// Any element type: SwiftUI puts these identifiers on labels, buttons, cells and collections
    /// depending on the container, so a type-specific query could silently never match.
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @discardableResult
    private func revealSidebarRow(_ app: XCUIApplication, identifier: String,
                                  maxSwipes: Int = 20) -> XCUIElement {
        let target = element(app, identifier)
        guard !target.exists else { return target }
        let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app
        var swipes = 0
        while !target.exists, swipes < maxSwipes {
            list.swipeUp(velocity: .fast)
            swipes += 1
        }
        return target
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
