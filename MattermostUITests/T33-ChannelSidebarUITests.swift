import XCTest

/// T33 — the native channel sidebar against a **real** Mattermost server, with the browser's numbers
/// standing in for nothing: every expectation is read back from the server through its own API.
///
/// Why a live suite (the card's DoD forbids fixture-only evidence): the four acceptance criteria are
/// all statements about *the server's* state —
///   1. grouping/order come from the server's sidebar categories, and a reorder persists;
///   2. unread/mention bold state moves with real socket events;
///   3. a muted channel shows no unread state and leaves the totals the way the web app does;
///   4. the quick switcher finds channels and DMs and navigates.
/// A stub can only prove that the client renders what the test author already decided; these tests
/// prove it renders what a running `mattermost` server reports.
///
/// Run (the fixture server is the local throwaway one; credentials live in `scripts/perf_seed.py`):
///
///     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
///     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
///     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
///     python3 scripts/qa-test.py --platform ios --sim <iPad sim> \
///       --only-testing MattermostUITests/T33ChannelSidebarUITests
///
/// Each test skips (never fails) when the env or the server is missing, like every live test here.
final class T33ChannelSidebarUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var userID: String!
    /// The team the shell opens on (`teams_order` puts `perf` first in the fixture).
    private var teamID: String!
    /// A second account that can post into the same team: the unread/mention tests must be caused by
    /// *another user's* message over the socket, not by this test writing a counter.
    private var botLogin: String!
    private var botPassword: String!
    private var cachedBot: (token: String, userID: String)?

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live channel-sidebar test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        try ping()
        let session = try authenticate(login: loginID, password: password)
        token = session.token
        userID = session.userID
        teamID = try firstTeamID()
        botLogin = env["MM_AUTH_BOT_LOGIN"] ?? "opsbot"
        botPassword = env["MM_AUTH_BOT_PASSWORD"] ?? "OpsBot-Not-A-Real-Secret-1"
    }

    /// The second account, signed in once per test, and *made a member* of the team's channels: on a
    /// freshly seeded server the bot may only be in the other team, and a 403 from `POST /posts`
    /// would otherwise look like a client bug.
    private func botSession() throws -> (token: String, userID: String) {
        if let cachedBot { return cachedBot }
        let session = try authenticate(login: botLogin, password: botPassword)
        let channels = try teamChannels()
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/teams/\(teamID!)/members"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["team_id": teamID!,
                                                                      "user_id": session.userID])
        _ = try? synchronous(request)
        for channel in channels {
            var join = URLRequest(url: serverURL.appendingPathComponent(
                "api/v4/channels/\(channel.id)/members"))
            join.httpMethod = "POST"
            join.setValue("application/json", forHTTPHeaderField: "Content-Type")
            join.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
            join.httpBody = try JSONSerialization.data(withJSONObject: ["user_id": session.userID])
            _ = try? synchronous(join)     // 400 = already a member, which is the normal case
        }
        cachedBot = session
        return session
    }

    // MARK: - 1. The list renders the server's channels and categories

    func testTheSidebarRendersTheServersChannelsAndCategories() throws {
        let channels = try teamChannels()
        XCTAssertGreaterThanOrEqual(channels.count, 3, "the fixture team has at least three channels")

        let app = launchAndSignIn()
        let pane = element(app, "nativeTeamSidebar")
        XCTAssertTrue(pane.waitForExistence(timeout: 40), "the native sidebar must mount:\n\(app.debugDescription)")

        XCTAssertTrue(element(app, "channelSidebar.category.channels").waitForExistence(timeout: 30),
                      "the server's `channels` category must draw:\n\(app.debugDescription)")

        for channel in channels {
            let row = element(app, "channelSidebar.channel.\(channel.id)")
            XCTAssertTrue(row.waitForExistence(timeout: 20),
                          "channel \(channel.name) is in the server's answer but not on screen:\n"
                          + "\(app.debugDescription)")
            if channel.type == "G" {
                // A group message's label is every resolved member joined; the test only insists the
                // raw `id__a__b__c` form is not what is drawn.
                XCTAssertFalse(row.label.contains("__"),
                               "a group message must not be drawn as its raw id, got '\(row.label)'")
            } else {
                XCTAssertEqual(row.label, try expectedLabel(for: channel),
                               "the row's label must be the name the server gives it — for a DM that "
                               + "is the other person, resolved, not `id__a__b`")
            }
        }
        attachShot(app, named: "t33-01-channel-list-real-server")
    }

    // MARK: - 2. The quick switcher finds and opens

    func testTheQuickSwitcherFuzzyFindsAChannelAndOpensIt() throws {
        let channels = try teamChannels()
        guard let target = channels.first(where: { $0.name == "perf-feed" }) ?? channels.first else {
            return XCTFail("the fixture team has no channels")
        }
        // A subsequence of the channel's name: p-f-f-d inside "perf-feed". Not a substring, so a
        // filter-only switcher could not find it.
        let query = target.name == "perf-feed" ? "pffd" : String(target.name.prefix(2))

        let app = launchAndSignIn()
        let opener = element(app, "channelSidebar.quickSwitcher")
        XCTAssertTrue(opener.waitForExistence(timeout: 40), "the pane must offer the switcher:\n\(app.debugDescription)")
        opener.tap()

        let field = app.textFields["channelSidebar.quickSwitcher.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), "the switcher must focus a search field")
        field.tap()
        field.typeText(query)

        let result = element(app, "channelSidebar.quickSwitcher.result.\(target.id)")
        XCTAssertTrue(result.waitForExistence(timeout: 15),
                      "fuzzy query '\(query)' must find \(target.name):\n\(app.debugDescription)")
        attachShot(app, named: "t33-02-quick-switcher-fuzzy")
        result.tap()

        // Navigating is the shell's own funnel: the channel pane shows the channel the server gave.
        let title = element(app, "nativeChannelTitle")
        XCTAssertTrue(title.waitForExistence(timeout: 20), "the channel view must open")
        XCTAssertEqual(title.label, target.name)
        // ...and the switcher is a gesture, so it must be gone. Without this the test would pass with
        // the sheet still covering the pane, because a presented sheet does not remove the pane
        // behind it from the accessibility tree.
        XCTAssertTrue(waitUntil(timeout: 10) { !field.exists },
                      "choosing a result must close the switcher")
        attachShot(app, named: "t33-03-quick-switcher-opened")
    }

    // MARK: - 3. Unread + mention state moves live over the socket

    func testUnreadAndMentionBoldStateMovesLiveAfterAnotherUsersPost() throws {
        let channels = try teamChannels()
        // `off-topic` is the fixture channel the second user (`opsbot`) is a member of, so it can
        // post there; the app's team on screen is `perf`, so the socket routes it to this list.
        guard let target = channels.first(where: { $0.name == "off-topic" }) ?? channels.first else {
            return XCTFail("the fixture team has no channels")
        }
        // Start from a known state: everything read (the fixture accumulates counts across runs).
        try markAllRead(channels)

        let app = launchAndSignIn()
        let row = element(app, "channelSidebar.channel.\(target.id)")
        XCTAssertTrue(row.waitForExistence(timeout: 40), "the channel row must be on screen:\n\(app.debugDescription)")
        XCTAssertFalse((row.value as? String ?? "").contains("Unread"),
                       "the channel was just marked read, so it cannot start bold: '\(row.value ?? "nil")'")

        // Another user posts (the real socket path: the server pushes `posted` + `post_unread`).
        let bot = try botSession()
        var postedIDs: [String] = []
        if let id = try post("live probe: an ordinary message", channelID: target.id, token: bot.token) {
            postedIDs.append(id)
        }

        XCTAssertTrue(waitUntil(timeout: 45) {
            (row.value as? String ?? "").contains("Unread")
        }, "a post in another channel of the open team must make the row bold within the socket round "
           + "trip, got '\(row.value ?? "nil")'")
        attachShot(app, named: "t33-04-live-unread")

        // …and a mention moves the badge, not just the bold state.
        if let id = try post("live probe: @\(loginID!) please look", channelID: target.id, token: bot.token) {
            postedIDs.append(id)
        }
        XCTAssertTrue(waitUntil(timeout: 45) {
            (row.value as? String ?? "").contains("mention")
        }, "an @-mention must turn into a mention badge, got '\(row.value ?? "nil")'")
        attachShot(app, named: "t33-05-live-mention")

        // The numbers on screen are the server's numbers (read fresh, not from the post's response).
        let serverMentions = try memberRow(channelID: target.id).mentionCount
        XCTAssertTrue((row.value as? String ?? "").contains("\(serverMentions) mention"),
                      "the row must show the server's own mention count (\(serverMentions)), "
                      + "got '\(row.value ?? "nil")'")

        // Leave the fixture the way it was found.
        for id in postedIDs { try? delete(id, token: bot.token) }
        try markAllRead(channels)
    }

    // MARK: - 4. Muting: the server's rule, then the shell's rendering of it

    func testAMutedChannelShowsNoUnreadStateAndLeavesTheTotals() throws {
        let channels = try teamChannels()
        guard let muted = channels.first(where: { $0.name == "off-topic" }) ?? channels.first,
              let other = channels.first(where: { $0.name == "town-square" })
                  ?? channels.first(where: { $0.id != muted.id }) else {
            return XCTFail("the fixture team needs a muted channel and an unmuted control channel")
        }
        try markAllRead(channels)
        try setMuted(true, channelID: muted.id)
        var posted: [(String, String)] = []   // (token, post id) for cleanup
        defer {
            try? setMuted(false, channelID: muted.id)
            for (token, id) in posted { try? delete(id, token: token) }
            try? markAllRead(channels)
        }

        // Traffic in the muted channel *before* the app ever loads: the shell must derive "muted"
        // from the membership row, not from having watched someone mute it.
        let bot = try botSession()
        if let id = try post("live probe: muted channel traffic", channelID: muted.id, token: bot.token) {
            posted.append((bot.token, id))
        }
        // What the server itself reports: the counters are **not** mute-aware — `msg_count` is the
        // cursor from the last view, so one post leaves one unread message even though the channel is
        // muted (`mark_unread: mention` is a client-side rule, not a server-side suppression).
        // Asserting the number makes the next assertion non-vacuous: the *client* is what hides it.
        let afterTraffic = try memberRow(channelID: muted.id)
        let totalAfterTraffic = try totalMsgCount(channelID: muted.id)
        XCTAssertEqual(max(totalAfterTraffic - afterTraffic.msgCount, 0), 1,
                       "the server must report exactly one unread message in the muted channel "
                       + "(total \(totalAfterTraffic), msg_count \(afterTraffic.msgCount)); without "
                       + "that, the client-side suppression below would prove nothing")

        let app = launchAndSignIn()
        let row = element(app, "channelSidebar.channel.\(muted.id)")
        XCTAssertTrue(row.waitForExistence(timeout: 40), "the muted channel must still be listed:\n\(app.debugDescription)")
        let value = row.value as? String ?? ""
        XCTAssertTrue(value.contains("Muted"), "the row must say it is muted, got '\(value)'")
        XCTAssertFalse(value.contains("Unread"),
                       "a muted channel must not show unread emphasis, got '\(value)'")

        let totals = element(app, "channelSidebar.totals")
        XCTAssertTrue(totals.waitForExistence(timeout: 10))
        XCTAssertEqual(totals.label, "All caught up",
                       "the muted channel must not reach the totals, got '\(totals.label)'")
        attachShot(app, named: "t33-06-muted-channel")

        // …and the exception mute keeps: a *mention* still badges on a muted channel (upstream shows
        // `unreadMentions` regardless of mute; only the message-count emphasis is suppressed).
        if let id = try post("live probe: @\(loginID!) a mention through the mute",
                             channelID: muted.id, token: bot.token) {
            posted.append((bot.token, id))
        }
        XCTAssertTrue(waitUntil(timeout: 45) {
            (row.value as? String ?? "").contains("mention")
        }, "an @-mention must reach a muted channel's badge, got '\(row.value ?? "nil")'")
        XCTAssertTrue((row.value as? String ?? "").contains("Muted"),
                      "the mention must not un-mute the row, got '\(row.value ?? "nil")'")
        // The footer is **desktop-exact**: a muted channel contributes nothing to the badge totals,
        // mentions included (`getTeamsUnreadStatuses`: "if channel is muted, we skip its count").
        // Give the socket round trip time to land before asserting silence (T33-AV F2).
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertEqual(element(app, "channelSidebar.totals").label, "All caught up",
                       "a muted channel's mention must not reach the footer aggregate, got "
                       + "'\(element(app, "channelSidebar.totals").label)'")
        attachShot(app, named: "t33-07-muted-mention")

        // Control: the same traffic in a non-muted channel *does* move the totals, so the assertions
        // above are not vacuous.
        if let id = try post("live probe: unmuted channel traffic", channelID: other.id, token: bot.token) {
            posted.append((bot.token, id))
        }
        XCTAssertTrue(waitUntil(timeout: 45) {
            element(app, "channelSidebar.totals").label != "All caught up"
        }, "unmuted traffic must move the totals; the mute assertions above would otherwise prove nothing")
        attachShot(app, named: "t33-08-totals-move")
    }

    // MARK: - 5. A reorder is a server write and survives relaunch

    func testAReorderThroughTheContextMenuWritesTheServerAndSurvivesRelaunch() throws {
        let channels = try teamChannels()
        try markAllRead(channels)
        var before = try channelsCategoryOrder()
        guard before.count >= 2 else {
            return XCTFail("the channels category needs at least two channels to reorder")
        }
        defer { try? restoreChannelsOrder(before) }

        let app = launchAndSignIn()
        let moverID = before[1]          // second row: "Move up" is available and changes the order
        let mover = element(app, "channelSidebar.channel.\(moverID)")
        XCTAssertTrue(mover.waitForExistence(timeout: 40), "the row must be on screen:\n\(app.debugDescription)")

        // The row's second action (long press / secondary click) carries the reorder; the same write a
        // drag makes goes out: PUT /users/{uid}/teams/{tid}/channels/categories.
        mover.press(forDuration: 1.2)
        let moveUp = app.buttons["Move up"]
        XCTAssertTrue(moveUp.waitForExistence(timeout: 10),
                      "the context menu must offer the reorder:\n\(app.debugDescription)")
        moveUp.tap()

        var expected = before
        expected.swapAt(0, 1)
        XCTAssertTrue(waitUntil(timeout: 30) {
            (try? channelsCategoryOrder()) == expected
        }, "the reorder must reach the server, expected \(expected), got \((try? channelsCategoryOrder()) ?? before)")

        // (b) **the row on screen moves too.** The defect T33-AV F1 measured was that the server kept
        // the write while the app rolled the row back behind an error banner; asserting only the
        // server (as this test used to) cannot see that.
        XCTAssertTrue(waitUntil(timeout: 20) {
            drawnAbove(app, expected[0], expected[1])
        }, "the row must stay where the server put it (the T33-AV F1 rollback would draw \(before[0]) "
           + "above \(before[1]) again)")
        // (c) …and nothing is reported as a failed write.
        XCTAssertFalse(element(app, "channelSidebar.actionError").exists,
                       "a write the server accepted must not be reported as an error:\n\(app.debugDescription)")
        attachShot(app, named: "t33-10-reorder-on-screen")
        let serverOrderAfterMove = try channelsCategoryOrder()

        // Relaunch: a fresh process, a fresh load, no in-memory order to fall back on.
        app.terminate()
        let relaunched = launchAndSignIn()
        let first = element(relaunched, "channelSidebar.channel.\(serverOrderAfterMove[0])")
        let second = element(relaunched, "channelSidebar.channel.\(serverOrderAfterMove[1])")
        XCTAssertTrue(first.waitForExistence(timeout: 40) && second.waitForExistence(timeout: 40),
                      "both rows must be on screen after relaunch:\n\(relaunched.debugDescription)")
        XCTAssertLessThan(first.frame.minY, second.frame.minY,
                          "the persisted order must be the order drawn after relaunch "
                          + "(\(serverOrderAfterMove[0]) above \(serverOrderAfterMove[1]))")
        attachShot(relaunched, named: "t33-09-reorder-after-relaunch")

        // Leave the fixture tidy. Best effort by design: the assertions above are the test, and a
        // cleanup write is not worth failing the card over (the fixture order is arbitrary either way).
        try? restoreChannelsOrder(before)
    }

    // MARK: - 6. A layout change made by another client reaches the open list (T33-AV F3)

    /// The inverted T33-AV probe: an external `PUT` while the app is open must move the rows on
    /// screen over the socket (`sidebar_category_updated`), with no relaunch and no team switch.
    func testALayoutChangeFromAnotherClientReachesTheOpenListWithoutARelaunch() throws {
        let channels = try teamChannels()
        try markAllRead(channels)
        let before = try channelsCategoryOrder()
        guard before.count >= 2 else {
            return XCTFail("the channels category needs at least two channels to reorder")
        }
        try setChannelsCategoryCollapsed(false)
        defer { try? restoreChannelsOrder(before) }

        let app = launchAndSignIn()
        let first = element(app, "channelSidebar.channel.\(before[0])")
        let second = element(app, "channelSidebar.channel.\(before[1])")
        XCTAssertTrue(first.waitForExistence(timeout: 40) && second.waitForExistence(timeout: 40),
                      "both rows must be on screen:\n\(app.debugDescription)")
        XCTAssertTrue(drawnAbove(app, before[0], before[1]),
                      "the list must start in the server's order (\(before))")

        // Another client — this test, as the same user — writes the layout while the app is running.
        try reorderChannelsFromAnotherClient(swapping: before[0], before[1])
        let after = try channelsCategoryOrder()
        XCTAssertEqual(Array(after.prefix(2)), [before[1], before[0]],
                       "the external write must land on the server, got \(after)")

        XCTAssertTrue(waitUntil(timeout: 30) { drawnAbove(app, before[1], before[0]) },
                      "a layout written by another client must reach the open list over the socket — "
                      + "the T33-AV F3 defect left it unchanged until a relaunch")
        XCTAssertEqual(app.state, .runningForeground, "the change must arrive without relaunching")
        XCTAssertFalse(element(app, "channelSidebar.actionError").exists)
        attachShot(app, named: "t33-11-external-layout")
    }

    // MARK: - 7. A collapse is a server write (the other half of T33-AV F1)

    func testCollapsingACategoryReachesTheServerAndSurvivesRelaunch() throws {
        let channels = try teamChannels()
        guard let target = channels.first(where: { $0.name == "town-square" }) ?? channels.first else {
            return XCTFail("the fixture team has no channels")
        }
        try markAllRead(channels)
        try setChannelsCategoryCollapsed(false)
        defer { try? setChannelsCategoryCollapsed(false) }

        let app = launchAndSignIn()
        XCTAssertTrue(element(app, "channelSidebar.channel.\(target.id)").waitForExistence(timeout: 40),
                      "the row must be on screen before collapsing:\n\(app.debugDescription)")
        let header = element(app, "channelSidebar.category.channels")
        XCTAssertTrue(header.waitForExistence(timeout: 20))
        header.tap()

        XCTAssertTrue(waitUntil(timeout: 20) { (try? channelsCategoryCollapsed()) == true },
                      "a collapse must reach the server — the defect this card repairs discarded the "
                      + "write with `try?`, so the local header and the server disagreed forever")

        // Relaunch: the server's value is what draws.
        app.terminate()
        let relaunched = launchAndSignIn()
        XCTAssertTrue(element(relaunched, "channelSidebar.category.channels").waitForExistence(timeout: 40),
                      "the category header must mount:\n\(relaunched.debugDescription)")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertFalse(element(relaunched, "channelSidebar.channel.\(target.id)").exists,
                       "a collapsed category draws no rows after a relaunch")
        attachShot(relaunched, named: "t33-12-collapsed-after-relaunch")
    }

    // MARK: - Launch + sign-in

    private func launchAndSignIn() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetPersistedState",
                               "-uiTestForgetSession", serverURL.absoluteString,
                               "-uiTestSeedServer", serverURL.absoluteString,
                               "-uiTestSeedServerName", "Local Mattermost",
                               "-surfaceMode", "shell=native",
                               "-surfaceMode", "auth=native",
                               // T33's own flag: the channel list replaces T30's placeholder only
                               // when the `sidebar` surface resolves native.
                               "-surfaceMode", "sidebar=native",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        signIn(app)
        return app
    }

    /// The production native sign-in form, driven the way a person drives it.
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
        XCTAssertTrue(element(app, "nativeShell").waitForExistence(timeout: 40),
                      "signing in must reach the shell:\n\(app.debugDescription)")
    }

    // MARK: - Server access (the test is its own API client, so nothing is assumed)

    private struct Channel {
        let id: String
        let name: String
        let displayName: String
        let type: String
    }

    private struct Member {
        let msgCount: Int
        let mentionCount: Int
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

    private func teamChannels() throws -> [Channel] {
        let rows = try getJSON("/api/v4/users/me/teams/\(teamID!)/channels") as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = row["id"] as? String, let name = row["name"] as? String else { return nil }
            let display = (row["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
            return Channel(id: id, name: name, displayName: display,
                           type: row["type"] as? String ?? "")
        }
    }

    /// What a row is supposed to say. The server's `display_name` answers for every channel except a
    /// DM/GM, where it is empty and `name` is `id__a__b` — the shell resolves those to the other people
    /// (`ChannelSidebarService.resolveDirectLabels`, the same thing desktop shows), so the expectation
    /// is resolved here the same way rather than comparing against the raw id form.
    private func expectedLabel(for channel: Channel) throws -> String {
        guard channel.type == "D" else { return channel.displayName }
        let others = channel.name.components(separatedBy: "__").filter { !$0.isEmpty && $0 != userID }
        guard let other = others.first else { return channel.displayName }
        let user = try getJSON("/api/v4/users/\(other)") as? [String: Any] ?? [:]
        let nickname = user["nickname"] as? String ?? ""
        if !nickname.isEmpty { return nickname }
        let full = [user["first_name"], user["last_name"]].compactMap { $0 as? String }
            .filter { !$0.isEmpty }.joined(separator: " ")
        if !full.isEmpty { return full }
        return (user["username"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? channel.displayName
    }

    /// The membership row the app reads (`/users/me/channel_members`), so a badge expectation is the
    /// server's number rather than this test's arithmetic.
    private func memberRow(channelID: String) throws -> Member {
        let rows = try getJSON("/api/v4/users/me/channel_members") as? [[String: Any]] ?? []
        guard let row = rows.first(where: { ($0["channel_id"] as? String) == channelID }) else {
            throw XCTSkip("no membership row for \(channelID)")
        }
        return Member(msgCount: row["msg_count"] as? Int ?? 0,
                      mentionCount: row["mention_count"] as? Int ?? 0)
    }

    /// Mark every channel of the fixture team read, so "no bold" is a fact rather than a leftover.
    private func markAllRead(_ channels: [Channel]) throws {
        for channel in channels {
            var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/channels/members/\(userID!)/view"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["channel_id": channel.id])
            _ = try? synchronous(request)
        }
    }

    @discardableResult
    private func post(_ message: String, channelID: String, token: String) throws -> String? {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/posts"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["channel_id": channelID,
                                                                      "message": message])
        let (data, response) = try synchronous(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        XCTAssertEqual(status, 201, "posting as the other user must succeed (got \(status))")
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String
    }

    private func delete(_ postID: String, token: String) throws {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/posts/\(postID)"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? synchronous(request)
    }

    /// `total_msg_count` off a fresh channel read — the other half of the unread formula.
    private func totalMsgCount(channelID: String) throws -> Int {
        let row = try getJSON("/api/v4/channels/\(channelID)") as? [String: Any] ?? [:]
        return row["total_msg_count"] as? Int ?? 0
    }

    // MARK: - The server's sidebar layout (categories = the user's sidebar preferences)

    private func categoriesPayload() throws -> [String: Any] {
        try getJSON("/api/v4/users/\(userID!)/teams/\(teamID!)/channels/categories")
            as? [String: Any] ?? [:]
    }

    /// The `channels` category's `channel_ids`, in the server's own order.
    private func channelsCategoryOrder() throws -> [String] {
        let categories = (try categoriesPayload()["categories"] as? [[String: Any]]) ?? []
        let channels = categories.first { ($0["type"] as? String) == "channels" }
        return (channels?["channel_ids"] as? [String]) ?? []
    }

    private func restoreChannelsOrder(_ ids: [String]) throws {
        let payload = try categoriesPayload()
        var categories = (payload["categories"] as? [[String: Any]]) ?? []
        guard let index = categories.firstIndex(where: { ($0["type"] as? String) == "channels" }) else {
            return
        }
        categories[index]["channel_ids"] = ids
        try writeCategories(categories, because: "restoring the fixture order")
    }

    /// Write the whole category array the way the app does. **The body is the bare array**: the
    /// endpoint rejects the GET's `{order, categories}` envelope with 400 (T33-AV F1/F6), which is what
    /// made this suite's cleanup a silent no-op.
    private func writeCategories(_ categories: [[String: Any]], because reason: String) throws {
        var request = URLRequest(url: serverURL.appendingPathComponent(
            "api/v4/users/\(userID!)/teams/\(teamID!)/channels/categories"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: categories)
        let (_, response) = try synchronous(request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200,
                       "\(reason) must be a successful categories write")
    }

    /// The `channels` category's `collapsed` flag, straight from the server.
    private func channelsCategoryCollapsed() throws -> Bool {
        let categories = (try categoriesPayload()["categories"] as? [[String: Any]]) ?? []
        return (categories.first { ($0["type"] as? String) == "channels" }?["collapsed"] as? Bool) ?? false
    }

    private func setChannelsCategoryCollapsed(_ collapsed: Bool) throws {
        let payload = try categoriesPayload()
        var categories = (payload["categories"] as? [[String: Any]]) ?? []
        guard let index = categories.firstIndex(where: { ($0["type"] as? String) == "channels" }) else {
            return
        }
        categories[index]["collapsed"] = collapsed
        try writeCategories(categories, because: "setting the category's collapsed state")
    }

    /// Another client's write, as the app's own user: exactly the shape the defect was found with
    /// (`testAV33ALayoutChangeFromAnotherClientWhileTheAppIsOpen`).
    private func reorderChannelsFromAnotherClient(swapping first: String, _ second: String) throws {
        var ids = try channelsCategoryOrder()
        guard let a = ids.firstIndex(of: first), let b = ids.firstIndex(of: second) else {
            return XCTFail("both channels must be in the `channels` category, got \(ids)")
        }
        ids.swapAt(a, b)
        let payload = try categoriesPayload()
        var categories = (payload["categories"] as? [[String: Any]]) ?? []
        guard let index = categories.firstIndex(where: { ($0["type"] as? String) == "channels" }) else {
            return XCTFail("the fixture has no `channels` category")
        }
        categories[index]["channel_ids"] = ids
        try writeCategories(categories, because: "an external layout write")
    }

    /// True when `first` is drawn above `second` — the only honest way to read "the order on screen".
    private func drawnAbove(_ app: XCUIApplication, _ first: String, _ second: String) -> Bool {
        let top = element(app, "channelSidebar.channel.\(first)")
        let bottom = element(app, "channelSidebar.channel.\(second)")
        guard top.exists, bottom.exists else { return false }
        return top.frame.minY < bottom.frame.minY
    }

    private func setMuted(_ muted: Bool, channelID: String) throws {
        var request = URLRequest(url: serverURL.appendingPathComponent(
            "api/v4/channels/\(channelID)/members/\(userID!)/notify_props"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "mark_unread": muted ? "mention" : "all",
        ])
        let (_, response) = try synchronous(request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200,
                       "muting must be a server write, not a local flag")
    }

    private func getJSON(_ path: String) throws -> Any {
        var request = URLRequest(url: serverURL.appendingPathComponent(path))
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        let (data, _) = try synchronous(request)
        return try JSONSerialization.jsonObject(with: data)
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

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    private func attachShot(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
