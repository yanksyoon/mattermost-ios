// t_ddf85143 — every modal close must close **its own** presentation.
//
// The card: "Tapping Cancel in the post options sheet does not close it; the same is true of several
// other modals' Done/Cancel." The report names one control and then says the class is wider, so this
// file measures the class: one launch, one assertion per modal close, each naming the control that
// failed to dismiss. Nothing in this repo tapped any of these before — the modal surfaces were only
// ever reached *through* (edit navigates to the composer, react queues the picker), so a close button
// that cannot close was invisible to the suite.
//
// What each case means:
//
//   postOptions.cancel        a sheet presented by `.sheet(item:)`, whose close is an `onDismiss`
//                             closure that clears the item (`ChannelPostListView.sheet`).
//   channelInfo.done          a sheet presented by `.sheet(isPresented:)`, whose close is
//                             `@Environment(\.dismiss)` read by the sheet's own root.
//   pinnedClose               a second `.sheet(isPresented:)` on the **same** view as channel info
//                             (`ChannelPaneContent.body` chains three), closed through an `onClose`
//                             closure.
//   profile.done              an item-bound sheet on the same view as the two above.
//   emojiPicker.close         a sheet presented from the composer, closed through `dismiss()`.
//   addMembers.cancel         a sheet presented **from inside another sheet**; dismissing it must
//                             leave the channel-info sheet underneath it up.
//
// Fixture: team `perf`, channel `t36-threads` (`scripts/perf_seed.py`, `scripts/t36_thread_seed.py`),
// the server at `TEST_RUNNER_MM_AUTH_SERVER`. Every case skips (never fails) when the fixture or the
// environment is missing.
//
// Run:
//
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=<fixture> TEST_RUNNER_MM_AUTH_PASSWORD=<fixture> \
//     python3 scripts/qa-test.py --platform ios --sim "iPhone 17 Pro" \
//       --only-testing MattermostUITests/TModalDismissUITests

import XCTest

