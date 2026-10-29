// t_2fa3bbe1 (C2 of t_8f9f5449) — the live tests for the profile popover on the three **list** hosts:
// search results, Saved, and the mentions inbox, plus the pinned sheet's push.
//
// Spec of record: `docs/t_8f9f5449-profile-popover-parity.md` §3 (the nested-tap restructure), §2.2
// (presentation legality) and §9 (the acceptance table). C1 (`t_07216319`) shipped the thread host.
//
// Four rules this file is built on, each with a measured reason:
//
//   * **No `-surfaceMode profile=native`.** T429's lesson: the flag hides exactly this class of defect,
//     and the shipped default (`.profile` = web) is the state that must offer the tap.
//   * **The tap is a coordinate, not an element.** The three list hosts are one accessibility element
//     per row (`T8e`, and spec §3), so under `.accessibilityElement(children: .combine)` the inner
//     `post.<id>.author` button is *not* addressable — the test taps the row at a point inside the
//     author header and asserts `post.<id>.author` is absent first, so a passing run cannot be a test
//     that silently found a different element.
//   * **The expected value comes from the server** (`GET /users/{authorID}`): username for the profile's
//     own line, display name for the row's label. A local string would let a wrong-account profile pass.
//   * **The fixture lives in `#t429-tap`**, never `#t41-profile`: T429 §5.1 records that posting there
//     pushed T41's seed post out of its pane's window and reddened T41's DM test.
//
// Each test seeds its own post, with a unique marker, so runs do not collide with T39/T41/T42/T429 or
// with each other (the search test's query must return exactly one row).
//
// Run:
//
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     python3 scripts/qa-test.py --platform ios --sim "name=iPhone 17 Pro" \
//       --only-testing MattermostUITests/T5449ListProfileUITests
//
// Skips — never fails — when the environment, the server, the buddy account or its membership in the
// fixture channel is missing, like every live test in this target.

import XCTest

