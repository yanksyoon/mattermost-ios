// T34 — the channel view model: load, paginate, patch from the socket, keep the reader in place.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0,
// app/actions/remote/post.ts (`handlePosts` merge rules), app/actions/websocket/posts.ts (in-place
// patch for posted/post_edited/post_deleted/reaction_*), app/screens/channel/channel_post_list
// (page load and the older-page trigger), app/screens/channel/channel.tsx (a channel switch starts a
// new list).
//
// The service is faked at the `ChannelServing` seam, so these tests exercise the *rules* — ordering,
// cursor advance, dedupe, event application, scroll anchor — with no network and no clock.

import XCTest
@testable import Mattermost

@MainActor
final class T34ChannelViewModelTests: XCTestCase {

    // MARK: Fakes

    @MainActor
    final class FakeService: ChannelServing {
        var pageSize: Int
        /// Answers for `before == nil`, consumed in order; the last one repeats.
        var firstPages: [MMPostList]
        /// Answers keyed by the `before` cursor.
        var olderPages: [String: MMPostList] = [:]
        var usersByID: [String: MMUser] = [:]
        var channel: MMChannel?
        var failure: Error?
        var membershipRow: MMChannelMember?
        /// Per-call delay for the `before == nil` answers, indexed like `firstPages`.
        var firstPageDelays: [Duration] = []

        private(set) var requestedCursors: [String?] = []
        private(set) var userRequests: [[String]] = []
        private var served = 0

        init(pageSize: Int, firstPages: [MMPostList] = []) {
            self.pageSize = pageSize
            self.firstPages = firstPages
        }

        func channel(id: String) async throws -> MMChannel {
            guard let channel else { throw MMError.notFound }
            return channel
        }

        func posts(channelID: String, before: String?, perPage: Int) async throws -> MMPostList {
            requestedCursors.append(before)
            if let failure { throw failure }
            if before == nil {
                let slot = min(served, max(0, firstPages.count - 1))
                served += 1
                // The delay is claimed *before* the await, so call order here is the order the server
                // answered in — which is the only thing that makes a "late answer" test meaningful.
                if firstPageDelays.indices.contains(slot), firstPageDelays[slot] > .zero {
                    try? await Task.sleep(for: firstPageDelays[slot])
                }
                return firstPages.isEmpty ? MMPostList(order: [], posts: [:]) : firstPages[slot]
            }
            return olderPages[before ?? ""] ?? MMPostList(order: [], posts: [:])
        }

        func users(ids: [String]) async throws -> [MMUser] {
            userRequests.append(ids)
            return ids.compactMap { usersByID[$0] }
        }

        func fileData(fileID: String, preferThumbnail: Bool) async throws -> Data {
            throw MMError.notFound
        }

        func membership(channelID: String) async throws -> MMChannelMember? { membershipRow }
    }

    // MARK: Helpers

    private let channelID = "chan-1"

    private func post(_ id: String, at millis: Int64, user: String = "u1",
                      message: String? = nil) -> MMPost {
        MMPost(id: id, createAt: millis, userId: user, channelId: channelID,
               message: message ?? "message \(id)")
    }

