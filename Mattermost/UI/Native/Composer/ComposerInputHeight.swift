// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0
// (162f2560d0e1df073220f7701d5a67cc17c8abeb), app/components/post_draft/post_input/post_input.tsx:171
//
//     const maxHeight = isTablet ? 150 : 88;
//     const pasteInputStyle = useMemo(() => ({...style.input, maxHeight}), ...)
//
// …and the same file at :388 renders that style on a `multiline={true}` TextInput. Upstream therefore
// has exactly one growing input with a ceiling: the field grows with its content up to `maxHeight`
// and scrolls internally past it. It never declares a height and never turns a scroller off — the
// two things the iOS composer did (kanban t_fbc576a2).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §12; no
// upstream source copied.

import SwiftUI
import UIKit

/// How tall the composer's text input is, and when it scrolls.
///
/// One rule, two numbers, no state: the input's height is **measured** from its own text, clamped to
/// `minimum...cap`, and the internal scroller is on exactly while the measured content is taller than
/// the cap. Everything else (the view, the tests, the note) reads these two values rather than
/// repeating 34/56/150/220 around the codebase.
///
/// The numbers:
///
///  * `cap = 88` on a phone and `150` on a tablet are upstream's own two ceilings
///    (`post_input.tsx:171`: `const maxHeight = isTablet ? 150 : 88`). A phone-width field (402 pt)
///    fits about four `body` lines in 88 pt; a tablet-width field fits six in 150.
///  * `cap = 150` is also what this shell uses for the **Mac window**, and that is the card's choice,
///    not upstream's (upstream has no Mac value). A Mac Catalyst window reports `UIUserInterfaceIdiom.pad`
///    — Catalyst presents a tablet interface, and this shell is otherwise identical code on iPad — so
///    the tablet ceiling is the one the window already inherits, and 150 pt of a 900 pt-wide window is
///    still six lines. 88 was *not* chosen for it: a Mac window would hit 88 after four lines and start
///    scrolling while two thirds of the composer is empty. Because the choice is made from the idiom
///    and not from the window width, a *narrow* Mac window keeps 150 too — a window that is dragged
///    narrow does not suddenly become a phone.
///  * `cap = 220` at accessibility text sizes keeps the ceiling this composer already had. It is not
///    an upstream number: upstream's `maxHeight` is in dp and its input relies on `allowFontScaling`
///    growing the *text* inside a fixed box, while this shell's Dynamic Type pass had already raised
///    both the floor (56) and the ceiling (220) so an AX3 line (~40 pt) does not sit in a 34 pt box
///    (T45, `ComposerView.typeSize`). 220 holds ~5 AX3 lines; 150 would hold under four.
///  * `minimum` 34 / 56: unchanged from the frame this replaces. Below the cap the *measured* content
///    decides the height; the minimum only keeps a one-line field from being shorter than its
///    placeholder and the row's 26 pt glyph buttons.
enum ComposerInputHeight {

    /// The sizes the composer uses for one Dynamic Type class.
    struct Limits: Equatable {
        let minimum: CGFloat
        let cap: CGFloat

        /// 34/88 — upstream's phone ceiling (`isTablet == false`).
        static let phone = Limits(minimum: 34, cap: 88)
        /// 34/150 — upstream's tablet ceiling, and the Mac window's (see the type's comment).
        static let tablet = Limits(minimum: 34, cap: 150)
        /// 56/220 — the accessibility text sizes, keeping T45's floor and ceiling.
        static let accessibility = Limits(minimum: 56, cap: 220)
    }

    /// Which of upstream's two layouts the field is in. `isTablet` in the pinned release.
    enum DeviceClass: Equatable {
        case phone
        case tablet
    }

    /// The class a view belongs to, from the platform rather than from a width.
    ///
    /// Width was the tempting oracle — "88 is a 402 pt field's ceiling" — but a resized window would
    /// then change the *input policy*, and the card asks for window resizing to re-*measure* at the
    /// same cap. `isMacCatalyst` is checked first because Catalyst reports `.pad`; the check makes the
    /// reason explicit instead of relying on that detail.
    static func deviceClass(idiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom,
                            isMacCatalyst: Bool = ProcessInfo.processInfo.isMacCatalystApp) -> DeviceClass {
        if isMacCatalyst || idiom == .pad { return .tablet }
        return .phone
    }

