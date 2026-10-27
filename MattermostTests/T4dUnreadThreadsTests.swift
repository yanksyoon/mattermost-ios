// t_4dfdf856 — the rail's Threads entry: unread threads must be visible before the pane is opened.
//
// The reported defect was "no place in the left panel to see unread threads / messages". The pane has
// carried All/Unread tabs since T36 (`GlobalThreadsView`, `GlobalThreadsViewModel` with `unread=true`);
// what was missing is a rail entry that says, **without opening anything**, that threads are waiting and
// how many. That number is a claim about the server's own counters, so it is derived by one function
// (`GlobalThreadsDerivation.railEntry`) and pinned here: a rail badge computed from a different rule
// than the pane's header would be two answers to one question, which is the class of defect T36-AV F3
// was about ("No threads yet" drawn over a full page of rows).
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb):
// app/components/threads_button/threads_button.tsx (the Threads entry: bold while anything is unread,
// `Badge` for the count), app/queries/servers/thread.ts `observeUnreadsAndMentions` (the counters behind
// it), app/screens/global_threads/global_threads.tsx (the All / Unreads tabs).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §13; no
// upstream source copied.
//
// No network and no clock: every expectation is a function of its arguments, except the one model test,
// which drives the model with the suite's fake server.

import XCTest
@testable import Mattermost

@MainActor
final class T4dUnreadThreadsTests: XCTestCase {

    // MARK: - The number the rail draws

    func testNothingUnreadDrawsNoBadgeAndSaysNothingIsWaiting() {
        let entry = ThreadsRailEntry.none
        XCTAssertNil(entry.badgeText, "an always-visible \"0\" reads as a failed load")
        XCTAssertFalse(entry.isUnread)
        XCTAssertEqual(entry.accessibilityValue, "No unread threads")
    }

    func testTheRailBadgeIsTheServersUnreadThreadCount() {
        let entry = GlobalThreadsDerivation.railEntry(
            totals: ThreadTotals(total: 154, unreadThreads: 12, unreadMentions: 11,
                                 unreadUrgentMentions: 0),
            drawn: [])
        XCTAssertEqual(entry.badgeText, "12")
        XCTAssertTrue(entry.isUnread)
        // The mention count is not lost: it rides in the accessible statement, so VoiceOver hears the
        // same two facts upstream's row carries (unreads + mentions) from one element.
        XCTAssertEqual(entry.accessibilityValue, "12 unread threads, 11 mentions")
    }

    func testOneUnreadThreadIsSingular() {
        let entry = ThreadsRailEntry(unreadThreads: 1, mentions: 0)
        XCTAssertEqual(entry.badgeText, "1")
        XCTAssertEqual(entry.accessibilityValue, "1 unread thread")
    }

    /// A thread whose replies were read but whose mention counter is still set is a measured state on
    /// this server (T42: a channel read clears replies, not a thread's `unread_mentions`), so the row
    /// still has to look "waiting" even when the thread count is zero.
    func testAMentionWithNoUnreadReplyStillEmphasisesTheRow() {
        let entry = ThreadsRailEntry(unreadThreads: 0, mentions: 3)
        XCTAssertTrue(entry.isUnread)
        XCTAssertNil(entry.badgeText, "there is no unread *thread* to count, so no number is drawn")
        XCTAssertEqual(entry.accessibilityValue, "3 mentions")
    }

    // MARK: - The number cannot contradict the rows already drawn

    /// The server's totals are the source, but a page that arrived without them (a proxy that strips
    /// `total`, a future server) must not leave the rail claiming nothing is unread while the pane
    /// holds unread rows — the same floor rule the pane's header uses.
    func testTheRailBadgeIsBoundedBelowByTheRowsAlreadyDrawn() {
        let drawn = [thread("t1", unread: 2), thread("t2", unread: 1), thread("t3", unread: 0)]
        let entry = GlobalThreadsDerivation.railEntry(totals: .zero, drawn: drawn)
        XCTAssertEqual(entry.badgeText, "2", "two drawn threads are unread, so \"0\" would be a lie")
        XCTAssertEqual(entry.unreadThreads, 2)
    }

    func testTheRailAndThePaneHeaderAreOneNumber() {
        let drawn = [thread("t1", unread: 1), thread("t2", unread: 0)]
        let totals = ThreadTotals(total: 40, unreadThreads: 7, unreadMentions: 2,
                                  unreadUrgentMentions: 0)
        let entry = GlobalThreadsDerivation.railEntry(totals: totals, drawn: drawn)
        let header = GlobalThreadsDerivation.displayedTotals(totals, drawn: drawn)
        // One derivation: the rail badge and the pane's "N unread threads" line can never disagree.
        XCTAssertEqual(entry.unreadThreads, header.unreadThreads)
        XCTAssertEqual(GlobalThreadsDerivation.tabSubtitle(totals: header, tab: .unreads),
                       "\(entry.unreadThreads) unread threads")
    }

    // MARK: - The model the rail reads, and liveness

