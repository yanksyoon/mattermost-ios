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
// inside the content, so this is a small, fail-soft bridge: when it cannot find the scroll view the
// caller falls back to `scrollTo(anchor: .top)` and the reader loses at most a sub-row offset.

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
    /// edge** (`rows` are the preference values, which SwiftUI reports in the scroll content's
    /// coordinate space, so the offset has to be subtracted first).
    ///
    /// Rows scrolled past the edge (negative distance, within a point of tolerance) are ignored, and if
    /// every row is above the edge — an over-scroll — the nearest one is still the honest answer.
    static func topVisible(rows: [String: CGFloat],
                           contentOffsetY: CGFloat) -> (id: String, offsetFromTop: CGFloat)? {
        var candidates: [(id: String, distance: CGFloat)] = []
        for (id, position) in rows where position.isFinite {
            candidates.append((id: id, distance: position - contentOffsetY))
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

/// A handle on the list's scroll view, attached from inside the content.
@MainActor
final class ChannelScrollController: ObservableObject {
    fileprivate weak var scrollView: UIScrollView?

    /// Whether the bridge found a scroll view (diagnostics and the fallback decision).
    var isAttached: Bool { scrollView != nil }
    /// The current vertical content offset, in points.
    var offsetY: CGFloat { scrollView?.contentOffset.y ?? 0 }
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
