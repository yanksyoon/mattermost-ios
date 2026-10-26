// T35 — the list's half of the composer: the optimistic row, its reconciliation **by
// `pending_post_id`**, the tombstone an edit/delete produces, and the "did it land anyway?" question
// a retry asks.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0, `app/actions/remote/post.ts`
// (the `pending_post_id` round trip and `handlePosts`), `app/actions/websocket/posts.ts` (the
// `posted` echo), `app/utils/post_list/index.ts` (a pending post is replaced, never appended).
// Licence Apache-2.0; see docs/THIRD_PARTY_NOTICES.md §12.
//
// These tests drive the *real* `ChannelViewModel` against a fake service, because the rules being
// checked are about the loaded window: whether the echo beat the REST answer, whether the row is
// already on screen, and where a replacement belongs in the order.

import XCTest
@testable import Mattermost

@MainActor
final class T35ChannelPendingRowTests: XCTestCase {

    private let channelID = "chan-1"

    @MainActor
    final class FakeChannelService: ChannelServing {
        var page = MMPostList(order: [], posts: [:])
        var channel = MMChannel(id: "chan-1", name: "town-square", displayName: "Town Square",
                                type: "O", teamId: "team-1")
        var usersByID: [String: MMUser] = [:]

        private(set) var requestedCursors: [String?] = []

        func channel(id: String) async throws -> MMChannel { channel }

        func posts(channelID: String, before: String?, perPage: Int) async throws -> MMPostList {
            requestedCursors.append(before)
            return before == nil ? page : MMPostList()
        }

        func users(ids: [String]) async throws -> [MMUser] { ids.compactMap { usersByID[$0] } }
        func fileData(fileID: String, preferThumbnail: Bool) async throws -> Data {
            throw MMError.notFound
        }
    }

    private var service: FakeChannelService!
    private var model: ChannelViewModel!

    override func setUp() async throws {
        service = FakeChannelService()
        model = ChannelViewModel(channelID: channelID, channelName: "Town Square",
                                 service: service, myUserID: "u1", lastViewedAt: 0)
    }

    // MARK: Helpers

    private func serverPost(_ id: String, at millis: Int64, message: String? = nil) -> MMPost {
        MMPost(id: id, createAt: millis, userId: "u1", channelId: channelID,
               message: message ?? "message \(id)")
    }

    private func pendingPost(_ id: String, at millis: Int64, rootID: String = "",
                             message: String? = nil) -> MMPost {
        MMPost(id: id, createAt: millis, userId: "u1", channelId: channelID, rootId: rootID,
               message: message ?? "optimistic", pendingPostId: id)
    }