final class TModalDismissUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var userID: String!
    private var teamID: String!
    private var channelID: String!

    private let channelName = "t36-threads"
    private let channelDisplayName = "T36 Threads"

    /// Every close this run pressed, and whether the thing it closed actually went away.
    private var outcomes: [(control: String, closed: Bool)] = []
    private var app: XCUIApplication?

    override func setUpWithError() throws {
        addTeardownBlock { [weak self] in
            guard let self, let app = self.app, app.state != .notRunning,
                  (self.testRun?.totalFailureCount ?? 0) > 0 else { return }
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "modal-dismiss-failure-\(self.name)"
            shot.lifetime = .keepAlways
            self.add(shot)
        }
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live modal test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url

        var ping = URLRequest(url: url.appendingPathComponent("api/v4/system/ping"))
        ping.timeoutInterval = 5
        let (_, pingResponse) = try synchronous(ping)
        try XCTSkipUnless((pingResponse as? HTTPURLResponse)?.statusCode == 200,
                          "the live server at \(url.absoluteString) is not answering")

        let session = try authenticate(login: loginID, password: password)
        token = session.token
        userID = session.userID
        guard let team = try teamsForMe().first(where: { $0["name"] as? String == "perf" }) else {
            throw XCTSkip("team #perf is missing — run scripts/perf_seed.py")
        }
        teamID = team["id"] as? String
        guard let channel = try getJSON("/api/v4/teams/\(teamID!)/channels/name/\(channelName)",
                                        token: token) as? [String: Any],
              let id = channel["id"] as? String else {
            throw XCTSkip("channel #\(channelName) is missing — run scripts/t36_thread_seed.py")
        }
        channelID = id
    }

    // MARK: - The matrix

    func testEveryModalCloseClosesItsOwnSheet() throws {
        let app = try launchOnFixtureChannel()

        // 1. A post's options sheet, closed by its own Cancel (the reported control).
        let stamp = Int(Date().timeIntervalSince1970)
        let postID = try createPost(message: "modal dismiss \(stamp)")
        XCTAssertTrue(revealPost(app, postID).waitForExistence(timeout: 30),
                      "the fixture post must be a row of the presented channel:\n\(app.debugDescription)")
        openMenu(app, postID: postID)
        record("postOptions.cancel",
               close: element(app, "postOptions.cancel"),
               goneWhen: { !self.element(app, "postOptions.cancel").exists },
               on: app)

        // 2. Channel info, closed by its own Done (`dismiss()` inside the sheet's root).
        tap(element(app, "nativeChannelInfoButton"), expecting: "channelInfo.sheet", on: app)
        record("channelInfo.done",
               close: element(app, "channelInfo.done"),
               goneWhen: { !self.element(app, "channelInfo.sheet").exists },
               on: app)

        // 3. Pinned messages — a second `.sheet(isPresented:)` on the same view as channel info.
        tap(element(app, "nativeChannelPinnedButton"), expecting: "pinnedSheet", on: app)
        record("pinnedClose",
               close: element(app, "pinnedClose"),
               goneWhen: { !self.element(app, "pinnedSheet").exists },
               on: app)

        // 4. The profile popover — an item-bound sheet on that same view.
        tap(element(app, "nativeProfileButton"), expecting: "profileSheet", on: app)
        record("profile.done",
               close: element(app, "profile.done"),
               goneWhen: { !self.element(app, "profileSheet").exists },
               on: app)

        // 5. The emoji picker, presented from the composer.
        tap(element(app, "channelComposer.emoji"), expecting: "emojiPicker", on: app)
        record("emojiPicker.close",
               close: element(app, "emojiPicker.close"),
               goneWhen: { !self.element(app, "emojiPicker").exists },
               on: app)

        // 6. A sheet presented from inside another sheet: dismissing it must leave the channel-info
        //    sheet underneath it up, and then channel info must close normally.
        tap(element(app, "nativeChannelInfoButton"), expecting: "channelInfo.sheet", on: app)
        tap(element(app, "channelInfo.action.addMembers"), expecting: "addMembers.sheet", on: app)
        record("addMembers.cancel",
               close: element(app, "addMembers.cancel"),
               goneWhen: { !self.element(app, "addMembers.sheet").exists },
               on: app)
        XCTAssertTrue(element(app, "channelInfo.sheet").exists,
                      "closing the add-people sheet must not close the channel-info sheet underneath "
                      + "it:\n\(app.debugDescription)")
        record("channelInfo.done (after nested)",
               close: element(app, "channelInfo.done"),
               goneWhen: { !self.element(app, "channelInfo.sheet").exists },
               on: app)

        // 7. The *other* item in that one slot: pinned, opened from inside channel info. Same slot,
        //    different item — the case a second `.sheet` modifier used to shadow.
        tap(element(app, "nativeChannelInfoButton"), expecting: "channelInfo.sheet", on: app)
        let pinnedRow = revealInChannelInfo(app, "channelInfo.action.pinned")
        tap(pinnedRow, expecting: "pinnedSheet", on: app)
        record("pinnedClose (from channel info)",
               close: element(app, "pinnedClose"),
               goneWhen: { !self.element(app, "pinnedSheet").exists },
               on: app)
        XCTAssertTrue(element(app, "channelInfo.sheet").exists,
                      "closing pinned must leave the channel-info sheet underneath it up:\n"
                      + app.debugDescription)
        record("channelInfo.done (after pinned)",
               close: element(app, "channelInfo.done"),
               goneWhen: { !self.element(app, "channelInfo.sheet").exists },
               on: app)

        // The verdict, per control, so a red run names the one that failed rather than "a modal".
        for outcome in outcomes {
            XCTAssertTrue(outcome.closed, "\(outcome.control) did not close its modal")
        }
        print("MODAL-DISMISS MATRIX " + outcomes.map { "\($0.control)=\($0.closed ? "closed" : "STUCK")" }
            .joined(separator: " "))
    }

    // MARK: - One close

    /// Tap a close control and record whether what it closes went away.
    ///
    /// A stuck modal is *recovered* from — a sheet can be swiped down — so the next case measures the
    /// next control instead of measuring the previous failure. The recovery is never silent: the
    /// outcome is already recorded, and the recovery itself is printed.
    private func record(_ control: String, close: XCUIElement,
                        goneWhen: @escaping () -> Bool, on app: XCUIApplication) {
        guard close.waitForExistence(timeout: 15) else {
            outcomes.append((control, false))
            print("MODAL-CLOSE \(control): the close control never appeared")
            app.swipeDown(velocity: .fast)
            return
        }
        close.tap()
        let closed = waitUntil(timeout: 10, goneWhen)
        outcomes.append((control, closed))
        print("MODAL-CLOSE \(control): \(closed ? "closed" : "STUCK")")
        if !closed {
            // Down on the sheet itself: a sheet that ignores its own button usually still responds to
            // a drag. If it does not, nothing more can be measured and the next tap will say so.
            app.swipeDown(velocity: .fast)
            _ = waitUntil(timeout: 5, goneWhen)
        }
    }

    /// Tap an opener and wait for the thing it should present.
    private func tap(_ opener: XCUIElement, expecting identifier: String, on app: XCUIApplication) {
        XCTAssertTrue(opener.waitForExistence(timeout: 20),
                      "\(identifier)'s opener must be in the tree:\n\(app.debugDescription)")
        opener.tap()
        XCTAssertTrue(element(app, identifier).waitForExistence(timeout: 25),
                      "\(identifier) must be presented by its opener:\n\(app.debugDescription)")
    }

    // MARK: - The reported configuration

    /// The launch a reader actually gets: `app.launchArguments = []`.
    ///
    /// The matrix test forces every surface native, which proves the closes work when the native
    /// sheet is the one that presented. The report came from the shipped app, so the control is
    /// measured again there — the session is restored from the vault rather than seeded, and the
    /// surfaces resolve to their own defaults.
    func testTheOptionsCancelClosesInTheShippedConfiguration() throws {
        // One seed launch, only to put a session in the vault. Then the app is a reader's app.
        var app = try launchOnFixtureChannel()
        app.terminate()

        app = XCUIApplication()
        app.launchArguments = []
        self.app = app
        app.launch()
        if app.textFields["loginIDField"].waitForExistence(timeout: 20) {
            signIn(app)
        }
        // Readiness is the shell's *content*, not its root identifier: `nativeShell` is measured
        // absent on the shipped launch while the channel pane and the sidebar are both up (this
        // test's own red line, `build/logs/tdf85143-shipped3.log`), so keying on it fails a launch
        // that is working. Either the channel list or the sidebar's quick switcher is the state
        // `landOnFixtureChannel` needs anyway.
        let ready = element(app, "channelPostList").waitForExistence(timeout: 60)
            || element(app, "channelSidebar.quickSwitcher").waitForExistence(timeout: 20)
        XCTAssertTrue(ready,
                      "the shipped launch must be signed in and showing the channel shell:\n"
                      + app.debugDescription)
        landOnFixtureChannel(app)

        let postID = try createPost(message: "modal dismiss shipped "
                                        + "\(Int(Date().timeIntervalSince1970))")
        XCTAssertTrue(revealPost(app, postID).waitForExistence(timeout: 30),
                      "the fixture post must be a row of the presented channel:\n\(app.debugDescription)")
        let menu = element(app, "post.\(postID).menu")
        try XCTSkipUnless(menu.waitForExistence(timeout: 20),
                          "the shipped configuration draws no native row menu — nothing to measure")
        menu.tap()
        try XCTSkipUnless(element(app, "postOptions.cancel").waitForExistence(timeout: 25),
                          "the shipped configuration did not present the native options sheet")

        record("postOptions.cancel (shipped)",
               close: element(app, "postOptions.cancel"),
               goneWhen: { !self.element(app, "postOptions.cancel").exists },
               on: app)
        for outcome in outcomes {
            XCTAssertTrue(outcome.closed,
                          "\(outcome.control) did not close its modal on the shipped launch")
        }
        print("MODAL-DISMISS SHIPPED MATRIX "
              + outcomes.map { "\($0.control)=\($0.closed ? "closed" : "STUCK")" }.joined(separator: " "))
    }

    // MARK: - Fixture

    private func createPost(message: String) throws -> String {
        let json = try postJSON("/api/v4/posts",
                                body: ["channel_id": channelID as String, "message": message],
                                token: token)
        guard let post = json as? [String: Any], let id = post["id"] as? String else {
            throw XCTSkip("the server refused the fixture post")
        }
        return id
    }

    // MARK: - App helpers

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
                               "-surfaceMode", "channelInfo=native",
                               "-surfaceMode", "composer=native",
                               "-surfaceMode", "search=native",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        if app.textFields["loginIDField"].waitForExistence(timeout: 15) {
            signIn(app)
        }
        // Since `t_295b0a32` a signed-in launch opens a channel and pushes it over the list, so
        // `nativeShell` is absent and only the pane is in the tree (t_9399c0b4).
        // `ShellSettle.waitForSignedIn` answers for the list, the pushed pane and the tab bar;
        // `landOnFixtureChannel` below pops the push itself (`Back`).
        XCTAssertTrue(ShellSettle.waitForSignedIn(app, timeout: 45),
                      "the app must reach the native shell (signed in):\n\(app.debugDescription)")
        landOnFixtureChannel(app)
        return app
    }

    /// Get from wherever the shell came up onto `#t36-threads`, through the app's own controls.
    ///
    /// Idempotent: an app that is already on the channel (a restored location, the shipped launch)
    /// passes through in one check instead of walking the quick switcher again.
    private func landOnFixtureChannel(_ app: XCUIApplication) {
        if element(app, "channelPostList").exists,
           element(app, "nativeChannelTitle").label == channelDisplayName {
            return
        }
        if !element(app, "channelPostList").waitForExistence(timeout: 8) {
            tapBackIfPossible(app)
        }
        // The quick switcher is a row **of the channel list**, and a pushed pane draws `channelPostList`
        // — so "the post list is absent" is the wrong test for "the list is on show" (measured,
        // `t9399c0b4`: "the sidebar must offer the quick switcher" with "Town Square" pushed over it).
        _ = ShellSettle.revealChannelList(app)
        let current = element(app, "sidebarCurrentTeam")
        if current.exists, !current.label.localizedCaseInsensitiveContains("perf") {
            let rail = element(app, "teamSidebar.team.\(teamID!)")
            XCTAssertTrue(rail.waitForExistence(timeout: 15),
                          "the team rail must offer #perf:\n\(app.debugDescription)")
            rail.tap()
            _ = element(app, "channelPostList").waitForExistence(timeout: 30)
        }
        if !element(app, "channelSidebar.quickSwitcher").waitForExistence(timeout: 10) {
            // Switching the rail into #perf pushed that team's default channel: pop it the same way.
            _ = ShellSettle.revealChannelList(app)
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
        XCTAssertEqual(element(app, "nativeChannelTitle").label, channelDisplayName,
                       "the switcher must land on #\(channelName), not another channel")
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
        // Two taps, a beat apart: on a fresh iPad simulator the first tap can land while the form is
        // still settling and leaves nothing focused, after which `typeText` fails with "Neither
        // element nor any descendant has keyboard focus" (measured on `AV33 iPad Pro 11 M5`). On a
        // field that is already focused the second tap is a no-op.
        field.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        field.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        field.typeText(loginID)
        let secret = app.secureTextFields["loginPasswordField"]
        XCTAssertTrue(secret.waitForExistence(timeout: 10))
        secret.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        secret.typeText(password)
        app.buttons["loginSubmitButton"].tap()
    }

    /// Open a row's options sheet and expand it, so a row below the `.medium` fold is still reachable
    /// (T48-AV-R5 measured a synthesized tap at the bottom row landing on the row above it).
    private func openMenu(_ app: XCUIApplication, postID: String) {
        let menu = element(app, "post.\(postID).menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 25),
                      "the row must expose its options button:\n\(app.debugDescription)")
        menu.tap()
        XCTAssertTrue(element(app, "postOptions.cancel").waitForExistence(timeout: 25),
                      "the options sheet must open:\n\(app.debugDescription)")
        app.swipeUp()
    }

    /// A row of the channel-info list that may be below the fold. The list is the sheet's content, so
    /// the scrolls go to the sheet.
    private func revealInChannelInfo(_ app: XCUIApplication, _ identifier: String,
                                     maxSwipes: Int = 6) -> XCUIElement {
        let target = element(app, identifier)
        guard !(target.exists && target.isHittable) else { return target }
        let sheet = element(app, "channelInfo.sheet")
        var swipes = 0
        while !(target.exists && target.isHittable), swipes < maxSwipes {
            sheet.swipeUp(velocity: .fast)
            swipes += 1
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

    // MARK: - Server access (the test is its own API client)

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
        let token = http?.value(forHTTPHeaderField: "Token") ?? (body?["token"] as? String)
        guard http?.statusCode == 200, let token, let id = body?["id"] as? String else {
            throw XCTSkip("could not sign in as \(login) on the live server")
        }
        return Session(token: token, userID: id)
    }

    private func teamsForMe() throws -> [[String: Any]] {
        try getJSON("/api/v4/users/me/teams", token: token) as? [[String: Any]] ?? []
    }

    private func getJSON(_ path: String, token: String) throws -> Any {
        var request = URLRequest(url: serverURL.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try synchronous(request)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func postJSON(_ path: String, body: Any?, token: String) throws -> Any {
        var request = URLRequest(url: serverURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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

    /// This suite's own REST session — **no cookie store** (a stale `MMAUTHTOKEN` makes a correct
    /// login answer 401; see `T47CreateChannelAVUITests.restSession`).
    private func synchronous(_ request: URLRequest) throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var result: (Data, URLResponse)?
        var failure: Error?
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, error in
            if let error { failure = error }
            if let data, let response { result = (data, response) }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 30)
        if let failure { throw failure }
        guard let result else { throw XCTSkip("the request to \(request.url?.absoluteString ?? "?") "
                                              + "timed out") }
        return result
    }
}
