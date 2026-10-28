// T635-A (card t_7cb5dd3e): a launch that **restores** a channel must paint its newest row.
//
// The defect this file falsifies, as filed by QA (docs/t635-build-note.md §A): a restore launch could
// paint the pane with a header, a `Back`, a working composer and a post list that never materialised a
// single row — 5/5 launches, still blank at 85 s, no spinner, no error, no "No messages yet". Nothing
// in the app distinguished "a pane with rows below the fold" from "a pane whose viewport is in the
// void", so this test reads two things the tree can be wrong about independently:
//
//  1. **rows** — at least one `post.<id>` element after the restore (works on any build, and is what
//     reds on the pre-fix tree: the blank pane keeps `channelPostList` and paints no `post.*` child);
//  2. **position** — with `-uiTestExposeScrollGeometry` (`ScrollGeometrySeam`), the list's own
//     `contentOffset`/`contentSize`/viewport and how many laid-out rows intersect the viewport. The
//     claim is "the newest row is on screen", i.e. a row reaches the viewport's bottom edge — not
//     merely "a row exists somewhere", which the one-row-24-pt-sliver states pass.
//
// Run (throwaway fixture; same env names as the other live suites):
//
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     xcodebuild test -project Mattermost.xcodeproj -scheme Mattermost \
//       -destination 'platform=iOS Simulator,id=81AD82E4-...' \
//       -only-testing:MattermostUITests/T635RestoredPaneUITests
//
// Every test skips (never fails) when the environment or the fixture is missing.

import XCTest