    private func list(_ posts: [MMPost], hasNext: Bool? = nil) -> MMPostList {
        MMPostList(order: posts.map(\.id),
                   posts: Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) }),
                   hasNext: hasNext)
    }

    /// A reply: a post whose `root_id` names the post it answers.
    private func reply(_ id: String, at millis: Int64, root: String, user: String = "u1") -> MMPost {
        var post = post(id, at: millis, user: user)
        post.rootId = root
        return post
    }

    private func model(_ service: FakeService,
                       myUserID: String? = "me",
                       lastViewedAt: Int64? = nil) -> ChannelViewModel {
        ChannelViewModel(channelID: channelID,
                         channelName: "Town Square",
                         service: service,
                         myUserID: myUserID,
                         lastViewedAt: lastViewedAt,
                         now: { Date(timeIntervalSince1970: 1_800_000_000) },
                         calendar: .current,
                         locale: Locale(identifier: "en_US_POSIX"))
    }

    private func ids(_ model: ChannelViewModel) -> [String] { model.items.compactMap(\.postID) }

    // MARK: First page

    func testFirstPageLoadsNewestFirstAndRendersOldestFirst() async {
        let service = FakeService(pageSize: 3, firstPages: [
            list([post("c", at: 3_000), post("b", at: 2_000), post("a", at: 1_000)], hasNext: true)
        ])
        let model = model(service)
        await model.load()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.loadedPostIDs, ["c", "b", "a"])
        XCTAssertEqual(ids(model), ["a", "b", "c"])
        XCTAssertTrue(model.hasMore)
        XCTAssertEqual(service.requestedCursors, [nil])
    }

    func testShortPageMeansNoMore() async {
        let service = FakeService(pageSize: 3, firstPages: [list([post("a", at: 1_000)])])
        let model = model(service)
        await model.load()
        XCTAssertFalse(model.hasMore)
    }

    /// The pinned server answers `has_next: false` on **every** channel page, including the first of
    /// six (measured: `per_page=60` on a 503-post channel). Paging must therefore follow the page
    /// length, not the flag — this is the regression that made the live "scroll to the top" test show
    /// one page and "This is the beginning of the channel".
    func testAFullPageKeepsPagingEvenWhenTheServerSaysHasNextIsFalse() async {
        let service = FakeService(pageSize: 2, firstPages: [
            list([post("b", at: 2_000), post("a", at: 1_000)], hasNext: false)
        ])
        service.olderPages["a"] = list([post("older", at: 500)], hasNext: false)
        let model = model(service)
        await model.load()
        XCTAssertTrue(model.hasMore, "a full page is not the end, whatever has_next says")

        let grew = await model.loadEarlier()
        XCTAssertTrue(grew)
        XCTAssertEqual(model.loadedPostIDs, ["b", "a", "older"])
        XCTAssertFalse(model.hasMore, "a short page ends the window")
    }

    func testLoadIfNeededDoesNotRefetchAnAlreadyLoadedWindow() async {
        let service = FakeService(pageSize: 3, firstPages: [list([post("a", at: 1_000)])])
        let model = model(service)
        await model.load(ifNeeded: true)
        await model.load(ifNeeded: true)
        XCTAssertEqual(service.requestedCursors.count, 1)
    }

    // MARK: Older pages

    func testLoadEarlierPrependsTheOlderPageWithoutDuplicates() async {
        let first = list([post("c", at: 3_000), post("b", at: 2_000)], hasNext: true)
        let service = FakeService(pageSize: 2, firstPages: [first])
        service.olderPages["b"] = list([post("a", at: 1_000), post("b", at: 2_000)], hasNext: true)
        let model = model(service)
        await model.load()

        let grew = await model.loadEarlier()
        XCTAssertTrue(grew)
        XCTAssertEqual(model.loadedPostIDs, ["c", "b", "a"], "the shared boundary post must not duplicate")
        XCTAssertEqual(model.oldestLoadedPostID, "a",
                       "the window must grow at its older end — what the live UI test reads from the seam")
        XCTAssertEqual(service.requestedCursors, [nil, "b"])
        XCTAssertNil(model.loadEarlierError)
    }

    func testAShortOlderPageEndsPaging() async {
        let service = FakeService(pageSize: 2, firstPages: [list([post("c", at: 3_000), post("b", at: 2_000)], hasNext: true)])
        service.olderPages["b"] = list([post("a", at: 1_000)])
        let model = model(service)
        await model.load()
        await model.loadEarlier()
        XCTAssertFalse(model.hasMore)
    }

    // MARK: Replies are not rows (T34-AV-F1) — one rule, both paths

    /// The defect the T34-AV validator measured: a reply arriving in a page was drawn as a top-level
    /// row (288 of perf-feed's 503 rows), while the *same* reply arriving over the socket was dropped.
    /// Both halves now answer with `ChannelViewModel.isTimelineRow`, so the answer cannot depend on
    /// how the post arrived.
    func testARepliesPageDrawsNoRowsAndTheSameReplyIsDroppedOverTheSocket() async {
        let root = post("a", at: 1_000)
        let drawn = reply("r1", at: 1_500, root: "a")
        let service = FakeService(pageSize: 3, firstPages: [list([drawn, root])])

        let model = model(service)
        await model.load()

        XCTAssertEqual(model.loadedPostIDs, ["a"],
                       "the page's reply must not be a channel row, got \(model.loadedPostIDs)")
        XCTAssertEqual(model.loadedCount, 1)
        XCTAssertNil(model.post(id: "r1"), "a dropped reply is not in the window at all")
        XCTAssertEqual(ids(model), ["a"])

        // The same post over the socket: the same answer, for the same reason.
        XCTAssertEqual(model.handle(.posted(drawn)), .ignored)
        XCTAssertEqual(model.loadedPostIDs, ["a"])

        // And a second reply that was never in a page either.
        XCTAssertEqual(model.handle(.posted(reply("r2", at: 2_000, root: "a"))), .ignored)
        XCTAssertEqual(model.loadedPostIDs, ["a"])
    }

    /// The older cursor is the **page's** oldest id, not the oldest row the window kept: `before` is
    /// exclusive, so a cursor taken from the kept rows would step back inside the page just read.
    func testTheOlderCursorIsThePagesOldestIDEvenWhenThatPostIsAReply() async {
        // Newest first, as the server orders a channel page: `c`, then `a`, then the reply — so the
        // page's oldest post is one this window drops, and the last row kept is `a`.
        let page = list([post("c", at: 3_000), post("a", at: 2_500), reply("r", at: 2_000, root: "c")])
        let service = FakeService(pageSize: 3, firstPages: [page])
        service.olderPages["r"] = list([post("older", at: 500)], hasNext: false)

        let model = model(service)
        await model.load()
        XCTAssertEqual(model.loadedPostIDs, ["c", "a"])
        XCTAssertEqual(model.oldestLoadedPostID, "a", "the last row kept is not the page's oldest post")

        let grew = await model.loadEarlier()
        XCTAssertTrue(grew)
        XCTAssertEqual(service.requestedCursors, [nil, "r"],
                       "the page asked for what is older than the reply, which is the page's oldest id")
        XCTAssertEqual(model.loadedPostIDs, ["c", "a", "older"])
    }

    /// A page can hold nothing this window keeps (a run of replies under one root). Ending the window
    /// there would leave the sentinel saying "This is the beginning of the channel" with posts still
    /// unread, so the walk advances the server cursor and asks again inside the same `loadEarlier`.
    func testARepliesOnlyPageIsWalkedThroughInsteadOfEndingTheWindow() async {
        let first = list([post("c", at: 3_000), post("b", at: 2_000)], hasNext: true)
        let service = FakeService(pageSize: 2, firstPages: [first])
        // Two full pages of replies, then a page with a row.
        service.olderPages["b"] = list([reply("r1", at: 1_900, root: "b"),
                                        reply("r2", at: 1_800, root: "b")], hasNext: true)
        service.olderPages["r2"] = list([reply("r3", at: 1_700, root: "b"),
                                         reply("r4", at: 1_600, root: "b")], hasNext: true)
        service.olderPages["r4"] = list([post("a", at: 1_000)], hasNext: false)

        let model = model(service)
        await model.load()
        XCTAssertEqual(model.loadedPostIDs, ["c", "b"])
        XCTAssertTrue(model.hasMore)

        let grew = await model.loadEarlier()
        XCTAssertTrue(grew, "the walk must reach the row behind the replies, not stop at the first empty page")
        XCTAssertEqual(service.requestedCursors, [nil, "b", "r2", "r4"])
        XCTAssertEqual(model.loadedPostIDs, ["c", "b", "a"])
        XCTAssertFalse(model.hasMore, "the short page that carried the row ended the window")
        XCTAssertFalse(model.loadedPostIDs.contains("r1"))
        XCTAssertFalse(model.loadedPostIDs.contains("r3"))
    }

    func testARepeatedPageStopsInsteadOfLooping() async {
        // The server hands back the same window (a stale cursor). The model must stop, not spin.
        let service = FakeService(pageSize: 2, firstPages: [list([post("b", at: 2_000), post("a", at: 1_000)], hasNext: true)])
        service.olderPages["a"] = list([post("b", at: 2_000), post("a", at: 1_000)], hasNext: true)
        let model = model(service)
        await model.load()

        let grew = await model.loadEarlier()
        XCTAssertFalse(grew)
        XCTAssertFalse(model.hasMore)
        XCTAssertEqual(model.loadedPostIDs, ["b", "a"])
        // A second attempt is a no-op: no further request is made.
        _ = await model.loadEarlier()
        XCTAssertEqual(service.requestedCursors.count, 2)
    }

    func testAFailedOlderPageKeepsThePostsAndReportsNextToTheSentinel() async {
        let service = FakeService(pageSize: 2, firstPages: [list([post("b", at: 2_000), post("a", at: 1_000)], hasNext: true)])
        let model = model(service)
        await model.load()
        service.failure = MMError.offline

        let grew = await model.loadEarlier()
        XCTAssertFalse(grew)
        XCTAssertEqual(model.phase, .loaded, "the posts already on screen stay usable")
        XCTAssertEqual(model.loadedCount, 2)
        XCTAssertNotNil(model.loadEarlierError)
    }

    // MARK: Socket

    func testPostedAppendsAndScrollsTheWindowForward() async {
        let service = FakeService(pageSize: 3, firstPages: [list([post("a", at: 1_000)])])
        let model = model(service)
        await model.load()

        let outcome = model.handle(.posted(post("b", at: 2_000, user: "u2")))
        XCTAssertEqual(outcome, .appended)
        XCTAssertEqual(model.loadedPostIDs, ["b", "a"])
        XCTAssertEqual(ids(model), ["a", "b"])
    }

    func testReplayedPostedReplacesInsteadOfDuplicating() async {
        let service = FakeService(pageSize: 3, firstPages: [list([post("a", at: 1_000)])])
        service.usersByID["u1"] = MMUser(id: "u1", username: "ada")
        let model = model(service)
        await model.load()

        var edited = post("a", at: 1_000)
        edited.message = "changed by replay"
        XCTAssertEqual(model.handle(.posted(edited)), .patched)
        XCTAssertEqual(model.loadedCount, 1)
        XCTAssertEqual(model.post(id: "a")?.message, "changed by replay")
    }

    func testOnlyThisChannelsTopLevelPostsAreAccepted() async {
        let service = FakeService(pageSize: 3, firstPages: [list([post("a", at: 1_000)])])
        let model = model(service)
        await model.load()

        var elsewhere = post("x", at: 2_000)
        elsewhere.channelId = "other"
        XCTAssertEqual(model.handle(.posted(elsewhere)), .ignored)

        var reply = post("r", at: 2_000)
        reply.rootId = "a"
        XCTAssertEqual(model.handle(.posted(reply)), .ignored, "a reply belongs to the thread pane, not the channel list")

        XCTAssertEqual(model.loadedPostIDs, ["a"])
    }

    func testEditKeepsThePosition() async {
        let service = FakeService(pageSize: 3, firstPages: [list([post("c", at: 3_000), post("b", at: 2_000), post("a", at: 1_000)])])
        let model = model(service)
        await model.load()
        let before = ids(model)

        var edited = post("b", at: 2_000)
        edited.message = "now edited"
        edited.editAt = 9_000
        XCTAssertEqual(model.handle(.postEdited(edited)), .patched)

        XCTAssertEqual(ids(model), before, "an edit must not move the post")
        XCTAssertEqual(model.post(id: "b")?.message, "now edited")
        let rows = model.items.compactMap { item -> PostRowModel? in
            if case .post(let row) = item, row.id == "b" { return row }
            return nil
        }
        XCTAssertEqual(rows.first?.isEdited, true)
    }

    func testEditingAPostThatIsNotLoadedIsIgnored() async {
        let service = FakeService(pageSize: 3, firstPages: [list([post("a", at: 1_000)])])
        let model = model(service)
        await model.load()
        XCTAssertEqual(model.handle(.postEdited(post("zzz", at: 500))), .ignored)
    }

    func testDeleteKeepsTheSlotAsATombstone() async {
        let service = FakeService(pageSize: 3, firstPages: [list([post("b", at: 2_000), post("a", at: 1_000)])])
        let model = model(service)
        await model.load()

        var deleted = post("b", at: 2_000)
        deleted.deleteAt = 9_000
        XCTAssertEqual(model.handle(.postDeleted(deleted)), .deleted)

        XCTAssertEqual(model.loadedPostIDs, ["b", "a"], "the row stays where the reader saw it")
        let row = model.items.compactMap { item -> PostRowModel? in
            if case .post(let row) = item, row.id == "b" { return row }
            return nil
        }.first
        XCTAssertEqual(row?.isDeleted, true)
        XCTAssertTrue(row?.blocks.isEmpty ?? false)
    }

    func testReactionEventsPatchTheSummaryAndIgnoreReplays() async throws {
        let service = FakeService(pageSize: 3, firstPages: [list([post("a", at: 1_000)])])
        let model = model(service)
        await model.load()

        let reaction = MMReaction(userId: "me", postId: "a", emojiName: "tada", createAt: 5_000)
        XCTAssertEqual(model.handle(.reactionAdded(reaction)), .reactions)
        XCTAssertEqual(model.handle(.reactionAdded(reaction)), .ignored, "a replayed add must not double-count")

        var row = model.items.compactMap { item -> PostRowModel? in
            if case .post(let row) = item, row.id == "a" { return row }
            return nil
        }.first
        XCTAssertEqual(row?.reactions.map(\.emojiName), ["tada"])
        XCTAssertEqual(row?.reactions.first?.count, 1)
        XCTAssertEqual(row?.reactions.first?.includesMe, true)

        XCTAssertEqual(model.handle(.reactionRemoved(reaction)), .reactions)
        row = model.items.compactMap { item -> PostRowModel? in
            if case .post(let row) = item, row.id == "a" { return row }
            return nil
        }.first
        XCTAssertTrue(row?.reactions.isEmpty ?? false)
    }

    func testChannelViewedByMeClearsTheUnreadDivider() async {
        let service = FakeService(pageSize: 3, firstPages: [list([post("a", at: 5_000)])])
        let model = model(service, lastViewedAt: 1_000)
        await model.load()
        XCTAssertTrue(model.items.contains(.newMessages))

        let viewed = SocketChannelViewed(channelID: channelID, userID: "me")
        XCTAssertEqual(model.handle(.channelViewed(viewed)), .viewed)
        XCTAssertFalse(model.items.contains(.newMessages))
    }

    func testChannelViewedBySomeoneElseIsIgnored() async {
        let service = FakeService(pageSize: 3, firstPages: [list([post("a", at: 5_000)])])
        let model = model(service, lastViewedAt: 1_000)
        await model.load()
        XCTAssertEqual(model.handle(.channelViewed(SocketChannelViewed(channelID: "chan-1",
                                                                      userID: "u2"))), .ignored)
        XCTAssertTrue(model.items.contains(.newMessages))
    }

    /// `multiple_channels_viewed` (T33's view path) can clear this channel's divider too: the payload
    /// carries my read timestamps for every channel a `view` call touched.
    func testMultipleChannelsViewedClearsTheDividerForThisChannel() async {
        let service = FakeService(pageSize: 3, firstPages: [list([post("a", at: 5_000)])])
        let model = model(service, lastViewedAt: 1_000)
        await model.load()
        XCTAssertTrue(model.items.contains(.newMessages))

        let viewed = SocketMultipleChannelsViewed(userID: "me",
                                                  channelTimes: [channelID: 9_000, "other": 2])
        XCTAssertEqual(model.handle(.multipleChannelsViewed(viewed)), .viewed)
        XCTAssertFalse(model.items.contains(.newMessages))

        // Another channel's read state, or another user's, moves nothing here.
        XCTAssertEqual(model.handle(.multipleChannelsViewed(
            SocketMultipleChannelsViewed(userID: "me", channelTimes: ["other": 9_000]))), .ignored)
        XCTAssertEqual(model.handle(.multipleChannelsViewed(
            SocketMultipleChannelsViewed(userID: "u2", channelTimes: [channelID: 9_000]))), .ignored)
    }

    // MARK: Failure
    func testTheUnreadDividerComesFromTheMembershipRow() async {
        // The channel page carries no read state; `last_viewed_at` is the only source. The model asks
        // for the membership row on the first load and places the divider from it.
        let service = FakeService(pageSize: 3, firstPages: [list([post("b", at: 3_000), post("a", at: 1_000)])])
        service.membershipRow = MMChannelMember(channelId: channelID, userId: "me",
                                                lastViewedAt: 1_500)
        let model = model(service, lastViewedAt: nil)
        await model.load()

        guard let divider = model.items.firstIndex(where: { $0 == .newMessages }) else {
            return XCTFail("no unread divider from the membership row")
        }
        XCTAssertEqual(model.items[divider + 1].postID, "b")
    }

    func testNoMembershipRowMeansNoDividerRatherThanEverythingRead() async {
        let service = FakeService(pageSize: 3, firstPages: [list([post("a", at: 3_000)])])
        let model = model(service, lastViewedAt: nil)
        await model.load()
        XCTAssertFalse(model.items.contains(.newMessages))
    }

    func testAFailedFirstPageReportsAMessageAndRetryRecovers() async {
        let service = FakeService(pageSize: 3, firstPages: [list([post("a", at: 1_000)])])
        service.failure = MMError.offline
        let model = model(service)
        await model.load()
        guard case .failed(let message) = model.phase else { return XCTFail("expected a failure") }
        XCTAssertTrue(message.lowercased().contains("offline"), message)

        service.failure = nil
        await model.retry()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.loadedPostIDs, ["a"])
    }

    func testANewerLoadWinsOverOneThatWasAlreadyInFlight() async {
        // The first request is slow and answers with a stale page; the second lands first. The model
        // must not merge the late answer on top of the fresh window.
        let stale = list([post("stale", at: 1_000)], hasNext: true)
        let fresh = list([post("new2", at: 3_000), post("new1", at: 2_000)], hasNext: true)
        let service = FakeService(pageSize: 3, firstPages: [stale, fresh])
        service.firstPageDelays = [.milliseconds(150), .zero]
        let model = model(service)

        let first = Task { await model.load(ifNeeded: false) }
        try? await Task.sleep(for: .milliseconds(20))
        let second = Task { await model.reload() }
        await second.value
        await first.value

        XCTAssertFalse(model.loadedPostIDs.contains("stale"),
                       "a superseded response must be dropped, got \(model.loadedPostIDs)")
        XCTAssertEqual(model.loadedPostIDs, ["new2", "new1"])
        XCTAssertEqual(model.phase, .loaded)
    }

    // MARK: Scroll anchor

    func testTheAnchorSurvivesAnOlderPageLanding() async {
        let service = FakeService(pageSize: 2, firstPages: [list([post("c", at: 3_000), post("b", at: 2_000)], hasNext: true)])
        service.olderPages["b"] = list([post("a", at: 1_000)])
        let model = model(service)
        await model.load()

        let anchor = ChannelViewModel.ScrollAnchor(postID: "c", offsetFromTop: 42)
        model.setScrollAnchor(anchor)
        await model.loadEarlier()

        XCTAssertEqual(model.pendingScrollRestore, anchor, "the view is told to scroll back to the reader's post")
        XCTAssertEqual(model.pendingScrollTarget, "c")
        XCTAssertTrue(model.loadedPostIDs.contains("c"), "the anchored post must still exist")
        model.consumeScrollRestore()
        XCTAssertNil(model.pendingScrollRestore, "the restore is applied once, not on every render")
    }

    // MARK: Title

    func testChannelHeaderTitleUsesTheChannelDisplayName() async {
        let service = FakeService(pageSize: 3, firstPages: [list([post("a", at: 1_000)])])
        service.channel = MMChannel(id: channelID, name: "town-square", displayName: "Town Square",
                                    type: "O", teamId: "t1")
        let model = model(service)
        await model.load()
        XCTAssertEqual(model.title, "Town Square")
        XCTAssertEqual(model.channelType, "O")
    }

    func testDMHeaderShowsTheOtherParticipantNotTheIDPair() async {
        let service = FakeService(pageSize: 3, firstPages: [list([post("a", at: 1_000, user: "u2")])])
        service.channel = MMChannel(id: channelID, name: "me__u2", displayName: "", type: "D",
                                    teamId: "")
        service.usersByID["u2"] = MMUser(id: "u2", username: "ada", firstName: "Ada",
                                         lastName: "Lovelace")
        service.usersByID["me"] = MMUser(id: "me", username: "perfprobe")
        let model = model(service)
        await model.load()
        XCTAssertEqual(model.title, "Ada Lovelace")
    }
}

