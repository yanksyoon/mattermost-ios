// T39 — the two jump/offset behaviours that only a live server can settle, adopted from the T39-AV
// probe so they are a regression in the suite rather than a throwaway script.
//
// Why live: both are statements about a running server's data.
//   1. **A jump to an OLD post** in a channel the app has never opened. The shipped
//      `T39SearchUITests.testSearchRendersTheServersMatchAndOpensItAtThePost` jumps to the channel's
//      *newest* post, which is inside the first page, so `ChannelViewModel.focus` takes its
//      `postsByID` branch and `GET /posts/{id}` is never called (T39-AV F5). This test searches for a
//      post that is far outside the newest page, taps it from a cold launch, and asserts the row the
//      app landed on is that exact post — and that the list draws the gap separator for the messages
//      it did not load (T39-AV F2).
//   2. **`time_zone_offset` is seconds.** The field is seconds east of UTC (`GetStartOfDayMillis` ->
//      Go's `time.FixedZone(name, offset)`; both reference clients send `utcOffset() * 60`). T39
//      shipped minutes, which made `on:` mean the UTC day: `in:t34-showcase on:2026-10-26` answered 3
//      posts where the web client answered 1 (T39-AV F1). The oracle here is the server asked both
//      ways, compared with the count the screen shows — on `#t39-anchor`, whose posts carry a fixed
//      `create_at` so the anchor day is a fixture property and not the wall clock
//      (`scripts/t39_offset_anchor_seed.py`, T39-R2).
//
// Run (local throwaway server; credentials come from the environment, never from this file):
//
//     python3 scripts/t39_offset_anchor_seed.py --url http://127.0.0.1:8065   # once per fixture
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     python3 scripts/qa-test.py --platform ios --sim <sim> \
//       --only-testing MattermostUITests/T39JumpUITests
//
// Each test skips (never fails) when the environment, the server or the fixture is missing, like every
// live test here.

import XCTest

