// T36 — the channel timeline's reply line: a reply moves its root's count and participant stack, and
// tapping the line opens the thread.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb):
// app/components/post_list/thread_overview/thread_overview.tsx (the participant stack + reply count
// under a root), app/components/post_list/post/body/reply_count (tapping it opens the thread),
// app/actions/websocket/posts.ts (a reply's `posted` frame updates the root's `reply_count`).
//
// T34 shipped the collapsed timeline without a reply line and documented it as T36's; these tests pin
// the two directions that make the line honest — an arriving reply, and a delete.

import XCTest
@testable import Mattermost

@MainActor
final class T36ChannelReplyLineTests: XCTestCase {

    func testAReplyArrivingOnTheSocketRaisesItsRootsCountWithoutAddingARow() async {
        let service = FakeChannelService()
        service.posts = [MMPostList(order: ["root"],
                                    posts: ["root": post("root", at: 100, channel: "c1")])]
        let model = makeModel(service: service)
        await model.load()
        XCTAssertEqual(model.timelineRows.count, 1)

        let outcome = model.handle(.posted(post("r1", at: 200, channel: "c1", rootID: "root")))

        XCTAssertEqual(outcome, .patched)
        XCTAssertEqual(model.timelineRows.count, 1, "a reply is not a row of the collapsed timeline")
        XCTAssertEqual(model.timelineRows.first?.replyCount, 1)
        XCTAssertEqual(model.timelineRows.first?.participants.map(\.id), ["them"])
    }

    func testAReplayedReplyFrameCannotInflateTheCount() async {
        // A reconnect replays frames; the reply's `create_at` is already counted by the root.
        let service = FakeChannelService()
        service.posts = [MMPostList(order: ["root"],
                                    posts: ["root": post("root", at: 100, channel: "c1")])]
        let model = makeModel(service: service)
        await model.load()

        _ = model.handle(.posted(post("r1", at: 200, channel: "c1", rootID: "root")))
        _ = model.handle(.posted(post("r1", at: 200, channel: "c1", rootID: "root")))

        XCTAssertEqual(model.timelineRows.first?.replyCount, 1)
    }

    func testTwoRepliesCountTwice() async {
        let service = FakeChannelService()
        service.posts = [MMPostList(order: ["root"],
                                    posts: ["root": post("root", at: 100, channel: "c1")])]
        let model = makeModel(service: service)
        await model.load()

        _ = model.handle(.posted(post("r1", at: 200, channel: "c1", rootID: "root")))
        _ = model.handle(.posted(post("r2", at: 300, channel: "c1", rootID: "root", user: "bo")))

        XCTAssertEqual(model.timelineRows.first?.replyCount, 2)
        XCTAssertEqual(model.timelineRows.first?.participants.map(\.id), ["bo", "them"])
    }

    func testDeletingAReplyLowersTheCount() async {
        let service = FakeChannelService()
        service.posts = [MMPostList(order: ["root"],
                                    posts: ["root": post("root", at: 100, channel: "c1")])]
        let model = makeModel(service: service)
        await model.load()
        _ = model.handle(.posted(post("r1", at: 200, channel: "c1", rootID: "root")))

        var deleted = post("r1", at: 200, channel: "c1", rootID: "root")
        deleted.deleteAt = 999
        deleted.updateAt = 999
        let outcome = model.handle(.postDeleted(deleted))

        XCTAssertEqual(outcome, .patched)
        XCTAssertEqual(model.timelineRows.first?.replyCount, 0)
        XCTAssertEqual(model.timelineRows.count, 1)
    }

    func testAReplyForARootTheWindowDoesNotHoldChangesNothing() async {
        let service = FakeChannelService()
        service.posts = [MMPostList(order: ["root"],
                                    posts: ["root": post("root", at: 100, channel: "c1")])]
        let model = makeModel(service: service)
        await model.load()

        let outcome = model.handle(.posted(post("r1", at: 200, channel: "c1", rootID: "not-in-window")))

        XCTAssertEqual(outcome, .ignored)
        XCTAssertEqual(model.timelineRows.first?.replyCount, 0)
    }

    func testThreadUpdatedSetsTheServersExactCount() async {
        let service = FakeChannelService()
        service.posts = [MMPostList(order: ["root"],
                                    posts: ["root": post("root", at: 100, channel: "c1")])]
        let model = makeModel(service: service)
        await model.load()

        let thread = MMThread(id: "root", replyCount: 7, lastReplyAt: 700,
                              participants: [MMUser(id: "bo", username: "bo", firstName: "Bo")],
                              post: post("root", at: 100, channel: "c1"))
        let outcome = model.handle(.threadUpdated(SocketThreadUpdated(thread: thread,
                                                                     previousUnreadReplies: 0,
                                                                     previousUnreadMentions: 0)))

        XCTAssertEqual(outcome, .patched)
        XCTAssertEqual(model.timelineRows.first?.replyCount, 7, "the server's recomputation is authoritative")
        XCTAssertEqual(model.timelineRows.first?.participants.map(\.displayName), ["Bo"])
    }

    func testTheReplyActivityFromTheThreadPanePachesTheRow() async {
        // The thread pane's own count after it loaded or sent a reply: the two panes must agree about
        // the same thread without waiting for a socket frame.
        let service = FakeChannelService()
        service.posts = [MMPostList(order: ["root"],
                                    posts: ["root": post("root", at: 100, channel: "c1")])]
        let model = makeModel(service: service)
        await model.load()

        model.applyReplyActivity(rootID: "root", count: 4, lastReplyAt: 400)

        XCTAssertEqual(model.timelineRows.first?.replyCount, 4)
    }

    // MARK: - Fixtures

    private func makeModel(service: FakeChannelService) -> ChannelViewModel {
        ChannelViewModel(channelID: "c1",
                         channelName: "c1",
                         service: service,
                         myUserID: "me",
                         lastViewedAt: 0,
                         now: { Date(timeIntervalSince1970: 1_000) })
    }

    private func post(_ id: String,
                      at createAt: Int64,
                      channel: String,
                      rootID: String = "",
                      user: String = "them") -> MMPost {
        MMPost(id: id, createAt: createAt, userId: user, channelId: channel, rootId: rootID,
               message: "m-\(id)")
    }
}

private extension ChannelViewModel {
    /// The post rows the timeline draws (no separators, no unread divider) — the list the reply line
    /// lives in.
    var timelineRows: [PostRowModel] {
        items.compactMap { item in
            if case .post(let row) = item { return row }
            return nil
        }
    }
}

/// The smallest `ChannelServing` the reply line needs: one page of posts, no attachments.
@MainActor
final class FakeChannelService: ChannelServing {
    var posts: [MMPostList] = []
    var pageSize = 60
    var usersByID: [String: MMUser] = [:]
    private var served = 0

    func channel(id: String) async throws -> MMChannel {
        MMChannel(id: id, name: id, displayName: id.capitalized, type: "O")
    }

    func posts(channelID: String, before: String?, perPage: Int) async throws -> MMPostList {
        guard !posts.isEmpty else { return MMPostList() }
        let slot = min(served, posts.count - 1)
        served += 1
        return posts[slot]
    }

    func users(ids: [String]) async throws -> [MMUser] {
        ids.compactMap { usersByID[$0] }
    }

    func fileData(fileID: String, preferThumbnail: Bool) async throws -> Data {
        throw MMError.notFound
    }
}