// MARK: - Coordinator

@MainActor
final class T34ChannelPaneCoordinatorTests: XCTestCase {

    private func server() -> ServerConfig {
        ServerConfig(name: "Local", url: URL(string: "https://example.com")!)
    }

    func testOneModelPerChannelAndTheSameInstanceOnReEntry() {
        let coordinator = ChannelPaneCoordinator()
        coordinator.serviceFactory = { _ in T34ChannelViewModelTests.FakeService(pageSize: 3) }
        let server = server()

        let first = coordinator.model(for: server, channelID: "a", channelName: "A")
        let again = coordinator.model(for: server, channelID: "a", channelName: "A")
        XCTAssertTrue(first === again)
        XCTAssertEqual(coordinator.modelCount, 1)
    }

    func testTheWarmChannelCacheIsBounded() {
        let coordinator = ChannelPaneCoordinator()
        coordinator.serviceFactory = { _ in T34ChannelViewModelTests.FakeService(pageSize: 3) }
        let server = server()
        for index in 0..<10 {
            _ = coordinator.model(for: server, channelID: "c\(index)", channelName: "C\(index)")
        }
        XCTAssertEqual(coordinator.modelCount, ChannelPaneCoordinator.warmChannelLimit)
        // The most recent channel survived; the first was evicted.
        XCTAssertNotNil(coordinator.activeModel(serverID: server.id, channelID: "c9"))
        XCTAssertNil(coordinator.activeModel(serverID: server.id, channelID: "c0"))
    }

