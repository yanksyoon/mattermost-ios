// T36 — the thread rules, as pure functions.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb):
// app/utils/thread/index.ts (the activity key the list is ordered by), app/screens/thread/
// thread_post_list/thread_post_list.tsx (root first, then replies; "load earlier" above),
// app/screens/global_threads/threads_list/* (a row's preview, its reply count, its unread dot),
// app/actions/remote/thread.ts (`fetchThreads` paging by `before`, `totalsOnly` counters).
//
// No network, no clock, no calendar singleton: every rule here is a function of its arguments, so a
// day boundary or a tie can be pinned exactly.

import XCTest
@testable import Mattermost

final class T36ThreadModelsTests: XCTestCase {

    // MARK: - The chain

    func testTheChainStartsWithTheRootEvenThoughTheServerReturnsItAmongTheReplies() {
        let root = post("root", at: 100, user: "ana", channel: "c1", rootID: "")
        // Measured: `GET /posts/{id}/thread` returns the root inside `order` and `posts`.
        let chain = ThreadDerivation.chain(root: root, replies: [root, post("r1", at: 200, rootID: "root")])
        XCTAssertEqual(chain.map(\.id), ["root", "r1"])
    }

    func testAPostFromAnotherRootIsNotDrawnAsAReply() {
        let root = post("root", at: 100)
        let other = post("x1", at: 150, rootID: "someone-else")
        let orphan = post("x2", at: 160, rootID: "")
        let chain = ThreadDerivation.chain(root: root, replies: [other, orphan, post("r1", at: 200, rootID: "root")])
        XCTAssertEqual(chain.map(\.id), ["root", "r1"])
    }

    func testRepliesAreOldestFirstWithAnIdTiebreak() {
        let root = post("root", at: 100)
        let chain = ThreadDerivation.chain(root: root, replies: [
            post("b", at: 200, rootID: "root"),
            post("a", at: 200, rootID: "root"),
            post("first", at: 150, rootID: "root"),
        ])
        XCTAssertEqual(chain.map(\.id), ["root", "first", "a", "b"])
    }

    func testADuplicateReplyKeepsItsFreshestRevisionAndItsFirstPosition() {
        var edited = post("r1", at: 200, rootID: "root")
        edited.message = "edited"
        let chain = ThreadDerivation.chain(root: post("root", at: 100),
                                           replies: [post("r1", at: 200, rootID: "root"), edited])
        XCTAssertEqual(chain.map(\.id), ["root", "r1"])
        XCTAssertEqual(chain.last?.message, "edited")
    }

    func testAnEmptyPostIdIsNeverAChainMember() {
        let chain = ThreadDerivation.chain(root: post("root", at: 100),
                                           replies: [post("", at: 200, rootID: "root")])
        XCTAssertEqual(chain.map(\.id), ["root"])
    }

    // MARK: - Merging pages and echoes

    func testAnOlderPagePrependsWithoutDisturbingTheNewerReplies() {
        let merged = ThreadDerivation.merge(existing: [post("r9", at: 900, rootID: "root")],
                                            page: [post("r1", at: 100, rootID: "root")],
                                            rootID: "root")
        XCTAssertEqual(merged.map(\.id), ["r1", "r9"])
    }

    func testAReplyThePaneHoldsButThePageOmitsIsKept() {
        // Measured: the server drops a deleted reply from `/posts/{id}/thread` entirely. A reader who
        // already saw it must keep seeing it (as a tombstone), not have the row vanish.
        var deleted = post("r2", at: 200, rootID: "root")
        deleted.deleteAt = 999
        let merged = ThreadDerivation.merge(existing: [deleted],
                                            page: [post("r1", at: 100, rootID: "root")],
                                            rootID: "root")
        XCTAssertEqual(merged.map(\.id), ["r1", "r2"])
    }

    func testTheSocketEchoOfASentReplyReplacesTheOptimisticCopy() {
        var pending = post("pending:abc", at: 300, user: "me", rootID: "root")
        pending.pendingPostId = "abc"
        let echo = post("real", at: 300, user: "me", rootID: "root")
        let merged = ThreadDerivation.merge(existing: [pending], page: [echo], rootID: "root")
        // The optimistic row keeps its id here: replacing it is the view model's pending-id map, and
        // `merge` must not silently drop either row before that map has run.
        XCTAssertEqual(Set(merged.map(\.id)), ["pending:abc", "real"])
    }

    // MARK: - The reply count

    func testTheReplyCountPrefersTheServersNumberOverThePage() {
        // Measured on 9.11.19: a thread row says reply_count 2 while its root post says 0.
        let root = post("root", at: 100)
        XCTAssertEqual(ThreadDerivation.replyCount(root: root, replies: [], serverCount: 2), 2)
    }

    func testTheReplyCountIsNeverSmallerThanTheLoadedChain() {
        let root = post("root", at: 100)
        let replies = [post("r1", at: 200, rootID: "root"), post("r2", at: 300, rootID: "root")]
        XCTAssertEqual(ThreadDerivation.replyCount(root: root, replies: replies, serverCount: 0), 2)
    }

