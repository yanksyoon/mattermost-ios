// T48 — the post options menu against a **real** Mattermost server, with every expectation read back
// from that server through its own API.
//
// Why live: S38's acceptance is not "a button is drawn". It is "the button does what the server would
// do" — the permalink is the one the server serves, the save is a flagged_post preference the Saved
// list then contains, mark-unread moves the server's own unread counters, and a pin is visible in the
// channel's pinned sheet. A stub can only prove the drawing.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0, `app/screens/post_options/index.ts`.
//
// Fixture: team `perf` (`scripts/perf_seed.py`) and the second author `t36reply`
// (`scripts/t36_thread_seed.py`) — posts by another author are what make Mark Unread offered
// (upstream withholds it on my own posts). Each test creates its own root post as that account.
//
// Navigation note (measured on this host, iOS 26.5 simulator): with a reset shell the app may come up
// on its own home pane ("No channel selected") or with a restored channel already pushed, and it
// refights `Back` in the second case. The suite therefore presses `Back` when no channel list is on
// screen and reaches the fixture channel through the sidebar's identifier-addressed quick switcher —
// never by tapping a channel row, which was measured to exist and vanish between `exists` and `tap`
// while the pane rebuilds.
//
// Run (throwaway local fixture; credentials are the fixture accounts in `scripts/perf_seed.py` and
// `scripts/t36_thread_seed.py`):
//
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     python3 scripts/qa-test.py --platform ios --sim "iPhone 17 Pro" \
//       --only-testing MattermostUITests/T48PostOptionsUITests
//
// Every test skips (never fails) when the environment or the fixture is missing.

import XCTest