    func testDeactivateDropsTheServersWindows() {
        let coordinator = ChannelPaneCoordinator()
        coordinator.serviceFactory = { _ in T34ChannelViewModelTests.FakeService(pageSize: 3) }
        let server = server()
        _ = coordinator.model(for: server, channelID: "a", channelName: "A")
        coordinator.deactivate(server.id)
        XCTAssertEqual(coordinator.modelCount, 0)
    }

    func testSocketEventsReachOnlyTheMatchingChannelsModel() async {
        let service = T34ChannelViewModelTests.FakeService(
            pageSize: 3,
            firstPages: [MMPostList(order: [], posts: [:])])
        let coordinator = ChannelPaneCoordinator()
        coordinator.serviceFactory = { _ in service }
        let server = server()
        let model = coordinator.model(for: server, channelID: "a", channelName: "A")
        await model.load()

        let post = MMPost(id: "p1", createAt: 1_000, userId: "u1", channelId: "a", message: "hello")
        await coordinator.handle(.posted(post), serverID: server.id)
        XCTAssertEqual(model.loadedPostIDs, ["p1"])

        let elsewhere = MMPost(id: "p2", createAt: 2_000, userId: "u1", channelId: "b", message: "no")
        await coordinator.handle(.posted(elsewhere), serverID: server.id)
        XCTAssertEqual(model.loadedPostIDs, ["p1"])
    }
}

