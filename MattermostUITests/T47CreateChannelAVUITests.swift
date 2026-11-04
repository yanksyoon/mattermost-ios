// T47-AV — the adversarial pass over the create-channel form and the direct-message picker.
//
// The T47 build note (docs/t47-build-note.md) measured the happy path. This suite attacks the four
// claims a reader of that note cannot check from the note itself:
//
//   1. **the server's answer is the authority.** The client's permission gate is a UI decision; if the
//      team role loses the create ids while the form is open, the tap must still reach the server and
//      the server's refusal must reach the reader — not a silent failure, and not a channel.
//   2. **the picker's opening list is not the typed search.** `GET /users?in_team=` (opening list)
//      returns a deactivated account; `POST /users/search` with `allow_inactive: false` does not. The
//      AV recorded that asymmetry (T47-AV F3); the repair card T47-AV-R2 filtered `delete_at != 0`,
//      so this test now asserts the repaired behaviour: neither list offers the account, and every
//      row states who is there (F2 — "Unknown" used to be drawn nowhere).
//   3. **a half-typed draft.** What is on screen when the app is relaunched — and, more importantly,
//      nothing is sent by the relaunch.
//   4. **one tap, twice.** `POST /channels/direct` is create-or-find; opening the same conversation a
//      second time must not leave a second channel behind.
//   5. **the `+` under a stalled read** (T47-AV-R1 F1a) and **a failed permission read's retry**
//      (F1b): both need a transport that bends one endpoint, which is
//      `scripts/t47_r1_fixture_proxy.py`. They skip unless `TEST_RUNNER_MM_AV_STALL_SERVER` /
//      `TEST_RUNNER_MM_AV_PERMISSION_SERVER` point at it.
//   6. **a dismissed draft** (F6) is asserted by test 3: Cancel → reopen shows an empty form.
//
// Run (the fixture and account from docs/t47-av-build-note.md):
//
//     MM_AV_RESTRICTED_LOGIN=t47av-restricted
//     MM_AV_RESTRICTED_PASSWORD=… python3 scripts/qa-test.py --platform ios --sim id=… \
//       --only-testing MattermostUITests/T47CreateChannelAVUITests \
//       TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 TEST_RUNNER_MM_AUTH_LOGIN=perfprobe …
//
// The restricted account is created by `scripts/t47_av_probe.py --setup`. If it (or its password) is
// absent, test 1 skips rather than inventing an answer.

import XCTest

final class T47CreateChannelAVUITests: XCTestCase {

    /// One admin session per test process: the server rate-limits `/users/login` per IP.
    private static var cachedSession: (server: String, token: String, userID: String)?

    private var env: [String: String]!
    private var serverURL: URL!
    private var adminLogin: String!
    private var adminPassword: String!
    private var restrictedLogin: String!
    private var restrictedPassword: String!
    /// Optional fixtures for the two T47-AV-R1 repairs (`scripts/t47_r1_fixture_proxy.py`). Absent
    /// values skip the two tests that need them rather than inventing a result.
    private var stallServer: String!
    private var permissionServer: String!
    private var token: String!
    private var userID: String!
    private var teamID: String!
    /// Set while test 1 has the restricted account's team role flipped; `tearDown` puts it back.
    private var rolesToRestore: String?

