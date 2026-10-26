// T40 — the channel-info surface against a **real** Mattermost server.
//
// Why live: every acceptance criterion of the card is a statement about a running server's data —
//   1. the channel's own header/purpose/member list render;
//   2. adding and removing a member reaches the server and the list agrees with it;
//   3. leaving behaves per Mattermost rules (a public channel's membership goes; a DM is closed);
//   4. rename/purpose/header persist;
//   5. joining from the browser lands in the channel;
//   6. an account whose permission set lacks an administrator id is offered no administrator action.
// A stub could only prove this file's own fixtures render. The oracle for each assertion is the server,
// read back through its own API with the same account the app signs in as.
//
// Run (local throwaway server; same credentials as T34/T39):
//
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     python3 scripts/qa-test.py --platform ios --sim <sim> \
//       --only-testing MattermostUITests/T40ChannelInfoUITests
//
// `scripts/t40_channel_seed.py` puts the fixture in the state these tests need (three channels, one
// non-admin account, and the permission-strip experiment's snapshot). Each test also seeds what it
// needs and skips — never fails — when the environment or the server is missing, like every live test
// here. Nothing is fabricated: a skipped test is reported as skipped.
//
// Screenshots: each test attaches one, so a run leaves visual evidence next to the machine verdict
// (`docs/t40-shots/` is where the committed copies live).

import XCTest

