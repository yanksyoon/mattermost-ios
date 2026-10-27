// T34 — the restore **path**, pinned against a fake scroll surface (task t_a4d02070).
//
// Why this file exists: the live suite's anchor test asserts the user-visible property — the anchored
// row keeps its y across a page insert — and QA measured that this still passes on this host when the
// restore is deleted from the list outright (`docs/t34qa-build-note.md` §8, mutation A; the run that
// jumped the pane on purpose, mutation B, fails as it must). So the live oracle does not isolate
// `restoreReader`, and a regression *inside* it would be invisible.
//
// `ScrollRestoreRunner` is the loop, lifted out of the view. These tests drive it with a fake surface
// that simulates the page insert, so the three properties that matter are decided in milliseconds
// instead of an 80 s simulator run:
//
//   1. the correction is applied, with the right sign and magnitude (a merged page moves the anchor
//      down by its own height; the content has to move up by exactly that);
//   2. it is applied **once** — the loop is a closed system, and a second application is the T34-R4
//      defect that moved the reader 585 pt;
//   3. a row the lazy stack dropped is brought back through `scrollTo` and then corrected.
//
// The wiring — that the view actually calls the runner for a pending anchor — is
// `T34ChannelViewRestoreWiringTests`, because no unit test of the loop can prove its own caller.

import XCTest
@testable import Mattermost

@MainActor
final class T34ScrollRestorePathTests: XCTestCase {

    // MARK: - The page insert

    /// The case the loop exists for: the reader was 42 pt into a post, an older page of 1,000 pt was
    /// prepended above it, so the post now sits 1,042 pt down and the content has to move up by 1,000.
    func testTheCorrectionPutsTheAnchorBackAndReportsIt() async {
        let surface = FakeScrollSurface(contentHeight: 2_000, rowOffset: 1_042)
        let report = await ScrollRestoreRunner.run(
            anchor: .init(postID: "p42", offsetFromTop: 42),
            baselineContentHeight: 1_000,      // the height the anchor was captured against
            surface: surface.surface,
            pause: {})

        XCTAssertEqual(report.outcome, .settled)
        XCTAssertEqual(report.corrections, 1, "one correction, not one per frame")
        XCTAssertEqual(report.appliedPoints, 1_000, accuracy: 0.001,
                       "content moves up by exactly the page height")
        XCTAssertEqual(report.firstResidual ?? .nan, 1_000, accuracy: 0.001,
                       "the first measurement is the whole displacement — the run is evidence of it")
        XCTAssertEqual(report.finalResidual ?? .nan, 0, accuracy: 0.001)
        XCTAssertEqual(surface.scrolls, [1_000], "the scroll view saw exactly one move")
        XCTAssertEqual(surface.rowOffset, 42, "the reader is back on the same pixels")
    }

    /// The view's own numbers: three settled observations are required before the loop is done, so a
    /// restore that "looks right" for one frame is not called finished.
    func testTheRestoreIsNotDoneUntilTheLayoutHasSettled() async {
        let surface = FakeScrollSurface(contentHeight: 2_000, rowOffset: 1_042)
        let report = await ScrollRestoreRunner.run(
            anchor: .init(postID: "a", offsetFromTop: 42),
            baselineContentHeight: 1_000,
            surface: surface.surface,
            pause: {})

        XCTAssertGreaterThanOrEqual(report.measurements, ScrollRestoreRunner.settledRunsRequired + 1,
                                    "1 measuring frame that corrects + 3 settled frames")
    }

    /// A negative control: the OS kept the anchor (the iOS 18+ anchoring QA suspected). The loop must
    /// say so — zero corrections, settled — instead of inventing a move or spinning.
    func testAnAnchorThatNeverMovedIsSettledWithoutCorrections() async {
        let surface = FakeScrollSurface(contentHeight: 2_000, rowOffset: 42)
        let report = await ScrollRestoreRunner.run(
            anchor: .init(postID: "a", offsetFromTop: 42),
            baselineContentHeight: 1_000,
            surface: surface.surface,
            pause: {})

        XCTAssertEqual(report.outcome, .settled)
        XCTAssertEqual(report.corrections, 0)
        XCTAssertTrue(surface.scrolls.isEmpty)
        XCTAssertEqual(report.firstResidual ?? .nan, 0, accuracy: 0.001,
                       "the report states the residual plainly; it does not claim work it did not do")
    }