    /// The limits for a Dynamic Type size and a device class.
    static func limits(for typeSize: DynamicTypeSize,
                       device: DeviceClass = deviceClass()) -> Limits {
        if typeSize.isAccessibilitySize { return .accessibility }
        return device == .tablet ? .tablet : .phone
    }

    /// One measurement of the input: what its text needs, what it is drawn at, whether it scrolls.
    struct Measurement: Equatable {
        /// `sizeThatFits(width, .greatestFiniteMagnitude).height` — unclamped, so a test can prove
        /// the field grew past the cap and was only hidden by it.
        let contentHeight: CGFloat
        /// What the field is drawn at: `min(max(contentHeight, minimum), cap)`.
        let height: CGFloat
        /// True exactly when the content is taller than the cap — the field has stopped growing and
        /// scrolls its own text instead.
        let scrolls: Bool
        let limits: Limits
    }

    /// Apply the rule.
    ///
    /// The content height is rounded **up** before the comparison: `sizeThatFits` returns fractional
    /// points, and truncating would draw a field one point short of its last line (a clipped descender
    /// is the same defect as clipped text). Rounding up also makes "one point past the cap" mean
    /// what it says in a test: `cap + 1` scrolls, `cap` does not.
    static func measurement(contentHeight: CGFloat, limits: Limits) -> Measurement {
        let measured = ceil(max(0, contentHeight))
        let scrolls = measured > limits.cap
        let height = min(max(measured, limits.minimum), limits.cap)
        return Measurement(contentHeight: measured, height: height, scrolls: scrolls, limits: limits)
    }
}

/// The input's `UITextView`: measures itself and switches its own scroller.
///
/// A subclass rather than a coordinator-side helper because the two events that must trigger a
/// re-measure are layout events — the first non-zero width and every later width change (a Catalyst
/// window resize) — and `UIViewRepresentable` gets no callback for either. `layoutSubviews` is the
/// only place that sees them.
///
/// What it deliberately does **not** do: set its own frame height. SwiftUI owns the height (the
/// representable reports `Measurement.height` upward and the frame follows), so the view and the
/// scroller can never disagree about how tall the field is.
///
/// Not `final`: `PasteAwareTextView` subclasses it to add `paste:` and
/// `canPerformAction(_:withSender:)` (kanban t_9fe70579) — the only UIKit seam that can take a pasted
/// image. The measurement and caret behaviour stay here, unchanged.
class ComposerInputTextView: UITextView {

    /// Reports every measurement whose value changed. Called on the main thread, from a layout pass
    /// or a delegate callback; the receiver only stores it.
    var onMeasure: ((ComposerInputHeight.Measurement) -> Void)?

    /// The current Dynamic Type limits. Assigning a different value re-measures immediately, which is
    /// what makes a Dynamic Type change (not a width change) update the height.
    ///
    /// The starting value is the phone pair; `ComposerTextView.makeUIView` assigns the limits for the
    /// device and text size before the first layout, so this default is only what a view built outside
    /// the representable (a test, a preview) measures with.
    var limits: ComposerInputHeight.Limits = .phone {
        didSet {
            guard limits != oldValue else { return }
            remeasure()
        }
    }

