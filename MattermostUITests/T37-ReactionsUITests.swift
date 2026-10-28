// T37 — emoji reactions and the picker against a **real** Mattermost server, with every expectation
// read back from that server through its own API.
//
// Why live: the acceptance criteria are statements about two things at once — what the reader sees on
// the native list, and what the server ends up storing. A stub can only prove the first, and it would
// prove it against this file's own fixture rather than against `POST /reactions`.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0, app/actions/remote/reactions.ts.
//
// Fixture: the `perf` team's `t36-threads` channel (`scripts/t36_thread_seed.py`) — reused rather than
// seeded again because a reaction needs a post by *another* author, which that fixture already has (the
// `t36reply` account). Each test makes its own post, so a run never consumes the fixture.
//
// Run (local throwaway server; credentials are the throwaway dev account in `scripts/perf_seed.py`):
//
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     python3 scripts/qa-test.py --platform ios --sim "iPhone 17 Pro" \
//       --only-testing MattermostUITests/T37ReactionsUITests
//
// Every test skips (never fails) when the environment or the fixture is missing.

import XCTest

final class T37ReactionsUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var userID: String!
    private var teamID: String!
    private var channelID: String!
    /// The fixture channel's `display_name` from the server — what the pane header (`nativeChannelTitle`)
    /// reads when that channel is on screen. Read in `setUp`, never hard-coded.
    private var channelDisplayName = ""

    /// The second author the T36 fixture creates: its posts are the ones this app did not make.
    private let secondLogin = "t36reply"
    private let secondPassword = "T36Reply-Not-A-Real-Secret-1"
    private var secondToken: String!
    private var secondUserID: String!
    /// The server's own display names for the two fixture readers — the reactor sheet's oracle.
    private var userDisplayName = ""
    private var secondDisplayName = ""

    private let channelName = "t36-threads"
    /// The only server custom emoji the fixture holds (40×40 PNG, `scripts/t34_post_seed.py`).
    private let customEmoji = "t34parrot"

    /// Outer deadline for a **relaunch** to land on the shell (or on the sign-in it falls back to).
    ///
    /// T55-AV-R F-1 (`t_1f9af95a`): `terminate()` + `launch()` under host load 140-275 took 60-160 s
    /// to reach the shell on this machine, and a fixed 40 s budget reded this test 3/3 while the app
    /// was, in fact, restoring the session and the channel. 240 s is a load-tolerant ceiling for a
    /// first launch after a cold terminate, not a product claim: the test's assertions are unchanged
    /// and still name their element when they fail.
    private let relaunchLandingTimeout: TimeInterval = 240

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live reaction test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
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
        channelDisplayName = channel["display_name"] as? String ?? ""
        let second = try authenticate(login: secondLogin, password: secondPassword)
        secondToken = second.token
        secondUserID = second.userID
        userDisplayName = session.displayName
        secondDisplayName = second.displayName
    }

    // MARK: - 1. The pill is the server's, and a tap writes back

    /// The card's first criterion, in one run: a reaction another reader left is drawn as a pill, a tap
    /// on it adds **my** reaction on the server, a second tap removes it — and the pill never shows a
    /// count the server does not agree with.
    func testTappingAPillWritesTheReactionToTheServerAndTappingAgainRemovesIt() throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let post = try post(message: "t37 reaction target \(stamp)", rootID: nil, as: secondToken)
        let postID = try XCTUnwrap(post["id"] as? String)
        // The other reader's reaction is what puts a pill on the row without the app doing anything.
        try addReaction(postID: postID, emoji: "smile", as: secondToken)

        let app = launchAndOpenChannel()
        XCTAssertTrue(revealPost(app, postID, maxSwipes: 10).exists,
                      "the fixture post must be a row of the channel:\n\(app.debugDescription)")

        let pill = element(app, "post.\(postID).reaction.smile")
        XCTAssertTrue(pill.waitForExistence(timeout: 30),
                      "a reaction the server holds must be drawn as a pill:\n\(app.debugDescription)")
        XCTAssertEqual(pill.label, "smile 1", "one reactor, named by the pill")

        // 1. A tap adds mine, and the server says so.
        pill.tap()
        XCTAssertTrue(waitUntil(timeout: 25) { self.reactionUserIDs(postID, emoji: "smile").contains(self.userID) },
                      "the tap must reach POST /reactions; the server holds "
                      + "\(reactionUserIDs(postID, emoji: "smile"))")
        XCTAssertTrue(waitUntil(timeout: 15) {
            self.element(app, "post.\(postID).reaction.smile").label == "smile 2"
        }, "the pill must follow the server's count; it reads "
           + "\"\(element(app, "post.\(postID).reaction.smile").label)\"")
        attach(app, "t37-01-pill-added")

        // 2. A second tap removes it again.
        element(app, "post.\(postID).reaction.smile").tap()
        XCTAssertTrue(waitUntil(timeout: 25) { !self.reactionUserIDs(postID, emoji: "smile").contains(self.userID) },
                      "the second tap must reach DELETE …/reactions; the server holds "
                      + "\(reactionUserIDs(postID, emoji: "smile"))")
        XCTAssertTrue(waitUntil(timeout: 15) { self.element(app, "post.\(postID).reaction.smile").label
            == "smile 1" },
                      "the pill must follow the server's count:\n\(app.debugDescription)")
        attach(app, "t37-02-pill-removed")
    }

    // MARK: - 2. The picker reaches the same write

    /// The card's second criterion: a reader who has not reacted yet can open the picker from the row
    /// menu, search, pick an emoji, and the server ends up holding exactly that reaction — under the
    /// canonical shortcode (`thumbsup` is stored as the alias group's canonical name).
    func testThePickerFromTheRowMenuAddsTheReactionTheServerStores() throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let post = try post(message: "t37 picker target \(stamp)", rootID: nil, as: secondToken)
        let postID = try XCTUnwrap(post["id"] as? String)

        let app = launchAndOpenChannel()
        XCTAssertTrue(revealPost(app, postID, maxSwipes: 10).exists,
                      "the fixture post must be a row of the channel:\n\(app.debugDescription)")

        let menu = element(app, "post.\(postID).menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 20),
                      "the row must offer its menu:\n\(app.debugDescription)")
        menu.tap()
        let react = element(app, "postOptions.react")
        XCTAssertTrue(react.waitForExistence(timeout: 20),
                      "the menu must offer React:\n\(app.debugDescription)")
        react.tap()

        XCTAssertTrue(element(app, "emojiPicker").waitForExistence(timeout: 20),
                      "React must open the picker:\n\(app.debugDescription)")
        // The first category's first cell: a deterministic, on-screen emoji. (Search and its ranking
        // are pinned by T37ReactionTests; a live run here is about the write path, not the ranking.)
        // One name for the cell, the oracle and the pill. (The first version of this test tapped
        // `grinning` and asserted the server held `tada`, which is red no matter how the app behaves —
        // the reason `docs/t37-build-note.md` first recorded this path as "still red".)
        let picked = "grinning"
        let cell = element(app, "emojiPicker.emoji.\(picked)")
        XCTAssertTrue(cell.waitForExistence(timeout: 20),
                      "the picker must draw the system categories:\n\(app.debugDescription)")
        attach(app, "t37-03-picker-search")
        cell.tap()

        XCTAssertTrue(waitUntil(timeout: 25) { self.reactionUserIDs(postID, emoji: picked).contains(self.userID) },
                      "picking must write POST /reactions; the server holds "
                      + "\(reactionUserIDs(postID, emoji: picked))")
        XCTAssertTrue(waitUntil(timeout: 20) {
            self.element(app, "post.\(postID).reaction.\(picked)").exists
        }, "the new pill must appear on the row:\n\(app.debugDescription)")
        attach(app, "t37-04-picker-pill")
    }

    // MARK: - 3. The alias rule, on the wire

    /// `thumbsup` and `+1` are two rows on the server (measured on 9.11.19) and must be one pill to the
    /// reader. This test leaves *both* spellings on the post — one as the second reader and one as
    /// **me** — and checks that the row draws a single pill with the full count, then that **one** tap
    /// removes every row I hold (both spellings), not just the canonical one, and leaves the other
    /// reader's row alone. That is the coordinator's `heldAliases` rule; without it a client sends one
    /// DELETE and the pill comes back on the next page load.
    func testAliasSpellingsAreOnePillAndOneRemoveClearsEveryRowIHold() throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let post = try post(message: "t37 alias target \(stamp)", rootID: nil, as: secondToken)
        let postID = try XCTUnwrap(post["id"] as? String)
        try addReaction(postID: postID, emoji: "+1", as: secondToken)
        // My own rows, written through the API: a reader who reacted from the web app (or from a
        // second device) can hold two spellings of the same picture, and the client has to clear both.
        try addReaction(postID: postID, emoji: "+1", as: token)
        try addReaction(postID: postID, emoji: "thumbsup", as: token)

        let app = launchAndOpenChannel()
        XCTAssertTrue(revealPost(app, postID, maxSwipes: 10).exists,
                      "the fixture post must be a row of the channel:\n\(app.debugDescription)")

        // One pill, both spellings: the count is the group's, not the canonical alias's.
        let canonicalPill = element(app, "post.\(postID).reaction.+1")
        XCTAssertTrue(canonicalPill.waitForExistence(timeout: 30),
                      "the alias group must be drawn under its canonical name:\n\(app.debugDescription)")
        XCTAssertEqual(canonicalPill.label, "+1 3",
                       "all three rows are one pill (two of them mine, under two spellings)")
        XCTAssertFalse(element(app, "post.\(postID).reaction.thumbsup").exists,
                       "the second spelling must not get its own pill")
        attach(app, "t37-05-alias-pill")

        // ONE tap removes both of my rows and only mine.
        canonicalPill.tap()
        XCTAssertTrue(waitUntil(timeout: 25) {
            !self.reactionUserIDs(postID, emoji: "+1").contains(self.userID)
                && !self.reactionUserIDs(postID, emoji: "thumbsup").contains(self.userID)
        }, "one tap must delete every alias I hold; the server holds "
           + "+1=\(reactionUserIDs(postID, emoji: "+1")) "
           + "thumbsup=\(reactionUserIDs(postID, emoji: "thumbsup"))")
        XCTAssertEqual(reactionUserIDs(postID, emoji: "+1"), [secondUserID],
                       "the other reader's row must survive my remove")
        XCTAssertTrue(waitUntil(timeout: 15) {
            self.element(app, "post.\(postID).reaction.+1").label == "+1 1"
        }, "the pill must follow the server's count; it reads "
           + "\"\(element(app, "post.\(postID).reaction.+1").label)\"")
        attach(app, "t37-06-alias-cleared")
    }

    // MARK: - 4. A burst of taps never drifts from the server's count

    /// T37-AV F5: the suite tapped once, waited, tapped once more. This one bursts taps with no
    /// settling time — the case a coalescing write machine gets wrong — and then requires the pill to
    /// end up showing exactly the count the server holds, with no duplicate row of mine.
    func testBurstOfTapsConvergesAndNeverDrifts() throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let post = try post(message: "t37 burst target \(stamp)", rootID: nil, as: secondToken)
        let postID = try XCTUnwrap(post["id"] as? String)
        try addReaction(postID: postID, emoji: "smile", as: secondToken)

        let app = launchAndSignIn(resetState: true)
        openChannel(app)
        XCTAssertTrue(revealPost(app, postID).exists, "the fixture post must be a row of the channel")
        let pillID = "post.\(postID).reaction.smile"
        XCTAssertTrue(element(app, pillID).waitForExistence(timeout: 30),
                      "the other reader's reaction must be a pill:\n\(app.debugDescription)")
        XCTAssertEqual(pillLabel(app, pillID), "smile 1", "baseline pill")

        // --- 7 taps: odd, so my reaction must end up present.
        burstTap(app, at: element(app, pillID).frame, times: 7)
        let added = converge(pillID: pillID, postID: postID, emoji: "smile",
                             minePresent: true, timeout: 40, app: app)
        attach(app, "t37-07-burst-7-added")
        XCTAssertTrue(added.settled,
                      "after 7 rapid taps the pill must settle on the server's count "
                      + "(last sample: pill=\"\(added.lastPill)\" server=\(added.lastServerCount) "
                      + "mine=\(added.lastMinePresent))")
        XCTAssertEqual(added.lastPill, "smile \(added.lastServerCount)",
                       "the pill must show the server's count, not a drifted one")
        XCTAssertTrue(added.lastMinePresent, "7 taps (odd) must leave my reaction on the server")
        XCTAssertEqual(reactionUserIDs(postID, emoji: "smile").filter { $0 == userID }.count, 1,
                       "my reaction must exist exactly once — a duplicate row is the drift the card forbids")

        // --- 7 more taps: odd again, so my reaction must be gone and only the other reader's row must
        // remain. (Seven, not eight: each tap flips one state, so eight flips would return to where the
        // first burst left it.)
        burstTap(app, at: element(app, pillID).frame, times: 7)
        let removed = converge(pillID: pillID, postID: postID, emoji: "smile",
                               minePresent: false, timeout: 40, app: app)
        attach(app, "t37-08-burst-7-removed")
        XCTAssertTrue(removed.settled,
                      "after 7 more rapid taps the pill must settle back to the server's count "
                      + "(last sample: pill=\"\(removed.lastPill)\" server=\(removed.lastServerCount) "
                      + "mine=\(removed.lastMinePresent))")
        XCTAssertEqual(reactionUserIDs(postID, emoji: "smile"), [secondUserID],
                       "only the other reader's row may survive; residue is a drift")
        XCTAssertEqual(pillLabel(app, pillID), "smile 1",
                       "the pill must read the two-reader baseline again")

        // Stability: three samples two seconds apart, all equal to the server.
        for _ in 0..<3 {
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            let serverCount = reactionUserIDs(postID, emoji: "smile").count
            XCTAssertEqual(pillLabel(app, pillID), "smile \(serverCount)",
                           "the pill drifted after it had settled")
        }
    }

    // MARK: - 5. A server custom emoji renders and is written under its own name

    /// T37-AV F5: the suite picked `grinning` — a system emoji. This one picks the **server's** own
    /// emoji, which is the case that fails when the bundled table shadows it or the catalogue image
    /// never loads (a fallback box or the raw `:name:` text).
    func testServerCustomEmojiIsOfferedAndWritten() throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let post = try post(message: "t37 custom target \(stamp)", rootID: nil, as: secondToken)
        let postID = try XCTUnwrap(post["id"] as? String)

        let app = launchAndSignIn(resetState: true)
        openChannel(app)
        XCTAssertTrue(revealPost(app, postID).exists, "the fixture post must be a row of the channel")

        XCTAssertTrue(openPickerFromRowMenu(app, postID: postID), "the row menu must open the picker")
        let cell = element(app, "emojiPicker.custom.\(customEmoji)")
        XCTAssertTrue(cell.waitForExistence(timeout: 25),
                      "the picker's Custom section must offer the server's `:\(customEmoji):`:\n"
                      + "\(app.debugDescription)")
        attach(app, "t37-09-custom-picker")
        cell.tap()

        XCTAssertTrue(waitUntil(timeout: 25) {
            self.reactionUserIDs(postID, emoji: self.customEmoji).contains(self.userID)
        }, "picking a custom emoji must write it under its own (case-sensitive) name; the server holds "
           + "\(reactionUserIDs(postID, emoji: customEmoji))")
        let pillID = "post.\(postID).reaction.\(customEmoji)"
        XCTAssertTrue(element(app, pillID).waitForExistence(timeout: 20),
                      "a custom reaction must be drawn as its own pill:\n\(app.debugDescription)")
        attach(app, "t37-10-custom-pill")
        XCTAssertEqual(element(app, pillID).label, "\(customEmoji) 1", "the custom pill's label")
    }

    // MARK: - 6. The reactor sheet names the reactors, including me

    /// T37-AV F5: the card's third criterion had no live coverage at all. A long press on a pill must
    /// open the reactor list, and the names must be the server's display names with "(you)" on my row.
    func testReactorSheetNamesBothReadersIncludingMe() throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let post = try post(message: "t37 reactors target \(stamp)", rootID: nil, as: secondToken)
        let postID = try XCTUnwrap(post["id"] as? String)
        try addReaction(postID: postID, emoji: "smile", as: secondToken)
        try addReaction(postID: postID, emoji: "smile", as: token)

        let app = launchAndSignIn(resetState: true)
        openChannel(app)
        XCTAssertTrue(revealPost(app, postID).exists, "the fixture post must be a row of the channel")
        let pill = element(app, "post.\(postID).reaction.smile")
        XCTAssertTrue(pill.waitForExistence(timeout: 30), "both reactors must make a pill")
        XCTAssertEqual(pill.label, "smile 2", "two reactors, one pill")

        pill.press(forDuration: 1.0)
        XCTAssertTrue(element(app, "reactions.sheet").waitForExistence(timeout: 20),
                      "a long press on a pill must open the reactor sheet:\n\(app.debugDescription)")
        // Identifier-contract probe: the sheet's NavigationStack carries `reactions.sheet`; record
        // whether its documented children survive that construct (F2 was the picker's version of it).
        print("PROBE reactions.close by id: \(element(app, "reactions.close").exists); "
              + "reactions.tab.smile by id: \(element(app, "reactions.tab.smile").exists)")

        let mine = element(app, "reactionReactor.\(userID!)")
        XCTAssertTrue(mine.waitForExistence(timeout: 20),
                      "my own row must be listed:\n\(app.debugDescription)")
        XCTAssertTrue(mine.label.contains("(you)"),
                      "my row must be marked as mine; it reads \"\(mine.label)\"")
        XCTAssertTrue(mine.label.contains(userDisplayName),
                      "my row must carry my display name (\(userDisplayName)); it reads \"\(mine.label)\"")

        let other = element(app, "reactionReactor.\(secondUserID!)")
        XCTAssertTrue(other.exists, "the other reactor's row must be listed:\n\(app.debugDescription)")
        XCTAssertTrue(other.label.contains(secondDisplayName),
                      "the other reactor's row must carry the server's display name "
                      + "(\(secondDisplayName)); it reads \"\(other.label)\"")
        XCTAssertFalse(other.label.contains("(you)"), "the other reactor is not me")
        XCTAssertFalse(other.label.contains("Unknown user"),
                       "the sheet must resolve the other reactor's profile, not leave it unknown: "
                       + "\(app.debugDescription)")
        attach(app, "t37-11-reactor-sheet")
    }

    // MARK: - 7. Recents persist across a relaunch

    /// T37-AV F5: the card's suite never relaunched the app, and the app's own
    /// `-uiTestResetPersistedState` seam wipes `UserDefaults`, so persistence is only observable by
    /// starting again *without* that flag.
    func testRecentsSurviveRelaunch() throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let post = try post(message: "t37 recents target \(stamp)", rootID: nil, as: secondToken)
        let postID = try XCTUnwrap(post["id"] as? String)
        let picked = "seedling"
        XCTAssertFalse(reactionUserIDs(postID, emoji: picked).contains(userID),
                       "the recent-recording emoji must not already be on the post")

        let app = launchAndSignIn(resetState: true)
        openChannel(app)
        XCTAssertTrue(revealPost(app, postID).exists, "the fixture post must be a row of the channel")
        XCTAssertTrue(openPickerFromRowMenu(app, postID: postID), "the row menu must open the picker")
        // The grid is a LazyVGrid: only the visible cells exist in the tree. Search narrows it to the
        // one cell, which is also the search path the picker documents ("colon-stripping search").
        searchInPicker(app, for: picked)
        let cell = element(app, "emojiPicker.emoji.\(picked)")
        XCTAssertTrue(cell.waitForExistence(timeout: 20),
                      "the picker must draw a result for \"\(picked)\":\n\(app.debugDescription)")
        cell.tap()
        XCTAssertTrue(waitUntil(timeout: 25) {
            self.reactionUserIDs(postID, emoji: picked).contains(self.userID)
        }, "the pick must write the reaction (the recent is recorded on a successful pick)")

        // Relaunch WITHOUT the reset seam: UserDefaults (and therefore the recents row) must survive.
        app.terminate()
        let relaunched = XCUIApplication()
        relaunched.launchArguments = launchArguments(resetState: false, forgetSession: false)
        relaunched.launch()
        // T55-AV-R F-1 (t_1f9af95a): this wait, not the recents claim, is what made this test red 3/3
        // on this host. The old form was a single `nativeShell.waitForExistence(timeout: 40)`; under
        // load 140-275 a relaunch after `terminate()` took 60-160 s to reach a usable surface, the
        // budget expired first, and a snapshot later in the same failed run showed the pane — and the
        // restored channel — already up. So the landing wait now polls every surface a relaunch can
        // legitimately reach (`nativeShell`, the pushed `nativeChannelPane`, or `loginIDField` when the
        // session was not restored), re-arms instead of spending one element's budget, and names what
        // never appeared. The claim this test protects is unchanged and is not the shell: it is the
        // recents row below, read after a relaunch WITHOUT `-uiTestResetPersistedState`.
        switch waitForLanding(relaunched, timeout: relaunchLandingTimeout) {
        case .shell, .pane:
            break
        case .signIn:
            signIn(relaunched, login: loginID, password: password, shellTimeout: relaunchLandingTimeout)
        case .neither:
            if relaunched.state != .notRunning {
                let shot = XCTAttachment(screenshot: relaunched.screenshot())
                shot.name = "t37r2-relaunch-never-landed"
                shot.lifetime = .keepAlways
                add(shot)
                let tree = XCTAttachment(string: relaunched.debugDescription)
                tree.name = "t37r2-relaunch-never-landed-tree"
                tree.lifetime = .keepAlways
                add(tree)
            }
            XCTFail("the relaunched app reached none of `nativeShell`, `nativeChannelPane` or "
                    + "`loginIDField` within \(Int(relaunchLandingTimeout)) s "
                    + "(XCUIApplication state \(relaunched.state.rawValue)); nothing below this line can "
                    + "be read from an app that never mounted")
            return
        }
        // The assertion is about the surface this test then drives, not the shell's chrome: in the
        // failing runs the `nativeShell` container had not settled while the pane `openChannel`
        // selects into was already in the tree (`nativeChannelPane`, title "T36 Threads").
        XCTAssertTrue(element(relaunched, "nativeChannelPane").waitForExistence(timeout: 120),
                      "the relaunched app must mount the channel pane it then drives:\n"
                      + "\(relaunched.debugDescription)")
        openChannelAfterRelaunch(relaunched)
        attach(relaunched, "t37r2-pane-after-relaunch")
        let paneTitle = element(relaunched, "nativeChannelTitle")
        XCTAssertTrue(revealPost(relaunched, postID).exists,
                      "the fixture channel's pane must be on screen after the relaunch "
                      + "(pane title reads \"\(paneTitle.exists ? paneTitle.label : "<none>")\"):\n"
                      + "\(relaunched.debugDescription)")
        XCTAssertTrue(openPickerFromRowMenu(relaunched, postID: postID),
                      "the row menu must open the picker")
        let recent = element(relaunched, "emojiPicker.recent.\(picked)")
        attach(relaunched, "t37-12-recents-after-relaunch")
        XCTAssertTrue(recent.waitForExistence(timeout: 20),
                      "the emoji picked before the relaunch must be in the Recently Used row:\n"
                      + "\(relaunched.debugDescription)")
    }

    // MARK: - 8. The composer's picker inserts what its own rule says

    /// T37-AV F5 + F3(c): the composer's emoji button opens the same picker in `.composer` mode. The
    /// insertion rule is a **character** for a system emoji and the **shortcode** for a custom one —
    /// pinned here because the T35 parity row claimed the shortcode for both.
    func testComposerPickerInsertsThePickedEmoji() throws {
        let app = launchAndSignIn(resetState: true)
        openChannel(app)
        let button = element(app, "channelComposer.emoji")
        XCTAssertTrue(button.waitForExistence(timeout: 30),
                      "the native composer must offer its emoji button:\n\(app.debugDescription)")
        button.tap()
        XCTAssertTrue(element(app, "emojiPicker").waitForExistence(timeout: 20),
                      "the composer's emoji button must open the picker")
        // `tada` is far down the grid (a LazyVGrid draws only visible cells), so the search box is both
        // the reliable way to reach it and the path the card's "search" behaviour is about.
        searchInPicker(app, for: "tada")
        let cell = element(app, "emojiPicker.emoji.tada")
        XCTAssertTrue(cell.waitForExistence(timeout: 20),
                      "the composer picker must draw a result for \"tada\":\n\(app.debugDescription)")
        cell.tap()
        let input = app.descendants(matching: .any).matching(identifier: "channelComposer.input").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 20), "the composer input must be on screen")
        XCTAssertTrue(waitUntil(timeout: 15) { (input.value as? String ?? "").contains("🎉") },
                      "picking a system emoji in the composer must insert its character; the input reads "
                      + "\"\(input.value as? String ?? "")\"")

        // A custom emoji has no character to insert, so the composer must carry its shortcode.
        button.tap()
        XCTAssertTrue(element(app, "emojiPicker").waitForExistence(timeout: 20),
                      "the composer's emoji button must open the picker again")
        searchInPicker(app, for: customEmoji)
        let customCell = element(app, "emojiPicker.emoji.\(customEmoji)")
        XCTAssertTrue(customCell.waitForExistence(timeout: 20),
                      "the search must also find the server's custom emoji:\n\(app.debugDescription)")
        customCell.tap()
        XCTAssertTrue(waitUntil(timeout: 15) {
            (input.value as? String ?? "").contains(":\(self.customEmoji):")
        }, "picking a custom emoji must insert its shortcode; the input reads "
           + "\"\(input.value as? String ?? "")\"")
        attach(app, "t37-13-composer-insert")
    }

    // MARK: - 9. A reaction from another client arrives over the socket, once

    /// T37-AV **F1**, the finding this card closes: the card's first criterion explicitly names *socket
    /// events*. Nothing in the original suite drove a reaction the app did not itself write, so the
    /// socket path was unproven — and it was dead, because `TeamSocketScope` refused reaction events
    /// and that gate is the only route from the socket into a pane. Another user's reaction is written
    /// through the REST API while the app shows the channel; the pill must appear — once — and leave
    /// again when that row is deleted.
    func testForeignReactionArrivesOverTheSocketOnce() throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let post = try post(message: "t37 socket target \(stamp)", rootID: nil, as: secondToken)
        let postID = try XCTUnwrap(post["id"] as? String)
        let pillID = "post.\(postID).reaction.tada"
        let emoji = "tada"

        let app = launchAndSignIn(resetState: true)
        openChannel(app)
        XCTAssertTrue(revealPost(app, postID).exists, "the fixture post must be a row of the channel")
        XCTAssertFalse(element(app, pillID).exists,
                       "a post with no reactions must have no pill before the other client reacts")

        // The other client (a second session, exactly what the web app would be) reacts while the app
        // is open. Nothing in the app initiated this: only the socket can deliver it.
        try addReaction(postID: postID, emoji: emoji, as: secondToken)
        let pill = element(app, pillID)
        XCTAssertTrue(waitUntil(timeout: 30) { pill.exists },
                      "the other reader's reaction must arrive over the socket:\n\(app.debugDescription)")
        attach(app, "t37-14-socket-added")
        XCTAssertEqual(pill.label, "tada 1",
                       "the pill must draw the one reactor the server holds, exactly once")

        // And a removal by that client must take it away again.
        try removeReaction(postID: postID, emoji: emoji, as: secondToken)
        XCTAssertTrue(waitUntil(timeout: 30) { !element(app, pillID).exists },
                      "the other reader's removal must clear the pill:\n\(app.debugDescription)")
        attach(app, "t37-15-socket-removed")
        XCTAssertTrue(reactionUserIDs(postID, emoji: emoji).isEmpty,
                      "the server must hold no reaction after the other client's delete")
    }

    // MARK: - 10. The control: a foreign *post* arrives on the same socket

    /// The contrast that isolated F1: the same second client, on the same socket, in the same channel —
    /// a `posted` event reaches the open pane and a `reaction_added` must now reach it the same way.
    /// Without the control, "the reaction did not appear" could be blamed on the socket.
    func testForeignPostArrivesButItsReactionDoesNot() throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let app = launchAndSignIn(resetState: true)
        openChannel(app)

        // control: the post is written by the other client *after* the pane is open, so only the
        // socket can add the row.
        let post = try post(message: "t37 socket control \(stamp)", rootID: nil, as: secondToken)
        let postID = try XCTUnwrap(post["id"] as? String)
        XCTAssertTrue(revealPost(app, postID).exists,
                      "the other client's post must arrive over the socket (control):\n\(app.debugDescription)")

        // subject: a reaction on that same post, by the same client, must arrive the same way.
        try addReaction(postID: postID, emoji: "tada", as: secondToken)
        XCTAssertTrue(reactionUserIDs(postID, emoji: "tada").contains(secondUserID),
                      "control: the server must hold the other reader's reaction")
        let appeared = waitUntil(timeout: 30) { self.element(app, "post.\(postID).reaction.tada").exists }
        attach(app, "t37-16-socket-contrast")
        XCTAssertTrue(appeared,
                      "a foreign reaction_added must reach the open pane exactly like the foreign posted "
                      + "above: if the post arrived and the reaction did not, TeamSocketScope is "
                      + "refusing reaction events again (T37-AV F1)")
    }

    // MARK: - Server helpers

    private func ping() throws {
        let url = serverURL.appendingPathComponent("api/v4/system/ping")
        let (_, response) = try synchronous(URLRequest(url: url))
        try XCTSkipUnless((response as? HTTPURLResponse)?.statusCode == 200,
                          "no Mattermost at \(serverURL.absoluteString)")
    }

    private func authenticate(login: String, password: String) throws
        -> (token: String, userID: String, displayName: String) {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/users/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["login_id": login,
                                                                      "password": password])
        let (data, response) = try synchronous(request)
        let http = response as? HTTPURLResponse
        guard http?.statusCode == 200 else {
            throw XCTSkip("could not sign in as \(login): HTTP \(http?.statusCode ?? -1)")
        }
        guard let header = http?.value(forHTTPHeaderField: "Token"),
              let me = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = me["id"] as? String else {
            throw XCTSkip("the login answer carried no token")
        }
        // The reactor sheet draws the server's own display name, so the oracle has to read it the way
        // the sheet's `/users/ids` answer would: first + last name, falling back to the username.
        let display = [(me["first_name"] as? String) ?? "", (me["last_name"] as? String) ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " ")
        return (header, id, display.isEmpty ? (me["username"] as? String ?? "") : display)
    }

    private func teamsForMe() throws -> [[String: Any]] {
        try getJSON("/api/v4/users/me/teams") as? [[String: Any]] ?? []
    }

    private func channel(named name: String, in teamID: String) throws -> [String: Any]? {
        var request = URLRequest(url: serverURL.appendingPathComponent(
            "api/v4/teams/\(teamID)/channels/name/\(name)"))
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        let (data, response) = try synchronous(request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func post(message: String, rootID: String?, as token: String) throws -> [String: Any] {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/posts"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        var body: [String: Any] = ["channel_id": channelID, "message": message]
        if let rootID { body["root_id"] = rootID }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try synchronous(request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201,
                       "the server must accept the fixture post")
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func addReaction(postID: String, emoji: String, as token: String) throws {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/reactions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        guard let me = try getJSON("/api/v4/users/me", as: token) as? [String: Any],
              let uid = me["id"] as? String else {
            throw XCTSkip("could not read the fixture user")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["user_id": uid,
                                                                      "post_id": postID,
                                                                      "emoji_name": emoji])
        let (_, response) = try synchronous(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        XCTAssertTrue(status == 201 || status == 200,
                      "POST /reactions for \(emoji) must be accepted (HTTP \(status))")
    }

    /// `DELETE /users/{uid}/posts/{pid}/reactions/{emoji}` — the other client's removal.
    private func removeReaction(postID: String, emoji: String, as token: String) throws {
        guard let me = try getJSON("/api/v4/users/me", as: token) as? [String: Any],
              let uid = me["id"] as? String else {
            throw XCTSkip("could not read the fixture user")
        }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "+/")
        let encoded = emoji.addingPercentEncoding(withAllowedCharacters: allowed) ?? emoji
        let base = serverURL.absoluteString.hasSuffix("/")
            ? String(serverURL.absoluteString.dropLast()) : serverURL.absoluteString
        guard let url = URL(string: "\(base)/api/v4/users/\(uid)/posts/\(postID)/reactions/\(encoded)") else {
            throw XCTSkip("could not build the delete URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        let (_, response) = try synchronous(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        XCTAssertTrue(status == 200 || status == 404,
                      "DELETE the reaction for \(emoji) must be accepted (HTTP \(status))")
    }

    /// The user ids the server holds for one emoji name on one post — the oracle for every write here.
    private func reactionUserIDs(_ postID: String, emoji: String) -> [String] {
        guard let json = try? getJSON("/api/v4/posts/\(postID)"),
              let post = json as? [String: Any],
              let metadata = post["metadata"] as? [String: Any],
              let reactions = metadata["reactions"] as? [[String: Any]] else { return [] }
        return reactions.filter { $0["emoji_name"] as? String == emoji }
            .compactMap { $0["user_id"] as? String }
    }

    private func getJSON(_ path: String, as token: String? = nil) throws -> Any {
        var request = URLRequest(url: serverURL.appendingPathComponent(path))
        request.setValue("Bearer \(token ?? self.token!)", forHTTPHeaderField: "Authorization")
        let (data, _) = try synchronous(request)
        return try JSONSerialization.jsonObject(with: data)
    }

    /// An ephemeral session with cookies off: the `Authorization` header is then the only identity a
    /// fixture call can carry, so a fixture post cannot silently belong to the app's session.
    private static let fixtureSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    private func synchronous(_ request: URLRequest) throws -> (Data, URLResponse) {
        var result: Result<(Data, URLResponse), Error>?
        let semaphore = DispatchSemaphore(value: 0)
        Self.fixtureSession.dataTask(with: request) { data, response, error in
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

    // MARK: - App helpers

    private func launchArguments(resetState: Bool, forgetSession: Bool) -> [String] {
        var args: [String] = ["-uiTestSeedServer", serverURL.absoluteString,
                              "-uiTestSeedServerName", "Local Mattermost"]
        if resetState { args.insert("-uiTestResetPersistedState", at: 0) }
        if forgetSession { args.append(contentsOf: ["-uiTestForgetSession", serverURL.absoluteString]) }
        args.append(contentsOf: ["-surfaceMode", "shell=native",
                                 "-surfaceMode", "auth=native",
                                 "-surfaceMode", "sidebar=native",
                                 "-surfaceMode", "composer=native",
                                 "-AppleLanguages", "(en)", "-AppleLocale", "en_US"])
        return args
    }

    /// Which signed-in surface a launch has reached: the shell container, the channel pane inside it,
    /// or the native sign-in. A relaunch can legitimately land on any of the three.
    ///
    /// `pane` is not a weaker form of `shell`: measured on this host (2026-10-27), a relaunch that
    /// restores a channel pushes that pane onto a `NavigationStack`, and in that presentation SwiftUI
    /// exposes `nativeChannelPane` while the `nativeShell` container is **absent from the tree
    /// entirely** (`t37r2-recents-alone.log`: an empty `nativeShell` match at 21:20:19.44 while the
    /// same snapshot holds the pane, title "T36 Threads", composer and post list). Polling only
    /// `nativeShell` therefore reports "the app never mounted" against an app that is showing the
    /// screen the test is about to read.
    private enum Landing {
        case shell
        case pane
        case signIn
        case neither
    }

    /// Poll for the surfaces a launch can reach, and report **which** one appeared.
    ///
    /// T55-AV-R F-1 (`t_1f9af95a`): a single `nativeShell.waitForExistence(timeout:)` cannot tell
    /// "the shell is slow on a loaded host" from "the app never got there", and it cannot see the
    /// sign-in branch the relaunch is allowed to take (`-uiTestForgetSession` is absent). Both
    /// identifiers plus the pane are read every tick, so the app settling on the sign-in surface or
    /// on a pushed pane is not charged against the shell container's budget, and `neither` names
    /// every element the caller should have seen instead of leaving a bare `false`.
    private func waitForLanding(_ app: XCUIApplication, timeout: TimeInterval) -> Landing {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let landing = landing(of: app) { return landing }
            // A tick, not a blocking `waitForExistence`: the loop has to look at several surfaces,
            // and a long snapshot wait on one of them is the budget shape this helper replaces.
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        // The tree can settle between the final tick and this line.
        return landing(of: app) ?? .neither
    }

    private func landing(of app: XCUIApplication) -> Landing? {
        if element(app, "nativeShell").exists { return .shell }
        if element(app, "nativeChannelPane").exists { return .pane }
        if app.textFields["loginIDField"].exists { return .signIn }
        return nil
    }

    /// Launch and sign in, leaving the shell up (the adopted live tests open the channel themselves).
    private func launchAndSignIn(resetState: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = launchArguments(resetState: resetState, forgetSession: true)
        app.launch()
        signIn(app, login: loginID, password: password)
        return app
    }

    /// Sign in and wait for the shell. `shellTimeout` is the relaunch path's load-tolerant budget; a
    /// fresh test launch keeps the 45 s it has always had (measured worst case on this host: ~20 s).
    private func signIn(_ app: XCUIApplication, login: String, password: String,
                        shellTimeout: TimeInterval = 45) {
        let field = app.textFields["loginIDField"]
        XCTAssertTrue(field.waitForExistence(timeout: 25),
                      "the native sign-in must mount against \(serverURL.absoluteString):\n\(app.debugDescription)")
        field.tap()
        field.typeText(login)
        let secret = app.secureTextFields["loginPasswordField"]
        XCTAssertTrue(secret.exists)
        secret.tap()
        secret.typeText(password)
        app.buttons["loginSubmitButton"].tap()
        XCTAssertTrue(element(app, "nativeShell").waitForExistence(timeout: shellTimeout),
                      "signing in must reach the shell (`nativeShell`):\n\(app.debugDescription)")
    }

    private func launchAndOpenChannel() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = launchArguments(resetState: true, forgetSession: true)
        app.launch()
        signIn(app)
        openChannel(app)
        return app
    }

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

    private func openChannel(_ app: XCUIApplication) {
        var row = element(app, "channelSidebar.channel.\(channelID!)")
        if !row.waitForExistence(timeout: 20) {
            // A relaunch can restore a different team on the rail (the fixture channel lives in #perf),
            // so select the fixture team before looking for the row again.
            let team = element(app, "teamSidebar.team.\(teamID!)")
            if team.waitForExistence(timeout: 10) { team.tap() }
            row = element(app, "channelSidebar.channel.\(channelID!)")
        }
        XCTAssertTrue(row.waitForExistence(timeout: 45),
                      "the sidebar must list channel \(channelID ?? ""):\n\(app.debugDescription)")
        row.tap()
        XCTAssertTrue(element(app, "channelPostList").waitForExistence(timeout: 40),
                      "the channel pane must mount:\n\(app.debugDescription)")
    }

    /// Put the fixture channel on screen after a relaunch, in **either** of the two shapes a relaunch
    /// can land in, and only on a pane that actually holds rows.
    ///
    /// Two shapes were measured on this host (2026-10-27, `build/logs/t37r2/`):
    ///
    /// 1. The sidebar (`channelSidebar.channel.*`) is in the tree — the pre-relaunch shape. `openChannel`
    ///    taps the row, as it always has.
    /// 2. The relaunch restores the channel *pane*, and compact layout pushes it over the sidebar inside
    ///    a `NavigationStack`, so **no row exists to tap** and the old `openChannel` spent 20 s + 45 s
    ///    on an element that is never there (`t37r2-recents-max.log`, before this fix).
    ///
    /// A restored pane is accepted, but only when it holds at least one post row: on this host the
    /// restore also lands on a pane whose header and composer are drawn while `channelPostList` reports
    /// seven pages of content and paints **no rows at all** for 85 s at load 5 (`t37r2-alone-b2.log`,
    /// and the two screenshots `manual-*-relaunch*.png`). That pane is not a usable channel, so the test
    /// falls back to the route a reader takes — `Back`, then the sidebar row — instead of reading the
    /// recents claim off a screen that has nothing on it.
    private func openChannelAfterRelaunch(_ app: XCUIApplication) {
        let title = element(app, "nativeChannelTitle")
        let row = element(app, "channelSidebar.channel.\(channelID!)")
        let back = app.navigationBars.buttons["Back"]

        // The restore painted its rows in ~2 s whenever it worked, so the grace below is a generous
        // multiple of the observed paint, not a budget for a slow host.
        let grace = Date().addingTimeInterval(20)
        while Date() < grace {
            if row.exists { openChannel(app); return }
            if title.exists, title.label == channelDisplayName, hasAnyPostRow(app) { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        if title.exists, title.label == channelDisplayName, hasAnyPostRow(app) { return }
        if back.exists, back.isHittable { back.tap() }
        openChannel(app)
    }

    /// Does the post list hold at least one row in the tree right now?
    ///
    /// The restored-but-empty pane measured on this host keeps `channelPostList` and its seven-page
    /// content height but no `post.*` child, so "the pane is up" and "the channel is readable" are two
    /// different facts and the test needs the second.
    private func hasAnyPostRow(_ app: XCUIApplication) -> Bool {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "post."))
            .firstMatch
            .exists
    }

    /// Type into the picker's search box **by its documented identifier**.
    ///
    /// T37-AV F2 measured that `emojiPicker.search` did not exist in the tree (the container id on the
    /// layout VStack shadowed it), so the harness this helper came from had to fall back to "a text
    /// field identified `emojiPicker`". The fallback is deliberately gone: the sheet carries
    /// `.accessibilityElement(children: .contain)` now, and every adopted live test that searches
    /// therefore asserts the identifier resolves — that is F2's regression test.
    private func searchInPicker(_ app: XCUIApplication, for term: String) {
        let documented = element(app, "emojiPicker.search")
        guard documented.waitForExistence(timeout: 10) else {
            XCTFail("the picker must expose `emojiPicker.search` (T37-AV F2); the sheet's search field "
                    + "is addressable by no documented name:\n\(app.debugDescription)")
            return
        }
        documented.tap()
        documented.typeText(term)
    }

    /// Open the picker from a row's options menu (the only way to reach a **first** reaction).
    private func openPickerFromRowMenu(_ app: XCUIApplication, postID: String) -> Bool {
        let menu = element(app, "post.\(postID).menu")
        guard menu.waitForExistence(timeout: 20) else { return false }
        menu.tap()
        let react = element(app, "postOptions.react")
        guard react.waitForExistence(timeout: 20) else { return false }
        react.tap()
        return element(app, "emojiPicker").waitForExistence(timeout: 20)
    }

    /// Tap `times` times with no waiting between taps (the machine sees a burst, not a sequence).
    ///
    /// The taps go through the **application's** coordinate space at the pill's captured frame, not
    /// through `element.coordinate(…)`: a burst re-renders the row after every write, and a coordinate
    /// that re-resolves the element raises "No matches found" the moment the pill is between frames
    /// (measured on this host — the first port of this test failed exactly that way, at the burst, and
    /// not on an assertion).
    private func burstTap(_ app: XCUIApplication, at frame: CGRect, times: Int) {
        let point = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: frame.midX, dy: frame.midY))
        for _ in 0..<times { point.tap() }
    }

    private struct Convergence {
        var settled: Bool
        var lastPill: String
        var lastServerCount: Int
        var lastMinePresent: Bool
    }

    /// Poll until the pill's count equals the server's grouping of that emoji and my own reaction's
    /// presence matches `minePresent`.
    private func converge(pillID: String, postID: String, emoji: String,
                          minePresent: Bool, timeout: TimeInterval,
                          app: XCUIApplication) -> Convergence {
        let started = Date()
        var lastPill = ""
        var lastCount = -1
        var lastMine = false
        while Date().timeIntervalSince(started) < timeout {
            let rows = reactionUserIDs(postID, emoji: emoji)
            lastCount = rows.count
            lastMine = rows.contains(userID)
            // A re-render can drop the pill from the tree for a frame; a sample taken then is "not yet",
            // not "wrong", so it must not raise out of the poll.
            lastPill = pillLabel(app, pillID) ?? ""
            if lastMine == minePresent && lastPill == "\(emoji) \(lastCount)" {
                return Convergence(settled: true, lastPill: lastPill, lastServerCount: lastCount,
                                   lastMinePresent: lastMine)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return Convergence(settled: false, lastPill: lastPill, lastServerCount: lastCount,
                           lastMinePresent: lastMine)
    }

    /// The pill's label, or `nil` when the row is not in the tree at this instant (a snapshot taken
    /// between the write and the re-render). Reading `.label` on a missing element raises, which would
    /// turn a timing artefact into a red.
    private func pillLabel(_ app: XCUIApplication, _ identifier: String) -> String? {
        let pill = element(app, identifier)
        return pill.exists ? pill.label : nil
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

    /// A channel row that may be outside the viewport (`LazyVStack`: an off-screen row is not in the
    /// tree at all).
    @discardableResult
    private func revealPost(_ app: XCUIApplication, _ postID: String,
                            maxSwipes: Int = 12) -> XCUIElement {
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

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