    /// A correction the scroll view will not take (the content is already at its end, or the controller
    /// has not attached yet) must not be counted as applied: `corrections` is what distinguishes "the
    /// restore worked" from "the restore asked". The loop keeps trying within its budget and then says
    /// the layout never settled.
    func testAScrollTheViewRefusesIsNeverCountedAsACorrection() async {
        let surface = FakeScrollSurface(contentHeight: 2_000, rowOffset: 1_042)
        surface.refusesScrolls = true

        let report = await ScrollRestoreRunner.run(
            anchor: .init(postID: "a", offsetFromTop: 42),
            baselineContentHeight: 1_000,
            surface: surface.surface,
            pause: {})

        XCTAssertEqual(report.corrections, 0)
        XCTAssertEqual(report.appliedPoints, 0)
        XCTAssertTrue(surface.scrolls.isEmpty)
        XCTAssertEqual(report.firstResidual ?? .nan, 1_000, accuracy: 0.001)
        XCTAssertEqual(report.outcome, .exhausted)
    }

    // MARK: - The row the lazy stack dropped

    /// A page inserted above the reader can push the anchored row far enough away that `LazyVStack`
    /// dismantles it. Then there is nothing to measure, and the loop asks SwiftUI to bring the row back
    /// and corrects the residual from there — it must not give up, and it must not report a measurement
    /// it never took.
    func testARowThatIsNotLaidOutIsScrolledIntoViewThenCorrected() async {
        let surface = FakeScrollSurface(contentHeight: 2_000, rowOffset: 1_042)
        surface.nilReadsBeforeTheRowAppears = 3

        let report = await ScrollRestoreRunner.run(
            anchor: .init(postID: "a", offsetFromTop: 42),
            baselineContentHeight: 1_000,
            surface: surface.surface,
            pause: {})

        XCTAssertGreaterThanOrEqual(surface.rowIntoViewRequests, 1,
                                    "the view must ask SwiftUI for the row it cannot measure")
        XCTAssertEqual(report.corrections, 1)
        XCTAssertEqual(report.appliedPoints, 1_000, accuracy: 0.001)
        XCTAssertEqual(report.outcome, .settled)
        XCTAssertGreaterThan(report.measurements, 0)
    }

    /// A row that never comes back is reported as such — the reader is displaced, and the report says
    /// so instead of pretending the restore worked. The caller still consumes the anchor, so one bad
    /// restore cannot block every later one (`pendingScrollRestore` also gates paging).
    func testARowThatNeverLaysOutIsReportedAndTheBudgetIsBounded() async {
        let surface = FakeScrollSurface(contentHeight: 2_000, rowOffset: nil)
        let report = await ScrollRestoreRunner.run(
            anchor: .init(postID: "a", offsetFromTop: 42),
            baselineContentHeight: 1_000,
            surface: surface.surface,
            pause: {})

        XCTAssertEqual(report.outcome, .rowNeverLaidOut)
        XCTAssertEqual(report.measurements, 0)
        XCTAssertEqual(report.frames, ScrollRestoreRunner.frameBudget)
        XCTAssertGreaterThanOrEqual(surface.rowIntoViewRequests, ScrollRestoreRunner.frameBudget)
        XCTAssertNil(report.firstResidual)
        XCTAssertTrue(report.summary.contains("outcome=rowNeverLaidOut"), report.summary)
    }

    // MARK: - Refusals