    private(set) var measurement: ComposerInputHeight.Measurement?
    /// The width the last measurement was taken at. `layoutSubviews` fires for height changes too, and
    /// re-measuring on those would be an endless loop around the frame SwiftUI is applying.
    private var measuredWidth: CGFloat = 0
    /// True between an edit that owes the reader a caret scroll and the moment that scroll has been
    /// re-applied after layout. See `keepCaretVisible`.
    private var caretScrollPending = false
    /// The size of the last layout pass. A scroll changes `bounds.origin`, not its size, so this is
    /// how `layoutSubviews` tells "the field was resized" from "the field scrolled" — the correction
    /// below must not fire on the scroll it just made.
    private var lastLayoutSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        let resized = bounds.size != lastLayoutSize
        lastLayoutSize = bounds.size
        let width = bounds.width
        if width > 0, abs(width - measuredWidth) >= 0.5 { remeasure(width: width) }
        // The third net of `keepCaretVisible`: an edit asks for a scroll, UIKit lays the inserted
        // text out, and *then* this runs. Doing it here as well as in the delegate is what closes the
        // window in which the scroll used a caret rectangle from before the last line existed
        // (measured live: the field kept `caret=0` for the whole 60 s poll). Only a *resize* counts:
        // a scroll calls this method too, and re-running the correction there would cancel a reader's
        // own swipe. The flag is cleared first, so the scroll this triggers cannot re-enter.
        if caretScrollPending, resized {
            caretScrollPending = false
            if isScrollEnabled, !isCaretOnScreen { scrollCaretIntoView() }
        }
    }

    /// Measure the text at `width`, apply the clamp, and turn the scroller on exactly at the cap.
    ///
    /// `sizeThatFits` includes `textContainerInset`, so the result is the field's own height, not the
    /// text's. It is independent of the current frame height and of `isScrollEnabled`, so the same
    /// width always answers the same number — that is what makes the switch at the cap stable.
    @discardableResult
    func remeasure(width: CGFloat? = nil) -> ComposerInputHeight.Measurement? {
        let width = width ?? bounds.width
        guard width > 0 else { return measurement }
        measuredWidth = width
        let content = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let next = ComposerInputHeight.measurement(contentHeight: content, limits: limits)
        if isScrollEnabled != next.scrolls { isScrollEnabled = next.scrolls }
        let changed = next != measurement
        measurement = next
        if changed { onMeasure?(next) }
        return next
    }

    /// Put the caret back on screen after an edit.
    ///
    /// The everyday failure this fixes is not exotic: type a long message, the field hits its cap and
    /// starts scrolling, and every further character is inserted *below* the visible region unless
    /// something scrolls to it. `scrollRangeToVisible` is that something; `ensureLayout` first,
    /// because the caret rect is read from the layout manager and a keystroke has not necessarily
    /// been laid out yet when the delegate runs.
    ///
    /// It scrolls **twice**: once now, and once more after the runloop turn in which UIKit finishes
    /// laying out the inserted text. The second scroll is not belt-and-braces — with only the first,
    /// a fast paste or a long `typeText` left the field one line short of the caret and nothing ever
    /// corrected it (the live suite read `caret=0` for its whole 60 s timeout; the same code passes
    /// when layout happens to win the race). `layoutSubviews` is the third net, for the case where
    /// the layout lands before the queued block runs.
    func keepCaretVisible() {
        guard selectedRange.location != NSNotFound else { return }
        caretScrollPending = true
        scrollCaretIntoView()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.caretScrollPending else { return }
            self.caretScrollPending = false
            self.scrollCaretIntoView()
        }
    }

    /// The scroll itself, with the layout that has to precede it.
    ///
    /// `scrollRangeToVisible` is not sufficient on its own, and the reason is measurable rather than
    /// theoretical: it lands the caret on the last **glyph line** inside the text container, while
    /// the caret's own rectangle hangs a little lower (its descent plus the field's 6 pt bottom
    /// inset). The live suite caught the result: `offset=1606.3 caretMaxY=1700.7 bounds=1694.3` — the
    /// caret's bottom 6.4 pt sat below the visible edge, so a reader typing at the end of a capped
    /// message saw the caret cut in half. After the platform call, this nudges the offset by exactly
    /// the shortfall, clamped to the scroller's own maximum, so the whole caret is inside the field.
    private func scrollCaretIntoView() {
        guard selectedRange.location != NSNotFound else { return }
        layoutManager.ensureLayout(for: textContainer)
        scrollRangeToVisible(selectedRange)

        let visible = bounds
        guard isScrollEnabled, visible.height > 0, let caret = caretRectangle else { return }
        guard caret.maxY > visible.maxY || caret.minY < visible.minY else { return }

        var offset = contentOffset
        if caret.maxY > visible.maxY {
            offset.y += caret.maxY - visible.maxY + 1
        } else {
            offset.y -= visible.minY - caret.minY + 1
        }
        // The scroller's own bounds: a text view's minimum offset is `-contentInset.top` and its
        // maximum is the content (plus the bottom inset) less one viewport. `contentSize` can be a
        // layout pass behind the caret (a view that has not been laid out yet reports a small one),
        // so the caret's own position is the floor for that maximum — never scroll past the caret
        // just to satisfy a stale content size.
        let minimum = -contentInset.top
        let maximum = max(minimum,
                          contentSize.height + contentInset.bottom - visible.height,
                          caret.maxY + 1 - visible.height)
        offset.y = min(max(offset.y, minimum), maximum)
        guard offset.y != contentOffset.y else { return }
        setContentOffset(offset, animated: false)
    }

    /// Whether the caret is inside the part of the field the reader can see.
    ///
    /// Only the diagnostics seam reads this (`ComposerInputDiagnostics`), but it is the claim the card
    /// is about, so it is a property of the view rather than something the seam re-derives from
    /// `contentOffset` (which would be a second implementation of "on screen" that could disagree).
    var isCaretOnScreen: Bool {
        guard selectedRange.location != NSNotFound,
              let caret = caretRectangle else { return false }
        let tolerance: CGFloat = 1
        return caret.minY >= bounds.minY - tolerance && caret.maxY <= bounds.maxY + tolerance
    }

    /// The caret's rectangle in the view's own coordinate space, laid out. `nil` when the offset is
    /// not addressable (a stale selection after a clear).
    var caretRectangle: CGRect? {
        guard let position = position(from: beginningOfDocument, offset: selectedRange.location) else {
            return nil
        }
        layoutManager.ensureLayout(for: textContainer)
        let caret = caretRect(for: position)
        guard !caret.isNull, !caret.isInfinite else { return nil }
        return caret
    }
}

