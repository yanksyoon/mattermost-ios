// t_05caa678 — the header's bookmarks bar, with no network and no clock.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560)
// `app/components/channel_bookmarks/channel_bookmarks.tsx` (draws `null` when there is nothing —
// no empty state, no spinner), `app/components/channel_bookmarks/channel_bookmark/channel_bookmark.tsx`
// (a link chip opens its `link_url`), `app/screens/channel/header/header.tsx:145`
// (`showBookmarkBar = isBookmarksEnabled && hasBookmarks && shouldRenderBookmarks`).
//
// What is asserted here, and why it is asserted *here* rather than only on a live server:
//
//  * the **order** is the server's (`sort_order`), because no server on this host answers 200 for the
//    route — the pinned 9.11.19 Team Edition fixture answers 404 for every `/channels/{id}/bookmarks`
//    call (`scripts/t52_channel_probe.py`, re-measured for this card) — so a live 200 test would be a
//    skipped test, and an unasserted rule;
//  * a **404 is not an error**: the same absence as an empty list, with nothing drawn anywhere else.
//    This is the card's rule for the sheet's fetch (a missing feature must not look like a broken
//    screen) applied to the bar;
//  * the bar is **one fetch per appearance**, so a pane re-appearing does not re-ask and cannot
//    flicker.

import XCTest
@testable import Mattermost

@MainActor
final class T05ChannelBookmarksTests: XCTestCase {

    private let channelID = "chan0000000000000000000001"

    // MARK: - Fakes

    /// A service that answers with what the test says, and counts how often it was asked.
    @MainActor
    private final class FakeService: ChannelBookmarkServing {
        var answer: [MMChannelBookmark]
        var error: Error?
        /// Held before answering, so two overlapping `load()` calls can actually overlap.
        var delayNanos: UInt64 = 0
        private(set) var calls: [[String]] = []

        init(answer: [MMChannelBookmark] = [], error: Error? = nil) {
            self.answer = answer
            self.error = error
        }

        func bookmarks(channelID: String) async throws -> [MMChannelBookmark] {
            calls.append([channelID])
            if delayNanos > 0 { try? await Task.sleep(nanoseconds: delayNanos) }
            if let error { throw error }
            return answer
        }
    }

    private func bookmark(_ id: String,
                          name: String,
                          order: Int64,
                          type: String = "link",
                          link: String = "https://example.com/\(UUID().uuidString)",
                          deleteAt: Int64 = 0) -> MMChannelBookmark {
        MMChannelBookmark(id: id,
                          channelID: channelID,
                          displayName: name,
                          type: type,
                          sortOrder: order,
                          linkURL: link,
                          deleteAt: deleteAt)
    }

    // MARK: - Order

    /// The server's arrangement is the bar's arrangement — not alphabetical, not by id.
    func testTheServersSortOrderIsTheDrawOrder() async {
        let service = FakeService(answer: [
            bookmark("b3", name: "Zebra", order: 30),
            bookmark("b1", name: "Apple", order: 10),
            bookmark("b2", name: "Mango", order: 20),
        ])
        let model = ChannelBookmarksViewModel(channelID: channelID, service: service)
        await model.load()

        XCTAssertEqual(model.rowIDs, ["b1", "b2", "b3"],
                       "the bar must draw the server's order, not a client-side one")
        XCTAssertEqual(model.bookmarks.map(\.displayName), ["Apple", "Mango", "Zebra"])
        XCTAssertTrue(model.isVisible)
    }

    /// Two rows with the same `sort_order` keep the server's own arrival order (a stable sort: the
    /// alternative silently reorders a bar the reader arranged).
    func testEqualSortOrdersKeepTheServersArrivalOrder() async {
        let service = FakeService(answer: [
            bookmark("second", name: "Second", order: 5),
            bookmark("first", name: "First", order: 5),
        ])
        let model = ChannelBookmarksViewModel(channelID: channelID, service: service)
        await model.load()

        XCTAssertEqual(model.rowIDs, ["second", "first"],
                       "a tie must keep the server's order, not sort by id or name")
    }

