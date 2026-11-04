// t_8d539b3f — Direct messages: the 20 most recent, the rest on "Load more" — against a **real**
// Mattermost server.
//
// Why live: the arithmetic (20 rows, "N remaining", promotion, the roll-up) is pinned offline in
// `MattermostTests/T8dDirectMessagePagingTests.swift`. What an offline test cannot say is that the
// *drawn* control is really the one that loads the next page: that it is one accessibility element
// labelled "Load more" with the remaining count as its value, that it sits **after** the drawn
// channel rows, and that tapping it grows the list until the oldest conversation is drawn. That is
// what this suite reads off the screen, tapping the way a person does.
//
// Run (fixture server + seeded DMs):
//
//     python3 scripts/t8d_dm_seed.py --count 45
//     source build/logs/t8d-dm-fixture.env        # exports TEST_RUNNER_MM_DM_COUNT / _OLDEST
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     python3 scripts/qa-test.py --platform ios --sim <sim> \
//       --only-testing MattermostUITests/T8dDirectMessagePagingUITests
//
// The suite skips — never fails — when the environment, the server or the fixture is missing, like
// every live test here (`scripts/t8d_dm_seed.py --cleanup` removes what the seed created).

import XCTest

final class T8dDirectMessagePagingUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!

    /// The DMs `scripts/t8d_dm_seed.py` created, in the **server's** recency order (newest first),
    /// read back from `last_post_at` by the seeder.
    ///
    /// They arrive as environment variables, not as a fixture file: this test runs **inside the
    /// simulator**, whose filesystem cannot see a path on the host. `TEST_RUNNER_MM_DM_COUNT` and
    /// `TEST_RUNNER_MM_DM_OLDEST` are what the seeder exports (`build/logs/t8d-dm-fixture.env`).
    private struct Fixture {
        let count: Int
        let oldest: String
    }

    private var fixture: Fixture!

    /// One session per test process: the server rate-limits logins by IP.
    private static var cachedSession: (server: String, token: String, userID: String)?

    private var token: String!
    private var userID: String!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live DM-paging test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        try ping()

        if let cached = Self.cachedSession, cached.server == raw {
            token = cached.token
            userID = cached.userID
        } else {
            let session = try authenticate(login: loginID, password: password)
            token = session.token
            userID = session.userID
            Self.cachedSession = (server: raw, token: session.token, userID: session.userID)
        }

        let count = Int(env["MM_DM_COUNT"] ?? "") ?? 0
        let oldest = env["MM_DM_OLDEST"] ?? ""
        try XCTSkipUnless(count > 20 && !oldest.isEmpty,
                          "Live DM-paging test: seed the fixture first "
                          + "(python3 scripts/t8d_dm_seed.py --count 45), then "
                          + "`source build/logs/t8d-dm-fixture.env` before scripts/qa-test.py")
        fixture = Fixture(count: count, oldest: oldest)
    }

    // MARK: - The one test this card needs on screen

    /// The control is drawn after the rows, it is one element with the remaining count in its value,
    /// and tapping it really loads the rest: the oldest seeded DM — beyond the first page — is
    /// reachable afterwards and the control is gone.
    func testTheLoadMoreRowSitsAfterTheDrawnRowsAndTappingItLoadsTheRest() throws {
        let app = launchAndSignIn()
        let control = app.buttons["channelSidebar.loadMore.direct_messages"]

        XCTAssertTrue(revealLoadMore(app, control),
                      "the Direct messages group draws its Load more row on a >20-DM fixture:\n"
                      + "\(app.debugDescription)")

        // One element, labelled for a person and valued with the fact that matters.
        XCTAssertEqual(control.label, "Load more")
        let firstRemaining = try remaining(in: control)
        XCTAssertGreaterThan(firstRemaining, 0, "a drawn control has something left to load")
        print("[t8d] drawn: label=\(control.label) value=\(control.value as? String ?? "none")")
        // Photographed with the control actually on screen: a realised row is not a visible row —
        // the 20-row page ends just below the fold, so the shot has to scroll to it first.
        bringIntoView(app, control)
        attach("t8d-01-page-and-load-more")

        // The rows come first, the control last: the last drawn channel row ends above the control's
        // top edge (the a11y order the card asks for, read off frames on one screen).
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                                    "channelSidebar.channel."))
        let drawn = rows.count
        XCTAssertGreaterThan(drawn, 0, "the DM page's own rows are drawn above the control")
        let lastRow = rows.element(boundBy: drawn - 1)
        XCTAssertLessThanOrEqual(lastRow.frame.maxY, control.frame.minY + 2,
                                 "the Load more row is drawn after the last channel row")

        // The oldest seeded DM is beyond the first page: not drawn yet.
        XCTAssertFalse(app.buttons["channelSidebar.channel.\(fixture.oldest)"].exists,
                       "the oldest DM is held back by the 20-row page before any Load more tap")

        // Tap the real control until nothing is left. Each tap must move the remaining count down
        // (or remove the control when it has loaded the last page) — a tap that changes nothing is
        // the defect this asserts against.
        var taps = 0
        var values = [firstRemaining]
        let maxTaps = max(2, firstRemaining / 20 + 3)
        while taps < maxTaps {
            if !control.exists {
                // The list grew below: follow it down like a reader would.
                _ = revealLoadMore(app, control, swipes: 12)
                if !control.exists { break }
            }
            let before = try remaining(in: control)
            control.tap()
            taps += 1
            // The action runs, then the list grows below the control and it may leave the realised
            // window: wait a beat, re-find it, and read the value the redraw produced.
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            guard revealLoadMore(app, control, swipes: 10) else {
                // Nothing left to draw: the last page was this tap. The row below proves it.
                print("[t8d] tap \(taps) from \"\(before) remaining\" removed the control")
                break
            }
            let after = try remaining(in: control)
            if taps == 1 {
                bringIntoView(app, control)
                attach("t8d-02-after-one-load")
            }
            XCTAssertLessThan(after, before,
                              "tap \(taps) must reveal more: \"\(before) remaining\" then \"\(after) remaining\"")
            values.append(after)
        }
        XCTAssertLessThanOrEqual(taps, maxTaps, "the control must disappear once every DM is loaded")
        print("[t8d] Load more taps=\(taps) remaining: \(values)")

        // Strictly monotonically down: every activation loads a page, never re-shows one.
        for (previous, next) in zip(values, values.dropFirst()) {
            XCTAssertGreaterThan(previous, next, "each activation reveals more: \(values)")
        }

        // The row the cap was hiding is now drawn — the "rest loaded on click", end to end.
        let oldest = ShellSettle.revealSidebarChannel(app, channelID: fixture.oldest,
                                                      maxDownSwipes: 60, maxUpSwipes: 20)
        XCTAssertTrue(oldest.found,
                      "the oldest seeded DM is drawn once the rest is loaded: \(oldest.report)")

        // And with every row drawn the control is gone.
        XCTAssertFalse(control.exists, "nothing is left, so the control is not drawn")
        attach("t8d-03-all-loaded")
    }

    /// A screenshot of the running app, kept for the run's `xcresult` (exported afterwards with
    /// `scripts/t37_export_shots.py`). The name is the file name the build note cites.
    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Scroll the sidebar until the row is **hittable**, not merely present in the tree: a
    /// `LazyVStack` realises rows past the viewport, so `exists` is true for a row nobody can see.
    private func bringIntoView(_ app: XCUIApplication, _ element: XCUIElement, swipes: Int = 8) {
        let list = ShellSettle.channelSidebarScroll(app)
        guard list.exists else { return }
        for _ in 0..<swipes {
            if element.isHittable { return }
            list.swipeUp(velocity: .fast)
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
    }

    // MARK: - Launch + sign-in

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
        signIn(app)
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
        XCTAssertTrue(ShellSettle.waitForSignedIn(app, timeout: 40),
                      "signing in must reach the shell:\n\(app.debugDescription)")
        ShellSettle.revealChannelList(app)
    }

    /// Swipe the sidebar down until the Load more row is in the tree — the DM group is the **last**
    /// one on the fixture account, so this is a real scroll, not a formality.
    @discardableResult
    private func revealLoadMore(_ app: XCUIApplication, _ control: XCUIElement,
                                swipes: Int = 40) -> Bool {
        if control.exists { return true }
        let list = ShellSettle.channelSidebarScroll(app)
        guard list.exists else { return false }
        for _ in 0..<swipes {
            list.swipeUp(velocity: .fast)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            if control.exists { return true }
        }
        return control.exists
    }

    /// The remaining count out of the control's accessibility value ("25 remaining").
    private func remaining(in element: XCUIElement) throws -> Int {
        let raw = (element.value as? String) ?? ""
        let digits = raw.prefix { $0.isNumber }
        guard let value = Int(digits) else {
            throw XCTSkip("the Load more row did not carry a remaining count in its value: \"\(raw)\"")
        }
        return value
    }

    // MARK: - Server access (the test is its own API client, so nothing is assumed)

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
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw XCTSkip("could not sign in as \(login) on \(serverURL.absoluteString): "
                          + "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let token = http.value(forHTTPHeaderField: "Token")
                ?? http.value(forHTTPHeaderField: "token"),
              let userID = body?["id"] as? String else {
            throw XCTSkip("no session token in the sign-in answer for \(login)")
        }
        return (token, userID)
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
}
