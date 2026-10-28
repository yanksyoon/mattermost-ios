// T39 — the search, saved and pinned screens against a **real** Mattermost server.
//
// Why live: the card's acceptance criteria are statements about a running server's data —
//   1. a query reaches `POST /teams/{id}/posts/search` and its matches render in the result list;
//   2. a malformed query is explained instead of silently answering an empty list;
//   3. a result opens the message it names (the channel pane lands on that post);
//   4. unsaving/unpinning from the list removes the row and the change is on the server.
// A stub could only prove this file's own fixtures render. The oracle for every assertion below is
// the server, read back through its own API with the same account the app signs in as.
//
// Run (local throwaway server; credentials as for T34):
//
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     python3 scripts/qa-test.py --platform ios --sim <sim> \
//       --only-testing MattermostUITests/T39SearchUITests
//
// Each test skips (never fails) when the environment or the server is missing, like every live test
// here. Nothing is fabricated: a skipped test is reported as skipped.

import XCTest

final class T39SearchUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var userID: String!
    private var teamID: String!

    /// The channel `scripts/t34_post_seed.py` fills with one post per state.
    private let showcaseChannelName = "t34-showcase"

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live search test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
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

    // MARK: - 1. A query reaches the server's search and its matches render

    func testSearchRendersTheServersMatchAndOpensItAtThePost() throws {
        let channel = try channel(named: showcaseChannelName)
        let newest = try newestPost(inChannel: channel.id)
        let postID = try XCTUnwrap(newest["id"] as? String)
        let terms = try searchableWord(in: try XCTUnwrap(newest["message"] as? String))

        // The oracle: the server, asked the way the app asks, holds this post for this term.
        let serverHit = try search(terms: terms).first { $0["id"] as? String == postID }
        XCTAssertNotNil(serverHit,
                        "the fixture's newest post must be findable by \(terms) — the test's premise")

        let app = launchApp()
        openSearch(app)
        type(terms, into: "searchField", in: app)
        tap("searchSubmit", in: app)

        let row = revealResult(app, postID: postID)
        XCTAssertTrue(row.waitForExistence(timeout: 40),
                      "the result list must draw the server's match \(postID) for \(terms):\n"
                      + "\(app.debugDescription)")
        XCTAssertTrue(element(app, "searchSummary").waitForExistence(timeout: 10),
                      "a result set must say how many matches it holds")

        // The body is the server's message — proof the row is not a placeholder. The row is one
        // accessibility element (it is a button, so SwiftUI combines its children), so the text is
        // read from the row's own label rather than from a child identifier.
        let message = ((newest["message"] as? String) ?? "").lowercased()
        let term = terms.lowercased()
        XCTAssertTrue(message.contains(term))
        XCTAssertTrue(row.label.lowercased().contains(term),
                      "the result must draw the server's message text, got label: "
                      + "\u{201C}\(row.label)\u{201D}")
        attach(app, "t39-1-search-results")

        // Tapping a result opens the channel it lives in, landed on that post.
        row.tap()
        XCTAssertTrue(element(app, "postFocus.\(postID)").waitForExistence(timeout: 60),
                      "a result must open its message, not just its channel:\n\(app.debugDescription)")
        attach(app, "t39-2-focus-on-post")
    }

    // MARK: - 2. A malformed query is explained, never answered with an empty list

    func testAMalformedQueryExplainsItselfInsteadOfShowingAnEmptyList() throws {
        let app = launchApp()
        openSearch(app)
        type("before:notadate", into: "searchField", in: app)
        tap("searchSubmit", in: app)

        let banner = element(app, "searchValidationError")
        XCTAssertTrue(banner.waitForExistence(timeout: 20),
                      "an unsendable query must say why:\n\(app.debugDescription)")
        XCTAssertTrue((banner.label).contains("YYYY-MM-DD"),
                      "the sentence must name the format it wants, got: \(banner.label)")
        XCTAssertFalse(element(app, "searchResults").exists,
                       "a malformed query must not draw a result list")
        XCTAssertFalse(element(app, "searchEmpty").exists,
                       "and it must never be presented as \"nothing matched\"")
        attach(app, "t39-3-invalid-query")
    }

    // MARK: - 3. Unsaving from the Saved list removes the row, on the server too

    func testUnsaveFromTheSavedTabRemovesTheRowAndThePreference() throws {
        let channel = try channel(named: showcaseChannelName)
        let newest = try newestPost(inChannel: channel.id)
        let postID = try XCTUnwrap(newest["id"] as? String)
        try savePost(postID)
        XCTAssertTrue(try isSaved(postID), "the premise: the post is saved before the app starts")

        let app = launchApp()
        openSaved(app)
        let row = revealRow(app, identifier: "savedPosts.row.\(postID)", in: "savedPosts")
        XCTAssertTrue(row.waitForExistence(timeout: 60),
                      "the Saved list must draw the server's flagged post:\n\(app.debugDescription)")
        attach(app, "t39-4-saved-list")

        element(app, "savedPosts.remove.\(postID)").tap()
        XCTAssertTrue(waitUntil(timeout: 30) { !row.exists },
                      "unsaving must remove the row in place:\n\(app.debugDescription)")
        XCTAssertTrue(waitUntil(timeout: 20) { (try? self.isSaved(postID)) == false },
                      "the unsave must reach the server, not just the screen")
        attach(app, "t39-5-saved-after-unsave")
    }

    // MARK: - 4. Unpinning from the pinned sheet removes the row, on the server too

    func testUnpinFromThePinnedSheetRemovesTheRowAndThePin() throws {
        let channel = try channel(named: showcaseChannelName)
        let newest = try newestPost(inChannel: channel.id)
        let postID = try XCTUnwrap(newest["id"] as? String)
        try setPinned(postID, pinned: true)
        XCTAssertEqual(try isPinned(postID), true, "the premise: the post is pinned")

        let app = try launchAndOpenChannel(named: showcaseChannelName)
        let pinButton = element(app, "nativeChannelPinnedButton")
        XCTAssertTrue(pinButton.waitForExistence(timeout: 60),
                      "the channel header must offer its pinned messages:\n\(app.debugDescription)")
        pinButton.tap()

        let row = element(app, "pinnedPosts.row.\(postID)")
        XCTAssertTrue(row.waitForExistence(timeout: 40),
                      "the sheet must draw the server's pinned post:\n\(app.debugDescription)")
        attach(app, "t39-6-pinned-sheet")

        element(app, "pinnedPosts.remove.\(postID)").tap()
        XCTAssertTrue(waitUntil(timeout: 30) { !row.exists },
                      "unpinning must remove the row in place:\n\(app.debugDescription)")
        XCTAssertEqual(try isPinned(postID), false,
                       "the unpin must reach the server, not just the screen")
        attach(app, "t39-7-pinned-after-unpin")
    }

    // MARK: - Launch

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetPersistedState",
                               "-uiTestForgetSession", serverURL.absoluteString,
                               "-uiTestSeedServer", serverURL.absoluteString,
                               "-uiTestSeedServerName", "Local Mattermost",
                               "-surfaceMode", "shell=native",
                               "-surfaceMode", "auth=native",
                               "-surfaceMode", "sidebar=native",
                               "-surfaceMode", "search=native",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        signIn(app)
        return app
    }

    /// The channel open, the way a person does it: pick the team on the rail, then the channel row.
    ///
    /// The sidebar is sorted by activity, so a channel that has been quiet can sit below the fold of
    /// a `List` that only builds what is on screen — the row is revealed by scrolling, then tapped.
    private func launchAndOpenChannel(named name: String) throws -> XCUIApplication {
        let app = launchApp()
        let channel = try channel(named: name)

        let teamRow = element(app, "teamSidebar.team.\(teamID!)")
        if !teamRow.waitForExistence(timeout: 10) {
            // The compact shell may have pushed a channel over the sidebar (see `openSearch`).
            returnToSidebar(app)
        }
        XCTAssertTrue(teamRow.waitForExistence(timeout: 40),
                      "the rail must list the team this test seeds:\n\(app.debugDescription)")
        if !(teamRow.value as? String ?? "").contains("Selected") {
            teamRow.tap()
        }

        let row = revealSidebarRow(app, identifier: "channelSidebar.channel.\(channel.id)")
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "the sidebar must list #\(name):\n\(app.debugDescription)")
        row.tap()
        return app
    }

    /// Scroll the channel list until `identifier` exists (a lazy list builds only its viewport).
    @discardableResult
    private func revealSidebarRow(_ app: XCUIApplication, identifier: String,
                                  maxSwipes: Int = 20) -> XCUIElement {
        let target = element(app, identifier)
        guard !target.exists else { return target }
        // The row may be above the viewport as well as below it: come back to the top first.
        // T8f: the channel list is a `ScrollView` + `LazyVStack` now, and `ShellSettle` names its
        // scroll view (it used to be `app.collectionViews.firstMatch`, the `List`'s collection).
        let list = ShellSettle.channelSidebarScroll(app)
        var swipes = 0
        while !target.exists, swipes < maxSwipes {
            list.swipeUp(velocity: .fast)
            swipes += 1
        }
        return target
    }

    private func signIn(_ app: XCUIApplication) {
        let field = app.textFields["loginIDField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20),
                      "the native sign-in must mount against \(serverURL.absoluteString):\n"
                      + "\(app.debugDescription)")
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

    /// Open the search screen. The regular (Pad/desktop) layout reaches it from the detail column's
    /// toolbar; the compact layout has it as a tab. Either entry point must land on the same screen.
    ///
    /// The compact shell **pushes** a channel above the tabs whenever the launch restored one — and
    /// the launch restores the last channel **only** (`LaunchDestination`, after T95-A: no town-hall
    /// fallback), so a launch with nothing saved lands on the channel list with its tab bar and a
    /// launch that restored a channel shows a pushed pane with `Back`. `RootView`'s navigation stack
    /// sits above the `TabView`, so the pushed pane covers the bar; that is upstream's own shape
    /// (`Stack` above `Tabs`; the Mobile v2 design slides the bar away in a channel), not a defect —
    /// `docs/t95-shell-tab-bar-decision.md` §2. `ShellSettle.tapTab` is that reader's route: pop the
    /// pane with `Back`, then tap the tab. It is the one helper every suite uses (T95-B).
    private func openSearch(_ app: XCUIApplication) {
        if !ShellSettle.tapTab(ShellSettle.Tab.search, in: app, wait: 20) {
            let toolbarButton = element(app, "shellSearchButton")
            XCTAssertTrue(toolbarButton.waitForExistence(timeout: 20),
                          "neither the toolbar nor a tab opens search:\n\(app.debugDescription)")
            toolbarButton.tap()
        }
        XCTAssertTrue(element(app, "searchField").waitForExistence(timeout: 30),
                      "the search screen must mount:\n\(app.debugDescription)")
    }

    /// Pop a channel the compact shell pushed over the tab bar, back to the channel list.
    ///
    /// One implementation for every suite: `ShellSettle.revealTabs` (T95-B). Kept as a named local
    /// because the call sites above read as "return to the sidebar", which is what a reader does.
    private func returnToSidebar(_ app: XCUIApplication, maxPops: Int = 3) {
        ShellSettle.revealTabs(app, maxPops: maxPops)
    }

    /// The Saved screen. The compact layout reaches it from a tab (after `Back`, when a channel is
    /// pushed over the bar — `ShellSettle.tapTab`); the regular layout from the detail toolbar.
    private func openSaved(_ app: XCUIApplication) {
        if !ShellSettle.tapTab(ShellSettle.Tab.saved, in: app, wait: 20) {
            let toolbarButton = element(app, "shellSavedButton")
            XCTAssertTrue(toolbarButton.waitForExistence(timeout: 20),
                          "neither the toolbar nor a tab opens saved messages:\n"
                          + "\(app.debugDescription)")
            toolbarButton.tap()
        }
        XCTAssertTrue(element(app, "nativeSavedPane").waitForExistence(timeout: 30),
                      "the saved screen must mount:\n\(app.debugDescription)")
    }

    private func type(_ text: String, into identifier: String, in app: XCUIApplication) {
        let field = knownType(app, identifier)
        XCTAssertTrue(field.waitForExistence(timeout: 20), "\(identifier) must exist")
        field.tap()
        field.typeText(text)
    }

    /// The identifiers this suite touches most often, looked up **by type** where the type is known.
    ///
    /// Why: XCUITest's accessibility serialiser runs inside the app process and logs every element
    /// it visits, so a `descendants(matching: .any)` identifier query on the drawn shell costs
    /// ~1 MB of app log while a type-scoped one costs ~0.05–0.35 MB. Enough of that in a short
    /// window quarantine the process's firehose buffer and the next snapshot taken then crashes the
    /// app in XCTest's fault callback (`docs/t8d-build-note.md` §1/§2). The types below are not
    /// guesses — they were read off the tree in `t8d-base-A`'s exported diagnostics
    /// (`searchField` → `TextField`, `searchSubmit` → `Button`, `searchSummary` → `StaticText`).
    private func knownType(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        switch identifier {
        case "searchField": return app.textFields[identifier]
        case "searchSubmit": return app.buttons[identifier]
        default: return element(app, identifier)
        }
    }

    /// Tap an element only once it exists.
    ///
    /// A bare `.tap()` on a query the app has not snapshotted yet fails as "No matches found", which
    /// on a loaded host reds a correct screen: measured on 2026-10-27, `testAMalformedQuery…` reded with
    /// `Failed to tap "searchSubmit" … No matches found` in a batch run and passed alone in 61 s
    /// (`build/logs/t39r2/t39r2-live-f-rebased.log`, `t39r2-malformed-alone.log`).
    private func tap(_ identifier: String, in app: XCUIApplication) {
        let target = knownType(app, identifier)
        XCTAssertTrue(target.waitForExistence(timeout: 20), "\(identifier) must exist:\n\(app.debugDescription)")
        target.tap()
    }

    /// A result may be below the fold of a lazy list: swipe until it exists.
    @discardableResult
    private func revealResult(_ app: XCUIApplication, postID: String,
                              maxSwipes: Int = 12) -> XCUIElement {
        let target = element(app, "searchResult.\(postID)")
        guard !target.exists else { return target }
        let list = element(app, "searchResults")
        var swipes = 0
        while !target.exists, swipes < maxSwipes {
            list.swipeUp(velocity: .fast)
            swipes += 1
        }
        return target
    }

    @discardableResult
    private func revealRow(_ app: XCUIApplication, identifier: String,
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

    // MARK: - Server access (the test is its own API client)

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
            // The status and the body are part of the message on purpose: a skip that cannot say why
            // cost T55-AV-R three runs before the 401 was visible.
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw XCTSkip("could not sign in as \(login) on the live server (status \(code) \(body))")
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

    private struct Channel {
        let id: String
        let name: String
        let displayName: String
    }

    private func channel(named name: String) throws -> Channel {
        let row = try getJSON("/api/v4/teams/\(teamID!)/channels/name/\(name)") as? [String: Any]
        guard let row, let id = row["id"] as? String else {
            throw XCTSkip("channel #\(name) is missing — run scripts/t34_post_seed.py")
        }
        return Channel(id: id, name: row["name"] as? String ?? name,
                       displayName: row["display_name"] as? String ?? name)
    }

    /// The channel's newest post, read the way the app reads it (`collapsedThreads=true`).
    private func newestPost(inChannel channelID: String) throws -> [String: Any] {
        var components = URLComponents(url: serverURL.appendingPathComponent(
            "api/v4/channels/\(channelID)/posts"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "per_page", value: "10"),
                                  URLQueryItem(name: "collapsedThreads", value: "true")]
        let url = try XCTUnwrap(components?.url)
        let page = try getJSON(url: url) as? [String: Any] ?? [:]
        let order = page["order"] as? [String] ?? []
        let posts = page["posts"] as? [String: Any] ?? [:]
        guard let first = order.first, let post = posts[first] as? [String: Any] else {
            throw XCTSkip("channel has no posts — run scripts/t34_post_seed.py")
        }
        return post
    }

    /// A word from a post body that the server's search can find: the longest run of letters.
    private func searchableWord(in message: String) throws -> String {
        let words = message.split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 5 }
        guard let word = words.max(by: { $0.count < $1.count }) else {
            throw XCTSkip("the newest post has no word long enough to search for")
        }
        return word
    }

    private func search(terms: String) throws -> [[String: Any]] {
        let body: [String: Any] = ["terms": terms,
                                   "is_or_search": false,
                                   "time_zone_offset": 0,
                                   "page": 0,
                                   "per_page": 60,
                                   "include_deleted_channels": true]
        let json = try postJSON("/api/v4/teams/\(teamID!)/posts/search", body: body)
        let page = json as? [String: Any] ?? [:]
        let order = page["order"] as? [String] ?? []
        let posts = page["posts"] as? [String: Any] ?? [:]
        return order.compactMap { posts[$0] as? [String: Any] }
    }

    private func savePost(_ postID: String) throws {
        let preference: [String: Any] = ["user_id": userID as String,
                                         "category": "flagged_post",
                                         "name": postID,
                                         "value": "true"]
        _ = try putJSON("/api/v4/users/\(userID!)/preferences", body: [preference])
    }

    private func isSaved(_ postID: String) throws -> Bool {
        let rows = try getJSON("/api/v4/users/\(userID!)/preferences/flagged_post")
            as? [[String: Any]] ?? []
        return rows.contains { ($0["name"] as? String) == postID }
    }

    private func setPinned(_ postID: String, pinned: Bool) throws {
        let verb = pinned ? "pin" : "unpin"
        _ = try postJSON("/api/v4/posts/\(postID)/\(verb)", body: nil)
    }

    private func isPinned(_ postID: String) throws -> Bool {
        let post = try getJSON("/api/v4/posts/\(postID)") as? [String: Any] ?? [:]
        return (post["is_pinned"] as? Bool) ?? false
    }

    // MARK: - HTTP

    private func getJSON(_ path: String) throws -> Any {
        try getJSON(url: serverURL.appendingPathComponent(path))
    }

    private func getJSON(url: URL) throws -> Any {
        var request = URLRequest(url: url)
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

    private func sendJSON(_ method: String, _ path: String, body: Any?) throws -> Any {
        var request = URLRequest(url: serverURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
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

    /// T39-R2: `URLSession.shared` keeps an `MMAUTHTOKEN` cookie from any earlier sign-in of this
    /// runner container, and Mattermost answers a `POST /users/login` that carries a dead session with
    /// 401 `api.context.session_expired.app_error` — measured on 2026-10-27 (T55-AV-R §3.4 F-4), where
    /// every T39 test skipped instead of measuring. T36-R and T40-R already use this session for
    /// exactly this reason (`T40ChannelInfoUITests.swift:954-966`); this is that session.
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
