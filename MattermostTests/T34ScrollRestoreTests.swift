// T34 — the scroll-restore arithmetic and the view model's anchor handoff.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0,
// app/screens/channel/channel_post_list/channel_post_list.tsx (`onViewableItemsChanged` records the
// first viewable post; after a page is prepended the list is scrolled back to it) and the
// `maintainVisibleContentPosition` behaviour upstream gets from its inverted list.
//
// What is *not* tested here: the pixels. That is `MattermostUITests/T34-ChannelPostListUITests
// .testReachingTheTopKeepsTheReadersPostInPlace`, which measures the anchored row's frame on a real
// server. This file pins the numbers that test depends on, so a regression in the arithmetic is a
// fast red unit test rather than a flaky UI run.

import XCTest
@testable import Mattermost

@MainActor
final class T34ScrollRestoreTests: XCTestCase {

    // MARK: - The adjustment

    func testTheAdjustmentIsTheDistanceThePostMoved() {
        // The reader was 42 pt into the anchored post; after the prepend it sits 1042 pt down, so the
        // content has to move up by exactly 1000 pt.
        XCTAssertEqual(ScrollRestorePlan.adjustment(recordedOffsetFromTop: 42, currentOffsetFromTop: 1_042),
                       1_000)
    }

    func testAPostThatDidNotMoveNeedsNoAdjustment() {
        let adjustment = ScrollRestorePlan.adjustment(recordedOffsetFromTop: 12, currentOffsetFromTop: 12)
        XCTAssertEqual(adjustment, 0)
        XCTAssertTrue(ScrollRestorePlan.isNoOp(adjustment))
    }

    func testSubPixelNoiseIsIgnoredAndRealMovesAreNot() {
        XCTAssertTrue(ScrollRestorePlan.isNoOp(0.4))
        XCTAssertTrue(ScrollRestorePlan.isNoOp(-0.4))
        XCTAssertFalse(ScrollRestorePlan.isNoOp(0.6))
        XCTAssertFalse(ScrollRestorePlan.isNoOp(-1))
    }

    func testNegativeOffsetsAreHandled() {
        // An over-scroll can leave the anchored post above the viewport top; the arithmetic is the
        // same, and the controller clamps the result.
        XCTAssertEqual(ScrollRestorePlan.adjustment(recordedOffsetFromTop: -30, currentOffsetFromTop: 970),
                       1_000)
    }

    func testNonFiniteInputNeverProducesAScroll() {
        XCTAssertEqual(ScrollRestorePlan.adjustment(recordedOffsetFromTop: .nan, currentOffsetFromTop: 10), 0)
        XCTAssertEqual(ScrollRestorePlan.adjustment(recordedOffsetFromTop: 10, currentOffsetFromTop: .infinity), 0)
        XCTAssertTrue(ScrollRestorePlan.isNoOp(.nan))
        XCTAssertTrue(ScrollRestorePlan.isNoOp(.infinity))
    }

    // MARK: - Which row the reader is on

    /// The values handed to `topVisible` are **distances below the viewport's top edge**, measured from
    /// each row's own view (`ChannelScrollController.offsetFromTop`). The anchor is the smallest
    /// non-negative one — a row that straddles the edge belongs to the reader, the rows above it do not.
    /// (T34-R3 fed this content-space positions and picked the first row of the window; T34-R4 reads
    /// the distance from UIKit so there is no conversion left to get wrong.)
    func testTheAnchorIsTheTopmostRowBelowTheViewportEdgeNotTheFirstRowInTheContent() {
        let rows: [String: CGFloat] = ["oldest": -4_000, "above": -200, "edge": 120, "next": 400]
        let anchor = ScrollRestorePlan.topVisible(rows: rows)
        XCTAssertEqual(anchor?.id, "edge")
        XCTAssertEqual(anchor?.offsetFromTop ?? -1, 120, accuracy: 0.001)
    }

    func testRowsScrolledPastTheEdgeAreIgnored() {
        let rows: [String: CGFloat] = ["gone": -1_000, "slightlyAbove": -2, "visible": 100]
        let anchor = ScrollRestorePlan.topVisible(rows: rows)
        XCTAssertEqual(anchor?.id, "visible",
                       "a row 2 pt above the edge is not the reader's place; the next one is")
    }

    func testAnOverscrollFallsBackToTheNearestRow() {
        let rows: [String: CGFloat] = ["a": -2_100, "b": -1_000]
        let anchor = ScrollRestorePlan.topVisible(rows: rows)
        XCTAssertEqual(anchor?.id, "b", "every row is above the viewport: the nearest one is the answer")
        XCTAssertEqual(anchor?.offsetFromTop ?? 0, -1_000, accuracy: 0.001)
    }