// MARK: - The production page request (T34-AV-F1)

/// What the app actually asks the server for.
///
/// The tests above fake `ChannelServing`, so they pin the *rule*; this one pins the *request* the
/// rule leans on — `collapsedThreads=true`, the server's own "top-level posts only" view of a
/// channel. Measured on the pinned 9.11.19 server (perf-feed, 503 posts = 215 roots + 288 replies):
/// without it a 60-post page came back 25 roots + 35 replies, with it 60 roots and 0 replies, and
/// `before`-paging over the roots walked the same 215 ids an unfiltered walk's roots do
/// (docs/t34r5-build-note.md §2).
@MainActor
final class T34ChannelPageRequestTests: XCTestCase {

    private func apiClient(_ transport: FakeAPITransport) throws -> APIClient {
        try APIClient(serverURL: URL(string: "https://mm.example.com")!,
                      transport: transport,
                      retryPolicy: APIClient.RetryPolicy(maxAttempts: 1, baseDelay: 0, maxDelay: 0,
                                                         jitterRatio: 0),
                      tokenProvider: { "test-token" },
                      sleep: { _ in },
                      random: { 0 })
    }

    func testTheProductionServiceAsksTheServerForTheThreadCollapsedPage() async throws {
        let transport = FakeAPITransport(repeating: .json(["order": [], "posts": [:] as [String: Any]]))
        let api = try apiClient(transport)
        let service = SessionChannelService(pageSize: 60, resolve: { api })

        _ = try await service.posts(channelID: "c1", before: nil, perPage: 60)
        let newest = try XCTUnwrap(transport.lastRequest?.url.absoluteString)
        XCTAssertTrue(newest.contains("per_page=60"), newest)
        XCTAssertTrue(newest.contains("collapsedThreads=true"),
                      "the channel timeline asks for top-level posts only, got \(newest)")
        XCTAssertFalse(newest.contains("collapsedThreadsExtended"),
                       "only the filter is requested, not the heavier thread metadata: \(newest)")

        // An older page carries the same filter: the cursor moves, the rule does not.
        _ = try await service.posts(channelID: "c1", before: "p9", perPage: 40)
        let older = try XCTUnwrap(transport.lastRequest?.url.absoluteString)
        XCTAssertTrue(older.contains("before=p9"), older)
        XCTAssertTrue(older.contains("per_page=40"), older)
        XCTAssertTrue(older.contains("collapsedThreads=true"), older)
    }
}
