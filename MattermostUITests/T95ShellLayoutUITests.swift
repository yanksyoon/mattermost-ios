// T95-A — the phone shell's launch shape, asserted as **parity** rather than as a bug.
//
// Two claims, both from the decision record `docs/t95-shell-tab-bar-decision.md` (§2 D1, §3 D2):
//
//   1. a launch with nothing saved lands on the channel list, with its tab bar — upstream's cold
//      start restores the last thread, else the last channel, else `HOME`
//      (`mattermost-mobile` v2.45.0 = `162f2560`, `app/init/launch.ts:245-262`, `:290-294`). There is
//      no town-hall or first-channel fallback, so a reset launch (`-uiTestResetPersistedState` wipes
//      `mm.native.lastChannel`) must show the tabs and **not** a pushed channel pane;
//   2. opening a channel from the sidebar **covers** the tab bar (a `Back` chevron instead), and
//      `Back` brings the bar back — upstream keeps its `Stack` above the `Tabs`, so a channel is a
//      sibling route pushed over the tab navigator, and the Mobile v2 design slides the bar off in a
//      channel on phone.
//
// This test is the falsifier for both halves of the compact layout: reinstating the town-hall push
// makes step 1 red (a `nativeChannelPane` at launch, no tab bar), and a future "keep the tab bar in
// a channel" change makes step 2 red (tab bar still on screen under the pane). Both reds have been
// **executed**, not assumed:
//
//   * step 1's launch window (`firstMoment(within: launchWindow)`) reds when the town-hall fallback
//     is reinstated in `LaunchDestination.request` — measured, with the elapsed time in the failure
//     message (`docs/t95a-av2-build-note.md` §1);
//   * step 2's `app.tabBars.count == 0` reds when the compact layout keeps the bar in a channel —
//     the per-tab-stack mutant (a `NavigationStack` inside the Channels tab instead of above the
//     `TabView`) was rendered for one run and this assertion failed on it
//     (`docs/t95a-av2-build-note.md` §2).
//
// The regular half of D2 is a second test in this file,
// `testTheRegularLayoutLandsOnTheSplitViewWithAnEmptyDetail`, and runs on an iPad destination; this
// method asserts the compact/phone half and skips elsewhere. Both share this file's fixture code —
// no second fixture, no second helper.
//
// Run (local fixture server; credentials come from the environment, never from this file):
//
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     python3 scripts/qa-test.py --platform ios --sim id=81A7F251-8B31-4945-8783-5A264C14B8D5 \
//       --only-testing MattermostUITests/T95ShellLayoutUITests
//
// Skips (never fails) when the environment, the server or the fixture is missing, like every live
// test here.

import XCTest