    func testNoRowsMeansNoAnchor() {
        XCTAssertNil(ScrollRestorePlan.topVisible(rows: [:]))
    }

    // MARK: - The handoff

    func testTheAnchorCarriesTheOffsetNotJustThePost() {
        let anchor = ChannelViewModel.ScrollAnchor(postID: "p42", offsetFromTop: 137.5)
        XCTAssertEqual(anchor.postID, "p42")
        XCTAssertEqual(anchor.offsetFromTop, 137.5,
                       "the offset is what makes the restore exact; a test that only checks the id is not enough")
    }

    /// The view model must not drop the offset between the capture and the restore: that was the
    /// substance of review finding F5 (the view recorded it and scrolled to the row's top instead).
    func testTheRestoreHandoffCarriesTheRecordedOffset() async {
        let service = FakeChannelService(pageSize: 2)
        service.firstPage = MMPostList(order: ["b", "a"],
                                       posts: ["b": post("b", 2_000), "a": post("a", 1_000)])
        service.olderPages["a"] = MMPostList(order: ["z"], posts: ["z": post("z", 500)])
        let model = ChannelViewModel(channelID: "ch", channelName: "Town Square", service: service)
        await model.load()

        let anchor = ChannelViewModel.ScrollAnchor(postID: "b", offsetFromTop: 87.25)
        model.setScrollAnchor(anchor)
        _ = await model.loadEarlier()

        XCTAssertEqual(model.pendingScrollRestore, anchor)
        XCTAssertEqual(model.pendingScrollRestore?.offsetFromTop, 87.25)
        model.consumeScrollRestore()
        XCTAssertNil(model.pendingScrollRestore)
    }

    /// `loadEarlier()` asks the view for the reader's place *before* it sends the request, and that
    /// reading wins over an older sample: an anchor sampled a moment too late is the position the post
    /// has after the insert, which would make the restore a no-op and leave the reader displaced by a
    /// whole page (the live defect behind T34-R4).
    func testLoadEarlierTakesTheAnchorFromTheViewBeforeTheRequest() async {
        let service = FakeChannelService(pageSize: 2)
        service.firstPage = MMPostList(order: ["b", "a"],
                                       posts: ["b": post("b", 2_000), "a": post("a", 1_000)])
        service.olderPages["a"] = MMPostList(order: ["z"], posts: ["z": post("z", 500)])
        let model = ChannelViewModel(channelID: "ch", channelName: "Town Square", service: service)
        await model.load()

        model.setScrollAnchor(.init(postID: "b", offsetFromTop: 10))     // stale sample
        model.readerAnchorProvider = { .init(postID: "a", offsetFromTop: 250) }

        _ = await model.loadEarlier()

        XCTAssertEqual(model.pendingScrollRestore, .init(postID: "a", offsetFromTop: 250),
                       "the anchor must come from the view's fresh reading, not the last poll")
    }

    /// A view-less host (unit tests, a future host without a scroll view) keeps working: no provider
    /// means the previously set anchor is used unchanged.
    func testWithoutAProviderTheAnchorIsUnchanged() async {
        let service = FakeChannelService(pageSize: 2)
        service.firstPage = MMPostList(order: ["b", "a"],
                                       posts: ["b": post("b", 2_000), "a": post("a", 1_000)])
        service.olderPages["a"] = MMPostList(order: ["z"], posts: ["z": post("z", 500)])
        let model = ChannelViewModel(channelID: "ch", channelName: "Town Square", service: service)
        await model.load()

        let anchor = ChannelViewModel.ScrollAnchor(postID: "b", offsetFromTop: 44)
        model.setScrollAnchor(anchor)
        model.readerAnchorProvider = { nil }

        _ = await model.loadEarlier()
        XCTAssertEqual(model.pendingScrollRestore, anchor)
    }

    // MARK: - Helpers

    private func post(_ id: String, _ millis: Int64) -> MMPost {
        MMPost(id: id, createAt: millis, userId: "u1", channelId: "ch", message: "message \(id)")
    }

    @MainActor
    private final class FakeChannelService: ChannelServing {
        let pageSize: Int
        var firstPage = MMPostList()
        var olderPages: [String: MMPostList] = [:]

        init(pageSize: Int) { self.pageSize = pageSize }

        func channel(id: String) async throws -> MMChannel {
            MMChannel(id: id, name: "town-square", displayName: "Town Square", type: "O", teamId: "t")
        }

        func posts(channelID: String, before: String?, perPage: Int) async throws -> MMPostList {
            if let before { return olderPages[before] ?? MMPostList() }
            return firstPage
        }

        func users(ids: [String]) async throws -> [MMUser] { [] }

        func fileData(fileID: String, preferThumbnail: Bool) async throws -> Data {
            throw MMError.notFound
        }
    }
}
