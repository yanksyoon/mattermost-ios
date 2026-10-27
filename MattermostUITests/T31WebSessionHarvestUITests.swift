import XCTest

/// T31 (follow-up) — **a session made in the webview must be the native shell's session**, against a
/// real Mattermost server.
///
/// The user-visible claim this suite exists for: sign in through the web view (Path A's own login, or
/// the SSO/SAML hand-off that deliberately stays there), then use the native shell — and the shell
/// renders the workspace, not the sign-in screen. Before the harvest landed, the second half of that
/// sentence was false: the webview held an `HttpOnly` `MMAUTHTOKEN` and the native transport held
/// nothing, so every native surface was unauthenticated while the user was plainly signed in.
///
/// Why a live suite: the state under test is a **cookie in WebKit's store plus a session on the
/// server**. A stub could only prove that the client renders what the test author already decided.
/// Here the token comes from the server's own `POST /users/login`, the channel rows that must appear
/// are read back from the server's own API, and the app reaches them with no native sign-in form and
/// no vault token at launch.
///
/// The second test is the **negative control**: the same launch without the cookie must still show
/// the native sign-in surface. Without it, the first test's green would not distinguish "the harvest
/// worked" from "the gate never asked".
///
/// Run (the fixture server is the local throwaway one; credentials live in `scripts/perf_seed.py`):
///
///     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
///     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
///     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
///     python3 scripts/qa-test.py --platform ios --sim id=81A7F251-8B31-4945-8783-5A264C14B8D5 \
///       --only-testing MattermostUITests/T31WebSessionHarvestUITests --label t31harvest-live
///
/// Each test skips (never fails) when the env or the server is missing, like every live test here.
final class T31WebSessionHarvestUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!

    /// A cookie-free session for this test's own API calls.
    ///
    /// `URLSession.shared` keeps a cookie jar that outlives a test run (the runner's container is
    /// reused), so an earlier `MMAUTHTOKEN` for the fixture host is presented on *every* request —
    /// and the server answers a login carrying a revoked session with `session_expired` before the
    /// credentials are ever looked at. Measured here: `POST /users/login` 401
    /// `api.context.session_expired.app_error` from the test process while the same request from
    /// `curl` answered 200. Ephemeral, no cookie storage, nothing inherited.
    private lazy var api: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    /// The channel ids the fixture account is a member of in the team the shell opens on: the rows
    /// that prove the channel list loaded with the harvested session rather than sitting on
    /// "Loading channels…".
    private var memberIDs: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live webview-session test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        try ping()
        let token = try authenticate()
        memberIDs = try memberChannels(token: token).map(\.id)
        try XCTSkipUnless(!memberIDs.isEmpty,
                          "the fixture account is a member of no channel in its first team")
    }

    // MARK: - The card

    /// A launch whose **only** credential is the webview's `MMAUTHTOKEN` reaches the workspace.
    func testAWebviewOnlySessionRendersTheNativeWorkspaceWithoutSigningInAgain() throws {
        let token = try authenticate()
        let app = launch(seedingWebviewCookie: token)

        XCTAssertTrue(element(app, "nativeShell").waitForExistence(timeout: 60),
                      "a webview-signed-in launch must render the native workspace:\n\(app.debugDescription)")
        XCTAssertFalse(element(app, "nativeAuthSurface").exists,
                       "…and must not fall back to the native sign-in surface for a user who is "
                       + "already signed in (this is the defect the harvest fixes)")
        XCTAssertFalse(app.textFields["loginIDField"].exists,
                       "no sign-in form: nothing on this launch knows a password")

        // The rail (authenticated `/users/me/teams`) and the channel list (authenticated
        // `/users/me/teams/{id}/channels`) both answered — so the token reached the **native**
        // transport, not just the gate.
        XCTAssertTrue(element(app, "nativeTeamSidebar").waitForExistence(timeout: 40),
                      "the team rail is loaded in the native shell:\n\(app.debugDescription)")
        XCTAssertTrue(waitUntil(timeout: 60) { element(app, "channelSidebar.category.channels").exists },
                      "the server's channel grouping is on screen:\n\(app.debugDescription)")

        // Rows the *server* says this account is a member of, rendered by the native list. Matched
        // as a set rather than one id: the list is lazy, so which rows are above the fold is not
        // something this test should be pinned to.
        let rendered = Set(app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "channelSidebar.channel."))
            .allElementsBoundByIndex.map(\.identifier))
        let expected = Set(memberIDs.map { "channelSidebar.channel.\($0)" })
        XCTAssertFalse(rendered.intersection(expected).isEmpty,
                       "none of the fixture's channels (\(expected.sorted())) is listed — got "
                       + "\(rendered.sorted()); an authentication failure leaves the list empty:\n"
                       + app.debugDescription)
        attachShot(app, named: "t31harvest-webview-session-native-shell")
    }

    /// The control: the same launch with no webview cookie and no vault token is signed out, so the
    /// native sign-in surface appears. This is what makes the test above falsifiable.
    func testWithoutAWebviewSessionTheSameLaunchStillAsksForSignIn() throws {
        let app = launch(seedingWebviewCookie: nil)

        XCTAssertTrue(element(app, "nativeAuthSurface").waitForExistence(timeout: 60),
                      "with no credential anywhere the shell must ask for sign-in:\n\(app.debugDescription)")
        XCTAssertFalse(element(app, "nativeShell").exists,
                       "and must not draw a workspace it has no session for")
        attachShot(app, named: "t31harvest-control-native-auth-surface")
    }

    // MARK: - Launch

    /// One launch of the native shell. `seedingWebviewCookie` is the whole variable under test: the
    /// app's DEBUG seam plants that token as the seeded server's `MMAUTHTOKEN`, which is the copy a
    /// webview sign-in leaves — and `-uiTestForgetSession` guarantees the vault holds nothing, so the
    /// cookie is the *only* credential on the device.
    private func launch(seedingWebviewCookie token: String?) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-uiTestResetPersistedState",
                    "-uiTestForgetSession", serverURL.absoluteString,
                    "-uiTestSeedServer", serverURL.absoluteString,
                    "-uiTestSeedServerName", "Local Mattermost",
                    // The simulator quarantines a process whose os_log volume is high, after which
                    // XCTest's snapshot callback dies mid-run (T40-R measured this). A UI run turns
                    // the app's logging down to `error`; nothing else about the app changes.
                    "-uiTestLogLevel", "error",
                    // The native shell and its panes: this card is about the *native* stack seeing
                    // the webview's session, so every surface that draws the workspace is native.
                    "-surfaceMode", "shell=native",
                    "-surfaceMode", "auth=native",
                    "-surfaceMode", "sidebar=native",
                    "-surfaceMode", "channelView=native",
                    "-surfaceMode", "threads=native",
                    "-surfaceMode", "composer=native",
                    "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if let token {
            args += ["-uiTestSeedWebSessionCookie", token]
        }
        app.launchArguments = args
        app.launch()
        return app
    }

    // MARK: - Server access (the test is its own API client, so nothing is assumed)

    private func ping() throws {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/system/ping"))
        request.timeoutInterval = 5
        let (_, response) = try synchronous(request)
        try XCTSkipUnless((response as? HTTPURLResponse)?.statusCode == 200,
                          "the live server at \(serverURL.absoluteString) is not answering")
    }

    private func authenticate() throws -> String {
        let url = serverURL.appendingPathComponent("api/v4/users/login")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["login_id": loginID!,
                                                                      "password": password!])
        let (data, response) = try synchronous(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let token = http.value(forHTTPHeaderField: "Token"), !token.isEmpty else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let headers = (response as? HTTPURLResponse)?.allHeaderFields.keys
                .map { String(describing: $0) }.joined(separator: ",") ?? ""
            let body = String(data: data.prefix(300), encoding: .utf8) ?? "<non-utf8>"
            throw XCTSkip("could not sign in as \(loginID ?? "") on the live server "
                          + "(\(request.httpMethod ?? "?") \(url.absoluteString), "
                          + "body \(request.httpBody?.count ?? -1) bytes, status \(status), "
                          + "headers \(headers), body \(body))")
        }
        return token
    }

    /// The channels this account is a member of, in the first team the server lists. The shell opens
    /// on the first team when nothing is selected (`TeamSidebarCoordinator.applyDefaultTeamIfNeeded`),
    /// so the expectation is the same list the rail's own default would show.
    ///
    /// A **non-DM** channel is preferred: the list is a lazy `List`, so a row below the fold does not
    /// exist in the accessibility tree at all, and the DMs sit in their own (collapsed, bottom)
    /// category. A public channel is in the "Channels" category at the top on the fixture.
    private func memberChannels(token: String) throws -> [(id: String, displayName: String)] {
        let teams = try getJSON("/api/v4/users/me/teams", token: token) as? [[String: Any]] ?? []
        guard let teamID = teams.first?["id"] as? String else {
            throw XCTSkip("the fixture account has no team")
        }
        let rows = try getJSON("/api/v4/users/me/teams/\(teamID)/channels", token: token) as? [[String: Any]] ?? []
        let channels: [(id: String, displayName: String, type: String)] = rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            let name = row["name"] as? String ?? id
            let display = (row["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
            return (id, display, row["type"] as? String ?? "")
        }
        let preferred = channels.filter { $0.type == "O" } + channels.filter { $0.type == "P" }
            + channels.filter { $0.type != "D" && $0.type != "G" }
        return (preferred.isEmpty ? channels : preferred).map { ($0.id, $0.displayName) }
    }

    private func getJSON(_ path: String, token: String) throws -> Any {
        var request = URLRequest(url: serverURL.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try synchronous(request)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func synchronous(_ request: URLRequest) throws -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Data, URLResponse)?
        var failure: Error?
        api.dataTask(with: request) { data, response, error in
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

    /// Poll a UI condition without XCUITest's own long retry loop on a *single* element query: a
    /// `waitForExistence` that is going to fail keeps taking element snapshots, which is exactly what
    /// the quarantined-snapshot failure above is made of.
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return condition()
    }

    private func attachShot(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