    func testADeletedReplyDoesNotCountTowardsTheLoadedTotal() {
        var deleted = post("r1", at: 200, rootID: "root")
        deleted.deleteAt = 1
        XCTAssertEqual(ThreadDerivation.loadedReplyCount([deleted]), 0)
    }

    func testTheReplyLabelIsNilAtZeroAndSingularAtOne() {
        XCTAssertNil(ThreadDerivation.replyLabel(0))
        XCTAssertEqual(ThreadDerivation.replyLabel(1), "1 reply")
        XCTAssertEqual(ThreadDerivation.replyLabel(4), "4 replies")
    }

    // MARK: - Participants

    func testParticipantStubsFromTheServerStillProduceAnAvatarWithoutAName() {
        // Measured: without `collapsedThreadsExtended=true` the server answers id-only stubs
        // (`username` empty). An avatar from the id is honest; an invented name is not.
        var root = post("root", at: 100, user: "root-author")
        root.participants = [MMUser(id: "stub-user")]
        let authors = ThreadDerivation.participants(root: root, replies: [], users: [:])
        // The first avatar is the id-only stub, drawn without a name; the root's author follows.
        XCTAssertEqual(authors.first?.id, "stub-user")
        XCTAssertTrue(authors.first?.displayName.isEmpty ?? false)
        XCTAssertTrue(authors.first?.initials.isEmpty ?? false)
    }

    func testParticipantProfilesAreUsedWhenThePageCarriesThem() {
        var root = post("root", at: 100, user: "ana")
        root.participants = [MMUser(id: "ana", username: "ana", firstName: "Ana")]
        let authors = ThreadDerivation.participants(root: root, replies: [], users: [:])
        XCTAssertEqual(authors.map(\.displayName), ["Ana"])
    }

    func testALoadedReplyAuthorTheServerOmittedJoinsTheStackNewestFirst() {
        var root = post("root", at: 100, user: "ana")
        root.participants = [MMUser(id: "ana", username: "ana", firstName: "Ana")]
        let replies = [
            post("r1", at: 200, user: "bo", rootID: "root"),
            post("r2", at: 300, user: "cy", rootID: "root"),
        ]
        let authors = ThreadDerivation.participants(root: root,
                                                    replies: replies,
                                                    users: ["bo": MMUser(id: "bo", username: "bo", firstName: "Bo"),
                                                            "cy": MMUser(id: "cy", username: "cy", firstName: "Cy")])
        XCTAssertEqual(authors.map(\.displayName), ["Ana", "Cy", "Bo"])
    }

    func testTheParticipantStackIsCapped() {
        let root = post("root", at: 100, user: "ana")
        let replies = (1...8).map { post("r\($0)", at: Int64($0) * 10, user: "u\($0)", rootID: "root") }
        let authors = ThreadDerivation.participants(root: root, replies: replies, users: [:])
        XCTAssertEqual(authors.count, ThreadDerivation.participantLimit)
    }

    // MARK: - Activity ordering

    func testActivityIsTheNewerOfLastReplyAndRootCreation() {
        let created = MMThread(id: "t1",
                               replyCount: 0,
                               lastReplyAt: 0,
                               post: post("t1", at: 500))
        XCTAssertEqual(ThreadDerivation.activityAt(created), 500)
        let replied = MMThread(id: "t2", replyCount: 1, lastReplyAt: 900, post: post("t2", at: 500))
        XCTAssertEqual(ThreadDerivation.activityAt(replied), 900)
    }

    func testReadingAThreadDoesNotReorderTheList() {
        var read = MMThread(id: "t1", replyCount: 1, lastReplyAt: 200, lastViewedAt: 100_000,
                            post: post("t1", at: 100))
        read.lastViewedAt = 100_000
        XCTAssertEqual(ThreadDerivation.activityAt(read), 200)
    }

    func testThreadsAreSortedNewestActivityFirst() {
        let threads = [
            MMThread(id: "old", replyCount: 3, lastReplyAt: 100, post: post("old", at: 100)),
            MMThread(id: "new", replyCount: 1, lastReplyAt: 900, post: post("new", at: 100)),
            MMThread(id: "mid", replyCount: 2, lastReplyAt: 500, post: post("mid", at: 100)),
        ]
        XCTAssertEqual(ThreadDerivation.sorted(threads).map(\.id), ["new", "mid", "old"])
    }

    func testMergingAPageKeepsTheNewestRevisionOfEachThread() {
        let stale = MMThread(id: "t1", replyCount: 1, lastReplyAt: 100, post: post("t1", at: 100))
        let fresh = MMThread(id: "t1", replyCount: 4, lastReplyAt: 400, post: post("t1", at: 100))
        let merged = ThreadDerivation.mergeThreads(existing: [stale, MMThread(id: "t2", replyCount: 0,
                                                                            post: post("t2", at: 50))],
                                                   page: [fresh])
        XCTAssertEqual(merged.map(\.id), ["t1", "t2"])
        XCTAssertEqual(merged.first?.replyCount, 4)
    }