    /// A non-finite measurement (a row mid-animation, a NaN out of a conversion) must never become a
    /// scroll. `ScrollRestorePlan` treats it as a no-op, so the loop settles claiming no correction was
    /// needed — the pin here is only that no move is invented from garbage.
    func testANonFiniteMeasurementNeverBecomesAScroll() async {
        let surface = FakeScrollSurface(contentHeight: 2_000, rowOffset: .nan)
        let report = await ScrollRestoreRunner.run(
            anchor: .init(postID: "a", offsetFromTop: 42),
            baselineContentHeight: 1_000,
            surface: surface.surface,
            pause: {})

        XCTAssertTrue(surface.scrolls.isEmpty)
        XCTAssertEqual(report.corrections, 0)
        XCTAssertEqual(report.appliedPoints, 0)
    }

    /// The loop is bounded: a list that never stops moving costs one budget, not the run.
    func testAMovingListExhaustsTheBudgetInsteadOfSpinning() async {
        let surface = FakeScrollSurface(contentHeight: 2_000, rowOffset: 1_042)
        surface.contentHeightDriftPerRead = 40     // the content keeps growing under the reader

        let report = await ScrollRestoreRunner.run(
            anchor: .init(postID: "a", offsetFromTop: 42),
            baselineContentHeight: 1_000,
            surface: surface.surface,
            pause: {})

        XCTAssertEqual(report.outcome, .exhausted)
        XCTAssertEqual(report.frames, ScrollRestoreRunner.frameBudget)
        XCTAssertEqual(report.firstResidual ?? .nan, 1_000, accuracy: 0.001)
    }

    /// The report is the live seam's whole payload: it has to name the post and the outcome in one line.
    func testTheReportSummaryNamesThePostAndTheOutcome() async {
        let surface = FakeScrollSurface(contentHeight: 2_000, rowOffset: 1_042)
        let report = await ScrollRestoreRunner.run(
            anchor: .init(postID: "post.abc", offsetFromTop: 42),
            baselineContentHeight: 1_000,
            surface: surface.surface,
            pause: {})

        XCTAssertTrue(report.summary.hasPrefix("restore post.post.abc outcome=settled"),
                      report.summary)
        XCTAssertTrue(report.summary.contains("corrections=1"), report.summary)
        XCTAssertTrue(report.summary.contains("firstResidual=1000.0"), report.summary)
    }
}

/// A scroll surface with no scroll view: content height, the anchor's distance from the top, and the
/// moves it was asked to make — enough to stand in for a page insert.
///
/// `rowOffset` is the distance from the viewport's top edge to the anchor, so it is what
/// `convert(_:to:)` answers in the real controller; a scroll of `delta` points moves the row **up** the
/// screen by `delta`.
@MainActor
final class FakeScrollSurface {
    private(set) var contentHeight: CGFloat
    private(set) var rowOffset: CGFloat?
    private(set) var scrolls: [CGFloat] = []
    private(set) var rowIntoViewRequests = 0

    /// Reads that answer `nil` (the row is not in the lazy stack's window) before it becomes visible.
    var nilReadsBeforeTheRowAppears = 0
    /// Extra content height added on every read, for the never-settling case.
    var contentHeightDriftPerRead: CGFloat = 0
    /// A scroll view that will not move (detached, or clamped at the end of the content).
    var refusesScrolls = false

    init(contentHeight: CGFloat, rowOffset: CGFloat?) {
        self.contentHeight = contentHeight
        self.rowOffset = rowOffset
    }

    var surface: ScrollRestoreSurface {
        ScrollRestoreSurface(
            contentHeight: { [self] in
                let value = contentHeight
                contentHeight += contentHeightDriftPerRead
                return value
            },
            offsetFromTop: { [self] _ in
                if nilReadsBeforeTheRowAppears > 0 {
                    nilReadsBeforeTheRowAppears -= 1
                    return nil
                }
                return rowOffset
            },
            scrollBy: { [self] delta in
                guard !refusesScrolls, delta.isFinite, abs(delta) > 0.01,
                      let current = rowOffset, current.isFinite else { return false }
                scrolls.append(delta)
                rowOffset = current - delta
                return true
            },
            scrollRowIntoView: { [self] _ in rowIntoViewRequests += 1 })
    }
}