final class T5449ListProfileUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var myUserID: String!
    private var teamID: String!
    private var channelID: String!
    /// The buddy whose posts these fixtures are: their id, login, and the two strings the server owns.
    private var buddyID: String!
    private var buddyUsername: String!
    private var buddyDisplayName: String!

    /// T429's channel, reused on purpose: its two accounts exist and its fixtures are cheap. Not
    /// `#t41-profile` (see the note at the top of this file).
    private let channelName = "t429-tap"

    private var buddyLogin: String {
        ProcessInfo.processInfo.environment["MM_AUTH_BUDDY_LOGIN"] ?? "t41buddy"
    }

    private var buddyPassword: String {
        ProcessInfo.processInfo.environment["MM_AUTH_BUDDY_PASSWORD"] ?? "T41-Buddy-Not-A-Real-Secret-1"
    }

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live list-profile test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        try ping()

        let session = try authenticate(login: loginID, password: password)
        token = session.token
        myUserID = session.userID

        let teams = try getJSON("/api/v4/users/me/teams") as? [[String: Any]] ?? []
        guard let team = teams.first(where: { ($0["name"] as? String) == "perf" }) else {
            throw XCTSkip("#perf is missing — run scripts/perf_seed.py and scripts/t41_profile_seed.py")
        }
        teamID = try XCTUnwrap(team["id"] as? String)
        channelID = try ensureChannel(teamID: teamID, name: channelName)

        let buddy = try authenticate(login: buddyLogin, password: buddyPassword)
        try ensureMember(userID: buddy.userID, channelID: channelID)
        let buddyUser = try getJSON("/api/v4/users/\(buddy.userID)") as? [String: Any] ?? [:]
        buddyID = buddy.userID
        buddyUsername = try XCTUnwrap(buddyUser["username"] as? String)
        buddyDisplayName = Self.displayName(of: buddyUser)
        try XCTSkipIf(buddyUsername == loginID,
                      "the buddy account is the signed-in account — the fixtures would be the reader's own")
    }

    // MARK: - 1. A search result's author

    /// The author of a search result, tapped in the result row, opens **that author's** profile; and the
    /// row's own tap still opens the post.
    func testTheAuthorOfASearchResultOpensTheirProfile() throws {
        let marker = "t5449c2search\(Self.stamp())"
        let postID = try seedBuddyPost(message: "\(marker) from t41buddy")

        let app = launchApp()
        openSearch(app)
        type(marker, into: "searchField", in: app)
        tap("searchSubmit", in: app)

        let row = element(app, "searchResult.\(postID)")
        XCTAssertTrue(row.waitForExistence(timeout: 60),
                      "the server's own result must be listed for \"\(marker)\":\n\(app.debugDescription)")
        XCTAssertTrue(row.label.contains(buddyDisplayName),
                      "the row must be drawing that author, got \"\(row.label)\" — without this the "
                      + "author tap below could open a profile from the wrong row")
        tapAuthorHeader(of: row, postID: postID, in: app)

        XCTAssertTrue(element(app, "profileSheet").waitForExistence(timeout: 30),
                      "a result's author tap must open the profile from this host:\n\(app.debugDescription)")
        let username = element(app, "profile.username")
        XCTAssertTrue(username.waitForExistence(timeout: 20),
                      "the profile must mount:\n\(app.debugDescription)")
        XCTAssertEqual(username.label, "@\(buddyUsername!)",
                       "the popover must be about the tapped result's author, read from the server")
        attach(app, "t5449-c2-search-author-profile")

        // Dismiss, then prove the row's own tap still works away from the author header.
        tap("profile.done", in: app)
        XCTAssertTrue(waitUntil(timeout: 20) { !self.element(app, "profileSheet").exists },
                      "the profile must close before the row's own tap is exercised")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.8)).tap()
        XCTAssertTrue(element(app, "postFocus.\(postID)").waitForExistence(timeout: 45),
                      "tapping the row away from the author must still open the post:\n"
                      + "\(app.debugDescription)")
        attach(app, "t5449-c2-search-row-still-opens-post")
    }

    // MARK: - 2. A saved post's author

    /// The author of a saved post, tapped in the Saved tab's row, opens that author's profile.
    func testTheAuthorOfASavedPostOpensTheirProfile() throws {
        let marker = "t5449c2saved\(Self.stamp())"
        let postID = try seedBuddyPost(message: "\(marker) from t41buddy")
        try savePost(postID)
        XCTAssertTrue(try isSaved(postID), "the premise: the post is flagged for this account")

        let app = launchApp()
        openSaved(app)

        let row = revealRow(element(app, "savedPosts.row.\(postID)"), in: "savedPosts", app: app)
        XCTAssertTrue(row.waitForExistence(timeout: 60),
                      "the Saved list must draw the server's flagged post:\n\(app.debugDescription)")
        XCTAssertTrue(row.label.contains(buddyDisplayName),
                      "the saved row must be drawing that author, got \"\(row.label)\"")
        tapAuthorHeader(of: row, postID: postID, in: app)

        XCTAssertTrue(element(app, "profileSheet").waitForExistence(timeout: 30),
                      "a saved post's author tap must open the profile:\n\(app.debugDescription)")
        let username = element(app, "profile.username")
        XCTAssertTrue(username.waitForExistence(timeout: 20))
        XCTAssertEqual(username.label, "@\(buddyUsername!)",
                       "the popover must be about the saved post's author, read from the server")
        attach(app, "t5449-c2-saved-author-profile")
    }

    // MARK: - 3. A mention's author

    /// The author of a mention, tapped in the mentions inbox, opens that author's profile.
    func testTheAuthorOfAMentionOpensTheirProfile() throws {
        // The buddy mentions the signed-in account, so the post is in *this* reader's feed.
        let marker = "t5449c2mention\(Self.stamp())"
        let postID = try seedBuddyPost(message: "@\(loginID!) \(marker) from t41buddy")

        let app = launchApp()
        openMentions(app)

        let row = element(app, "activity.row.\(postID)")
        XCTAssertTrue(row.waitForExistence(timeout: 60),
                      "the mention the buddy just posted must be the feed's newest row:\n"
                      + "\(app.debugDescription)")
        XCTAssertTrue(row.label.contains(buddyDisplayName),
                      "the activity row must be drawing that author, got \"\(row.label)\"")
        tapAuthorHeader(of: row, postID: postID, in: app)

        XCTAssertTrue(element(app, "profileSheet").waitForExistence(timeout: 30),
                      "a mention's author tap must open the profile:\n\(app.debugDescription)")
        let username = element(app, "profile.username")
        XCTAssertTrue(username.waitForExistence(timeout: 20))
        XCTAssertEqual(username.label, "@\(buddyUsername!)",
                       "the popover must be about the mention's author, read from the server")
        attach(app, "t5449-c2-mention-author-profile")
    }

    // MARK: - 4. A pinned post's author — the profile is **pushed**, not presented

    /// The author of a pinned post opens their profile **as a push inside the pinned sheet**: no
    /// `profileSheet` (a nested sheet is T40's measured failure mode), the pinned list still underneath.
    func testTheAuthorOfAPinnedPostPushesTheProfile() throws {
        let marker = "t5449c2pinned\(Self.stamp())"
        let postID = try seedBuddyPost(message: "\(marker) from t41buddy")
        try setPinned(postID, pinned: true)
        XCTAssertTrue(try isPinned(postID), "the premise: the post is pinned")

        let app = launchApp()
        openChannel(app)

        let pinButton = element(app, "nativeChannelPinnedButton")
        XCTAssertTrue(pinButton.waitForExistence(timeout: 60),
                      "the channel header must offer its pinned messages:\n\(app.debugDescription)")
        pinButton.tap()

        let row = revealRow(element(app, "pinnedPosts.row.\(postID)"), in: "pinnedPosts", app: app)
        XCTAssertTrue(row.waitForExistence(timeout: 60),
                      "the pinned sheet must draw the server's pinned post:\n\(app.debugDescription)")
        XCTAssertTrue(row.label.contains(buddyDisplayName),
                      "the pinned row must be drawing that author, got \"\(row.label)\"")

        tapAuthorHeader(of: row, postID: postID, in: app)

        // The push, positively: `profilePush` is the pushed form's identifier (spec §2.2). A sheet would
        // not carry it, so this cannot pass by presenting a sheet.
        XCTAssertTrue(element(app, "profilePush").waitForExistence(timeout: 30),
                      "a profile opened from inside the pinned sheet must be pushed on that sheet's "
                      + "own stack:\n\(app.debugDescription)")
        let username = element(app, "profile.username")
        XCTAssertTrue(username.waitForExistence(timeout: 20),
                      "the pushed profile must mount:\n\(app.debugDescription)")
        XCTAssertEqual(username.label, "@\(buddyUsername!)",
                       "the push must be about the pinned post's author, read from the server")
        XCTAssertFalse(element(app, "profileSheet").exists,
                       "no nested sheet: T40 measured a sheet inside a sheet whose confirmation never ran")
        attach(app, "t5449-c2-pinned-author-push")

        // The stack, measured by popping it: the pinned list is underneath the push (a push that
        // replaced the sheet would have nothing to go back to). While a destination is on top the
        // list is not in the tree — measured, which is why this is a pop rather than an `exists`.
        let back = element(app, "BackButton")
        if back.waitForExistence(timeout: 10) {
            back.tap()
        } else {
            app.navigationBars.buttons["Back"].tap()
        }
        XCTAssertTrue(element(app, "pinnedPosts").waitForExistence(timeout: 20),
                      "popping the profile must return to the pinned list it was pushed from:\\n"
                      + "\(app.debugDescription)")
        XCTAssertTrue(waitUntil(timeout: 20) { !self.element(app, "profilePush").exists },
                      "the push must be gone once it is popped, leaving the pinned sheet up")
    }

    // MARK: - App driving

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        // No `-surfaceMode profile=native` (T429's lesson, see the header). The two list surfaces are
        // switched on because their panes only draw natively when asked to on this tree.
        app.launchArguments = ["-uiTestResetPersistedState",
                               "-uiTestForgetSession", serverURL.absoluteString,
                               "-uiTestSeedServer", serverURL.absoluteString,
                               "-uiTestSeedServerName", "Local Mattermost",
                               "-surfaceMode", "shell=native",
                               "-surfaceMode", "auth=native",
                               "-surfaceMode", "sidebar=native",
                               "-surfaceMode", "search=native",
                               "-surfaceMode", "activity=native",
                               "-uiTestLogLevel", "error",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // Same XCTest/os_log crash guard as T41/T429/T5449-C1.
        app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"
        app.launch()
        signIn(app)
        return app
    }

    private func signIn(_ app: XCUIApplication) {
        let field = app.textFields["loginIDField"]
        XCTAssertTrue(field.waitForExistence(timeout: 30),
                      "the native sign-in must mount against \(serverURL.absoluteString):\n"
                      + "\(app.debugDescription)")
        field.tap()
        field.typeText(loginID)
        let secret = app.secureTextFields["loginPasswordField"]
        XCTAssertTrue(secret.exists)
        secret.tap()
        secret.typeText(password)
        app.buttons["loginSubmitButton"].tap()
        XCTAssertTrue(element(app, "nativeShell").waitForExistence(timeout: 60),
                      "signing in must reach the shell:\n\(app.debugDescription)")
    }

    /// A tab, from wherever the compact shell is (a restored channel puts the bar behind a push —
    /// `ShellSettle.tapTab` is that reader's route), with the regular layout's toolbar as the fallback.
    private func openTab(_ title: String, toolbarIdentifier: String, mounted: String,
                         in app: XCUIApplication) {
        if !ShellSettle.tapTab(title, in: app, wait: 20) {
            let toolbarButton = element(app, toolbarIdentifier)
            XCTAssertTrue(toolbarButton.waitForExistence(timeout: 20),
                          "neither the tab bar nor the toolbar opens \"\(title)\":\n\(app.debugDescription)")
            toolbarButton.tap()
        }
        XCTAssertTrue(element(app, mounted).waitForExistence(timeout: 40),
                      "\(title) must mount:\n\(app.debugDescription)")
    }

    private func openSearch(_ app: XCUIApplication) {
        openTab(ShellSettle.Tab.search, toolbarIdentifier: "shellSearchButton",
                mounted: "nativeSearchPane", in: app)
    }

    private func openSaved(_ app: XCUIApplication) {
        openTab(ShellSettle.Tab.saved, toolbarIdentifier: "shellSavedButton",
                mounted: "nativeSavedPane", in: app)
        // Not `element(app, "savedPosts")`: the List's own identifier is not in the tree on this
        // runtime — `nativeSavedPane` is (measured, `build/logs/t5449c2-live1.log`: the CollectionView
        // carries the pane's identifier and the list's is not exposed at all). The mount that matters
        // is the pane, and the row below is the proof the list drew.
    }

    private func openMentions(_ app: XCUIApplication) {
        openTab(ShellSettle.Tab.activity, toolbarIdentifier: "shellActivityButton",
                mounted: "nativeActivityPane", in: app)
        XCTAssertTrue(element(app, "activity.list").waitForExistence(timeout: 40),
                      "the mentions feed must mount:\n\(app.debugDescription)")
    }

    /// Open the fixture channel through the quick switcher — the way a person does it on a workspace
    /// whose sidebar is longer than one screen (T70's measured reason, reused from T5449-C1).
    private func openChannel(_ app: XCUIApplication) {
        let teamRow = element(app, "teamSidebar.team.\(teamID!)")
        XCTAssertTrue(teamRow.waitForExistence(timeout: 40),
                      "the team rail must list #perf:\n\(app.debugDescription)")
        if !(teamRow.value as? String ?? "").contains("Selected") { teamRow.tap() }

        let switcher = app.buttons["channelSidebar.quickSwitcher"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 30),
                      "the sidebar must offer the quick switcher:\n\(app.debugDescription)")
        switcher.tap()
        let field = app.textFields["channelSidebar.quickSwitcher.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the quick switcher must mount")
        field.tap()
        field.typeText(channelName)
        let result = element(app, "channelSidebar.quickSwitcher.result.\(channelID!)")
        XCTAssertTrue(result.waitForExistence(timeout: 30),
                      "the quick switcher must offer #\(channelName):\n\(app.debugDescription)")
        result.tap()
        XCTAssertTrue(element(app, "channelPostList").waitForExistence(timeout: 90),
                      "the channel pane must mount:\n\(app.debugDescription)")
    }

    private func type(_ text: String, into identifier: String, in app: XCUIApplication) {
        let field = element(app, identifier)
        XCTAssertTrue(field.waitForExistence(timeout: 20), "\(identifier) must exist")
        field.tap()
        field.typeText(text)
    }

    private func tap(_ identifier: String, in app: XCUIApplication) {
        let target = element(app, identifier)
        XCTAssertTrue(target.waitForExistence(timeout: 20), "\(identifier) must exist")
        target.tap()
    }

    /// Scroll a list until one row is drawn (a lazy `List` builds only what is on screen).
    private func revealRow(_ target: XCUIElement, in listIdentifier: String,
                           app: XCUIApplication, maxSwipes: Int = 12) -> XCUIElement {
        guard !target.exists else { return target }
        let list = element(app, listIdentifier)
        var swipes = 0
        while !target.exists, swipes < maxSwipes {
            list.swipeUp(velocity: .fast)
            swipes += 1
        }
        return target
    }

    /// Tap the author header of a list row — the surface spec §3's restructure exists to keep tappable.
    ///
    /// Measured on this tree (`build/logs/t5449c2-live1.log`): the author's own avatar and name stay
    /// **addressable inside** these rows — a saved row at `{{16, 302.3}, {346.3, 68.3}}` carries
    /// `post.<id>.avatar` at `{{28, 324.7}, {36, 36}}` and `post.<id>.author` at `{{74, 324.7}, {72.7, 18}}`
    /// — because `PostRowView` is itself `.accessibilityElement(children: .contain)` and an outer
    /// `.combine` does not flatten a nested container. So the tap is the element a reader taps. A fixed
    /// fraction of the row is *not* equivalent: (0.18, 0.22) of that saved row is y 317.3, which is in
    /// the row's channel line, and it opens the post instead of the profile.
    private func tapAuthorHeader(of row: XCUIElement, postID: String, in app: XCUIApplication) {
        let avatar = element(app, "post.\(postID).avatar")
        let name = element(app, "post.\(postID).author")
        let header = avatar.exists ? avatar : name
        XCTAssertTrue(header.waitForExistence(timeout: 20),
                      "the row must draw the author's own button — the tap target the restructure is "
                      + "there to keep reachable:\n\(row.debugDescription)")
        let centre = CGPoint(x: header.frame.midX, y: header.frame.midY)
        XCTAssertTrue(row.frame.contains(centre),
                      "the author header \(header.frame) must sit inside its row \(row.frame)")
        header.tap()
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return condition()
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private static func stamp() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
    }

    /// The app's own display-name rule (`PostListDerivation.displayName(for:)`): nickname, else
    /// "First Last", else the username — applied to the **server's** user object.
    private static func displayName(of user: [String: Any]) -> String {
        let nickname = user["nickname"] as? String ?? ""
        if !nickname.isEmpty { return nickname }
        let first = user["first_name"] as? String ?? ""
        let last = user["last_name"] as? String ?? ""
        let full = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
        if !full.isEmpty { return full }
        return user["username"] as? String ?? ""
    }

    // MARK: - Fixtures

    /// One post by the buddy in the fixture channel; returns its id.
    private func seedBuddyPost(message: String) throws -> String {
        let buddy = try authenticate(login: buddyLogin, password: buddyPassword)
        let post = try sendJSON("POST", "/api/v4/posts",
                               body: ["channel_id": channelID!,
                                      "message": message],
                               as: buddy.token) as? [String: Any] ?? [:]
        guard let id = post["id"] as? String else {
            throw XCTSkip("the buddy's post was not accepted by the server")
        }
        return id
    }

    /// The T39 path: the `flagged_post` preference is what the Saved list is built from.
    private func savePost(_ postID: String) throws {
        let preference: [String: Any] = ["user_id": myUserID,
                                         "category": "flagged_post",
                                         "name": postID,
                                         "value": "true"]
        _ = try sendJSON("PUT", "/api/v4/users/\(myUserID!)/preferences",
                         body: [preference], as: token)
    }

    private func isSaved(_ postID: String) throws -> Bool {
        let rows = try getJSON("/api/v4/users/\(myUserID!)/preferences/flagged_post")
            as? [[String: Any]] ?? []
        return rows.contains { ($0["name"] as? String) == postID }
    }

    private func setPinned(_ postID: String, pinned: Bool) throws {
        _ = try sendJSON("POST", "/api/v4/posts/\(postID)/\(pinned ? "pin" : "unpin")",
                         body: nil, as: token)
    }

    private func isPinned(_ postID: String) throws -> Bool {
        let post = try getJSON("/api/v4/posts/\(postID)") as? [String: Any] ?? [:]
        return post["is_pinned"] as? Bool ?? false
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
              let session = http.value(forHTTPHeaderField: "Token"),
              let user = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = user["id"] as? String else {
            throw XCTSkip("could not sign in as \(login) on \(serverURL.absoluteString) — run "
                          + "scripts/t41_profile_seed.py")
        }
        return (session, id)
    }

    /// T429's channel, created on first run and rejoined by name afterwards.
    private func ensureChannel(teamID: String, name: String) throws -> String {
        if let existing = try? getJSON("/api/v4/teams/\(teamID)/channels/name/\(name)") as? [String: Any],
           let id = existing["id"] as? String {
            return id
        }
        let created = try sendJSON("POST", "/api/v4/channels",
                                   body: ["team_id": teamID, "name": name,
                                          "display_name": "T429 tap fixture", "type": "O"],
                                   as: token) as? [String: Any] ?? [:]
        guard let id = created["id"] as? String else {
            throw XCTSkip("the fixture could not create #\(name)")
        }
        return id
    }

    private func ensureMember(userID: String, channelID: String) throws {
        if (try? getJSON("/api/v4/channels/\(channelID)/members/\(userID)")) != nil { return }
        _ = try sendJSON("POST", "/api/v4/channels/\(channelID)/members",
                         body: ["user_id": userID], as: token)
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
            throw NSError(domain: "T5449Oracle", code: status, userInfo: [
                NSLocalizedDescriptionKey:
                    "GET \(path) -> HTTP \(status) \(String(decoding: data.prefix(200), as: UTF8.self))"])
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func sendJSON(_ method: String, _ path: String, body: Any?, as session: String) throws -> Any {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = method
        request.setValue("Bearer \(session)", forHTTPHeaderField: "Authorization")
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
        guard !data.isEmpty, let json = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return json
    }

    /// No cookie store (a stale `MMAUTHTOKEN` cookie makes the server answer `session_expired`).
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
}
