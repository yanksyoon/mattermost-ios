// T38 **memory probe** — the measurement behind the card's "image loading is cancellable and bounded"
// criterion. This is a harness, not a suite member: it drives a media-heavy channel through six scroll
// passes while `scripts/t38_mem_sample.py` samples the app process from outside, and the numbers come
// from that sampler, never from a test assertion. It skips (never fails) unless the heavy fixture and
// the `MM_AUTH_*` environment exist, so it is not part of the four-test live suite
// (`MattermostUITests/T38AttachmentsUITests`) and does not contribute to that suite's "0 skipped".
//
// Fixture: `scripts/t38_heavy_seed.py` — DEFAULT 4 posts × 10 images, 1024×768 noisy PNGs (~2 MB each,
// ~95 MB in the channel). Small or flat images would make the measurement meaningless: the question is
// whether the inline path's cache is bounded when every image it decodes is megabytes of real pixels.
//
// Run (the whole measurement, three pieces, from the repo root):
//
//     python3 scripts/t38_heavy_seed.py
//     python3 scripts/t38_mem_sample.py 420 > build/logs/t38-mem.csv &      # watches the app
//     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
//     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
//     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
//     python3 scripts/qa-test.py --platform ios --sim "iPhone 17 Pro" \
//       --derived-data ~/Library/Developer/Xcode/DerivedData/t38-ios \
//       --only-testing MattermostUITests/T38HeavyScrollProbeUITests
//     python3 scripts/t38_mem_fold.py build/logs/t38-mem.csv <start> <end> <pass1> <pass2> …
//
// The test prints `PROBE-START`, `PROBE-PASS-<n>` and `PROBE-END` with epoch timestamps; those are the
// window and pass boundaries the fold is given. Result of the run recorded in
// `docs/t38-build-note.md` §3.1 (2026-10-26).

import XCTest

final class T38HeavyScrollProbeUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var teamID: String!
    private var channelID: String!
    private var postIDs: [String] = []
    private var fileCount = 0

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "probe: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        serverURL = try XCTUnwrap(URL(string: raw))
        token = try login(loginID, password)
        let teams = try json("/api/v4/users/me/teams") as? [[String: Any]] ?? []
        teamID = try XCTUnwrap((teams.first { $0["name"] as? String == "perf" })?["id"] as? String,
                               "probe: team #perf is missing")
        let channel = try json("/api/v4/teams/\(teamID!)/channels/name/t38-heavy") as? [String: Any]
        channelID = try XCTUnwrap(channel?["id"] as? String,
                                  "probe: #t38-heavy is missing — run scripts/t38_heavy_seed.py")
        let page = try json("/api/v4/channels/\(channelID!)/posts?per_page=200") as? [String: Any]
        let posts = page?["posts"] as? [String: Any] ?? [:]
        var bytes = 0
        for (_, value) in posts {
            guard let post = value as? [String: Any],
                  let props = post["props"] as? [String: Any],
                  props["t38_heavy_key"] != nil,
                  let id = post["id"] as? String else { continue }
            postIDs.append(id)
            let files = (post["metadata"] as? [String: Any])?["files"] as? [[String: Any]] ?? []
            fileCount += files.count
            bytes += files.reduce(0) { $0 + (($1["size"] as? Int) ?? 0) }
        }
        try XCTSkipUnless(postIDs.count >= 4 && fileCount >= 40,
                          "probe: fixture incomplete — \(postIDs.count) posts / \(fileCount) files")
        print("PROBE-FIXTURE posts=\(postIDs.count) files=\(fileCount) bytes=\(bytes)")
    }

    /// Scroll the heavy channel six times over. The assertion at the end only proves the list still
    /// renders; the memory claim comes from the sampler beside it.
    func testScrollingAMediaHeavyChannelSixTimes() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetPersistedState",
                               "-uiTestSeedServer", serverURL.absoluteString,
                               "-uiTestSeedServerName", "Local Mattermost",
                               "-uiTestForgetSession", serverURL.absoluteString,
                               "-surfaceMode", "shell=native",
                               "-surfaceMode", "auth=native",
                               "-surfaceMode", "sidebar=native",
                               "-surfaceMode", "composer=native",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let login = app.textFields["loginIDField"]
        XCTAssertTrue(login.waitForExistence(timeout: 30), "sign-in must mount:\n\(app.debugDescription)")
        login.tap(); login.typeText(loginID)
        let secret = app.secureTextFields["loginPasswordField"]
        XCTAssertTrue(secret.exists)
        secret.tap(); secret.typeText(password)
        app.buttons["loginSubmitButton"].tap()
        XCTAssertTrue(el(app, "nativeShell").waitForExistence(timeout: 60),
                      "sign-in must reach the shell")

        var row = el(app, "channelSidebar.channel.\(channelID!)")
        if !row.waitForExistence(timeout: 25) {
            let team = el(app, "teamSidebar.team.\(teamID!)")
            if team.waitForExistence(timeout: 10) { team.tap() }
            row = el(app, "channelSidebar.channel.\(channelID!)")
        }
        XCTAssertTrue(row.waitForExistence(timeout: 45), "the sidebar must list #t38-heavy")
        // The heavy channel is the newest row, so its centre can sit under the tab bar; tap its top.
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
        let list = el(app, "channelPostList")
        XCTAssertTrue(list.waitForExistence(timeout: 120),
                      "the channel pane must mount:\n\(app.debugDescription)")

        print("PROBE-START \(Date().timeIntervalSince1970)")
        sleep(8)

        // Six passes over the same 40 images. `previewLimit` is 40 and `previewByteLimit` is 24 MB of
        // decoded bitmap, which is less than one pass of ten 2 MB images at 600² — so every pass evicts
        // and refetches. An unbounded cache would climb pass after pass; a bounded one plateaus.
        for pass in 1...6 {
            for _ in 0..<8 { list.swipeUp(velocity: .fast) }
            sleep(2)
            for _ in 0..<8 { list.swipeDown(velocity: .fast) }
            sleep(2)
            print("PROBE-PASS-\(pass) \(Date().timeIntervalSince1970)")
        }
        sleep(10)
        print("PROBE-END \(Date().timeIntervalSince1970)")

        var seen = 0
        for postID in postIDs {
            let target = el(app, "post.\(postID)")
            var swipes = 0
            while !target.exists, swipes < 10 { list.swipeUp(velocity: .fast); swipes += 1 }
            if el(app, "post.\(postID).attachments").exists { seen += 1 }
        }
        XCTAssertGreaterThanOrEqual(seen, postIDs.count - 1,
                                    "\(seen)/\(postIDs.count) fixture posts still draw their attachment section")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "t38-heavy-after-6-passes"
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Helpers

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func login(_ id: String, _ pw: String) throws -> String {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/users/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["login_id": id, "password": pw])
        let (data, response) = try synchronous(request)
        let http = response as? HTTPURLResponse
        let token = http?.value(forHTTPHeaderField: "Token") ?? ""
        try XCTSkipUnless(http?.statusCode == 200 && !token.isEmpty,
                          "probe: login failed HTTP \(http?.statusCode ?? -1)")
        _ = data
        return token
    }

    private func json(_ path: String) throws -> Any {
        var request = URLRequest(url: try XCTUnwrap(URL(string: path, relativeTo: serverURL)))
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        let (data, _) = try synchronous(request)
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Cookies off: the `Authorization` header is then the only identity a fixture read can carry, so a
    /// read cannot silently belong to the app's own session.
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