    func testTheModelsRailEntryCarriesTheServersCounters() async {
        let service = FakeThreadService()
        service.threadPages[nil] = MMThreadList(threads: [thread("t1", unread: 1)],
                                                total: 154,
                                                totalUnreadThreads: 12,
                                                totalUnreadMentions: 11)
        let model = GlobalThreadsViewModel(teamID: "team", service: service, myUserID: "me")

        await model.load()

        XCTAssertEqual(model.railEntry.badgeText, "12")
        XCTAssertEqual(model.railEntry.accessibilityValue, "12 unread threads, 11 mentions")
    }

    /// Reading a thread from **another client** must move the rail's number: the server sends
    /// `thread_read_changed` and carries no refetch. Before this was wired the header (and the rail
    /// badge beside it) kept counting a thread the reader had just read until the next page load —
    /// measured on the local server: `total_unread_threads` fell to 11 while the pane still said 12.
    func testAReadEventMovesTheTeamsCountersAndTheRailBadge() async {
        let service = FakeThreadService()
        service.threadPages[nil] = MMThreadList(threads: [thread("t1", unread: 1, mentions: 1),
                                                          thread("t2", unread: 2)],
                                                total: 154,
                                                totalUnreadThreads: 12,
                                                totalUnreadMentions: 11)
        let model = GlobalThreadsViewModel(teamID: "team", service: service, myUserID: "me")
        await model.load()
        XCTAssertEqual(model.railEntry.badgeText, "12")
        let requests = service.threadListRequests.count

        _ = model.handle(.threadReadChanged(SocketThreadReadChanged(threadID: "t1",
                                                                    channelID: "c1",
                                                                    timestamp: 2_000,
                                                                    unreadReplies: 0,
                                                                    unreadMentions: 0,
                                                                    previousUnreadReplies: 1,
                                                                    previousUnreadMentions: 1)))

        XCTAssertEqual(model.totals.unreadThreads, 11, "the team's counter moves with the thread")
        XCTAssertEqual(model.totals.unreadMentions, 10)
        XCTAssertEqual(model.railEntry.badgeText, "11")
        XCTAssertEqual(service.threadListRequests.count, requests,
                       "a read state is carried by the event; the rail must not refetch to learn it")
    }

    /// The move is derived from the model's own copy of the thread, so a frame the socket delivers
    /// twice does not count the same read twice.
    func testAReplayedReadEventDoesNotMoveTheCountersAgain() async {
        let service = FakeThreadService()
        service.threadPages[nil] = MMThreadList(threads: [thread("t1", unread: 1)],
                                                total: 2, totalUnreadThreads: 2)
        let model = GlobalThreadsViewModel(teamID: "team", service: service, myUserID: "me")
        await model.load()
        let event = SocketThreadReadChanged(threadID: "t1", channelID: "c1", timestamp: 2_000,
                                            unreadReplies: 0, unreadMentions: 0,
                                            previousUnreadReplies: 1, previousUnreadMentions: 0)

        _ = model.handle(.threadReadChanged(event))
        _ = model.handle(.threadReadChanged(event))

        XCTAssertEqual(model.totals.unreadThreads, 1, "one read, one decrement")
    }

    /// A thread that is **partly** read is still an unread thread: only the mention counter moves.
    func testAPartiallyReadThreadKeepsCountingAsUnread() async {
        let service = FakeThreadService()
        service.threadPages[nil] = MMThreadList(threads: [thread("t1", unread: 3)],
                                                total: 1, totalUnreadThreads: 1)
        let model = GlobalThreadsViewModel(teamID: "team", service: service, myUserID: "me")
        await model.load()

        _ = model.handle(.threadReadChanged(SocketThreadReadChanged(threadID: "t1",
                                                                    channelID: "c1",
                                                                    timestamp: 2_000,
                                                                    unreadReplies: 1,
                                                                    unreadMentions: 0,
                                                                    previousUnreadReplies: 3,
                                                                    previousUnreadMentions: 0)))

        XCTAssertEqual(model.totals.unreadThreads, 1)
        XCTAssertEqual(model.railEntry.badgeText, "1")
    }

    /// The team-wide read (`PUT …/threads/read`) is the same claim at once.
    func testATeamWideReadClearsTheRailBadge() async {
        let service = FakeThreadService()
        service.threadPages[nil] = MMThreadList(threads: [thread("t1", unread: 1)],
                                                total: 1, totalUnreadThreads: 1,
                                                totalUnreadMentions: 1)
        let model = GlobalThreadsViewModel(teamID: "team", service: service, myUserID: "me")
        await model.load()

        _ = model.handle(.threadReadChanged(SocketThreadReadChanged(threadID: "",
                                                                    channelID: "",
                                                                    timestamp: 3_000,
                                                                    unreadReplies: 0,
                                                                    unreadMentions: 0,
                                                                    previousUnreadReplies: 0,
                                                                    previousUnreadMentions: 0)))

        XCTAssertNil(model.railEntry.badgeText)
        XCTAssertEqual(model.railEntry.accessibilityValue, "No unread threads")
    }

    // MARK: - Fixtures

    private func thread(_ id: String, unread: Int, mentions: Int = 0) -> MMThread {
        MMThread(id: id,
                 replyCount: max(unread, 1),
                 lastReplyAt: 900,
                 participants: [MMUser(id: "them")],
                 post: MMPost(id: id, createAt: 100, userId: "them", channelId: "c1",
                              message: "root of \(id)"),
                 unreadReplies: unread,
                 unreadMentions: mentions)
    }
}