final class T48PostOptionsUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var userID: String!
    private var teamID: String!
    /// The channel this test measures — the one the shell presents, resolved through the API.
    private var channelID: String!

    private let channelName = "t36-threads"
    /// The channel's display name, which is what `nativeChannelTitle` draws.
    private let channelDisplayName = "T36 Threads"

    /// The second author the T36 fixture creates: its posts are the ones this app did not make.
    private let secondLogin = "t36reply"
    private let secondPassword = "T36Reply-Not-A-Real-Secret-1"
    private var secondToken: String!
    private var secondUserID: String!

    /// The app this run drove, so a red run can attach what was on screen.
    private var app: XCUIApplication?

    override func setUpWithError() throws {
        // A failure must carry the screen it failed on. Every `attach` call in this file sits on the
        // success path — before this block, a red run said "the row never appeared" and nothing
        // about what the app was drawing instead (T48-AV §F6).
        //
        // `totalFailureCount` is read in teardown, before XCTest settles the case: `hasSucceeded` is
        // still false there for a test that passed, so keying on it attached a screenshot to every
        // green test as well (measured on this host, run 1 — five `t48-failure-…` images, four of
        // them green).
        addTeardownBlock { [weak self] in
            guard let self, let app = self.app, app.state != .notRunning,
                  (self.testRun?.totalFailureCount ?? 0) > 0 else { return }
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "t48-failure-\(self.name)"
            shot.lifetime = .keepAlways
            self.add(shot)
        }
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live post-options test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        try ping()
        let session = try authenticate(login: loginID, password: password)
        token = session.token
        userID = session.userID
        guard let team = try teamsForMe().first(where: { $0["name"] as? String == "perf" }) else {
            throw XCTSkip("team #perf is missing — run scripts/perf_seed.py")
        }
        teamID = team["id"] as? String
        guard let channel = try channel(named: channelName, in: teamID) else {
            throw XCTSkip("channel #\(channelName) is missing — run scripts/t36_thread_seed.py")
        }
        channelID = try XCTUnwrap(channel["id"] as? String)
        let second = try authenticate(login: secondLogin, password: secondPassword)
        secondToken = second.token
        secondUserID = second.userID
    }

    // MARK: - 1. The menu is upstream's, and Copy Link is the server's own permalink

    /// The card's headline criterion: the sheet offers the options S38 names, and the two copy options
    /// put the right strings on the pasteboard. The permalink is compared against the shape the server
    /// itself serves (`{server}/{team}/pl/{post_id}`) built here from the server's team name — not from
    /// a constant the app also owns.
    func testTheMenuOffersTheMissingOptionsAndCopyLinkIsTheServersPermalink() throws {
        let app = try launchOnFixtureChannel()
        let stamp = Int(Date().timeIntervalSince1970)
        let message = "t48 copy target \(stamp)"
        let postID = try createPost(message: message, as: secondToken)
        // One reply gives the root a thread, so Follow Message is offered (upstream requires it).
        _ = try createPost(message: "\(message) reply", rootID: postID, as: secondToken)
        XCTAssertTrue(revealPost(app, postID).waitForExistence(timeout: 30),
                      "the fixture post must be a row of the presented channel:\n\(app.debugDescription)")

        openMenu(app, postID: postID)
        // The parity gap in one assertion: every option S38 names resolves by its documented name.
        // The sheet is a `.medium` list, so later rows are below the fold — a row that is not drawn
        // yet is `exists == false`, not absent, and must be scrolled to.
        for identifier in ["postOptions.copyText", "postOptions.copyLink", "postOptions.save",
                           "postOptions.pin", "postOptions.markUnread", "postOptions.followThread"] {
            XCTAssertTrue(revealOption(app, identifier).exists,
                          "\(identifier) must be offered on another author's plain root post:\n"
                          + app.debugDescription)
        }
        attach(app, "t48-01-menu")

        // Copy Link — the string shown is read back from the pasteboard by the sheet itself.
        revealOption(app, "postOptions.copyLink").tap()
        let copied = revealAppendedRow(app, "postOptions.copied")
        XCTAssertTrue(copied.exists,
                      "a copy that did not reach the pasteboard must not claim it did:\n"
                      + app.debugDescription)
        let expectedLink = "\(serverURL.absoluteString.hasSuffix("/") ? String(serverURL.absoluteString.dropLast()) : serverURL.absoluteString)/perf/pl/\(postID)"
        XCTAssertEqual(copied.label, expectedLink,
                       "Copy Link must be the path the server serves, not a path this build invented")
        // The pasteboard itself is asserted **inside the app**: `PostOptionsSheet` shows this row only
        // after reading the string back out of `UIPasteboard.general` half a second later. The test
        // runner must not read the pasteboard — on iOS 26 that read raises the system paste prompt and
        // wedges the run (measured here).
        attach(app, "t48-02-copied-link")
        revealOption(app, "postOptions.done").tap()

        // Copy Text — the message body, through the same pasteboard read-back.
        openMenu(app, postID: postID)
        revealOption(app, "postOptions.copyText").tap()
        let copiedText = revealAppendedRow(app, "postOptions.copied")
        XCTAssertTrue(copiedText.exists,
                      "Copy Text must show the row that only appears after the app read the string "
                      + "back out of the pasteboard:\n\(app.debugDescription)")
        XCTAssertEqual(copiedText.label, message, "Copy Text must copy the message, not the permalink")
        revealOption(app, "postOptions.done").tap()
    }

    // MARK: - 2. Save from the menu lands in the Saved list, on the server too

    func testSaveFromTheMenuPutsThePostInTheServersSavedList() throws {
        let app = try launchOnFixtureChannel()
        let postID = try createPost(message: "t48 save target \(Int(Date().timeIntervalSince1970))",
                                    as: secondToken)
        XCTAssertEqual(try isSaved(postID), false, "the premise: the post is not saved yet")

        XCTAssertTrue(revealPost(app, postID).waitForExistence(timeout: 30))
        openMenu(app, postID: postID)
        revealOption(app, "postOptions.save").tap()

        XCTAssertTrue(waitUntil(timeout: 30) { (try? self.isSaved(postID)) == true },
                      "Save must reach PUT /users/{uid}/preferences; the server does not hold it")
        XCTAssertTrue(waitUntil(timeout: 20) { !self.element(app, "postOptions.cancel").exists },
                      "a successful write must dismiss the sheet:\n\(app.debugDescription)")
        attach(app, "t48-03-saved")

        // The menu itself is the state's mirror: opening it again offers Remove from saved. (The Saved
        // screen's rendering of a flagged post is T39's suite, `testUnsaveFromTheSavedTab…`; this test
        // asserts the write and the state, which is what this menu owns.)
        openMenu(app, postID: postID)
        XCTAssertTrue(revealOption(app, "postOptions.unsave").exists,
                      "a saved post must offer Remove from saved on the next open:\n"
                      + app.debugDescription)
        XCTAssertFalse(element(app, "postOptions.save").exists)

        // Leave the fixture as it was found.
        try unsave(postID)
    }

    // MARK: - 3. Mark unread raises the server's unread counters for the channel

    func testMarkUnreadRaisesTheChannelsUnreadStateOnTheServer() throws {
        let app = try launchOnFixtureChannel()
        let postID = try createPost(message: "t48 unread target \(Int(Date().timeIntervalSince1970))",
                                    as: secondToken)
        XCTAssertTrue(revealPost(app, postID).waitForExistence(timeout: 30))
        openMenu(app, postID: postID)
        revealOption(app, "postOptions.markUnread").tap()

        // The server answers the write with the membership row it just changed; the app must land on
        // the same numbers it sent. Assert the *server*: GET the member row back.
        XCTAssertTrue(waitUntil(timeout: 30) {
            guard let now = try? self.membership(),
                  let viewed = now["last_viewed_at"] as? Int64,
                  let count = now["msg_count"] as? Int64,
                  let created = try? self.createAt(postID) else { return false }
            return count >= 1 && viewed < created
        }, "set_unread must leave the server holding an unread post for this reader; it holds "
           + "\(String(describing: try? membership()))")
        attach(app, "t48-05-marked-unread")
    }

    // MARK: - 4. Pin from the menu shows in the channel's pinned sheet

    func testPinFromTheMenuShowsInThePinnedSheet() throws {
        let app = try launchOnFixtureChannel()
        let postID = try createPost(message: "t48 pin target \(Int(Date().timeIntervalSince1970))",
                                    as: secondToken)
        XCTAssertEqual(try isPinned(postID), false, "the premise: the post is not pinned")

        XCTAssertTrue(revealPost(app, postID).waitForExistence(timeout: 30))
        openMenu(app, postID: postID)
        revealOption(app, "postOptions.pin").tap()

        XCTAssertTrue(waitUntil(timeout: 30) { (try? self.isPinned(postID)) == true },
                      "Pin must reach POST /posts/{id}/pin; the server does not hold it")
        // The open sheet's own state followed the write: the next open offers Unpin. (The pinned-rows
        // sheet's rendering is T39's `testUnpinFromThePinnedSheet…`, which unpins from that sheet; this
        // test asserts the write and the menu state, which is what this menu owns.)
        openMenu(app, postID: postID)
        XCTAssertTrue(revealOption(app, "postOptions.unpin").exists,
                      "a pinned post must offer Unpin on the next open:\n\(app.debugDescription)")
        attach(app, "t48-06-pinned")

        try setPinned(postID, pinned: false)
    }

    // MARK: - 5. A second client's writes move the open menu without a reload

    /// The card's socket clause, end to end: with the sheet **open**, another signed-in session pins the
    /// post and saves it. `post_edited` and `preferences_changed` must turn Pin into Unpin and Save into
    /// Remove from saved *in place* — closing and reopening the sheet would prove nothing.
    func testASecondClientsPinAndSaveMoveTheOpenMenu() throws {
        let app = try launchOnFixtureChannel()
        let postID = try createPost(message: "t48 socket target \(Int(Date().timeIntervalSince1970))",
                                    as: secondToken)
        XCTAssertTrue(revealPost(app, postID).waitForExistence(timeout: 30))
        openMenu(app, postID: postID)
        XCTAssertTrue(revealOption(app, "postOptions.pin").exists)

        // Another session (the second fixture account) pins the post; nobody touches this app.
        XCTAssertEqual(try pinAsSecondClient(postID), true)
        XCTAssertTrue(waitUntil(timeout: 40) {
            self.element(app, "postOptions.unpin").exists
                && !self.element(app, "postOptions.pin").exists
        }, "post_edited must turn the open sheet's Pin into Unpin:\n\(app.debugDescription)")

        // …and this reader's own preference, written from another session, turns Save into Remove.
        //
        // This hop was the card's known gap (t_fddfb0d5): it stayed red while the pin hop above was
        // green, because `preferences_changed` carries `data.preferences` as a **JSON string** and the
        // decoder guarded on `arrayValue` — the frame was dropped, so the model's `.preferencesChanged`
        // branch was unreachable against a live server (T48-AV §F2). The decoder now accepts both
        // shapes (MattermostTests/T48PreferencesSocketTests feeds this exact wire form), and the
        // expectation wrapper that recorded the gap is gone: the assertion is the product's again.
        try saveViaAPI(postID)
        XCTAssertTrue(waitUntil(timeout: 40) {
            self.revealOption(app, "postOptions.unsave").exists
        }, "preferences_changed must turn the open sheet's Save into Remove from saved:\n"
           + app.debugDescription)
        attach(app, "t48-07-socket-moved")

        try setPinned(postID, pinned: false)
        try unsave(postID)
    }

    // MARK: - 6. A followed thread still offers Unfollow after a relaunch (T48-AV-R3)

    /// The card's acceptance: with a root this account already follows, the sheet opened **after a
    /// relaunch** offers Unfollow Message and not Follow Message; unfollowing it turns the row back
    /// into Follow Message; and the answer is the server's, not an in-memory patch.
    ///
    /// The relaunch is real (`terminate()` then `launch()`): the follow dictionary the view model keeps
    /// dies with the process, so the only thing that can still answer is the read. That read is the CRT
    /// thread row — `GET …/threads/{root}` is 200 while followed and 404 once not, which is what
    /// `scripts/t48_follow_probe.py` measured (no surface carries `is_following`). Each assertion is
    /// taken twice: from the menu, and from the server through the same endpoint.
    func testAFollowedRootStillOffersUnfollowAfterARelaunch() throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let postID = try createPost(message: "t48r3 follow target \(stamp)", as: secondToken)
        // One reply gives the root a thread; 9.11.19 has no thread row for a root without one.
        _ = try createPost(message: "t48r3 follow reply \(stamp)", rootID: postID, as: secondToken)
        try setFollowed(postID, following: true)
        XCTAssertEqual(try isFollowed(postID), true,
                       "the premise: the server holds the follow (PUT answered "
                       + "\(lastFollowWriteStatus.map(String.init) ?? "—"), GET …/threads/{root} answered "
                       + "\(lastFollowStatus))")

        var app = try launchOnFixtureChannel()
        XCTAssertTrue(revealPost(app, postID).waitForExistence(timeout: 30),
                      "the fixture post must be a row of the presented channel")
        openMenu(app, postID: postID)
        var state = followRowState(app)
        XCTAssertTrue(state.unfollow, "the first launch must offer Unfollow Message:\n\(app.debugDescription)")
        XCTAssertFalse(state.follow)
        attach(app, "t48-08-followed-first-launch")

        // A genuine relaunch: a new process, no in-memory follow state, the same server.
        app.terminate()
        app = try launchOnFixtureChannel()
        XCTAssertTrue(revealPost(app, postID).waitForExistence(timeout: 30))
        openMenu(app, postID: postID)
        state = followRowState(app)
        XCTAssertTrue(state.unfollow,
                      "after a relaunch the sheet must still offer Unfollow Message — the answer has to "
                      + "come from the server, because no socket frame or write has happened since:\n"
                      + app.debugDescription)
        XCTAssertFalse(state.follow,
                       "offering Follow Message on a followed thread is the T48-AV F3 defect")
        attach(app, "t48-09-followed-after-relaunch")

        // Unfollow from the menu: the server stops holding the follow, and the re-opened sheet offers
        // Follow Message again.
        revealOption(app, "postOptions.unfollowThread").tap()
        XCTAssertTrue(waitUntil(timeout: 30) { !self.element(app, "postOptions.cancel").exists },
                      "a successful unfollow must dismiss the sheet:\n\(app.debugDescription)")
        XCTAssertTrue(waitUntil(timeout: 20) { (try? self.isFollowed(postID)) == false },
                      "DELETE …/threads/{root}/following must leave the server holding no follow")

        openMenu(app, postID: postID)
        state = followRowState(app)
        XCTAssertTrue(state.follow, "unfollowing must turn the row back into Follow Message:\n"
                      + app.debugDescription)
        XCTAssertFalse(state.unfollow)
        attach(app, "t48-10-unfollowed")
    }

    // MARK: - App helpers

    /// Launch into the shell and land on the fixture channel through the app's own deep-link seam.
    ///
    /// The sign-in step is adaptive: `-uiTestForgetSession` deletes the Keychain token, but a simulator
    /// that has been signed in before may still come up inside the shell (a WKWebView cookie session
    /// survives the vault delete). The suite measures the menu, not the signed-out state, so it signs in
    /// only when the form is actually up.
    private func launchOnFixtureChannel() throws -> XCUIApplication {
        let app = XCUIApplication()
        self.app = app
        app.launchArguments = ["-uiTestResetPersistedState",
                               "-uiTestForgetSession", serverURL.absoluteString,
                               "-uiTestSeedServer", serverURL.absoluteString,
                               "-uiTestSeedServerName", "Local Mattermost",
                               "-surfaceMode", "shell=native",
                               "-surfaceMode", "auth=native",
                               "-surfaceMode", "sidebar=native",
                               "-surfaceMode", "composer=native",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        if app.textFields["loginIDField"].waitForExistence(timeout: 15) {
            signIn(app)
        }
        XCTAssertTrue(element(app, "nativeShell").waitForExistence(timeout: 45),
                      "the app must reach the native shell (signed in):\n\(app.debugDescription)")

        if !element(app, "channelPostList").waitForExistence(timeout: 8) {
            // The shell may come up on its own home pane ("No channel selected") or with a restored
            // channel pushed over the sidebar. `Back` is the one control both states share.
            tapBackIfPossible(app)
        }
        let current = element(app, "sidebarCurrentTeam")
        if current.exists, !current.label.localizedCaseInsensitiveContains("perf") {
            // Measured: switching the rail into #perf opens that team's default channel (Town Square),
            // so the switch *is* the navigation on this layout; the sidebar follows after a Back.
            let rail = element(app, "teamSidebar.team.\(teamID!)")
            XCTAssertTrue(rail.waitForExistence(timeout: 15),
                          "the team rail must offer #perf:\n\(app.debugDescription)")
            rail.tap()
            _ = element(app, "channelPostList").waitForExistence(timeout: 30)
        }
        if !element(app, "channelSidebar.quickSwitcher").waitForExistence(timeout: 10) {
            tapBackIfPossible(app)
        }
        let opener = element(app, "channelSidebar.quickSwitcher")
        XCTAssertTrue(opener.waitForExistence(timeout: 30),
                      "the sidebar must offer the quick switcher:\n\(app.debugDescription)")
        opener.tap()
        let field = app.textFields["channelSidebar.quickSwitcher.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 15),
                      "the quick switcher must focus a field:\n\(app.debugDescription)")
        field.tap()
        field.typeText(channelName)
        let result = element(app, "channelSidebar.quickSwitcher.result.\(channelID!)")
        XCTAssertTrue(result.waitForExistence(timeout: 25),
                      "the switcher must find #\(channelName):\n\(app.debugDescription)")
        result.tap()
        XCTAssertTrue(element(app, "channelPostList").waitForExistence(timeout: 45),
                      "the fixture channel must be open:\n\(app.debugDescription)")
        // The title is the unambiguous name: both #perf and #ops own a "Town Square".
        XCTAssertEqual(element(app, "nativeChannelTitle").label, channelDisplayName,
                       "the switcher must land on #\(channelName), not another channel")
        return app
    }

    private func tapBackIfPossible(_ app: XCUIApplication) {
        for identifier in ["backToolbarButton", "BackButton"] {
            let back = app.buttons[identifier]
            if back.waitForExistence(timeout: 5), back.isEnabled {
                back.tap()
                _ = element(app, "channelSidebar.quickSwitcher").waitForExistence(timeout: 15)
                return
            }
        }
    }

    private func signIn(_ app: XCUIApplication) {
        let field = app.textFields["loginIDField"]
        XCTAssertTrue(field.waitForExistence(timeout: 25),
                      "the native sign-in must mount against \(serverURL.absoluteString):\n"
                      + app.debugDescription)
        field.tap()
        field.typeText(loginID)
        let secret = app.secureTextFields["loginPasswordField"]
        XCTAssertTrue(secret.waitForExistence(timeout: 10))
        secret.tap()
        secret.typeText(password)
        app.buttons["loginSubmitButton"].tap()
        XCTAssertTrue(element(app, "nativeShell").waitForExistence(timeout: 45),
                      "signing in must reach the shell:\n\(app.debugDescription)")
    }

    /// The Saved screen. On a phone the channel is pushed over the shell's tabs, so the bar is absent
    /// while one is open — `ShellSettle.tapTab` takes `Back` first and then taps the tab, the reader's
    /// own route (`docs/t95-shell-tab-bar-decision.md` §2 D1). The split layout reaches Saved from the
    /// detail toolbar.
    private func openSaved(_ app: XCUIApplication) {
        if !ShellSettle.tapTab(ShellSettle.Tab.saved, in: app, wait: 5) {
            let toolbarButton = element(app, "shellSavedButton")
            XCTAssertTrue(toolbarButton.waitForExistence(timeout: 20),
                          "neither the toolbar nor a tab opens saved messages:\n"
                          + app.debugDescription)
            toolbarButton.tap()
        }
        XCTAssertTrue(element(app, "nativeSavedPane").waitForExistence(timeout: 30),
                      "the saved screen must mount:\n\(app.debugDescription)")
    }

    /// A sheet row that may be below the fold: a `.medium` detent draws only the first rows.
    @discardableResult
    private func revealOption(_ app: XCUIApplication, _ identifier: String,
                              maxSwipes: Int = 4) -> XCUIElement {
        let target = element(app, identifier)
        guard !target.exists else { return target }
        for _ in 0..<maxSwipes {
            app.swipeUp()
            if target.exists { return target }
        }
        return target
    }

    /// Open the row's options sheet **and** drag it to its large detent.
    ///
    /// The sheet presents at `.medium`, and its last row is drawn from y=844 to y=888 on this 874-point
    /// screen — under the bottom edge. A synthesized tap at that row's centre did not reach it: measured
    /// four times on this host (T48-AV-R5, iPhone 16 Pro / iOS 18.3, an instrumented build logging the
    /// pressed option) the app received **Reply**, the row 338 points above, which is exactly the
    /// detent's own height, and the teardown screenshot showed the thread composer where a pinned post
    /// was expected. That is why `testPinFromTheMenuShowsInThePinnedSheet` — the only test that presses
    /// the bottom row — could not reproduce while every other option did.
    ///
    /// One swipe expands the sheet to `.large`; the same tap then reaches `Pin to Channel`
    /// (`build/logs/t48r5-pin-probe4.log`, one test, green, with `press enter pin` in the app log). This
    /// is the harness's shape of the problem: a reader's finger is not a synthesized touch, so nothing
    /// here claims the sheet is broken for people — but a test that taps a row the sheet is not showing
    /// measures the sheet, not the menu.
    private func openMenu(_ app: XCUIApplication, postID: String) {
        let menu = element(app, "post.\(postID).menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 25),
                      "the row must expose its options button:\n\(app.debugDescription)")
        menu.tap()
        let cancel = element(app, "postOptions.cancel")
        XCTAssertTrue(cancel.waitForExistence(timeout: 25),
                      "the options sheet must open:\n\(app.debugDescription)")
        app.swipeUp()
        XCTAssertTrue(cancel.waitForExistence(timeout: 5),
                      "the sheet must survive the swipe to its large detent:\n\(app.debugDescription)")
    }

    /// Which follow direction the open sheet is drawing.
    ///
    /// The answer is a request (`loadFollowState`), so the row is not there on the sheet's first frame:
    /// this waits for either direction instead of reading one frame. They are mutually exclusive by
    /// construction (`offeredOptions` appends one of the two), so "not drawn while the other is" is a
    /// real absence rather than a row that happens to be below the fold.
    private func followRowState(_ app: XCUIApplication,
                                timeout: TimeInterval = 25) -> (follow: Bool, unfollow: Bool) {
        let follow = element(app, "postOptions.followThread")
        let unfollow = element(app, "postOptions.unfollowThread")
        _ = waitUntil(timeout: timeout) { follow.exists || unfollow.exists }
        return (follow.exists, unfollow.exists)
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

    /// A sheet row that is appended **after** an asynchronous step — `postOptions.copied` appears only
    /// once the app has read the string back out of the pasteboard, up to ~2 s after the tap.
    ///
    /// A single `revealOption` cannot express this: it bursts its swipes while the row does not exist
    /// yet and then stops, so the row is drawn below the fold with nothing left to scroll. Poll and
    /// scroll together, and stop the moment it exists.
    @discardableResult
    private func revealAppendedRow(_ app: XCUIApplication, _ identifier: String,
                                   timeout: TimeInterval = 20) -> XCUIElement {
        let target = element(app, identifier)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if target.exists { return target }
            app.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        return target
    }

    /// A channel row that may be outside the viewport (`LazyVStack`: an off-screen row is not in the
    /// tree at all).
    @discardableResult
    private func revealPost(_ app: XCUIApplication, _ postID: String,
                            maxSwipes: Int = 14) -> XCUIElement {
        let target = element(app, "post.\(postID)")
        guard !target.exists else { return target }
        let list = element(app, "channelPostList")
        var swipes = 0
        while !target.exists, swipes < maxSwipes {
            list.swipeUp(velocity: .fast)
            swipes += 1
        }
        return target
    }

    @discardableResult
    private func revealRow(_ app: XCUIApplication, _ identifier: String,
                           in listIdentifier: String, maxSwipes: Int = 12) -> XCUIElement {
        let target = element(app, identifier)
        guard !target.exists else { return target }
        let list = element(app, listIdentifier)
        var swipes = 0
        while !target.exists, swipes < maxSwipes {
            list.swipeUp(velocity: .fast)
            swipes += 1
        }
        return target
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Server access (the test is its own API client)

    private func ping() throws {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/system/ping"))
        request.timeoutInterval = 5
        let (_, response) = try synchronous(request)
        try XCTSkipUnless((response as? HTTPURLResponse)?.statusCode == 200,
                          "the live server at \(serverURL.absoluteString) is not answering")
    }

    private struct Session {
        let token: String
        let userID: String
    }

    private func authenticate(login: String, password: String) throws -> Session {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/users/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["login_id": login,
                                                                      "password": password])
        let (data, response) = try synchronous(request)
        let http = response as? HTTPURLResponse
        let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        // The session's own header, not the body copy: this is the credential every later request
        // sends, and the header is the form T47-AV measured as surviving a cookie-free session
        // (`T47CreateChannelAVUITests.authenticate`). The body copy is only a fallback for a server
        // that omits the header.
        let token = http?.value(forHTTPHeaderField: "Token") ?? (body?["token"] as? String)
        guard http?.statusCode == 200, let token, let id = body?["id"] as? String else {
            throw XCTSkip("could not sign in as \(login) on the live server")
        }
        return Session(token: token, userID: id)
    }

    private func teamsForMe() throws -> [[String: Any]] {
        try getJSON("/api/v4/users/me/teams", token: token) as? [[String: Any]] ?? []
    }

    /// The channel the fixture names, by the API's own resolution.
    private func channel(named name: String, in teamID: String) throws -> [String: Any]? {
        try getJSON("/api/v4/teams/\(teamID)/channels/name/\(name)", token: token) as? [String: Any]
    }

    /// Create a post as another author. `rootID` makes it a reply, which is what gives a root post a
    /// thread (and therefore a Follow row).
    private func createPost(message: String, rootID: String? = nil, as token: String) throws -> String {
        var body: [String: Any] = ["channel_id": channelID as String, "message": message]
        if let rootID { body["root_id"] = rootID }
        let json = try postJSON("/api/v4/posts", body: body, token: token)
        guard let post = json as? [String: Any], let id = post["id"] as? String else {
            throw XCTSkip("the server refused the fixture post")
        }
        return id
    }

    private func membership() throws -> [String: Any] {
        try getJSON("/api/v4/channels/\(channelID!)/members/\(userID!)", token: token)
            as? [String: Any] ?? [:]
    }

    private func createAt(_ postID: String) throws -> Int64 {
        let post = try getJSON("/api/v4/posts/\(postID)", token: token) as? [String: Any] ?? [:]
        return (post["create_at"] as? Int64) ?? 0
    }

    private func isSaved(_ postID: String) throws -> Bool {
        let rows = try getJSON("/api/v4/users/\(userID!)/preferences/flagged_post", token: token)
            as? [[String: Any]] ?? []
        return rows.contains { ($0["name"] as? String) == postID }
    }

    private func saveViaAPI(_ postID: String) throws {
        _ = try putJSON("/api/v4/users/\(userID!)/preferences",
                        body: [["user_id": userID as String,
                                "category": "flagged_post",
                                "name": postID,
                                "value": "true"]],
                        token: token)
    }

    private func unsave(_ postID: String) throws {
        _ = try postJSON("/api/v4/users/\(userID!)/preferences/delete",
                         body: [["user_id": userID as String,
                                 "category": "flagged_post",
                                 "name": postID,
                                 "value": "true"]],
                         token: token)
    }

    /// Pin as the **second** account: a genuine other client, which is what the socket clause means.
    private func pinAsSecondClient(_ postID: String) throws -> Bool {
        _ = try postJSON("/api/v4/posts/\(postID)/pin", body: nil, token: secondToken)
        return try isPinned(postID)
    }

    private func setPinned(_ postID: String, pinned: Bool) throws {
        _ = try postJSON("/api/v4/posts/\(postID)/\(pinned ? "pin" : "unpin")", body: nil, token: token)
    }

    private func isPinned(_ postID: String) throws -> Bool {
        let post = try getJSON("/api/v4/posts/\(postID)", token: token) as? [String: Any] ?? [:]
        return (post["is_pinned"] as? Bool) ?? false
    }

    /// The last status the follow write and the follow read answered, so a red premise names the
    /// wire rather than only the boolean (T48-AV §F6: a red run must be diagnosable).
    private var lastFollowWriteStatus: Int?
    private var lastFollowStatus: Int = 0

    /// Follow or unfollow this reader's thread from **outside** the app, the way a previous session (or
    /// another client) would have left it.
    private func setFollowed(_ postID: String, following: Bool) throws {
        let path = "/api/v4/users/me/teams/\(teamID!)/threads/\(postID)/following"
        var request = URLRequest(url: serverURL.appendingPathComponent(path))
        request.httpMethod = following ? "PUT" : "DELETE"
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        if following {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["state": true])
        }
        let (data, response) = try synchronous(request)
        lastFollowWriteStatus = (response as? HTTPURLResponse)?.statusCode
        print("T48R3 follow write \(request.httpMethod ?? "?") -> \(lastFollowWriteStatus ?? -1) "
              + "\(String(data: data, encoding: .utf8)?.prefix(300) ?? "")")
    }

    /// The server's own answer to "do I follow this thread?" — measured
    /// (`scripts/t48_follow_probe.py`): the CRT thread row answers **200 while followed and 404 once
    /// not**, and no post or thread object carries `is_following`.
    ///
    /// `token!` and not `token`: this field is `String!`, and interpolating it without the bang puts
    /// the literal `Optional("…")` on the wire — measured, the first run of this test failed its
    /// premise with `401 api.context.session_expired` on a header no server could accept.
    private func isFollowed(_ postID: String) throws -> Bool {
        var request = URLRequest(url: serverURL.appendingPathComponent(
            "api/v4/users/me/teams/\(teamID!)/threads/\(postID)"))
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        let (data, response) = try synchronous(request)
        lastFollowStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
        print("T48R3 follow read GET …/threads/\(postID) -> \(lastFollowStatus) "
              + "\(String(data: data, encoding: .utf8)?.prefix(300) ?? "")")
        return lastFollowStatus == 200
    }

    // MARK: - HTTP

    private func getJSON(_ path: String, token: String) throws -> Any {
        var request = URLRequest(url: serverURL.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try synchronous(request)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func postJSON(_ path: String, body: Any?, token: String) throws -> Any {
        try sendJSON("POST", path, body: body, token: token)
    }

    private func putJSON(_ path: String, body: Any?, token: String) throws -> Any {
        try sendJSON("PUT", path, body: body, token: token)
    }

    private func sendJSON(_ method: String, _ path: String, body: Any?, token: String) throws -> Any {
        var request = URLRequest(url: serverURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try synchronous(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw XCTSkip("\(method) \(path) answered \(status) — the fixture is not in the state "
                          + "this test needs")
        }
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return json
    }

    /// This suite's own REST session — **no cookie store**.
    ///
    /// `URLSession.shared` carries `MMAUTHTOKEN` between tests in one runner process; T47-AV measured
    /// that a stale cookie makes a *correct* login answer 401 (`docs/t47-av-build-note.md`, and
    /// `T47CreateChannelAVUITests.restSession` for the fix). The Authorization header this file builds
    /// is the only credential a request should carry.
    private static let restSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

    private func synchronous(_ request: URLRequest) throws -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<(Data, URLResponse), Error>?
        Self.restSession.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else {
                result = .success((data ?? Data(), response ?? URLResponse()))
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 30)
        switch result {
        case .success(let value): return value
        case .failure(let error): throw error
        case nil: throw XCTSkip("the fixture request timed out")
        }
    }
}
