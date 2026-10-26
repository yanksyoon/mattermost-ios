// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/channel/channel_post_list/channel_post_list.tsx (`onViewableItemsChanged` +
//        `scrollToIndex`, and the `maintainVisibleContentPosition` behaviour `inverted` FlatList
//        gets from its data plumbing), app/utils/post_list/index.ts.
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §10; no
// upstream source copied. This file is this repo's own bridge (component-map.md §1) — upstream's
// list is a virtualised FlatList, SwiftUI's is a `ScrollView`.
//
// Why a point offset and not just a row:
// the reader's place is a *post plus how far they had scrolled into it*. `ScrollViewReader`'s
// `scrollTo(_:anchor:)` can only align a row to an edge of the viewport, so restoring with
// `.top` moves the content by up to one row height whenever the reader was part-way through a post
// (T34 review F5 — the captured offset was recorded and never read). `UIScrollView` has the primitive
// SwiftUI lacks on iOS 17 (`contentOffset`), and the enclosing scroll view is reachable from a view
// inside the content, so this is a small, fail-soft bridge.
//
// Why the measurement comes from UIKit and not from a SwiftUI preference (T34-R4):
// the R3 bridge fed the restore a `GeometryReader` preference — a row position in the scroll
// *content*'s coordinate space, republished whenever SwiftUI decided something had moved. Combining a
// frame from one layout pass with a `contentOffset` read a moment later produced corrections that were
// applied from a stale pair, and the live anchor test (`testLoadingOlderPostsDoesNotMoveTheAnchoredPost`)
// measured the anchored row 585 pt away from where it had been. A row's own `UIView` is the ground
// truth: `convert(_:to:)` through the scroll view answers "how far below the viewport's top edge is this
// row *right now*" synchronously, with no layout-pass bookkeeping, and correcting against it is a
// closed loop that cannot apply the same move twice (each correction is computed from a measurement
// taken after the previous one).

import SwiftUI
import UIKit

/// The arithmetic of the restore, separated from the lookups so a unit test can pin it.
enum ScrollRestorePlan {
    /// Points to move the content by so a post returns to the distance from the top it had before
    /// an older page was prepended. Positive = content moves up (towards newer posts).
    ///
    /// Both arguments are **distances below the viewport's top edge**, not raw positions inside the
    /// scroll content: a content-space value keeps growing as pages are prepended, so comparing two of
    /// them would compare a position against a position taken in a different layout (T34-R3: the live
    /// anchor test measured a 585 pt jump because the anchor was the first row of the window, not the
    /// row the reader was looking at).
    static func adjustment(recordedOffsetFromTop: CGFloat, currentOffsetFromTop: CGFloat) -> CGFloat {
        guard recordedOffsetFromTop.isFinite, currentOffsetFromTop.isFinite else { return 0 }
        return currentOffsetFromTop - recordedOffsetFromTop
    }

    /// Below this the sub-pixel difference is not worth a scroll (and `setContentOffset` on a value
    /// that differs only by rounding can fight SwiftUI's own layout pass).
    static let tolerance: CGFloat = 0.5

    static func isNoOp(_ adjustment: CGFloat) -> Bool {
        !adjustment.isFinite || abs(adjustment) < tolerance
    }

    /// The row the reader is looking at: the one with the smallest **distance below the viewport's top
    /// edge** (`rows` already holds those distances — see `ChannelScrollController.offsetFromTop`).
    ///
    /// Rows scrolled past the edge (negative distance, within a point of tolerance) are ignored, and if
    /// every row is above the edge — an over-scroll — the nearest one is still the honest answer.
    static func topVisible(rows: [String: CGFloat]) -> (id: String, offsetFromTop: CGFloat)? {
        var candidates: [(id: String, distance: CGFloat)] = []
        for (id, distance) in rows where distance.isFinite {
            candidates.append((id: id, distance: distance))
        }
        candidates.sort { lhs, rhs in
            lhs.distance == rhs.distance ? lhs.id < rhs.id : lhs.distance < rhs.distance
        }
        for candidate in candidates where candidate.distance >= -tolerance {
            return (candidate.id, candidate.distance)
        }
        var nearest: (id: String, distance: CGFloat)?
        for candidate in candidates {
            if nearest == nil || abs(candidate.distance) < abs(nearest!.distance) {
                nearest = candidate
            }
        }
        return nearest.map { (id: $0.id, offsetFromTop: $0.distance) }
    }
}

