// T36 — the Threads list (global threads): load, page, tab, and the socket.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb):
// app/screens/global_threads/threads_list/index.tsx (the paged list and `onEndReached`),
// app/screens/global_threads/global_threads.tsx (the All / Unreads tabs),
// app/actions/remote/thread.ts (`fetchThreads` with `before` and `unread_only`),
// app/actions/websocket/threads.ts (thread_updated / thread_follow_changed / thread_read_changed
// applied to a list that is on screen).

import XCTest
@testable import Mattermost

@MainActor
final class T36GlobalThreadsViewModelTests: XCTestCase {

    func testLoadShowsTheNewestThreadFirstAndTheServersCounters() async {
        let service = FakeThreadService()
        service.pageSize = 2
        service.threadPages[nil] = MMThreadList(threads: [thread("old", lastReplyAt: 100),
                                                          thread("new", lastReplyAt: 900)],
                                                total: 2, totalUnreadThreads: 1)
        let model = makeModel(service: service)

        await model.load()

        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.loadedThreadIDs, ["new", "old"])
        XCTAssertEqual(model.totals.unreadThreads, 1)
        XCTAssertEqual(model.rows.first?.threadID, "new")
    }

    func testAFullPageLoadsTheNextOneAndARepeatedThreadIsNotDuplicated() async {
        let service = FakeThreadService()
        service.pageSize = 2
        service.threadPages[nil] = MMThreadList(threads: [thread("t1", lastReplyAt: 900),
                                                          thread("t2", lastReplyAt: 800)],
                                                total: 3)
        service.threadPages["t2"] = MMThreadList(threads: [thread("t2", lastReplyAt: 800),
                                                          thread("t3", lastReplyAt: 700)],
                                                 total: 3)
        let model = makeModel(service: service)
        await model.load()
        XCTAssertTrue(model.hasMore)

        let grew = await model.loadMore()

        XCTAssertTrue(grew)
        XCTAssertEqual(model.loadedThreadIDs, ["t1", "t2", "t3"])
        XCTAssertEqual(service.threadListRequests.map(\.before), [nil, "t2"])
    }

    func testAShortPageStopsPaging() async {
        let service = FakeThreadService()
        service.pageSize = 3
        service.threadPages[nil] = MMThreadList(threads: [thread("t1", lastReplyAt: 900)], total: 1)
        let model = makeModel(service: service)

        await model.load()

        XCTAssertFalse(model.hasMore)
        let grew = await model.loadMore()
        XCTAssertFalse(grew)
        XCTAssertEqual(service.threadListRequests.count, 1, "a finished list must not call the server again")
    }

    func testTheUnreadsTabAsksTheServerForUnreadThreadsOnly() async {
        let service = FakeThreadService()
        service.threadPages[nil] = MMThreadList(threads: [thread("t1", lastReplyAt: 900, unread: 1)], total: 1)
        let model = makeModel(service: service)
        await model.load()

        await model.select(tab: .unreads)

        XCTAssertEqual(model.tab, .unreads)
        XCTAssertEqual(service.threadListRequests.last?.unreadOnly, true)
        XCTAssertEqual(model.tab, .unreads)
        // The rows on screen are unread, so the line must not claim there are none: the counter is the
        // server's totals **bounded below by the rows it just answered with** (T36-AV F3). This page's
        // totals said zero unread while carrying an unread thread.
        XCTAssertEqual(model.subtitle, "1 unread thread")
    }

    /// The reconciliation only ever *raises* the counters to the rows on screen; a server total that is
    /// larger than the rows (the list is paged) stays authoritative.
    func testALargerServerCounterIsNotReducedToTheDrawnRows() async {
        let service = FakeThreadService()
        service.threadPages[nil] = MMThreadList(threads: [thread("t1", lastReplyAt: 900, unread: 1)],
                                                total: 40, totalUnreadThreads: 7)
        let model = makeModel(service: service)
        await model.load()
        await model.select(tab: .unreads)

        XCTAssertEqual(model.rows.count, 1)
        XCTAssertEqual(model.subtitle, "7 unread threads",
                       "the counters describe the team, not the drawn page")
    }

    func testSwitchingTabsClearsTheOtherTabsRowsWhileItLoads() async {
        let service = FakeThreadService()
        service.threadPages[nil] = MMThreadList(threads: [thread("t1", lastReplyAt: 900)], total: 1)
        let model = makeModel(service: service)
        await model.load()

        service.loadError = MMError.offline
        await model.select(tab: .unreads)

        XCTAssertTrue(model.rows.isEmpty)
        guard case .failed = model.phase else { return XCTFail("expected a failed phase") }
    }

    func testAFailedLoadSaysWhyAndARetryRecovers() async {
        let service = FakeThreadService()
        service.loadError = MMError.offline
        let model = makeModel(service: service)

        await model.load()
        guard case .failed(let message) = model.phase else { return XCTFail("expected a failed phase") }
        XCTAssertTrue(message.contains("offline"))

        service.loadError = nil
        service.threadPages[nil] = MMThreadList(threads: [thread("t1", lastReplyAt: 900)], total: 1)
        await model.reload()

        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.loadedThreadIDs, ["t1"])
    }

    func testAuthorNamesComeFromTheProfilePass() async {
        let service = FakeThreadService()
        service.threadPages[nil] = MMThreadList(threads: [thread("t1", lastReplyAt: 900, author: "ana")], total: 1)
        service.usersByID["ana"] = MMUser(id: "ana", username: "ana", firstName: "Ana", lastName: "Lopez")
        let model = makeModel(service: service)

        await model.load()

        XCTAssertEqual(model.rows.first?.author.displayName, "Ana Lopez")
    }

    // MARK: - The counter line and the rows (T36-AV F3)

    /// An empty counter set drawn over a page of rows is the F3 defect ("No threads yet" above a full
    /// list). The header's copy therefore comes from the rows when the server's `total` says zero.
    func testTheCounterLineNeverSaysNoThreadsYetOverDrawnRows() async {
        let service = FakeThreadService()
        // A page that carries rows but no usable total (a proxy that strips it, or a server that
        // omitted it): the old copy was "No threads yet" over these two rows.
        service.threadPages[nil] = MMThreadList(threads: [thread("t1", lastReplyAt: 900),
                                                          thread("t2", lastReplyAt: 800)],
                                                total: 0, includesTotals: false)
        let model = makeModel(service: service)

        await model.load()

        XCTAssertEqual(model.rows.count, 2)
        XCTAssertEqual(model.subtitle, "2 threads",
                       "an empty totals must not be drawn over a non-empty page")
        XCTAssertNotEqual(model.subtitle, "No threads yet")
    }

    /// The same rule for the Unreads tab: rows that are unread must be counted even when the server's
    /// unread counter came back zero.
    func testTheUnreadCounterLineAgreesWithUnreadRows() async {
        let service = FakeThreadService()
        service.threadPages[nil] = MMThreadList(threads: [thread("t1", lastReplyAt: 900, unread: 1)],
                                                total: 1, totalUnreadThreads: 0)
        let model = makeModel(service: service)
        await model.load()
        await model.select(tab: .unreads)

        XCTAssertEqual(model.subtitle, "1 unread thread")
    }

    /// A page that omits `total` must not zero the counters a previous page stated.
    func testAPageWithoutTotalsKeepsTheCounterLineStanding() async {
        let service = FakeThreadService()
        service.pageSize = 2
        service.threadPages[nil] = MMThreadList(threads: [thread("t1", lastReplyAt: 900),
                                                          thread("t2", lastReplyAt: 800)],
                                                total: 5)
        service.threadPages["t2"] = MMThreadList(threads: [thread("t3", lastReplyAt: 700)],
                                                 includesTotals: false)
        let model = makeModel(service: service)
        await model.load()
        XCTAssertEqual(model.subtitle, "5 threads")

        _ = await model.loadMore()

        XCTAssertEqual(model.subtitle, "5 threads",
                       "the counters describe the team, not the page that carried them")
    }

    // MARK: - A deleted root (T36-AV F5)

    /// A root deleted while the list is open takes its row with it: the whole chain 404s afterwards, so
    /// the row could only open onto "This thread no longer exists.".
    func testADeletedRootRemovesItsRow() async {
        let service = FakeThreadService()
        service.threadPages[nil] = MMThreadList(threads: [thread("t1", lastReplyAt: 900),
                                                          thread("t2", lastReplyAt: 800)], total: 2)
        let model = makeModel(service: service)
        await model.load()

        let outcome = model.handle(.postDeleted(MMPost(id: "t1", createAt: 100, channelId: "c1")))

        XCTAssertEqual(outcome, .removed)
        XCTAssertEqual(model.loadedThreadIDs, ["t2"])
    }

    func testADeletedReplyLeavesItsThreadsRowAlone() async {
        let service = FakeThreadService()
        service.threadPages[nil] = MMThreadList(threads: [thread("t1", lastReplyAt: 900)], total: 1)
        let model = makeModel(service: service)
        await model.load()

        let outcome = model.handle(.postDeleted(MMPost(id: "r1", createAt: 200, channelId: "c1",
                                                       rootId: "t1")))

        XCTAssertEqual(outcome, .ignored)
        XCTAssertEqual(model.loadedThreadIDs, ["t1"])
    }

    // MARK: - Socket

    func testThreadUpdatedPatchesTheRowInPlace() async {
        let service = FakeThreadService()
        service.threadPages[nil] = MMThreadList(threads: [thread("t1", lastReplyAt: 900)], total: 1)
        let model = makeModel(service: service)
        await model.load()

        let outcome = model.handle(.threadUpdated(SocketThreadUpdated(
            thread: thread("t1", lastReplyAt: 2_000, replies: 5),
            previousUnreadReplies: 0,
            previousUnreadMentions: 0)))

        XCTAssertEqual(outcome, .patched)
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertEqual(model.rows.first?.replyCount, 5)
    }

    func testThreadUpdatedForAThreadTheListDoesNotHoldInsertsIt() async {
        // `thread_updated` only reaches followers, so its arrival is also the insert for a thread
        // followed on another device.
        let service = FakeThreadService()
        service.threadPages[nil] = MMThreadList(threads: [thread("t1", lastReplyAt: 900)], total: 1)
        let model = makeModel(service: service)
        await model.load()

        let outcome = model.handle(.threadUpdated(SocketThreadUpdated(
            thread: thread("t2", lastReplyAt: 2_000),
            previousUnreadReplies: 0,
            previousUnreadMentions: 0)))

        XCTAssertEqual(outcome, .inserted)
        XCTAssertEqual(model.loadedThreadIDs, ["t2", "t1"])
    }

    func testUnfollowingRemovesTheRow() async {
        let service = FakeThreadService()
        service.threadPages[nil] = MMThreadList(threads: [thread("t1", lastReplyAt: 900),
                                                          thread("t2", lastReplyAt: 800)], total: 2)
        let model = makeModel(service: service)
        await model.load()

        let outcome = model.handle(.threadFollowChanged(SocketThreadFollowChanged(threadID: "t1",
                                                                                 state: false,
                                                                                 replyCount: 1)))

        XCTAssertEqual(outcome, .removed)
        XCTAssertEqual(model.loadedThreadIDs, ["t2"])
    }

    func testFollowingAThreadTheListDoesNotHoldWaitsForTheNextLoad() async {
        let service = FakeThreadService()
        service.threadPages[nil] = MMThreadList(threads: [thread("t1", lastReplyAt: 900)], total: 1)
        let model = makeModel(service: service)
        await model.load()

        let outcome = model.handle(.threadFollowChanged(SocketThreadFollowChanged(threadID: "t9",
                                                                                 state: true,
                                                                                 replyCount: 2)))

        XCTAssertEqual(outcome, .ignored)
        XCTAssertEqual(model.loadedThreadIDs, ["t1"], "a placeholder row would have to invent a root post")
    }

    func testReadChangedClearsTheBadgeAndRemovesTheRowFromUnreads() async {
        let service = FakeThreadService()
        service.threadPages[nil] = MMThreadList(threads: [thread("t1", lastReplyAt: 900, unread: 2)], total: 1)
        let model = makeModel(service: service)
        await model.load()
        await model.select(tab: .unreads)
        XCTAssertEqual(model.rows.count, 1)

        let outcome = model.handle(.threadReadChanged(SocketThreadReadChanged(threadID: "t1",
                                                                             channelID: "c1",
                                                                             timestamp: 5_000,
                                                                             unreadReplies: 0,
                                                                             unreadMentions: 0,
                                                                             previousUnreadReplies: 2,
                                                                             previousUnreadMentions: 0)))

        XCTAssertEqual(outcome, .unread)
        XCTAssertTrue(model.rows.isEmpty, "a read thread does not belong in Unreads")
    }

    func testATeamWideReadClearsEveryRow() async {
        let service = FakeThreadService()
        service.threadPages[nil] = MMThreadList(threads: [thread("t1", lastReplyAt: 900, unread: 2),
                                                          thread("t2", lastReplyAt: 800, unread: 1)],
                                                total: 2, totalUnreadThreads: 2)
        let model = makeModel(service: service)
        await model.load()

        _ = model.handle(.threadReadChanged(SocketThreadReadChanged(threadID: "",
                                                                    channelID: "",
                                                                    timestamp: 5_000,
                                                                    unreadReplies: 0,
                                                                    unreadMentions: 0,
                                                                    previousUnreadReplies: 0,
                                                                    previousUnreadMentions: 0)))

        XCTAssertTrue(model.rows.allSatisfy { !$0.unread.isUnread })
        XCTAssertEqual(model.totals.unreadThreads, 0)
    }

    func testAPostEventIsNotThisListsBusiness() async {
        // The list is driven by thread_updated; a `posted` frame for a channel it does not show must
        // not refetch or insert anything.
        let service = FakeThreadService()
        service.threadPages[nil] = MMThreadList(threads: [thread("t1", lastReplyAt: 900)], total: 1)
        let model = makeModel(service: service)
        await model.load()
        let requestsBefore = service.threadListRequests.count

        let outcome = model.handle(.posted(MMPost(id: "p1", createAt: 100, channelId: "c1")))

        XCTAssertEqual(outcome, .ignored)
        XCTAssertEqual(service.threadListRequests.count, requestsBefore)
    }

    // MARK: - Fixtures

    private func makeModel(service: FakeThreadService) -> GlobalThreadsViewModel {
        GlobalThreadsViewModel(teamID: "team",
                               service: service,
                               myUserID: "me",
                               now: { Date(timeIntervalSince1970: 1_000) })
    }

    private func thread(_ id: String,
                        lastReplyAt: Int64,
                        replies: Int = 1,
                        unread: Int = 0,
                        author: String = "them") -> MMThread {
        MMThread(id: id,
                 replyCount: replies,
                 lastReplyAt: lastReplyAt,
                 lastViewedAt: 0,
                 participants: [MMUser(id: author)],
                 post: MMPost(id: id, createAt: 100, userId: author, channelId: "c1", message: "root of \(id)"),
                 unreadReplies: unread,
                 unreadMentions: 0)
    }
}