    private func loadWindow(_ posts: [MMPost]) async {
        service.page = MMPostList(order: posts.map(\.id),
                                  posts: Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) }))
        await model.load(ifNeeded: true)
    }

    private func rows() -> [PostRowModel] {
        model.items.compactMap { item in
            if case .post(let row) = item { return row }
            return nil
        }
    }

    private func row(id: String) -> PostRowModel? { rows().first { $0.id == id } }

    // MARK: - The optimistic row

    func testAPendingRowIsDrawnWithASendingStatus() async {
        await loadWindow([serverPost("p1", at: 1_000)])
        model.insertPendingPost(pendingPost("pending:1", at: 2_000))

        let row = row(id: "pending:1")
        XCTAssertNotNil(row, "the optimistic row must be in the list immediately")
        XCTAssertTrue(row?.isPending ?? false)
        XCTAssertEqual(model.pendingRowIDsForTests, ["pending:1"])
        // Newest first: the message the person just sent is at the bottom of the list.
        XCTAssertEqual(rows().last?.id, "pending:1")
    }

    func testConfirmingReplacesThePendingRowWithTheServersPost() async {
        await loadWindow([serverPost("p1", at: 1_000)])
        model.insertPendingPost(pendingPost("pending:1", at: 2_000))

        let saved = serverPost("p2", at: 2_100, message: "optimistic")
        model.confirmPendingPost(id: "pending:1", with: saved)

        XCTAssertNil(row(id: "pending:1"))
        XCTAssertEqual(row(id: "p2")?.post.message, "optimistic")
        XCTAssertFalse(row(id: "p2")?.isPending ?? true)
        XCTAssertEqual(rows().count, 2, "one row per post — the pending row must not linger")
        XCTAssertTrue(model.pendingRowIDsForTests.isEmpty)
    }

    // MARK: - The socket echo, in both orders

    func testTheSocketEchoAfterTheRestAnswerDoesNotDuplicateTheRow() async {
        await loadWindow([serverPost("p1", at: 1_000)])
        model.insertPendingPost(pendingPost("pending:1", at: 2_000))
        let saved = serverPost("p2", at: 2_100, message: "optimistic")
        model.confirmPendingPost(id: "pending:1", with: saved)

        // Same post, over the socket, carrying the client id the app supplied.
        var echo = saved
        echo.pendingPostId = "pending:1"
        let outcome = model.handle(.posted(echo))

        XCTAssertEqual(outcome, .patched)
        XCTAssertEqual(rows().filter { $0.id == "p2" }.count, 1)
        XCTAssertNil(row(id: "pending:1"))
    }

    func testTheSocketEchoBeforeTheRestAnswerLeavesOneRow() async {
        await loadWindow([serverPost("p1", at: 1_000)])
        model.insertPendingPost(pendingPost("pending:1", at: 2_000))

        // The echo beats the REST response: the pending row is withdrawn and the server's post takes
        // its place. A reply would not be drawn here at all, which is why the width matters.
        var echo = serverPost("p2", at: 2_100, message: "optimistic")
        echo.pendingPostId = "pending:1"
        model.handle(.posted(echo))
        XCTAssertNil(row(id: "pending:1"))
        XCTAssertEqual(rows().filter { $0.id == "p2" }.count, 1)

        // …and the REST answer arriving afterwards finds the row already there.
        var saved = echo
        saved.pendingPostId = ""
        model.confirmPendingPost(id: "pending:1", with: saved)
        XCTAssertEqual(rows().filter { $0.id == "p2" }.count, 1)
        XCTAssertEqual(rows().count, 2)
    }

    func testAReplysEchoIsNotAddedToTheChannel() async {
        await loadWindow([serverPost("p1", at: 1_000)])

        // A reply the app itself sent: the socket echoes it with this device's client id. The
        // channel list keeps top-level posts only (T34-AV-F1), so the echo is ignored here — the
        // thread pane (S13/T36) is where a reply is drawn.
        var reply = MMPost(id: "reply-1", createAt: 2_200, userId: "u1", channelId: channelID,
                           rootId: "p1", message: "in the thread")
        reply.pendingPostId = "pending:1"
        let outcome = model.handle(.posted(reply))

        XCTAssertEqual(outcome, .ignored)
        XCTAssertFalse(model.loadedPostIDs.contains("reply-1"))
        XCTAssertEqual(rows().count, 1)
    }

    func testInsertingAPendingRowForAReplyIsRefused() async {
        await loadWindow([serverPost("p1", at: 1_000)])
        model.insertPendingPost(pendingPost("pending:1", at: 2_000, rootID: "p1"))
        // A row that could never reconcile would be a permanent phantom.
        XCTAssertNil(row(id: "pending:1"))
        XCTAssertTrue(model.pendingRowIDsForTests.isEmpty)
    }

    // MARK: - Failure and retry

    func testAFailedSendTakesTheRowAway() async {
        await loadWindow([serverPost("p1", at: 1_000)])
        model.insertPendingPost(pendingPost("pending:1", at: 2_000))
        model.removePendingPost(id: "pending:1")

        XCTAssertNil(row(id: "pending:1"))
        XCTAssertEqual(rows().count, 1)
        XCTAssertNil(model.post(withPendingID: "pending:1"),
                     "a removed row is not a post that landed")
    }

    func testTheRetryCheckAnswersYesOnceThePostIsKnown() async {
        await loadWindow([serverPost("p1", at: 1_000)])
        model.insertPendingPost(pendingPost("pending:1", at: 2_000))
        XCTAssertNil(model.post(withPendingID: "pending:1"), "nothing landed yet")

        model.confirmPendingPost(id: "pending:1", with: serverPost("p2", at: 2_100))
        XCTAssertEqual(model.post(withPendingID: "pending:1")?.id, "p2")
    }

    // MARK: - Edit and delete

    func testAnEditPatchesTheRowInPlace() async {
        await loadWindow([serverPost("p1", at: 1_000, message: "before"),
                          serverPost("p2", at: 2_000, message: "second")])
        model.replacePost(serverPost("p1", at: 1_000, message: "after"))

        XCTAssertEqual(row(id: "p1")?.post.message, "after")
        // An edit does not move the row: the conversation's order is the send order.
        XCTAssertEqual(rows().map(\.id), ["p1", "p2"])
    }

    func testADeleteLeavesATombstoneNotAGap() async {
        await loadWindow([serverPost("p1", at: 1_000), serverPost("p2", at: 2_000)])
        model.tombstonePost(id: "p2")

        let tombstone = row(id: "p2")
        XCTAssertNotNil(tombstone, "the row keeps its slot")
        XCTAssertTrue(tombstone?.isDeleted ?? false)
        XCTAssertEqual(tombstone?.post.message, "")
        // The later socket event finds nothing left to do: same tombstone, no duplicate.
        var deleted = serverPost("p2", at: 2_000)
        deleted.deleteAt = 9_000
        model.handle(.postDeleted(deleted))
        XCTAssertEqual(rows().filter { $0.id == "p2" }.count, 1)
        XCTAssertEqual(rows().count, 2)
    }

    func testAnEditToAPostOutsideTheWindowIsIgnored() async {
        await loadWindow([serverPost("p1", at: 1_000)])
        // Nothing to patch, and — crucially — nothing appended: an old post must not jump to the
        // bottom of the list because it was edited.
        model.replacePost(serverPost("ancient", at: 1))
        XCTAssertEqual(rows().map(\.id), ["p1"])
    }
}