final class T635RestoredPaneUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var teamID: String!
    private var channelID: String!
    private var channelDisplayName = ""
    private let channelName = "t36-threads"

    /// A relaunch after `terminate()` took 60-160 s to reach a usable surface on a loaded host
    /// (T55-AV-R F-1, card t_1f9af95a), so the landing budget is generous and re-armed rather than
    /// spent on one element. The *product* claim below has its own, smaller budget.
    private let landingTimeout: TimeInterval = 240
    /// How long the restored pane may take to paint its first row. The defect was measured still blank
    /// at 85 s; the fix paints rows in <1 s (measured 5/5 through `simctl` alone). 45 s is a
    /// load-tolerant multiple of the observed paint, not a budget for a slow host.
    private let paintTimeout: TimeInterval = 45

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live restore test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        try ping()
        let session = try authenticate(login: loginID, password: password)
        token = session.token
        guard let team = try teamsForMe().first(where: { $0["name"] as? String == "perf" }) else {
            throw XCTSkip("team #perf is missing — run scripts/perf_seed.py")
        }
        teamID = team["id"] as? String
        guard let channel = try channel(named: channelName, in: teamID) else {
            throw XCTSkip("channel #\(channelName) is missing — run scripts/t36_thread_seed.py")
        }
        channelID = try XCTUnwrap(channel["id"] as? String)
        channelDisplayName = channel["display_name"] as? String ?? ""
    }

    // MARK: - 1. The restore lands on the newest row

    /// The card's acceptance criterion: after a launch that restores the saved channel, the pane shows
    /// its rows **without any touch input**. Fails on the pre-fix tree (no `post.*` element for 45 s),
    /// and additionally asserts the geometry claim when the seam is present.
    func testARestoredChannelPaneShowsItsNewestRow() throws {
        let app = try signedInWithChannelOpen()
        app.terminate()

        let relaunched = restoreLaunch()
        let restored = try waitForRestoredPane(relaunched)
        XCTAssertTrue(restored, "the launch must restore the channel it was left in — nothing else is "
                      + "being tested here (card rule: a pass from a launch that restored nothing does "
                      + "not count)")

        let painted = waitForPaintedRow(relaunched, timeout: paintTimeout)
        attach(relaunched, "t635-restored-pane")
        XCTAssertTrue(painted,
                      "a restored channel pane must paint at least one post row within "
                      + "\(Int(paintTimeout)) s (defect t_7cb5dd3e: the pane painted none for 85 s). "
                      + "Last geometry: \(geometryReport(relaunched)). "
                      + "Tree:\n\(relaunched.debugDescription)")

        // The stronger claim, when the seam is compiled in: a row reaches the bottom of the viewport,
        // i.e. the pane is positioned at its newest message and not merely "holding a row somewhere".
        guard let reading = readGeometry(relaunched) else {
            XCTFail("`-uiTestExposeScrollGeometry` must publish `channelPostList.scrollGeometry` on the "
                    + "restored pane:\n\(relaunched.debugDescription)")
            return
        }
        XCTAssertGreaterThan(reading.items, 0, "the restored window must not be empty: \(reading)")
        XCTAssertGreaterThan(reading.visibleRows, 0,
                             "at least one laid-out row must intersect the viewport: \(reading)")
        XCTAssertTrue(reading.bottomRowOnScreen,
                      "the pane must open on its newest row — the lowest row must reach the "
                      + "viewport's bottom edge: \(reading)")
    }

    // MARK: - 2. Re-opening the channel from the sidebar

    /// Answers the card's fourth criterion: **does re-opening the channel from the sidebar repair a
    /// blank restored pane?**
    ///
    /// Written as a product claim that holds either way — after `Back` and a tap on the channel row the
    /// timeline must hold rows — so it is a meaningful assertion on both the pre-fix and the fixed
    /// tree; the attachment records whether the *restored* pane was already legible, which is the
    /// answer to the question rather than an assumption about it.
    func testReopeningTheChannelFromTheSidebarPaintsTheTimeline() throws {
        let app = try signedInWithChannelOpen()
        app.terminate()

        let relaunched = restoreLaunch()
        _ = try waitForRestoredPane(relaunched)
        let restoredHadRows = waitForPaintedRow(relaunched, timeout: 20)
        let restoredReading = geometryReport(relaunched)
        let note = "restored pane painted rows: \(restoredHadRows); geometry: \(restoredReading)"
        attach(relaunched, "t635-before-reopen")

        // The reader's route back to a channel: Back (the restored pane is pushed over the sidebar),
        // then the channel's own row.
        let back = relaunched.navigationBars.buttons["Back"]
        if back.waitForExistence(timeout: 30), back.isHittable {
            back.tap()
        }
        let row = element(relaunched, "channelSidebar.channel.\(channelID!)")
        if !row.waitForExistence(timeout: 30) {
            let team = element(relaunched, "teamSidebar.team.\(teamID!)")
            if team.waitForExistence(timeout: 10) { team.tap() }
        }
        XCTAssertTrue(element(relaunched, "channelSidebar.channel.\(channelID!)").waitForExistence(timeout: 45),
                      "the sidebar must list the fixture channel after Back:\n\(relaunched.debugDescription)")
        element(relaunched, "channelSidebar.channel.\(channelID!)").tap()
        XCTAssertTrue(element(relaunched, "channelPostList").waitForExistence(timeout: 45),
                      "re-opening the channel must mount its post list")

        let painted = waitForPaintedRow(relaunched, timeout: 45)
        attach(relaunched, "t635-after-reopen")
        let afterReading = geometryReport(relaunched)
        XCTAssertTrue(painted,
                      "a channel opened by tapping it from the sidebar must paint rows — this is the "
                      + "reader's repair route, so it must work on every build. "
                      + "Before the reopen: \(note). After: \(afterReading). Tree:\n"
                      + "\(relaunched.debugDescription)")

        let answer = XCTAttachment(string: "T635 criterion 4 — " + note
                                   + "; after Back + row tap, rows painted: \(painted); geometry: "
                                   + afterReading)
        answer.name = "t635-reopen-answer"
        answer.lifetime = .keepAlways
        add(answer)
    }

    // MARK: - App driving

    /// Sign in to a **fresh** shell (persisted state reset) and open the fixture channel by tapping it,
    /// which is also what saves it as the last channel the next launch restores.
    private func signedInWithChannelOpen() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = launchArguments(resetState: true, forgetSession: true,
                                              exposeGeometry: false)
        app.launch()
        let field = app.textFields["loginIDField"]
        XCTAssertTrue(field.waitForExistence(timeout: 45),
                      "the native sign-in must mount against \(serverURL.absoluteString):\n"
                      + "\(app.debugDescription)")
        field.tap()
        field.typeText(loginID)
        let secret = app.secureTextFields["loginPasswordField"]
        XCTAssertTrue(secret.exists)
        secret.tap()
        secret.typeText(password)
        app.buttons["loginSubmitButton"].tap()
        XCTAssertTrue(element(app, "nativeShell").waitForExistence(timeout: 90),
                      "signing in must reach the shell (`nativeShell`):\n\(app.debugDescription)")

        var row = element(app, "channelSidebar.channel.\(channelID!)")
        if !row.waitForExistence(timeout: 30) {
            let team = element(app, "teamSidebar.team.\(teamID!)")
            if team.waitForExistence(timeout: 15) { team.tap() }
            row = element(app, "channelSidebar.channel.\(channelID!)")
        }
        XCTAssertTrue(row.waitForExistence(timeout: 60),
                      "the sidebar must list channel \(channelID ?? ""):\n\(app.debugDescription)")
        row.tap()
        XCTAssertTrue(element(app, "channelPostList").waitForExistence(timeout: 60),
                      "the channel pane must mount:\n\(app.debugDescription)")
        XCTAssertTrue(waitForPaintedRow(app, timeout: 45),
                      "the channel must be readable *before* the relaunch, or the relaunch proves "
                      + "nothing about restoring it: \(geometryReport(app))")
        return app
    }

    /// The relaunch that is the test: **no** `-uiTestResetPersistedState`, no `-uiTestForgetSession`.
    private func restoreLaunch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = launchArguments(resetState: false, forgetSession: false,
                                              exposeGeometry: true)
        app.launch()
        return app
    }

    private func launchArguments(resetState: Bool, forgetSession: Bool,
                                 exposeGeometry: Bool) -> [String] {
        var args: [String] = ["-uiTestSeedServer", serverURL.absoluteString,
                              "-uiTestSeedServerName", "Local Mattermost"]
        if resetState { args.insert("-uiTestResetPersistedState", at: 0) }
        if forgetSession { args.append(contentsOf: ["-uiTestForgetSession", serverURL.absoluteString]) }
        if exposeGeometry { args.append("-uiTestExposeScrollGeometry") }
        args.append(contentsOf: ["-surfaceMode", "shell=native",
                                 "-surfaceMode", "auth=native",
                                 "-surfaceMode", "sidebar=native",
                                 "-surfaceMode", "composer=native",
                                 "-AppleLanguages", "(en)", "-AppleLocale", "en_US"])
        return args
    }

    /// Wait for the surfaces a relaunch can reach and report whether the **channel pane** is one of
    /// them. A launch that lands on the sign-in screen has restored nothing and must not be read as a
    /// pass (card rule); the caller fails on `false` with that sentence.
    private func waitForRestoredPane(_ app: XCUIApplication) throws -> Bool {
        let deadline = Date().addingTimeInterval(landingTimeout)
        while Date() < deadline {
            if element(app, "nativeChannelPane").exists { return true }
            if app.textFields["loginIDField"].exists { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return element(app, "nativeChannelPane").exists
    }

    /// At least one post row is drawn. `post.<26-char id>` is the row's own identifier
    /// (`PostRowView.swift:245`); the suffix is required so the row's sub-elements
    /// (`post.<id>.menu`, `post.<id>.reaction.x`) are not mistaken for a row.
    private func waitForPaintedRow(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if paintedRows(app).firstMatch.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return paintedRows(app).firstMatch.exists
    }

    private func paintedRows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier MATCHES %@", "post\\.[a-z0-9]{20,}"))
    }

    // MARK: - The geometry seam

    private struct Reading: CustomStringConvertible {
        var rows = 0
        var visibleRows = 0
        var items = 0
        var offset: Double = 0
        var size: Double = 0
        var viewport: Double = 0
        var lowestRow: Double = -.infinity
        var top: String = "none"
        var fromBottom: Double = 0

        /// A row reaches the viewport's bottom edge (20 pt of tolerance for the list's 12 pt bottom
        /// padding) — "the pane is on its newest message".
        ///
        /// Deliberately not `fromBottom <= 1`: one measured stuck state had the *content* at its end
        /// (`fromBottom == 0`) with a single row whose bottom sat 15 pt below the viewport top, i.e.
        /// 475 pt of blank pane below the last thing drawn.
        var bottomRowOnScreen: Bool {
            viewport > 0 && lowestRow.isFinite && lowestRow >= viewport - 20
        }

        var description: String {
            String(format: "items=%d rows=%d visible=%d offset=%.1f size=%.1f viewport=%.1f "
                           + "lowestRow=%.1f fromBottom=%.1f top=%@",
                   items, rows, visibleRows, offset, size, viewport, lowestRow, fromBottom, top)
        }
    }

    private func readGeometry(_ app: XCUIApplication) -> Reading? {
        let seam = element(app, "channelPostList.scrollGeometry")
        guard seam.exists else { return nil }
        return parseGeometry(seam.value as? String ?? seam.label)
    }

    /// `ScrollGeometrySeam` publishes `rows=… visible=… items=… offset=… size=… viewport=… …` as its
    /// accessibility value; `blankStreak=… n=…` may follow.
    private func parseGeometry(_ raw: String) -> Reading? {
        func number(_ key: String) -> Double? {
            guard let range = raw.range(of: "\(key)=") else { return nil }
            let rest = raw[range.upperBound...]
            let token = rest.prefix { $0.isNumber || $0 == "-" || $0 == "." }
            return Double(token)
        }
        guard let items = number("items") else { return nil }
        var reading = Reading()
        reading.items = Int(items)
        reading.rows = Int(number("rows") ?? 0)
        reading.visibleRows = Int(number("visible") ?? 0)
        reading.offset = number("offset") ?? 0
        reading.size = number("size") ?? 0
        reading.viewport = number("viewport") ?? 0
        reading.lowestRow = number("lowestRow") ?? -.infinity
        reading.fromBottom = number("fromBottom") ?? 0
        if let range = raw.range(of: "top=") {
            let rest = raw[range.upperBound...]
            reading.top = String(rest.prefix { !$0.isWhitespace })
        }
        return reading
    }

    private func geometryReport(_ app: XCUIApplication) -> String {
        readGeometry(app).map(\.description) ?? "no scrollGeometry seam on screen"
    }

    // MARK: - Fixture calls

    private struct Session {
        var token: String
        var userID: String
    }

    private func ping() throws {
        let (data, _) = try get("/api/v4/system/ping")
        _ = data
    }

    private func authenticate(login: String, password: String) throws -> Session {
        var request = URLRequest(url: serverURL.appendingPathComponent("/api/v4/users/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["login_id": login,
                                                                      "password": password])
        let (data, response) = try synchronous(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        try XCTSkipUnless(status == 200, "the fixture login failed (HTTP \(status))")
        let token = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Token")
            ?? (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "token")
        let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return Session(token: try XCTUnwrap(token, "the fixture login returned no token"),
                       userID: body["id"] as? String ?? "")
    }

    private func teamsForMe() throws -> [[String: Any]] {
        let (data, _) = try get("/api/v4/users/me/teams")
        return try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
    }

    private func channel(named name: String, in teamID: String?) throws -> [String: Any]? {
        guard let teamID else { return nil }
        let (data, response) = try get("/api/v4/teams/\(teamID)/channels/name/\(name)")
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func get(_ path: String) throws -> (Data, URLResponse) {
        var request = URLRequest(url: serverURL.appendingPathComponent(path))
        request.setValue("Bearer \(token ?? "")", forHTTPHeaderField: "Authorization")
        return try synchronous(request)
    }

    /// An ephemeral session with cookies off, so the `Authorization` header is the only identity a
    /// fixture call can carry (T39-R2): a stale app session cookie must not decide who this is.
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

    // MARK: - Element helpers

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        let tree = XCTAttachment(string: geometryReport(app) + "\n\n" + app.debugDescription)
        tree.name = "\(name)-tree"
        tree.lifetime = .keepAlways
        add(tree)
    }
}
