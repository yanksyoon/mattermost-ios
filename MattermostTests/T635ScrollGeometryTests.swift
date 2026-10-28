// T635-A — the two claims the restored-pane falsifier reads, pinned without a simulator.
//
// `T635RestoredPaneUITests` measures the real list through `-uiTestExposeScrollGeometry`; this file pins
// the reading those measurements are judged by, so a change to "a row is on screen" is a fast red unit
// test rather than a 70 s UI run. Every number below is one measured on iPhone 16 Pro / iOS 18.3 during
// the defect's reproduction (card t_7cb5dd3e, `docs/t635a-build-note.md`).
//
// What is *not* tested here: the layout. That a `LazyVStack` materialises nothing while its viewport sits
// past the rows it has laid out is the bug; the UI test is the falsifier for it.

import XCTest
@testable import Mattermost

final class T635ScrollGeometryTests: XCTestCase {

    private func sample(items: Int = 62, rows: Int = 0, visible: Int = 0,
                        offset: CGFloat = 0, size: CGFloat = 0, viewport: CGFloat = 0,
                        lowestRow: CGFloat = -.infinity, fromBottom: CGFloat = 0)
        -> ChannelScrollGeometrySample {
        ChannelScrollGeometrySample(attached: true, offsetY: offset, contentHeight: size,
                                    viewportHeight: viewport, insetTop: 0, insetBottom: 0,
                                    laidOutRows: rows, visibleRows: visible, topRowID: nil,
                                    topRowOffset: .infinity, lowestRowBottom: lowestRow,
                                    distanceFromBottom: fromBottom, itemCount: items,
                                    fitsViewport: false)
    }

    /// The blank pane as measured through the seam on the unfixed tree: the window is loaded, the list is
    /// not attached, nothing is laid out — and the pane is on screen looking exactly like an empty
    /// channel with no rows.
    func testANonEmptyWindowWithNoVisibleRowIsNotARowOnScreen() {
        let blank = sample(items: 62, rows: 0, visible: 0,
                           offset: 0, size: 0, viewport: 490.7, lowestRow: -.infinity)
        XCTAssertFalse(blank.showsARow, "62 loaded items and zero visible rows is the defect, not a pass")
        XCTAssertFalse(blank.bottomRowOnScreen)
    }

    /// The second measured stuck shape (launch 4 of the fix verification, before the attach fix): the
    /// **content** is at its end (`fromBottom == 0`) and exactly one row is laid out, its bottom 15 pt
    /// below the viewport's top edge — 475 pt of blank pane under it. `fromBottom` alone would call this
    /// "at the bottom", which is why the claim is row-based.
    func testOneRowAtTheTopEdgeDoesNotCountAsTheNewestRowOnScreen() {
        let sliver = sample(items: 62, rows: 1, visible: 1,
                            offset: 2_618.3, size: 2_636, viewport: 490.7, lowestRow: 15,
                            fromBottom: 0)
        XCTAssertTrue(sliver.showsARow, "one laid-out row does intersect the viewport")
        XCTAssertFalse(sliver.bottomRowOnScreen,
                       "a row ending 15 pt below the viewport's top edge leaves 475 pt of pane blank")
    }

    /// A correctly placed pane: ten rows on screen, the lowest reaching the viewport's bottom edge (the
    /// list's 12 pt bottom padding is inside the content, so the tolerance is 20 pt).
    func testAPaneAtItsNewestRowHasARowAtTheViewportBottom() {
        let placed = sample(items: 62, rows: 10, visible: 10,
                            offset: 2_805.3, size: 3_296, viewport: 490.7, lowestRow: 490.67,
                            fromBottom: 0)
        XCTAssertTrue(placed.showsARow)
        XCTAssertTrue(placed.bottomRowOnScreen)
    }

    /// The offset must sit inside `[-insetTop, content + insetBottom − viewport]`. One measured stuck
    /// shape had the viewport starting 466 pt below the last row it had laid out (`offset = size − 23.7`,
    /// resolved against a ~24 pt viewport), i.e. outside the content the layout actually built.
    func testAnOffsetPastTheEndOfTheContentIsNotInsideIt() {
        let pastTheEnd = sample(items: 62, offset: 2_618.3, size: 2_636, viewport: 490.7)
        XCTAssertFalse(pastTheEnd.offsetInsideContent,
                       "2 618 > 2 636 − 490.7: the viewport starts below every real row")
        let atTheEstimate = sample(items: 62, offset: 2_681.3, size: 3_172, viewport: 490.7)
        XCTAssertTrue(atTheEstimate.offsetInsideContent,
                      "inside the content the lazy stack *believes* it has — which is exactly why an "
                      + "offset check alone cannot catch this defect, and the row check is needed")
    }

    /// A viewport that is not laid out yet (a restored pane during the launch push) reports
    /// `attached=false, viewport=0`; no claim may pass on that.
    func testADetachedListSatisfiesNeitherClaim() {
        let detached = ChannelScrollGeometrySample(attached: false, offsetY: 0, contentHeight: 0,
                                                   viewportHeight: 0, insetTop: 0, insetBottom: 0,
                                                   laidOutRows: 0, visibleRows: 0, topRowID: nil,
                                                   topRowOffset: .infinity,
                                                   lowestRowBottom: -.infinity,
                                                   distanceFromBottom: 0, itemCount: 62,
                                                   fitsViewport: false)
        XCTAssertFalse(detached.showsARow)
        XCTAssertFalse(detached.bottomRowOnScreen)
        XCTAssertFalse(detached.offsetInsideContent)
    }
}
