// T36 — the thread pane's view model: load, follow/read state, the socket, and paging.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb):
// app/screens/thread/index.tsx + thread.tsx (load, mark-read on appear),
// app/screens/thread/thread_follow_button/thread_follow.tsx (optimistic toggle),
// app/actions/websocket/threads.ts (thread_updated / thread_follow_changed / thread_read_changed),
// app/actions/remote/thread.ts (fetchThread paging by `from_post` + `from_create_at`).
//
// The service is faked at the `ThreadServing` seam: these tests exercise the rules — the root is not
// duplicated, a reply lands once, a follow that fails is reverted, a read moves the badge — with no
// network and no clock.

import XCTest
@testable import Mattermost

@MainActor
final class T36ThreadViewModelTests: XCTestCase {

    // MARK: - Load

    func testLoadDrawsTheRootOnceAndItsRepliesInOrder() async {
        let service = FakeThreadService()
        service.root = post("root", at: 100)
        service.pages = [page(root: "root", replies: [("r1", 200), ("r2", 300)])]
        let model = makeModel(service: service)

        await model.load()

        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.items.compactMap(\.postID), ["root", "r1", "r2"])
        XCTAssertEqual(model.replyCount, 2)
    }

    func testTheRootIsNeverDuplicatedEvenThoughTheEndpointReturnsItAmongTheReplies() async {
        let service = FakeThreadService()
        service.root = post("root", at: 100)
        // Measured: `order` and `posts` both contain the root.
        service.pages = [MMPostList(order: ["root", "r1"],
                                    posts: ["root": post("root", at: 100), "r1": post("r1", at: 200, rootID: "root")])]
        let model = makeModel(service: service)

        await model.load()

        XCTAssertEqual(model.items.compactMap(\.postID), ["root", "r1"])
        XCTAssertEqual(model.loadedReplyIDs, ["r1"])
    }

    /// T36-AV F1: the server's `order` array is **not** chronological, and the pane must not draw it
    /// as if it were.
    ///
    /// Measured on 9.11.19 (`probe_order.py`): of 6 threads whose replies were created with strictly
    /// increasing `create_at`, **2 came back with a newer reply before an older one** — and each thread
    /// answered identically across five repeated GETs, so it is not a race. The drawn order is
    /// therefore `create_at` ascending with the id as tiebreak, and this test exists so nobody
    /// "restores" the server array into the chain. Same shape as the measurement: the newer reply
    /// arrives *before* the older one.
    func testANonChronologicalServerOrderIsDrawnChronologically() async {
        let service = FakeThreadService()
        service.root = post("root", at: 100)
        // The server's array: …868 first, then the older …838, then …897 — exactly the measured shape.
        service.pages = [MMPostList(order: ["root", "r868", "r838", "r897"],
                                    posts: ["root": post("root", at: 100),
                                            "r868": post("r868", at: 868, rootID: "root"),
                                            "r838": post("r838", at: 838, rootID: "root"),
                                            "r897": post("r897", at: 897, rootID: "root")])]
        let model = makeModel(service: service)

        await model.load()

        XCTAssertEqual(model.loadedReplyIDs, ["r838", "r868", "r897"],
                       "the chain is a chronology, not the server's `order` array")
        XCTAssertEqual(model.items.compactMap(\.postID), ["root", "r838", "r868", "r897"],
                       "the root stays first and its replies read oldest-first")
    }

    /// The tiebreak: two replies created in the same millisecond are still drawn in a stable order
    /// (id ascending), which is what keeps a redraw from swapping two rows.
    func testRepliesInTheSameMillisecondAreOrderedById() async {
        let service = FakeThreadService()
        service.root = post("root", at: 100)
        service.pages = [MMPostList(order: ["root", "rb", "ra"],
                                    posts: ["root": post("root", at: 100),
                                            "rb": post("rb", at: 500, rootID: "root"),
                                            "ra": post("ra", at: 500, rootID: "root")])]
        let model = makeModel(service: service)

        await model.load()

        XCTAssertEqual(model.loadedReplyIDs, ["ra", "rb"])
    }

    // MARK: - A thread whose root is gone

    /// T36-AV F5: deleting a thread's root makes the whole chain unreachable — measured on 9.11.19,
    /// `GET /posts/{root}/thread` **and** `GET /posts/{reply}/thread` both answer 404 once the root is
    /// deleted, while `GET …/threads/{root}` can still answer 200. The pane must say so with its
    /// not-found copy, never draw an empty thread and never keep a spinner.
    func testAThreadWhoseRootWasDeletedSaysSoAndDrawsNoEmptyPane() async {
        let service = FakeThreadService()
        service.loadError = MMError.notFound
        let model = makeModel(service: service)

        await model.load()

        XCTAssertEqual(model.phase, .failed("This thread no longer exists."))
        XCTAssertTrue(model.items.isEmpty, "an error screen is not an empty thread")
        XCTAssertNil(model.root)
        XCTAssertFalse(model.items.compactMap(\.postID).contains("root"))
        XCTAssertEqual(ThreadViewModel.message(for: MMError.notFound), "This thread no longer exists.")
    }

    func testAThreadOpenedWithoutAChannelLearnsItFromTheRoot() async {
        let service = FakeThreadService()
        service.root = post("root", at: 100, channel: "chan-from-root")
        // The page's own root is what the pane reads (measured: the endpoint always carries it).
        service.pages = [MMPostList(order: ["root"],
                                    posts: ["root": post("root", at: 100, channel: "chan-from-root")])]
        let model = makeModel(service: service, channelID: "")

        await model.load()

        XCTAssertEqual(model.channelID, "chan-from-root")
    }

    func testAFailedLoadKeepsItsCopyAndARetryRecovers() async {
        let service = FakeThreadService()
        service.root = post("root", at: 100)
        service.loadError = MMError.offline
        let model = makeModel(service: service)

        await model.load()
        guard case .failed(let message) = model.phase else {
            return XCTFail("expected a failed phase, got \(model.phase)")
        }
        XCTAssertTrue(message.contains("offline"))

        service.loadError = nil
        service.pages = [page(root: "root", replies: [("r1", 200)])]
        await model.retry()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.replyCount, 1)
    }

    func testAnEmptyRootIdentifierFailsInsteadOfRequestingTheServer() async {
        let service = FakeThreadService()
        let model = makeModel(service: service, rootID: "")

        await model.load()

        guard case .failed = model.phase else { return XCTFail("expected a failed phase") }
        XCTAssertTrue(service.threadRequests.isEmpty)
    }

    // MARK: - Follow state

    func testAFollowedThreadStartsWithTheBellsFilledAndItsUnreadCounters() async {
        let service = FakeThreadService()
        service.root = post("root", at: 100)
        service.pages = [page(root: "root", replies: [("r1", 200)])]
        service.threadRow = MMThread(id: "root", replyCount: 1, lastReplyAt: 200, post: post("root", at: 100),
                                     unreadReplies: 1, unreadMentions: 0)
        let model = makeModel(service: service)

        await model.load()

        XCTAssertEqual(model.followState, .following)
        XCTAssertEqual(model.unread.replies, 1)
    }

    func testAnUnfollowedThreadIsNotFollowingEvenThoughItsRepliesLoad() async {
        let service = FakeThreadService()
        service.root = post("root", at: 100)
        service.pages = [page(root: "root", replies: [("r1", 200)])]
        service.threadRow = nil    // the server's 404 = "you do not follow it"
        let model = makeModel(service: service)

        await model.load()

        XCTAssertEqual(model.followState, .notFollowing)
        XCTAssertFalse(model.isFollowing)
        XCTAssertEqual(model.loadedReplyIDs, ["r1"])
    }

    func testFollowingWritesToTheServerAndReReadsTheRow() async {
        let service = FakeThreadService()
        service.root = post("root", at: 100)
        service.pages = [page(root: "root", replies: [])]
        service.threadRow = nil
        let model = makeModel(service: service)
        await model.load()

        service.threadRow = MMThread(id: "root", replyCount: 0, post: post("root", at: 100))
        await model.toggleFollow()

        XCTAssertEqual(service.followWrites.map(\.following), [true])
        XCTAssertEqual(model.followState, .following)
    }

    func testAFollowTheServerRefusesIsRevertedAndSaysNothingItCannotBackUp() async {
        let service = FakeThreadService()
        service.root = post("root", at: 100)
        service.pages = [page(root: "root", replies: [])]
        service.threadRow = MMThread(id: "root", replyCount: 0, post: post("root", at: 100))
        let model = makeModel(service: service)
        await model.load()
        XCTAssertEqual(model.followState, .following)

        service.followError = MMError.offline
        await model.toggleFollow()

        XCTAssertEqual(model.followState, .following, "the rejected unfollow must not stick")
        XCTAssertEqual(service.followWrites.count, 1)
    }

    // MARK: - Read state

    func testMarkingReadMovesTheBadgeAndRecordsThatItWasDone() async {
        let service = FakeThreadService()
        service.root = post("root", at: 100)
        service.pages = [page(root: "root", replies: [("r1", 200)])]
        service.threadRow = MMThread(id: "root", replyCount: 1, lastReplyAt: 200, post: post("root", at: 100),
                                     unreadReplies: 1)
        service.readAnswer = MMThread(id: "root", replyCount: 1, lastReplyAt: 200, post: post("root", at: 100),
                                      unreadReplies: 0, unreadMentions: 0)
        let model = makeModel(service: service)
        await model.load()
        XCTAssertEqual(model.unread.replies, 1)

        await model.markRead()

        XCTAssertTrue(model.didMarkRead)
        XCTAssertFalse(model.unread.isUnread)
        XCTAssertEqual(service.readCalls.count, 1)
    }

    func testAFailedMarkReadDoesNotTurnTheThreadIntoAnErrorScreen() async {
        let service = FakeThreadService()
        service.root = post("root", at: 100)
        service.pages = [page(root: "root", replies: [("r1", 200)])]
        service.threadRow = MMThread(id: "root", replyCount: 1, post: post("root", at: 100), unreadReplies: 1)
        service.readError = MMError.offline
        let model = makeModel(service: service)
        await model.load()

        await model.markRead()

        XCTAssertEqual(model.phase, .loaded)
        XCTAssertFalse(model.didMarkRead)
        XCTAssertTrue(model.unread.isUnread, "the badge stays until a read actually lands")
    }

    // MARK: - The unread divider (t_dbf5395b)

    /// The pane's rows are derived by the same `PostListDerivation` as the channel timeline, fed with
    /// the thread's own read position: the line goes in front of the first reply created after
    /// `last_viewed_at`, and after the root and the replies the reader has already seen.
    func testTheUnreadDividerSitsBeforeTheFirstUnseenReply() async {
        let service = FakeThreadService()
        service.root = post("root", at: 100)
        service.pages = [page(root: "root", replies: [("r1", 200), ("r2", 300)])]
        service.threadRow = MMThread(id: "root", replyCount: 2, lastReplyAt: 300,
                                     lastViewedAt: 150, post: post("root", at: 100),
                                     unreadReplies: 2)
        let model = makeModel(service: service)

        await model.load()

        XCTAssertEqual(model.items.compactMap(\.postID), ["root", "r1", "r2"],
                       "the divider is an item between rows, never a row of its own")
        guard let divider = model.items.firstIndex(of: .newMessages) else {
            return XCTFail("no unread divider though two replies are newer than "
                           + "last_viewed_at 150: \(model.items.map(\.id))")
        }
        XCTAssertGreaterThan(divider, model.items.firstIndex(where: { $0.postID == "root" })!,
                             "the root was read at 150, so the line belongs below it")
        XCTAssertEqual(model.items[divider + 1].postID, "r1",
                       "the divider must precede the first unseen reply, not the newest one")
    }

    /// `nil` is unknown, never "everything is read": a thread the reader does not follow has no row,
    /// so there is no read position to place a line at, and a thread read up to its newest reply has
    /// nothing to mark. Neither case may invent a divider.
    func testNoDividerWithoutAFollowedRowOrWhenEverythingIsRead() async {
        let service = FakeThreadService()
        service.root = post("root", at: 100)
        service.pages = [page(root: "root", replies: [("r1", 200)])]
        service.threadRow = nil
        let unfollowed = makeModel(service: service)

        await unfollowed.load()

        XCTAssertEqual(unfollowed.followState, .notFollowing)
        XCTAssertFalse(unfollowed.items.contains(.newMessages),
                       "a thread with no thread row has no read position to draw a line from")

        service.threadRow = MMThread(id: "root", replyCount: 1, lastReplyAt: 200,
                                     lastViewedAt: 900, post: post("root", at: 100))
        let read = makeModel(service: service)

        await read.load()

        XCTAssertFalse(read.items.contains(.newMessages), "nothing is newer than where the reader stopped")
    }

    /// **The upstream rule this card exists for** (`app/actions/websocket/threads.ts`: a
    /// `thread_read_changed` frame does not move `viewed_at` while that thread is on screen).
    ///
    /// Opening a thread marks it read, and the read answer carries `last_viewed_at = now`. If the
    /// divider were drawn from that number it would exist only for the frames between the load and
    /// the read answer — invisible in the app, unassertable in a live test. The line therefore stays
    /// where the load put it, and only a read made *outside* this pane moves it.
    func testOpeningThePaneDoesNotEraseTheDividerItJustDrew() async {
        let service = FakeThreadService()
        service.root = post("root", at: 100)
        service.pages = [page(root: "root", replies: [("r1", 200), ("r2", 300)])]
        service.threadRow = MMThread(id: "root", replyCount: 2, lastReplyAt: 300,
                                     lastViewedAt: 150, post: post("root", at: 100),
                                     unreadReplies: 2)
        service.readAnswer = MMThread(id: "root", replyCount: 2, lastReplyAt: 300,
                                      lastViewedAt: 10_000, post: post("root", at: 100),
                                      unreadReplies: 0, unreadMentions: 0)
        let model = makeModel(service: service)
        await model.load()

        await model.markRead()

        XCTAssertTrue(model.didMarkRead)
        XCTAssertFalse(model.unread.isUnread, "the badge is cleared by the read that landed")
        XCTAssertEqual(model.unreadDividerPostID, "r1",
                       "the line must outlive the read the pane performed on mount")

        // A read frame for *this* thread (another client, or this pane's own echo) is the same rule.
        _ = model.handle(.threadReadChanged(SocketThreadReadChanged(threadID: "root",
                                                                    channelID: "c1",
                                                                    timestamp: 20_000,
                                                                    unreadReplies: 0,
                                                                    unreadMentions: 0,
                                                                    previousUnreadReplies: 0,
                                                                    previousUnreadMentions: 0)))
        XCTAssertEqual(model.unreadDividerPostID, "r1", "a frame for the open thread does not move it")

        // A whole-team read happened with this thread off the screen, so it does move.
        _ = model.handle(.threadReadChanged(SocketThreadReadChanged(threadID: "",
                                                                    channelID: "",
                                                                    timestamp: 20_000,
                                                                    unreadReplies: 0,
                                                                    unreadMentions: 0,
                                                                    previousUnreadReplies: 0,
                                                                    previousUnreadMentions: 0)))
        XCTAssertNil(model.unreadDividerPostID,
                     "a team-wide read of 20_000 is past every row here, so nothing is new")
    }

    /// "Mark as unread" on a reply puts the line in front of **that** reply, which is what upstream
    /// does by stamping `viewed_at = post.createAt - 1` (`app/actions/remote/thread.ts`).
    func testMarkUnreadPutsTheDividerInFrontOfTheChosenReply() async {
        let service = FakeThreadService()
        service.root = post("root", at: 100)
        service.pages = [page(root: "root", replies: [("r1", 200), ("r2", 300)])]
        service.threadRow = MMThread(id: "root", replyCount: 2, lastReplyAt: 300,
                                     lastViewedAt: 900, post: post("root", at: 100))
        let model = makeModel(service: service)
        await model.load()
        XCTAssertNil(model.unreadDividerPostID, "everything is read before the action")

        await model.markUnread(from: "r2")

        XCTAssertEqual(model.unreadDividerPostID, "r2")
        XCTAssertEqual(service.markUnreadCalls.map(\.postID), ["r2"])
    }

    // MARK: - Paging

    func testLoadEarlierPrependsTheOlderReplyPage() async {
        let service = FakeThreadService()
        service.root = post("root", at: 100)
        service.pageSize = 3
        service.pages = [MMPostList(order: ["root", "r3", "r4"],
                                    posts: ["root": post("root", at: 100),
                                            "r3": post("r3", at: 300, rootID: "root"),
                                            "r4": post("r4", at: 400, rootID: "root")])]
        service.olderPage = MMPostList(order: ["root", "r1", "r2"],
                                       posts: ["root": post("root", at: 100),
                                               "r1": post("r1", at: 100, rootID: "root"),
                                               "r2": post("r2", at: 200, rootID: "root")])
        let model = makeModel(service: service)
        await model.load()
        XCTAssertTrue(model.hasMore)

        let grew = await model.loadEarlier()

        XCTAssertTrue(grew)
        XCTAssertEqual(model.loadedReplyIDs, ["r1", "r2", "r3", "r4"])
        XCTAssertEqual(service.threadRequests.last?.fromPost, "r4")
    }

    func testLoadEarlierStopsWhenThePageBringsNothingNew() async {
        let service = FakeThreadService()
        service.root = post("root", at: 100)
        service.pageSize = 3
        service.pages = [MMPostList(order: ["root", "r3", "r4"],
                                    posts: ["root": post("root", at: 100),
                                            "r3": post("r3", at: 300, rootID: "root"),
                                            "r4": post("r4", at: 400, rootID: "root")])]
        service.olderPage = MMPostList(order: ["root"], posts: ["root": post("root", at: 100)])
        let model = makeModel(service: service)
        await model.load()

        let grew = await model.loadEarlier()

        XCTAssertFalse(grew)
        XCTAssertFalse(model.hasMore, "a page that ends the chain must stop the request loop")
    }

    // MARK: - Socket

    func testAReplyArrivingOnTheSocketLandsOnceAtIndexWithoutARefetch() async {
        let service = FakeThreadService()
        service.root = post("root", at: 100)
        service.pages = [page(root: "root", replies: [("r1", 200)])]
        let model = makeModel(service: service)
        await model.load()
        let requestsBefore = service.threadRequests.count

        let outcome = model.handle(.posted(post("r2", at: 300, user: "bo", rootID: "root")))
        XCTAssertEqual(outcome, .appended)
        XCTAssertEqual(model.loadedReplyIDs, ["r1", "r2"])
        XCTAssertEqual(model.replyCount, 2)
        XCTAssertEqual(service.threadRequests.count, requestsBefore, "a socket post must not refetch the thread")

        // The same frame replayed (a reconnect) must not add a second row.
        _ = model.handle(.posted(post("r2", at: 300, user: "bo", rootID: "root")))
        XCTAssertEqual(model.loadedReplyIDs, ["r1", "r2"])
    }

    func testAPostUnderAnotherRootIsIgnored() async {
        let service = FakeThreadService()
        service.root = post("root", at: 100)
        service.pages = [page(root: "root", replies: [])]
        let model = makeModel(service: service)
        await model.load()

        XCTAssertEqual(model.handle(.posted(post("x", at: 200, rootID: "other"))), .ignored)
        XCTAssertTrue(model.loadedReplyIDs.isEmpty)
    }

    func testThreadUpdatedPatchesTheCountAndFollowState() async {
        let service = FakeThreadService()
        service.root = post("root", at: 100)
        service.pages = [page(root: "root", replies: [])]
        service.threadRow = nil
        let model = makeModel(service: service)
        await model.load()
        XCTAssertEqual(model.followState, .notFollowing)

        let updated = MMThread(id: "root", replyCount: 3, lastReplyAt: 300,
                               post: post("root", at: 100, replyCount: 3), unreadReplies: 3)
        let outcome = model.handle(.threadUpdated(SocketThreadUpdated(thread: updated,
                                                                     previousUnreadReplies: 0,
                                                                     previousUnreadMentions: 0)))

        XCTAssertEqual(outcome, .patched)
        XCTAssertEqual(model.replyCount, 3)
        XCTAssertEqual(model.unread.replies, 3)
        XCTAssertTrue(model.isFollowing, "a thread_updated only ever reaches a follower")
    }

    func testThreadUpdatedForAnotherThreadIsIgnored() async {
        let service = FakeThreadService()
        service.root = post("root", at: 100)
        service.pages = [page(root: "root", replies: [])]
        let model = makeModel(service: service)
        await model.load()

        let other = MMThread(id: "other", replyCount: 1, post: post("other", at: 100))
        XCTAssertEqual(model.handle(.threadUpdated(SocketThreadUpdated(thread: other,
                                                                      previousUnreadReplies: 0,
                                                                      previousUnreadMentions: 0))), .ignored)
        XCTAssertEqual(model.replyCount, 0)
    }

    func testFollowChangedUpdatesTheBellAndClearsTheBadgeOnUnfollow() async {
        let service = FakeThreadService()
        service.root = post("root", at: 100)
        service.pages = [page(root: "root", replies: [("r1", 200)])]
        service.threadRow = MMThread(id: "root", replyCount: 1, post: post("root", at: 100), unreadReplies: 1)
        let model = makeModel(service: service)
        await model.load()
        XCTAssertTrue(model.unread.isUnread)

        let outcome = model.handle(.threadFollowChanged(SocketThreadFollowChanged(threadID: "root",
                                                                                 state: false,
                                                                                 replyCount: 1)))

        XCTAssertEqual(outcome, .following)
        XCTAssertEqual(model.followState, .notFollowing)
        XCTAssertFalse(model.unread.isUnread, "an unfollowed thread cannot be unread")
    }

    func testReadChangedClearsThisThreadsCounters() async {
        let service = FakeThreadService()
        service.root = post("root", at: 100)
        service.pages = [page(root: "root", replies: [("r1", 200)])]
        service.threadRow = MMThread(id: "root", replyCount: 1, post: post("root", at: 100), unreadReplies: 1)
        let model = makeModel(service: service)
        await model.load()

        let outcome = model.handle(.threadReadChanged(SocketThreadReadChanged(threadID: "root",
                                                                             channelID: "c1",
                                                                             timestamp: 5_000,
                                                                             unreadReplies: 0,
                                                                             unreadMentions: 0,
                                                                             previousUnreadReplies: 1,
                                                                             previousUnreadMentions: 0)))

        XCTAssertEqual(outcome, .unread)
        XCTAssertFalse(model.unread.isUnread)
    }

    func testATeamWideReadClearsThisThreadToo() async {
        let service = FakeThreadService()
        service.root = post("root", at: 100)
        service.pages = [page(root: "root", replies: [("r1", 200)])]
        service.threadRow = MMThread(id: "root", replyCount: 1, post: post("root", at: 100), unreadReplies: 1)
        let model = makeModel(service: service)
        await model.load()

        _ = model.handle(.threadReadChanged(SocketThreadReadChanged(threadID: "",
                                                                    channelID: "",
                                                                    timestamp: 5_000,
                                                                    unreadReplies: 0,
                                                                    unreadMentions: 0,
                                                                    previousUnreadReplies: 0,
                                                                    previousUnreadMentions: 0)))

        XCTAssertFalse(model.unread.isUnread)
    }

    func testADeleteOnTheSocketTurnsTheReplyIntoATombstone() async {
        let service = FakeThreadService()
        service.root = post("root", at: 100)
        service.pages = [page(root: "root", replies: [("r1", 200)])]
        let model = makeModel(service: service)
        await model.load()

        var deleted = post("r1", at: 200, rootID: "root")
        deleted.deleteAt = 999
        deleted.updateAt = 999
        XCTAssertEqual(model.handle(.postDeleted(deleted)), .deleted)
        XCTAssertEqual(model.loadedReplyIDs, ["r1"], "the row keeps its place")
        if case .post(let row)? = model.items.first(where: { $0.postID == "r1" }) {
            XCTAssertTrue(row.isDeleted)
        } else {
            XCTFail("expected a row for the deleted reply")
        }
    }

    // MARK: - The composer's sink

    func testAPendingReplyIsShownAtOnceAndReplacedByTheServersPost() async {
        let service = FakeThreadService()
        service.root = post("root", at: 100)
        service.pages = [page(root: "root", replies: [])]
        let model = makeModel(service: service)
        await model.load()

        var pending = post("pending:abc", at: 300, user: "me", rootID: "root")
        pending.pendingPostId = "abc"
        model.insertPendingPost(pending)
        XCTAssertEqual(model.items.compactMap(\.postID), ["root", "pending:abc"])

        let landed = post("real", at: 300, user: "me", rootID: "root")
        model.confirmPendingPost(id: "abc", with: landed)

        XCTAssertEqual(model.items.compactMap(\.postID), ["root", "real"])
        XCTAssertEqual(model.replyCount, 1)
        XCTAssertTrue(model.pendingReplyIDsForTests.isEmpty)
    }

    func testAFailedSendTakesTheOptimisticRowAway() async {
        let service = FakeThreadService()
        service.root = post("root", at: 100)
        service.pages = [page(root: "root", replies: [])]
        let model = makeModel(service: service)
        await model.load()

        var pending = post("pending:abc", at: 300, user: "me", rootID: "root")
        pending.pendingPostId = "abc"
        model.insertPendingPost(pending)
        model.removePendingPost(id: "abc")

        XCTAssertEqual(model.items.compactMap(\.postID), ["root"])
    }

    // MARK: - t_e73f31ce: an id-only participant is not a profile

    /// The defect, as measured: a `thread_updated` frame's `participants` can be **id-only stubs**
    /// (`{"id": "…"}`, the non-extended form — the REST thread answer on this server carries
    /// `participants: null`, so a socket frame is the path that fills the map), and the thread model
    /// stored them as if they were profiles. The reply's author name then drew as `""` — a 0×0,
    /// untappable button, and VoiceOver read `" profile"` for the avatar.
    ///
    /// This test reproduces the state that frame leaves behind — a stub in the map, the reply's real
    /// profile never fetched — and pins both halves of the repair:
    ///  (a) the row never draws a blank name, even while the map holds only a stub;
    ///  (b) the stub does not count as "known", so a profile load goes out and the real name lands.
    func testAnIdOnlyParticipantNeverLeavesABlankReplyAuthorAndIsStillAskedFor() async {
        let service = FakeThreadService()
        service.root = post("root", at: 100, user: "me")
        service.pages = [page(root: "root", replies: [("r1", 200)])]
        // The first profile fetch fails — the measured state: an avatar is drawn, no name is known.
        service.usersError = MMError.offline
        let model = makeModel(service: service)
        await model.load()
        XCTAssertEqual(author(of: "r1", in: model)?.displayName, "Unknown user",
                       "a reply whose profile was never fetched draws the honest fallback, not \"\"")

        // The server can name them after all; the frame that arrives carries the id only.
        service.usersError = nil
        service.usersByID["them"] = MMUser(id: "them", username: "them",
                                           firstName: "Them", lastName: "Person")
        service.clearProfileRequests()

        let updated = MMThread(id: "root", replyCount: 1,
                               participants: [MMUser(id: "them")],
                               post: post("root", at: 100, user: "me"))
        XCTAssertEqual(model.handle(.threadUpdated(SocketThreadUpdated(thread: updated,
                                                                      previousUnreadReplies: 0,
                                                                      previousUnreadMentions: 0))),
                       .patched)

        // (a) the stub is what the map holds now, and the row still draws a name-shaped label.
        XCTAssertEqual(model.users["them"]?.isIdOnlyStub, true)
        XCTAssertEqual(author(of: "r1", in: model)?.displayName, "Unknown user",
                       "a stored stub must never become an empty author name")

        // (b) the stub was not taken as "known": a load went out for it, and the real name landed.
        let askedForTheStub = await eventually { service.profileRequestIDs.contains("them") }
        XCTAssertTrue(askedForTheStub,
                      "an id-only participant must not block the profile request (t_e73f31ce) — "
                      + "asked for \(service.profileRequests)")
        let resolved = await eventually { self.author(of: "r1", in: model)?.displayName == "Them Person" }
        let drawnName = author(of: "r1", in: model)?.displayName ?? "nil"
        XCTAssertTrue(resolved,
                      "the reply's author name must resolve once the server names them — drew \(drawnName)")
    }

    /// The other direction of the same merge: a full participant profile must not be replaced by a
    /// later id-only frame, and a person already named costs no second request.
    func testAFullParticipantProfileIsNotOverwrittenByALaterStub() async {
        let service = FakeThreadService()
        service.root = post("root", at: 100, user: "me")
        service.pages = [page(root: "root", replies: [("r1", 200)])]
        service.usersByID["me"] = MMUser(id: "me", username: "me", firstName: "Me")
        service.usersByID["them"] = MMUser(id: "them", username: "them",
                                           firstName: "Them", lastName: "Person")
        let model = makeModel(service: service)
        await model.load()
        XCTAssertEqual(author(of: "r1", in: model)?.displayName, "Them Person")
        service.clearProfileRequests()

        let updated = MMThread(id: "root", replyCount: 1,
                               participants: [MMUser(id: "them")],
                               post: post("root", at: 100, user: "me"))
        _ = model.handle(.threadUpdated(SocketThreadUpdated(thread: updated,
                                                            previousUnreadReplies: 0,
                                                            previousUnreadMentions: 0)))
        // Let any scheduled load run, so "no request" is a fact and not a race.
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(model.users["them"]?.username, "them",
                       "an id-only participant must not overwrite a real profile")
        XCTAssertEqual(author(of: "r1", in: model)?.displayName, "Them Person",
                       "the reply's author name must survive a stub-shaped frame")
        XCTAssertTrue(service.profileRequests.isEmpty,
                      "a person already named must not be asked for again — asked for \(service.profileRequests)")
    }

    // MARK: - Fixtures

    /// The author a row for `postID` currently draws, or `nil` when there is no such row.
    private func author(of postID: String, in model: ThreadViewModel) -> PostAuthor? {
        guard case .post(let row)? = model.items.first(where: { $0.postID == postID }) else {
            return nil
        }
        return row.author
    }

    /// Poll a condition on the main actor (the profile load is a detached `Task`), so a test never
    /// asserts on a state that a `Task.yield` might not have reached.
    private func eventually(timeout: TimeInterval = 2,
                            _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func makeModel(service: FakeThreadService,
                           rootID: String = "root",
                           channelID: String = "c1") -> ThreadViewModel {
        ThreadViewModel(rootID: rootID,
                        channelID: channelID,
                        teamID: "team",
                        service: service,
                        myUserID: "me",
                        now: { Date(timeIntervalSince1970: 1_000) })
    }

    private func page(root: String, replies: [(id: String, at: Int64)]) -> MMPostList {
        let rootPost = post(root, at: 100)
        var posts: [String: MMPost] = [root: rootPost]
        var order = [root]
        for reply in replies {
            posts[reply.id] = post(reply.id, at: reply.at, rootID: root)
            order.append(reply.id)
        }
        return MMPostList(order: order, posts: posts)
    }

    private func post(_ id: String,
                      at createAt: Int64,
                      user: String = "them",
                      channel: String = "c1",
                      rootID: String = "",
                      replyCount: Int = 0) -> MMPost {
        MMPost(id: id, createAt: createAt, userId: user, channelId: channel, rootId: rootID,
               message: "m-\(id)", replyCount: replyCount)
    }
}

