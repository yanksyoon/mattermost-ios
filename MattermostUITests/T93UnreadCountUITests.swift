import XCTest
import UIKit

/// t_93eca948 — the unread **count** on a channel row, against the **live** 9.11.19 fixture.
///
/// The card's DoD asks for a screenshot of two channels showing different counts together with the
/// `total_msg_count` / `msg_count` values that produced them. This suite is that evidence and the
/// live half of the arithmetic: it writes a known number of posts into two channels as *another
/// account*, reads the server's two fields back, and asserts the row draws their **difference**.
///
/// Run (the fixture server is the local throwaway one; credentials live in `scripts/perf_seed.py`):
///
///     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
///     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
///     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
///     python3 scripts/qa-test.py --platform ios --sim id=81A7F251-8B31-4945-8783-5A264C14B8D5 \
///       --only-testing MattermostUITests/T93UnreadCountUITests
///
/// Each test skips (never fails) when the env or the server is missing, like every live test here.
final class T93UnreadCountUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var userID: String!
    private var teamID: String!
    private var botLogin: String!
    private var botPassword: String!
    private var cachedBot: (token: String, userID: String)?

    /// How many posts this test writes into each channel. The card's own example: 40 vs 2.
    private static let forty = 40
    private static let two = 2

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live unread-count test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        try ping()
        let session = try authenticate(login: loginID, password: password)
        token = session.token
        userID = session.userID
        teamID = try firstTeamID()
        botLogin = env["MM_AUTH_BOT_LOGIN"] ?? "t43buddy"
        botPassword = env["MM_AUTH_BOT_PASSWORD"] ?? "T43-Buddy-Not-A-Real-Secret-1"
        try resetFixtureToVisibleAndRead()
    }

    // MARK: - The card's evidence: two channels, two different numbers

    func testTwoUnreadChannelsShowTwoDifferentCounts() throws {
        let channels = try teamChannels()
        // Two ordinary public channels of the fixture team, so a post from the second account is
        // possible (it is made a member below).
        guard let fortyChannel = channels.first(where: { $0.name == "off-topic" }),
              let twoChannel = channels.first(where: { $0.name == "perf-feed" }) else {
            return XCTFail("the fixture team needs off-topic and perf-feed, got \(channels.map(\.name))")
        }
        try markAllRead(channels)
        // Both rows on screen at once: the account's sidebar holds eight custom "T8G group" categories
        // (sort_order 10…80) over a 321-channel Channels section, so the Channels category is lifted
        // to the top and the two rows put at its head. Restored from the snapshot in `defer`.
        let snapshot = try categoriesSnapshot()
        try raiseChannelsCategory(channelIDs: [fortyChannel.id, twoChannel.id])
        var posted: [(String, String)] = []              // (token, post id)
        defer {
            for (postToken, id) in posted { try? delete(id, token: postToken) }
            try? markAllRead(channels)
            try? restoreCategories(snapshot)
        }

        let bot = try botSession(channelIDs: [fortyChannel.id, twoChannel.id])
        for index in 0..<Self.forty {
            if let id = try post("t93 probe: unread \(index + 1) of \(Self.forty)",
                                 channelID: fortyChannel.id, token: bot.token) {
                posted.append((bot.token, id))
            }
        }
        for index in 0..<Self.two {
            if let id = try post("t93 probe: unread \(index + 1) of \(Self.two)",
                                 channelID: twoChannel.id, token: bot.token) {
                posted.append((bot.token, id))
            }
        }

        // The two fields the number is derived from, read back from the server.
        let fortyTotal = try totalMsgCount(channelID: fortyChannel.id)
        let fortySeen = try myMembership(channelID: fortyChannel.id).msgCount
        let twoTotal = try totalMsgCount(channelID: twoChannel.id)
        let twoSeen = try myMembership(channelID: twoChannel.id).msgCount
        print("T93 ARITHMETIC \(fortyChannel.name): total_msg_count=\(fortyTotal) msg_count=\(fortySeen) "
              + "=> unread=\(fortyTotal - fortySeen); "
              + "\(twoChannel.name): total_msg_count=\(twoTotal) msg_count=\(twoSeen) "
              + "=> unread=\(twoTotal - twoSeen)")
        XCTAssertEqual(fortyTotal - fortySeen, Self.forty,
                       "the server must report 40 unread in \(fortyChannel.name); otherwise the row "
                       + "assertion below proves nothing")
        XCTAssertEqual(twoTotal - twoSeen, Self.two,
                       "the server must report 2 unread in \(twoChannel.name)")

        let app = launchAndSignIn()
        let fortyRow = ShellSettle.revealSidebarChannel(app, channelID: fortyChannel.id,
                                                        maxPops: 3).row
        XCTAssertTrue(fortyRow.waitForExistence(timeout: 40),
                      "the 40-unread row must be reachable:\n\(app.debugDescription)")
        let twoRow = ShellSettle.revealSidebarChannel(app, channelID: twoChannel.id, maxPops: 3).row
        // `revealSidebarChannel` stops when the row is *in the tree*, and SwiftUI materialises rows
        // well below the fold: the two rows came back with `y ≈ 1085` and `isHittable == false`. A
        // screenshot of rows that are not on screen proves nothing, so scroll them into view.
        for _ in 0..<12 where !(fortyRow.isHittable && twoRow.isHittable) {
            app.swipeUp(velocity: .fast)
        }
        let fortyAfter = try myMembership(channelID: fortyChannel.id).msgCount
        let fortyTotalAfter = try totalMsgCount(channelID: fortyChannel.id)
        let twoAfter = try myMembership(channelID: twoChannel.id).msgCount
        let twoTotalAfter = try totalMsgCount(channelID: twoChannel.id)
        print("T93 SERVER-DURING-RUN \(fortyChannel.name): \(fortyTotalAfter)-\(fortyAfter)= "
              + "\(fortyTotalAfter - fortyAfter); \(twoChannel.name): \(twoTotalAfter)-\(twoAfter)= "
              + "\(twoTotalAfter - twoAfter)")
        XCTAssertTrue(twoRow.exists, "the 2-unread row must be on screen beside it:\n\(app.debugDescription)")
        print("T93 ROWS forty='\(fortyRow.value as? String ?? "nil")' "
              + "hittable=\(fortyRow.isHittable) frame=\(fortyRow.frame) | "
              + "two='\(twoRow.value as? String ?? "nil")' hittable=\(twoRow.isHittable) "
              + "frame=\(twoRow.frame)")
        XCTAssertTrue(fortyRow.isHittable, "both rows must be on screen, not merely in the tree")

        // The row speaks the number (the pill itself is decorative — it is drawn from the same value).
        XCTAssertTrue(waitUntil(timeout: 30) {
            (fortyRow.value as? String ?? "").contains("\(Self.forty) unread messages")
        }, "the row must count its 40 unread posts, got '\(fortyRow.value ?? "nil")'")
        XCTAssertTrue((twoRow.value as? String ?? "").contains("\(Self.two) unread messages"),
                      "the row must count its 2 unread posts, got '\(twoRow.value ?? "nil")'")

        // The section total is the rows' own numbers added up: 42.
        let header = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "channelSidebar.category.channels"))
            .firstMatch
        if header.exists {
            print("T93 HEADER \(header.identifier) value='\(header.value as? String ?? "")'")
        }

        let shot = attachScreenshot(app, named: "t93-unread-counts")
        print("T93 SHOT \(shot.path)")

        // Requirement 5: a number this size is drawn as a number, not a dot. The accessibility value
        // is the row's own statement of what the pill draws.
        XCTAssertEqual(fortyRow.label, fortyChannel.displayName)
    }

    /// Requirement 4, live: opening the channel posts its view, and the number clears without a
    /// relaunch — the badge goes, not just the bold text.
    func testOpeningTheChannelClearsItsCountWithoutARelaunch() throws {
        let channels = try teamChannels()
        guard let target = channels.first(where: { $0.name == "perf-feed" }) else {
            return XCTFail("the fixture team needs perf-feed, got \(channels.map(\.name))")
        }
        try markAllRead(channels)
        let snapshot = try categoriesSnapshot()
        try raiseChannelsCategory(channelIDs: [target.id])
        let bot = try botSession(channelIDs: [target.id])
        var posted: [(String, String)] = []
        defer {
            for (postToken, id) in posted { try? delete(id, token: postToken) }
            try? markAllRead(channels)
            try? restoreCategories(snapshot)
        }
        for index in 0..<3 {
            if let id = try post("t93 probe: clears on open \(index + 1)", channelID: target.id,
                                 token: bot.token) {
                posted.append((bot.token, id))
            }
        }
        let total = try totalMsgCount(channelID: target.id)
        let seen = try myMembership(channelID: target.id).msgCount
        XCTAssertEqual(total - seen, 3, "3 unread posts before the app starts")

        let app = launchAndSignIn()
        let row = ShellSettle.revealSidebarChannel(app, channelID: target.id, maxPops: 3).row
        XCTAssertTrue(row.waitForExistence(timeout: 40),
                      "the channel must be on screen:\n\(app.debugDescription)")
        XCTAssertTrue(waitUntil(timeout: 30) {
            (row.value as? String ?? "").contains("3 unread messages")
        }, "the row must start with its 3 posts, got '\(row.value ?? "nil")'")

        // The reader opens the channel, which is what posts the view, then comes back to the list.
        row.tap()
        XCTAssertTrue(app.otherElements["nativeChannelPane"].waitForExistence(timeout: 30),
                      "tapping the row must open the channel pane:\n\(app.debugDescription)")
        ShellSettle.revealChannelList(app)
        let cleared = ShellSettle.revealSidebarChannel(app, channelID: target.id, maxPops: 3).row
        XCTAssertTrue(cleared.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil(timeout: 30) {
            !((cleared.value as? String ?? "").contains("Unread"))
        }, "opening the channel must clear its count in the same visit, got '\(cleared.value ?? "nil")'")
        attachScreenshot(app, named: "t93-cleared-on-open")
    }

    // MARK: - Second account

    private func botSession(channelIDs: [String]) throws -> (token: String, userID: String) {
        if let cachedBot { return cachedBot }
        let session = try authenticate(login: botLogin, password: botPassword)
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/teams/\(teamID!)/members"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["team_id": teamID!,
                                                                      "user_id": session.userID])
        _ = try? synchronous(request)
        // Only the channels this test posts into: the fixture team has 350-odd of them and joining
        // all of them would rewrite the fixture account's sidebar.
        for channelID in channelIDs {
            var join = URLRequest(url: serverURL.appendingPathComponent(
                "api/v4/channels/\(channelID)/members"))
            join.httpMethod = "POST"
            join.setValue("application/json", forHTTPHeaderField: "Content-Type")
            join.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
            join.httpBody = try JSONSerialization.data(withJSONObject: ["user_id": session.userID])
            _ = try? synchronous(join)     // 400 = already a member, which is the normal case
        }
        cachedBot = session
        return session
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
        let field = app.textFields["loginIDField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20),
                      "the native sign-in must mount against \(serverURL.absoluteString):\n"
                      + "\(app.debugDescription)")
        field.tap()
        field.typeText(loginID)
        let secret = app.secureTextFields["loginPasswordField"]
        XCTAssertTrue(secret.exists)
        secret.tap()
        secret.typeText(password)
        app.buttons["loginSubmitButton"].tap()
        XCTAssertTrue(ShellSettle.waitForSignedIn(app, timeout: 40),
                      "signing in must reach the shell:\n\(app.debugDescription)")
        // A signed-in launch opens a channel over the list (t_295b0a32), so take the reader's route
        // back before any `channelSidebar.*` query.
        ShellSettle.revealChannelList(app)
        return app
    }

    // MARK: - Server access (the test is its own API client)

    private struct Channel {
        let id: String
        let name: String
        let displayName: String
        /// The server's `total_msg_count` for the channel — half of the unread formula.
        let totalMsgCount: Int?
    }

    private struct Member {
        let msgCount: Int
        let mentionCount: Int
    }

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
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let token = http.value(forHTTPHeaderField: "Token"),
              let user = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = user["id"] as? String else {
            throw XCTSkip("could not sign in as \(login) on the live server")
        }
        return (token, id)
    }

    private func firstTeamID() throws -> String {
        let teams = try getJSON("/api/v4/users/me/teams") as? [[String: Any]] ?? []
        guard let team = teams.first, let id = team["id"] as? String else {
            throw XCTSkip("the fixture account has no team")
        }
        return id
    }

    private func teamChannels() throws -> [Channel] {
        let rows = try getJSON("/api/v4/users/me/teams/\(teamID!)/channels") as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = row["id"] as? String, let name = row["name"] as? String else { return nil }
            let display = (row["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
            return Channel(id: id, name: name, displayName: display,
                           totalMsgCount: row["total_msg_count"] as? Int)
        }
    }

    /// `GET /channels/{id}/members/me` — the reader's own row, which is where `msg_count` lives.
    private func myMembership(channelID: String) throws -> Member {
        let row = try getJSON("/api/v4/channels/\(channelID)/members/me") as? [String: Any] ?? [:]
        return Member(msgCount: row["msg_count"] as? Int ?? 0,
                      mentionCount: row["mention_count"] as? Int ?? 0)
    }

    /// `total_msg_count` off a fresh channel read — the other half of the formula.
    private func totalMsgCount(channelID: String) throws -> Int {
        let row = try getJSON("/api/v4/channels/\(channelID)") as? [String: Any] ?? [:]
        return row["total_msg_count"] as? Int ?? 0
    }

    /// Post a view for every channel that actually has unread posts.
    ///
    /// The fixture account is a member of 429 channels; posting a view for each of them took tens of
    /// seconds of silence, which is what tripped the runner's stall watchdog (`Test crashed with
    /// signal term`). Two list reads plus one view per *unread* channel is the same end state.
    private func markAllRead(_ channels: [Channel]) throws {
        let members = try getJSON("/api/v4/users/me/teams/\(teamID!)/channels/members") as? [[String: Any]] ?? []
        var msgCountByChannel: [String: Int] = [:]
        for member in members {
            guard let id = member["channel_id"] as? String else { continue }
            msgCountByChannel[id] = member["msg_count"] as? Int ?? 0
        }
        for channel in channels where (channel.totalMsgCount ?? 0) > (msgCountByChannel[channel.id] ?? 0) {
            var request = URLRequest(url: serverURL.appendingPathComponent(
                "api/v4/channels/members/\(userID!)/view"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["channel_id": channel.id])
            _ = try? synchronous(request)
        }
    }

    @discardableResult
    private func post(_ message: String, channelID: String, token: String) throws -> String? {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/posts"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["channel_id": channelID,
                                                                      "message": message])
        let (data, response) = try synchronous(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        XCTAssertEqual(status, 201, "posting as the other user must succeed (got \(status))")
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String
    }

    private func delete(_ postID: String, token: String) throws {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/posts/\(postID)"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? synchronous(request)
    }

    // MARK: - The server's sidebar layout

    private func categoriesPayload() throws -> [String: Any] {
        try getJSON("/api/v4/users/\(userID!)/teams/\(teamID!)/channels/categories") as? [String: Any] ?? [:]
    }

    private func categoriesSnapshot() throws -> [[String: Any]] {
        let payload = try categoriesPayload()
        return (payload["categories"] as? [[String: Any]]) ?? []
    }

    /// Lift the `channels` category above the custom ones **and** put `channelIDs` at the head of it,
    /// so both rows are drawn in one screenful. `sort_order` is what the app orders by; the array
    /// order is what the server stores, so both move.
    ///
    /// Sorting alone was not enough: the fixture account carries eight custom "T8G group"
    /// categories (10 channels each), and the app kept them above Channels — the two rows landed at
    /// `y ≈ 1371`, below the fold and un-hittable. Collapsing every other category is what actually
    /// brings the section up; a collapsed group is one header tall, and `ChannelSidebarGroup`
    /// promises it still rolls its rows up, which is exactly what the screenshot should show too.
    private func raiseChannelsCategory(channelIDs: [String]) throws {
        var categories = try categoriesSnapshot()
        guard let index = categories.firstIndex(where: { ($0["type"] as? String) == "channels" }) else {
            throw XCTSkip("the fixture account has no channels category")
        }
        var order = (categories[index]["channel_ids"] as? [String]) ?? []
        for id in channelIDs.reversed() {
            order.removeAll { $0 == id }
            order.insert(id, at: 0)
        }
        categories[index]["channel_ids"] = order
        categories[index]["sort_order"] = -10
        categories[index]["collapsed"] = false
        for other in categories.indices where other != index {
            categories[other]["collapsed"] = true
        }
        try writeCategories(categories)
    }

    private func restoreCategories(_ categories: [[String: Any]]) throws {
        guard !categories.isEmpty else { return }
        try writeCategories(categories)
    }

    /// The body is the **bare category array** — the endpoint rejects the GET's `{order, categories}`
    /// envelope with 400 (T33-AV F1), which is what made an earlier suite's cleanup a silent no-op.
    private func writeCategories(_ categories: [[String: Any]]) throws {
        var request = URLRequest(url: serverURL.appendingPathComponent(
            "api/v4/users/\(userID!)/teams/\(teamID!)/channels/categories"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: categories)
        let (data, response) = try synchronous(request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200,
                       "writing the fixture's categories must succeed: \(String(decoding: data, as: UTF8.self))")
    }

    /// No category collapsed, nothing muted, everything read.
    private func resetFixtureToVisibleAndRead() throws {
        let members = try getJSON("/api/v4/users/me/teams/\(teamID!)/channels/members") as? [[String: Any]] ?? []
        for member in members {
            guard let channelID = member["channel_id"] as? String,
                  let notify = member["notify_props"] as? [String: Any],
                  (notify["mark_unread"] as? String) == "mention" else { continue }
            var request = URLRequest(url: serverURL.appendingPathComponent(
                "api/v4/channels/\(channelID)/members/\(userID!)/notify_props"))
            request.httpMethod = "PUT"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["mark_unread": "all"])
            _ = try? synchronous(request)
        }
        try markAllRead(try teamChannels())
    }

    // MARK: - Plumbing

    private func getJSON(_ path: String) throws -> Any {
        var request = URLRequest(url: serverURL.appendingPathComponent(path))
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        let (data, _) = try synchronous(request)
        return try JSONSerialization.jsonObject(with: data)
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

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    /// Write the device screenshot where the host can copy it (the runner's own temp directory is on
    /// the simulator's data volume, which the host sees under `CoreSimulator/Devices`).
    @discardableResult
    private func attachScreenshot(_ app: XCUIApplication, named name: String) -> URL {
        let image = app.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("t_93eca948", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        try? image.pngRepresentation.write(to: url)
        return url
    }
}
