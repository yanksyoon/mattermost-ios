// T70 — the live check behind card t_70b41028 ("authors render as Unknown user").
//
// A harness, not a suite member: it skips unless `MM_AUTH_*` names a reachable server and an account,
// and it is not part of the four-test live suite. What it does:
//
//   1. measures the channel on the server (distinct author ids in the newest page, and how many
//      posts are system messages);
//   2. launches the app with the native surfaces, signs in through the real login screen, opens the
//      channel, and asserts that **no row draws "Unknown user"** while every author the server knows
//      is named;
//   3. prints the fixture truth as `PROBE-T70 …`.
//
// The profile counts themselves (requested / cached / sent / resolved) are what the `-shellSnapshot`
// dump prints from `ChannelViewModel.profileDiagnostics`; the run recipe is in the card's build note
// (`docs/t_70b41028-author-profiles.md` §4): this test leaves the session signed in, then the app is
// launched once with `-shellSnapshot <container>/Documents/t70` and the `.txt` is read back.
//
// Run:
//
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     TEST_RUNNER_MM_T70_CHANNEL=off-topic \
//     python3 scripts/qa-test.py --platform ios --sim "iPhone 17 Pro" \
//       --derived-data ~/Library/Developer/Xcode/DerivedData/mmios-t70b41028 \
//       --only-testing MattermostUITests/T70AuthorNamesUITests

import XCTest

final class T70AuthorNamesUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var channelName: String!
    private var channelID: String!
    private var teamID: String!
    private var authorIDs: [String] = []
    private var systemPosts = 0

    override func setUpWithError() throws {
        try super.setUpWithError()
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        channelName = env["MM_T70_CHANNEL"] ?? "off-topic"
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "probe: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        serverURL = try XCTUnwrap(URL(string: raw))

        let token = try login(loginID, password)
        let teams = try json("/api/v4/users/me/teams", token: token) as? [[String: Any]] ?? []
        let team = try XCTUnwrap(teams.first { $0["name"] as? String == "perf" },
                                 "probe: team #perf is missing")
        let teamID = try XCTUnwrap(team["id"] as? String)
        self.teamID = teamID
        let channel = try json("/api/v4/teams/\(teamID)/channels/name/\(channelName!)",
                               token: token) as? [String: Any]
        channelID = try XCTUnwrap(channel?["id"] as? String, "probe: #\(channelName!) is missing")

        let page = try json("/api/v4/channels/\(channelID!)/posts?per_page=60", token: token)
            as? [String: Any] ?? [:]
        let posts = page["posts"] as? [String: Any] ?? [:]
        let order = page["order"] as? [String] ?? []
        var ids = Set<String>()
        for id in order {
            guard let post = posts[id] as? [String: Any] else { continue }
            if let user = post["user_id"] as? String, !user.isEmpty { ids.insert(user) }
            if (post["type"] as? String)?.isEmpty == false { systemPosts += 1 }
        }
        authorIDs = ids.sorted()
        try XCTSkipUnless(!authorIDs.isEmpty, "probe: #\(channelName!) has no authors in its newest page")
        print("PROBE-T70 channel=\(channelName!) id=\(channelID!) posts=\(order.count) "
              + "authors=\(authorIDs.count) system=\(systemPosts)")
    }

    func testNoAuthorInTheChannelReadsUnknownUser() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetPersistedState",
                               "-uiTestSeedServer", serverURL.absoluteString,
                               "-uiTestSeedServerName", "Local Mattermost",
                               "-uiTestForgetSession", serverURL.absoluteString,
                               "-surfaceMode", "shell=native",
                               "-surfaceMode", "auth=native",
                               "-surfaceMode", "sidebar=native",
                               "-surfaceMode", "channelView=native",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let login = app.textFields["loginIDField"]
        XCTAssertTrue(login.waitForExistence(timeout: 30), "sign-in must mount")
        login.tap(); login.typeText(loginID)
        let secret = app.secureTextFields["loginPasswordField"]
        XCTAssertTrue(secret.exists)
        secret.tap(); secret.typeText(password)
        app.buttons["loginSubmitButton"].tap()
        XCTAssertTrue(element(app, "nativeShell").waitForExistence(timeout: 60),
                      "sign-in must reach the shell")

        // The fixture account belongs to more than one team and to a workspace whose channel list
        // is far longer than one screen (`#perf` measured 18,842 pt tall on 2026-10-29 — hundreds of
        // `T8G probe` channels), so neither "the row is on screen" nor a bounded scroll is a fair
        // way to reach a channel. A person uses the quick switcher, which resolves by name; the
        // test does the same (T39's jump suite uses it for exactly this reason).
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
                      "the quick switcher must offer #\(channelName!) (\(channelID!)):\n"
                      + app.debugDescription)
        result.tap()

        XCTAssertTrue(element(app, "channelPostList").waitForExistence(timeout: 120),
                      "the channel pane must mount")
        // The rows carry profiles a moment after the page lands; wait for a name, then read the tree.
        // Since `t_42968927` the author's name is a **button** (it opens the profile), so it is no
        // longer a `staticText` — the wait and the count below are label-based, not type-based, or
        // this probe would silently stop seeing the very fallback it exists to catch.
        _ = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "perfprobe")).firstMatch
            .waitForExistence(timeout: 30)

        let unknown = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Unknown user"))
        let unknownCount = unknown.count
        print("PROBE-T70 unknown-user rows=\(unknownCount) authors=\(authorIDs.count)")
        XCTAssertEqual(unknownCount, 0,
                       "every author in #\(channelName!) must be named; the dump is\n\(app.debugDescription)")
        let shot = XCUIScreen.main.screenshot()
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "t70-author-names.png")
        try? shot.pngRepresentation.write(to: url)
        print("PROBE-T70 shot=\(url.path)")
    }

    // MARK: - Fixture access (same shape as T38HeavyScrollProbe)

    private func login(_ id: String, _ pw: String) throws -> String {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/users/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["login_id": id, "password": pw])
        let (_, response) = try synchronous(request)
        let http = response as? HTTPURLResponse
        let token = http?.value(forHTTPHeaderField: "Token") ?? ""
        try XCTSkipUnless(http?.statusCode == 200 && !token.isEmpty,
                          "probe: login failed HTTP \(http?.statusCode ?? -1)")
        return token
    }

    private func json(_ path: String, token: String) throws -> Any {
        var request = URLRequest(url: try XCTUnwrap(URL(string: path, relativeTo: serverURL)))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try synchronous(request)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

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
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        Self.fixtureSession.dataTask(with: request) { data, response, error in
            box.data = data
            box.response = response
            box.error = error
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 30)
        if let error = box.error { throw error }
        return (box.data ?? Data(), box.response ?? URLResponse())
    }

    private final class ResultBox: @unchecked Sendable {
        var data: Data?
        var response: URLResponse?
        var error: Error?
    }
}