// MARK: - The fake server

@MainActor
final class FakeThreadService: ThreadServing {
    var pageSize = 60
    var root: MMPost?
    /// Answers for the first page, consumed in order (the last repeats).
    var pages: [MMPostList] = []
    /// The answer to a `fromPost != nil` request.
    var olderPage: MMPostList?
    var threadRow: MMThread?
    var usersByID: [String: MMUser] = [:]
    /// When set, `POST /users/ids` answers with this error (the live state where a profile fetch
    /// failed and a row had to fall back).
    var usersError: Error?
    /// Every `POST /users/ids` body this fake was asked for, in order.
    private(set) var profileRequests: [[String]] = []
    var loadError: Error?
    var olderError: Error?
    var followError: Error?
    var readError: Error?
    var readAnswer: MMThread?

    struct ThreadRequest: Equatable {
        var postID: String
        var fromPost: String?
        var fromCreateAt: Int64?
    }

    private(set) var threadRequests: [ThreadRequest] = []
    private(set) var threadListRequests: [(teamID: String, before: String?, unreadOnly: Bool)] = []
    private(set) var followWrites: [(following: Bool, threadID: String)] = []
    private(set) var readCalls: [(timestamp: Int64, threadID: String)] = []
    private(set) var markUnreadCalls: [(threadID: String, postID: String)] = []
    private var servedPages = 0
    /// The thread list answers keyed by the `before` cursor (`nil` = first page).
    var threadPages: [String?: MMThreadList] = [:]