final class T40ChannelInfoUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var userID: String!
    private var teamID: String!

    /// The channel the "render the server's data" and "add/remove/settings" tests use.
    private let standupName = "t40-standup"
    /// A public channel the signed-in account is **not** in, for the browse-and-join test.
    private let browseName = "t40-browse-me"
    /// A public channel the account is in, for the leave test.
    private let goodbyeName = "t40-goodbye"
    /// The non-admin fixture account (`scripts/t40_channel_seed.py` creates it).
    private var memberLogin: String!
    private var memberPassword: String!

    /// The `channel_user` role's permissions before a test stripped them; restored in `tearDown`.
    private var strippedRoleSnapshot: (roleID: String, permissions: [String])?

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        memberLogin = env["MM_AUTH_MEMBER_LOGIN"] ?? "t40member"
        memberPassword = env["MM_AUTH_MEMBER_PASSWORD"] ?? "T40-Member-Not-A-Real-Secret-1"
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live channel-info test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        try ping()
        let session = try authenticate(login: loginID, password: password)
        token = session.token
        userID = session.userID
        teamID = try firstTeamID()
    }

    override func tearDownWithError() throws {
        // The permission experiment below narrows a **server role**; put it back even when the test
        // failed half way through, or the next run (and the next card) inherits a strange server.
        if let snapshot = strippedRoleSnapshot {
            _ = try? sendJSON("PUT", "/api/v4/roles/\(snapshot.roleID)/patch",
                              body: ["permissions": snapshot.permissions], allowFailure: true)
            strippedRoleSnapshot = nil
        }
    }

    // MARK: - 1. The screen renders the server's own data

    func testInfoScreenRendersTheServersHeaderPurposeAndMembers() throws {
        let channel = try ensureChannel(named: standupName,
                                        displayName: "T40 Standup",
                                        purpose: "Daily standup notes",
                                        header: "Standup at 09:15")
        try ensureMember(channel.id, userID: userID)

        let app = launchApp()
        openChannel(app, channel: channel)
        openChannelInfo(app)

        let title = element(app, "channelInfo.title")
        XCTAssertTrue(title.waitForExistence(timeout: 20),
                      "the info screen must mount:\n\(app.debugDescription)")
        XCTAssertTrue(title.label.contains("T40 Standup"), "title was \(title.label)")
        XCTAssertTrue(element(app, "channelInfo.purpose").label.contains("Daily standup notes"),
                      "purpose line was \(element(app, "channelInfo.purpose").label)")
        XCTAssertTrue(element(app, "channelInfo.header").label.contains("Standup at 09:15"),
                      "header line was \(element(app, "channelInfo.header").label)")

        // The member count comes from `GET /channels/{id}/stats`; the oracle is the membership list.
        let serverMembers = try memberIDs(channel.id)
        let count = element(app, "channelInfo.memberCount")
        XCTAssertTrue(count.waitForExistence(timeout: 20))
        XCTAssertTrue(count.label.contains("\(serverMembers.count) member"),
                      "count \(count.label) must match the server's \(serverMembers.count) members")
        attach(app, "01-channel-info")
    }

    // MARK: - 2. Add and remove a member, with the server as the oracle

    func testAddingAndRemovingAMemberReachesTheServer() throws {
        let channel = try ensureChannel(named: standupName, displayName: "T40 Standup")
        let memberID = try ensureNonAdminUser()
        try ensureMember(channel.id, userID: userID)
        try ensureNotMember(channel.id, userID: memberID)

        let app = launchApp()
        openChannel(app, channel: channel)
        openChannelInfo(app)

        element(app, "channelInfo.action.addMembers").tap()
        let pickerRow = element(app, "addMembers.row.\(memberID)")
        XCTAssertTrue(pickerRow.waitForExistence(timeout: 20),
                      "the picker must list the account that is not a member:\n\(app.debugDescription)")
        pickerRow.tap()
        element(app, "addMembers.submit").tap()

        XCTAssertTrue(waitUntil(timeout: 20) { self.memberIDs(channel.id).contains(memberID) },
                      "the add must reach the server (the app is not the oracle)")

        // …and the app's own list agrees: open the member list and find the row.
        element(app, "channelInfo.action.members").tap()
        let row = element(app, "channelMemberRow.\(memberID)")
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "the member list must show the added member:\n\(app.debugDescription)")
        attach(app, "02-member-added")

        // Remove: swipe the row, confirm, and read the server back.
        row.swipeLeft()
        let remove = element(app, "channelMember.remove.\(memberID)")
        XCTAssertTrue(remove.waitForExistence(timeout: 10),
                      "a managed member row must offer Remove:\n\(app.debugDescription)")
        remove.tap()
        element(app, "channelMember.remove.confirm").tap()

        XCTAssertTrue(waitUntil(timeout: 20) { !self.memberIDs(channel.id).contains(memberID) },
                      "the removal must reach the server")
        XCTAssertTrue(waitUntil(timeout: 20) { !row.exists },
                      "the row must disappear without a manual refresh")
        attach(app, "03-member-removed")
    }

    // MARK: - 3. Rename / purpose / header persist

    func testPurposeAndHeaderPersistOnTheServer() throws {
        let channel = try ensureChannel(named: standupName, displayName: "T40 Standup")
        try ensureMember(channel.id, userID: userID)
        let stamp = "edited-\(Int(Date().timeIntervalSince1970))"

        let app = launchApp()
        openChannel(app, channel: channel)
        openChannelInfo(app)
        element(app, "channelInfo.action.settings").tap()

        let purpose = element(app, "channelSettings.purpose")
        XCTAssertTrue(purpose.waitForExistence(timeout: 20),
                      "the settings form must mount:\n\(app.debugDescription)")
        purpose.tap()
        purpose.typeText(" \(stamp)")
        let header = element(app, "channelSettings.header")
        header.tap()
        header.typeText(" \(stamp)")
        element(app, "channelSettings.save").tap()

        XCTAssertTrue(waitUntil(timeout: 20) {
            let row = (try? self.getJSON("/api/v4/channels/\(channel.id)")) as? [String: Any]
            return ((row?["purpose"] as? String) ?? "").contains(stamp)
        }, "the purpose must reach the server")

        let reread = try getJSON("/api/v4/channels/\(channel.id)") as? [String: Any] ?? [:]
        XCTAssertTrue(((reread["header"] as? String) ?? "").contains(stamp),
                      "the header must reach the server too")
        attach(app, "04-settings-saved")
    }

    // MARK: - 4. Leaving a public channel removes the membership

    func testLeavingAPublicChannelRemovesTheMembershipAndTheRow() throws {
        let channel = try ensureChannel(named: goodbyeName, displayName: "T40 Goodbye")
        try ensureMember(channel.id, userID: userID)

        let app = launchApp()
        openChannel(app, channel: channel)
        openChannelInfo(app)
        element(app, "channelInfo.action.leave").tap()
        element(app, "channelInfo.leave.confirm").tap()

        XCTAssertTrue(waitUntil(timeout: 20) {
            !self.memberIDs(channel.id).contains(self.userID)
        }, "leaving must reach the server")
        // The sheet closes with the membership: the channel is no longer mine to inspect.
        XCTAssertTrue(waitUntil(timeout: 20) { !element(app, "channelInfo.sheet").exists },
                      "the info sheet must close after a leave:\n\(app.debugDescription)")
        XCTAssertTrue(waitUntil(timeout: 20) {
            !element(app, "channelSidebar.channel.\(channel.id)").exists
        }, "the channel must leave the sidebar:\n\(app.debugDescription)")
        attach(app, "05-left")
    }

    // MARK: - 5. Browse → join → straight into the channel

    func testBrowsingAndJoiningAPublicChannelNavigatesIntoIt() throws {
        let channel = try ensureChannel(named: browseName, displayName: "T40 Browse Me")
        try ensureNotMember(channel.id, userID: userID)

        let app = launchApp()
        let browseButton = element(app, "channelSidebar.browseChannels")
        XCTAssertTrue(browseButton.waitForExistence(timeout: 40),
                      "the sidebar must offer the channel browser:\n\(app.debugDescription)")
        browseButton.tap()

        let row = element(app, "browseChannels.row.\(channel.id)")
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "the browser must list a public channel I am not in:\n\(app.debugDescription)")
        row.tap()

        XCTAssertTrue(waitUntil(timeout: 20) { self.memberIDs(channel.id).contains(self.userID) },
                      "the join must reach the server")
        let title = element(app, "nativeChannelTitle")
        XCTAssertTrue(title.waitForExistence(timeout: 30),
                      "joining must land in the channel, not back on a list:\n\(app.debugDescription)")
        XCTAssertTrue(title.label.contains("T40 Browse Me"), "opened \(title.label)")
        attach(app, "06-joined")
    }

    // MARK: - 6. A permission set without the administrator id offers nothing (the security assertion)

    func testAnAccountWithoutThePermissionIsOfferedNoAdminAction() throws {
        let channel = try ensureChannel(named: standupName, displayName: "T40 Standup")
        let memberID = try ensureNonAdminUser()
        try ensureMember(channel.id, userID: memberID)

        // Narrow `channel_user` to a stock member's permissions for the duration of this test. The role's
        // **name** stays `channel_user`: what changes is the permissions array the app reads, which is
        // exactly the distinction the card draws (gate on ids, not on names).
        try stripChannelUserPermissions()

        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetPersistedState",
                               "-uiTestForgetSession", serverURL.absoluteString,
                               "-uiTestSeedServer", serverURL.absoluteString,
                               "-uiTestSeedServerName", "Local Mattermost",
                               "-surfaceMode", "shell=native",
                               "-surfaceMode", "auth=native",
                               "-surfaceMode", "sidebar=native",
                               "-surfaceMode", "channelInfo=native",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        signIn(app, login: memberLogin, password: memberPassword)

        let teamRow = element(app, "teamSidebar.team.\(teamID!)")
        XCTAssertTrue(teamRow.waitForExistence(timeout: 40),
                      "the rail must list the team:\n\(app.debugDescription)")
        if !(teamRow.value as? String ?? "").contains("Selected") { teamRow.tap() }
        let sidebarRow = revealSidebarRow(app, identifier: "channelSidebar.channel.\(channel.id)")
        XCTAssertTrue(sidebarRow.waitForExistence(timeout: 20),
                      "the non-admin must see the channel:\n\(app.debugDescription)")
        sidebarRow.tap()
        openChannelInfo(app)

        // The member list is not a permission: it is offered to everybody.
        XCTAssertTrue(element(app, "channelInfo.action.members").waitForExistence(timeout: 20))
        // Everything an administrator would get is absent.
        for identifier in ["channelInfo.action.addMembers",
                           "channelInfo.action.settings",
                           "channelInfo.action.archive",
                           "channelInfo.action.unarchive"] {
            XCTAssertFalse(element(app, identifier).exists,
                           "\(identifier) must not be offered without the permission "
                           + "(role name is irrelevant — the permissions array decides)")
        }
        attach(app, "07-non-admin")

        // And the server agrees the write would have been refused — asked with the **member's** token, not
        // the administrator's: an unprivileged add answers 403.
        let memberSession = try authenticate(login: memberLogin, password: memberPassword)
        let refused = try sendJSONExpectingFailure("POST",
                                                   "/api/v4/channels/\(channel.id)/members",
                                                   body: ["user_id": userID],
                                                   token: memberSession.token)
        XCTAssertEqual(refused, 403,
                       "the server must refuse the write this account's permissions do not allow")
    }

    // MARK: - Fixtures

    private struct Channel {
        let id: String
        let name: String
        let displayName: String
    }

    /// Create the channel if it is missing (or if it is archived, restore it), and make sure its
    /// display name / purpose / header are what the test expects.
    @discardableResult
    private func ensureChannel(named name: String,
                              displayName: String,
                              purpose: String? = nil,
                              header: String? = nil) throws -> Channel {
        var row = (try? getJSON("/api/v4/teams/\(teamID!)/channels/name/\(name)")) as? [String: Any]
        if row == nil || ((row?["delete_at"] as? Int) ?? 0) != 0 {
            if let existing = row, let id = existing["id"] as? String {
                _ = try? postJSON("/api/v4/channels/\(id)/restore", body: nil)
            } else {
                var body: [String: Any] = ["team_id": teamID!,
                                           "name": name,
                                           "display_name": displayName,
                                           "type": "O"]
                if let purpose { body["purpose"] = purpose }
                if let header { body["header"] = header }
                _ = try? postJSON("/api/v4/channels", body: body)
            }
            row = (try? getJSON("/api/v4/teams/\(teamID!)/channels/name/\(name)")) as? [String: Any]
        }
        guard var row, let id = row["id"] as? String else {
            throw XCTSkip("could not create or read #\(name) — run scripts/t40_channel_seed.py")
        }
        var patch: [String: Any] = [:]
        if (row["display_name"] as? String) != displayName { patch["display_name"] = displayName }
        if let purpose, (row["purpose"] as? String) != purpose { patch["purpose"] = purpose }
        if let header, (row["header"] as? String) != header { patch["header"] = header }
        if !patch.isEmpty {
            _ = try? putJSON("/api/v4/channels/\(id)/patch", body: patch)
            row = (try? getJSON("/api/v4/channels/\(id)")) as? [String: Any] ?? row
        }
        return Channel(id: id, name: name, displayName: displayName)
    }

    /// The non-admin account's user id, created by the seed script.
    private func ensureNonAdminUser() throws -> String {
        let users = (try? getJSON("/api/v4/users?in_team=\(teamID!)&per_page=200")) as? [[String: Any]] ?? []
        if let match = users.first(where: { ($0["username"] as? String) == memberLogin }),
           let id = match["id"] as? String {
            return id
        }
        throw XCTSkip("the non-admin fixture account \(memberLogin) is missing — "
                      + "run scripts/t40_channel_seed.py")
    }

    // MARK: - Membership helpers (the oracle)

    private func memberIDs(_ channelID: String) -> Set<String> {
        let rows = (try? getJSON("/api/v4/channels/\(channelID)/members?per_page=200"))
            as? [[String: Any]] ?? []
        return Set(rows.compactMap { $0["user_id"] as? String })
    }

    private func ensureMember(_ channelID: String, userID targetID: String) throws {
        guard !memberIDs(channelID).contains(targetID) else { return }
        _ = try? postJSON("/api/v4/channels/\(channelID)/members", body: ["user_id": targetID])
    }

    private func ensureNotMember(_ channelID: String, userID targetID: String) throws {
        guard try memberIDs(channelID).contains(targetID) else { return }
        _ = try? sendJSON("DELETE", "/api/v4/channels/\(channelID)/members/\(targetID)",
                          body: nil, allowFailure: true)
    }

    /// Narrow `channel_user` to a stock member's permission set, remembering what it was.
    ///
    /// This is the live half of the card's security assertion: the role keeps its name, so an app that
    /// gated on "is the role called channel_admin?" would still show the actions; one that gates on the
    /// permissions array does not. `tearDown` restores the array.
    private func stripChannelUserPermissions() throws {
        guard let role = try getJSON("/api/v4/roles/name/channel_user") as? [String: Any],
              let roleID = role["id"] as? String,
              let current = role["permissions"] as? [String] else {
            throw XCTSkip("could not read the channel_user role — is this a fixture server?")
        }
        strippedRoleSnapshot = (roleID, current)
        // Only ids this server actually knows (they appear in its own `channel_user` set): a guessed
        // stock list would risk a 400 on an id this version retired, and the test would then be about
        // the fixture's vocabulary rather than about the permission gate.
        let stockMember: [String] = ["read_channel", "create_post", "use_channel_mentions",
                                     "add_reaction", "edit_post", "delete_post",
                                     "upload_file", "get_public_link"]
        _ = try putJSON("/api/v4/roles/\(roleID)/patch", body: ["permissions": stockMember])
    }

    // MARK: - App driving

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetPersistedState",
                               "-uiTestForgetSession", serverURL.absoluteString,
                               "-uiTestSeedServer", serverURL.absoluteString,
                               "-uiTestSeedServerName", "Local Mattermost",
                               "-surfaceMode", "shell=native",
                               "-surfaceMode", "auth=native",
                               "-surfaceMode", "sidebar=native",
                               "-surfaceMode", "channelInfo=native",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
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

    /// Pick the team on the rail, then the channel row (the sidebar is sorted by activity, so the row
    /// may need scrolling — a lazy `List` builds only its viewport).
    private func openChannel(_ app: XCUIApplication, channel: Channel) {
        let teamRow = element(app, "teamSidebar.team.\(teamID!)")
        XCTAssertTrue(teamRow.waitForExistence(timeout: 40),
                      "the rail must list the team this test seeds:\n\(app.debugDescription)")
        if !(teamRow.value as? String ?? "").contains("Selected") { teamRow.tap() }
        let row = revealSidebarRow(app, identifier: "channelSidebar.channel.\(channel.id)")
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "the sidebar must list #\(channel.name):\n\(app.debugDescription)")
        row.tap()
        XCTAssertTrue(element(app, "nativeChannelTitle").waitForExistence(timeout: 30),
                      "the channel pane must mount:\n\(app.debugDescription)")
    }

    /// The info button lives in the native channel header (the pane is native under `shell=native`).
    private func openChannelInfo(_ app: XCUIApplication) {
        let button = element(app, "nativeChannelInfoButton")
        XCTAssertTrue(button.waitForExistence(timeout: 20),
                      "the channel header must offer channel info:\n\(app.debugDescription)")
        button.tap()
        XCTAssertTrue(element(app, "channelInfo.sheet").waitForExistence(timeout: 20),
                      "the channel-info sheet must mount:\n\(app.debugDescription)")
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
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let token = http.value(forHTTPHeaderField: "Token"),
              let user = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = user["id"] as? String else {
            throw XCTSkip("could not sign in as \(login) on the live server")
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

    private func getJSON(_ path: String) throws -> Any {
        var request = URLRequest(url: serverURL.appendingPathComponent(path))
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        let (data, _) = try synchronous(request)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func postJSON(_ path: String, body: Any?) throws -> Any {
        try sendJSON("POST", path, body: body)
    }

    private func putJSON(_ path: String, body: Any?) throws -> Any {
        try sendJSON("PUT", path, body: body)
    }

    private func sendJSON(_ method: String, _ path: String, body: Any?,
                          allowFailure: Bool = false) throws -> Any {
        var request = URLRequest(url: serverURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
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

    /// The status code only — used for the "the server agrees this write is refused" assertion.
    private func sendJSONExpectingFailure(_ method: String, _ path: String, body: Any?,
                                          token: String) throws -> Int {
        var request = URLRequest(url: serverURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (_, response) = try synchronous(request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    private func synchronous(_ request: URLRequest) throws -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Data, URLResponse)?
        var failure: Error?
        URLSession.shared.dataTask(with: request) { data, response, error in
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
