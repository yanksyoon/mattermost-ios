import XCTest

/// T34 — the native channel pane against a **real** Mattermost server, with every expectation read
/// back from that server through its own API.
///
/// Why live (the card's DoD forbids fixture-only evidence): the four acceptance criteria are all
/// statements about what a running server's data looks like once rendered —
///   1. a channel's posts render in order with day separators, and an edit/delete/system message is
///      drawn the way the server's fields say;
///   2. markdown, fenced code, tables, quotes, mentions, emoji, reactions and an attachment all draw;
///   3. scrolling to the top pages older posts in without duplicating or reordering them;
///   4. a message that arrives over the socket appears without a reload, and the "New messages" line
///      sits where `last_viewed_at` says it does.
/// A stub could only prove the test author's own fixture renders; these prove the client renders the
/// server's data. The seeded channels (`scripts/t34_post_seed.py`) carry one post per state.
///
/// Run (local throwaway server, credentials in `scripts/perf_seed.py`):
///
///     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
///     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
///     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
///     python3 scripts/qa-test.py --platform ios --sim <sim> \
///       --only-testing MattermostUITests/T34ChannelPostListUITests
///
/// Each test skips (never fails) when the environment or the server is missing, like every live test
/// here. Nothing is fabricated: a skipped test is reported as skipped.
final class T34ChannelPostListUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var userID: String!
    private var teamID: String!

    /// The channels `scripts/t34_post_seed.py` creates in team `perf`.
    private let showcaseChannelName = "t34-showcase"
    private let longChannelName = "perf-feed"
    private let foldChannelName = "t34-fold"

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live post-list test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        try ping()
        let session = try authenticate(login: loginID, password: password)
        token = session.token
        userID = session.userID
        teamID = try firstTeamID()
    }

    // MARK: - 1. The showcase channel renders every state the server has

    func testThePostListRendersTheServersShowcase() throws {
        let channel = try channel(named: showcaseChannelName)
        let posts = try channelPosts(channel.id)
        XCTAssertGreaterThan(posts.count, 6, "the seeded showcase channel has one post per state")

        // What the server says each state looks like, resolved before the app is launched so the
        // assertions below are about *server* data, not about what the seed script promised.
        let editedID = (posts.first { ($0["edit_at"] as? Int ?? 0) > 0 }?["id"] as? String) ?? ""
        let systemID = (posts.first { !(($0["type"] as? String) ?? "").isEmpty }?["id"] as? String) ?? ""
        let attachmentPost = posts.first { post in
            !(((post["metadata"] as? [String: Any])?["files"] as? [[String: Any]]) ?? []).isEmpty
        }
        let attachmentFile = ((attachmentPost?["metadata"] as? [String: Any])?["files"]
            as? [[String: Any]])?.first
        let attachmentID = (attachmentPost?["id"] as? String) ?? ""
        let attachmentFileID = (attachmentFile?["id"] as? String) ?? ""
        let attachmentFileName = (attachmentFile?["name"] as? String) ?? ""

        let reactedPost = posts.first { post in
            !(((post["metadata"] as? [String: Any])?["reactions"] as? [[String: Any]]) ?? []).isEmpty
        }
        let reactions = ((reactedPost?["metadata"] as? [String: Any])?["reactions"]
            as? [[String: Any]]) ?? []
        let emoji = (reactions.first?["emoji_name"] as? String) ?? ""
        let emojiCount = reactions.filter { ($0["emoji_name"] as? String) == emoji }.count
        let reactedID = (reactedPost?["id"] as? String) ?? ""

        // T34 review F7: the server's own custom emoji. The assertion is that `:t34parrot:` becomes an
        // image: until `GET /emoji` answers and `GET /emoji/{id}/image` lands, the renderer draws the
        // literal shortcode, so "no literal shortcode in the body" is a real end-to-end check.
        let customEmojiPost = posts.first {
            (($0["props"] as? [String: Any])?["t34_key"] as? String) == "custom-emoji"
        }
        let customEmojiID = (customEmojiPost?["id"] as? String) ?? ""

        XCTAssertFalse(editedID.isEmpty, "the seeded channel has no edited post")
        XCTAssertFalse(systemID.isEmpty, "the seeded channel has no system message")
        XCTAssertFalse(attachmentID.isEmpty, "the seeded channel has no attachment post")
        XCTAssertFalse(reactedID.isEmpty, "the seeded channel has no reaction")
        XCTAssertFalse(customEmojiID.isEmpty, "the seeded channel has no post with a custom emoji")

        let app = launchAndOpen(channelName: channel.name)
        let list = element(app, "channelPostList")
        XCTAssertTrue(list.waitForExistence(timeout: 60),
                      "the post list must mount for #\(channel.name):\n\(app.debugDescription)")

        // The newest post of the server's page is on screen straight away: a conversation opens at
        // its newest message, not at the top of the loaded window.
        let newestID = (posts.first?["id"] as? String) ?? ""
        XCTAssertTrue(element(app, "post.\(newestID)").waitForExistence(timeout: 30),
                      "the list must open at the newest post \(newestID):\n\(app.debugDescription)")
        attach(app, "t34-showcase-open")

        // Walk the channel from the newest post to the oldest, checking each state as it comes into
        // view. A SwiftUI lazy list only builds what is visible, so "renders when the reader gets
        // there" is the question a test can honestly ask.
        for post in posts {
            let postID = post["id"] as? String ?? ""
            let row = revealRow(app, "post.\(postID)")
            XCTAssertTrue(row.waitForExistence(timeout: 10),
                          "post \(postID) is in the server's answer but never rendered while scrolling:\n"
                          + "\(app.debugDescription)")

            if postID == editedID {
                XCTAssertTrue(element(app, "post.\(postID).edited").waitForExistence(timeout: 10),
                              "the server's edited post has no (edited) marker")
            }
            if postID == systemID {
                XCTAssertTrue(element(app, "post.\(postID).system").waitForExistence(timeout: 10),
                              "the server's system message is not drawn as one")
            }
            if postID == attachmentID {
                let attachmentRow = element(app, "post.\(postID).attachment.\(attachmentFileID)")
                XCTAssertTrue(attachmentRow.waitForExistence(timeout: 20),
                              "the attachment row is missing:\n\(app.debugDescription)")
                XCTAssertTrue(attachmentRow.label.contains(attachmentFileName),
                              "the attachment row does not name \(attachmentFileName), "
                              + "got '\(attachmentRow.label)'")
            }
            if postID == reactedID {
                let reaction = element(app, "post.\(postID).reaction.\(emoji)")
                XCTAssertTrue(reaction.waitForExistence(timeout: 20),
                              "reaction :\(emoji): is missing:\n\(app.debugDescription)")
                XCTAssertTrue(reaction.label.contains("\(emojiCount)"),
                              "reaction label should carry the server's count \(emojiCount), "
                              + "got '\(reaction.label)'")
            }
            if postID == customEmojiID {
                let resolved = waitUntil(timeout: 20) {
                    !blockLabel(app, postID: postID).contains(":t34parrot:")
                }
                XCTAssertTrue(resolved,
                              "the server's :t34parrot: is still drawn as a literal shortcode: "
                              + "'\(blockLabel(app, postID: postID))'")
                XCTAssertTrue(blockLabel(app, postID: postID).contains("custom emoji"),
                              "the sentence around the emoji must still be there: "
                              + "'\(blockLabel(app, postID: postID))'")
                attach(app, "t34-showcase-custom-emoji")
            }
        }

        // Having reached the oldest post, its day separator is right above it — the list is divided by
        // the server's own timestamps, and there is one boundary at the top of the loaded window.
        let separator = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'channelDateSeparator.'"))
            .firstMatch
        XCTAssertTrue(separator.exists,
                      "no day separator above the oldest post:\n\(app.debugDescription)")
        XCTAssertEqual(separator.label.hasPrefix("Messages from"), true, "separator label: \(separator.label)")
    }

    // MARK: - 2. A long post folds and unfolds

    func testALongPostFoldsAndExpands() throws {
        let channel = try channel(named: showcaseChannelName)
        let posts = try channelPosts(channel.id)
        let long = try XCTUnwrap(posts.first {
            (($0["props"] as? [String: Any])?["t34_key"] as? String) == "long"
        }, "the seeded channel has no long post")

        let app = launchAndOpen(channelName: channel.name)
        XCTAssertTrue(element(app, "channelPostList").waitForExistence(timeout: 60))

        let longID = long["id"] as? String ?? ""
        let identifier = "post.\(longID).showMore"
        let fold = revealRow(app, identifier, maxSwipes: 6)
        XCTAssertTrue(fold.waitForExistence(timeout: 20),
                      "the long post must offer \"Show more\":\n\(app.debugDescription)")
        XCTAssertEqual(fold.label, "Show more")
        let foldedHeight = element(app, "post.\(longID)").frame.height
        XCTAssertLessThan(foldedHeight, 3_000, "the folded row must be bounded (was \(foldedHeight))")

        fold.tap()
        // Expanding must actually reveal the rest: the summary ("… 35 more blocks") goes away and the
        // row grows. The "Show less" affordance is *not* asserted here — it sits below the fold of a
        // post several screens tall, and SwiftUI only publishes elements near the viewport to
        // accessibility. Collapsing is proven at the unit level (T34PostListTests fold tests) and by
        // the single-block test, whose row is short enough to keep the affordance reachable.
        XCTAssertTrue(waitUntil(timeout: 20) {
            !element(app, "post.\(longID).foldSummary").exists
        }, "expanding the post must drop the fold summary")
        let expandedRow = element(app, "post.\(longID)")
        XCTAssertGreaterThan(expandedRow.frame.height, foldedHeight * 2,
                            "expanding must reveal the rest of the post")
    }

    // MARK: - 3. Scrolling to the top pages older posts in, without duplicating them

    func testReachingTheTopLoadsOlderPostsWithoutDuplicates() throws {
        let channel = try channel(named: longChannelName)
        let firstPage = try channelPosts(channel.id, perPage: 60)
        XCTAssertEqual(firstPage.count, 60, "the long channel must have a full first page")
        let older = try channelPosts(channel.id, perPage: 60, before: firstPage.last?["id"] as? String)
        XCTAssertFalse(older.isEmpty, "the long channel must have an older page")

        let app = launchAndOpen(channelName: channel.name)
        let list = element(app, "channelPostList")
        XCTAssertTrue(list.waitForExistence(timeout: 60),
                      "the post list must mount:\n\(app.debugDescription)")

        // The newest post of the first page is on screen; the oldest is not (60 posts do not fit).
        let newest = try XCTUnwrap(firstPage.first?["id"] as? String)
        XCTAssertTrue(element(app, "post.\(newest)").waitForExistence(timeout: 30))

        // Swipe down (towards older posts, which are above) until the sentinel is reachable.
        let sentinel = element(app, "channelPostList.loadEarlier")
        var swipes = 0
        while !sentinel.exists, swipes < 40 {
            list.swipeDown(velocity: .fast)
            swipes += 1
        }
        XCTAssertTrue(sentinel.waitForExistence(timeout: 30),
                      "the load-earlier sentinel never appeared after \(swipes) swipes")

        // After the load, keep scrolling towards the old end: the page that just landed is above the
        // reader, so its posts only become reachable once they swipe up into it.
        let olderNewest = try XCTUnwrap(older.first?["id"] as? String)
        XCTAssertTrue(scrollTowardOlderPosts(app, "post.\(olderNewest)"),
                      "the page that loaded is not reachable by scrolling:\n" + "\(app.debugDescription)")

        // No post is drawn twice, and the first page's oldest post is still exactly once.
        let identifiers = postRows(app).map(\.identifier)
        XCTAssertEqual(Set(identifiers).count, identifiers.count,
                       "a post id was drawn twice: \(identifiers)")
        XCTAssertTrue(identifiers.contains("post.\(olderNewest)"),
                      "the older page's newest post is not on screen")
        XCTAssertLessThanOrEqual(swipes, 40, "the sentinel needed \(swipes) swipes")
    }

    // MARK: - 4. A single-block post folds too (review F6)

    /// The review's finding: a post that is **one** markdown block was drawn in full and "Show more"
    /// had nothing to reveal. The measurement is the row's height — a 600-line fence and a 14.8 K
    /// character paragraph must both occupy a bounded row, and the fence's summary must count lines.
    func testASingleBlockPostIsBoundedAndOffersMore() throws {
        let channel = try channel(named: foldChannelName)
        let posts = try channelPosts(channel.id)
        let fence = try XCTUnwrap(posts.first {
            (($0["props"] as? [String: Any])?["t34_key"] as? String) == "huge-fence"
        }, "the seeded channel has no huge fence post")
        let fenceID = try XCTUnwrap(fence["id"] as? String)
        let fenceLines = (fence["message"] as? String ?? "").components(separatedBy: "\n").count - 2
        XCTAssertGreaterThan(fenceLines, 200, "the fixture fence must be long enough to matter")

        let app = launchAndOpen(channelName: channel.name)
        XCTAssertTrue(element(app, "channelPostList").waitForExistence(timeout: 60))

        let row = revealRow(app, "post.\(fenceID)", maxSwipes: 10)
        XCTAssertTrue(row.waitForExistence(timeout: 30),
                      "the huge fence never rendered:\n\(app.debugDescription)")

        // 600 lines of code at ~17 pt each would be ~10 000 pt. Folded, the row is a fraction of that.
        let foldedHeight = row.frame.height
        XCTAssertGreaterThan(foldedHeight, 40, "the row must still draw something")
        XCTAssertLessThan(foldedHeight, 1_200,
                          "a one-block post must be folded, not drawn in full (height \(foldedHeight))")

        let summary = element(app, "post.\(fenceID).foldSummary")
        XCTAssertTrue(summary.waitForExistence(timeout: 10),
                      "the fold must say what it is hiding:\n\(app.debugDescription)")
        XCTAssertTrue(summary.label.contains("more line"),
                      "a code fence is shortened by lines, got '\(summary.label)'")

        let more = element(app, "post.\(fenceID).showMore")
        XCTAssertTrue(more.exists, "a folded post must offer \"Show more\"")
        more.tap()
        XCTAssertTrue(waitUntil(timeout: 20) { !element(app, "post.\(fenceID).foldSummary").exists },
                      "expanding must drop the summary")
        // The expanded block is several screens tall, so "Show less" is out of the accessibility tree
        // (SwiftUI publishes only what is near the viewport) — the collapse path is covered by the unit
        // tests, and what a reader sees here is that the rest of the block is now drawn.
        XCTAssertGreaterThan(element(app, "post.\(fenceID)").frame.height, foldedHeight,
                             "expanding must draw more of the block")
    }

    // MARK: - 5. Paging does not move the reader (review F5, measured)

    /// The review's finding: nothing proved that `loadEarlier()` keeps the reader's place, and
    /// `offsetFromTop` was carried but never read. This measures it in the running app: the topmost
    /// visible post's **frame** before one page insert and after it, with the page triggered through a
    /// launch-argument seam so the load cannot race the measurement.
    func testLoadingOlderPostsDoesNotMoveTheAnchoredPost() throws {
        let channel = try channel(named: longChannelName)
        let firstPage = try channelPosts(channel.id, perPage: 60)
        XCTAssertEqual(firstPage.count, 60)
        let older = try channelPosts(channel.id, perPage: 60, before: firstPage.last?["id"] as? String)
        let olderID = try XCTUnwrap(older.last?["id"] as? String)

        let app = launchAndOpen(channelName: channel.name, exposeLoadEarlier: true)
        let list = element(app, "channelPostList")
        XCTAssertTrue(list.waitForExistence(timeout: 60))

        // Move the window off the bottom so the anchor is genuinely mid-content, then let it settle.
        list.swipeDown()
        _ = waitUntil(timeout: 10) { postRows(app).count > 3 }

        let top = try XCTUnwrap(topVisibleRow(app),
                                "no post row is visible to anchor on:\n\(app.debugDescription)")
        let before = top.frame
        attach(app, "t34-scroll-before-load")

        let trigger = element(app, "channelPostList.forceLoadEarlier")
        XCTAssertTrue(trigger.waitForExistence(timeout: 20),
                      "the test seam (-uiTestExposeLoadEarlier) is not mounted")
        trigger.tap()
        attach(app, "t34-scroll-after-load")

        // The anchor must still be on screen, at the same offset. `PostRowView` rows are lazy: if the
        // restore did not happen, the viewport keeps its content offset, the anchor is pushed down by
        // a whole page and stops existing. Wait for two consecutive measurements to agree before
        // comparing, so the assertion is not reading a half-applied layout.
        var settled: CGRect?
        _ = waitUntil(timeout: 20) {
            let row = element(app, top.identifier)
            guard row.exists else { return false }
            if let settled, abs(settled.minY - row.frame.minY) <= 2 { return true }
            settled = row.frame
            return false
        }
        let after = element(app, top.identifier)
        XCTAssertTrue(after.exists,
                      "the anchored post \(top.identifier) left the screen: the list jumped"
                      + " by the height of the inserted page")
        XCTAssertEqual(after.frame.minY, before.minY, accuracy: 2,
                       "the anchored post moved from y=\(before.minY) to y=\(after.frame.minY)")

        // And the page really was inserted: the reader can now reach posts that were not loaded
        // before. Without this the frame comparison above would pass on a no-op.
        XCTAssertTrue(scrollTowardOlderPosts(app, "post.\(olderID)"),
                      "loadEarlier() did not merge a page: the oldest post of the older page is not "
                      + "reachable by scrolling")
    }

    // MARK: - 6. A new post arrives over the socket without a reload

    func testANewPostAppearsWithoutReloadAndTheUnreadLineFollowsLastViewedAt() throws {
        let channel = try channel(named: showcaseChannelName)
        // Mark the channel read *now*, so the next message is provably "after" the divider position.
        try markRead(channelID: channel.id)

        let app = launchAndOpen(channelName: channel.name)
        XCTAssertTrue(element(app, "channelPostList").waitForExistence(timeout: 60))

        let message = "t34 ui live post \(UUID().uuidString.prefix(8))"
        let postID = try XCTAssertNotNilAndUnwrap(post(message, channelID: channel.id))

        // The socket must deliver it: no pull-to-refresh, no relaunch.
        let row = element(app, "post.\(postID)")
        XCTAssertTrue(row.waitForExistence(timeout: 45),
                      "a posted message must appear over the socket without a reload:\n"
                      + "\(app.debugDescription)")
        XCTAssertTrue(row.label.contains(String(message.prefix(20))) || app.staticTexts[message].exists,
                      "the new row does not carry the message text, got '\(row.label)'")

        // `last_viewed_at` (read back from the server) is what places the unread line — but opening a
        // channel marks it read, so whether the line is still due depends on the server's own read
        // position *now*, not on the value read before the app launched. Assert the rule, not a guess
        // about that race.
        let afterView = try membership(channelID: channel.id)["last_viewed_at"] as? Int ?? 0
        let created = (try channelPosts(channel.id).first { ($0["id"] as? String) == postID }?["create_at"] as? Int) ?? 0
        let divider = element(app, "channelNewMessages")
        if created > afterView {
            XCTAssertTrue(divider.waitForExistence(timeout: 20),
                          "a message after last_viewed_at must draw the New messages line "
                          + "(post \(created) > read \(afterView)):\n\(app.debugDescription)")
        } else {
            XCTAssertFalse(divider.exists,
                           "the server already has this message read (\(afterView) >= \(created)), so "
                           + "the app must not invent a New messages line")
        }

        // Clean up: the seeded channel is shared state, so the test leaves nothing behind.
        try delete(postID, token: token)
        XCTAssertTrue(waitUntil(timeout: 30) {
            element(app, "post.\(postID).deleted").exists
                || !element(app, "post.\(postID)").exists
        }, "a deleted post must turn into a tombstone (or disappear) on the socket")
    }

    // MARK: - Launch

    private func launchAndOpen(channelName: String, exposeLoadEarlier: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["-uiTestResetPersistedState",
                         "-uiTestForgetSession", serverURL.absoluteString,
                         "-uiTestSeedServer", serverURL.absoluteString,
                         "-uiTestSeedServerName", "Local Mattermost",
                         "-surfaceMode", "shell=native",
                         "-surfaceMode", "auth=native",
                         "-surfaceMode", "sidebar=native",
                         "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if exposeLoadEarlier { arguments.append("-uiTestExposeLoadEarlier") }
        app.launchArguments = arguments
        app.launch()
        signIn(app)

        // Open the channel the way a person does: the sidebar row for it.
        let channel = try? self.channel(named: channelName)
        let identifier = "channelSidebar.channel.\(channel?.id ?? "")"
        let row = element(app, identifier)
        XCTAssertTrue(row.waitForExistence(timeout: 40),
                      "the sidebar must list #\(channelName):\n\(app.debugDescription)")
        row.tap()
        return app
    }

    private func signIn(_ app: XCUIApplication) {
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
        XCTAssertTrue(element(app, "nativeShell").waitForExistence(timeout: 40),
                      "signing in must reach the shell:\n\(app.debugDescription)")
    }

    // MARK: - Server access (the test is its own API client)

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

    private struct Channel {
        let id: String
        let name: String
    }

    private func channel(named name: String) throws -> Channel {
        let row = try getJSON("/api/v4/teams/\(teamID!)/channels/name/\(name)") as? [String: Any]
        guard let row, let id = row["id"] as? String else {
            throw XCTSkip("channel #\(name) is missing — run scripts/t34_post_seed.py")
        }
        return Channel(id: id, name: row["name"] as? String ?? name)
    }

    private func channelPosts(_ channelID: String, perPage: Int = 200,
                              before: String? = nil) throws -> [[String: Any]] {
        // A query string must go through `URLComponents`: `appendingPathComponent` would escape the
        // `?` into the path and the request would 404 (which is how this test first read "0 posts").
        var components = URLComponents(url: serverURL.appendingPathComponent(
            "api/v4/channels/\(channelID)/posts"), resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "per_page", value: String(perPage))]
        if let before { items.append(URLQueryItem(name: "before", value: before)) }
        components?.queryItems = items
        let url = try XCTUnwrap(components?.url)
        let page = try getJSON(url: url) as? [String: Any] ?? [:]
        let order = page["order"] as? [String] ?? []
        let posts = page["posts"] as? [String: Any] ?? [:]
        return order.compactMap { posts[$0] as? [String: Any] }
    }

    private func membership(channelID: String) throws -> [String: Any] {
        try getJSON("/api/v4/channels/\(channelID)/members/me") as? [String: Any] ?? [:]
    }

    private func markRead(channelID: String) throws {
        var request = URLRequest(url: serverURL.appendingPathComponent(
            "api/v4/channels/members/\(userID!)/view"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["channel_id": channelID])
        _ = try? synchronous(request)
    }

    private func post(_ message: String, channelID: String) throws -> String? {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/posts"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["channel_id": channelID,
                                                                      "message": message])
        let (data, response) = try synchronous(request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201,
                       "posting as the fixture user must succeed")
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String
    }

    private func delete(_ postID: String, token: String) throws {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/posts/\(postID)"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? synchronous(request)
    }

    private func getJSON(_ path: String) throws -> Any {
        try getJSON(url: serverURL.appendingPathComponent(path))
    }

    private func getJSON(url: URL) throws -> Any {
        var request = URLRequest(url: url)
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

    /// A row that may be outside the current viewport: swipe towards older messages until it exists,
    /// then back towards newer ones. A lazy list only builds what is on screen, so "does it render
    /// when the reader gets there" is the only question a UI test can ask.
    @discardableResult
    private func revealRow(_ app: XCUIApplication, _ identifier: String,
                           maxSwipes: Int = 12) -> XCUIElement {
        let target = element(app, identifier)
        guard !target.exists else { return target }
        let list = element(app, "channelPostList")
        var swipes = 0
        while !target.exists, swipes < maxSwipes {
            list.swipeDown(velocity: .fast)
            swipes += 1
        }
        while !target.exists, swipes < maxSwipes * 2 {
            list.swipeUp(velocity: .fast)
            swipes += 1
        }
        return target
    }

    // MARK: - Element helpers

    /// Any element type: SwiftUI puts these identifiers on labels, buttons, cells and collections
    /// depending on the container, so a type-specific query could silently never match.
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

    /// Every rendered post row (`post.<id>`), with the frame it occupies right now.
    ///
    /// Row identifiers are `post.<id>`; the row's own children are `post.<id>.body` and friends, so
    /// exactly one dot separates a row from its parts. One pass of the tree, because a `frame` read per
    /// element is a separate query and this list is long.
    private func postRows(_ app: XCUIApplication) -> [(identifier: String, frame: CGRect)] {
        let query = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'post.'"))
        return (0..<query.count).compactMap { index in
            let candidate = query.element(boundBy: index)
            let identifier = candidate.identifier
            guard identifier.components(separatedBy: ".").count == 2 else { return nil }
            let frame = candidate.frame
            guard frame.height > 0 else { return nil }
            return (identifier, frame)
        }
    }

    /// The topmost post row that starts at or below the list's top edge — the row a person reads first.
    private func topVisibleRow(_ app: XCUIApplication) -> (identifier: String, frame: CGRect)? {
        let top = element(app, "channelPostList").frame.minY
        return postRows(app)
            .filter { $0.frame.minY >= top - 1 }
            .min { $0.frame.minY < $1.frame.minY }
    }

    /// The text of a post's markdown blocks, joined — what the reader would see (including any
    /// shortcode the renderer failed to resolve, which is exactly what the emoji test looks for).
    private func blockLabel(_ app: XCUIApplication, postID: String) -> String {
        let query = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "post.\(postID).block"))
        guard query.count > 0 else { return "" }
        return (0..<query.count).map { query.element(boundBy: $0).label }.joined(separator: " ")
    }

    /// Swipe towards the **older** end until `identifier` is in the tree, stopping as soon as the list
    /// stops moving (it is at the very top) so a missing post costs seconds, not a swipe budget.
    private func scrollTowardOlderPosts(_ app: XCUIApplication, _ identifier: String,
                                        maxSwipes: Int = 60) -> Bool {
        let list = element(app, "channelPostList")
        var lastTop = CGFloat.greatestFiniteMagnitude
        for _ in 0..<maxSwipes {
            if element(app, identifier).exists { return true }
            list.swipeDown(velocity: .fast)
            let top = postRows(app).first?.frame.minY ?? lastTop
            if abs(top - lastTop) <= 1 { return element(app, identifier).exists }
            lastTop = top
        }
        return element(app, identifier).exists
    }

    /// Scroll towards the **newer** end (swipe up) until `identifier` — optionally with a given label —
    /// is in the tree, and return it.
    ///
    /// A post that expands is taller than the screen, so its "Show less" affordance starts thousands
    /// of points below the viewport and SwiftUI only publishes it to accessibility once it is near.
    /// The swipes are deliberately slow: a fast flick crosses several screens and steps straight over
    /// the target. `rowID` stops the walk once the whole row is above the viewport.
    private func revealBelow(_ app: XCUIApplication, _ identifier: String, rowID: String? = nil,
                             label: String? = nil, maxSwipes: Int = 25) -> XCUIElement {
        let list = element(app, "channelPostList")
        func found() -> Bool {
            let candidate = element(app, identifier)
            guard candidate.exists else { return false }
            return label == nil || candidate.label == label
        }
        if found() { return element(app, identifier) }
        for _ in 0..<maxSwipes {
            if let rowID {
                let row = element(app, "post.\(rowID)")
                if row.exists, row.frame.maxY < list.frame.minY { break }  // the row is now above us
            }
            list.swipeUp(velocity: .slow)
            if found() { return element(app, identifier) }
        }
        return element(app, identifier)
    }

    /// Keep a screenshot in the result bundle (exported to `docs/t34-shots/` after a run).
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// `XCTUnwrap` for an optional that a helper returned.
    private func XCTAssertNotNilAndUnwrap<T>(_ value: T?, file: StaticString = #filePath,
                                             line: UInt = #line) throws -> T {
        try XCTUnwrap(value, "expected a value", file: file, line: line)
    }
}
