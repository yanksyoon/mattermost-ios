// T56 perf harness (card t_38e0eac6, T6) — the 200-post scroll A/B, measured, not assumed.
//
// This is a harness, not a suite member (it skips rather than fails when the fixture or credentials
// are absent). It scrolls the same 200-post channel six times in ONE build, in one of two arms:
//
//   TEST_RUNNER_T56_PERF_ARM=native   -> the shipped surface (one selectable UITextView per body)
//   TEST_RUNNER_T56_PERF_ARM=legacy   -> `-uiTestLegacyBlockBody`, the per-block `Text` body it replaced
//
// and prints PROBE-START / PROBE-PASS-<n> / PROBE-END epoch stamps. `scripts/t56_perf_sample.sh`
// samples the app process's RSS alongside it; the delta between the two arms on the same host,
// device and build is the regression number the card asks for. There is no frame-time instrument in
// this repo (verified: no CADisplayLink / hitch collector anywhere), so the harness reports RSS plus
// each pass's wall time — it does not invent a frame-time number.
//
// Fixture: `scripts/t56_perf_seed.py --posts 200` (#t56-perf). Channel name can be overridden with
// TEST_RUNNER_T56_PERF_CHANNEL.

import XCTest

final class T56PerfProbeUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var channelID: String!
    private var channelName: String!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        channelName = env["T56_PERF_CHANNEL"] ?? "t56-perf"
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "probe: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        serverURL = try XCTUnwrap(URL(string: raw))
        token = try login()
        let teams = try json("/api/v4/users/me/teams") as? [[String: Any]] ?? []
        guard let team = teams.first, let teamID = team["id"] as? String else {
            throw XCTSkip("probe: the account has no team")
        }
        let channel = try json("/api/v4/teams/\(teamID)/channels/name/\(channelName!)") as? [String: Any]
        guard let id = channel?["id"] as? String else {
            throw XCTSkip("probe: #\(channelName!) is missing — run scripts/t56_perf_seed.py")
        }
        channelID = id
    }

    func testScrollingTwoHundredPosts() throws {
        let arm = ProcessInfo.processInfo.environment["T56_PERF_ARM"] ?? "native"
        var arguments = ["-uiTestResetPersistedState",
                         "-uiTestForgetSession", serverURL.absoluteString,
                         "-uiTestSeedServer", serverURL.absoluteString,
                         "-uiTestSeedServerName", "Local Mattermost",
                         "-surfaceMode", "shell=native",
                         "-surfaceMode", "auth=native",
                         "-surfaceMode", "sidebar=native",
                         "-surfaceMode", "composer=native",
                         "-uiTestLogLevel", "error",
                         "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if arm == "legacy" { arguments.append("-uiTestLegacyBlockBody") }

        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"
        app.launch()
        print("PROBE-ARM \(arm)")

        signIn(app)
        openChannel(app)

        let list = app.descendants(matching: .any).matching(identifier: "channelPostList").firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 45), "the channel pane must mount")

        print("PROBE-START \(Date().timeIntervalSince1970)")
        for pass in 1...6 {
            let started = Date()
            for _ in 0..<4 { list.swipeUp(velocity: .fast) }
            for _ in 0..<4 { list.swipeDown(velocity: .fast) }
            print("PROBE-PASS-\(pass) \(Int(Date().timeIntervalSince1970 * 1000)) "
                  + "seconds=\(String(format: "%.2f", Date().timeIntervalSince(started)))")
            waitForQuiet()
        }
        print("PROBE-END \(Date().timeIntervalSince1970)")

        XCTAssertTrue(list.exists, "the list must still render after 200-post scroll passes")
    }

    // MARK: - Driving

    private func waitForQuiet() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    }

    private func signIn(_ app: XCUIApplication) {
        let field = app.textFields["loginIDField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "sign-in must mount")
        field.tap()
        field.typeText(loginID)
        let secret = app.secureTextFields["loginPasswordField"]
        secret.tap()
        secret.typeText(password)
        app.buttons["loginSubmitButton"].tap()
        XCTAssertTrue(ShellSettle.waitForSignedIn(app, timeout: 40), "signing in must reach the shell")
    }

    private func openChannel(_ app: XCUIApplication) {
        ShellSettle.revealChannelList(app)
        let quick = app.descendants(matching: .any).matching(identifier: "channelSidebar.quickSwitcher").firstMatch
        if !quick.waitForExistence(timeout: 20) {
            let toggle = app.navigationBars.buttons["ToggleSidebar"]
            if toggle.waitForExistence(timeout: 10) { toggle.tap() }
        }
        XCTAssertTrue(quick.waitForExistence(timeout: 40), "the quick switcher must be offered")
        quick.tap()
        let field = app.descendants(matching: .any)
            .matching(identifier: "channelSidebar.quickSwitcher.field").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText(channelName)
        let result = app.descendants(matching: .any)
            .matching(identifier: "channelSidebar.quickSwitcher.result.\(channelID!)").firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 25), "the quick switcher must find #\(channelName!)")
        result.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "channelPostList")
            .firstMatch.waitForExistence(timeout: 45), "the channel pane must mount")
    }

    // MARK: - Server

    private func login() throws -> String {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/users/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["login_id": loginID!,
                                                                       "password": password!])
        let (_, response) = try synchronous(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let token = http.value(forHTTPHeaderField: "Token") else {
            throw XCTSkip("probe: login failed")
        }
        return token
    }

    private func json(_ path: String) throws -> Any {
        var request = URLRequest(url: serverURL.appendingPathComponent(path))
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        let (data, _) = try synchronous(request)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func synchronous(_ request: URLRequest) throws -> (Data, URLResponse) {
        let expectation = expectation(description: "http \(request.url?.path ?? "")")
        var result: Result<(Data, URLResponse), Error>?
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { result = .failure(error) }
            else { result = .success((data ?? Data(), response ?? URLResponse())) }
            expectation.fulfill()
        }.resume()
        wait(for: [expectation], timeout: 20)
        return try result!.get()
    }
}
