// T40 — the channel-info surface against a **real** Mattermost server.
//
// Why live: every acceptance criterion of the card is a statement about a running server's data —
//   1. the channel's own header/purpose/member list render;
//   2. adding and removing a member reaches the server and the list agrees with it;
//   3. leaving behaves per Mattermost rules (a public channel's membership goes; a DM is closed);
//   4. rename/purpose/header persist;
//   5. joining from the browser lands in the channel — and the sidebar gains the row;
//   6. an account whose permission set lacks an administrator id is offered no administrator action;
//   7. archive/unarchive reaches the server;
//   8. an open info screen follows `channel_updated` / `user_added` / `user_removed` events.
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
// **Point it at the server directly, never at a proxy.** Two tests assert socket *delivery*
// (`testBrowsing...`'s `06b-joined-sidebar` and all of `testTheOpenInfoScreenFollowsRenameAndMembershipEvents`),
// and a logging relay is not a websocket tunnel: measured on `build/logs/t40r-suite10.log`, the app opened
// `GET /api/v4/websocket` through the relay and received no frame, so those two tests failed while the
// other six passed — the proxy, not the app. A relay is good for one thing only: proving that a write
// leaves the app (`build/logs/t40r-relay-suite10.txt`).
//
// `scripts/t40_channel_seed.py` puts the fixture in the state these tests need (three channels, one
// non-admin account, and the permission-strip experiment's snapshot). Each test also seeds what it
// needs and skips — never fails — when the environment or the server is missing, like every live test
// here. Nothing is fabricated: a skipped test is reported as skipped.
//
// Screenshots: each test attaches one, so a run leaves visual evidence next to the machine verdict
// (`docs/t40-shots/` is where the committed copies live).
//
// ## What T40-R changed here, and why
//
// * **The add test no longer re-taps the row until the Add button enables.** That loop existed because
//   the picker's view model was held in a plain `@State` and nothing observed it, so the button stayed
//   disabled forever (T40-AV F1). The defect is fixed in the view; the test now taps once and asserts
//   the button counts the selection.
// * **The settings test dismisses the keyboard before Save** and asserts Save is enabled before tapping.
//   A disabled row's tap is a silent no-op — exactly how the missing `PUT …/patch` hid (F2).
// * **The browse test scrolls the browser sheet to its row** (F6): the list is lazy over a team with
//   dozens of channels, so the row is not in the accessibility tree until it is on screen. Its failure
//   was never the sheet-tap defect the build note blamed.
// * **The non-admin test no longer waits for the team rail** (F5): the rail is deliberately not drawn
//   for an account with exactly one team, and `t40member` is in one team. It reveals its channel row
//   directly, which is what the security assertion needs.
// * **The role strip is repaired before it can poison a run** (F9): a killed process that left the
//   shared `channel_user` role stripped is put back at `setUp`, and the strip's own window is as short
//   as the assertions allow.

import XCTest

final class T40ChannelInfoUITests: XCTestCase {

    /// One admin session per test process; the server rate-limits logins by IP (see `setUpWithError`).
    private static var cachedAdminSession: (server: String, token: String, userID: String)? = nil
    /// Whether the fixture's `channel_user` role has already been verified/repaired in this process.
    private static var repairedChannelUser = false

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var userID: String!
    private var teamID: String!

    /// The last reason a server-side read failed, so an assertion can say why the oracle is empty.
    private var lastOracleFailure: String?

    /// The channel the "render the server's data", add/remove/settings and event tests use.
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