    // MARK: - Paging

    func testAFullPageAdvancesTheCursorToTheLastThreadTheServerSent() {
        let page = MMThreadList(threads: [MMThread(id: "t1", post: post("t1")),
                                          MMThread(id: "t2", post: post("t2"))],
                                total: 10)
        XCTAssertEqual(ThreadDerivation.nextBeforeCursor(page: page, pageSize: 2), "t2")
        XCTAssertTrue(ThreadDerivation.hasMore(page: page, pageSize: 2))
    }

    func testAShortPageEndsTheList() {
        let page = MMThreadList(threads: [MMThread(id: "t1", post: post("t1"))], total: 10)
        XCTAssertNil(ThreadDerivation.nextBeforeCursor(page: page, pageSize: 2))
        XCTAssertFalse(ThreadDerivation.hasMore(page: page, pageSize: 2))
    }

    func testATotalsOnlyAnswerNeverPages() {
        // The server answers `threads: null` for `totalsOnly=true`; asking again would loop.
        let page = MMThreadList(threads: [], total: 15, includesThreads: false)
        XCTAssertNil(ThreadDerivation.nextBeforeCursor(page: page, pageSize: 1))
        XCTAssertFalse(ThreadDerivation.hasMore(page: page, pageSize: 1))
        XCTAssertEqual(page.totals.total, 15)
    }

    func testAFullPageThatIsAlsoTheLastDoesNotPage() {
        let page = MMThreadList(threads: [MMThread(id: "t1", post: post("t1")),
                                          MMThread(id: "t2", post: post("t2"))],
                                total: 2)
        XCTAssertFalse(ThreadDerivation.hasMore(page: page, pageSize: 2))
    }

    // MARK: - The global list's rows

    func testARowsPreviewStripsMarkdownAndCollapsesWhitespace() {
        XCTAssertEqual(GlobalThreadsDerivation.preview("**bold**\n\nand   more"), "bold and more")
    }

    func testARowsPreviewIsClippedWithAnEllipsis() {
        let long = String(repeating: "a", count: 200)
        let preview = GlobalThreadsDerivation.preview(long, limit: 10)
        XCTAssertEqual(preview, String(repeating: "a", count: 10) + "…")
    }

    func testARowSaysSoWhenTheRootHasNoText() {
        let thread = MMThread(id: "t1", replyCount: 1, post: post("t1", at: 100, message: ""))
        let row = GlobalThreadsDerivation.rows(threads: [thread], users: [:], myUserID: "me").first
        XCTAssertEqual(row?.preview, "(no text)")
    }

    func testARowMarksMyOwnRootAsMine() {
        let mine = MMThread(id: "t1", replyCount: 1, post: post("t1", at: 100, user: "me"))
        let theirs = MMThread(id: "t2", replyCount: 1, post: post("t2", at: 100, user: "you"))
        let rows = GlobalThreadsDerivation.rows(threads: [mine, theirs], users: [:], myUserID: "me")
        XCTAssertEqual(rows.map(\.isMine), [true, false])
    }

    func testARowDrawsTheThreadsReplyCountAndUnreadBadge() {
        let thread = MMThread(id: "t1", replyCount: 5, lastReplyAt: 200,
                              post: post("t1", at: 100), unreadReplies: 2, unreadMentions: 1)
        let row = GlobalThreadsDerivation.rows(threads: [thread], users: [:], myUserID: "me").first
        XCTAssertEqual(row?.replyCount, 5)
        XCTAssertEqual(row?.unread.badge, "1 mention")
    }

    func testTheTabSubtitleCountsWhatTheTabShows() {
        let totals = ThreadTotals(total: 7, unreadThreads: 3, unreadMentions: 1, unreadUrgentMentions: 0)
        XCTAssertEqual(GlobalThreadsDerivation.tabSubtitle(totals: totals, tab: .unreads), "3 unread threads")
        XCTAssertEqual(GlobalThreadsDerivation.tabSubtitle(totals: totals, tab: .all), "7 threads")
        XCTAssertEqual(GlobalThreadsDerivation.tabSubtitle(totals: .zero, tab: .all), "No threads yet")
        XCTAssertEqual(GlobalThreadsDerivation.tabSubtitle(totals: .zero, tab: .unreads), "No unread threads")
    }

    func testProfileIDsCallForRootAuthorsAndParticipantsOnce() {
        let thread = MMThread(id: "t1", replyCount: 1,
                              participants: [MMUser(id: "bo"), MMUser(id: "ana")],
                              post: post("t1", at: 100, user: "ana"))
        XCTAssertEqual(Set(GlobalThreadsDerivation.profileIDs(in: [thread])), ["ana", "bo"])
    }

    // MARK: - Fixtures

    private func post(_ id: String,
                      at createAt: Int64 = 0,
                      user: String = "them",
                      channel: String = "c1",
                      rootID: String = "",
                      message: String = "hello") -> MMPost {
        MMPost(id: id, createAt: createAt, userId: user, channelId: channel, rootId: rootID,
               message: message)
    }
}