    override func setUpWithError() throws {
        env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        adminLogin = env["MM_AUTH_LOGIN"] ?? ""
        adminPassword = env["MM_AUTH_PASSWORD"] ?? ""
        restrictedLogin = env["MM_AV_RESTRICTED_LOGIN"] ?? ""
        restrictedPassword = env["MM_AV_RESTRICTED_PASSWORD"] ?? ""
        stallServer = env["MM_AV_STALL_SERVER"] ?? ""
        permissionServer = env["MM_AV_PERMISSION_SERVER"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !adminLogin.isEmpty && !adminPassword.isEmpty,
                          "Live create-channel AV test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        try ping()
        if let cached = Self.cachedSession, cached.server == raw {
            token = cached.token
            userID = cached.userID
        } else {
            let session = try authenticate(login: adminLogin, password: adminPassword)
            token = session.token
            userID = session.userID
            Self.cachedSession = (server: raw, token: session.token, userID: session.userID)
        }
        teamID = try firstTeamID()
    }

    override func tearDownWithError() throws {
        if let id = rolesToRestore {
            _ = try? sendJSON("PUT", "/api/v4/teams/\(teamID!)/members/\(id)/roles",
                              body: ["roles": "team_user"])
            rolesToRestore = nil
        }
    }

    // MARK: - 1. The server is the authority

    /// The form is opened while the account may create channels; then the team role that carries
    /// `create_public_channel` is taken away **on the server**, and the tap must still be refused by
    /// the server and explained to the reader. A client that only trusted its cached permission
    /// answer would create nothing either — but it would also say nothing, and this test would hang
    /// on the error sentence.
    func testTheServerRefusesACreateAfterTheTeamRoleIsRevoked() throws {
        guard !restrictedLogin.isEmpty, !restrictedPassword.isEmpty else {
            throw XCTSkip("set MM_AV_RESTRICTED_LOGIN / _PASSWORD (scripts/t47_av_probe.py --setup)")
        }
        guard let restricted = try userID(named: restrictedLogin) else {
            throw XCTSkip("\(restrictedLogin) does not exist on this fixture")
        }
        try setRoles("team_user", userID: restricted)
        rolesToRestore = restricted
        try acceptTerms(login: restrictedLogin, password: restrictedPassword)

        let stamp = Int(Date().timeIntervalSince1970)
        let displayName = "T47 AV Revoked \(stamp)"
        let urlName = "t47-av-revoked-\(stamp)"
        XCTAssertEqual(try statusOfChannelNamed(urlName), 404,
                       "the fixture must not already have \(urlName)")

        let app = launchApp(logIn: restrictedLogin, password: restrictedPassword)
        showSidebar(app)
        let plus = control(app, "nativeSidebarCreateMenu")
        XCTAssertTrue(plus.waitForExistence(timeout: 30),
                      "the restricted account is a plain team member here and may create:" 
                      + "\n\(app.debugDescription)")
        plus.tap()
        openCreateMenuRow(app, "nativeSidebarCreate.createChannel")

        let nameField = app.textFields["createChannel.displayName"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 20),
                      "the create form must mount:\n\(app.debugDescription)")
        nameField.tap()
        nameField.typeText(displayName)
        XCTAssertEqual(app.textFields["createChannel.urlName"].value as? String, urlName)

        // The server's answer changes under the open form: the team role that carried
        // `create_public_channel` is gone. The app's cached permission answer has not changed.
        let revoke = try sendJSON("PUT", "/api/v4/teams/\(teamID!)/members/\(restricted)/roles",
                                  body: ["roles": "team_admin"])
        XCTAssertEqual(revoke.status, 200, "the fixture must accept the role change")

        let submit = assertButton(app, "createChannel.submit")
        XCTAssertTrue(waitUntil(timeout: 10) { submit.isEnabled }, "the draft is valid")
        submit.tap()

        // The refusal, in the reader's words.
        let error = element(app, "createChannel.createError")
        XCTAssertTrue(error.waitForExistence(timeout: 30),
                      "the server's refusal must be shown, not swallowed:\n\(app.debugDescription)")
        XCTAssertTrue(error.label.lowercased().contains("permission"),
                      "the copy must say why; it says \"\(error.label)\"")
        attach(app, "av1-revoked-refusal")

        // And nothing was created: the server's own record, not the screen's.
        XCTAssertEqual(try statusOfChannelNamed(urlName), 404,
                       "a 403 from the server must not leave a channel behind")
        try setRoles("team_user", userID: restricted)
        rolesToRestore = nil
    }

    // MARK: - 2. A deactivated team member: in neither read of the picker

