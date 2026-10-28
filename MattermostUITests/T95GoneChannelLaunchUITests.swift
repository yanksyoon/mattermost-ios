// T95-A-AV-R follow-up (card t_fcbd5cc8) — **measurement**, not a fix.
//
// The question: `ChannelSidebarCoordinator.model(for:)` drives the launch decide from
// `model.$groups.sink { … applyLaunchDestinationIfNeeded(…) }`, and Combine publishes `@Published`
// in **willSet** — so inside that sink `model.groups` is still the *previous* value. With nothing
// saved the stale-empty read is harmless (`LaunchDestination.request` answers `nil` for "nothing
// saved" anyway). With a **saved channel that is gone** `request(saved:available:)` trusts the saved
// record when `available.isEmpty` ("not loaded yet — the pane is the judge"), so the stale read is
// the one case where it can hand back a channel the reader has left.
//
// The unit tests cover `request()` directly; they cannot see which `available` the coordinator hands
// it. This test drives the real launch path instead:
//
//   1. sign in on a wiped store, open a freshly created channel, terminate  → the product's own
//      `LastChannelStore` now holds that channel (no store bytes are fabricated here);
//   2. leave the channel over the API and confirm it is gone from the account's channel list;
//   3. relaunch **without** `-uiTestResetPersistedState` (that seam wipes the store) and measure
//      whether the shell opens the gone channel's pane on the directory-arrival decide.
//
// What it records (evidence, in the xcodebuild log *and* in the run's log file):
//   * `MEASURE …` lines — when the directory arrived, when/if the pane appeared, and the pane title;
//   * the `launch=` field of the `-shellSnapshot` diagnostics file, read from the host afterwards
//     (`… `launch=entries=0 saved=<id> -> <outcome>` is the decide that ran);
//   * two screenshots attached to the test result.
//
// Verdict semantics: the test asserts the **policy** (`docs/t95a-build-note.md`: a saved channel
// that is no longer in the list opens nothing). While the willSet read is unfixed the assertion is
// expected to fail, and the failure message carries the measurement. That is the point of this card:
// it produces the number, it does not paper over it with a pass.
//
// Run (local fixture; credentials come from the environment, never from this file):
//
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     python3 scripts/qa-test.py --platform ios --sim id=<udid> \
//       --only-testing MattermostUITests/T95GoneChannelLaunchUITests
//
// Skips (never fails) when the environment, the server or the fixture is missing, like every live
// test here.

import XCTest