// MARK: - The measurement seam

/// `-uiTestExposeComposerInputGeometry`: publishes the input's own measurement as one accessibility
/// value, so a UI test can read what the field *did* (height, whether it scrolls, whether the caret is
/// visible) instead of inferring it from a screenshot.
///
/// Gated on a launch argument, exactly like `ScrollGeometrySeam` and the gallery's diagnostics seam: a
/// build a person launches cannot reach this code, and the value is a set of measurements, not text.
enum ComposerInputDiagnostics {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTestExposeComposerInputGeometry")
    }
}

/// What the last measurement was. A reference the seam and the text view share, because the text view
/// is a `UIViewRepresentable` and the seam is a sibling SwiftUI view: neither can see the other.
final class ComposerInputGeometryProbe: ObservableObject {
    /// Weak: the text view owns its lifetime, and the probe must not keep a dismantled field alive.
    weak var view: ComposerInputTextView?
    @Published private(set) var summary = "no measurement yet"

    @MainActor
    func sample() {
        guard let view, let measurement = view.measurement else {
            summary = "no measurement yet"
            return
        }
        // `offset`, `sel` and the caret's own rect are here for one reason: when `caret=0` the number
        // that says *why* has to be in the report, or the next person re-derives the geometry from a
        // screenshot (the seam exists to avoid exactly that).
        let caret = view.caretRectangle
        summary = String(format: "height=%.1f content=%.1f cap=%.1f scrolls=%d caret=%d "
                                 + "offset=%.1f sel=%d len=%d caretY=%.1f caretMaxY=%.1f bounds=%.1f",
                         measurement.height,
                         measurement.contentHeight,
                         measurement.limits.cap,
                         measurement.scrolls ? 1 : 0,
                         view.isCaretOnScreen ? 1 : 0,
                         view.contentOffset.y,
                         view.selectedRange.location,
                         (view.text as NSString).length,
                         caret?.minY ?? -1,
                         caret?.maxY ?? -1,
                         view.bounds.maxY)
    }
}

/// The seam itself: a four-point clear square in the input's corner.
struct ComposerInputGeometrySeam: View {
    @ObservedObject var probe: ComposerInputGeometryProbe

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 4, height: 4)
            .accessibilityElement()
            .accessibilityLabel("Composer input geometry report")
            .accessibilityValue(probe.summary)
            .accessibilityIdentifier("channelComposer.inputGeometry")
            .task {
                while !Task.isCancelled {
                    probe.sample()
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
    }
}
