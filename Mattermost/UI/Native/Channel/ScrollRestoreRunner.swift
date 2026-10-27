// T34 — the reader-restore loop, lifted out of the view so it can be pinned.
//
// Why this type exists (task t_a4d02070): the live UI test
// (`T34-ChannelPostListUITests.testLoadingOlderPostsDoesNotMoveTheAnchoredPost`) asserts the
// **user-visible** property — "the anchored row keeps its y across a page insert" — and QA measured
// that this still holds on this host with the restore call deleted from `ChannelPostListView`
// (`docs/t34qa-build-note.md` §8, mutation A). So the live suite cannot see a regression *inside*
// the restore, and a green suite does not mean "the restore works".
//
// The loop therefore lives here, in a form two things can drive:
//   * the view (`ChannelPostListView.restoreReader`), against the real scroll view; and
//   * `T34ScrollRestorePathTests`, against a fake surface that simulates the page insert, so the
//     correction's sign, its single application and the un-laid-out fallback are pinned by a fast
//     test instead of an 80 s simulator run;
// and every run ends with a `ScrollRestoreReport`, published on the view model. That report is the
// second pin: the live anchor test now also reads it through the `-uiTestExposeLoadEarlier` seam, so
// deleting the restore call fails something (no report, and the anchor is never consumed) even on a
// host where the OS keeps the anchored row where it was.
//
// Behaviour is unchanged from the version that shipped in `ChannelPostListView.restoreReader`
// (T34-R4): measure the row from its own `UIView`, correct the residual through the scroll view's
// point offset, and only call the restore "done" once the content has been re-laid-out **and
// settled** for three consecutive observations. The one addition is bookkeeping.

import CoreGraphics
import Foundation

/// The scroll view as the restore loop needs it, in the four operations it uses.
///
/// A struct of closures rather than a protocol over `ChannelScrollController`, because two of the
/// four are not the controller's to answer: the un-laid-out fallback goes through SwiftUI's
/// `ScrollViewProxy`, which only the view holds. With this seam the loop can be driven by a fake in a
/// unit test with no scroll view, no SwiftUI and no waiting.
struct ScrollRestoreSurface {
    /// The height UIKit currently believes the content has — how the loop tells "the inserted page has
    /// been laid out" apart from "nothing has moved yet" (both look like a zero correction).
    var contentHeight: () -> CGFloat
    /// Distance from the viewport's top edge to the row's top edge, `nil` when the row is not laid out.
    var offsetFromTop: (String) -> CGFloat?
    /// Move the content by `delta` points. Returns whether it actually moved.
    var scrollBy: (CGFloat) -> Bool
    /// Bring a row that is no longer laid out back into view (SwiftUI's own `scrollTo`).
    var scrollRowIntoView: (String) -> Void
}

/// What one restore did. Published so a test — unit, hosting, or live — can assert that the restore
/// **ran** rather than inferring it from where the list happens to be.
struct ScrollRestoreReport: Equatable {
    enum Outcome: String, Equatable {
        /// The content was re-laid-out, settled, and the anchor sat where it was recorded.
        case settled
        /// The budget ran out with the anchor still moving or the content never settling.
        case exhausted
        /// The row never laid out, so nothing was ever measured (a diagnostic, not a crash).
        case rowNeverLaidOut
    }

    var postID: String
    var recordedOffsetFromTop: CGFloat
    var baselineContentHeight: CGFloat
    /// Loop iterations spent (each one waits a frame).
    var frames: Int
    /// How many of those iterations found the row laid out.
    var measurements: Int
    /// Corrections actually applied to the scroll view (a non-zero adjustment that moved it).
    var corrections: Int
    /// Net points applied. Positive = content moved up towards newer posts.
    var appliedPoints: CGFloat
    /// The first measured residual — **evidence about the OS**, not an assertion: ~0 means the anchor
    /// had already been preserved when the restore first looked (iOS 18+ `defaultScrollAnchor`), a page
    /// height means our correction did the work.
    var firstResidual: CGFloat?
    /// The last measured residual.
    var finalResidual: CGFloat?
    var outcome: Outcome