    /// A tombstoned row and a row with no id are not drawn: the first is gone on the server, the
    /// second could not be identified, tapped or de-duplicated.
    func testTombstonedAndUnidentifiableRowsAreNotDrawn() async {
        let service = FakeService(answer: [
            bookmark("live", name: "Live", order: 1),
            bookmark("gone", name: "Gone", order: 2, deleteAt: 1793000000000),
            bookmark("", name: "Nameless id", order: 3),
        ])
        let model = ChannelBookmarksViewModel(channelID: channelID, service: service)
        await model.load()

        XCTAssertEqual(model.rowIDs, ["live"])
    }

    // MARK: - 404 / failure: absent, not broken

    /// The fixture's answer (404 on a build without the route). The bar is absent, nothing is
    /// retried in the background, and the failure is recorded as `unsupported` rather than an error
    /// the UI would have to draw.
    func testA404IsAQuietUnavailableState() async {
        let service = FakeService(error: MMError.notFound)
        let model = ChannelBookmarksViewModel(channelID: channelID, service: service)
        await model.load()

        XCTAssertEqual(model.phase, .unavailable)
        XCTAssertFalse(model.isVisible, "a 404 must not draw a bar, an empty box or an error")
        XCTAssertTrue(model.bookmarks.isEmpty)
        XCTAssertEqual(model.outcome, "bookmarks=unsupported status=404")
        XCTAssertEqual(service.calls.count, 1)
    }

    /// A transport failure is the same absence. The card's rule is that the feature can never be
    /// the reason the header or the post list looks broken, so nothing about the failure reaches
    /// the screen.
    func testATransportFailureIsTheSameAbsentBar() async {
        let service = FakeService(error: MMError.timeout)
        let model = ChannelBookmarksViewModel(channelID: channelID, service: service)
        await model.load()

        XCTAssertEqual(model.phase, .unavailable)
        XCTAssertFalse(model.isVisible)
        XCTAssertEqual(model.outcome, "bookmarks=failed status=none")
    }

    /// A 200 with no rows is not "unavailable" — it is a loaded, empty bar. Same pixels, different
    /// fact, and the distinction is what the diagnostics line reports.
    func testAnEmptyAnswerIsLoadedAndDrawsNothing() async {
        let model = ChannelBookmarksViewModel(channelID: channelID, service: FakeService(answer: []))
        await model.load()

        XCTAssertEqual(model.phase, .loaded)
        XCTAssertFalse(model.isVisible, "an empty list draws no bar — zero height, not an empty box")
        XCTAssertEqual(model.outcome, "bookmarks=loaded count=0")
    }

    // MARK: - One fetch, no flicker

    /// The pane's `.task` runs on every appearance. A bar already answered must not be re-asked (a
    /// second request could flash a bar away on a slow server).
    func testASecondAppearanceDoesNotRefetch() async {
        let service = FakeService(answer: [bookmark("b1", name: "One", order: 1)])
        let model = ChannelBookmarksViewModel(channelID: channelID, service: service)
        await model.load()
        await model.load()
        await model.load(ifNeeded: false)

        XCTAssertEqual(service.calls.count, 2,
                       "the default is one fetch per appearance; `ifNeeded: false` is the explicit refetch")
        XCTAssertEqual(model.rowIDs, ["b1"])
    }

    /// After an unavailable answer, a re-appearance is also not a retry — the bar that was absent
    /// stays absent without a request per appearance.
    func testAnUnavailableBarIsNotRetriedOnEveryAppearance() async {
        let service = FakeService(error: MMError.notFound)
        let model = ChannelBookmarksViewModel(channelID: channelID, service: service)
        await model.load()
        await model.load()

        XCTAssertEqual(service.calls.count, 1)
    }

    /// Two appearances that overlap share one request (measured on the live suite: SwiftUI ran the
    /// pane's `.task(id:)` twice while the post list settled, and the fixture saw two requests).
    func testOverlappingAppearancesShareOneRequest() async {
        let service = FakeService(answer: [bookmark("b1", name: "One", order: 1)])
        service.delayNanos = 150_000_000
        let model = ChannelBookmarksViewModel(channelID: channelID, service: service)

        let first = Task { await model.load() }
        let second = Task { await model.load() }
        _ = await first.value
        _ = await second.value

        XCTAssertEqual(service.calls.count, 1, "one appearance, one request — even when two callers race")
        XCTAssertEqual(model.rowIDs, ["b1"])
        XCTAssertTrue(model.isVisible)
    }

