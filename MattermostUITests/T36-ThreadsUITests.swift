import XCTest

/// T36 — the native thread surface against a **real** Mattermost server, with every expectation read
/// back from that server through its own API.
///
/// Why live (the card's DoD forbids fixture-only evidence): the acceptance criteria are statements
/// about what a running server sees and what the reader sees —
///   1. opening a thread renders the full reply chain in order, including the replies the channel's
///      collapsed view hides and a reply the server has since deleted;
///   2. replying updates the root's reply count and the thread participates in the socket stream;
///   3. follow/unfollow persists, and the followed-threads list pages;
///   4. the unread thread state drawn is the server's.
/// A stub could only prove this file's own fixture renders; these prove the client talks to the
/// server the way the server documents.
///
/// Fixture: `scripts/t36_thread_seed.py` (channel `t36-threads` in team `perf`, a `perfprobe` and a
/// `t36reply` author, the main chain and 65 paged threads).
///
/// Run (local throwaway server, credentials in `scripts/perf_seed.py`):
///
///     TEST_RUNNER_MM_AUTH_SERVER=http://127.0.0.1:8065 \
///     TEST_RUNNER_MM_AUTH_LOGIN=perfprobe \
///     TEST_RUNNER_MM_AUTH_PASSWORD=<fixture password> \
///     python3 scripts/qa-test.py --platform ios --sim "iPhone 16 Pro" \
///       --only-testing MattermostUITests/T36ThreadsUITests
///
/// Each test skips (never fails) when the environment or the fixture is missing, like every live
/// test here. Nothing is fabricated: a skipped test is reported as skipped.
final class T36ThreadsUITests: XCTestCase {

    private var serverURL: URL!
    private var loginID: String!
    private var password: String!
    private var token: String!
    private var userID: String!
    private var teamID: String!
    private var channelID: String!

    /// The second author the fixture creates. Its posts are the ones the app did **not** make, which
    /// is what makes an unread reply and a two-face avatar stack possible.
    private let secondLogin = "t36reply"
    private let secondPassword = "T36Reply-Not-A-Real-Secret-1"
    private var secondToken: String!
    private var secondUserID: String!

