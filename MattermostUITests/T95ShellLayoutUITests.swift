// T95-A — the phone shell's launch shape, asserted as **parity** rather than as a bug.
//
// Three claims, from the decision record `docs/t95-shell-tab-bar-decision.md` (§2 D1, §3 D2) as
// amended by card `t_295b0a32` (the product owner's 2026-10-27 instruction: "launch into last opened
// channel, or default to town hall"):
//
//   1. a launch with nothing saved opens the team's **town hall** — not "No channel selected" and
//      not an empty detail column. Upstream's cold start restores the last thread, else the last
//      channel, else `HOME` (`mattermost-mobile` v2.45.0 = `162f2560`, `app/init/launch.ts:245-262`,
//      `:290-294`) and has no town-hall fallback; T95-A followed it and the owner called the result a
//      regression. The fallback is back (`LaunchDestination`), so this is the assertion that pins it;
//   2. opening a channel from the sidebar **covers** the tab bar on compact (a `Back` chevron
//      instead), and `Back` brings the bar back — upstream keeps its `Stack` above the `Tabs`, so a
//      channel is a sibling route pushed over the tab navigator, and the Mobile v2 design slides the
//      bar off in a channel on phone;
//   3. on the regular layout the same launch selects the town hall in the **detail column** and the
//      shell (split view) stays on screen.
//
// The falsifiers are real: deleting the fallback from `LaunchDestination.resolve` makes step 1 red
// (`nativeChannelPane` never appears; the title never names the town hall), and a future "keep the
// tab bar in a channel" change makes step 2 red (`app.tabBars.count == 0` while the pane is open).
// Both reds were executed for T95-A's inverse policy (`docs/t95a-av2-build-note.md` §1–§2) and are
// the same measurements run the other way.
//
// The regular half of the layout is a second test in this file,
// `testTheRegularLayoutOpensTheTownHallInTheDetailColumn`, and runs on an iPad destination; this
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

    func testTheCompactLaunchOpensTheTownHallAndItsPushCoversTheTabBar() throws {
        // D1 is the **phone** layout: tabs, and a channel pushed over them. The regular layout has no
        // tab bar at all (`NativeShellView.regularLayout`, deviation D-1 in the decision doc), so
        // this half is asserted on an iPhone destination and the split-view half in
        // `testTheRegularLayoutOpensTheTownHallInTheDetailColumn`.
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone,
                      "D1 is the phone layout — run this method on an iPhone destination")

        // A reset launch (`-uiTestResetPersistedState` wipes `mm.native.lastChannel`) has nothing
        // saved. The owner's instruction says that launch lands on the team's town hall, so the
        // town-hall push is the *expected* destination — this file is its falsifier.
        let app = launchAndSignIn()

        // 1. The town hall's pane, pushed over the tab bar, with its own title.
        let pane = otherElement(app, "nativeChannelPane")
        XCTAssertTrue(pane.waitForExistence(timeout: 60),
                      "a launch with nothing saved must open the team's town hall — "
                      + "`LaunchDestination`'s fallback chain is what this asserts; a shell that "
                      + "stays on the channel list is the regression card t_295b0a32 was filed for:\n"
                      + app.debugDescription)
        let title = element(app, "nativeChannelTitle")
        XCTAssertTrue(title.waitForExistence(timeout: 15),
                      "the pushed pane must name the channel it opened:\n" + app.debugDescription)
        // The header starts as the slug the shell was handed and `loadChannelHeader()` replaces it
        // with the server's display name a beat later (T40's `ChannelPaneTitle`), so either spelling
        // is the right channel; a different channel is not.
        XCTAssertTrue(waitUntil(timeout: 30) {
            let label = title.exists ? title.label : ""
            return label == self.townHall.displayName || label == self.townHall.name
        }, "the launch must land on #\(townHall.name) / #\(townHall.displayName) (the team's "
           + "default), got '\(title.exists ? title.label : "nil")':\n" + app.debugDescription)
        attach(app, "t295-1-launch-opens-the-town-hall")

        // 2. The push covers the tab bar: the compact layout's stack sits above the TabView,
        //    exactly as upstream's `Stack` wraps `Tabs` (design doc: the bar slides off in a channel).
        //
        //    Mutation-tested (T95-A-AV F2): a per-tab stack — a `NavigationStack` *inside* the
        //    Channels tab instead of above the `TabView` — keeps the bar on screen under the channel
        //    pane, and the `app.tabBars.count == 0` below fails on it. So this is not an assertion
        //    that merely describes the current implementation; it reds on the one change it is about
        //    (`docs/t95a-av2-build-note.md` §2).
        let back = app.navigationBars.buttons["Back"]
        XCTAssertTrue(back.waitForExistence(timeout: 10),
                      "a pushed channel offers Back — on upstream too, its phone channel header "
                      + "carries the chevron:\n" + app.debugDescription)
        XCTAssertTrue(waitUntil(timeout: 10) { app.tabBars.count == 0 },
                      "the pushed pane covers the tab bar (upstream parity, D1); a tab bar still on "
                      + "screen here means someone changed the shell's structure — that is a "
                      + "deviation card, not a bug fix:\n" + app.debugDescription)
        attach(app, "t295-2-channel-covers-the-bar")

        // 3. Back → the bar is back, and no channel pane is left behind.
        back.tap()
        XCTAssertTrue(waitUntil(timeout: 30) { app.tabBars.firstMatch.exists },
                      "Back must return to the channel list with its tab bar:\n" + app.debugDescription)
        XCTAssertFalse(otherElement(app, "nativeChannelPane").exists,
                       "the popped destination must not stay in the hierarchy:\n" + app.debugDescription)
        attach(app, "t295-3-back-restores-the-bar")

        // 4. And opening the town hall by its own row still works: the fallback did not replace the
        //    reader's route to a conversation.
        let row = revealSidebarRow(app, identifier: "channelSidebar.channel.\(townHall.id)")
        XCTAssertTrue(row.waitForExistence(timeout: 40),
                      "the sidebar must list #\(townHall.name) so the test can open it:\n"
                      + app.debugDescription)
        row.tap()
        XCTAssertTrue(otherElement(app, "nativeChannelPane").waitForExistence(timeout: 40),
                      "tapping a sidebar row must push the channel pane:\n" + app.debugDescription)
        XCTAssertTrue(waitUntil(timeout: 30) {
            let label = title.exists ? title.label : ""
            return label == self.townHall.displayName || label == self.townHall.name
        }, "the pane must show the channel whose row was tapped (#\(townHall.name) / "
           + "#\(townHall.displayName)), got '\(title.exists ? title.label : "nil")'")
    }

    /// The **regular** half of the layout (`docs/t95-shell-tab-bar-decision.md` §3, D-1): a launch
    /// with nothing saved opens the team's town hall in the split view's **detail column**, and the
    /// shell stays on screen — the regular layout never pushes.
    ///
    /// `LastChannelLaunchTests` is layout-independent: it pins `LaunchDestination.resolve` and never
    /// which pane the shell renders. This method pins what the regular shell draws for that decision,
    /// so a split view that ignored the destination could not stay green.
    ///
    /// Runs on an iPad destination, landscape so both columns are on screen; skips on a phone
    /// destination, where the split view does not exist.
    func testTheRegularLayoutOpensTheTownHallInTheDetailColumn() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad,
                          "the regular half of the layout needs a regular-width destination (an iPad)")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }

        let app = launchAndSignIn()

        // The split view is the shell: it **stays** (nothing is pushed over it on regular width, so
        // `nativeShell` remains in the tree — on compact a pushed pane is what removes it).
        let shell = element(app, "nativeShell")
        XCTAssertTrue(waitUntil(timeout: 60) { shell.exists },
                      "the regular layout must keep the shell on screen — a launch that pushes a "
                      + "destination instead of selecting the detail column is the compact shape on "
                      + "the wrong device:\n" + app.debugDescription)

        // The detail column holds the town hall: the owner's "default to town hall" as the regular
        // layout renders it.
        let pane = otherElement(app, "nativeChannelPane")
        XCTAssertTrue(pane.waitForExistence(timeout: 60),
                      "a launch with nothing saved must select the team's town hall in the detail "
                      + "column, not leave it empty (card t_295b0a32):\n" + app.debugDescription)
        let title = element(app, "nativeChannelTitle")
        XCTAssertTrue(title.waitForExistence(timeout: 15),
                      "the detail column must name the channel it opened:\n" + app.debugDescription)
        XCTAssertTrue(waitUntil(timeout: 30) {
            let label = title.exists ? title.label : ""
            return label == self.townHall.displayName || label == self.townHall.name
        }, "the detail column must show #\(townHall.name) / #\(townHall.displayName), got "
           + "'\(title.exists ? title.label : "nil")':\n" + app.debugDescription)
        XCTAssertFalse(element(app, "nativeEmptyDestination").exists,
                       "the empty destination is exactly what a fallback launch must not draw:\n"
                       + app.debugDescription)

        // The sidebar column is on screen and lists the team's channels — that is the split view
        // being a *split* view, not a detail column stretched over the window. The column's own team
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

        attach(app, "t295-regular-launch-town-hall")
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

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