    /// Measured on 9.11.19 (`scripts/t47_av_probe.py`, T47-AV §2): `GET /users?in_team=` returns
    /// deactivated accounts (`delete_at` non-zero) while `POST /users/search` — sent
    /// `allow_inactive: false` — does not. The picker used to draw the opening list exactly as the
    /// server answered it, so one sheet offered two different populations, and the deactivated row
    /// opened a conversation (recorded as T47-AV F3 by the previous, *recording* version of this
    /// test: `testThePickerOffersADeactivatedTeamMemberThatSearchHides`).
    ///
    /// The repair drops `delete_at != 0` in `DirectMessageDerivation.rows`, the one place both reads
    /// flow through, and this test asserts the repaired behaviour on both lists. It also asserts the
    /// other half of the picker's honesty (F2): every row *states* who is there — the old view drew
    /// the presence only when the raw status string was non-empty, so "Unknown" never reached the
    /// screen and the row's label said nothing about presence at all.
    ///
    /// The team is the one the app is actually on: the rail's current row is read and, if it is not
    /// this oracle's team, the rail row for this team is tapped first. `GET /users/me/teams[0]` is
    /// not necessarily where the app opens (T47-AV F7), and an oracle about a team the sheet is not
    /// showing proves nothing.
    func testThePickerDoesNotOfferADeactivatedTeamMemberThatSearchHides() throws {
        let users = try getJSON("/api/v4/users?in_team=\(teamID!)&page=0&per_page=200") as? [[String: Any]] ?? []
        guard let gone = users.first(where: { ($0["delete_at"] as? Int ?? 0) > 0 }),
              let goneID = gone["id"] as? String, let goneName = gone["username"] as? String else {
            throw XCTSkip("the fixture team has no deactivated member to exercise the picker with")
        }
        let term = String(goneName.prefix(5))
        let search = try postJSON("/api/v4/users/search", ["term": term, "team_id": teamID!,
                                                           "page": 0, "per_page": 50,
                                                           "allow_inactive": false]) as? [[String: Any]] ?? []
        XCTAssertFalse(search.contains { $0["id"] as? String == goneID },
                       "the typed search excludes inactive accounts — the half of the asymmetry that "
                       + "the opening list is now held to")

        let app = launchApp(logIn: adminLogin, password: adminPassword)
        showSidebar(app)
        try pinTeam(teamID, in: app)
        openDirectMessagePicker(app)
        let sheet = element(app, "newDM.sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 20),
                      "the create-a-direct-message sheet must mount:\n\(app.debugDescription)")

        // 1. The opening list draws people, and the deactivated account is not among them. A SwiftUI
        //    `List` only materialises visible rows, so absence is asserted over a full sweep (the row
        //    is looked for after every swipe) rather than from one snapshot — and the sweep is proved
        //    to have reached the end of the list by finding the last row the oracle says is there.
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "newDM.row."))
        XCTAssertTrue(waitUntil(timeout: 20) { rows.count > 0 },
                      "the opening list must draw somebody:\n\(app.debugDescription)")

        let goneRow = element(app, "newDM.row.\(goneID)")
        var offered = goneRow.exists
        var swipes = 0
        let lastID = lastActiveTeamMemberID(users)
        while !offered, swipes < 12 {
            guard app.collectionViews.firstMatch.exists else { break }
            app.collectionViews.firstMatch.swipeUp(velocity: .fast)
            swipes += 1
            offered = goneRow.exists
            if lastID.map({ element(app, "newDM.row.\($0)").exists }) == true { break }
        }
        XCTAssertFalse(offered,
                       "the opening list must not offer deactivated @\(goneName) — the typed search "
                       + "already hides them, and the two lists cannot disagree inside one sheet "
                       + "(swipes: \(swipes), last row reached: \(lastID ?? "?"))")
        print("T47-AV-R2: deactivated @\(goneName) (\(goneID)) absent over a \(swipes)-swipe sweep; "
              + "last active row \(lastID ?? "?") reached")
        attach(app, "av2-deactivated-not-in-list")

        // 2. The row states who is there (F2). The oracle asks the server for the presence of the
        //    row that is on screen and expects the same word the row draws; "Unknown" is the
        //    expected answer when the server has no status for them.
        let first = rows.element(boundBy: 0)
        let firstID = String(first.identifier.dropFirst("newDM.row.".count))
        let present = try presenceWord(for: firstID)
        print("T47-AV-R2: first row \(firstID) reads \"\(first.label)\"; the server says \"\(present)\"")
        XCTAssertTrue(first.label.localizedCaseInsensitiveContains(present),
                      "the row must state its presence (\"\(present)\"); it reads \"\(first.label)\" — "
                      + "an unrendered presence label is exactly what F2 measured")
        attach(app, "av2-presence-on-the-row")

        // 3. The same account, typed: the search path hides it (`allow_inactive: false`) and the empty
        //    state appears instead. This half already held before the repair; it is what the opening
        //    list is now held to.
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.tap()
        searchField.typeText(goneName)
        let empty = element(app, "newDM.empty")
        XCTAssertTrue(empty.waitForExistence(timeout: 20),
                      "the typed search must find nobody for a deactivated account:\n\(app.debugDescription)")
        XCTAssertFalse(element(app, "newDM.row.\(goneID)").exists,
                       "the searched list must not contain the deactivated account")
        attach(app, "av2-deactivated-search-empty")
    }

    // MARK: - 3. A half-typed draft and a relaunch

    /// Type into the form, do not submit, kill the app, relaunch with the session kept. The draft is
    /// held by an in-memory model the coordinator owns; nothing writes it to disk. The test asserts
    /// the honest consequence: the form is gone after a relaunch and the server never saw the name.
    func testAHalfTypedDraftDoesNotSurviveARelaunchAndNothingIsSent() throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let displayName = "T47 AV Draft \(stamp)"
        let urlName = "t47-av-draft-\(stamp)"

        let app = launchApp(logIn: adminLogin, password: adminPassword)
        showSidebar(app)
        control(app, "nativeSidebarCreateMenu").tap()
        openCreateMenuRow(app, "nativeSidebarCreate.createChannel")
        let nameField = app.textFields["createChannel.displayName"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 20))
        nameField.tap()
        nameField.typeText(displayName)
        XCTAssertEqual(app.textFields["createChannel.urlName"].value as? String, urlName)
        XCTAssertEqual(try statusOfChannelNamed(urlName), 404, "nothing may have been sent yet")

        // Cancel and reopen. The model is one per (server, team) in `ChannelInfoCoordinator` — it
        // outlives the sheet, because the sidebar's `+` draws from the same permission answer — so the
        // sheet is what tells it the attempt is over (T47-AV-R1, F6). The reopened form must be empty:
        // neither the typed name nor the URL it derived may come back.
        app.buttons["createChannel.cancel"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !element(app, "createChannel.sheet").exists })
        control(app, "nativeSidebarCreateMenu").tap()
        openCreateMenuRow(app, "nativeSidebarCreate.createChannel")
        let reopened = app.textFields["createChannel.displayName"]
        XCTAssertTrue(reopened.waitForExistence(timeout: 20))
        // XCUITest reports an empty text field's placeholder as its `value`, so the assertion is the
        // absence of the draft (and a disabled Create), not the presence of an empty string.
        let reopenedName = (reopened.value as? String) ?? ""
        XCTAssertFalse(reopenedName.contains(displayName),
                       "a cancelled draft must not survive: the name field shows \"\(reopenedName)\"")
        let reopenedURL = (app.textFields["createChannel.urlName"].value as? String) ?? ""
        XCTAssertFalse(reopenedURL.contains(urlName),
                       "the derived URL went with the name; the field shows \"\(reopenedURL)\"")
        XCTAssertFalse(app.buttons["createChannel.submit"].isEnabled,
                       "an empty draft cannot be submitted")
        XCTAssertEqual(try statusOfChannelNamed(urlName), 404, "reopening must not send it")

        app.terminate()
        let relaunched = launchApp(logIn: adminLogin, password: adminPassword, keepingState: true)
        showSidebar(relaunched)
        XCTAssertFalse(element(relaunched, "createChannel.sheet").exists,
                       "a half-typed create draft is not restored by a relaunch (in-memory model)")
        XCTAssertEqual(try statusOfChannelNamed(urlName), 404,
                       "the relaunch must not send the draft either")
        attach(relaunched, "av3-relaunch-no-draft")
    }

    // MARK: - 4. One tap, twice

    /// `POST /channels/direct` is create-or-find. Open the same conversation from the picker twice and
    /// the server must still hold exactly one D channel named after the pair, with the two people in
    /// it — no second conversation, and the sidebar's row is that one channel.
    func testOpeningTheSameConversationTwiceFindsOneChannel() throws {
        let teammate = try teammateOnTheTeam()
        let teammateID = teammate["id"] as? String ?? ""
        let username = teammate["username"] as? String ?? ""
        let pairName = [userID!, teammateID].sorted().joined(separator: "__")

        let app = launchApp(logIn: adminLogin, password: adminPassword)
        showSidebar(app)
        openDirectMessagePicker(app)

        let search = app.searchFields.firstMatch
        if search.waitForExistence(timeout: 10) {
            search.tap()
            if (search.value as? String) != username { search.typeText(username) }
        }
        let row = element(app, "newDM.row.\(teammateID)")
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "the picker must list @\(username):\n\(app.debugDescription)")
        row.tap()
        let title = element(app, "nativeChannelTitle")
        XCTAssertTrue(title.waitForExistence(timeout: 30),
                      "the first tap must land in the conversation:\n\(app.debugDescription)")

        // Second time, from the sidebar.
        showSidebar(app)
        openDirectMessagePicker(app)
        let rowAgain = element(app, "newDM.row.\(teammateID)")
        XCTAssertTrue(rowAgain.waitForExistence(timeout: 20),
                      "the picker must still list @\(username):\n\(app.debugDescription)")
        rowAgain.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 30),
                      "the second tap must land in the conversation:\n\(app.debugDescription)")

        // The server's record: exactly one channel named after the pair.
        let channels = try getJSON("/api/v4/users/me/teams/\(teamID!)/channels?page=0&per_page=500")
            as? [[String: Any]] ?? []
        let matches = channels.filter {
            $0["type"] as? String == "D" && $0["name"] as? String == pairName
        }
        XCTAssertEqual(matches.count, 1,
                       "two taps must leave one conversation named \(pairName); the server has \(matches.count)")
        let channelID = matches.first?["id"] as? String ?? ""
        XCTAssertFalse(channelID.isEmpty)
        let members = try getJSON("/api/v4/channels/\(channelID)/members") as? [[String: Any]] ?? []
        XCTAssertEqual(Set(members.compactMap { $0["user_id"] as? String }),
                       Set([userID!, teammateID]))
        showSidebar(app)
        XCTAssertTrue(revealSidebarRow(app, identifier: "channelSidebar.channel.\(channelID)")
            .waitForExistence(timeout: 30),
            "the sidebar must hold that one conversation:\n\(app.debugDescription)")
        attach(app, "av4-one-conversation")
    }

    // MARK: - 5. The `+` does not wait behind an unrelated read (T47-AV-R1, F1a)

    /// `ChannelSidebarView` used to load the create model as the second statement of the task that
    /// first *awaited* `GET /users/me/teams/{id}/threads`, so one slow threads read starved the `+`
    /// for as long as it ran (measured: 30 s after sign-in, `channelSidebar.loading` still spinning and
    /// no `nativeSidebarCreateMenu`). The two reads are separate tasks now.
    ///
    /// The stall is real, not injected into the app: `scripts/t47_r1_fixture_proxy.py` holds that one
    /// path for `--threads-delay` seconds and forwards everything else. The app is pointed at the
    /// proxy, and the fixture's own counters prove the threads read was still in flight when the `+`
    /// appeared — the claim is read from the thing that did the stalling.
    func testTheCreateMenuAppearsWhileTheThreadsReadIsStalled() throws {
        try XCTSkipUnless(!stallServer.isEmpty,
                          "set TEST_RUNNER_MM_AV_STALL_SERVER "
                          + "(python3 scripts/t47_r1_fixture_proxy.py --listen 8076 --threads-delay 60)")
        guard let proxy = URL(string: stallServer) else {
            throw XCTSkip("MM_AV_STALL_SERVER is not a URL: \(stallServer ?? "")")
        }

        let app = launchApp(logIn: adminLogin, password: adminPassword, server: proxy)
        showSidebar(app)
        let started = Date()
        let plus = control(app, "nativeSidebarCreateMenu")
        XCTAssertTrue(plus.waitForExistence(timeout: 25),
                      "the `+` must not wait behind the threads read:\n\(app.debugDescription)")
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 45,
                          "the `+` appeared only after \(elapsed)s — the threads read is stalled for 60s")

        let status = try fixtureStatus(proxy)
        XCTAssertGreaterThanOrEqual(status["threads_delayed"] as? Int ?? 0, 1,
                                    "the fixture must have held the threads read")
        XCTAssertGreaterThanOrEqual(status["threads_in_flight"] as? Int ?? 0, 1,
                                    "the `+` arrived while a threads read was still in flight")
        attach(app, "r1a-create-menu-while-threads-stalled")

        // A menu, not a decoration: the create row opens the form.
        plus.tap()
        openCreateMenuRow(app, "nativeSidebarCreate.createChannel")
        XCTAssertTrue(app.textFields["createChannel.displayName"].waitForExistence(timeout: 20),
                      "the `+` drawn under a stalled read must still open the form:\n\(app.debugDescription)")
    }

    // MARK: - 6. A failed permission read is not "no permission" (T47-AV-R1, F1b)

    /// `load()` turned a failed `POST /roles/names` (and a failed `GET …/members/me`) into an empty
    /// permission set — the same state as a reader who may not create. The `+` was not drawn for
    /// either, so the model's failure sentence and its retry lived in a sheet the `+` is the only way
    /// into: unreachable.
    ///
    /// The fixture (`--fail-permission-reads 1`) refuses the first attempt and forwards the second, so
    /// this test observes the retry's *effect*: the same `+`, opened again, is the real menu.
    func testAFailedPermissionReadOffersARetryThatActuallyReloads() throws {
        try XCTSkipUnless(!permissionServer.isEmpty,
                          "set TEST_RUNNER_MM_AV_PERMISSION_SERVER "
                          + "(python3 scripts/t47_r1_fixture_proxy.py --listen 8077 --fail-permission-reads 1)")
        guard let proxy = URL(string: permissionServer) else {
            throw XCTSkip("MM_AV_PERMISSION_SERVER is not a URL: \(permissionServer ?? "")")
        }

        let app = launchApp(logIn: adminLogin, password: adminPassword, server: proxy)
        showSidebar(app)

        // The answer failed, so the menu is honest about it — but it is drawn, and it can retry.
        let plus = control(app, "nativeSidebarCreateMenu")
        XCTAssertTrue(plus.waitForExistence(timeout: 30),
                      "a failed permission read must not look like \"you may not\":\n\(app.debugDescription)")
        plus.tap()
        let retry = app.buttons.matching(identifier: "nativeSidebarCreateRetry").firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 10),
                      "the failure must offer a reachable retry:\n\(app.debugDescription)")
        let before = try fixtureStatus(proxy)
        attach(app, "r1b-permission-read-failed-retry")
        retry.tap()

        // The retry re-ran the reads (the fixture forwards them now), so the real menu comes back.
        XCTAssertTrue(waitUntil(timeout: 30) {
            let plus = control(app, "nativeSidebarCreateMenu")
            return plus.exists && plus.isHittable
        }, "the `+` must come back after the retry:\n\(app.debugDescription)")
        let createRow = app.buttons.matching(identifier: "nativeSidebarCreate.createChannel").firstMatch
        var opened = 0
        while !createRow.exists && opened < 3 {
            let plus = control(app, "nativeSidebarCreateMenu")
            if plus.exists && plus.isHittable { plus.tap() }
            _ = createRow.waitForExistence(timeout: 6)
            opened += 1
        }
        XCTAssertTrue(createRow.waitForExistence(timeout: 10),
                      "the retry must re-run load() and offer the real menu:\n\(app.debugDescription)")

        let after = try fixtureStatus(proxy)
        XCTAssertGreaterThanOrEqual(after["permission_requests"] as? Int ?? 0,
                                    (before["permission_requests"] as? Int ?? 0) + 1,
                                    "the retry must have asked the server again, not re-rendered the old answer")
        attach(app, "r1b-menu-after-retry")
    }

    // MARK: - App driving

    private func launchApp(logIn login: String, password: String,
                           keepingState: Bool = false,
                           server: URL? = nil) -> XCUIApplication {
        // A test that points the app at a fixture proxy passes it here; everything the suite itself
        // asks the server goes to `serverURL` (the real one) unless the proxy is transparent.
        let target = server ?? serverURL!
        let app = XCUIApplication()
        var arguments = ["-uiTestSeedServer", target.absoluteString,
                         "-uiTestSeedServerName", "Local Mattermost",
                         "-surfaceMode", "shell=native",
                         "-surfaceMode", "auth=native",
                         "-surfaceMode", "sidebar=native",
                         "-surfaceMode", "channelInfo=native",
                         "-uiTestLogLevel", "error",
                         "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if !keepingState {
            arguments = ["-uiTestResetPersistedState",
                         "-uiTestForgetSession", target.absoluteString] + arguments
        }
        app.launchArguments = arguments
        app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"
        app.launch()
        if !keepingState || app.textFields["loginIDField"].waitForExistence(timeout: 10) {
            signIn(app, login: login, password: password)
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
        // Not `nativeShell`: since `t_295b0a32` a signed-in launch opens a channel and pushes it
        // **over** the list, so the shell container is absent until `Back` (t_9399c0b4).
        // `ShellSettle.waitForSignedIn` answers "are we in?" for both landings; `showSidebar` is
        // what comes back to the list.
        XCTAssertTrue(ShellSettle.waitForSignedIn(app, timeout: 40),
                      "signing in must reach the shell:\n\(app.debugDescription)")
    }

    private func showSidebar(_ app: XCUIApplication) {
        // `nativeSidebar` is in the tree even when a pushed channel pane covers it — measured on this
        // card (`t9399c0b4`): present at t=8.67 s, `sidebarCurrentTeam` never — so it cannot be the
        // early-out test. `ShellSettle.tapTab` settles the landing, pops the pane, taps `Channels`, and
        // answers false on the split layout (no bar), leaving the sidebar alone.
        if !ShellSettle.tapTab(ShellSettle.Tab.channels, in: app, wait: 5),
           !element(app, "nativeSidebar").exists {
            let back = app.navigationBars.firstMatch.buttons.element(boundBy: 0)
            if back.exists, back.isHittable { back.tap() }
        }
        XCTAssertTrue(element(app, "nativeSidebar").waitForExistence(timeout: 20),
                      "the shell must be back on the channel sidebar:\n\(app.debugDescription)")
    }

    private func openDirectMessagePicker(_ app: XCUIApplication) {
        let plus = control(app, "nativeSidebarCreateMenu")
        XCTAssertTrue(plus.waitForExistence(timeout: 30),
                      "the create menu must be offered:\n\(app.debugDescription)")
        plus.tap()
        openCreateMenuRow(app, "nativeSidebarCreate.createDirectMessage")
        let sheet = element(app, "newDM.sheet")
        if !sheet.waitForExistence(timeout: 20) {
            openCreateMenuRow(app, "nativeSidebarCreate.createDirectMessage")
            XCTAssertTrue(sheet.waitForExistence(timeout: 20),
                          "the create-a-direct-message sheet must mount:\n\(app.debugDescription)")
        }
    }

    @discardableResult
    private func revealSidebarRow(_ app: XCUIApplication, identifier: String,
                                  maxSwipes: Int = 25) -> XCUIElement {
        let target = element(app, identifier)
        if target.waitForExistence(timeout: 15) { return target }
        // The channel sidebar is a `ScrollView` + `LazyVStack` since T8f (`channelSidebar.scroll`).
        // Drive it through the application's own swipe rather than a `collectionViews` query: there
        // is no collection view there, and a query that finds nothing returns silently without
        // scrolling (measured in this AV run — the DM row sits below the first viewport of a
        // 5,305-pt list).
        var swipes = 0
        while !target.exists, swipes < maxSwipes {
            app.swipeUp(velocity: .fast)
            swipes += 1
        }
        swipes = 0
        while !target.exists, swipes < maxSwipes {
            app.swipeDown(velocity: .fast)
            swipes += 1
        }
        return target
    }

    private func scrollTo(_ target: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 8) {
        let container = app.collectionViews.firstMatch
        var swipes = 0
        while !target.exists, swipes < maxSwipes, container.exists {
            container.swipeUp(velocity: .fast)
            swipes += 1
        }
    }

    // MARK: - Server

    /// Put the app on `teamID` so the sheet this test drives lists the team the oracle reads.
    ///
    /// The rail marks the current team in its accessibility value. `GET /users/me/teams[0]` and the
    /// rail's first entry are not the same team on this fixture (T47-AV F7: one run created in
    /// Operations while the oracle looked in Perf), and the sheet lists whichever team the shell is
    /// on — so the test makes them agree instead of hoping they do.
    private func pinTeam(_ teamID: String, in app: XCUIApplication) throws {
        let row = element(app, "teamSidebar.team.\(teamID)")
        guard row.waitForExistence(timeout: 20) else {
            throw XCTSkip("the shell's team rail does not offer \(teamID), so the picker's team cannot be pinned")
        }
        if (row.value as? String ?? "").contains("Current team") { return }
        row.tap()
        XCTAssertTrue(waitUntil(timeout: 30) {
            (element(app, "teamSidebar.team.\(teamID)").value as? String ?? "").contains("Current team")
        }, "tapping the rail row must make \(teamID) the current team; value: "
            + "\(element(app, "teamSidebar.team.\(teamID)").value as? String ?? "nil")")
    }

    /// The word the row must draw for the presence the server holds for `userID`.
    ///
    /// The mapping restates `DirectMessageCandidate.statusLabel` because the test is the oracle: a
    /// server that answers no status for a person is "Unknown", never "Offline".
    private func presenceWord(for userID: String) throws -> String {
        let rows = try postJSON("/api/v4/users/status/ids", [userID]) as? [[String: Any]] ?? []
        let status = rows.first { $0["user_id"] as? String == userID }?["status"] as? String ?? ""
        switch status {
        case "online": return "Online"
        case "away": return "Away"
        case "dnd": return "Do not disturb"
        case "offline": return "Offline"
        default: return "Unknown"
        }
    }

    /// The id of the row that sorts last in the picker among the team's active members other than me.
    /// The absence sweep stops once it is on screen: a SwiftUI `List` only materialises visible rows,
    /// so "the deactivated row is not there" means something only once the sweep has traversed the
    /// whole list, which this row proves it did.
    private func lastActiveTeamMemberID(_ users: [[String: Any]]) -> String? {
        let people = users.compactMap { user -> (id: String, display: String, username: String)? in
            guard let id = user["id"] as? String, id != userID,
                  (user["delete_at"] as? Int ?? 0) == 0 else { return nil }
            let nickname = user["nickname"] as? String ?? ""
            let full = [user["first_name"] as? String ?? "", user["last_name"] as? String ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " ")
            let username = user["username"] as? String ?? ""
            let display = !nickname.isEmpty ? nickname : (full.isEmpty ? username : full)
            return (id, display, username)
        }
        return people.sorted { lhs, rhs in
            let comparison = lhs.display.compare(rhs.display,
                                                 options: [.caseInsensitive, .diacriticInsensitive])
            if comparison == .orderedSame { return lhs.username < rhs.username }
            return comparison == .orderedAscending
        }.last?.id
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
              let issued = http.value(forHTTPHeaderField: "Token"),
              let user = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = user["id"] as? String else {
            throw XCTSkip("could not sign in as \(login) on \(serverURL.absoluteString) (HTTP \(status))")
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

    private func userID(named username: String) throws -> String? {
        let user = try getJSON("/api/v4/users/username/\(username)") as? [String: Any]
        return user?["id"] as? String
    }

    private func setRoles(_ roles: String, userID: String) throws {
        let answer = try sendJSON("PUT", "/api/v4/teams/\(teamID!)/members/\(userID)/roles",
                                  body: ["roles": roles])
        XCTAssertEqual(answer.status, 200, "PUT team member roles=\(roles) must be accepted")
    }

    /// The T49 gate reads the signed-in user's own acceptance; a fresh account has none, so the
    /// app would sit on the terms gate before the shell this suite needs. Accept as that user.
    private func acceptTerms(login: String, password: String) throws {
        let session = try authenticate(login: login, password: password)
        var document: [String: Any]?
        var request = URLRequest(url: url(for: "/api/v4/terms_of_service"))
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try synchronous(request)
        if (response as? HTTPURLResponse)?.statusCode == 200 {
            document = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        guard let documentID = document?["id"] as? String else { return }
        // The app's own body (`ServerTermsOfServiceAPI.accept`) is camelCase, and the server matches
        // it case-insensitively; `terms_of_service_id` is silently ignored (measured: the gate came
        // back for a user whose acceptance had "worked").
        _ = try sendJSON("POST", "/api/v4/users/me/terms_of_service",
                         body: ["termsOfServiceId": documentID, "accepted": true],
                         bearer: session.token, allowFailure: true)
    }

    private func statusOfChannelNamed(_ name: String) throws -> Int {
        var request = URLRequest(url: url(for: "/api/v4/teams/\(teamID!)/channels/name/\(name)"))
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        let (_, response) = try synchronous(request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    /// The fixture proxy's own counters (`scripts/t47_r1_fixture_proxy.py`) — a timing claim is read
    /// from the process that did the stalling, not from the screen it produced.
    private func fixtureStatus(_ proxy: URL) throws -> [String: Any] {
        var request = URLRequest(url: proxy.appendingPathComponent("__fixture/status"))
        request.timeoutInterval = 5
        let (data, response) = try synchronous(request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XCTSkip("the fixture proxy at \(proxy.absoluteString) has no /__fixture/status")
        }
        return json
    }

    private func teammateOnTheTeam() throws -> [String: Any] {
        let users = try getJSON("/api/v4/users?in_team=\(teamID!)&page=0&per_page=60") as? [[String: Any]] ?? []
        let candidate = users.first { user in
            (user["id"] as? String) != userID
                && (user["delete_at"] as? Int ?? 0) == 0
                && (user["is_bot"] as? Bool ?? false) == false
        }
        guard let candidate else {
            throw XCTSkip("the fixture team has no second (active) member to start a DM with")
        }
        return candidate
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
            throw NSError(domain: "T47AV", code: status, userInfo: [
                NSLocalizedDescriptionKey:
                    "GET \(path) -> HTTP \(status) \(String(decoding: data.prefix(200), as: UTF8.self))"])
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func postJSON(_ path: String, _ body: Any) throws -> Any {
        let answer = try sendJSON("POST", path, body: body)
        return answer.json
    }

    @discardableResult
    private func sendJSON(_ method: String, _ path: String, body: Any?,
                          bearer: String? = nil, allowFailure: Bool = false)
        throws -> (status: Int, json: Any) {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = method
        request.setValue("Bearer \(bearer ?? token!)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try synchronous(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !allowFailure, !(200...299).contains(status) {
            throw XCTSkip("\(method) \(path) answered \(status)")
        }
        guard !data.isEmpty, let json = try? JSONSerialization.jsonObject(with: data) else {
            return (status, [:])
        }
        return (status, json)
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
