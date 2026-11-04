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
// as: a name that did not exist before the run and carries a per-run token cannot arrive from a refresh.
//
// Harness repairs (T47-AV-R4, card `t_40082af1`, evidence `docs/t47-av-verdict.md` §1.2, §6 F7/F8):
//
//   * **The team is pinned from the app, not from the API's order.** The shell opens on
//     `TeamSwitchViewModel.entries.first` (the rail's order) while `GET /users/me/teams[0]` answers the
//     API's order. When they disagreed (T47-AV run A opened on Operations), the create landed in
//     Operations, the oracle looked in Perf, and the test said "POST /channels never landed" — false.
//     `pinTeam` reads `sidebarCurrentTeam` off the screen, matches it to a team id, and every oracle
//     call below uses **that** id.
//   * **`revealSidebarRow` scrolls the sidebar that exists.** It used to ask for
//     `app.collectionViews.firstMatch`; the sidebar has been a `ScrollView` + `LazyVStack`
//     (`channelSidebar.scroll`) since T8f, so the query found nothing and the guard returned without a
//     single swipe (F7). It now drives `ShellSettle.channelSidebarScroll` (falling back to the app) and
//     attaches a note with the surface and the swipe counts.
//   * **The created id is recorded from the server's answer, before any UI assertion, and the archive is
//     proven.** The id comes from the name-keyed lookup (independent of the sidebar and of the pane), any
//     name this run may have minted is re-resolved in `tearDownWithError`, `DELETE`'s status is asserted,
//     and the channel is read back to prove `delete_at` moved. A run that cannot archive fails by name,
//     with the channel id that is still live (F8).
//   * **The DM half creates nothing.** A direct channel cannot be deleted (`DELETE /channels/{id}` →
//     400 `api.channel.delete_channel.type.invalid`, measured on three probe DMs), so the pair is
//     resolved *before* the tap from `GET /users/me/channels` (read-only) and an **existing** pair is
//     preferred; only a fixture with no pair at all gets a pre-tap `POST /channels/direct`, and that DM
//     is then reported in the log as a permanent fixture mutation.
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
// was dropped from the log (`Authorization: Bearer *** /api/v4/channels HTTP/1.1`). The log that
// missed the create was the relay's bug, not the app's behaviour; the script now searches each
// connection's stream for request lines.
//
// The suite creates one channel per run and archives it at the end, proving the archive; a name is never
// recycled by the server, so every run uses a fresh one.

import XCTest

final class T47CreateChannelUITests: XCTestCase {

    /// One admin session per test process: the server rate-limits `/users/login` per IP.
    private static var cachedSession: (server: String, token: String, userID: String)?

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var userID: String!

    /// The team the **app** is on, read off the screen once per test (`pinTeam`). Every oracle call
    /// about "the team" uses this, never `GET /users/me/teams[0]` (F7).
    private var teamID: String!
    /// The account's teams as the server lists them, captured when the team was pinned.
    private var accountTeams: [[String: Any]] = []

    /// A channel this run created: the id the server answered, the name this run minted, and the team the
    /// server says it is in (which may not be the pinned one — that is asserted, then archived).
    private struct CreatedChannel {
        let id: String
        let name: String
        let teamID: String
    }

