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
///
/// **Sidebar requirement (fixture, measured 2026-10-30).** The suite opens `t36-threads` from the
/// channel sidebar, so the row has to be *reachable*, not **above the fold**. On the shared fixture
/// server account `perfprobe` is in **351** channels of team `perf` (`POST /users/login` →
/// `/users/me/teams/{id}/channels`), the sidebar's content is **5 095 pt** tall inside its 874 pt
/// viewport and the rows materialised at rest are `T8G probe 00xx` — nothing near `t36-threads`.
/// The list is a `ScrollView` + `LazyVStack` (`NativeChannelSidebarContent`), so a row outside the
/// window is *absent from the accessibility tree*, and the first version of this suite read that as
/// "the sidebar does not list the channel" (5/5 red, `docs/t_c941e3d3-build-note.md`). `openChannel`
/// therefore scrolls the sidebar's own surface through
/// `ShellSettle.revealSidebarChannel` and reports the swipe count — the fixture may hold any number
/// of channels, and a dedicated single-channel account is **not** required.
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
    ///  * **in order**: the oracle is chronology — `create_at` ascending, id as the tiebreak — read
    ///    from the server's own posts. It is deliberately *not* the `order` array
    ///    `GET /posts/{id}/thread` returns: measured on 9.11.19 that array is not a sequence (2 of 6
    ///    threads came back with a newer reply before an older one, identically across five repeated
    ///    GETs), and comparing against it would fail a pane that draws the conversation correctly.
    ///  * **deleted**: a reply is deleted over the **socket** while the pane is open. The server
    ///    omits a deleted reply from `/posts/{id}/thread` (measured, `docs/t36-build-note.md` §2), so
    ///    nothing but the reader's own copy can produce a tombstone — if the app drops the event the
    ///    row vanishes and this test fails.
    func testTheThreadDrawsTheWholeChainInOrderIncludingTheCollapsedAndDeletedReply() throws {
        // A chain of this test's own, at the **newest** end of the channel. The seeded chain is
        // hundreds of posts back now, and scrolling to it took up to 24 swipes per run — enough
        // accessibility traffic to crash the simulator's logging machinery (measured: SIGSEGV inside
        // `firehose_client_start_quarantine` while `revealPost` enumerated the list). A fresh chain is
        // on the first screen, so the row and frame assertions are stable.
        let stamp = Int(Date().timeIntervalSince1970)
        let root = try post(message: "t36 chain root \(stamp)", rootID: nil, as: secondToken)
        assertAuthoredBy(secondUserID, root, "the chain root")
        let rootID = try XCTUnwrap(root["id"] as? String)
        for index in 1...3 {
            // Strictly increasing `create_at`, 150 ms apart: this is what makes "in order" a claim about
            // chronology rather than about the server's (measured non-sequential) `order` array.
            Thread.sleep(forTimeInterval: 0.15)
            let author = index.isMultiple(of: 2) ? secondToken! : token!
            _ = try post(message: "T36 main reply \(index) \(stamp)", rootID: rootID, as: author)
        }
        let chain = try threadPostIDs(rootID)

        // The oracles, before the app is even launched.
        XCTAssertEqual(chain.first, rootID, "the thread answers root-first")
        let fixtureEntries = try fixtureReplies(rootID)
        XCTAssertEqual(fixtureEntries.count, 3,
                       "the fixture chain is a root and three replies; server answered \(fixtureEntries)")
        // The order this suite asserts is **chronology**, taken from the server's own `create_at`
        // values — never the server's `order` array: measured on 9.11.19, 2 of 6 threads whose replies
        // were created with strictly increasing `create_at` came back with a newer reply before an
        // older one, identically across five repeated GETs (probe_order.py). The evidence is attached,
        // not asserted, so a server that starts answering chronologically does not fail this test.
        let expected = chronological(fixtureEntries)
        let serverOrder = fixtureEntries.map(\.id)
        let comparison = "server order: \(serverOrder)\nchronology  : \(expected)"
        let evidence = XCTAttachment(string: comparison)
        evidence.name = "t36-server-order-vs-chronology"
        evidence.lifetime = .keepAlways
        add(evidence)
        for reply in fixtureEntries {
            XCTAssertTrue(chain.contains(reply.id),
                          "every fixture reply must be part of the thread the server answers")
        }

        let channelPage = try channelPosts(channelID, collapsedThreads: true, perPage: 200)
        let channelIDs = Set(channelPage.map { $0["id"] as? String ?? "" })
        XCTAssertTrue(channelIDs.contains(rootID), "the collapsed page must carry the root")
        for reply in chain.dropFirst() {
            XCTAssertFalse(channelIDs.contains(reply),
                           "collapsedThreads=true must hide reply \(reply) from the channel page; "
                           + "the 'the channel view collapses it, the thread shows it' claim needs both halves")
        }

        let app = launchAndOpenChannel()
        XCTAssertTrue(revealPost(app, rootID, maxSwipes: 4).exists,
                      "the root must be a row of the channel:\n\(app.debugDescription)")
        // The same page, drawn: the replies are not channel rows.
        for reply in chain.dropFirst() {
            XCTAssertFalse(element(app, "post.\(reply)").exists,
                           "reply \(reply) is not a channel row — the channel view is collapsed")
        }
        attach(app, "t36-01-channel-collapsed")

        openThread(app, rootID: rootID)

        // Every fixture member is drawn, oldest first. The list opens scrolled to the newest reply, so
        // it is scrolled back to the top before the frames are compared.
        let drawn = [rootID] + expected
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
                                 + "— the chain is chronological (\(comparison)); frames were \(frames)")
        }
        attach(app, "t36-02-thread-chain")

        // Deleted reply: a reply this test creates and then deletes, so the fixture is not consumed by
        // an assertion (a deleted reply cannot be re-fetched — see below).
        let victimStamp = Int(Date().timeIntervalSince1970)
        let victimPost = try post(message: "t36 doomed reply \(victimStamp)", rootID: rootID, as: token)
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
        // A thread of this test's own at the newest end of the channel (see the chain test for why: the
        // seeded one needs a long scroll, and scrolling an ever-growing accessibility tree is what
        // crashes the simulator's logging machinery).
        let stamp = Int(Date().timeIntervalSince1970)
        let root = try post(message: "t36 reply fixture root \(stamp)", rootID: nil, as: secondToken)
        assertAuthoredBy(secondUserID, root, "the reply fixture root")
        let rootID = try XCTUnwrap(root["id"] as? String)
        let seeded = try post(message: "t36 reply fixture reply \(stamp)", rootID: rootID, as: token)
        assertAuthoredBy(userID, seeded, "the reply fixture's own reply")
        let before = try threadPostIDs(rootID).count - 1
        XCTAssertEqual(before, 1, "the fixture thread starts with one reply")
        let message = "t36 reply from the app \(stamp)"

        let app = launchAndOpenChannel()
        openThread(app, rootID: rootID, maxSwipes: 4)

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
        tapPaneBack(app)
        XCTAssertTrue(element(app, "channelPostList").waitForExistence(timeout: 30),
                      "Back must return to the channel:\n\(app.debugDescription)")
        let line = element(app, "post.\(rootID).replyCount")
        XCTAssertTrue(waitUntil(timeout: 30) { (line.value as? String) == String(serverCount) },
                      "the root's reply line must carry the server's count \(serverCount), "
                      + "was \(String(describing: line.value))")
        attach(app, "t36-07-channel-reply-line")
    }

    // MARK: - 2b. Two replies in a row from one thread pane (kanban t_56159748)

    /// The report, live: *"I replied to a thread but the message was sent to the channel."*
    ///
    /// One thread pane, one cached composer, two sends without leaving the pane or re-opening the
    /// thread — the second send used to arrive as a **top-level channel post** (the composer had
    /// silently dropped to `.newPost` after the first). The server is the oracle: a reply carries
    /// `root_id == rootID`, a channel post carries none, and both ids must be rows of the thread.
    func testTwoRepliesInARowFromTheThreadComposerBothLandInTheThread() throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let root = try post(message: "t56159748 root \(stamp)", rootID: nil, as: secondToken)
        assertAuthoredBy(secondUserID, root, "the reply-twice fixture root")
        let rootID = try XCTUnwrap(root["id"] as? String)
        _ = try post(message: "t56159748 seed reply \(stamp)", rootID: rootID, as: token)

        let app = launchAndOpenChannel()
        openThread(app, rootID: rootID, maxSwipes: 4)

        let first = "t56159748 first reply \(stamp)"
        try sendInThread(app, first)
        let firstPost = try waitForPost(withMessage: first, channelID: channelID, timeout: 40)
        XCTAssertEqual(firstPost["root_id"] as? String, rootID,
                       "the first reply belongs to the thread")

        // The same pane, the same composer: nothing was reopened, nothing re-armed.
        let second = "t56159748 second reply \(stamp)"
        try sendInThread(app, second)
        let secondPost = try waitForPost(withMessage: second, channelID: channelID, timeout: 40)
        XCTAssertEqual(secondPost["root_id"] as? String, rootID,
                       "the second reply from the same thread pane must stay in the thread — an "
                       + "absent root_id is the channel post this card reported")
        attach(app, "t56159748-01-second-reply")

        let threadIDs = try threadPostIDs(rootID)
        let firstID = try XCTUnwrap(firstPost["id"] as? String)
        let secondID = try XCTUnwrap(secondPost["id"] as? String)
        XCTAssertTrue(threadIDs.contains(firstID) && threadIDs.contains(secondID),
                      "both replies must be rows of the thread (server list: \(threadIDs))")
        XCTAssertEqual(secondPost["channel_id"] as? String, channelID,
                       "and the thread's channel is still this channel")
    }

    // MARK: - 2c. The count belongs to a root in the channel (kanban t_0833c752)

    /// The owner's report: *"inside the thread view every reply shows a number of replies. It should
    /// only appear in the channel view, and only for a thread that actually has replies."*
    ///
    /// This is the half the reader must still be able to use: in the **channel timeline** the root
    /// draws exactly one reply line, it is tappable, and it opens the thread. `t0833` fixtures are
    /// created fresh at the newest end so the row is on the first screen.
    func testTheChannelRootCarriesExactlyOneTappableReplyLine() throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let root = try post(message: "t0833 line root \(stamp)", rootID: nil, as: secondToken)
        assertAuthoredBy(secondUserID, root, "the reply-line root")
        let rootID = try XCTUnwrap(root["id"] as? String)
        for index in 1...3 {
            let reply = try post(message: "t0833 line reply \(index) \(stamp)",
                                 rootID: rootID, as: token)
            assertAuthoredBy(userID, reply, "reply \(index) of the reply-line thread")
        }

        let app = launchAndOpenChannel()
        XCTAssertTrue(revealPost(app, rootID).waitForExistence(timeout: 40),
                      "the fresh root must be on the channel's first screen:\n\(app.debugDescription)")

        let matches = app.descendants(matching: .any)
            .matching(identifier: "post.\(rootID).replyCount")
        XCTAssertTrue(waitUntil(timeout: 30) { matches.count == 1 },
                      "a root with three replies must draw exactly one reply line, got "
                      + "\(matches.count) (the server's own count is 3):\n\(app.debugDescription)")
        let line = matches.firstMatch
        XCTAssertTrue(line.isHittable, "the reply line must be a control, not a label")
        XCTAssertEqual(line.value as? String, "3",
                       "the line carries the server's count of the thread's replies")
        attachScreenshot("t0833-01-channel-root-reply-line")

        line.tap()
        XCTAssertTrue(element(app, "threadPane").waitForExistence(timeout: 40),
                      "the reply line must open the thread:\n\(app.debugDescription)")
        XCTAssertTrue(element(app, "threadPostList").waitForExistence(timeout: 40),
                      "the thread's post list must mount:\n\(app.debugDescription)")
        attachScreenshot("t0833-02-thread-opened-from-the-line")
    }

    /// The thread surface's own **root** row: no reply-count element at all.
    ///
    /// Upstream draws its overview only when `location !== Screens.THREAD`
    /// (`post_list/post/post.tsx`), and this pane's header (`threadPane.subtitle`) is where the count
    /// belongs. A hidden element would be just as wrong as a drawn one: this asserts absence of the
    /// identifier, not absence of text.
    func testTheThreadRootRowCarriesNoReplyLine() throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let root = try post(message: "t0833 thread root \(stamp)", rootID: nil, as: secondToken)
        assertAuthoredBy(secondUserID, root, "the thread-root fixture")
        let rootID = try XCTUnwrap(root["id"] as? String)
        let reply = try post(message: "t0833 thread reply \(stamp)", rootID: rootID, as: token)
        assertAuthoredBy(userID, reply, "the thread-root reply")
        let replyID = try XCTUnwrap(reply["id"] as? String)

        let app = launchAndOpenChannel()
        // The line exists in the channel — that is what opens the thread, and the control for it.
        openThread(app, rootID: rootID)
        XCTAssertTrue(element(app, "thread.post.\(rootID)").waitForExistence(timeout: 40),
                      "the thread must draw its root row:\n\(app.debugDescription)")
        XCTAssertTrue(element(app, "thread.post.\(replyID)").waitForExistence(timeout: 40),
                      "the thread must draw its reply row:\n\(app.debugDescription)")

        XCTAssertFalse(element(app, "post.\(rootID).replyCount").waitForExistence(timeout: 5),
                       "the thread pane's root row must not repeat the reply count — the pane's "
                       + "header carries it:\n\(app.debugDescription)")
        let subtitle = element(app, "threadPane.subtitle")
        XCTAssertTrue(subtitle.waitForExistence(timeout: 10),
                      "the count's home inside the thread is the pane header")
        XCTAssertTrue(subtitle.label.lowercased().contains("reply"),
                      "the header must name the replies the count belongs to, got: "
                      + "\u{201C}\(subtitle.label)\u{201D}")
        attachScreenshot("t0833-03-thread-root-without-a-reply-line")
    }

    /// Every reply row of an open thread: no reply-count element on any of them.
    ///
    /// This is the sentence the owner read. The server hands the thread's total to each reply
    /// (`reply_count: 3` on every post of a three-reply thread, measured), so both fixes are
    /// needed to make it true: the row zeroes a reply's count and the thread surface draws none.
    func testNoReplyRowInTheThreadCarriesAReplyLine() throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let root = try post(message: "t0833 replies root \(stamp)", rootID: nil, as: secondToken)
        assertAuthoredBy(secondUserID, root, "the reply-rows fixture root")
        let rootID = try XCTUnwrap(root["id"] as? String)
        var replyIDs: [String] = []
        for index in 1...3 {
            let reply = try post(message: "t0833 replies \(index) \(stamp)",
                                 rootID: rootID, as: token)
            assertAuthoredBy(userID, reply, "reply \(index) of the reply-rows thread")
            replyIDs.append(try XCTUnwrap(reply["id"] as? String))
        }

        let app = launchAndOpenChannel()
        openThread(app, rootID: rootID)
        for replyID in replyIDs {
            XCTAssertTrue(revealThreadPost(app, replyID).waitForExistence(timeout: 30),
                          "reply \(replyID) must be a row of the thread:\n\(app.debugDescription)")
            XCTAssertFalse(element(app, "post.\(replyID).replyCount").exists,
                           "reply \(replyID) must not draw a reply count in the thread pane:\n"
                           + "\(app.debugDescription)")
        }
        attachScreenshot("t0833-04-thread-replies-without-reply-lines")
    }

    /// A root with **no replies** draws nothing, even in the channel timeline.
    ///
    /// `thread_overview.tsx` returns `null` at `repliesCount === 0`; ours used to draw as soon as a
    /// count was non-zero, so this pins the other edge of the same rule.
    func testARootWithNoRepliesCarriesNoReplyLine() throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let root = try post(message: "t0833 lonely root \(stamp)", rootID: nil, as: secondToken)
        assertAuthoredBy(secondUserID, root, "the no-replies root")
        let rootID = try XCTUnwrap(root["id"] as? String)

        let app = launchAndOpenChannel()
        XCTAssertTrue(revealPost(app, rootID).waitForExistence(timeout: 40),
                      "the fresh root must be on the channel's first screen:\n\(app.debugDescription)")
        XCTAssertFalse(element(app, "post.\(rootID).replyCount").waitForExistence(timeout: 5),
                       "a post with no replies must draw no reply line:\n\(app.debugDescription)")
        attachScreenshot("t0833-05-channel-root-without-replies")
    }

    // MARK: - 3. Follow, unfollow, and the paged followed-threads list

    func testFollowPersistsAndTheFollowedThreadsListPages() throws {
        let stamp = Int(Date().timeIntervalSince1970)
        // A fresh thread the app has never seen, so the list assertions do not depend on what an
        // earlier run read: root by the other author, then a reply by *me*.
        let root = try post(message: "t36 follow fixture \(stamp)", rootID: nil, as: secondToken)
        assertAuthoredBy(secondUserID, root, "the fixture root")
        let rootID = try XCTUnwrap(root["id"] as? String)
        let reply = try post(message: "t36 follow reply \(stamp)", rootID: rootID, as: token)
        assertAuthoredBy(userID, reply, "the fixture reply")
        XCTAssertEqual(reply["root_id"] as? String, rootID, "the fixture reply belongs to this thread")

        // The follow is **written**, not assumed. T36-AV F2 measured that a fixture relying on
        // "replying follows a thread" has no evidence at all: the reply was silently authored by the
        // other account (a shared cookie jar), so no follow was ever created for me and the list was
        // right to omit the thread. The fixture now states the follow explicitly and proves the
        // thread is on the same page the app will ask for — *before* the app launches.
        try follow(rootID)
        let followed = try XCTUnwrap(fetchThread(rootID),
                                     "an explicitly followed thread must answer 200 for me")
        XCTAssertEqual(followed.replyCount, 1, "the fixture thread holds exactly my one reply")
        let listedBeforeLaunch = try XCTUnwrap(teamThreadEntry(rootID),
                                               "the followed thread must be in GET …/threads?per_page=60 "
                                               + "before the app is launched (T36-AV F2)")
        XCTAssertEqual(listedBeforeLaunch.unreadReplies, 0,
                       "a fresh fixture thread starts with nothing unread")

        let app = launchAndOpenChannel()
        let serverThreads = try teamThreads()
        XCTAssertGreaterThan(serverThreads.count, 60,
                             "the fixture must hold more than one 60-row page, it holds \(serverThreads.count)")
        // A thread beyond the first page: only a paged list can draw it.
        let deepID = try XCTUnwrap(serverThreads[62].id)

        element(app, "nativeChannelThreadsButton").tap()
        XCTAssertTrue(element(app, "nativeThreadsList").waitForExistence(timeout: 40),
                      "the Threads button must open the followed list:\n\(app.debugDescription)")

        // T36-AV F3: the counter line and the rows are one state. An empty `totals` drawn over a
        // page of rows read "No threads yet" above a full list; they must agree now.
        let subtitle = element(app, "globalThreads.subtitle")
        XCTAssertTrue(subtitle.waitForExistence(timeout: 20),
                      "the list must draw its counter line:\n\(app.debugDescription)")
        XCTAssertFalse(threadRows(app).isEmpty, "the list must draw rows — the fixture has \(serverThreads.count) threads")
        XCTAssertNotEqual(subtitle.label, "No threads yet",
                          "an empty counter line must not be drawn over a non-empty page (T36-AV F3)")
        XCTAssertTrue(subtitle.label.contains("thread"),
                      "the counter line names the threads it counts, was \(subtitle.label.debugDescription)")
        attach(app, "t36-08-global-threads")

        // Open a thread from the list and follow/unfollow it: the bell is the UI's only follow control.
        let row = element(app, "globalThreads.row.\(rootID)")
        XCTAssertTrue(row.waitForExistence(timeout: 30),
                      "the thread I followed is on the server's page before the app launched and must be "
                      + "a row, newest activity first:\n\(app.debugDescription)")
        // The row is the thread I made, drawn newest-first, with the root's own text as its preview.
        XCTAssertTrue(row.label.contains("t36 follow fixture"),
                      "the row previews the root it was read from, was \(row.label.debugDescription)")
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
        tapPaneBack(app)
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
        assertAuthoredBy(secondUserID, root, "the unread fixture root")
        let rootID = try XCTUnwrap(root["id"] as? String)
        let mine = try post(message: "t36 unread mine \(stamp)", rootID: rootID, as: token)
        assertAuthoredBy(userID, mine, "my reply in the unread fixture")
        // Written, not assumed (T36-AV F2): a thread whose follow exists only as a side effect of a
        // reply cannot be asserted about, because the reply's authorship is what was wrong.
        try follow(rootID)
        // A gap, so their reply is unambiguously *after* my last read (the server compares
        // millisecond timestamps, and two calls on localhost can land in the same one).
        Thread.sleep(forTimeInterval: 0.35)
        let theirs = try post(message: "t36 unread theirs \(stamp)", rootID: rootID, as: secondToken)
        assertAuthoredBy(secondUserID, theirs, "the reply that should leave the thread unread")

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
        tapPaneBack(app)
        XCTAssertTrue(waitUntil(timeout: 25) {
            !self.element(app, "globalThreads.unread.\(rootID)").exists
        }, "the badge must clear once the server reports the thread read:\n\(app.debugDescription)")
        attach(app, "t36-13-read-cleared")
    }

    // MARK: - 9. The unread divider inside the pane (t_dbf5395b)

    /// Opening a thread that has unread replies draws the "New messages" line in front of the first
    /// reply the reader has not read — placed from the server's own `last_viewed_at`, through the same
    /// `PostListDerivation` the channel timeline uses.
    ///
    /// What makes this assertable instead of a race:
    ///  * the fixture **writes** the read marker (`PUT …/read/{ts}`) and posts the unseen replies
    ///    after it, so "first unseen" is a fact about the server, not about when the app launched;
    ///  * opening the pane marks the thread read, so the server's `unread_replies` drops to **0**
    ///    while the line stays on screen. A divider drawn straight from the read answer would be gone
    ///    by then (`last_viewed_at` is now); upstream keeps `viewed_at` fixed for the thread being read
    ///    (`isThreadVisible` in `app/actions/websocket/threads.ts`), and this asserts that rule end to
    ///    end rather than trusting the unit case alone;
    ///  * the pane's line has its own identifier (`threadNewMessages`), so this cannot pass on the
    ///    channel timeline's `channelNewMessages` — which must not be on screen at all here.
    func testTheUnreadDividerSitsBeforeTheFirstUnseenReply() throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let root = try post(message: "t36 divider root \(stamp)", rootID: nil, as: secondToken)
        assertAuthoredBy(secondUserID, root, "the divider fixture root")
        let rootID = try XCTUnwrap(root["id"] as? String)
        // A reply of mine, so the fixture also has a row on the *seen* side of the marker.
        let mine = try post(message: "t36 divider seen \(stamp)", rootID: rootID, as: token)
        assertAuthoredBy(userID, mine, "the reply before the read marker")
        let seenID = try XCTUnwrap(mine["id"] as? String)
        try follow(rootID)

        // The read marker itself: everything created up to here is read. Written, not assumed.
        let marker = try markThreadRead(rootID)
        // A gap larger than a scheduler hiccup, so the replies below are unambiguously newer.
        Thread.sleep(forTimeInterval: 0.4)
        let unseen1 = try post(message: "t36 divider unseen one \(stamp)", rootID: rootID, as: secondToken)
        assertAuthoredBy(secondUserID, unseen1, "the first unseen reply")
        let firstUnseenID = try XCTUnwrap(unseen1["id"] as? String)
        Thread.sleep(forTimeInterval: 0.2)
        let unseen2 = try post(message: "t36 divider unseen two \(stamp)", rootID: rootID, as: secondToken)
        assertAuthoredBy(secondUserID, unseen2, "the second unseen reply")

        // The oracle, from the server: two unread replies, and the marker really is where we put it.
        var entry: ThreadEntry?
        XCTAssertTrue(waitUntil(timeout: 20) {
            entry = self.fetchThread(rootID)
            return entry?.unreadReplies == 2
        }, "the fixture leaves two unread replies; the server says \(String(describing: entry))")
        let lastViewedAt = try XCTUnwrap(entry?.lastViewedAt,
                                         "the thread row must carry last_viewed_at — the divider is placed from it")
        XCTAssertEqual(lastViewedAt, marker,
                       "the fixture's read marker is what the server stores as last_viewed_at")

        let entries = try threadEntries(rootID)
        let unseen = chronological(entries.filter { $0.createAt > lastViewedAt })
        XCTAssertEqual(unseen.first, firstUnseenID,
                       "by the server's own create_at the first unseen post is the fixture's first unseen "
                       + "reply; the thread answers \(entries) with last_viewed_at \(lastViewedAt)")
        XCTAssertTrue(unseen.contains(try XCTUnwrap(unseen2["id"] as? String)))
        XCTAssertFalse(unseen.contains(seenID), "my reply was created before the marker, so it is read")

        let app = launchAndOpenChannel()
        element(app, "nativeChannelThreadsButton").tap()
        XCTAssertTrue(element(app, "nativeThreadsList").waitForExistence(timeout: 40),
                      "the Threads button must open the followed list:\n\(app.debugDescription)")
        let row = element(app, "globalThreads.row.\(rootID)")
        XCTAssertTrue(row.waitForExistence(timeout: 40),
                      "the fixture thread must be a row of the followed list:\n\(app.debugDescription)")
        row.tap()
        XCTAssertTrue(element(app, "threadPane").waitForExistence(timeout: 40),
                      "the unread thread must open its pane:\n\(app.debugDescription)")

        // The read that opening performs lands on the server…
        XCTAssertTrue(waitUntil(timeout: 25) {
            (self.fetchThread(rootID)?.unreadReplies ?? -1) == 0
        }, "opening a thread marks it read on the server (T36-AV criterion 4)")
        // …and the line it drew is still there. That is the whole point: it is not a pre-read frame.
        let divider = element(app, "threadNewMessages")
        XCTAssertTrue(divider.waitForExistence(timeout: 20),
                      "a thread opened with unread replies must draw the divider, and keep it after the "
                      + "read it performs on mount:\n\(app.debugDescription)")
        XCTAssertEqual(divider.label, "New messages")
        XCTAssertFalse(element(app, "channelNewMessages").exists,
                       "the pane's divider carries the pane's identifier, not the channel timeline's")

        let firstUnseen = element(app, "thread.post.\(firstUnseenID)")
        XCTAssertTrue(firstUnseen.waitForExistence(timeout: 20),
                      "the first unseen reply must be a row of the pane:\n\(app.debugDescription)")
        let seenRow = element(app, "thread.post.\(seenID)")
        XCTAssertTrue(seenRow.exists, "the reply before the marker is still a row:\n\(app.debugDescription)")
        XCTAssertLessThan(divider.frame.minY, firstUnseen.frame.minY,
                          "the divider must sit above the first unseen reply; frames: divider "
                          + "\(divider.frame), first unseen \(firstUnseen.frame)")
        XCTAssertGreaterThan(divider.frame.minY, seenRow.frame.minY,
                             "and below the last reply the reader had already seen; frames: divider "
                             + "\(divider.frame), seen \(seenRow.frame)")
        attach(app, "t36-14-pane-divider")
    }

    // MARK: - Server helpers

    struct ThreadEntry {
        let id: String
        let unreadReplies: Int
        let unreadMentions: Int
        let replyCount: Int
        /// The server's own read position for this thread (`last_viewed_at`, ms) — the value the pane
        /// places its unread divider from.
        let lastViewedAt: Int64
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

    private func channelPosts(_ channelID: String, collapsedThreads: Bool = false,
                              perPage: Int = 60) throws -> [[String: Any]] {
        let suffix = collapsedThreads ? "&collapsedThreads=true" : ""
        let json = try getJSON("/api/v4/channels/\(channelID)/posts?per_page=\(perPage)\(suffix)")
        let posts = (json as? [String: Any])?["posts"] as? [String: [String: Any]] ?? [:]
        let order = (json as? [String: Any])?["order"] as? [String] ?? []
        return order.compactMap { posts[$0] }
    }

    /// The chain the server answers for a root, as its `order` array.
    ///
    /// Used for **membership only** ("is this post in the thread at all?"), never for order: on
    /// 9.11.19 that array is not a sequence — 5 of 6 threads created with strictly increasing replies
    /// came back in a different order, stable across five repeated GETs, and this fixture's own chain
    /// (replies created at …838, …868, …897 ms) is answered `868, 838, 897` (T36-AV F1).
    private func threadPostIDs(_ rootID: String) throws -> [String] {
        let json = try getJSON("/api/v4/posts/\(rootID)/thread?perPage=200&collapsedThreads=true")
        return (json as? [String: Any])?["order"] as? [String] ?? []
    }

    /// The thread's posts with the server's own `create_at`, in the server's `order`.
    private func threadEntries(_ rootID: String) throws -> [(id: String, createAt: Int64)] {
        let json = try getJSON("/api/v4/posts/\(rootID)/thread?perPage=200&collapsedThreads=true")
        let posts = (json as? [String: Any])?["posts"] as? [String: [String: Any]] ?? [:]
        let order = (json as? [String: Any])?["order"] as? [String] ?? []
        return order.compactMap { id in
            guard let post = posts[id], let createAt = post["create_at"] as? Int64 else { return nil }
            return (id, createAt)
        }
    }

    /// The three replies of the chain this test creates, with their `create_at`, in the server's order.
    /// Identified by their fixture text so a reply an earlier run added is not mistaken for one.
    private func fixtureReplies(_ rootID: String) throws -> [(id: String, createAt: Int64)] {
        let json = try getJSON("/api/v4/posts/\(rootID)/thread?perPage=200&collapsedThreads=true")
        let posts = (json as? [String: Any])?["posts"] as? [String: [String: Any]] ?? [:]
        let order = (json as? [String: Any])?["order"] as? [String] ?? []
        return order.compactMap { id in
            guard let post = posts[id], let createAt = post["create_at"] as? Int64,
                  let message = post["message"] as? String,
                  message.hasPrefix("T36 main reply ") else { return nil }
            return (id, createAt)
        }
    }

    /// Chronology — `create_at` ascending, id as the tiebreak. This is the order the pane must draw,
    /// and the only order this suite asserts (never the server's `order` array).
    private func chronological(_ entries: [(id: String, createAt: Int64)]) -> [String] {
        entries.sorted { lhs, rhs in
            if lhs.createAt != rhs.createAt { return lhs.createAt < rhs.createAt }
            return lhs.id < rhs.id
        }.map(\.id)
    }

    /// `PUT /users/me/teams/{team}/threads/{thread_id}/following` — follow the thread explicitly.
    ///
    /// A reply *does* follow a thread on this server (measured: one membership row per participant,
    /// `following = true` for the reply's author), but that follow is only real if the reply was
    /// really authored by the account the fixture believes it used — which is exactly what T36-AV F2
    /// got wrong. The fixture therefore writes the follow it then asserts about, and
    /// `assertAuthoredBy` proves the posts' authorship separately.
    private func follow(_ threadID: String) throws {
        var request = URLRequest(url: serverURL.appendingPathComponent(
            "api/v4/users/me/teams/\(teamID!)/threads/\(threadID)/following"))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "XMLHttpRequest")
        request.httpBody = Data("{}".utf8)
        let (_, response) = try synchronous(request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200,
                       "the fixture's explicit follow must be accepted")
    }

    /// `PUT /users/me/teams/{team}/threads/{thread_id}/read/{timestamp}` — write the read marker the
    /// unread divider is placed from, and answer the timestamp that was sent.
    ///
    /// Measured on the 9.11.19 fixture: the answer is the thread object and carries
    /// `last_viewed_at` = the timestamp that was sent, which is why a test can assert the marker's
    /// exact position instead of "some time around now".
    @discardableResult
    private func markThreadRead(_ threadID: String) throws -> Int64 {
        let marker = Int64(Date().timeIntervalSince1970 * 1000)
        var request = URLRequest(url: serverURL.appendingPathComponent(
            "api/v4/users/me/teams/\(teamID!)/threads/\(threadID)/read/\(marker)"))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "XMLHttpRequest")
        request.httpBody = Data("{}".utf8)
        let (data, response) = try synchronous(request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200,
                       "the fixture's read marker must be accepted")
        let answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(answer?["last_viewed_at"] as? Int64, marker,
                       "the read answer carries the marker it stored, so the divider's placement is exact")
        return marker
    }

    /// The server's own list entry for one thread, from the same page shape the app asks for.
    private func teamThreadEntry(_ threadID: String, perPage: Int = 60) throws -> ThreadEntry? {
        try teamThreads(perPage: perPage).first { $0.id == threadID }
    }

    /// A fixture post must be authored by the account the test intended: the identity of a fixture
    /// call is its `Authorization` header, and a cookie in the session's jar used to silently
    /// re-attribute posts to the other author (T36-AV F2 — the root cause of the missing follow).
    private func assertAuthoredBy(_ expectedID: String, _ post: [String: Any], _ what: String) {
        XCTAssertEqual(post["user_id"] as? String, expectedID,
                       "\(what) must be authored by the intended account (T36-AV F2: a shared "
                       + "URLSession cookie jar re-attributed fixture posts to the other author)")
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
                               lastViewedAt: entry["last_viewed_at"] as? Int64 ?? 0,
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
                           lastViewedAt: entry["last_viewed_at"] as? Int64 ?? 0,
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

    // MARK: - 8. The thread pane's leading control (t_1617a61c)

    /// **Entry point 1 — the channel timeline.** The pane's header carries one leading control
    /// (`threadPane.back`) whose label names the destination, and it returns to **that** channel: the
    /// router's own value names its id, the post is gone, and the timeline is exactly where the
    /// reader left it (the pushed channel pane is never destroyed, so its `UIScrollView` offset and
    /// the row at the top are unchanged — read from the scroll view through the geometry seam, not
    /// inferred from a frame).
    func testTheThreadHeaderBackReturnsToTheChannelItWasOpenedFrom() throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let root = try post(message: "t1617 back root \(stamp)", rootID: nil, as: secondToken)
        assertAuthoredBy(secondUserID, root, "the back-control root")
        let rootID = try XCTUnwrap(root["id"] as? String)
        let reply = try post(message: "t1617 back reply \(stamp)", rootID: rootID, as: token)
        assertAuthoredBy(userID, reply, "the back-control reply")

        let app = launchAndOpenChannel(extraArguments: ["-uiTestExposeNavigationLocation",
                                                        "-uiTestExposeScrollGeometry"])
        // Put the root on screen and note where the timeline is standing.
        XCTAssertTrue(revealPost(app, rootID).waitForExistence(timeout: 40),
                      "the fresh root must be on the channel's first screen:\n\(app.debugDescription)")
        let before = scrollGeometry(app)
        XCTAssertNotNil(before,
                        "`-uiTestExposeScrollGeometry` must publish `channelPostList.scrollGeometry`:\n"
                        + "\(app.debugDescription)")

        openThread(app, rootID: rootID)

        let back = element(app, "threadPane.back")
        XCTAssertTrue(back.waitForExistence(timeout: 20),
                      "the thread header must carry its leading control:\n\(app.debugDescription)")
        XCTAssertEqual(back.label, "Back to #\(channelName)",
                       "the control names its destination, not a bare glyph")
        XCTAssertEqual(navigationLocation(app)?["entry"], "channel",
                       "the router must know the thread was opened from a timeline")
        attachScreenshot("t1617a-01-thread-header-back")

        back.tap()

        XCTAssertTrue(element(app, "channelPostList").waitForExistence(timeout: 40),
                      "Back must show the channel pane again:\n\(app.debugDescription)")
        let location = navigationLocation(app)
        XCTAssertEqual(location?["pane"], "channel")
        XCTAssertEqual(location?["channel"], channelID,
                       "`navigation.location.channelID` is the thread root's channel")
        XCTAssertEqual(location?["post"], "none", "the thread is closed")
        XCTAssertEqual(location?["team"], teamID, "the same team")

        let after = scrollGeometry(app)
        XCTAssertNotNil(after)
        XCTAssertEqual(after?.offset ?? .nan, before?.offset ?? .nan, accuracy: 1.0,
                       "the timeline must not move: the reader returns to the place they left "
                       + "(before \(before?.description ?? "none"), after \(after?.description ?? "none"))")
        XCTAssertEqual(after?.top, before?.top,
                       "the same post is at the top of the timeline")
        attachScreenshot("t1617a-02-channel-returned")
    }

    /// **Entry point 2 — the Threads list.** Back from a thread opened as a list row returns to the
    /// list, not to whatever channel was last open (a launch opens the saved channel, so there *is*
    /// one for the old code to return to).
    func testTheThreadHeaderBackFromTheThreadsListReturnsToTheList() throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let root = try post(message: "t1617 list root \(stamp)", rootID: nil, as: secondToken)
        assertAuthoredBy(secondUserID, root, "the list-opened root")
        let rootID = try XCTUnwrap(root["id"] as? String)
        let reply = try post(message: "t1617 list reply \(stamp)", rootID: rootID, as: token)
        assertAuthoredBy(userID, reply, "the list-opened reply")

        let app = launchAndOpenChannel(extraArguments: ["-uiTestExposeNavigationLocation"])
        XCTAssertTrue(ShellSettle.tapTab(ShellSettle.Tab.threads, in: app),
                      "the Threads tab must be reachable:\n\(app.debugDescription)")
        let row = element(app, "globalThreads.row.\(rootID)")
        XCTAssertTrue(row.waitForExistence(timeout: 40),
                      "the thread the fixture just created must be a row of the list:\n"
                      + "\(app.debugDescription)")
        row.tap()

        XCTAssertTrue(element(app, "threadPane").waitForExistence(timeout: 40),
                      "a list row must open the thread:\n\(app.debugDescription)")
        XCTAssertEqual(navigationLocation(app)?["entry"], "threads-list",
                       "the router must know the thread was opened from the list")
        let back = element(app, "threadPane.back")
        XCTAssertTrue(back.waitForExistence(timeout: 20))
        XCTAssertEqual(back.label, "Back to Threads")
        attachScreenshot("t1617a-03-list-thread-header-back")

        back.tap()

        XCTAssertTrue(waitUntil(timeout: 30) { !element(app, "threadPane").exists },
                      "the thread pane must close:\n\(app.debugDescription)")
        XCTAssertTrue(element(app, "nativeThreadsList").waitForExistence(timeout: 40)
                      || element(app, "globalThreads.postList").waitForExistence(timeout: 40),
                      "Back must show the Threads list, not a channel:\n\(app.debugDescription)")
        XCTAssertFalse(element(app, "channelPostList").exists,
                       "Back from a list-opened thread must not land on the last channel")
        XCTAssertTrue(element(app, "globalThreads.row.\(rootID)").exists,
                      "the row the reader came from is still there")
        attachScreenshot("t1617a-04-threads-list-returned")
    }

    /// A full-screen capture attached to the test result (`docs/t1617a-shots/` is exported from it).
    private func attachScreenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The hidden `navigation.location` element (`-uiTestExposeNavigationLocation`), parsed.
    private func navigationLocation(_ app: XCUIApplication) -> [String: String]? {
        let seam = element(app, "navigation.location")
        guard seam.exists else { return nil }
        let raw = seam.value as? String ?? ""
        var parsed: [String: String] = [:]
        for token in raw.split(separator: " ") {
            let parts = token.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { parsed[String(parts[0])] = String(parts[1]) }
        }
        return parsed
    }

    /// One reading of the channel timeline's scroll view (`-uiTestExposeScrollGeometry`).
    private struct Geometry: CustomStringConvertible {
        var offset = 0.0
        var size = 0.0
        var top = "none"
        var description: String { "offset=\(offset) size=\(size) top=\(top)" }
    }

    private func scrollGeometry(_ app: XCUIApplication) -> Geometry? {
        let seam = element(app, "channelPostList.scrollGeometry")
        guard seam.exists else { return nil }
        let raw = seam.value as? String ?? ""
        func number(_ key: String) -> Double? {
            guard let range = raw.range(of: "\(key)=") else { return nil }
            let rest = raw[range.upperBound...]
            return Double(rest.prefix { $0.isNumber || $0 == "-" || $0 == "." })
        }
        var reading = Geometry()
        reading.offset = number("offset") ?? 0
        reading.size = number("size") ?? 0
        if let range = raw.range(of: "top=") {
            reading.top = String(raw[range.upperBound...].prefix { !$0.isWhitespace })
        }
        return reading
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
        Self.fixtureSession.dataTask(with: request) { data, response, error in
            if let error { failure = error }
            if let data, let response { result = (data, response) }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 20)
        if let failure { throw failure }
        guard let result else { throw URLError(.timedOut) }
        return result
    }

    /// The fixture's own session: **no cookie storage, and no cookies sent**.
    ///
    /// This is not tidiness, it is the fix for T36-AV F2 (measured on the pinned 9.11.19 server):
    ///
    ///  * `POST /users/login` answers `Set-Cookie: MMAUTHTOKEN=…; MMUSERID=…; MMCSRF=…` for exactly
    ///    the requests this suite makes (`X-Requested-With: XMLHttpRequest`) — probed on the server;
    ///  * a request that carries **both** `Cookie: MMAUTHTOKEN=<B>` and `Authorization: Bearer <A>` is
    ///    resolved as **B**, and a bogus cookie is a 401 even with A's valid header (probe: six cookie
    ///    shapes, header always `perfprobe`, every result authored by the cookie's user);
    ///  * `URLSession.shared`'s jar is shared by every fixture call in the process, so the suite's
    ///    second login (`t36reply`) **overwrote** the first one's cookie and every later "as me" call
    ///    was authored by `t36reply`. Measured in a log: the reply meant to be `perfprobe`'s was stored
    ///    with `user_id = t36reply` (DB author check), so no follow was ever created for `perfprobe`,
    ///    the app's list was right to omit the row, and each "is it followed?" read was answered for
    ///    the wrong account. That single defect is the whole of F2.
    ///
    /// An ephemeral session with cookies off makes the `Authorization` header the only identity a
    /// fixture call can have — which is what the assertions assume, and what `assertAuthoredBy`
    /// then checks on every fixture post.
    private static let fixtureSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    // MARK: - App helpers

    private func launchAndOpenChannel(extraArguments: [String] = []) -> XCUIApplication {
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
            + extraArguments
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
        // Since t_295b0a32 a signed-in launch opens a channel (the saved one, else the town hall),
        // and the shell pushes the pane *over* the root: `nativeShell` is not in the accessibility
        // tree at all once that happens. Waiting on it alone is a race — measured 2026-11-04, one
        // of these five tests red here while the other four passed — so ask the one helper that
        // answers "are we in?" for both shapes (`ShellSettle.waitForSignedIn`).
        XCTAssertTrue(ShellSettle.waitForSignedIn(app, timeout: 40),
                      "signing in must reach the shell:\n\(app.debugDescription)")
    }

    /// Open the fixture channel from the sidebar.
    ///
    /// The sidebar is lazy and this account is in hundreds of channels, so the row is usually below
    /// the fold: `ShellSettle.revealSidebarChannel` scrolls the sidebar's own surface until the row is
    /// materialised, and the message below reports what the sweep cost so a reader can tell "this
    /// account's channel list does not contain the channel" from "the sweep ran out of steps".
    private func openChannel(_ app: XCUIApplication) {
        let reveal = ShellSettle.revealSidebarChannel(app, channelID: channelID ?? "")
        XCTAssertTrue(reveal.row.waitForExistence(timeout: 40),
                      "the sidebar must list channel \(channelID ?? "") (\(reveal.report)):\n"
                      + "\(app.debugDescription)")
        reveal.row.tap()
        XCTAssertTrue(element(app, "channelPostList").waitForExistence(timeout: 40),
                      "the channel pane must mount:\n\(app.debugDescription)")
    }

    /// Open the thread the way a reader does: the root's reply line under the post.
    private func openThread(_ app: XCUIApplication, rootID: String, maxSwipes: Int = 12) {
        let line = element(app, "post.\(rootID).replyCount")
        XCTAssertTrue(revealPost(app, rootID, maxSwipes: maxSwipes).exists
                      && line.waitForExistence(timeout: 30),
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

    /// Type one message into the **open thread pane's** composer and press Send, then wait for the box
    /// to clear — the send being accepted is what the next send in the same pane depends on.
    private func sendInThread(_ app: XCUIApplication, _ message: String) throws {
        let input = composerInput(app)
        XCTAssertTrue(input.waitForExistence(timeout: 30),
                      "a native thread must offer the reply composer:\n\(app.debugDescription)")
        input.tap()
        input.typeText(message)
        let send = element(app, "channelComposer.send")
        XCTAssertTrue(send.waitForExistence(timeout: 10) && send.isEnabled,
                      "Send must be offered once there is text:\n\(app.debugDescription)")
        send.tap()
        XCTAssertTrue(waitUntil(timeout: 30) {
            let value = input.value as? String ?? ""
            return !value.contains(message)
        }, "the composer must clear after a successful send:\n\(app.debugDescription)")
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

    /// Leave the thread pane by the back button that is actually **enabled**.
    ///
    /// The shell draws a Back of its own in the top bar, and in the thread pane it is present but
    /// `Disabled`; XCUITest matches it first and a tap on it does nothing at all (measured: the follow
    /// test tapped it and stayed on the pane for 30 s). The pane's own back is the enabled one.
    private func tapPaneBack(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let candidates = app.navigationBars.buttons.matching(NSPredicate(format: "label == 'Back'"))
        for index in 0..<candidates.count {
            let candidate = candidates.element(boundBy: index)
            if candidate.exists, candidate.isEnabled {
                candidate.tap()
                return
            }
        }
        XCTFail("no enabled Back button to leave the pane:\n\(app.debugDescription)", file: file, line: line)
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