    func thread(postID: String, fromPost: String?, fromCreateAt: Int64?,
                perPage: Int) async throws -> MMPostList {
        threadRequests.append(ThreadRequest(postID: postID, fromPost: fromPost, fromCreateAt: fromCreateAt))
        if fromPost != nil {
            if let olderError { throw olderError }
            return olderPage ?? MMPostList()
        }
        if let loadError { throw loadError }
        guard !pages.isEmpty else { return MMPostList() }
        let slot = min(servedPages, pages.count - 1)
        servedPages += 1
        return pages[slot]
    }

    func threads(teamID: String, before: String?, perPage: Int, unreadOnly: Bool) async throws -> MMThreadList {
        threadListRequests.append((teamID: teamID, before: before, unreadOnly: unreadOnly))
        if let loadError { throw loadError }
        return threadPages[before] ?? MMThreadList()
    }

    func followedThread(teamID: String, threadID: String) async throws -> MMThread? {
        threadRow
    }

    func setFollowing(teamID: String, threadID: String, following: Bool) async throws {
        followWrites.append((following: following, threadID: threadID))
        if let followError { throw followError }
    }

    func markRead(teamID: String, threadID: String, at: Int64) async throws -> MMThread {
        readCalls.append((timestamp: at, threadID: threadID))
        if let readError { throw readError }
        return readAnswer ?? MMThread(id: threadID, post: root ?? MMPost(id: threadID))
    }

    func markUnread(teamID: String, threadID: String, postID: String) async throws -> MMThread {
        markUnreadCalls.append((threadID: threadID, postID: postID))
        return readAnswer ?? MMThread(id: threadID, post: root ?? MMPost(id: threadID))
    }

    func post(id: String) async throws -> MMPost {
        guard let root else { throw MMError.notFound }
        return root
    }

    func users(ids: [String]) async throws -> [MMUser] {
        profileRequests.append(ids)
        if let usersError { throw usersError }
        return ids.compactMap { usersByID[$0] }
    }

    /// The ids every `POST /users/ids` carried, flattened.
    var profileRequestIDs: [String] { profileRequests.flatMap { $0 } }

    /// Forget the recorded requests (a test that measures *one* frame's effect).
    func clearProfileRequests() { profileRequests.removeAll() }
}