final class T95ShellLayoutUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var teamID: String!

    /// The team's default channel, as the server names it: `town-square` on Mattermost's own
    /// defaults, `town-hall` on the measured fixture (renamed by the admins). Read from the server,
    /// never hard-coded — and falling back to any public channel so a renamed default still runs.
    private var townHall: (id: String, name: String, displayName: String)!

    /// How long "no destination at launch" is held for, once the channel directory is on screen.
    ///
    /// The shell decides its launch destination more than once (appearance, directory arrival, any
    /// location change), so the claim has to be held across the interval in which a decide can still
    /// land rather than sampled once. 20 s is well past the measured directory-arrival decide
    /// (rows on screen ~1.5 s after sign-in) while keeping the green run at ~1 min; the reinstated
    /// fallback reds inside 1 s of the window starting (`docs/t95a-av2-build-note.md` §1).
    private let launchWindow: TimeInterval = 20

    /// A cookie-free session for the fixture reads: `URLSession.shared` carries a stale
    /// `MMAUTHTOKEN` in its cookie jar, which makes `POST /users/login` answer 401 `api.context.*`
    /// on this host (T39-R2 measured it).
    private lazy var api: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live shell-layout test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        try ping()
        let session = try authenticate()
        teamID = try firstTeamID(token: session.token)
        townHall = try defaultChannel(token: session.token)
    }

    // MARK: - The test

    func testALaunchWithNothingSavedShowsTheTabBarAndAChannelPushCoversIt() throws {
        // D1 is the **phone** layout: tabs, and a channel pushed over them. The regular layout has no
        // tab bar at all (`NativeShellView.regularLayout`, deviation D-1 in the decision doc), so
        // this half is asserted on an iPhone destination and the split-view half in
        // `testTheRegularLayoutLandsOnTheSplitViewWithAnEmptyDetail`.
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone,
                      "D1 is the phone layout — run this method on an iPhone destination")

        let app = launchAndSignIn()

        // 1. Nothing saved → the channel list and its tab bar; no channel is invented.
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(waitUntil(timeout: 60) { tabBar.exists },
                      "a launch with nothing saved must land on the channel list, whose tab bar is "
                      + "on screen (upstream routes to HOME with no conversation saved):\n"
                      + app.debugDescription)
        attach(app, "t95a-1-launch-nothing-saved")
        XCTAssertTrue(app.tabBars.buttons["Search"].exists,
                      "the bar must be the shell's own five tabs, not an empty container:\n"
                      + app.debugDescription)

        // 1b. The "no destination" claim is a **window**, not a moment, and the window has to start
        //     after the channel directory is on screen.
        //
        //     The shell decides its launch destination more than once: on appearance
        //     (`ChannelSidebarCoordinator.activate`, where the team can still be unknown), again when
        //     the channel directory arrives (`model(for:)`'s `$groups` sink, `:143-146`), and once
        //     more from any location change (`apply(_:)`). A `waitForExistence(timeout: 5)` started
        //     before the directory is on screen can therefore close *before* the decide that would
        //     open a channel — that is exactly how this assertion used to pass on the tree that had
        //     the town-hall fallback (`docs/t95a-av2-build-note.md` §1). Waiting for the list first,
        //     then holding the assertion over a window, is the same claim with the race removed.
        let firstChannelRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "channelSidebar.channel."))
            .firstMatch
        XCTAssertTrue(waitUntil(timeout: 60) { firstChannelRow.exists },
                      "the channel directory must be on screen before this test can tell \"nothing "
                      + "was opened\" from \"nothing has arrived yet\":\n" + app.debugDescription)

        let paneAt = firstMoment(within: launchWindow) { otherElement(app, "nativeChannelPane").exists }
        XCTAssertNil(paneAt,
                     "a launch with nothing saved must NOT open a channel — LaunchDestination "
                     + "restores the last channel and nothing else, so no town hall may be pushed "
                     + "(this is the assertion a reinstated fallback breaks). A nativeChannelPane "
                     + "appeared \(paneAt.map { String(format: "%.1f", $0) } ?? "?") s after the "
                     + "channel directory was on screen:\n" + app.debugDescription)
        XCTAssertTrue(tabBar.exists,
                      "the tab bar must still be on screen at the end of the launch window — a bar "
                      + "that leaves without a channel pushed means the shell lost its tabs:\n"
                      + app.debugDescription)
        attach(app, "t95a-1b-launch-window-held")

        // 2. Open the team's default channel the way a reader does: tap its sidebar row.
        let row = revealSidebarRow(app, identifier: "channelSidebar.channel.\(townHall.id)")
        XCTAssertTrue(row.waitForExistence(timeout: 40),
                      "the sidebar must list #\(townHall.name) so the test can open it:\n"
                      + app.debugDescription)
        row.tap()

        let pane = otherElement(app, "nativeChannelPane")
        XCTAssertTrue(pane.waitForExistence(timeout: 40),
                      "tapping a sidebar row must push the channel pane:\n" + app.debugDescription)
        let title = element(app, "nativeChannelTitle")
        XCTAssertTrue(title.waitForExistence(timeout: 10),
                      "the pushed pane must name the channel it opened:\n" + app.debugDescription)
        // The header starts as the slug the shell was handed and `loadChannelHeader()` replaces it
        // with the server's display name a beat later (T40's `ChannelPaneTitle`), so either spelling
        // is the right channel; a different channel is not.
        XCTAssertTrue(waitUntil(timeout: 30) {
            let label = title.exists ? title.label : ""
            return label == self.townHall.displayName || label == self.townHall.name
        }, "the pane must show the channel whose row was tapped (#\(townHall.name) / "
           + "#\(townHall.displayName)), got '\(title.exists ? title.label : "nil")'")

        // ...and the push covers the tab bar: the compact layout's stack sits above the TabView,
        // exactly as upstream's `Stack` wraps `Tabs` (design doc: the bar slides off in a channel).
        //
        // Mutation-tested (T95-A-AV F2): a per-tab stack — a `NavigationStack` *inside* the Channels
        // tab instead of above the `TabView` — keeps the bar on screen under the channel pane, and
        // the `app.tabBars.count == 0` below fails on it. So this is not an assertion that merely
        // describes the current implementation; it reds on the one change it is about
        // (`docs/t95a-av2-build-note.md` §2).
        let back = app.navigationBars.buttons["Back"]
        XCTAssertTrue(back.waitForExistence(timeout: 10),
                      "a pushed channel offers Back — on upstream too, its phone channel header "
                      + "carries the chevron:\n" + app.debugDescription)
        XCTAssertTrue(waitUntil(timeout: 10) { app.tabBars.count == 0 },
                      "the pushed pane covers the tab bar (upstream parity, D1); a tab bar still on "
                      + "screen here means someone changed the shell's structure — that is a "
                      + "deviation card, not a bug fix:\n" + app.debugDescription)
        attach(app, "t95a-2-channel-covers-the-bar")

        // 3. Back → the bar is back, and no channel pane is left behind.
        back.tap()
        XCTAssertTrue(waitUntil(timeout: 30) { app.tabBars.firstMatch.exists },
                      "Back must return to the channel list with its tab bar:\n" + app.debugDescription)
        XCTAssertFalse(otherElement(app, "nativeChannelPane").exists,
                       "the popped destination must not stay in the hierarchy:\n" + app.debugDescription)
        attach(app, "t95a-3-back-restores-the-bar")
    }

    /// The **regular** half of D2 (`docs/t95-shell-tab-bar-decision.md` §3): a launch with nothing
    /// saved lands on the split view, with the empty detail column — not on an invented channel.
    ///
    /// Nothing asserted that before this test: the compact method above is phone-only (it needs
    /// `app.tabBars`, which the regular layout does not draw), and `LastChannelLaunchTests` is
    /// layout-independent — it measures `LaunchDestination.request` and first-tap behaviour, never
    /// which pane the shell renders. So a regular layout that opened the town hall on launch would
    /// have left every suite green. That is the gap this method closes (T95-A-AV F3).
    ///
    /// Runs on an iPad destination, landscape so both columns are on screen; skips on a phone
    /// destination, where the split view does not exist.
    func testTheRegularLayoutLandsOnTheSplitViewWithAnEmptyDetail() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad,
                          "the regular half of D2 needs a regular-width destination (an iPad)")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }

        let app = launchAndSignIn()

        // The split view is the shell: it **stays** (nothing is pushed over it, so `nativeShell`
        // remains in the tree — on compact a pushed pane is what removes it).
        let shell = element(app, "nativeShell")
        XCTAssertTrue(waitUntil(timeout: 60) { shell.exists },
                      "the regular layout must keep the shell on screen — a launch that pushes a "
                      + "destination instead of selecting the detail column is the compact shape on "
                      + "the wrong device:\n" + app.debugDescription)

        // The detail column is the empty destination: "nothing saved" means "nothing selected".
        let emptyDetail = element(app, "nativeEmptyDestination")
        XCTAssertTrue(emptyDetail.waitForExistence(timeout: 30),
                      "a launch with nothing saved must leave the detail column empty "
                      + "(NativeEmptyDestinationView), upstream's tablet shape for \"no current "
                      + "channel\":\n" + app.debugDescription)
        XCTAssertTrue(waitUntil(timeout: 10) {
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@",
                                                   "No channel selected")).firstMatch.exists
        }, "the empty detail must say so instead of rendering a blank pane:\n" + app.debugDescription)

        // The sidebar column is on screen and lists the team's channels — that is the split view
        // being a *split* view, not an empty detail stretched over the window. The column's own team
        // row names the team; any channel row proves the list is populated. (Deliberately not "the
        // town hall row": this fixture's team has ~40 channels, and scrolling the *detail* column
        // with `app.swipeUp()` would never reach it — the landing claim does not need that row.)
        XCTAssertTrue(element(app, "sidebarCurrentTeam").waitForExistence(timeout: 30),
                      "the split view's sidebar column must be on screen and name the team:\n"
                      + app.debugDescription)
        let channelRows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "channelSidebar.channel."))
        XCTAssertTrue(waitUntil(timeout: 30) { channelRows.count > 0 },
                      "the split view's sidebar column must list the team's channels:\n"
                      + app.debugDescription)

        // The regular layout has no tab bar (deviation D-1 in the decision doc: our split view uses
        // toolbar buttons for Search/Saved/Mentions), so none may appear here.
        XCTAssertEqual(app.tabBars.count, 0,
                       "the regular layout draws no tab bar (decision doc D-1); one on screen means "
                       + "the layout changed shape:\n" + app.debugDescription)

        // And nothing opens over the detail inside the launch window, for the same reason as the
        // compact test's step 1b: the launch decides again when the directory arrives.
        let paneAt = firstMoment(within: launchWindow) {
            otherElement(app, "nativeChannelPane").exists || app.staticTexts["nativeChannelTitle"].exists
        }
        XCTAssertNil(paneAt,
                     "the regular layout must not invent a destination: a channel pane/title "
                     + "appeared \(paneAt.map { String(format: "%.1f", $0) } ?? "?") s after the "
                     + "channel directory was on screen:\n" + app.debugDescription)
        XCTAssertTrue(emptyDetail.exists,
                      "the detail column must still be the empty destination after the launch "
                      + "window:\n" + app.debugDescription)
        attach(app, "t95a-av2-regular-launch-empty-detail")
    }

    // MARK: - Launch

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
        XCTAssertTrue(field.waitForExistence(timeout: 20),
                      "the native sign-in must mount against \(serverURL.absoluteString):\n"
                      + app.debugDescription)
        field.tap()
        field.typeText(loginID)
        let secret = app.secureTextFields["loginPasswordField"]
        XCTAssertTrue(secret.exists)
        secret.tap()
        secret.typeText(password)
        app.buttons["loginSubmitButton"].tap()
        // "Signed in" is the shell **or** a destination pushed over it: a restored channel pane
        // removes `nativeShell` from the accessibility tree (T37-R2 F-1b), so waiting on the shell
        // alone would decide this test's outcome inside its own launch helper.
        let shell = otherElement(app, "nativeShell")
        let pane = otherElement(app, "nativeChannelPane")
        XCTAssertTrue(waitUntil(timeout: 60) {
            !field.exists && (shell.exists || pane.exists || app.tabBars.firstMatch.exists)
        }, "signing in must reach the shell (the channel list, or a channel pane pushed over it):\n"
           + app.debugDescription)
        return app
    }

    // MARK: - Fixture (the test is its own API client; nothing is assumed)

    private func ping() throws {
        let (_, response) = try synchronous(get: "/api/v4/system/ping")
        guard response?.statusCode == 200 else {
            throw XCTSkip("the fixture server at \(serverURL.absoluteString) does not answer ping "
                          + "(status \(response?.statusCode ?? -1)); start it with: docker start mm-perf")
        }
    }

    private func authenticate() throws -> (token: String, userID: String) {
        let (data, response) = try synchronous(path: "/api/v4/users/login",
                                               method: "POST",
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

    private func firstTeamID(token: String) throws -> String {
        let (data, _) = try synchronous(get: "/api/v4/users/me/teams", token: token)
        let teams = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        guard let id = teams.first?["id"] as? String else {
            throw XCTSkip("the fixture account is in no team")
        }
        return id
    }

    /// The team's default channel: `town-square`/`town-hall` when the server has one, else its first
    /// public channel — so a fixture whose default was renamed still exercises the same row.
    private func defaultChannel(token: String) throws -> (id: String, name: String, displayName: String) {
        let (data, _) = try synchronous(get: "/api/v4/users/me/teams/\(teamID!)/channels", token: token)
        let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        let channels = rows.compactMap { row -> (id: String, name: String, displayName: String, type: String)? in
            guard let id = row["id"] as? String, let name = row["name"] as? String else { return nil }
            let display = (row["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
            return (id, name, display, row["type"] as? String ?? "")
        }
        let pickup = channels.first { $0.name == "town-square" || $0.name == "town-hall" }
            ?? channels.first { $0.type == "O" }
        guard let pickup else { throw XCTSkip("the fixture team has no channel to open") }
        return (pickup.id, pickup.name, pickup.displayName)
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

    // MARK: - Small helpers

    /// Any element type carrying `identifier`: SwiftUI decides whether an identifier lands on an
    /// `other`, a `staticText` or a `button`, and that changes across OS versions.
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The same lookup for the identifiers measured to land on an `Other` (`nativeShell`,
    /// `nativeChannelPane`, `nativeTeamSidebar` — read off the tree in `t8d-base-A`).
    ///
    /// Why a typed query and not `element(_:_:)`: T8d measured XCUITest's accessibility serialiser
    /// logging ~1 MB per any-type identifier query on the drawn shell versus ~0.09 MB for a
    /// type-scoped one, because a typed walk fetches the element type first and the rest of the
    /// attribute set only for the candidates. That log is emitted *inside the app process*; enough of
    /// it in a short window puts the process's firehose buffer in quarantine, and the next `os_log`
    /// taken during a snapshot crashes the app in XCTest's fault callback
    /// (`docs/t8d-build-note.md` §1). The sampler below runs every 0.1 s for the whole launch
    /// window, so it is the one place where the per-query cost dominates the run.
    private func otherElement(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.otherElements[identifier]
    }

    /// Scroll the channel list until `identifier` exists (a lazy `List` builds only its viewport).
    @discardableResult
    private func revealSidebarRow(_ app: XCUIApplication, identifier: String,
                                  maxSwipes: Int = 20) -> XCUIElement {
        let target = element(app, identifier)
        guard !target.exists else { return target }
        var swipes = 0
        while !target.exists, swipes < maxSwipes {
            app.swipeUp(velocity: .fast)
            swipes += 1
        }
        return target
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    /// The first moment (seconds from this call) at which `condition` holds, sampled every
    /// `sampling` seconds, or `nil` when it never does inside `window`.
    ///
    /// This is how a *window* is asserted instead of a moment. `waitForExistence(timeout:)` answers
    /// "was it there when I last looked, having polled for N seconds"; for a shell that re-decides
    /// its launch destination asynchronously, the interesting claim is "it never appeared across the
    /// interval in which a decide could land". Returning the elapsed time also puts the timing in the
    /// failure message, so a red says *when* the destination arrived.
    private func firstMoment(within window: TimeInterval,
                             sampling: TimeInterval = 0.1,
                             _ condition: () -> Bool) -> TimeInterval? {
        let start = Date()
        let deadline = start.addingTimeInterval(window)
        while Date() < deadline {
            if condition() { return Date().timeIntervalSince(start) }
            RunLoop.current.run(until: Date().addingTimeInterval(sampling))
        }
        return condition() ? Date().timeIntervalSince(start) : nil
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