final class T39JumpUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var teamID: String!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live jump test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        try ping()
        let session = try authenticate(login: loginID, password: password)
        token = session.token
        teamID = try fixtureTeamID()
    }

    // MARK: - 1. Jump to an old post in a channel never opened

    /// The fetch-by-id path, end to end: cold launch, search, tap a result whose post is the 140th
    /// newest in its channel (so it is not in the first page the pane loads), and assert the pane
    /// landed on **that** post with the messages it skipped marked.
    func testJumpToAnOldResultInAChannelNeverOpenedFetchesByIDAndMarksTheGap() throws {
        // The fixture, measured on this server before the test was written (scripts/t36_thread_seed.py):
        // "t36 follow fixture 1792995059" is the 140th-newest post of #t36-threads.
        let target = "hsafgioz4td98gijwugs631qny"
        let query = "1792995059"
        let targetText = "t36 follow fixture 1792995059"

        // The oracle: the server still answers this query with the target post, and the target is not
        // in the channel's newest page (which is what makes the fetch path necessary).
        let ids = try searchIDs(terms: query)
        guard ids.contains(target) else {
            throw XCTSkip("the server no longer answers \(query) with \(target): \(ids)")
        }
        let newestPage = try newestPageIDs(inChannelNamed: "t36-threads")
        XCTAssertFalse(newestPage.contains(target),
                       "the premise: \(target) must be outside the newest page, otherwise the pane's "
                       + "postsByID branch answers and the fetch-by-id path is not exercised")

        let app = launchApp()
        openSearch(app)
        type(query, into: "searchField", in: app)
        tap("searchSubmit", in: app)

        let row = revealResult(app, postID: target)
        XCTAssertTrue(row.waitForExistence(timeout: 40),
                      "the old post must be listed:\n\(app.debugDescription)")
        attach(app, "t39jump-1-results")
        row.tap()

        let focus = element(app, "postFocus.\(target)")
        XCTAssertTrue(focus.waitForExistence(timeout: 60),
                      "the jump must mark the EXACT post \(target), not just open its channel:\n"
                      + app.debugDescription)
        let targetRow = element(app, "post.\(target)")
        XCTAssertTrue(targetRow.exists, "the focused row must be laid out:\n\(app.debugDescription)")

        // Not a plain "open the channel at its newest message": the newest row must not be in the
        // visible list.
        //
        // Both halves of this check are read from the server at run time, and both had to change:
        //  * the id is `newestPage.first`, not a constant. The constant this test carried
        //    (`b4rnbrmcsffe8mshqxf17wktrr`) was the newest when T39 was written and is now #56 of the
        //    newest page ("t37 picker target 1793005481") — later suite runs posted into
        //    #t36-threads — so the pane legitimately draws it just past the gap and the old
        //    `!exists` form went red on a correct pane (measured 2026-10-27: `probe_newest.py`,
        //    build/logs/t39r2/t39r2-jump-diag4.log, screenshot `t39jump-2-focused`);
        //  * "visible" is "inside `channelPostList`'s frame", not "in the accessibility tree": the
        //    pane holds the whole newest page below the gap separator, so rows that are drawn or
        //    merely realized are all in the tree. If the pane had opened at the bottom, the newest
        //    row would be inside the list viewport — which is the claim this assertion is for.
        let trueNewest = try XCTUnwrap(newestPage.first,
                                       "the channel's newest page must not be empty")
        let newestRow = element(app, "post.\(trueNewest)")
        let listFrame = element(app, "channelPostList").frame
        XCTAssertFalse(newestRow.exists && listFrame.contains(newestRow.frame.origin),
                       "the channel's newest post \(trueNewest) must not be visible — if it is, the "
                       + "pane opened at the bottom and the focus came along by luck. "
                       + "newest=\(newestRow.exists ? "\(newestRow.frame)" : "absent"), "
                       + "list=\(listFrame)")
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(window.contains(targetRow.frame.origin),
                      "the focused row must be inside the window, frame=\(targetRow.frame) "
                      + "window=\(window)")
        // The row's own label is the message text (it is one accessibility element).
        let text = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", targetText)).firstMatch
        XCTAssertTrue(text.exists,
                      "the focused row must draw the server's message \(targetText):\n"
                      + app.debugDescription)
        attach(app, "t39jump-2-focused")

        // T39-AV F2: the messages between this post and the newest page were never loaded, so the list
        // must say so instead of drawing the two blocks as neighbours.
        let gap = revealGap(app)
        XCTAssertTrue(gap.exists,
                      "a jumped-to old post must be followed by the 'not loaded' separator:\n"
                      + app.debugDescription)
        XCTAssertTrue(gap.label.contains("Jumped to an older message") || gap.label.contains("not loaded"),
                      "the separator must say what it is, got: \(gap.label)")
        attach(app, "t39jump-3-gap")
    }

    // MARK: - 2. time_zone_offset is sent in seconds

    /// The anchor is a property of the **fixture**, not of the wall clock:
    /// `scripts/t39_offset_anchor_seed.py` writes three posts into `#t39-anchor` on `offsetAnchorDay`
    /// with an explicit `create_at` (the server honours it for a `system_admin` account), placed
    /// inside the reader's local day and outside the day a client sending `offset / 60` would ask
    /// for. The original test anchored on the *newest* post's day, and as the fixture grew that day
    /// stopped separating the two encodings — measured `in:t34-showcase on:2026-10-27` answering 2
    /// posts both ways (T55-AV-R §3.4 F-5) — so the test skipped on its own premise and a green run
    /// could mean nothing at all. The day is written into the posts' own `create_at`, so it does not
    /// move; change these two constants together with the seed script.
    private let offsetAnchorChannel = "t39-anchor"
    private let offsetAnchorDay = "2026-10-26"

    /// The screen's own result count is compared with the server asked twice: once with the offset in
    /// **seconds** (what the client must send) and once in minutes (what T39 shipped). The fixture
    /// makes those two answers differ, so the test fails if the unit ever regresses — and it cannot
    /// reach green without measuring.
    func testOnDateModifierSendsTheTimezoneOffsetInSeconds() throws {
        let secondsOffset = TimeZone.current.secondsFromGMT()
        // An offset that is a whole number of hours and not UTC is the case where the two encodings
        // disagree about the day; in UTC they agree and the test could not tell them apart.
        try XCTSkipUnless(secondsOffset != 0 && secondsOffset % 3600 == 0,
                          "this host's offset \(secondsOffset)s cannot separate seconds from "
                          + "minutes — run in a non-UTC time zone")
        let minutesOffset = secondsOffset / 60

        _ = try channelID(named: offsetAnchorChannel)
        let terms = "in:\(offsetAnchorChannel) on:\(offsetAnchorDay)"
        let secondsCount = try searchIDs(terms: terms, timeZoneOffsetSeconds: secondsOffset).count
        let minuteCount = try searchIDs(terms: terms, timeZoneOffsetSeconds: minutesOffset).count
        try XCTSkipUnless(secondsCount != minuteCount,
                          "the fixture does not separate the two offsets for \(terms) "
                          + "(seconds \(secondsCount), minutes \(minuteCount)) — re-run "
                          + "scripts/t39_offset_anchor_seed.py --tz-offset-seconds \(secondsOffset) "
                          + "against this server; this is a fixture gap, not a measurement")

        let app = launchApp()
        openSearch(app)
        type(terms, into: "searchField", in: app)
        tap("searchSubmit", in: app)

        let summary = element(app, "searchSummary")
        XCTAssertTrue(summary.waitForExistence(timeout: 40), "no summary:\n\(app.debugDescription)")
        let label = summary.label
        let shown = Int(label.prefix(while: { $0.isNumber })) ?? -1
        attach(app, "t39jump-4-ondate")
        XCTAssertEqual(shown, secondsCount,
                       "the screen shows \(shown) results for \(terms); a client sending the offset "
                       + "in SECONDS reads \(secondsCount) (the reader's day), one sending minutes "
                       + "reads \(minuteCount) (the UTC day). Summary: \(label)")
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

    private func signIn(_ app: XCUIApplication) {
        let field = app.textFields["loginIDField"]
        XCTAssertTrue(field.waitForExistence(timeout: 30),
                      "the native sign-in must mount against \(serverURL.absoluteString):\n"
                      + app.debugDescription)
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

    /// The regular layout reaches search from the detail toolbar, the compact layout from a tab.
    ///
    /// The compact shell **pushes** a channel over the tab bar: `LaunchDestination` opens the team's
    /// town hall as soon as the channel directory arrives, and `RootView`'s navigation stack is above
    /// the `TabView`, so the pushed pane covers it (measured 2026-10-27 —
    /// `build/logs/t39r2/t39r2-live-a.log`: a launch that pushed Town Square before the first tap had
    /// neither `shellSearchButton` nor a `TabBar`). Coming back from the pane is what a reader does,
    /// and the entry points stay the two the product offers.
    private func openSearch(_ app: XCUIApplication) {
        let toolbarButton = element(app, "shellSearchButton")
        if toolbarButton.waitForExistence(timeout: 20) {
            toolbarButton.tap()
        } else {
            let tab = app.tabBars.buttons["Search"]
            if !tab.waitForExistence(timeout: 5) {
                returnToSidebar(app)
            }
            XCTAssertTrue(tab.waitForExistence(timeout: 20),
                          "neither the toolbar nor a tab opens search:\n\(app.debugDescription)")
            tab.tap()
            if !element(app, "searchField").waitForExistence(timeout: 20) {
                // The pane pushed again while the tab was being selected: pop and retry once.
                returnToSidebar(app)
                XCTAssertTrue(tab.waitForExistence(timeout: 20),
                              "the tab must come back with the sidebar:\n\(app.debugDescription)")
                tab.tap()
            }
        }
        XCTAssertTrue(element(app, "searchField").waitForExistence(timeout: 30),
                      "the search screen must mount:\n\(app.debugDescription)")
    }

    /// Pop a channel the compact shell pushed over the tab bar, back to the sidebar.
    private func returnToSidebar(_ app: XCUIApplication, maxPops: Int = 3) {
        let back = app.navigationBars.buttons["Back"]
        var pops = 0
        while back.exists, pops < maxPops {
            back.tap()
            pops += 1
            _ = back.waitForExistence(timeout: 2)
        }
    }

    private func type(_ text: String, into identifier: String, in app: XCUIApplication) {
        let field = element(app, identifier)
        XCTAssertTrue(field.waitForExistence(timeout: 20), "\(identifier) must exist")
        field.tap()
        field.typeText(text)
    }

    /// Tap an element only once it exists.
    ///
    /// A bare `.tap()` on a query the app has not snapshotted yet fails as "No matches found", which
    /// on a loaded host reds a correct screen: measured on 2026-10-27, `testAMalformedQuery…` (the
    /// sibling suite) reded with `Failed to tap "searchSubmit" … No matches found` in a batch run and
    /// passed alone in 61 s (`build/logs/t39r2/t39r2-live-f-rebased.log`,
    /// `t39r2-malformed-alone.log`).
    private func tap(_ identifier: String, in app: XCUIApplication) {
        let target = element(app, identifier)
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

    /// The gap separator sits just below the jumped-to post in the newest page's direction. A lazy
    /// stack may not have built it yet, so a couple of short swipes are allowed before asserting.
    private func revealGap(_ app: XCUIApplication, maxSwipes: Int = 3) -> XCUIElement {
        let gap = element(app, "channelListGap")
        var swipes = 0
        while !gap.exists, swipes < maxSwipes {
            app.swipeUp(velocity: .slow)
            swipes += 1
        }
        return gap
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
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

    /// The team the fixtures live in (`perf`, as `scripts/perf_seed.py` creates it), else the account's
    /// first team.
    private func fixtureTeamID() throws -> String {
        let teams = try getJSON("/api/v4/users/me/teams") as? [[String: Any]] ?? []
        if let perf = teams.first(where: { ($0["name"] as? String) == "perf" }),
           let id = perf["id"] as? String {
            return id
        }
        guard let id = teams.first?["id"] as? String else {
            throw XCTSkip("the fixture account has no team")
        }
        return id
    }

    private func channelID(named name: String) throws -> String {
        let row = try getJSON("/api/v4/teams/\(teamID!)/channels/name/\(name)") as? [String: Any]
        guard let row, let id = row["id"] as? String else {
            throw XCTSkip("channel #\(name) is missing — run scripts/t36_thread_seed.py / "
                          + "scripts/t34_post_seed.py / scripts/t39_offset_anchor_seed.py")
        }
        return id
    }

    /// The ids of the channel's newest page, read the way the app reads it
    /// (`collapsedThreads=true`, `per_page=60`).
    private func newestPageIDs(inChannelNamed name: String) throws -> [String] {
        let channelID = try channelID(named: name)
        var components = URLComponents(url: serverURL.appendingPathComponent(
            "api/v4/channels/\(channelID)/posts"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "per_page", value: "60"),
                                  URLQueryItem(name: "collapsedThreads", value: "true")]
        let url = try XCTUnwrap(components?.url)
        let page = try getJSON(url: url) as? [String: Any] ?? [:]
        return (page["order"] as? [String] ?? [])
    }

    /// The server's ids for a query, with the offset in **seconds** (the field's real unit).
    private func searchIDs(terms: String, timeZoneOffsetSeconds: Int = 0) throws -> [String] {
        let body: [String: Any] = ["terms": terms,
                                   "is_or_search": false,
                                   "time_zone_offset": timeZoneOffsetSeconds,
                                   "page": 0,
                                   "per_page": 60,
                                   "include_deleted_channels": true]
        let json = try postJSON("/api/v4/teams/\(teamID!)/posts/search", body: body)
        let page = json as? [String: Any] ?? [:]
        return page["order"] as? [String] ?? []
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
        var request = URLRequest(url: serverURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try synchronous(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw XCTSkip("POST \(path) answered \(status) — the fixture is not in the state this "
                          + "test needs")
        }
        guard !data.isEmpty, let json = try? JSONSerialization.jsonObject(with: data) else {
            return [:]
        }
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
        var payload: Data?
        var response: URLResponse?
        var failure: Error?
        let semaphore = DispatchSemaphore(value: 0)
        Self.restSession.dataTask(with: request) { data, urlResponse, error in
            payload = data
            response = urlResponse
            failure = error
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 25)
        if let failure { throw failure }
        guard let payload, let response else {
            throw XCTSkip("the server did not answer \(request.url?.absoluteString ?? "?")")
        }
        return (payload, response)
    }
}
