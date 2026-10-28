import XCTest

/// T35 — the native composer against a **real** Mattermost server, with every expectation read back
/// from that server through its own API.
///
/// Why live (the card's DoD forbids fixture-only evidence): the acceptance criteria are statements
/// about what a running server sees and what the reader sees —
///   1. a send appears optimistically and reconciles with the socket echo without a duplicate;
///   2. a failed send is retryable and the text is never lost (backgrounding, relaunch);
///   3. drafts persist per channel across a channel switch, a **team** switch and a relaunch;
///   4. autocomplete queries the documented endpoints and respects channel membership;
///   5. an upload goes out as multipart with real progress, and the post carries the file.
/// A stub could only prove this file's own fixture renders; these prove the client talks to the
/// server the way the server documents.
///
/// Fixture: `scripts/t35_composer_seed.py` (channel `t35-composer` in team `perf`, channel
/// `t35-second-chat` in team `t35-second`).
///
/// Run (local throwaway server, credentials in `scripts/perf_seed.py`):
///
///     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
///     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
///     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
///     python3 scripts/qa-test.py --platform ios --sim "iPhone 16 Pro" \
///       --only-testing MattermostUITests/T35ComposerUITests
///
/// Each test skips (never fails) when the environment or the fixture is missing, like every live
/// test here. Nothing is fabricated: a skipped test is reported as skipped.
final class T35ComposerUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var userID: String!
    private var teamID: String!
    private var secondTeamID: String!

    private let channelName = "t35-composer"
    private let secondChannelName = "t35-second-chat"

    /// A real 1×1 PNG (70 bytes), handed to the composer through the launch-argument seam because a
    /// sandboxed app cannot read the host's `/tmp`. The bytes are a *pick*, not a fixture render: the
    /// upload, the progress, the send and the row are production code.
    private let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    private let pngFilename = "t35-upload.png"

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live composer test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        try ping()
        let session = try authenticate(login: loginID, password: password)
        token = session.token
        userID = session.userID
        let teams = try teamsForMe()
        guard let team = teams.first(where: { $0.name == "perf" }) else {
            throw XCTSkip("team #perf is missing — run scripts/t35_composer_seed.py")
        }
        teamID = team.id
        guard let second = teams.first(where: { $0.name == "t35-second" }) else {
            throw XCTSkip("team #t35-second is missing — run scripts/t35_composer_seed.py")
        }
        secondTeamID = second.id
    }

    // MARK: - 1. Send: once, and with the server's own id

    func testSendingAMessageAppearsOnceAndCarriesTheServersID() throws {
        let channel = try channel(named: channelName, in: teamID)
        let stamp = Int(Date().timeIntervalSince1970)
        let message = "t35 send \(stamp)"

        let app = launchAndOpen(channelName: channelName, teamID: teamID)
        let input = composerInput(app)
        input.tap()
        input.typeText(message)
        attach(app, "t35-01-typed")

        let send = element(app, "channelComposer.send")
        XCTAssertTrue(send.waitForExistence(timeout: 10), "the composer must offer Send:\n\(app.debugDescription)")
        XCTAssertTrue(send.isEnabled, "Send must be enabled once there is text")
        send.tap()

        // The server's answer is the oracle: the exact id it minted for this message.
        let created = try waitForPost(withMessage: message, channelID: channel.id, timeout: 30)
        let postID = try XCTUnwrap(created["id"] as? String, "the server did not mint an id")
        XCTAssertTrue(revealPost(app, postID).exists,
                      "the sent post must be in the list:\n\(app.debugDescription)")
        attach(app, "t35-02-sent")

        // Exactly one row, and none left labelled as pending: the optimistic row was *replaced*, by
        // the client id the server echoed, not appended to.
        let pending = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'post.pending:'"))
        XCTAssertEqual(pending.count, 0, "no optimistic row may survive its own send")
        XCTAssertEqual(rows(app).filter { $0 == "post.\(postID)" }.count, 1)

        // The composer is empty again, ready for the next message.
        XCTAssertEqual((input.value as? String) ?? "", "", "the input must clear after a successful send")

        // …and the server holds exactly one post with this text: a second one would be a duplicate
        // that the UI check above could not see.
        let matches = try channelPosts(channel.id).filter { ($0["message"] as? String) == message }
        XCTAssertEqual(matches.count, 1, "one send must produce exactly one post")
        // The row that is drawn is the row the **server** minted: the optimistic row was replaced by
        // id, not left beside it. `post.pending:` count 0 above is the other half of that sentence.
        // (The server does not echo `pending_post_id` back in the REST body — it carries it on the
        // socket `posted` frame — so the id in the list is the proof, not a field in this answer.)
    }

    // MARK: - 2. Autocomplete: users, then channels

    /// The membership filter is the thing worth asserting, so the term has to be one the **server**
    /// answers with non-members. Measured on this 9.11.19: `/users/autocomplete?name=p` returns
    /// `opsbot`, `perfprobe`, `playbooks`, `probeone832551`, `probezero959035`, and `perfprobe` is the
    /// only one of them in `#t35-composer`. Typing `@per` would not do: every name that term matches
    /// (`perfprobe`) is a member, so the old form of this test passed with the filter deleted —
    /// T35-AV F4. The raw answer is asserted too, below, so the two negative assertions can fail.
    func testAMentionCompletesFromTheChannelsMembersAndInsertsTheUsername() throws {
        let channel = try channel(named: channelName, in: teamID)

        // The oracle first: without this, a client that queried nothing at all would also "pass" the
        // negatives. These two names are in the server's own answer for "p" and are not members.
        let raw = try getJSON("/api/v4/users/autocomplete?name=p&in_channel_id=\(channel.id)"
                              + "&in_team_id=\(teamID)")
        let rawNames = ((raw as? [String: Any])?["users"] as? [[String: Any]] ?? [])
            .compactMap { $0["username"] as? String }
        XCTAssertTrue(rawNames.contains(loginID!),
                      "the server must offer the channel member \(loginID!) for \"p\"; it answered \(rawNames)")
        XCTAssertTrue(rawNames.contains("opsbot") && rawNames.contains("probeone832551"),
                      "the server must offer non-members for \"p\", or the negative half of this test is "
                      + "vacuous; it answered \(rawNames)")

        let app = launchAndOpen(channelName: channelName, teamID: teamID)
        let input = composerInput(app)
        input.tap()
        input.typeText("@p")

        let list = element(app, "composerSuggestions")
        XCTAssertTrue(list.waitForExistence(timeout: 20),
                      "typing @ must ask the server for members:\n\(app.debugDescription)")
        attach(app, "t35-03-mention-suggestions")
        let suggestion = element(app, "composerSuggestion.user-\(loginID!)")
        XCTAssertTrue(suggestion.waitForExistence(timeout: 10),
                      "the signed-in user is a member of this channel and must be offered:\n\(app.debugDescription)")

        // The negative half, on the same list: both names are in the server's answer for "p" (asserted
        // above) and neither is in this channel, so drawing either one means the filter is gone.
        XCTAssertFalse(element(app, "composerSuggestion.user-opsbot").exists,
                       "a team member who is not in this channel must not be offered")
        XCTAssertFalse(element(app, "composerSuggestion.user-probeone832551").exists,
                       "a team member who is not in this channel must not be offered")
        suggestion.tap()

        XCTAssertTrue(waitUntil(timeout: 10) { ((input.value as? String) ?? "").contains("@\(loginID!)") },
                      "choosing the mention must insert @username, was \((input.value as? String) ?? "")")
        attach(app, "t35-04-mention-inserted")
    }

    func testAChannelMentionUsesTheTildeForm() throws {
        let app = launchAndOpen(channelName: channelName, teamID: teamID)
        let input = composerInput(app)
        input.tap()
        input.typeText("#t35")

        let list = element(app, "composerSuggestions")
        XCTAssertTrue(list.waitForExistence(timeout: 20),
                      "typing # must search the team's channels:\n\(app.debugDescription)")
        let suggestion = element(app, "composerSuggestion.channel-\(channelName)")
        XCTAssertTrue(suggestion.waitForExistence(timeout: 10),
                      "#\(channelName) must be offered:\n\(app.debugDescription)")
        suggestion.tap()

        // The trigger is `#`, but Mattermost's channel-link syntax is `~name`.
        XCTAssertTrue(waitUntil(timeout: 10) { ((input.value as? String) ?? "").contains("~\(channelName)") },
                      "a channel mention must be inserted as ~name, was \((input.value as? String) ?? "")")
        attach(app, "t35-05-channel-mention")
    }

    // MARK: - 3. Upload: multipart, real progress, and a post that carries the file

    func testAnAttachmentUploadsWithProgressAndIsSentWithThePost() throws {
        let channel = try channel(named: channelName, in: teamID)
        let stamp = Int(Date().timeIntervalSince1970)
        let message = "t35 upload \(stamp)"

        let app = launchAndOpen(channelName: channelName, teamID: teamID,
                                extraArguments: ["-uiTestAttachFixtureBase64", pngFilename, pngBase64])
        let chip = element(app, "channelComposer.attachment.\(pngFilename)")
        XCTAssertTrue(chip.waitForExistence(timeout: 20),
                      "the picked file must appear in the tray:\n\(app.debugDescription)")

        // The chip publishes the upload's state, so "uploaded" is a fact about the server's answer
        // rather than a progress bar that happened to disappear.
        XCTAssertTrue(waitUntil(timeout: 40) {
            ((chip.value as? String) ?? "").hasPrefix("uploaded ")
        }, "the upload must reach `uploaded`, was \((chip.value as? String) ?? "nil")")
        let fileID = ((chip.value as? String) ?? "").replacingOccurrences(of: "uploaded ", with: "")
        XCTAssertFalse(fileID.isEmpty)
        attach(app, "t35-06-uploaded")

        let input = composerInput(app)
        input.tap()
        input.typeText(message)
        element(app, "channelComposer.send").tap()

        let created = try waitForPost(withMessage: message, channelID: channel.id, timeout: 30)
        let postID = try XCTUnwrap(created["id"] as? String)
        let fileIDs = (created["file_ids"] as? [String]) ?? []
        XCTAssertEqual(fileIDs, [fileID],
                       "the post must reference the file the upload returned")
        XCTAssertTrue(revealPost(app, postID).exists,
                      "the sent post must be in the list:\n\(app.debugDescription)")

        // The server really stored the bytes: the file exists and is named the way the tray said.
        let info = try getJSON("/api/v4/files/\(fileID)/info") as? [String: Any]
        XCTAssertEqual(info?["name"] as? String, pngFilename)
        XCTAssertEqual(info?["size"] as? Int, 70)
        attach(app, "t35-07-post-with-attachment")
    }

    // MARK: - 4. Edit and delete through the row menu

    func testMyOwnPostCanBeEditedAndDeletedFromTheRow() throws {
        let channel = try channel(named: channelName, in: teamID)
        let stamp = Int(Date().timeIntervalSince1970)
        let before = "t35 edit before \(stamp)"
        let after = "t35 edit after \(stamp)"

        let app = launchAndOpen(channelName: channelName, teamID: teamID)
        let input = composerInput(app)
        input.tap()
        input.typeText(before)
        element(app, "channelComposer.send").tap()

        let created = try waitForPost(withMessage: before, channelID: channel.id, timeout: 30)
        let postID = try XCTUnwrap(created["id"] as? String)
        let row = revealPost(app, postID)
        XCTAssertTrue(row.exists, "the sent post must be in the list:\n\(app.debugDescription)")

        // The actions live behind the row's overflow button, as a sheet. A `.contextMenu` (long
        // press) is not reachable here: on iOS 26 the long press lands in the body's Text and opens
        // the system Copy/Share menu instead (docs/t35-build-note.md §11).
        let rowMenu = element(app, "post." + postID + ".menu")
        XCTAssertTrue(rowMenu.waitForExistence(timeout: 15),
                      "my own post must offer its actions")
        rowMenu.tap()
        let edit = element(app, "postOptions.edit")
        XCTAssertTrue(edit.waitForExistence(timeout: 10),
                      "my own post must offer Edit:\n\(app.debugDescription)")
        edit.tap()
        XCTAssertTrue(element(app, "channelComposer.editingBanner").waitForExistence(timeout: 10),
                      "editing must be visible as a mode, not a silent text swap")
        attach(app, "t35-08-editing")

        // Replace the text: the field arrives pre-filled with the post's own message.
        XCTAssertEqual((input.value as? String) ?? "", before)
        input.tap()
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: before.count))
        input.typeText(after)
        element(app, "channelComposer.send").tap()

        XCTAssertTrue(waitUntil(timeout: 30) {
            (try? self.post(id: postID))?["message"] as? String == after
        }, "the server must hold the edited message")
        XCTAssertTrue(element(app, "post.\(postID)").waitForExistence(timeout: 30))
        XCTAssertFalse(element(app, "channelComposer.editingBanner").waitForExistence(timeout: 5),
                       "a successful save must leave edit mode")
        attach(app, "t35-09-edited")

        // Delete through the same sheet: the row becomes the tombstone, the server marks the post.
        element(app, "post." + postID + ".menu").tap()
        let delete = element(app, "postOptions.delete")
        XCTAssertTrue(delete.waitForExistence(timeout: 15),
                      "my own post must offer Delete:\n\(app.debugDescription)")
        delete.tap()
        XCTAssertTrue(waitUntil(timeout: 30) {
            (try? self.postIsGone(postID, channelID: channel.id)) ?? false
        }, "the server must no longer serve the post")
        // The row keeps its slot as a tombstone. The list is a `LazyVStack`, so a row outside the
        // viewport is not in the tree at all — reveal it before asking (the send/edit steps above
        // scrolled the window).
        XCTAssertTrue(revealPost(app, postID).exists,
                      "the row must keep its slot:\n\(app.debugDescription)")
        XCTAssertTrue(element(app, "post.\(postID).deleted").waitForExistence(timeout: 20),
                      "the row must keep its slot as a tombstone:\n\(app.debugDescription)")
        attach(app, "t35-10-deleted")
    }

    // MARK: - 5. Drafts

    func testADraftSurvivesATeamSwitch() throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let draft = "t35 draft team \(stamp) — not sent"
        let otherDraft = "t35 other team draft \(stamp)"
        let composerChannel = try channel(named: channelName, in: teamID)
        let secondChannel = try channel(named: secondChannelName, in: secondTeamID)

        let app = launchAndOpen(channelName: channelName, teamID: teamID)
        let input = composerInput(app)
        input.tap()
        input.typeText(draft)
        attach(app, "t35-11-draft-typed")

        // A team switch changes every channel id the composer could key on, and the second team's
        // single channel is its own draft slot.
        showSidebar(app)
        pickTeam(app, secondTeamID)
        openChannel(app, channelID: secondChannel.id)
        let secondInput = composerInput(app)
        secondInput.tap()
        secondInput.typeText(otherDraft)
        XCTAssertTrue(waitUntil(timeout: 20) { ((composerInput(app).value as? String) ?? "") == otherDraft },
                      "the second team's channel must hold its own draft: "
                      + "\((composerInput(app).value as? String) ?? "")")
        attach(app, "t35-12-second-team-draft")

        showSidebar(app)
        pickTeam(app, teamID)
        openChannel(app, channelID: composerChannel.id)
        XCTAssertTrue(waitUntil(timeout: 25) { ((composerInput(app).value as? String) ?? "") == draft },
                      "the draft must survive a team switch, was \((composerInput(app).value as? String) ?? "")")
        attach(app, "t35-13-draft-after-team-switch")
    }

    func testADraftIsRestoredAfterARelaunch() throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let draft = "t35 draft relaunch \(stamp) — not sent"

        let app = launchAndOpen(channelName: channelName, teamID: teamID)
        let input = composerInput(app)
        input.tap()
        input.typeText(draft)
        attach(app, "t35-14-draft-typed")

        // Kill the app and start it again with no reset flag: it reloads the same server row (same
        // UUID → same draft database) and the same session. The restored location is this channel,
        // so the draft has to come back without any navigation at all.
        app.terminate()
        let relaunched = relaunchSignedIn()
        // A relaunch comes back to the shell, not necessarily to the channel (the push stack is not
        // restored) — and the restored *team* is whatever the shell last selected, which is not
        // necessarily this fixture's team (measured: relaunch landed on team "Operations" while the
        // channel is in team "perf"). So walk the path a person walks: back to the sidebar, pick the
        // team, then find the channel through the quick switcher — the sidebar's own list is a
        // `List`, so a row outside the viewport is not in the accessibility tree at all and
        // tapping by identity would depend on scroll position.
        if !composerInput(relaunched).waitForExistence(timeout: 30) {
            let target = try channel(named: channelName, in: teamID)
            showSidebar(relaunched)
            pickTeam(relaunched, teamID)
            openViaQuickSwitcher(relaunched, term: target.name, channelID: target.id)
        }
        XCTAssertTrue(composerInput(relaunched).waitForExistence(timeout: 40),
                      "a relaunch must reach the channel's composer:\n\(relaunched.debugDescription)")
        XCTAssertTrue(waitUntil(timeout: 40) {
            ((self.composerInput(relaunched).value as? String) ?? "") == draft
        }, "the draft must be restored from disk after a relaunch, was "
           + "\((composerInput(relaunched).value as? String) ?? "")")
        attach(relaunched, "t35-15-draft-restored-after-relaunch")
    }

    // MARK: - Launch

    private func launchAndOpen(channelName: String, teamID: String,
                               extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["-uiTestResetPersistedState",
                         "-uiTestForgetSession", serverURL.absoluteString,
                         "-uiTestSeedServer", serverURL.absoluteString,
                         "-uiTestSeedServerName", "Local Mattermost",
                         "-surfaceMode", "shell=native",
                         "-surfaceMode", "auth=native",
                         "-surfaceMode", "sidebar=native",
                         // The surface under test: the composer, not the pane host.
                         "-surfaceMode", "composer=native",
                         "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        arguments.append(contentsOf: extraArguments)
        app.launchArguments = arguments
        app.launch()
        signIn(app)
        openChannel(app, channelID: (try? channel(named: channelName, in: teamID).id) ?? "")
        return app
    }

    /// The second launch of the draft test: no reset, no seed, no sign-in — the app has to come back
    /// with the same server row, the same session and the same draft database.
    ///
    /// "Back" is one of **two** shapes and the test must not decide which: with nothing changed since
    /// the first launch the shell restores the channel the reader was last in and shows the pushed
    /// pane (no `nativeShell` in the tree), and only a launch that restores nothing lands on the
    /// channel list. `ShellSettle.waitForSignedIn` answers for both (T95-B; `docs/t95-shell-tab-
    /// bar-decision.md` §3 D2).
    private func relaunchSignedIn() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-surfaceMode", "shell=native",
                               "-surfaceMode", "auth=native",
                               "-surfaceMode", "sidebar=native",
                               "-surfaceMode", "composer=native",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        ShellSettle.waitForSignedIn(app)
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

    /// Open a channel the way a person does: its row in the sidebar.
    private func openChannel(_ app: XCUIApplication, channelID: String) {
        let row = element(app, "channelSidebar.channel.\(channelID)")
        XCTAssertTrue(row.waitForExistence(timeout: 40),
                      "the sidebar must list channel \(channelID):\n\(app.debugDescription)")
        row.tap()
        XCTAssertTrue(element(app, "channelPostList").waitForExistence(timeout: 40),
                      "the channel pane must mount:\n\(app.debugDescription)")
    }

    /// Return to the channel sidebar. On a phone the channel view is **pushed** over the tabs, so the
    /// sidebar (its quick switcher and the team rail) is not in the tree at all: `Back` is the only
    /// way to it.
    private func showSidebar(_ app: XCUIApplication) {
        if element(app, "channelSidebar.quickSwitcher").waitForExistence(timeout: 3) { return }
        let back = app.navigationBars.buttons["Back"]
        XCTAssertTrue(back.waitForExistence(timeout: 25),
                      "a pushed channel must offer Back:\n\(app.debugDescription)")
        back.tap()
        XCTAssertTrue(element(app, "channelSidebar.quickSwitcher").waitForExistence(timeout: 30),
                      "Back must land on the channel sidebar:\n\(app.debugDescription)")
    }

    /// Switch the team on the rail, then wait for that team's channel list to be the one on screen.
    private func pickTeam(_ app: XCUIApplication, _ teamID: String) {
        let rail = element(app, "teamSidebar.team.\(teamID)")
        XCTAssertTrue(rail.waitForExistence(timeout: 25),
                      "the team rail must offer \(teamID):\n\(app.debugDescription)")
        rail.tap()
        XCTAssertTrue(element(app, "channelSidebar.quickSwitcher").waitForExistence(timeout: 30),
                      "the switched-to team's sidebar must mount:\n\(app.debugDescription)")
    }

    /// Open a channel through the sidebar's quick switcher: it searches the loaded team's channels,
    /// so it works regardless of which category happens to be expanded.
    private func openViaQuickSwitcher(_ app: XCUIApplication, term: String, channelID: String) {
        let opener = element(app, "channelSidebar.quickSwitcher")
        XCTAssertTrue(opener.waitForExistence(timeout: 20),
                      "the sidebar must offer the quick switcher:\n\(app.debugDescription)")
        opener.tap()
        let field = app.textFields["channelSidebar.quickSwitcher.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10),
                      "the quick switcher must focus a field:\n\(app.debugDescription)")
        field.tap()
        field.typeText(term)
        let result = element(app, "channelSidebar.quickSwitcher.result.\(channelID)")
        XCTAssertTrue(result.waitForExistence(timeout: 20),
                      "the quick switcher must find #\(term):\n\(app.debugDescription)")
        result.tap()
        XCTAssertTrue(element(app, "channelPostList").waitForExistence(timeout: 40),
                      "the switched-to channel must mount:\n\(app.debugDescription)")
    }

    /// The composer's text input. A `UITextView` bridge, so it is a `.textView` — with a fallback to
    /// any element, because SwiftUI's representable wrapping has changed type between OS versions.
    private func composerInput(_ app: XCUIApplication) -> XCUIElement {
        let identifier = "channelComposer.input"
        let textView = app.textViews[identifier]
        if textView.waitForExistence(timeout: 30) { return textView }
        return element(app, identifier)
    }

    // MARK: - Server access (the test is its own API client)

    private struct Team {
        let id: String
        let name: String
    }

    private struct Channel {
        let id: String
        let name: String
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

    private func teamsForMe() throws -> [Team] {
        let rows = try getJSON("/api/v4/users/me/teams") as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = row["id"] as? String, let name = row["name"] as? String else { return nil }
            return Team(id: id, name: name)
        }
    }

    private func channel(named name: String, in team: String) throws -> Channel {
        let row = try getJSON("/api/v4/teams/\(team)/channels/name/\(name)") as? [String: Any]
        guard let row, let id = row["id"] as? String else {
            throw XCTSkip("channel #\(name) is missing — run scripts/t35_composer_seed.py")
        }
        return Channel(id: id, name: row["name"] as? String ?? name)
    }

    private func channelPosts(_ channelID: String, perPage: Int = 200) throws -> [[String: Any]] {
        let page = try getJSON("/api/v4/channels/\(channelID)/posts?per_page=\(perPage)&collapsedThreads=true")
            as? [String: Any] ?? [:]
        let order = page["order"] as? [String] ?? []
        let posts = page["posts"] as? [String: Any] ?? [:]
        return order.compactMap { posts[$0] as? [String: Any] }
    }

    private func post(id: String) throws -> [String: Any]? {
        try getJSON("/api/v4/posts/\(id)") as? [String: Any]
    }

    /// Deleted, as *this* server reports it.
    ///
    /// The documented answer is a post whose `delete_at` is set, and that is what this asserted
    /// first — but a real Matermost 9.11.19 answers `GET /posts/{id}` with **404** once the post is
    /// soft-deleted by its author (measured with `probe_softdelete_oracle.py`: create → DELETE (200)
    /// → read = 404, and the post is gone from the channel's window; `PUT` after delete = 403). Both
    /// answers mean the same thing, so accept either, and require the window to agree.
    private func postIsGone(_ postID: String, channelID: String) throws -> Bool {
        if let row = try? post(id: postID) {
            if (row["status_code"] as? Int) == 404 { return true }
            if let deleteAt = row["delete_at"] as? Int, deleteAt > 0 { return true }
        }
        return try !channelPosts(channelID).contains { ($0["id"] as? String) == postID }
    }

    /// Poll the server until the post with this exact message exists. Returns the server's own object,
    /// which is the oracle for every id the UI is then checked against.
    private func waitForPost(withMessage message: String, channelID: String,
                             timeout: TimeInterval) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        var lastPosts: [[String: Any]] = []
        while Date() < deadline {
            lastPosts = try channelPosts(channelID)
            if let found = lastPosts.first(where: { ($0["message"] as? String) == message }) {
                return found
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTFail("the server never received \(message.debugDescription) in channel \(channelID); "
                + "it holds \(lastPosts.compactMap { $0["message"] as? String })")
        return [:]
    }

    private func getJSON(_ pathWithQuery: String) throws -> Any {
        // `appendingPathComponent` percent-escapes `?`, `=` and `&`, so the path and its query are
        // split here and the query is handed to `URLComponents` as a query.
        let parts = pathWithQuery.split(separator: "?", maxSplits: 1,
                                        omittingEmptySubsequences: false)
        var components = URLComponents(url: serverURL.appendingPathComponent(String(parts[0])),
                                       resolvingAgainstBaseURL: false)
        if parts.count > 1 { components?.query = String(parts[1]) }
        let url = try XCTUnwrap(components?.url)
        var request = URLRequest(url: url)
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

    /// A row that may be outside the viewport: swipe towards newer messages until it exists, then
    /// back towards older ones. The list is a `LazyVStack`, so a row that is off screen is not a
    /// smaller element — it is **not in the tree at all**, and "does it render when the reader gets
    /// there" is the only question a UI test can ask (the same helper T34's suite uses).
    @discardableResult
    private func revealPost(_ app: XCUIApplication, _ postID: String,
                            maxSwipes: Int = 10) -> XCUIElement {
        let target = element(app, "post.\(postID)")
        guard !target.exists else { return target }
        let list = element(app, "channelPostList")
        var swipes = 0
        while !target.exists, swipes < maxSwipes {
            list.swipeUp(velocity: .fast)
            swipes += 1
        }
        while !target.exists, swipes < maxSwipes * 2 {
            list.swipeDown(velocity: .fast)
            swipes += 1
        }
        return target
    }

    /// Every rendered post row (`post.<id>`), one entry per row — ids only, because a frame read per
    /// element is a separate query.
    private func rows(_ app: XCUIApplication) -> [String] {
        let query = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'post.'"))
        return (0..<query.count).compactMap { index in
            let identifier = query.element(boundBy: index).identifier
            guard identifier.components(separatedBy: ".").count == 2,
                  !identifier.hasPrefix("post.pending:") else { return nil }
            return identifier
        }
    }

    /// Keep a screenshot in the result bundle (exported to `docs/t35-shots/` after a run).
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