    /// Channels this run created, archived (and proven archived) in `tearDownWithError`. The id comes
    /// from the server's answer, recorded before any pane/sidebar assertion (F8).
    private var createdChannels: [CreatedChannel] = []
    /// Names this run may have minted. `tearDownWithError` re-resolves any of them the oracle did not
    /// record, so a run that failed before its lookup — or whose lookup threw — cannot leak a channel.
    private var attemptedChannelNames: [String] = []
    /// What this run wrote that the server will not let it take back (a direct channel). Reported, not
    /// hidden: the suite's "every run archives what it created" cannot be true of a DM.
    private var permanentFixtureMutations: [String] = []

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
    }

    /// Cleanup that cannot lie: every channel this run may have created is resolved and archived, the
    /// `DELETE`'s status is asserted, the archive is read back, and a channel that survives is named in a
    /// failure (T47-AV run A left `t47-ui-1793648428` live through `try?` + `allowFailure: true`).
    override func tearDownWithError() throws {
        for mutation in permanentFixtureMutations {
            print("T47 FIXTURE MUTATION — \(mutation)")
            let note = XCTAttachment(string: mutation)
            note.name = "permanent-fixture-mutation"
            note.lifetime = .keepAlways
            add(note)
        }
        guard serverURL != nil, token != nil else { return }

        // Belt and braces: a name this run minted but the oracle never recorded is looked up now — and
        // waited for, because a failure between the tap and the lookup leaves the app's `POST /channels`
        // in flight (10 s, then give up loudly: the archive below is the thing that must not be silent).
        for name in attemptedChannelNames
        where !createdChannels.contains(where: { $0.name == name }) {
            if let found = try? waitForChannelNamedAnywhere(name, timeout: 10) {
                createdChannels.append(CreatedChannel(id: found.channel["id"] as? String ?? "",
                                                      name: name,
                                                      teamID: found.teamID))
            }
        }
        for created in createdChannels {
            archive(created)
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
        // Registered before the app is even launched: if this test throws anywhere below, tearDown still
        // knows the one name a leaked channel could carry.
        attemptedChannelNames.append(urlName)

        let app = launchApp()
        showSidebar(app)

        // 0. The team the app is actually on — asserted once, up front, and used by every oracle call.
        try pinTeam(app)

        // The premise, measured: the channel does not exist yet, in any team.
        let preexisting = try teamsHoldingChannelNamed(urlName)
        XCTAssertTrue(preexisting.isEmpty,
                      "the fixture must not already have \(urlName); the server answered it in \(preexisting)")

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
        //
        //    The id is recorded here — from the server's answer to a lookup keyed by the name this run
        //    minted — before the pane and the sidebar are touched. A failure below can no longer lose the
        //    id, and a channel that landed in a different team is found and named instead of being
        //    reported as "never landed" (T47-AV §1.2).
        guard let created = try waitForChannelNamedAnywhere(urlName, timeout: 30) else {
            XCTFail("no channel named \(urlName) appeared in any team within 30 s — POST /channels never"
                    + " landed (teams: \(teamNames); the app was on \(teamNames[teamID] ?? teamID ?? "?"))")
            return
        }
        let channel = created.channel
        let channelID = channel["id"] as? String ?? ""
        XCTAssertFalse(channelID.isEmpty, "the server must answer the created channel")
        if !channelID.isEmpty {
            createdChannels.append(CreatedChannel(id: channelID, name: urlName, teamID: created.teamID))
        }
        XCTAssertEqual(created.teamID, teamID,
                       "the channel landed in team \(teamNames[created.teamID] ?? created.teamID),"
                       + " not in \(teamNames[teamID] ?? teamID ?? "?") — the team the sidebar shows;"
                       + " the app must create in the team it is on")
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
        // The relaunch must not have moved the app to another team, or the row below would be looked for
        // in the wrong list (and "it came from the server for this team" would be unproven).
        XCTAssertEqual(element(relaunched, "sidebarCurrentTeam").label
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       teamNames[teamID] ?? "",
                       "the relaunch must return to the same team:\n\(relaunched.debugDescription)")
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
    ///
    /// The tap must not be what creates the conversation: a DM cannot be archived, so the pair is
    /// resolved *before* the app is touched (read-only, from `GET /users/me/channels`) and an existing
    /// one is preferred. A fixture with no pair at all gets a pre-tap `POST /channels/direct`, and that
    /// created DM is reported as a permanent fixture mutation rather than pretended away.
    func testTheCreateMenuStartsADirectMessageWithATeammate() throws {
        let startedAt = Int(Date().timeIntervalSince1970 * 1000)

        let app = launchApp()
        showSidebar(app)
        try pinTeam(app)

        // 0. The pair, before the tap.
        let pair = try conversationPair()
        let channelID = pair.channel["id"] as? String ?? ""
        XCTAssertFalse(channelID.isEmpty, "the server must answer the pair's conversation")
        if pair.createdNow {
            permanentFixtureMutations.append(
                "direct channel \(pair.channelName) (\(channelID)) with @\(pair.username): created by this"
                + " run's pre-tap POST /channels/direct because the fixture had no pair; the server refuses"
                + " to delete a direct channel (400 api.channel.delete_channel.type.invalid)")
        }

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
            search.typeText(pair.username)
        }
        let row = element(app, "newDM.row.\(pair.teammateID)")
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "the picker must list @\(pair.username):\n\(app.debugDescription)")
        attach(app, "06-dm-picker")
        row.tap()

        // 3. The conversation is on show, titled with the person.
        let title = element(app, "nativeChannelTitle")
        XCTAssertTrue(title.waitForExistence(timeout: 30),
                      "starting a DM must land in the conversation:\n\(app.debugDescription)")
        let wanted = [pair.username, pair.nickname].filter { !$0.isEmpty }.map { $0.lowercased() }
        XCTAssertTrue(waitUntil(timeout: 20) {
            let label = title.label.lowercased()
            return wanted.contains { label.contains($0) }
        }, "the DM pane must be titled with the person (@\(pair.username)); it says \"\(title.label)\"")
        attach(app, "07-dm-open")

        // 4. The server's record of the pair — create-or-find again, and it must be the *same*
        //    conversation the pre-tap check named.
        let channel = try directChannel(with: pair.teammateID)
        XCTAssertFalse(channelID.isEmpty, "the server must answer the DM channel")
        XCTAssertEqual(channel["id"] as? String, channelID,
                       "the tap must open the pair's conversation, not a second one for the same two people")
        XCTAssertEqual(channel["type"] as? String, "D", "a direct message is type D")
        XCTAssertEqual(channel["name"] as? String, pair.channelName,
                       "the DM channel is named after both users")
        let createAt = channel["create_at"] as? Int ?? 0
        if !pair.createdNow {
            XCTAssertLessThan(createAt, startedAt,
                              "the pair predates this run (\(createAt) < \(startedAt)): the tap opened the"
                              + " existing conversation and wrote nothing new")
        }
        let members = try getJSON("/api/v4/channels/\(channelID)/members") as? [[String: Any]] ?? []
        let memberIDs = Set(members.compactMap { $0["user_id"] as? String })
        XCTAssertTrue(memberIDs.contains(pair.teammateID) && memberIDs.contains(userID!),
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
        // Not `nativeShell`: since `t_295b0a32` a signed-in launch opens a channel and pushes it
        // **over** the list, so the shell container is absent until `Back` (t_9399c0b4).
        // `ShellSettle.waitForSignedIn` answers "are we in?" for both landings; `showSidebar` is
        // what comes back to the list.
        XCTAssertTrue(ShellSettle.waitForSignedIn(app, timeout: 40),
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
        // `nativeSidebar` is in the tree even when a pushed channel pane covers it — measured on this
        // card (`t9399c0b4`): at t=8.67 s it existed, `sidebarCurrentTeam` never did, and the dump was
        // the "Town Square" pane with `Back` (`build/logs/t9399-T47CreateChannelUITests.log`). So it
        // cannot be the early-out test; `ShellSettle.tapTab` settles the landing, pops the pane and taps
        // `Channels`, and answers false on the split layout (no bar) leaving the sidebar alone.
        if !ShellSettle.tapTab(ShellSettle.Tab.channels, in: app, wait: 5),
           !element(app, "nativeSidebar").exists {
            let back = app.navigationBars.firstMatch.buttons.element(boundBy: 0)
            if back.exists, back.isHittable { back.tap() }
        }
        XCTAssertTrue(element(app, "nativeSidebar").waitForExistence(timeout: 20),
                      "the shell must be back on the channel sidebar:\n\(app.debugDescription)")
    }

    /// Scroll the sidebar until `identifier` exists, and say what was scrolled (T47-AV-R4, F7).
    ///
    /// The sidebar is a `ScrollView` + `LazyVStack` since T8f (`channelSidebar.scroll`): there is **no**
    /// collection view there, and the old helper's `app.collectionViews.firstMatch` guard returned
    /// silently without a single swipe — which is why every sidebar assertion in this suite failed at
    /// HEAD. Swipe the surface that exists — the sidebar's own scroll view
    /// (`ShellSettle.channelSidebarScroll`), or the app when even that is missing — up first (the list is
    /// long; a new channel sits far below the fold) and then back down, and leave the counts in the
    /// result bundle so a red run says whether it scrolled at all.
    @discardableResult
    private func revealSidebarRow(_ app: XCUIApplication, identifier: String,
                                  maxSwipes: Int = 25) -> XCUIElement {
        let target = element(app, identifier)
        if target.waitForExistence(timeout: 15) { return target }

        let scroller = ShellSettle.channelSidebarScroll(app)
        let surface: XCUIElement = scroller.exists ? scroller : app
        let surfaceName = scroller.exists ? "channelSidebar.scroll" : "app"
        var swipesUp = 0
        var swipesDown = 0
        while !target.exists, swipesUp < maxSwipes {
            surface.swipeUp(velocity: .fast)
            swipesUp += 1
        }
        while !target.exists, swipesDown < maxSwipes {
            surface.swipeDown(velocity: .fast)
            swipesDown += 1
        }
        XCTContext.runActivity(named: "revealSidebarRow \(identifier)") { activity in
            let note = XCTAttachment(string: "surface=\(surfaceName) swipesUp=\(swipesUp)"
                                     + " swipesDown=\(swipesDown) found=\(target.exists)")
            note.name = "sidebar-scroll"
            note.lifetime = .keepAlways
            activity.add(note)
        }
        return target
    }

    // MARK: - Team pinning

    /// The team the app is **on**, resolved from the screen to the server's id, and used by every oracle
    /// call in this test.
    ///
    /// The shell opens on the team rail's first entry; the API's `GET /users/me/teams` order is not the
    /// rail's. Reading `sidebarCurrentTeam` and matching its label to a team id is the only way the oracle
    /// and the app are guaranteed to be talking about one team (T47-AV F7: they disagreed once and the
    /// suite blamed the server).
    @discardableResult
    private func pinTeam(_ app: XCUIApplication) throws -> String {
        let current = element(app, "sidebarCurrentTeam")
        XCTAssertTrue(current.waitForExistence(timeout: 40),
                      "the sidebar must name the team it is showing:\n\(app.debugDescription)")
        let shown = current.label.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(shown.isEmpty, "the sidebar's team label is empty:\n\(app.debugDescription)")

        accountTeams = try teamsOnTheAccount()
        let matches = accountTeams.filter { team in
            let display = (team["display_name"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let urlName = (team["name"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return !shown.isEmpty && (display == shown || urlName == shown)
        }
        guard matches.count == 1, let id = matches.first?["id"] as? String, !id.isEmpty else {
            let listed = accountTeams.map {
                "\($0["display_name"] as? String ?? "?")/\($0["name"] as? String ?? "?")"
            }
            throw OracleFailure(message: "the sidebar shows team \"\(shown)\" but the account's teams are"
                               + " \(listed) — the oracle cannot be pointed at the team the app is on")
        }
        teamID = id
        let note = XCTAttachment(string: "app team = \(shown) -> \(id) (of \(teamNames))")
        note.name = "pinned-team"
        note.lifetime = .keepAlways
        add(note)
        return id
    }

    /// Team ids to their display names, for readable failure messages.
    private var teamNames: [String: String] {
        var names: [String: String] = [:]
        for team in accountTeams {
            if let id = team["id"] as? String {
                names[id] = team["display_name"] as? String ?? team["name"] as? String ?? id
            }
        }
        return names
    }

    private struct OracleFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
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

    private func teamsOnTheAccount() throws -> [[String: Any]] {
        let teams = try getJSON("/api/v4/users/me/teams") as? [[String: Any]] ?? []
        guard !teams.isEmpty else { throw XCTSkip("the fixture account has no team") }
        return teams
    }

    /// The server's answer for a channel name in one team: the channel, or nil on 404.
    ///
    /// Anything else is an error, not a "no": a 403 or a 500 swallowed into "does not exist" is how a
    /// wrong oracle becomes a wrong verdict.
    private func channelNamed(_ name: String, in team: String) throws -> [String: Any]? {
        var request = URLRequest(url: url(for: "/api/v4/teams/\(team)/channels/name/\(name)"))
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        let (data, response) = try synchronous(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OracleFailure(message: "GET /teams/\(team)/channels/name/\(name) -> HTTP \(status)"
                                + " \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        return json
    }

    /// Every team that answers this name — the premise check, widened to the whole account so a leaked
    /// name from an earlier run cannot hide in a team the oracle is not looking at.
    private func teamsHoldingChannelNamed(_ name: String) throws -> [String] {
        var holders: [String] = []
        for team in accountTeams {
            guard let id = team["id"] as? String else { continue }
            if try channelNamed(name, in: id) != nil { holders.append(id) }
        }
        return holders
    }

    /// Poll every team for the name, so a create that landed in the wrong team is **found and named**
    /// rather than reported as "POST /channels never landed" (T47-AV §1.2).
    private func waitForChannelNamedAnywhere(_ name: String,
                                             timeout: TimeInterval) throws -> (channel: [String: Any],
                                                                               teamID: String)? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for team in accountTeams {
                guard let id = team["id"] as? String else { continue }
                if let channel = try channelNamed(name, in: id),
                   !(channel["id"] as? String ?? "").isEmpty {
                    return (channel, id)
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        } while Date() < deadline
        return nil
    }

    /// Teammates the picker can offer: on the pinned team, not me, not deactivated, not a bot.
    private func teammatesOnTheTeam() throws -> [[String: Any]] {
        let users = try getJSON("/api/v4/users?in_team=\(teamID!)&page=0&per_page=60")
            as? [[String: Any]] ?? []
        let candidates = users.filter { user in
            (user["id"] as? String) != userID
                && (user["delete_at"] as? Int ?? 0) == 0
                && (user["is_bot"] as? Bool ?? false) == false
        }
        guard !candidates.isEmpty else {
            throw XCTSkip("the fixture team has no second member to start a DM with")
        }
        return candidates
    }

    private struct DMPair {
        let teammateID: String
        let username: String
        let nickname: String
        let channelName: String
        let channel: [String: Any]
        /// `true` only when the fixture had no conversation for the pair and this run's pre-tap
        /// `POST /channels/direct` made one — a write the server will not let this run undo.
        let createdNow: Bool
    }

    /// The pair the tap is going to open, resolved **before** the tap.
    ///
    /// `GET /users/me/channels` is the read that answers "does this pair already have a conversation"
    /// without writing anything: it lists direct channels (type `D`, named `<id>__<id>` with the ids
    /// sorted) for the signed-in user. An existing pair is used as-is, so the app's tap is a
    /// create-or-find that finds — the only shape in which "the run archives what it created" stays true
    /// for a DM, which the server refuses to delete.
    private func conversationPair() throws -> DMPair {
        let candidates = try teammatesOnTheTeam()
        let existing = try directChannels()

        for teammate in candidates {
            let otherID = teammate["id"] as? String ?? ""
            guard !otherID.isEmpty else { continue }
            let pairName = directChannelName(with: otherID)
            if let channel = existing.first(where: { ($0["name"] as? String) == pairName }) {
                return DMPair(teammateID: otherID,
                              username: teammate["username"] as? String ?? "",
                              nickname: teammate["nickname"] as? String ?? "",
                              channelName: pairName,
                              channel: channel,
                              createdNow: false)
            }
        }

        // No pair on the fixture: create the conversation now, before the app's tap, and say so.
        let teammate = candidates[0]
        let otherID = teammate["id"] as? String ?? ""
        let channel = try directChannel(with: otherID)
        return DMPair(teammateID: otherID,
                      username: teammate["username"] as? String ?? "",
                      nickname: teammate["nickname"] as? String ?? "",
                      channelName: directChannelName(with: otherID),
                      channel: channel,
                      createdNow: true)
    }

    /// The signed-in user's live direct channels (`GET /users/me/channels`).
    private func directChannels() throws -> [[String: Any]] {
        let channels = try getJSON("/api/v4/users/me/channels") as? [[String: Any]] ?? []
        return channels.filter { channel in
            (channel["type"] as? String) == "D"
                && (channel["delete_at"] as? Int ?? 0) == 0
                && !(channel["name"] as? String ?? "").isEmpty
        }
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

    // MARK: - The archive

    /// Archive one channel and prove it: `DELETE`'s status is asserted, then the channel is read back and
    /// `delete_at` must have moved. No `try?`, no `allowFailure` — a red run either archives its channel or
    /// fails with the id that is still live (T47-AV F8).
    private func archive(_ created: CreatedChannel) {
        guard !created.id.isEmpty else {
            XCTFail("this run recorded no id for \(created.name); nothing could be archived — check the"
                    + " fixture for a channel with that name")
            return
        }
        let teamName = teamNames[created.teamID] ?? created.teamID
        do {
            let status = try deleteChannel(created.id)
            XCTAssertEqual(status, 200,
                           "archiving \(created.name) (\(created.id), team \(teamName)) answered"
                           + " HTTP \(status) — the channel is STILL LIVE")
            guard status == 200 else { return }
            let after = try getJSON("/api/v4/channels/\(created.id)") as? [String: Any] ?? [:]
            let deleteAt = after["delete_at"] as? Int ?? 0
            XCTAssertGreaterThan(deleteAt, 0,
                                 "DELETE answered 200 but \(created.name) (\(created.id)) still reports"
                                 + " delete_at 0 — the archive did not take")
        } catch {
            XCTFail("archiving \(created.name) (\(created.id), team \(teamName)) FAILED: \(error)"
                    + " — the channel is STILL LIVE")
        }
    }

    /// The raw status of `DELETE /channels/{id}` (200 on success, 400 for a DM).
    private func deleteChannel(_ id: String) throws -> Int {
        var request = URLRequest(url: url(for: "/api/v4/channels/\(id)"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        let (_, response) = try synchronous(request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
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