    /// The rows survive the pane staying open: a reload of the same answer leaves the bar drawn and
    /// in the same order (the "tapping a bookmark must not lose the bar" rule).
    func testTheBarKeepsItsRowsWithThePaneOpen() async {
        let service = FakeService(answer: [bookmark("b1", name: "One", order: 1),
                                           bookmark("b2", name: "Two", order: 2)])
        let model = ChannelBookmarksViewModel(channelID: channelID, service: service)
        await model.load()
        let before = model.rowIDs
        await model.load(ifNeeded: false)

        XCTAssertEqual(model.rowIDs, before)
        XCTAssertTrue(model.isVisible)
    }

    // MARK: - What a chip says and where it goes

    func testALinkChipOpensItsTarget() {
        let link = bookmark("b1", name: "Docs", order: 1, link: "https://mattermost.com/docs")
        XCTAssertEqual(ChannelBookmarksDerivation.url(for: link)?.absoluteString,
                       "https://mattermost.com/docs")
    }

    /// Only web links are opened. A bookmark whose `link_url` is `javascript:` or empty is not a
    /// button — the bar must not hand an arbitrary scheme to the system opener.
    func testOnlyWebLinksAreOpened() {
        XCTAssertNil(ChannelBookmarksDerivation.url(for: bookmark("b1", name: "x", order: 1, link: "")))
        XCTAssertNil(ChannelBookmarksDerivation.url(
            for: bookmark("b2", name: "x", order: 2, link: "javascript:alert(1)")))
        XCTAssertNil(ChannelBookmarksDerivation.url(
            for: bookmark("b3", name: "x", order: 3, link: "file:///etc/passwd")))
        XCTAssertNil(ChannelBookmarksDerivation.url(
            for: bookmark("b4", name: "file", order: 4, type: "file", link: "")))
    }

    /// A name is never replaced by an id: an unnamed bookmark reads as a word.
    func testAnUnnamedChipFallsBackToAWord() {
        XCTAssertEqual(ChannelBookmarksDerivation.label(for: bookmark("b1", name: "  ", order: 1)),
                       "Bookmark")
        XCTAssertEqual(ChannelBookmarksDerivation.label(
            for: bookmark("b2", name: "", order: 2, type: "file")), "File")
        XCTAssertEqual(ChannelBookmarksDerivation.label(
            for: bookmark("b3", name: "Runbook", order: 3)), "Runbook")
    }

    func testTheChipGlyphFollowsTheBookmarkType() {
        XCTAssertEqual(ChannelBookmarksDerivation.glyph(for: bookmark("b1", name: "x", order: 1)), "link")
        XCTAssertEqual(ChannelBookmarksDerivation.glyph(
            for: bookmark("b2", name: "x", order: 2, type: "file")), "paperclip")
    }

    // MARK: - Wire shape

    /// The shipped route answers an **array** of bookmark objects (upstream
    /// `getChannelBookmarksForChannel` → `ChannelBookmarkWithFileInfo[]`). Decoding is tolerant on
    /// every field but `id`, so one odd value cannot blank the whole bar.
    func testTheWireShapeDecodesWithMissingOptionalFields() throws {
        let json = """
        [{"id":"a","channel_id":"c","display_name":"Docs","type":"link",
          "sort_order":2,"link_url":"https://example.com","delete_at":0},
         {"id":"b","display_name":"No type"}]
        """
        let rows = try JSONDecoder().decode([MMChannelBookmark].self, from: Data(json.utf8))
        XCTAssertEqual(rows.map(\.id), ["a", "b"])
        XCTAssertEqual(rows[0].sortOrder, 2)
        XCTAssertEqual(rows[0].linkURL, "https://example.com")
        XCTAssertEqual(rows[1].type, "link", "a missing type degrades to the common default")
        XCTAssertEqual(rows[1].sortOrder, 0)
    }
}