    /// One line, for the launch-argument seam's accessibility value and for failure messages.
    var summary: String {
        func points(_ value: CGFloat?) -> String {
            guard let value else { return "none" }
            return String(format: "%.1f", value)
        }
        return "restore post.\(postID) outcome=\(outcome.rawValue) frames=\(frames) "
            + "measurements=\(measurements) corrections=\(corrections) "
            + "applied=\(points(appliedPoints)) firstResidual=\(points(firstResidual)) "
            + "finalResidual=\(points(finalResidual))"
    }
}

/// The restore loop: measure, correct the residual, measure again until the layout has settled.
enum ScrollRestoreRunner {
    /// ~1.2 s of frames at 16 ms. The insert lays out in a frame or two; the budget is the bound on
    /// "the app never settles" rather than an expectation.
    static let frameBudget = 75
    /// Consecutive settled observations required before the restore is called done.
    static let settledRunsRequired = 3

    /// Timing seam: the loop's only side channel is waiting a frame.
    static let framePause: @MainActor () async -> Void = {
        try? await Task.sleep(for: .milliseconds(16))
    }

    /// Put `anchor` back where the reader left it.
    ///
    /// The older page was inserted *above* the anchor, so the anchor moved down by the height of that
    /// page; scrolling the content up by exactly that difference leaves the reader looking at the same
    /// pixels. Every number is measured at the moment it is read, so the loop is a closed control
    /// system: a correction cannot be applied twice, because the next measurement *contains* it and
    /// reads ~0 if it was right (T34-R4: the previous, half-SwiftUI-preference version reapplied the
    /// move and the live test measured the row 585 pt away).
    @MainActor
    static func run(anchor: ChannelViewModel.ScrollAnchor,
                    baselineContentHeight: CGFloat,
                    surface: ScrollRestoreSurface,
                    pause: @MainActor () async -> Void = framePause) async -> ScrollRestoreReport {
        var report = ScrollRestoreReport(postID: anchor.postID,
                                         recordedOffsetFromTop: anchor.offsetFromTop,
                                         baselineContentHeight: baselineContentHeight,
                                         frames: 0,
                                         measurements: 0,
                                         corrections: 0,
                                         appliedPoints: 0,
                                         firstResidual: nil,
                                         finalResidual: nil,
                                         outcome: .exhausted)
        var unchangedRuns = 0
        var previousHeight = surface.contentHeight()

        /// Measure, record and apply one correction. `nil` when the row was not laid out.
        func correctIfNeeded() -> CGFloat? {
            guard let measured = surface.offsetFromTop(anchor.postID) else { return nil }
            report.measurements += 1
            let adjustment = ScrollRestorePlan.adjustment(recordedOffsetFromTop: anchor.offsetFromTop,
                                                          currentOffsetFromTop: measured)
            if report.firstResidual == nil { report.firstResidual = adjustment }
            report.finalResidual = adjustment
            if !ScrollRestorePlan.isNoOp(adjustment), surface.scrollBy(adjustment) {
                report.corrections += 1
                report.appliedPoints += adjustment
            }
            return adjustment
        }

        for _ in 0..<frameBudget {
            report.frames += 1
            await pause()
            // A layout that has not run yet still reports the *old* positions, which read as "no
            // correction needed". Content height is what tells the two apart, so an early exit needs
            // both: the content has been re-laid-out **and settled**, and the anchor is where it
            // belongs.
            let height = surface.contentHeight()
            let laidOut = abs(height - baselineContentHeight) > 1 && abs(height - previousHeight) <= 1
            previousHeight = height

            if let adjustment = correctIfNeeded() {
                if ScrollRestorePlan.isNoOp(adjustment) {
                    unchangedRuns = laidOut ? unchangedRuns + 1 : 0
                    if unchangedRuns >= settledRunsRequired {
                        report.outcome = .settled
                        return report
                    }
                } else {
                    unchangedRuns = 0
                }
                continue
            }

            // Not laid out: bring it back with SwiftUI's own scroll-to, then put the recorded distance
            // back above it with a point offset.
            unchangedRuns = 0
            surface.scrollRowIntoView(anchor.postID)
            await pause()
            _ = correctIfNeeded()
        }

        report.outcome = report.measurements == 0 ? .rowNeverLaidOut : .exhausted
        return report
    }
}