    /// The fixture's `channel_user` permission ids, verbatim from `scripts/t40_channel_seed.py`
    /// (`FIXTURE_CHANNEL_USER_PERMISSIONS`, what `--reset-roles` writes back).
    ///
    /// This server's `channel_user` is **not** Mattermost's stock set: the fixture grants the
    /// channel-administrator ids to ordinary members, which is what makes the permission gate
    /// measurable at all. The list is duplicated here because the test bundle cannot read the repo;
    /// `scripts/t40_channel_seed.py` is the canonical copy and the two are compared in
    /// `docs/t40-build-note.md` §6.1.
    private static let fixtureChannelUserPermissions = [
        "add_bookmark_private_channel",
        "add_bookmark_public_channel",
        "add_reaction",
        "create_post",
        "delete_bookmark_private_channel",
        "delete_bookmark_public_channel",
        "delete_post",
        "delete_private_channel",
        "delete_public_channel",
        "edit_bookmark_private_channel",
        "edit_bookmark_public_channel",
        "edit_post",
        "get_public_link",
        "manage_private_channel_members",
        "manage_private_channel_properties",
        "manage_public_channel_members",
        "manage_public_channel_properties",
        "order_bookmark_private_channel",
        "order_bookmark_public_channel",
        "read_channel",
        "read_channel_content",
        "read_private_channel_groups",
        "read_public_channel_groups",
        "remove_reaction",
        "upload_file",
        "use_channel_mentions",
        "use_group_mentions",
    ]

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
        // One admin login per process, not one per test: the server rate-limits `/users/login` per IP
        // (measured: after a script and this suite shared the address, every test skipped with HTTP 429),
        // and each test signing in again is another chance to be throttled mid-suite.
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
        try repairChannelUserRoleIfStripped()
    }

    override func tearDownWithError() throws {
        // The permission experiment below narrows a **server role**; put it back even when the test
        // failed half way through, or the next run (and the next card) inherits a strange server.
        restoreStrippedRole()
        // The archive test may have died between the archive and the unarchive. Every test's
        // `ensureChannel` restores an archived channel anyway; repairing here keeps the fixture honest
        // even for a suite that starts somewhere else. A non-archived channel answers 400 to a restore,
        // which is why the failure is allowed and ignored.
        if let channelID = (try? ensureChannelID(named: standupName)) ?? nil {
            _ = try? sendJSON("POST", "/api/v4/channels/\(channelID)/restore",
                              body: nil, allowFailure: true)
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
                      "count \(count.label) must match the server's \(serverMembers.count) members"
                      + (lastOracleFailure.map { " (oracle: \($0))" } ?? ""))
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

        tapControl(app, "channelInfo.action.addMembers")
        let pickerRow = element(app, "addMembers.row.\(memberID)")
        XCTAssertTrue(pickerRow.waitForExistence(timeout: 20),
                      "the picker must list the account that is not a member:\n\(app.debugDescription)")
        pickerRow.tap()

        // One tap selects, and the app's own state must say so: the Add button enables and counts the
        // selection. A body that never re-runs after `selection` changes leaves the button disabled and
        // the tap a silent no-op — the T40-AV F1 defect, which is why there is no retry loop here.
        let submit = assertButton(app, "addMembers.submit")
        XCTAssertTrue(waitUntil(timeout: 10) { submit.isEnabled },
                      "one row tap must enable the Add button; it says \"\(submit.label)\""
                      + "\n\(app.debugDescription)")
        XCTAssertTrue(submit.label.contains("1"),
                      "the Add button must count the selection, not stay at zero: \"\(submit.label)\"")
        submit.tap()

        XCTAssertTrue(waitUntil(timeout: 20) { self.memberIDs(channel.id).contains(memberID) },
                      "the add must reach the server (the app is not the oracle)")
        XCTAssertTrue(waitUntil(timeout: 10) { !element(app, "addMembers.sheet").exists },
                      "the picker must close once the add landed:\n\(app.debugDescription)")

        // …and the app's own list agrees: open the member list and find the row.
        tapControl(app, "channelInfo.action.members")
        let row = element(app, "channelMemberRow.\(memberID)")
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "the member list must show the added member:\n\(app.debugDescription)")
        attach(app, "02-member-added")

        // Remove: swipe the row, confirm, and read the server back.
        //
        // `swipeLeft()` is aimed at the element the identifier resolved to, and inside a SwiftUI List row
        // that is the avatar's `StaticText` (~32pt wide): the synthesised gesture is too short to be a row
        // swipe, so no action appeared (measured: the swipe ran, the Remove button never existed). The
        // drag below spans the row at its own vertical centre instead, which is what a finger does.
        revealRowSwipeActions(app, row: row)
        let remove = element(app, "channelMember.remove.\(memberID)")
        XCTAssertTrue(remove.waitForExistence(timeout: 10),
                      "a managed member row must offer Remove:\n\(app.debugDescription)")
        remove.tap()
        tapControl(app, "channelMember.remove.confirm")

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
        tapControl(app, "channelInfo.action.settings")

        let purpose = element(app, "channelSettings.purpose")
        XCTAssertTrue(purpose.waitForExistence(timeout: 20),
                      "the settings form must mount:\n\(app.debugDescription)")
        purpose.tap()
        purpose.typeText(" \(stamp)")
        let header = element(app, "channelSettings.header")
        header.tap()
        header.typeText(" \(stamp)")
        // Scroll the Save row into view instead of dismissing the keyboard by tapping a navigation bar.
        // The first navigation bar in the tree can be the **shell's**, behind the sheet, and a tap there
        // closes the sheet (measured: the form was gone before Save was ever looked for).
        element(app, "channelSettings.form").swipeUp(velocity: .slow)

        let save = assertButton(app, "channelSettings.save")
        XCTAssertTrue(waitUntil(timeout: 10) { save.isEnabled },
                      "the Save row must enable once the draft differs from the server's copy"
                      + "\n\(app.debugDescription)")
        save.tap()

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
        // Opening the channel *goes through the sidebar row*, and `openChannel` fails loudly if that row
        // does not exist — so "the row was there before the leave" is established here, and the absence
        // check after the leave is meaningful. (The earlier form re-checked the row while the channel
        // pane was on screen, where there is no sidebar at all.)
        openChannel(app, channel: channel)
        openChannelInfo(app)
        tapControl(app, "channelInfo.action.leave")
        tapControl(app, "channelInfo.leave.confirm")

        XCTAssertTrue(waitUntil(timeout: 20) {
            !self.memberIDs(channel.id).contains(self.userID)
        }, "leaving must reach the server")
        // The sheet closes with the membership: the channel is no longer mine to inspect.
        XCTAssertTrue(waitUntil(timeout: 20) { !element(app, "channelInfo.sheet").exists },
                      "the info sheet must close after a leave:\n\(app.debugDescription)")
        attach(app, "05-left")

        // **Not asserted here: that the sidebar row is gone.** Measured twice (suite4, suite6): after a
        // leave the shell sits on the channel tab with a disabled Back and no sidebar to return to, so
        // `showSidebar` cannot reach the sidebar at all — the assertion would fail on the *navigation*,
        // not on the row. What the row's removal actually rests on:
        //  * `ChannelSidebarService` answers `.reloadNeeded` for my own `user_removed` and the coordinator
        //    reloads once per debounce — two unit tests in `MattermostTests/T33-ChannelSidebarTests.swift`
        //    (`testMyOwnMembershipChangeAsksForAFullReloadAndSomebodyElsesDoesNot`,
        //    `testMyOwnUserAddedEventReloadsTheListOncePerDebounce`);
        //  * the live suite proves the same event path in the other direction: the browse test's join
        //    makes the row appear (`06b-joined-sidebar`), and the socket test's `user_removed` makes a
        //    member row disappear from the open sheet.
        // The state this leaves behind (the shell on a channel I am no longer in) is a shell-navigation
        // gap recorded in `docs/t40-build-note.md` §6, not a channel-info defect.
    }

    // MARK: - 5. Browse → join → straight into the channel, and the sidebar follows

    func testBrowsingAndJoiningAPublicChannelNavigatesIntoIt() throws {
        let channel = try ensureChannel(named: browseName, displayName: "T40 Browse Me")
        try ensureNotMember(channel.id, userID: userID)

        let app = launchApp()
        let browseButton = element(app, "nativeSidebarBrowseChannels")
        XCTAssertTrue(browseButton.waitForExistence(timeout: 40),
                      "the sidebar must offer the channel browser:\n\(app.debugDescription)")
        browseButton.tap()
        XCTAssertTrue(element(app, "browseChannels.sheet").waitForExistence(timeout: 20),
                      "the browser sheet must mount:\n\(app.debugDescription)")

        // T40-AV F6: the sheet is a lazy `List` over a team with dozens of channels. The row is not in
        // the accessibility tree until it has been scrolled to, which is why every earlier run failed
        // on this step — not because of any tap defect.
        let row = revealInSheet(app, sheet: "browseChannels.sheet",
                                identifier: "browseChannels.row.\(channel.id)")
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "the browser must list a public channel I am not in:\n\(app.debugDescription)")
        row.tap()

        XCTAssertTrue(waitUntil(timeout: 20) { self.memberIDs(channel.id).contains(self.userID) },
                      "the join must reach the server")
        let title = element(app, "nativeChannelTitle")
        XCTAssertTrue(title.waitForExistence(timeout: 30),
                      "joining must land in the channel, not back on a list:\n\(app.debugDescription)")
        // T40-AV F4: the title is the channel's display name. The pane is handed the URL name and then
        // reads the channel itself (`ChannelViewModel.loadChannelHeader`), so the assertion waits for the
        // server's answer instead of sampling the frame before it arrives.
        XCTAssertTrue(waitUntil(timeout: 20) { title.label.contains("T40 Browse Me") },
                      "the pane title must be the display name, not the URL slug: opened \(title.label)")
        attach(app, "06-joined")

        // T40-AV F3: the sidebar gained the row, from the `user_added` event, with no reload, no pull
        // and no relaunch. Back to the sidebar to look at it.
        showSidebar(app)
        XCTAssertTrue(revealSidebarRow(app, identifier: "channelSidebar.channel.\(channel.id)")
                        .waitForExistence(timeout: 30),
                      "the joined channel must be listed in the sidebar:\n\(app.debugDescription)")
        attach(app, "06b-joined-sidebar")

        // Leave again so the next run starts from "not a member".
        //
        // `userID` is an implicitly-unwrapped `String!`, and interpolating one yields `Optional("…")`:
        // the path was `/members/Optional("jruqq…")` and the server answered 404 to a request the `try?`
        // swallowed, so the channel stayed joined — measured in the relay log of `t40r-suite9`
        // (`20:55:13 DELETE …/members/Optional(%22jruqq…%22)`). Force-unwrapped, because this point is
        // reached only after a signed-in run has set it.
        _ = try? sendJSON("DELETE", "/api/v4/channels/\(channel.id)/members/\(userID!)",
                          body: nil, allowFailure: true)
    }

    // MARK: - 6. A permission set without the administrator id offers nothing (the security assertion)

    func testAnAccountWithoutThePermissionIsOfferedNoAdminAction() throws {
        let channel = try ensureChannel(named: standupName, displayName: "T40 Standup")
        let memberID = try ensureNonAdminUser()
        try ensureMember(channel.id, userID: memberID)

        // Narrow `channel_user` to a stock member's permissions for the duration of this test. The role's
        // **name** stays `channel_user`: what changes is the permissions array the app reads, which is
        // exactly the distinction the card draws (gate on ids, not on names).
        //
        // T40-AV F9: this mutates a shared role, so `setUp` repairs a strip a killed run left behind and
        // `restoreStrippedRole()` below runs as soon as the assertions are done, not only in `tearDown`.
        try stripChannelUserPermissions()
        // The premise, checked rather than assumed: if the write did not take (a server that caches
        // roles, a role id that moved), every assertion below would be about a server that was never
        // narrowed — and "the server answered 201" would look like an app defect.
        let strippedRole = try getJSON("/api/v4/roles/name/channel_user") as? [String: Any]
        XCTAssertEqual((strippedRole?["permissions"] as? [String])?.count, 8,
                      "the permission experiment must be in effect: channel_user has "
                      + "\((strippedRole?["permissions"] as? [String])?.count ?? -1) ids, not the "
                      + "stock member's 8")

        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetPersistedState",
                               "-uiTestForgetSession", serverURL.absoluteString,
                               "-uiTestSeedServer", serverURL.absoluteString,
                               "-uiTestSeedServerName", "Local Mattermost",
                               "-surfaceMode", "shell=native",
                               "-surfaceMode", "auth=native",
                               "-surfaceMode", "sidebar=native",
                               "-surfaceMode", "channelInfo=native",
                               "-uiTestLogLevel", "error",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // T40-R: XCTest injects `XCTAutomationSupport` into the **app** process, and a UI run makes it
        // log one os_log *fault* per captured runtime issue. libtrace then quarantines that process
        // (`__LIBTRACE_CLIENT_QUARANTINED_DUE_TO_HIGH_LOGGING_VOLUME__`) and the next snapshot
        // dereferences a NULL (`_platform_strcmp` under `runtime_issue_os_log_fault_callback`; two crash
        // reports from this suite). `OS_ACTIVITY_MODE=disable` stops os_log delivery in the app process,
        // which is the volume the quarantine reacts to. Test-only: the app is unchanged, and the
        // `-uiTestLogLevel` seam above is what a normal run keeps.
        app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"
        app.launch()
        signIn(app, login: memberLogin, password: memberPassword)

        // T40-AV F5: **no rail step**. `TeamSidebarDerivation.content` is `.single` for an account with
        // exactly one team, and `t40member` is in one team (`GET /users/me/teams` -> ["perf"]), so
        // waiting for `teamSidebar.team.<id>` waited for a control the design deliberately does not draw
        // — the assertion never ran. The channel row is revealed directly instead.
        let sidebarRow = revealSidebarRow(app, identifier: "channelSidebar.channel.\(channel.id)")
        XCTAssertTrue(sidebarRow.waitForExistence(timeout: 40),
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

        // And the server agrees the write would have been refused — asked with the **member's** token,
        // not the administrator's: an unprivileged add of *another* person answers 403. (Adding
        // myself would be a legal join and prove nothing.)
        let other = try userID(username: "opsbot")
        let memberSession = try authenticate(login: memberLogin, password: memberPassword)
        let who = try getJSON("/api/v4/users/me", token: memberSession.token) as? [String: Any]
        XCTAssertEqual(who?["username"] as? String, memberLogin,
                       "the request below must be made by the account under test, not the administrator")
        let refused = try sendJSONExpectingFailure("POST",
                                                   "/api/v4/channels/\(channel.id)/members",
                                                   body: ["user_id": other],
                                                   token: memberSession.token)
        XCTAssertEqual(refused, 403,
                       "the server must refuse the write this account's permissions do not allow")

        // The fixture goes back to how the rest of the suite expects it, immediately.
        restoreStrippedRole()
    }

    // MARK: - 7. Archive then unarchive, with the server as the oracle

    func testArchivingAndUnarchivingAChannelReachesTheServer() throws {
        let channel = try ensureChannel(named: standupName, displayName: "T40 Standup")
        try ensureMember(channel.id, userID: userID)

        let app = launchApp()
        openChannel(app, channel: channel)
        openChannelInfo(app)
        tapControl(app, "channelInfo.action.settings")

        let archive = element(app, "channelSettings.archive")
        XCTAssertTrue(archive.waitForExistence(timeout: 20),
                      "the settings screen must offer archive for a channel I administer:"
                      + "\n\(app.debugDescription)")
        archive.tap()
        tapControl(app, "channelSettings.archive.confirm")

        XCTAssertTrue(waitUntil(timeout: 20) { self.deleteAt(channel.id) != 0 },
                      "the archive must reach the server (delete_at stays 0)")

        // The settings screen closes on success; the info screen behind it is now an archived channel,
        // says so, and offers the restore.
        XCTAssertTrue(element(app, "channelInfo.archivedBanner").waitForExistence(timeout: 20),
                      "the screen must say the channel is archived:\n\(app.debugDescription)")
        let unarchive = element(app, "channelInfo.action.unarchive")
        XCTAssertTrue(unarchive.waitForExistence(timeout: 20),
                      "an archived channel must offer unarchive:\n\(app.debugDescription)")
        attach(app, "08-archived")

        unarchive.tap()
        tapControl(app, "channelInfo.unarchive.confirm")

        XCTAssertTrue(waitUntil(timeout: 20) { self.deleteAt(channel.id) == 0 },
                      "the unarchive must reach the server (delete_at must go back to 0)")
        // The screen follows the restore: the archived banner is gone.
        XCTAssertTrue(waitUntil(timeout: 20) { !element(app, "channelInfo.archivedBanner").exists },
                      "the banner must clear once the channel is restored:\n\(app.debugDescription)")
        attach(app, "09-unarchived")
    }

    // MARK: - 8. The open screen follows the socket (rename, add, remove)

    func testTheOpenInfoScreenFollowsRenameAndMembershipEvents() throws {
        let channel = try ensureChannel(named: standupName, displayName: "T40 Standup")
        try ensureMember(channel.id, userID: userID)
        let otherID = try userID(username: "opsbot")
        try ensureNotMember(channel.id, userID: otherID)
        let stamp = Int(Date().timeIntervalSince1970) % 1000
        let renamed = "T40 Standup \(stamp)"

        let app = launchApp()
        openChannel(app, channel: channel)
        openChannelInfo(app)
        let title = element(app, "channelInfo.title")
        XCTAssertTrue(title.waitForExistence(timeout: 20),
                      "the info screen must mount:\n\(app.debugDescription)")

        // 1. `channel_updated` — a rename from outside the app patches the **open** screen.
        _ = try putJSON("/api/v4/channels/\(channel.id)/patch", body: ["display_name": renamed])
        XCTAssertTrue(waitUntil(timeout: 20) { element(app, "channelInfo.title").label.contains(renamed) },
                      "an open screen must follow a rename without a reload: title is "
                      + "\"\(element(app, "channelInfo.title").label)\"")

        // 2. `user_added` — somebody else joins; the open screen's count and member list follow.
        let before = try memberIDs(channel.id).count
        _ = try postJSON("/api/v4/channels/\(channel.id)/members", body: ["user_id": otherID])
        XCTAssertTrue(waitUntil(timeout: 20) { self.memberIDs(channel.id).contains(otherID) },
                      "the add must reach the server")
        XCTAssertTrue(waitUntil(timeout: 20) {
            element(app, "channelInfo.memberCount").label.contains("\(before + 1) member")
        }, "the open screen must count a member who joined elsewhere: it says "
           + "\"\(element(app, "channelInfo.memberCount").label)\", the server says \(before + 1)")

        tapControl(app, "channelInfo.action.members")
        let otherRow = element(app, "channelMemberRow.\(otherID)")
        XCTAssertTrue(otherRow.waitForExistence(timeout: 20),
                      "the member list must gain a row from `user_added`:\n\(app.debugDescription)")
        attach(app, "10-socket-added")

        // 3. `user_removed` — the row goes without a refresh.
        //
        // The row must be there **now**. Without this line the removal assertion can pass vacuously: if
        // the socket never delivered the `user_added`, the row was never drawn and "it is gone" is true
        // for the wrong reason (measured in a relay run whose proxy did not carry the websocket — the add
        // assert failed and this one went green).
        XCTAssertTrue(otherRow.exists,
                      "the row must be on screen before the removal can be observed:\n\(app.debugDescription)")
        _ = try sendJSON("DELETE", "/api/v4/channels/\(channel.id)/members/\(otherID)",
                         body: nil, allowFailure: true)
        XCTAssertTrue(waitUntil(timeout: 20) { !element(app, "channelMemberRow.\(otherID)").exists },
                      "the row must go on a user_removed event:\n\(app.debugDescription)")

        // Restore the fixture's display name.
        _ = try putJSON("/api/v4/channels/\(channel.id)/patch", body: ["display_name": "T40 Standup"])
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

    /// The channel's id, for the teardown repair — `nil` when the fixture has no such channel.
    private func ensureChannelID(named name: String) throws -> String? {
        let row = (try? getJSON("/api/v4/teams/\(teamID!)/channels/name/\(name)")) as? [String: Any]
        return row?["id"] as? String
    }

    /// The non-admin account's user id, created by the seed script.
    private func ensureNonAdminUser() throws -> String {
        try userID(username: memberLogin)
    }

    /// Any team member's id by username (the fixture's `opsbot` is used as "somebody else").
    private func userID(username: String) throws -> String {
        let users = (try? getJSON("/api/v4/users?in_team=\(teamID!)&per_page=200")) as? [[String: Any]] ?? []
        if let match = users.first(where: { ($0["username"] as? String) == username }),
           let id = match["id"] as? String {
            return id
        }
        throw XCTSkip("the fixture account \(username) is missing — run scripts/t40_channel_seed.py")
    }

    // MARK: - Membership helpers (the oracle)

    /// The channel's member ids straight from the server, or `nil` — with the reason kept in
    /// `lastOracleFailure` instead of being flattened to "the server has nothing".
    private func memberIDs(_ channelID: String) -> Set<String> {
        do {
            let rows = try getJSON("/api/v4/channels/\(channelID)/members?per_page=200")
                as? [[String: Any]] ?? []
            lastOracleFailure = nil
            return Set(rows.compactMap { $0["user_id"] as? String })
        } catch {
            lastOracleFailure = error.localizedDescription
            XCTContext.runActivity(named: "oracle: members of \(channelID)") { _ in
                print("T40 oracle failure: \(error.localizedDescription)")
            }
            return []
        }
    }

    /// The channel's `delete_at` (0 = not archived), read from the server.
    private func deleteAt(_ channelID: String) -> Int {
        let row = (try? getJSON("/api/v4/channels/\(channelID)")) as? [String: Any]
        return (row?["delete_at"] as? Int) ?? 0
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
    /// permissions array does not. `restoreStrippedRole()` puts the array back.
    ///
    /// **Hazard (T40-AV F9):** this writes a *server-wide* role on the shared fixture. A test process
    /// killed between this call and the restore leaves every other card's live fixture stripped;
    /// `setUp`'s `repairChannelUserRoleIfStripped()` and `scripts/t40_channel_seed.py --reset-roles` are
    /// the two repairs, and `docs/t40-build-note.md` §6.1 documents why a per-membership role is not an
    /// option on this server (measured: `POST /roles` 404s, the guest role cannot be assigned, and this
    /// server's only assignable channel roles are `channel_user` and the *more* privileged
    /// `channel_admin`).
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

    private func restoreStrippedRole() {
        guard let snapshot = strippedRoleSnapshot else { return }
        _ = try? sendJSON("PUT", "/api/v4/roles/\(snapshot.roleID)/patch",
                          body: ["permissions": snapshot.permissions], allowFailure: true)
        strippedRoleSnapshot = nil
    }

    /// Put the fixture's `channel_user` back if an earlier, killed run left it stripped.
    ///
    /// Runs once per process. The signal is the permission ids an administrator needs on this fixture
    /// (`manage_public_channel_members` and friends): if they are missing, the role is not the fixture's,
    /// and every other card's live tests would run against a server where nobody may manage a channel.
    private func repairChannelUserRoleIfStripped() throws {
        guard !Self.repairedChannelUser else { return }
        Self.repairedChannelUser = true
        guard let role = try? getJSON("/api/v4/roles/name/channel_user") as? [String: Any],
              let roleID = role["id"] as? String,
              let current = role["permissions"] as? [String] else { return }
        let required = ["manage_public_channel_members", "delete_public_channel"]
        guard !required.allSatisfy(current.contains) else { return }
        print("T40: channel_user is missing \(required.filter { !current.contains($0) }) — "
              + "a killed run left it stripped; restoring the fixture's \(Self.fixtureChannelUserPermissions.count) ids")
        _ = try? sendJSON("PUT", "/api/v4/roles/\(roleID)/patch",
                          body: ["permissions": Self.fixtureChannelUserPermissions],
                          allowFailure: true)
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
                               "-uiTestLogLevel", "error",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // See the note in `testAnAccountWithoutThePermissionIsOfferedNoAdminAction`: libtrace's logging
        // quarantine kills the **app** process mid-snapshot on this host, and this is the volume knob
        // that stops it. Test-only.
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
        tapControl(app, "nativeChannelInfoButton")
        XCTAssertTrue(element(app, "channelInfo.sheet").waitForExistence(timeout: 20),
                      "the channel-info sheet must mount:\n\(app.debugDescription)")
    }

    /// Leave the pushed channel pane and show the channel sidebar again.
    ///
    /// The compact layout pushes the pane over the sidebar's tab, so a sidebar row can only be asserted
    /// **after** coming back — the T40-AV probe looked for one while the pane was on screen, where no
    /// sidebar is drawn at all.
    ///
    /// Two shapes, both measured:
    ///  * a pushed pane (a channel opened from the sidebar, or after a browser join) — the shell's Back
    ///    button pops it;
    ///  * the channel tab itself, with **no push to pop**: measured right after a leave, the shell sat on
    ///    the channel tab with `backToolbarButton` *disabled*, so a back tap could never work — the way
    ///    out is the tab bar's Channels item.
    private func showSidebar(_ app: XCUIApplication) {
        if element(app, "nativeSidebar").exists { return }
        let back = app.navigationBars.firstMatch.buttons.element(boundBy: 0)
        if back.exists, back.isHittable { back.tap() }
        if !element(app, "nativeSidebar").waitForExistence(timeout: 5) {
            let channelsTab = app.tabBars.buttons["Channels"]
            if channelsTab.exists, channelsTab.isHittable { channelsTab.tap() }
        }
        XCTAssertTrue(element(app, "nativeSidebar").waitForExistence(timeout: 20),
                      "the shell must be back on the channel sidebar:\n\(app.debugDescription)")
    }

    /// Put the keyboard away without leaving the screen.
    ///
    /// Deliberately no navigation-bar tap: `app.navigationBars.firstMatch` can resolve to the **shell's**
    /// bar behind a presented sheet, and tapping it dismisses the sheet (measured on the settings form).
    /// A slow drag inside the scrollable container scrolls it and, under the default interactive
    /// dismissal, takes the keyboard with it.
    @discardableResult
    private func dismissKeyboard(_ app: XCUIApplication, inside container: String) -> Bool {
        var attempts = 0
        while app.keyboards.count > 0, attempts < 3 {
            element(app, container).swipeUp(velocity: .slow)
            attempts += 1
        }
        return app.keyboards.count == 0
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
              let token = http.value(forHTTPHeaderField: "Token"),
              let user = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = user["id"] as? String else {
            // The status travels with the skip: 429 is the server's login rate limiter (ten attempts a
            // minute — measured while this suite and a probe script shared an IP), and 401 is a wrong
            // password. "Could not sign in" alone made those two look alike.
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])??["id"] as? String
            throw XCTSkip("could not sign in as \(login) (password length \(password.count)) on \(serverURL.absoluteString) (HTTP \(status), \(reason ?? "no error id"))")
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

    /// A URL for an API path that may carry a query string.
    ///
    /// `appendingPathComponent` percent-encodes a `?`, so `/members?per_page=200` became
    /// `/members%3Fper_page=200` and the server answered 404 "there doesn't appear to be an api call for
    /// the url" — which the oracle then read as "no members". The query is split off and set as a query
    /// component instead.
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

    private func getJSON(_ path: String, token override: String? = nil) throws -> Any {
        var request = URLRequest(url: url(for: path))
        request.setValue("Bearer \(override ?? token!)", forHTTPHeaderField: "Authorization")
        let (data, response) = try synchronous(request)
        // An oracle that reads a 401 as "the server has nothing" is worse than no oracle: every
        // "the screen must match the server" assertion would then compare against an empty answer.
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NSError(domain: "T40Oracle", code: status, userInfo: [
                NSLocalizedDescriptionKey:
                    "GET \(path) -> HTTP \(status) \(String(decoding: data.prefix(200), as: UTF8.self))"])
        }
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
        var request = URLRequest(url: url(for: path))
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
        var request = URLRequest(url: url(for: path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (_, response) = try synchronous(request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    /// The REST oracle's own session — **no cookie store**.
    ///
    /// `URLSession.shared` keeps an `MMAUTHTOKEN` cookie from any earlier login of this process, and the
    /// server answers `api.context.session_expired.app_error` (401) for a request that carries a stale
    /// one — before it ever looks at the body, so a correct password reads as "wrong password". The
    /// app itself authenticates with the `Authorization` header and no cookies, and so must the oracle.
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

    /// Any element type: SwiftUI puts these identifiers on labels, buttons, cells and collections
    /// depending on the container, so a type-specific query could silently never match.
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The control itself, preferring a typed `buttons` query.
    ///
    /// A SwiftUI toolbar item's identifier can resolve on its *container* (an `Other` element): tapping
    /// that element's centre is not the same as tapping the button (T40-AV F1 logged
    /// `Find the "addMembers.submit" Other`). The typed query answers the Button, which is what a
    /// reader's finger meets, and it carries the enabled state a disabled row withholds.
    private func control(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        let typed = app.buttons.matching(identifier: identifier).firstMatch
        return typed.exists ? typed : element(app, identifier)
    }

    /// A control that must answer as a **button** — used where the assertion is about `isEnabled`.
    ///
    /// The generic `descendants` query can answer a container that is never disabled, which would make
    /// "the button enabled" pass for the wrong reason. This one asserts the type.
    private func assertButton(_ app: XCUIApplication, _ identifier: String,
                              timeout: TimeInterval = 10) -> XCUIElement {
        let typed = app.buttons.matching(identifier: identifier).firstMatch
        XCTAssertTrue(typed.waitForExistence(timeout: timeout),
                      "\(identifier) must exist as a button, not just a container:"
                      + "\n\(app.debugDescription)")
        return typed
    }

    /// Tap a control by identifier, preferring the typed query (see `control`).
    private func tapControl(_ app: XCUIApplication, _ identifier: String) {
        let typed = app.buttons.matching(identifier: identifier).firstMatch
        if typed.waitForExistence(timeout: 5), typed.isHittable {
            typed.tap()
            return
        }
        let fallback = element(app, identifier)
        if fallback.waitForExistence(timeout: 5) { fallback.tap() }
    }

    /// Scroll the sidebar until `identifier` exists.
    ///
    /// Three rules, each measured:
    ///  * a row arrives a beat after sign-in (the channel list is a request), so "not there yet" is not
    ///    "not there": the wait below is 15 s **before** any scrolling;
    ///  * the scroll container is the sidebar's `List`, which SwiftUI exposes as a collection view. An
    ///    `.accessibilityIdentifier` on the `List` itself does **not** surface as an element (tried and
    ///    measured in suite3), so the container is found by type — safe here because these helpers are
    ///    only used while the sidebar is the screen on show, where it owns the only list;
    ///  * if the sidebar is not the screen on show, swiping "something" is worse than failing: the old
    ///    fallback swiped the whole app, scrolled the post list 25 times and crashed an XCTest snapshot
    ///    pass on the resulting log volume. `nativeSidebar` — the sidebar's own anchor row — is the test
    ///    for "we are on the sidebar".
    @discardableResult
    private func revealSidebarRow(_ app: XCUIApplication, identifier: String,
                                  maxSwipes: Int = 25) -> XCUIElement {
        let target = element(app, identifier)
        if target.waitForExistence(timeout: 15) { return target }
        XCTAssertTrue(element(app, "nativeSidebar").exists,
                      "the sidebar must be the screen on show before a row can be scrolled for:"
                      + "\n\(app.debugDescription)")
        let container = app.collectionViews.firstMatch
        guard container.exists else { return target }
        var swipes = 0
        while !target.exists, swipes < maxSwipes {
            container.swipeUp(velocity: .fast)
            swipes += 1
        }
        return target
    }

    /// Whether the sidebar lists `identifier`, scanning the list from the top.
    ///
    /// A lazy `List` only builds its viewport, so "the element does not exist" is not the same as "the
    /// row is not in the list". This scrolls the whole way and answers honestly. Kept for the leave
    /// test's own future use: the shell cannot currently navigate back to the sidebar after a leave
    /// (see that test's note and `docs/t40-build-note.md` §6), so no test calls it today.
    private func sidebarLists(_ app: XCUIApplication, identifier: String, maxSwipes: Int = 12) -> Bool {
        let container = app.collectionViews.firstMatch
        guard container.exists else { return element(app, identifier).exists }
        for _ in 0..<3 { container.swipeDown(velocity: .fast) }
        if element(app, identifier).exists { return true }
        var swipes = 0
        while swipes < maxSwipes {
            container.swipeUp(velocity: .fast)
            if element(app, identifier).exists { return true }
            swipes += 1
        }
        return false
    }

    /// Scroll a **sheet's own** list until `identifier` exists.
    ///
    /// `revealSidebarRow` scrolls the sidebar; inside a sheet the gesture has to start on the sheet, and
    /// a short drag (not a fling) keeps the lazy list from overshooting the row (T40-AV F6).
    @discardableResult
    private func revealInSheet(_ app: XCUIApplication, sheet: String, identifier: String,
                               maxSwipes: Int = 25) -> XCUIElement {
        let target = element(app, identifier)
        guard !target.exists else { return target }
        let container = element(app, sheet)
        var swipes = 0
        while !target.exists, swipes < maxSwipes {
            let start = container.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            let end = container.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            start.press(forDuration: 0.05, thenDragTo: end)
            swipes += 1
        }
        return target
    }

    /// Reveal a row's trailing swipe actions by dragging across the row itself.
    ///
    /// `XCUIElement.swipeLeft()` runs the gesture on the element the identifier resolved to — inside a
    /// SwiftUI `List` row that is the avatar's `StaticText` (~32pt wide), which is too narrow to carry a
    /// row swipe; measured: the swipe was synthesised and no action ever appeared. This drags from 90% to
    /// 15% of the row's width at the row's own vertical centre, which is what a finger does.
    private func revealRowSwipeActions(_ app: XCUIApplication, row: XCUIElement) {
        let frame = row.frame
        let centre = frame.midY
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: app.frame.width * 0.90, dy: centre))
        let end = origin.withOffset(CGVector(dx: app.frame.width * 0.15, dy: centre))
        start.press(forDuration: 0.08, thenDragTo: end)
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