final class T95GoneChannelLaunchUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var userID: String!
    private var teamID: String!

    /// How long the "did a destination open at launch?" window is held *after the channel directory
    /// is on screen*. The decide this test is about fires when the directory arrives (rows appear
    /// ~1.5 s after sign-in on this fixture), and the shell can decide again on any location change,
    /// so the claim is an interval, not a moment.
    private let launchWindow: TimeInterval = 30

    /// The relaunch happens on a cold process while the host may be loaded: T55-AV-R F-1 measured
    /// 60–160 s for `terminate()` + `launch()` to reach a usable surface. The landing poll is
    /// separate from the claim's window, so a slow host cannot decide the claim.
    private let relaunchLandingTimeout: TimeInterval = 240

    /// The `-shellSnapshot` diagnostics file is written ~65 s into a launch with no committed
    /// webview (the app polls 60×1 s for one). The measurement itself now ends ~35 s after the
    /// relaunch, so the app is held a bit past the difference; the hold issues no accessibility
    /// queries, which is what keeps it clear of the T635 process death.
    private let diagnosticsHold: TimeInterval = 40

    /// A cookie-free session for the fixture: `URLSession.shared` carries a stale `MMAUTHTOKEN` in
    /// its cookie jar, which makes `POST /users/login` answer 401 `api.context.*` on this host.
    private lazy var api: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    private var probe: (id: String, name: String, displayName: String)!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live gone-channel test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        try ping()
        let session = try authenticate()
        token = session.token
        userID = session.userID
        teamID = try firstTeamID()
    }

    // MARK: - The measurement

    func testAGoneSavedChannelIsNotOpenedOnRelaunch() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone,
                      "the launch destination pushes a pane over the phone shell; run on an iPhone")

        // 1. A channel that exists, that this account is a member of, and that nothing else in the
        //    fixture knows about: created through the API so the run does not depend on a seeded name.
        let stamp = Int(Date().timeIntervalSince1970)
        probe = try createChannel(named: "t95gone-\(stamp)")
        markEpoch("MEASURE probe channel id=\(probe.id) name=#\(probe.name)")

        // 2. First launch: wiped store, sign in, and open the probe channel the way a reader does.
        //    This is what writes `mm.native.lastChannel` — the saved record is the product's own.
        //
        //    The open goes through the sidebar's quick switcher, not a row tap: the fixture team holds
        //    ~42 channels and the sidebar renders only the rows in view (measured on the first attempt
        //    of this test: the probe channel's row was never in the tree after 25 swipes, and the
        //    quick switcher is the reader's own path to a channel that is not on screen).
        let first = launchAndSignIn()
        openViaQuickSwitcher(first, term: probe.name, channelID: probe.id)
        let pane = element(first, "nativeChannelPane")
        XCTAssertTrue(pane.waitForExistence(timeout: 60),
                      "opening the probe channel must mount its pane (setup — the saved record is "
                      + "only written when a channel is opened):\n" + first.debugDescription)
        let firstTitle = element(first, "nativeChannelTitle")
        XCTAssertTrue(waitUntil(timeout: 30) {
            let label = firstTitle.exists ? firstTitle.label : ""
            return label == self.probe.displayName || label == self.probe.name
        }, "the opened pane must name the probe channel (setup), got "
           + "'\(firstTitle.exists ? firstTitle.label : "nil")'")
        attach(first, "t95gone-1-saved-channel-opened")

        // A beat for the location write to reach UserDefaults before the process dies.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        first.terminate()
        // Wait for the old process to be **gone** before launching the next one: measured on this
        // card, sampling right after `launch()` returned hit the *terminating* process (its last
        // frame — the probe channel's pane — was still in the accessibility tree at t=0.01 s and the
        // next query answered "Application com.mattermost.ios is not running"). A relaunch
        // measurement taken across that handshake is a measurement of the previous launch.
        XCTAssertTrue(waitUntil(timeout: 60) { first.state == .notRunning },
                      "the first launch must be terminated before the relaunch is measured; "
                      + "state=\(first.state.rawValue)")

        // 3. The reader leaves the channel. Read back from the server, so "gone" is the server's
        //    answer and not this test's assumption.
        let leaveStatus = try leaveChannel(probe.id)
        XCTAssertEqual(leaveStatus, 200,
                       "leaving the probe channel must succeed; a 4xx here would make the rest of "
                       + "the test a measurement of something else")
        let stillJoined = try channelNames().contains(probe.name)
        XCTAssertFalse(stillJoined,
                       "#\(probe.name) must be out of the account's channel list — that list is what "
                       + "the sidebar's `available` set is built from")
        markEpoch("MEASURE left #\(probe.name); stillJoined=\(stillJoined)")

        // 4. Relaunch with the store intact: no `-uiTestResetPersistedState` (it wipes UserDefaults,
        //    and with it the saved channel) and no `-uiTestForgetSession` (the session must be the
        //    one the first launch established — a sign-in would be a different launch).
        //
        //    The `-shellSnapshot` diagnostics path comes from `MM_SNAPSHOT_PATH`, which the host sets
        //    to a file **inside the app's own container** (`xcrun simctl get_app_container … data` +
        //    `/tmp/`). An iOS simulator app is sandboxed: a host-absolute path such as `/tmp/x`
        //    silently writes nothing (measured on this card — the probe file the parent card wrote to
        //    `/tmp` leaves no file on this runtime), so the seam can only be used with a
        //    container-relative path, and this test cannot compute one itself.
        let snapshotPath = ProcessInfo.processInfo.environment["MM_SNAPSHOT_PATH"]
        let app = XCUIApplication()
        app.launchArguments = relaunchArguments(snapshotPath: snapshotPath)
        app.launch()
        // The clock starts when the **new** process is foreground, not when `launch()` returned.
        let ready = waitUntil(timeout: 120) { app.state == .runningForeground }
        XCTAssertTrue(ready, "the relaunch never reached a foreground process (state="
                      + "\(app.state.rawValue)); nothing was measured")
        let startedAt = Date()
        markEpoch("MEASURE relaunched with args=\(app.launchArguments)")

        // 4b. Sample the relaunch from the process's first frame: pane, pane title, tab bars and the
        //     channel directory, every 250 ms, recording every **state change** with its elapsed time.
        //
        //     Sampling from launch rather than from "the shell appeared" is what makes a transient
        //     push visible: a pane that opens and is replaced before the shell settles is a different
        //     measurement from one that stays, and a `waitForExistence` started after the landing
        //     would miss it (the same race the parent card's §1 removed from the launch window).
        let relaunchPane = element(app, "nativeChannelPane")
        let relaunchTitle = element(app, "nativeChannelTitle")
        let firstRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "channelSidebar.channel."))
            .firstMatch

        var trace: [String] = []
        var paneAt: TimeInterval?
        var paneTitleAtFirstSight = "-"
        var rowsAt: TimeInterval?
        var landing: Landing = .neither
        var landingAt: TimeInterval?
        var lastState = ""
        var appDied = false
        let hardDeadline = Date().addingTimeInterval(relaunchLandingTimeout)
        while Date() < hardDeadline {
            // A cheap local state read first: T635 measured the app process vanishing under heavy
            // accessibility snapshotting on this host, and a snapshot query against a dead process
            // fails the test with "Application is not running" instead of a measurement.
            if app.state == .notRunning { appDied = true; break }
            let elapsed = Date().timeIntervalSince(startedAt)
            let paneNow = relaunchPane.exists
            let rows = firstRow.exists
            // Title and tab bars are read only where they mean something: a title without a pane, or
            // a tab-bar count on every tick, multiplies snapshots for no extra information.
            let titleNow = paneNow && relaunchTitle.exists ? relaunchTitle.label : "-"
            let tabs = paneNow ? app.tabBars.count : -1
            let shell = paneNow ? false : element(app, "nativeShell").exists
            let signIn = (paneNow || shell) ? false : app.textFields["loginIDField"].exists
            if rows, rowsAt == nil { rowsAt = elapsed }
            if paneNow, paneAt == nil {
                paneAt = elapsed
                paneTitleAtFirstSight = titleNow
            }
            if landing == .neither {
                if paneNow { landing = .pane }
                else if shell { landing = .shell }
                else if signIn { landing = .signIn }
                if landing != .neither { landingAt = elapsed }
            }
            let state = "pane=\(paneNow) title='\(titleNow)' tabs=\(tabs) rows=\(rows) "
                + "shell=\(shell) signIn=\(signIn)"
            if state != lastState {
                // Streamed, not buffered: if the process dies mid-window the trace up to that point
                // is still in the run log.
                trace.append(String(format: "t=%.2f ", elapsed) + state)
                markEpoch("MEASURE trace " + (trace.last ?? ""))
                lastState = state
            }
            if landing == .signIn { break }
            // The window starts when the directory is on screen — or, when the pane covers the
            // sidebar so no row is ever in the tree, when the launch first landed. Either way it is
            // bounded: an unbounded loop here is how the first draft ran into the T635 process death
            // 131 s in and measured nothing.
            if let windowStart = rowsAt ?? landingAt, elapsed > windowStart + launchWindow { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        if appDied {
            XCTFail("the app process died \(String(format: "%.1f", Date().timeIntervalSince(startedAt))) s "
                    + "into the relaunch measurement (the known T635 symptom on this host: the process "
                    + "vanishes under accessibility snapshotting), so this run measured nothing. "
                    + "Trace so far: \(trace.joined(separator: " | "))")
            return
        }

        switch landing {
        case .signIn:
            XCTFail("the relaunch landed on the sign-in surface, so this run cannot measure the "
                    + "launch decide (the session was not restored).\n" + app.debugDescription)
            return
        case .neither:
            XCTFail("the relaunch reached neither the shell nor a pane within "
                    + "\(Int(relaunchLandingTimeout)) s.\n" + app.debugDescription)
            return
        case .shell, .pane:
            break
        }

        // The window start is recorded, not required: when the pane covers the sidebar no
        // `channelSidebar.channel.*` row is in the tree at all, so "rows never appeared" is the
        // reproducing case's own signature — requiring a row here would refuse to measure exactly
        // the launch this test is about. The landing switch above is the real precondition.
        markEpoch("MEASURE landing=\(landing) directory rows at "
                  + "\(rowsAt.map { String(format: "%.2f", $0) } ?? "never (pane covers the sidebar)") "
                  + "s after launch; landing at "
                  + "\(landingAt.map { String(format: "%.2f", $0) } ?? "nil") s; "
                  + "window=\(launchWindow)s from \(rowsAt != nil ? "the directory" : "the landing")")
        let titleLabel = paneTitleAtFirstSight
        let tabBars = app.tabBars.count
        markEpoch("MEASURE paneAt=\(paneAt.map { String(format: "%.2f", $0) } ?? "nil") s after launch "
                  + "title='\(titleLabel)' tabBarsNow=\(tabBars)")
        attach(app, "t95gone-2-relaunch-after-leaving")

        // The policy under test (`docs/t95a-build-note.md`, `docs/t95-shell-tab-bar-decision.md` §3):
        // a saved channel that is no longer in the list opens nothing — the launch stays on the
        // channel list.
        //
        // This is a **measured, unfixed** product defect (card t_fcbd5cc8; the repair card is
        // `docs/t95a-gone-channel-build-note.md` §3). The expectation below is deliberate: the
        // falsifier has to exist while the bug does, and `XCTExpectFailure` is **strict** by default —
        // once the fix lands these assertions stop failing, the expectation goes unmatched and *this
        // test fails*, which is the signal to delete the wrapper (not the assertions).
        //
        // `continueAfterFailure` is raised here (not in `setUp`) so that all three observations are
        // recorded in one run: a matched expected failure still stops the test otherwise, and the
        // title/tab-bar half of the claim would then never be measured.
        continueAfterFailure = true
        XCTExpectFailure("""
            Known defect (card t_fcbd5cc8, measured 2026-10-28): a relaunch whose saved channel the \
            account has already left opens that channel's pane instead of the channel list. The \
            launch decide reads an empty `available` (the directory has not arrived, and the \
            `$groups` willSet read is one publish behind), which `LaunchDestination.request` trusts.
            """)
        XCTAssertNil(paneAt,
                     "the shell opened a channel pane \(paneAt.map { String(format: "%.2f", $0) } ?? "?") "
                     + "s after the relaunch, on a launch whose saved channel "
                     + "#\(probe.name) the account had already left (stillJoined=false). "
                     + "title='\(titleLabel)' tabBars=\(tabBars). A saved channel that is gone must "
                     + "open nothing: `LaunchDestination.request` only refuses it when `available` is "
                     + "loaded, and the launch decides run before (and, through the `$groups` willSet "
                     + "read, during) the directory's arrival."
                     + "\n" + app.debugDescription)
        XCTAssertFalse(titleLabel == probe.displayName || titleLabel == probe.name,
                       "the pane at launch names the channel the account has left "
                       + "(#\(probe.name)); the reader was sent back into a conversation they are "
                       + "no longer a member of")
        XCTAssertGreaterThan(tabBars, 0,
                            "a launch that lands on the channel list keeps its tab bar (D1); "
                            + "\(tabBars) bar(s) with no channel open means the shell lost its tabs")

        // 5. Keep the process alive past the `-shellSnapshot` diagnostics write (~65 s in a native
        //    shell: the probe waits 60×1 s for a webview that never commits), so the forensic
        //    `launch=` line — `entries=<n> saved=<id> -> <outcome>` — reaches disk for the run log.
        //    Only when the host supplied a writable container path.
        if let snapshotPath {
            markEpoch("MEASURE holding \(Int(diagnosticsHold)) s for the -shellSnapshot diagnostics "
                  + "(\(snapshotPath).txt)")
            RunLoop.current.run(until: Date().addingTimeInterval(diagnosticsHold))
        } else {
            markEpoch("MEASURE no MM_SNAPSHOT_PATH in the environment: the -shellSnapshot diagnostics "
                  + "are not taken (the app cannot write a host path); the run log carries the "
                  + "measurement instead")
        }
        markEpoch("MEASURE end state title='\(element(app, "nativeChannelTitle").exists ? element(app, "nativeChannelTitle").label : "-")' "
              + "pane=\(element(app, "nativeChannelPane").exists)")
    }

    // MARK: - Fixture

    private func ping() throws {
        let (_, response) = try synchronous(get: "/api/v4/system/ping")
        guard response?.statusCode == 200 else {
            throw XCTSkip("the fixture server at \(serverURL.absoluteString) does not answer ping "
                          + "(status \(response?.statusCode ?? -1)); start it with: docker start mm-perf")
        }
    }

    private func authenticate() throws -> (token: String, userID: String) {
        let (data, response) = try synchronous(path: "/api/v4/users/login", method: "POST",
                                               body: ["login_id": loginID, "password": password])
        guard response?.statusCode == 200,
              let token = response?.value(forHTTPHeaderField: "Token"),
              !token.isEmpty else {
            throw XCTSkip("the fixture server did not issue a token for \(loginID!) "
                          + "(status \(response?.statusCode ?? -1))")
        }
        let user = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (token, user["id"] as? String ?? "")
    }

    private func firstTeamID() throws -> String {
        let (data, _) = try synchronous(get: "/api/v4/users/me/teams", token: token)
        let teams = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        guard let id = teams.first?["id"] as? String else {
            throw XCTSkip("the fixture account is in no team")
        }
        return id
    }

    private func createChannel(named name: String) throws -> (id: String, name: String, displayName: String) {
        let display = "T95 Gone Probe"
        let (data, response) = try synchronous(path: "/api/v4/channels", method: "POST", token: token,
                                               body: ["team_id": teamID!, "name": name,
                                                      "display_name": display, "type": "O"])
        guard response?.statusCode == 201,
              let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = row["id"] as? String else {
            throw XCTSkip("the fixture server refused to create a probe channel "
                          + "(status \(response?.statusCode ?? -1)): \(String(data: data, encoding: .utf8) ?? "")")
        }
        return (id, name, display)
    }

    /// `DELETE /channels/{id}/members/{user_id}` — the account leaves the channel.
    private func leaveChannel(_ id: String) throws -> Int {
        let (_, response) = try synchronous(path: "/api/v4/channels/\(id)/members/\(userID!)",
                                            method: "DELETE", token: token)
        return response?.statusCode ?? -1
    }

    /// The account's own channel list — the server-side source of the sidebar's `available` set.
    private func channelNames() throws -> [String] {
        let (data, _) = try synchronous(get: "/api/v4/users/me/teams/\(teamID!)/channels", token: token)
        let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        return rows.compactMap { $0["name"] as? String }
    }

    private func synchronous(get path: String, token: String? = nil) throws -> (Data, HTTPURLResponse?) {
        try synchronous(path: path, method: "GET", token: token, body: nil)
    }

    private func synchronous(path: String,
                             method: String,
                             token: String? = nil,
                             body: [String: Any]? = nil) throws -> (Data, HTTPURLResponse?) {
        guard let url = URL(string: path, relativeTo: serverURL) else {
            throw XCTSkip("cannot build \(path) against \(serverURL.absoluteString)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let done = DispatchSemaphore(value: 0)
        var payload = Data()
        var http: HTTPURLResponse?
        api.dataTask(with: request) { data, response, _ in
            payload = data ?? Data()
            http = response as? HTTPURLResponse
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 25)
        return (payload, http)
    }

    // MARK: - App helpers

    private func launchAndSignIn() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetPersistedState",
                               "-uiTestForgetSession", serverURL.absoluteString,
                               "-uiTestSeedServer", serverURL.absoluteString,
                               "-uiTestSeedServerName", "Local Mattermost",
                               "-surfaceMode", "shell=native",
                               "-surfaceMode", "auth=native",
                               "-surfaceMode", "sidebar=native",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let field = app.textFields["loginIDField"]
        XCTAssertTrue(field.waitForExistence(timeout: 30),
                      "the native sign-in must mount against \(serverURL.absoluteString):\n"
                      + app.debugDescription)
        field.tap()
        field.typeText(loginID)
        let secret = app.secureTextFields["loginPasswordField"]
        XCTAssertTrue(secret.waitForExistence(timeout: 10))
        secret.tap()
        secret.typeText(password)
        app.buttons["loginSubmitButton"].tap()
        let shell = element(app, "nativeShell")
        XCTAssertTrue(waitUntil(timeout: 60) { shell.exists || app.tabBars.firstMatch.exists },
                      "signing in must reach the shell:\n" + app.debugDescription)
        return app
    }

    /// The relaunch: same surfaces, **no** reset seam and **no** forget-session seam, so the saved
    /// channel and the session are the ones the first launch left behind.
    private func relaunchArguments(snapshotPath: String?) -> [String] {
        var args = ["-surfaceMode", "shell=native",
                    "-surfaceMode", "auth=native",
                    "-surfaceMode", "sidebar=native",
                    "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if let snapshotPath { args.append(contentsOf: ["-shellSnapshot", snapshotPath]) }
        return args
    }

    private enum Landing {
        case shell
        case pane
        case signIn
        case neither
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Open a channel through the sidebar's quick switcher: it searches the loaded team's channels,
    /// so it works regardless of which category happens to be expanded or scrolled into view.
    /// (Same sequence as `T35-ComposerUITests.openViaQuickSwitcher`.)
    private func openViaQuickSwitcher(_ app: XCUIApplication, term: String, channelID: String) {
        let opener = element(app, "channelSidebar.quickSwitcher")
        XCTAssertTrue(opener.waitForExistence(timeout: 40),
                      "the sidebar must offer the quick switcher:\n" + app.debugDescription)
        opener.tap()
        let field = app.textFields["channelSidebar.quickSwitcher.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 15),
                      "the quick switcher must focus a field:\n" + app.debugDescription)
        field.tap()
        field.typeText(term)
        let result = element(app, "channelSidebar.quickSwitcher.result.\(channelID)")
        XCTAssertTrue(result.waitForExistence(timeout: 30),
                      "the quick switcher must find #\(term) (setup):\n" + app.debugDescription)
        result.tap()
        XCTAssertTrue(element(app, "channelPostList").waitForExistence(timeout: 60),
                      "the opened channel must mount its post list (setup):\n" + app.debugDescription)
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
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// One measurement line with an absolute timestamp, so the app's own probe log (which stamps every
    /// line with `Date().timeIntervalSince1970` in an instrumented build) and this test's timeline can
    /// be read against each other instead of guessed at.
    private func markEpoch(_ text: String) {
        print(String(format: "%.3f ", Date().timeIntervalSince1970) + text)
    }
}
