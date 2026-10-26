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

    // MARK: - Fixtures

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
    private(set) var threadListRequests: [(before: String?, unreadOnly: Bool)] = []
    private(set) var followWrites: [(following: Bool, threadID: String)] = []
    private(set) var readCalls: [(timestamp: Int64, threadID: String)] = []
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
        threadListRequests.append((before: before, unreadOnly: unreadOnly))
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
        readAnswer ?? MMThread(id: threadID, post: root ?? MMPost(id: threadID))
    }

    func post(id: String) async throws -> MMPost {
        guard let root else { throw MMError.notFound }
        return root
    }

    func users(ids: [String]) async throws -> [MMUser] {
        ids.compactMap { usersByID[$0] }
    }
}