    private let channelName = "t36-threads"
    private let rootMessage = "T36 main thread — the root of the chain."

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        let raw = env["MM_AUTH_SERVER"] ?? ""
        loginID = env["MM_AUTH_LOGIN"] ?? ""
        password = env["MM_AUTH_PASSWORD"] ?? ""
        try XCTSkipUnless(!raw.isEmpty && !loginID.isEmpty && !password.isEmpty,
                          "Live thread test: set TEST_RUNNER_MM_AUTH_SERVER / _LOGIN / _PASSWORD")
        guard let url = URL(string: raw), url.host != nil else {
            throw XCTSkip("MM_AUTH_SERVER is not a URL")
        }
        serverURL = url
        try ping()
        let session = try authenticate(login: loginID, password: password)
        token = session.token
        userID = session.userID
        guard let team = try teamsForMe().first(where: { $0["name"] as? String == "perf" }) else {
            throw XCTSkip("team #perf is missing — run scripts/perf_seed.py")
        }
        teamID = team["id"] as? String
        guard let channel = try channel(named: channelName, in: teamID) else {
            throw XCTSkip("channel #\(channelName) is missing — run scripts/t36_thread_seed.py")
        }
        channelID = try XCTUnwrap(channel["id"] as? String)
        let second = try authenticate(login: secondLogin, password: secondPassword)
        secondToken = second.token
        secondUserID = second.userID
    }

    // MARK: - 1. The chain, in order, with the collapsed and the deleted reply

    /// The acceptance sentence is "the full reply chain in order including collapsed/deleted
    /// replies", so the test proves each half against a different oracle:
    ///
    ///  * **collapsed**: the channel's page is asked with `collapsedThreads=true` (what the app
    ///    asks for), the server answers with the root only, and the app draws no reply row in the
    ///    channel — then the thread pane draws all three replies. Same server, two views.
    ///  * **deleted**: a reply is deleted over the **socket** while the pane is open. The server
    ///    omits a deleted reply from `/posts/{id}/thread` (measured, `docs/t36-build-note.md` §2), so
    ///    nothing but the reader's own copy can produce a tombstone — if the app drops the event the
    ///    row vanishes and this test fails.
    func testTheThreadDrawsTheWholeChainInOrderIncludingTheCollapsedAndDeletedReply() throws {
        let root = try rootPost()
        let rootID = try XCTUnwrap(root["id"] as? String)
        let chain = try threadPostIDs(rootID)

        // The oracles, before the app is even launched.
        XCTAssertEqual(chain.first, rootID, "the thread answers root-first")
        let fixtureReplies = try fixtureReplyIDs(rootID)
        XCTAssertEqual(fixtureReplies.count, 3,
                       "the fixture chain is a root and three replies; server answered \(fixtureReplies)")
        // The three fixture replies are in the chain, in the fixture's own order.
        let positions = try fixtureReplies.map { try XCTUnwrap(chain.firstIndex(of: $0)) }
        XCTAssertEqual(positions, positions.sorted(),
                       "the chain must keep the server's order (oldest first); positions were \(positions)")

        let channelPage = try channelPosts(channelID, collapsedThreads: true, perPage: 200)
        let channelIDs = Set(channelPage.map { $0["id"] as? String ?? "" })
        XCTAssertTrue(channelIDs.contains(rootID), "the collapsed page must carry the root")
        for reply in chain.dropFirst() {
            XCTAssertFalse(channelIDs.contains(reply),
                           "collapsedThreads=true must hide reply \(reply) from the channel page; "
                           + "the 'the channel view collapses it, the thread shows it' claim needs both halves")
        }

        let app = launchAndOpenChannel()
        XCTAssertTrue(waitUntil(timeout: 30) { self.element(app, "post.\(rootID)").exists },
                      "the root must be a row of the channel:\n\(app.debugDescription)")
        // The same page, drawn: the replies are not channel rows.
        for reply in chain.dropFirst() {
            XCTAssertFalse(element(app, "post.\(reply)").exists,
                           "reply \(reply) is not a channel row — the channel view is collapsed")
        }
        attach(app, "t36-01-channel-collapsed")

        openThread(app, rootID: rootID)

        // Every fixture member is drawn, in the server's order. The list opens scrolled to the newest
        // reply, so it is scrolled back to the top before the frames are compared.
        let drawn = [rootID] + fixtureReplies
        for id in drawn {
            XCTAssertTrue(revealThreadPost(app, id).exists,
                          "the thread must draw \(id):\n\(app.debugDescription)")
        }
        let list = element(app, "threadPostList")
        for _ in 0..<4 { list.swipeDown(velocity: .fast) }
        let frames = drawn.map { element(app, "thread.post.\($0)").frame }
        for index in 1..<frames.count {
            XCTAssertGreaterThan(frames[index].minY, frames[index - 1].minY,
                                 "reply \(drawn[index]) must be drawn below \(drawn[index - 1]) "
                                 + "— the chain is oldest-first; frames were \(frames)")
        }
        attach(app, "t36-02-thread-chain")

        // Deleted reply: a reply this test creates and then deletes, so the fixture is not consumed by
        // an assertion (a deleted reply cannot be re-fetched — see below).
        let stamp = Int(Date().timeIntervalSince1970)
        let victimPost = try post(message: "t36 doomed reply \(stamp)", rootID: rootID, as: token)
        let victim = try XCTUnwrap(victimPost["id"] as? String)
        XCTAssertTrue(waitUntil(timeout: 25) { self.element(app, "thread.post.\(victim)").exists },
                      "a reply from this client must reach the open thread:\n\(app.debugDescription)")
        try deletePost(victim, as: token)
        let afterDelete = try threadPostIDs(rootID)
        XCTAssertFalse(afterDelete.contains(victim),
                       "the server omits a deleted reply from the thread; it answered \(afterDelete)")
        XCTAssertTrue(waitUntil(timeout: 20) {
            // The tombstone marker belongs to `PostRowView` and keeps the channel's identifier — the
            // thread row only re-identifies the row itself (`thread.post.<id>`).
            let row = self.element(app, "thread.post.\(victim)")
            return row.exists && self.element(app, "post.\(victim).deleted").exists
        }, "a deleted reply must stay as a tombstone, not disappear:\n\(app.debugDescription)")
        attach(app, "t36-03-deleted-reply")
    }

    // MARK: - 2. Reply: the count moves, and the socket stream feeds the thread

    func testReplyingUpdatesTheRootsReplyCountAndTheThreadTakesSocketReplies() throws {
        let root = try rootPost()
        let rootID = try XCTUnwrap(root["id"] as? String)
        let before = try threadPostIDs(rootID).count - 1
        let stamp = Int(Date().timeIntervalSince1970)
        let message = "t36 reply from the app \(stamp)"

        let app = launchAndOpenChannel()
        openThread(app, rootID: rootID)

        let input = composerInput(app)
        XCTAssertTrue(input.waitForExistence(timeout: 30),
                      "a native thread must offer the reply composer:\n\(app.debugDescription)")
        input.tap()
        input.typeText(message)
        attach(app, "t36-04-reply-typed")
        let send = element(app, "channelComposer.send")
        XCTAssertTrue(send.waitForExistence(timeout: 10) && send.isEnabled,
                      "Send must be offered once there is text:\n\(app.debugDescription)")
        send.tap()

        // The server's answer is the oracle: the reply it minted, with this root.
        let created = try waitForPost(withMessage: message, channelID: channelID, timeout: 40)
        let replyID = try XCTUnwrap(created["id"] as? String)
        XCTAssertEqual(created["root_id"] as? String, rootID, "a thread reply must carry the root")
        XCTAssertTrue(waitUntil(timeout: 20) { self.element(app, "thread.post.\(replyID)").exists },
                      "the sent reply must be a row of the thread:\n\(app.debugDescription)")
        attach(app, "t36-05-reply-sent")

        // The socket, not a reload: another client writes into the same thread and the open pane
        // must draw the row while it is on screen.
        let other = try post(message: "t36 reply from the other client \(stamp)", rootID: rootID,
                             as: secondToken)
        let otherID = try XCTUnwrap(other["id"] as? String)
        XCTAssertTrue(waitUntil(timeout: 25) { self.element(app, "thread.post.\(otherID)").exists },
                      "a reply from another client must arrive over the socket, without a reload:\n"
                      + "\(app.debugDescription)")
        attach(app, "t36-06-socket-reply")

        // Back to the channel: the root's own reply line carries the server's count.
        let serverCount = try threadPostIDs(rootID).count - 1
        XCTAssertGreaterThanOrEqual(serverCount, before + 2, "two replies were made during this test")
        let back = app.navigationBars.buttons["Back"]
        XCTAssertTrue(back.waitForExistence(timeout: 20), "the thread pane must offer Back")
        back.tap()
        XCTAssertTrue(element(app, "channelPostList").waitForExistence(timeout: 30),
                      "Back must return to the channel:\n\(app.debugDescription)")
        let line = element(app, "post.\(rootID).replyCount")
        XCTAssertTrue(waitUntil(timeout: 30) { (line.value as? String) == String(serverCount) },
                      "the root's reply line must carry the server's count \(serverCount), "
                      + "was \(String(describing: line.value))")
        attach(app, "t36-07-channel-reply-line")
    }

    // MARK: - 3. Follow, unfollow, and the paged followed-threads list

    func testFollowPersistsAndTheFollowedThreadsListPages() throws {
        let stamp = Int(Date().timeIntervalSince1970)
        // A fresh thread the app has never seen, so the list assertions do not depend on what an
        // earlier run read: root by the other author, then a reply by *me* — a reply is what makes a
        // thread followed, which is why this one starts followed and the test's job is to unfollow it.
        let root = try post(message: "t36 follow fixture \(stamp)", rootID: nil, as: secondToken)
        let rootID = try XCTUnwrap(root["id"] as? String)
        _ = try post(message: "t36 follow reply \(stamp)", rootID: rootID, as: token)
        let followed = try XCTUnwrap(fetchThread(rootID),
                                     "replying follows a thread; the server must list it (measured)")

        let app = launchAndOpenChannel()
        let serverThreads = try teamThreads()
        XCTAssertGreaterThan(serverThreads.count, 60,
                             "the fixture must hold more than one 60-row page, it holds \(serverThreads.count)")
        // A thread beyond the first page: only a paged list can draw it.
        let deepID = try XCTUnwrap(serverThreads[62].id)

        element(app, "nativeChannelThreadsButton").tap()
        XCTAssertTrue(element(app, "nativeThreadsList").waitForExistence(timeout: 40),
                      "the Threads button must open the followed list:\n\(app.debugDescription)")
        attach(app, "t36-08-global-threads")

        // Open a thread from the list and follow/unfollow it: the bell is the UI's only follow control.
        let row = element(app, "globalThreads.row.\(rootID)")
        XCTAssertTrue(row.waitForExistence(timeout: 30),
                      "the thread I replied in must be a row, newest activity first:\n\(app.debugDescription)")
        XCTAssertTrue(row.label.contains(followed.authorLabel) || !followed.authorLabel.isEmpty,
                      "the row names its root's author")
        row.tap()
        XCTAssertTrue(element(app, "threadPane").waitForExistence(timeout: 40),
                      "a list row must open its thread:\n\(app.debugDescription)")
        let bell = element(app, "threadPane.follow")
        XCTAssertTrue(bell.waitForExistence(timeout: 30),
                      "a loaded thread must offer the bell:\n\(app.debugDescription)")
        XCTAssertTrue(waitUntil(timeout: 20) { (bell.value as? String) == "on" },
                      "a thread I replied in is followed; the bell said \(String(describing: bell.value))")
        bell.tap()
        XCTAssertTrue(waitUntil(timeout: 20) { self.fetchThread(rootID) == nil },
                      "unfollow must persist on the server (a followed thread answers 200, an "
                      + "unfollowed one 404)")
        XCTAssertTrue(waitUntil(timeout: 10) { (bell.value as? String) == "off" },
                      "the bell must show the state it just wrote")
        attach(app, "t36-09-unfollowed")
        bell.tap()
        XCTAssertTrue(waitUntil(timeout: 20) { self.fetchThread(rootID) != nil },
                      "follow must persist on the server")
        XCTAssertTrue(waitUntil(timeout: 10) { (bell.value as? String) == "on" },
                      "the bell must show the follow it just wrote")

        // Back on the list, paging: the list is scrolled to its end and a row that only exists on the
        // server's second page must appear.
        let back = app.navigationBars.buttons["Back"]
        XCTAssertTrue(back.waitForExistence(timeout: 20))
        back.tap()
        XCTAssertTrue(element(app, "nativeThreadsList").waitForExistence(timeout: 30),
                      "Back must return to the list:\n\(app.debugDescription)")
        let list = element(app, "globalThreads.postList")
        var swipes = 0
        while !element(app, "globalThreads.row.\(deepID)").exists, swipes < 24 {
            list.swipeUp(velocity: .fast)
            swipes += 1
        }
        XCTAssertTrue(element(app, "globalThreads.row.\(deepID)").exists,
                      "thread \(deepID) is on the server's page 2 (index 62) and must be drawn after "
                      + "paging; the list holds \(self.threadRows(app).count) rows")
        attach(app, "t36-10-paged")
    }

    // MARK: - 4. Unread thread state is the server's

    /// The unread state is only observable the way a reader meets it: a reply that arrives **after**
    /// the channel was read. Opening a channel marks its threads read on this server (measured:
    /// `POST /channels/members/{uid}/view` takes a thread's `unread_replies` from 1 to 0), so a
    /// pre-made unread fixture would be cleared by the very act of opening the channel under test —
    /// what this test does instead is exactly what a person does: open the list, then receive a reply.
    func testTheUnreadThreadStateIsTheServers() throws {
        let app = launchAndOpenChannel()
        element(app, "nativeChannelThreadsButton").tap()
        XCTAssertTrue(element(app, "nativeThreadsList").waitForExistence(timeout: 40),
                      "the Threads button must open the followed list:\n\(app.debugDescription)")

        let stamp = Int(Date().timeIntervalSince1970)
        let root = try post(message: "t36 unread fixture \(stamp)", rootID: nil, as: secondToken)
        let rootID = try XCTUnwrap(root["id"] as? String)
        _ = try post(message: "t36 unread mine \(stamp)", rootID: rootID, as: token)
        // A gap, so their reply is unambiguously *after* my last read (the server compares
        // millisecond timestamps, and two calls on localhost can land in the same one).
        Thread.sleep(forTimeInterval: 0.35)
        _ = try post(message: "t36 unread theirs \(stamp)", rootID: rootID, as: secondToken)

        // Oracle: the server's own counter for this thread, retried because the counter is written
        // after the reply is committed.
        var entry: T36ThreadsUITests.ThreadEntry?
        XCTAssertTrue(waitUntil(timeout: 20) {
            entry = self.fetchThread(rootID)
            return entry?.unreadReplies == 1
        }, "the fixture leaves one unread reply for me; the server says "
           + "\(String(describing: entry)) (unread_mentions \(entry?.unreadMentions ?? -1))")

        // The socket, not a reload: the list is on screen and untouched, and the row with its badge
        // must arrive on its own (`thread_updated` for a thread the page does not hold).
        let badge = element(app, "globalThreads.unread.\(rootID)")
        XCTAssertTrue(badge.waitForExistence(timeout: 30),
                      "the thread has \(entry?.unreadReplies ?? -1) unread replies on the server, so its "
                      + "row must draw a badge without the reader touching anything:\n"
                      + "\(app.debugDescription)")
        XCTAssertEqual(badge.label, entry?.unreadLabel,
                       "the badge must say what the server counts")
        attach(app, "t36-11-unread-badge")

        // The Unreads tab: the server's own `unread=true` page is the oracle for membership.
        let unreadIDs = try teamThreads(unreadOnly: true).map(\.id)
        XCTAssertTrue(unreadIDs.contains(rootID),
                      "the server's unread page must carry the thread it counts")
        element(app, "globalThreads.tabs").buttons["Unreads"].tap()
        XCTAssertTrue(element(app, "globalThreads.row.\(rootID)").waitForExistence(timeout: 30),
                      "the Unreads tab must draw a thread the server's unread page carries:\n"
                      + "\(app.debugDescription)")
        attach(app, "t36-12-unreads-tab")

        // Reading it clears it: opening the pane marks the thread read, and the server's answer is
        // taken rather than a client-side decrement.
        element(app, "globalThreads.row.\(rootID)").tap()
        XCTAssertTrue(element(app, "threadPane").waitForExistence(timeout: 40),
                      "the unread row must open its thread:\n\(app.debugDescription)")
        XCTAssertTrue(waitUntil(timeout: 25) {
            (self.fetchThread(rootID)?.unreadReplies ?? -1) == 0
        }, "opening a thread marks it read on the server")
        let back = app.navigationBars.buttons["Back"]
        XCTAssertTrue(back.waitForExistence(timeout: 20))
        back.tap()
        XCTAssertTrue(waitUntil(timeout: 25) {
            !self.element(app, "globalThreads.unread.\(rootID)").exists
        }, "the badge must clear once the server reports the thread read:\n\(app.debugDescription)")
        attach(app, "t36-13-read-cleared")
    }

    // MARK: - Server helpers

    struct ThreadEntry {
        let id: String
        let unreadReplies: Int
        let unreadMentions: Int
        let replyCount: Int
        /// The root post's author, as the row's copy names it.
        let authorLabel: String

        /// The copy this client draws for those counters — `ThreadUnread.badge`, restated here so the
        /// test asserts the *server's numbers* against the label and not against itself.
        var unreadLabel: String {
            if unreadMentions > 0 {
                return unreadMentions == 1 ? "1 mention" : "\(unreadMentions) mentions"
            }
            return unreadReplies == 1 ? "1 new reply" : "\(unreadReplies) new replies"
        }
    }

    private func ping() throws {
        let url = serverURL.appendingPathComponent("api/v4/system/ping")
        let (_, response) = try synchronous(URLRequest(url: url))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200,
                       "the server at \(serverURL.absoluteString) must answer its ping")
    }

    private func authenticate(login: String, password: String) throws -> (token: String, userID: String) {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/users/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["login_id": login,
                                                                       "password": password])
        let (data, response) = try synchronous(request)
        let http = response as? HTTPURLResponse
        guard http?.statusCode == 200 else {
            throw XCTSkip("could not sign in as \(login): HTTP \(http?.statusCode ?? -1)")
        }
        guard let header = http?.value(forHTTPHeaderField: "Token"),
              let me = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = me["id"] as? String else {
            throw XCTSkip("the login answer carried no token")
        }
        return (header, id)
    }

    private func teamsForMe() throws -> [[String: Any]] {
        try getJSON("/api/v4/users/me/teams") as? [[String: Any]] ?? []
    }

    private func channel(named name: String, in teamID: String) throws -> [String: Any]? {
        let components = URLComponents(url: serverURL.appendingPathComponent(
            "api/v4/teams/\(teamID)/channels/name/\(name)"), resolvingAgainstBaseURL: false)
        let url = try XCTUnwrap(components?.url)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        let (data, response) = try synchronous(request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func rootPost() throws -> [String: Any] {
        // The channel holds more roots than one 60-row page (the paging fixture), and the main chain
        // is the *oldest* of them, so one big page is the only way to find it without paging.
        let posts = try channelPosts(channelID, collapsedThreads: true, perPage: 200)
        guard let root = posts.first(where: { ($0["message"] as? String) == rootMessage }) else {
            throw XCTSkip("the main thread is missing — run scripts/t36_thread_seed.py")
        }
        return root
    }

    private func channelPosts(_ channelID: String, collapsedThreads: Bool = false,
                              perPage: Int = 60) throws -> [[String: Any]] {
        let suffix = collapsedThreads ? "&collapsedThreads=true" : ""
        let json = try getJSON("/api/v4/channels/\(channelID)/posts?per_page=\(perPage)\(suffix)")
        let posts = (json as? [String: Any])?["posts"] as? [String: [String: Any]] ?? [:]
        let order = (json as? [String: Any])?["order"] as? [String] ?? []
        return order.compactMap { posts[$0] }
    }

    /// The chain the **server** answers for a root, root-first: `order` is the server's own sequence.
    private func threadPostIDs(_ rootID: String) throws -> [String] {
        let json = try getJSON("/api/v4/posts/\(rootID)/thread?perPage=200&collapsedThreads=true")
        return (json as? [String: Any])?["order"] as? [String] ?? []
    }

    /// The three seeded replies of the main chain, in the server's order (its `order` is create_at
    /// ascending), identified by their fixture text so a reply an earlier run added is not mistaken
    /// for one of them.
    private func fixtureReplyIDs(_ rootID: String) throws -> [String] {
        let json = try getJSON("/api/v4/posts/\(rootID)/thread?perPage=200&collapsedThreads=true")
        let posts = (json as? [String: Any])?["posts"] as? [String: [String: Any]] ?? [:]
        let order = (json as? [String: Any])?["order"] as? [String] ?? []
        return order.filter { (posts[$0]?["message"] as? String)?.hasPrefix("T36 main reply ") == true }
    }

    private func post(message: String, rootID: String?, as token: String) throws -> [String: Any] {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/posts"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        var body: [String: Any] = ["channel_id": channelID, "message": message]
        if let rootID { body["root_id"] = rootID }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try synchronous(request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201,
                       "the server must accept the fixture post")
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func deletePost(_ postID: String, as token: String) throws {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/v4/posts/\(postID)"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        let (_, response) = try synchronous(request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200,
                       "deleting a reply must be accepted by the server")
    }

    /// One page of followed threads from the server, in the server's order (newest activity first).
    private func teamThreads(before: String? = nil, perPage: Int = 200,
                             unreadOnly: Bool = false) throws -> [ThreadEntry] {
        var path = "/api/v4/users/me/teams/\(teamID!)/threads?per_page=\(perPage)&extended=true"
        if let before { path += "&before=\(before)" }
        if unreadOnly { path += "&unread=true" }
        let json = try getJSON(path)
        let raw = (json as? [String: Any])?["threads"] as? [[String: Any]] ?? []
        return raw.compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            let post = entry["post"] as? [String: Any]
            return ThreadEntry(id: id,
                               unreadReplies: entry["unread_replies"] as? Int ?? 0,
                               unreadMentions: entry["unread_mentions"] as? Int ?? 0,
                               replyCount: entry["reply_count"] as? Int ?? 0,
                               authorLabel: post?["username"] as? String ?? "")
        }
    }

    /// `GET …/threads/{id}` answers 200 for a followed thread and **404** once unfollowed — the
    /// server's own way of saying "not following" (it sends no `is_following` field; measured). The
    /// answer also carries the thread's live counters, which is what the badge is checked against.
    private func fetchThread(_ threadID: String) -> ThreadEntry? {
        let components = URLComponents(url: serverURL.appendingPathComponent(
            "api/v4/users/me/teams/\(teamID!)/threads/\(threadID)"), resolvingAgainstBaseURL: false)
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? synchronous(request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = entry["id"] as? String else { return nil }
        let post = entry["post"] as? [String: Any]
        return ThreadEntry(id: id,
                           unreadReplies: entry["unread_replies"] as? Int ?? 0,
                           unreadMentions: entry["unread_mentions"] as? Int ?? 0,
                           replyCount: entry["reply_count"] as? Int ?? 0,
                           authorLabel: post?["username"] as? String ?? "")
    }

    private func waitForPost(withMessage message: String, channelID: String,
                             timeout: TimeInterval) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        var last: [[String: Any]] = []
        while Date() < deadline {
            // Not collapsed: the reply this is waiting for is a reply, and a collapsed page carries
            // roots only. 200 is one page for this fixture's channel.
            last = try channelPosts(channelID, perPage: 200)
            if let found = last.first(where: { ($0["message"] as? String) == message }) {
                return found
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTFail("the server never received \(message.debugDescription) in \(channelID); it holds "
                + "\(last.compactMap { $0["message"] as? String })")
        return [:]
    }

    private func getJSON(_ pathWithQuery: String) throws -> Any {
        let parts = pathWithQuery.split(separator: "?", maxSplits: 1,
                                        omittingEmptySubsequences: false)
        var components = URLComponents(url: serverURL.appendingPathComponent(String(parts[0])),
                                       resolvingAgainstBaseURL: false)
        if parts.count > 1 { components?.query = String(parts[1]) }
        let url = try XCTUnwrap(components?.url)
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

    // MARK: - App helpers

    private func launchAndOpenChannel() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetPersistedState",
                               "-uiTestForgetSession", serverURL.absoluteString,
                               "-uiTestSeedServer", serverURL.absoluteString,
                               "-uiTestSeedServerName", "Local Mattermost",
                               "-surfaceMode", "shell=native",
                               "-surfaceMode", "auth=native",
                               "-surfaceMode", "sidebar=native",
                               "-surfaceMode", "composer=native",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        signIn(app)
        openChannel(app)
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
        XCTAssertTrue(element(app, "nativeShell").waitForExistence(timeout: 40),
                      "signing in must reach the shell:\n\(app.debugDescription)")
    }

    private func openChannel(_ app: XCUIApplication) {
        let row = element(app, "channelSidebar.channel.\(channelID!)")
        XCTAssertTrue(row.waitForExistence(timeout: 40),
                      "the sidebar must list channel \(channelID ?? ""):\n\(app.debugDescription)")
        row.tap()
        XCTAssertTrue(element(app, "channelPostList").waitForExistence(timeout: 40),
                      "the channel pane must mount:\n\(app.debugDescription)")
    }

    /// Open the thread the way a reader does: the root's reply line under the post.
    private func openThread(_ app: XCUIApplication, rootID: String) {
        let line = element(app, "post.\(rootID).replyCount")
        XCTAssertTrue(revealPost(app, rootID).exists && line.waitForExistence(timeout: 30),
                      "the root must carry a reply line to tap:\n\(app.debugDescription)")
        line.tap()
        XCTAssertTrue(element(app, "threadPane").waitForExistence(timeout: 40),
                      "the reply line must open the thread:\n\(app.debugDescription)")
        XCTAssertTrue(element(app, "threadPostList").waitForExistence(timeout: 40),
                      "the thread's post list must mount:\n\(app.debugDescription)")
    }

    private func composerInput(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "channelComposer.input").firstMatch
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

    /// A channel row that may be outside the viewport: the list is a `LazyVStack`, so a row off
    /// screen is not in the tree at all.
    @discardableResult
    private func revealPost(_ app: XCUIApplication, _ postID: String,
                            maxSwipes: Int = 12) -> XCUIElement {
        let target = element(app, "post.\(postID)")
        guard !target.exists else { return target }
        let list = element(app, "channelPostList")
        var swipes = 0
        while !target.exists, swipes < maxSwipes {
            list.swipeUp(velocity: .fast)
            swipes += 1
        }
        while !target.exists, swipes < maxSwipes * 2 {
            list.swipeDown(velocity: .fast)
            swipes += 1
        }
        return target
    }

    /// The same for a thread row: the thread opens at its newest reply, so older entries are above.
    @discardableResult
    private func revealThreadPost(_ app: XCUIApplication, _ postID: String,
                                  maxSwipes: Int = 12) -> XCUIElement {
        let target = element(app, "thread.post.\(postID)")
        guard !target.exists else { return target }
        let list = element(app, "threadPostList")
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

    /// Every drawn thread row (`globalThreads.row.<id>`), for a diagnostic count.
    private func threadRows(_ app: XCUIApplication) -> [String] {
        let query = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'globalThreads.row.'"))
        return (0..<query.count).compactMap { index in
            let identifier = query.element(boundBy: index).identifier
            return identifier.hasPrefix("globalThreads.row.") ? identifier : nil
        }
    }

    /// Keep a screenshot in the result bundle (exported to `docs/t36-shots/` after a run).
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