/// A handle on the list's scroll view, attached from inside the content, plus the registry of the
/// rows it currently has laid out.
@MainActor
final class ChannelScrollController: ObservableObject {
    fileprivate weak var scrollView: UIScrollView?

    /// Where the reader was when the anchor was last taken. `contentHeight` is the scroll content's
    /// height at that moment, which is how a restore tells "the inserted page has been laid out" apart
    /// from "nothing has moved yet" (both look like a zero correction).
    struct ReaderPlace: Equatable {
        var postID: String
        var offsetFromTop: CGFloat
        var contentHeight: CGFloat
    }

    private(set) var lastPlace: ReaderPlace?

    /// Rows that are currently laid out, keyed by post id. Weak, because SwiftUI dismantles a row's
    /// view when the lazy list lets go of it, and a released view must not be read as a position.
    private var rowViews: [String: WeakRowView] = [:]

    private struct WeakRowView {
        weak var view: UIView?
    }

    /// Whether the bridge found a scroll view (diagnostics and the fallback decision).
    var isAttached: Bool { scrollView != nil }
    /// The current vertical content offset, in points.
    var offsetY: CGFloat { scrollView?.contentOffset.y ?? 0 }
    /// The height UIKit currently believes the content has, in points.
    var contentHeight: CGFloat { scrollView?.contentSize.height ?? 0 }
    /// How far the bottom edge of the content still is, in points (0 when the reader is at the end).
    var distanceFromBottom: CGFloat {
        guard let scrollView else { return 0 }
        let inset = scrollView.adjustedContentInset
        let visibleBottom = scrollView.contentOffset.y + scrollView.bounds.height
        return max(0, scrollView.contentSize.height + inset.bottom - visibleBottom)
    }
    /// How far the top edge of the content still is, in points (0 when the reader is at the top).
    var distanceFromTop: CGFloat {
        guard let scrollView else { return 0 }
        return max(0, scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
    }

    /// True when the content fits inside the viewport, so there is nothing to scroll: a window shorter
    /// than a screen is both "at the top" and "at the bottom", and the pane should fill itself.
    var contentFitsViewport: Bool {
        guard let scrollView else { return false }
        let inset = scrollView.adjustedContentInset
        return scrollView.contentSize.height + inset.top + inset.bottom <= scrollView.bounds.height + 1
    }

    /// True while the reader is touching this scroll view or it is still coasting. Our own
    /// programmatic scrolls (the paging restore) are neither, which is what keeps a merge from looking
    /// like a reader request for another page.
    var isUserScrolling: Bool {
        guard let scrollView else { return false }
        return scrollView.isDragging || scrollView.isDecelerating || scrollView.isTracking
    }

    /// `distanceFromBottom` under a point, to absorb sub-pixel layout noise.
    var isAtBottom: Bool { distanceFromBottom <= 1 }

    fileprivate func attach(_ view: UIScrollView?) {
        if let view { scrollView = view }
    }

    // MARK: Rows

    /// Called by every laid-out post row. Re-registering is the common case (SwiftUI updates the
    /// representable as the row re-renders); a dismantled row simply stops resolving.
    func registerRow(_ view: UIView, postID: String) {
        guard !postID.isEmpty else { return }
        rowViews[postID] = WeakRowView(view: view)
    }

    /// Distance, in points, from the viewport's **top edge** to the row's top edge — measured from the
    /// row's own view, so it is true at the instant it is read.
    ///
    /// `nil` when the row is not laid out (a lazy list drops rows that are far off screen), which is
    /// not an error: the caller asks SwiftUI to bring it back into view and measures again.
    func offsetFromTop(ofRow postID: String) -> CGFloat? {
        guard let scrollView, let view = rowViews[postID]?.view,
              view.isDescendant(of: scrollView), view.bounds.height > 0 else { return nil }
        let rect = view.convert(view.bounds, to: scrollView)
        return rect.minY - scrollView.bounds.origin.y
    }

    /// Every laid-out row, by distance below the viewport's top edge.
    private func laidOutRows() -> [String: CGFloat] {
        var rows: [String: CGFloat] = [:]
        for (postID, box) in rowViews {
            guard let view = box.view else {
                rowViews.removeValue(forKey: postID)
                continue
            }
            guard let scrollView, view.isDescendant(of: scrollView), view.bounds.height > 0 else {
                if box.view == nil { rowViews.removeValue(forKey: postID) }
                continue
            }
            let rect = view.convert(view.bounds, to: scrollView)
            rows[postID] = rect.minY - scrollView.bounds.origin.y
        }
        return rows
    }

    /// The reader's place: the top visible post, how far below the viewport edge it sits, and the
    /// content height it was measured against. Recorded so both the periodic anchor and the
    /// `loadEarlier()` hand-off use one snapshot rather than two reads of a moving list.
    @discardableResult
    func captureReaderPlace() -> ReaderPlace? {
        guard let visible = ScrollRestorePlan.topVisible(rows: laidOutRows()) else { return nil }
        let place = ReaderPlace(postID: visible.id,
                                offsetFromTop: visible.offsetFromTop,
                                contentHeight: contentHeight)
        lastPlace = place
        return place
    }

    // MARK: Scrolling

    /// Snap to the bottom of the content. Used to open a conversation on its newest message *after*
    /// the rows have real heights: `LazyVStack` measures lazily, so a single `scrollTo` issued when
    /// the first page lands is computed from estimated heights and can stop short.
    @discardableResult
    func scrollToBottom() -> Bool {
        guard let scrollView else { return false }
        let inset = scrollView.adjustedContentInset
        let target = max(-inset.top,
                         scrollView.contentSize.height + inset.bottom - scrollView.bounds.height)
        guard abs(target - scrollView.contentOffset.y) > 0.01 else { return false }
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: target), animated: false)
        return true
    }

    /// Move the content by `delta` points without animation. Returns whether it actually moved.
    @discardableResult
    func scroll(by delta: CGFloat) -> Bool {
        guard let scrollView, delta.isFinite, !ScrollRestorePlan.isNoOp(delta) else { return false }
        let inset = scrollView.adjustedContentInset
        let minimum = -inset.top
        let maximum = max(minimum,
                          scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
        let target = min(max(scrollView.contentOffset.y + delta, minimum), maximum)
        guard abs(target - scrollView.contentOffset.y) > 0.01 else { return false }
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: target), animated: false)
        return true
    }
}

/// Zero-sized view that finds the `UIScrollView` hosting this SwiftUI `ScrollView` and hands it to a
/// `ChannelScrollController`. Place it inside the scroll content.
struct ScrollViewResolver: UIViewRepresentable {
    let controller: ChannelScrollController

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        // The view is only in the hierarchy once the scroll view exists, and the scroll view can be
        // replaced on a re-mount (a channel switch rebuilds the pane), so resolve on the next turn
        // and again whenever SwiftUI updates this representable.
        DispatchQueue.main.async { controller.attach(view.enclosingScrollView) }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if !controller.isAttached {
            controller.attach(uiView.enclosingScrollView)
        }
    }
}

/// Registers a post row's own view with the scroll controller, so its position can be measured without
/// going through a SwiftUI preference (see the file comment).
struct RowAnchorProbe: UIViewRepresentable {
    let postID: String
    let controller: ChannelScrollController

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        controller.registerRow(view, postID: postID)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        controller.registerRow(uiView, postID: postID)
    }
}

private extension UIView {
    var enclosingScrollView: UIScrollView? {
        var current: UIView? = superview
        while let view = current {
            if let scrollView = view as? UIScrollView { return scrollView }
            current = view.superview
        }
        return nil
    }
}
