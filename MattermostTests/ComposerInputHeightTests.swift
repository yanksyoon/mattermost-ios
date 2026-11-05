// kanban t_fbc576a2 — the composer input's height and its scroller.
//
// The defect: `ComposerView.swift` set `isScrollEnabled = false` and gave the field a
// `minHeight/maxHeight` frame. Both together mean "grow until the cap, then clip": the text view kept
// drawing its text but had no scroller to reach the rest of it, and the caret could move out of sight.
//
// These tests drive the production `ComposerInputTextView` — a real `UITextView` with the composer's
// real font and insets — so the heights below are measured by UIKit, not by this file. What a unit
// test cannot do is drive the SwiftUI frame or a Catalyst window resize; T7 drives the view's own
// width instead (the event `layoutSubviews` sees), and the live UI test
// (`MattermostUITests/ComposerInputHeightUITests.swift`) is the end-to-end falsifier.
//
// The caps are upstream's two (`post_input.tsx:171`, `isTablet ? 150 : 88`). The phone cases are the
// ones this repo's live suite runs on an iPhone; the tablet cases are the Mac window's (Catalyst
// reports `.pad`). Both are exercised, because a test that only ever sees 150 cannot tell a device
// branch from a constant.

import UIKit
import XCTest
@testable import Mattermost

final class ComposerInputHeightTests: XCTestCase {

    // MARK: - The rule (no view)

    /// At exactly the cap the field still fits: it must not scroll, or a message that fits would be
    /// drawn with a scroller and a clipped-looking frame.
    func testExactlyAtTheCapDoesNotScroll() {
        for limits in [ComposerInputHeight.Limits.phone, .tablet] {
            let atCap = ComposerInputHeight.measurement(contentHeight: limits.cap, limits: limits)
            XCTAssertEqual(atCap.height, limits.cap)
            XCTAssertFalse(atCap.scrolls, "\(limits) at exactly its cap must not scroll")
        }
    }

    /// …and one point past it does. This is the AV case the card names ("cap+1"), for both ceilings.
    func testOnePointPastTheCapScrolls() {
        for limits in [ComposerInputHeight.Limits.phone, .tablet] {
            let past = ComposerInputHeight.measurement(contentHeight: limits.cap + 1, limits: limits)
            XCTAssertEqual(past.height, limits.cap, "the field stops at the cap")
            XCTAssertTrue(past.scrolls, "past the cap the text must scroll inside the field")
        }
    }

    func testTheMinimumWinsOverAShortContentHeight() {
        let empty = ComposerInputHeight.measurement(contentHeight: 0, limits: .phone)
        XCTAssertEqual(empty.height, 34)
        XCTAssertFalse(empty.scrolls)
        let axEmpty = ComposerInputHeight.measurement(contentHeight: 10, limits: .accessibility)
        XCTAssertEqual(axEmpty.height, 56)
    }

    /// `sizeThatFits` returns fractional points; truncating would draw a field one point short of its
    /// last line, which is the same clipping defect in miniature.
    func testAFractionalContentHeightIsRoundedUp() {
        let fractional = ComposerInputHeight.measurement(contentHeight: 100.2, limits: .tablet)
        XCTAssertEqual(fractional.contentHeight, 101)
        XCTAssertEqual(fractional.height, 101)
    }

    /// Upstream's two ceilings, upstream's floor, and the accessibility pair T45 already shipped.
    func testTheLimitsAreUpstreamsValuesAndTheAccessibilityCeilingIsKept() {
        // post_input.tsx:171 — `maxHeight = isTablet ? 150 : 88`.
        XCTAssertEqual(ComposerInputHeight.Limits.phone, .init(minimum: 34, cap: 88))
        XCTAssertEqual(ComposerInputHeight.Limits.tablet, .init(minimum: 34, cap: 150))
        // T45's floor/ceiling, unchanged by this card.
        XCTAssertEqual(ComposerInputHeight.Limits.accessibility, .init(minimum: 56, cap: 220))
    }

    /// `isTablet` is the idiom, not the width — and a Catalyst window is the tablet case (the card's
    /// "Mac window uses 150").
    func testTheDeviceClassComesFromTheIdiomAndCatalystIsTablet() {
        XCTAssertEqual(ComposerInputHeight.deviceClass(idiom: .phone, isMacCatalyst: false), .phone)
        XCTAssertEqual(ComposerInputHeight.deviceClass(idiom: .pad, isMacCatalyst: false), .tablet)
        XCTAssertEqual(ComposerInputHeight.deviceClass(idiom: .pad, isMacCatalyst: true), .tablet)
        // A Catalyst window is always tablet, whatever it reports and however narrow it is dragged.
        XCTAssertEqual(ComposerInputHeight.deviceClass(idiom: .phone, isMacCatalyst: true), .tablet)
    }

    /// The selection rule as a table: device class picks 88 or 150; an accessibility text size
    /// overrides both with 56/220.
    func testTheLimitsForADeviceAndTextSize() {
        XCTAssertEqual(ComposerInputHeight.limits(for: .large, device: .phone), .phone)
        XCTAssertEqual(ComposerInputHeight.limits(for: .large, device: .tablet), .tablet)
        XCTAssertEqual(ComposerInputHeight.limits(for: .accessibility3, device: .phone), .accessibility)
        XCTAssertEqual(ComposerInputHeight.limits(for: .accessibility3, device: .tablet), .accessibility)
    }

    // MARK: - The view (real UITextView measurement)

    /// A field configured exactly as `ComposerTextView.makeUIView` configures it.
    private func makeInput(width: CGFloat = 402,
                           limits: ComposerInputHeight.Limits = .phone) -> ComposerInputTextView {
        let view = ComposerInputTextView()
        view.font = .preferredFont(forTextStyle: .body)
        view.textContainerInset = UIEdgeInsets(top: 6, left: 2, bottom: 6, right: 2)
        view.textContainer.lineFragmentPadding = 0
        view.frame = CGRect(x: 0, y: 0, width: width, height: limits.minimum)
        view.limits = limits
        return view
    }

    private func text(lines: Int) -> String {
        (1...lines).map { "line \($0)" }.joined(separator: "\n")
    }

    /// Type into the field the way `updateUIView` and the delegate do: set the text, re-measure.
    @discardableResult
    private func enter(_ text: String, in view: ComposerInputTextView) -> ComposerInputHeight.Measurement? {
        view.text = text
        view.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        view.layoutIfNeeded()
        return view.remeasure()
    }

    // T1
    func testOneLineIsTheMinimumHeightAndDoesNotScroll() {
        for limits in [ComposerInputHeight.Limits.phone, .tablet] {
            let view = makeInput(limits: limits)
            let measured = enter("Hello", in: view)
            XCTAssertEqual(measured?.height, limits.minimum)
            XCTAssertEqual(measured?.scrolls, false)
            XCTAssertEqual(view.isScrollEnabled, false, "a one-line field must not scroll (\(limits))")
        }
    }

    // T2
    func testTheFieldGrowsLineByLineAndStillDoesNotScrollAtFiveLines() {
        let view = makeInput(limits: .tablet)
        var heights: [CGFloat] = []
        for lines in 1...5 {
            guard let measured = enter(text(lines: lines), in: view) else {
                return XCTFail("no measurement")
            }
            heights.append(measured.height)
            XCTAssertFalse(measured.scrolls, "\(lines) lines is under the tablet cap and must not scroll")
        }
        XCTAssertEqual(heights, heights.sorted(), "the height must grow with the text: \(heights)")
        XCTAssertGreaterThan(heights.last!, heights.first!, "five lines must be taller than one")
        XCTAssertGreaterThan(heights.last!, 34)
        XCTAssertLessThan(heights.last!, 150)
    }

    /// …and on a phone the same growth happens, stopping earlier: three lines fit inside 88 pt, so the
    /// field has grown by then without having become a scroller.
    func testTheFieldAlsoGrowsOnAPhoneBelowItsLowerCap() {
        let view = makeInput(limits: .phone)
        guard let one = enter(text(lines: 1), in: view),
              let three = enter(text(lines: 3), in: view) else { return XCTFail("no measurement") }
        XCTAssertEqual(one.height, 34)
        XCTAssertGreaterThan(three.height, one.height)
        XCTAssertLessThan(three.height, 88)
        XCTAssertFalse(three.scrolls)
        XCTAssertFalse(view.isScrollEnabled)
    }

    // T3
    func testPastTheCapTheHeightIsExactlyTheCapAndTheFieldScrolls() {
        for limits in [ComposerInputHeight.Limits.phone, .tablet] {
            let view = makeInput(limits: limits)
            guard let measured = enter(text(lines: 40), in: view) else {
                return XCTFail("no measurement")
            }
            XCTAssertEqual(measured.height, limits.cap, "the frame must stop at the cap (\(limits))")
            XCTAssertGreaterThan(measured.contentHeight, limits.cap, "…while the text is taller than it")
            XCTAssertTrue(measured.scrolls)
            XCTAssertTrue(view.isScrollEnabled, "the field has to scroll internally past the cap")
        }
    }

    // T4
    func testDeletingBackBelowTheCapShrinksTheFieldAndStopsItScrolling() {
        let view = makeInput(limits: .phone)
        enter(text(lines: 40), in: view)
        XCTAssertTrue(view.isScrollEnabled)
        guard let shrunk = enter("one line", in: view) else {
            return XCTFail("no measurement")
        }
        XCTAssertEqual(shrunk.height, 34, "the field must shrink back to the minimum")
        XCTAssertFalse(shrunk.scrolls)
        XCTAssertFalse(view.isScrollEnabled, "a field that fits must not keep its scroller")
    }

    // T5
    func testTheCaretAtTheEndOfALongMessageIsScrolledIntoView() {
        let view = makeInput(limits: .phone)
        enter(text(lines: 40), in: view)
        view.frame = CGRect(x: 0, y: 0, width: 402, height: 88)
        view.layoutIfNeeded()
        view.selectedRange = NSRange(location: (view.text as NSString).length, length: 0)

        XCTAssertFalse(view.isCaretOnScreen,
                       "precondition: the caret is below the visible region before anything scrolls it")
        view.keepCaretVisible()
        XCTAssertTrue(view.isCaretOnScreen,
                      "typing at the end of a capped field must keep the caret on screen "
                      + "(offset \(view.contentOffset.y), caret \(String(describing: view.caretRectangle)))")
    }

    /// The scroll is applied twice on purpose: once in the delegate and once after the runloop turn
    /// in which UIKit lays the inserted text out. This pins the second one — the state a lone
    /// synchronous scroll leaves behind is exactly a content offset that a later layout pass has
    /// reset (measured live as `caret=0` for the whole poll).
    func testTheCaretScrollIsRepeatedAfterTheRunloopTurns() {
        let view = makeInput(limits: .phone)
        enter(text(lines: 40), in: view)
        view.frame = CGRect(x: 0, y: 0, width: 402, height: 88)
        view.layoutIfNeeded()
        view.selectedRange = NSRange(location: (view.text as NSString).length, length: 0)
        view.keepCaretVisible()
        XCTAssertTrue(view.isCaretOnScreen, "the immediate scroll must work")

        view.contentOffset = .zero
        XCTAssertFalse(view.isCaretOnScreen, "precondition: the offset was reset")

        let turned = expectation(description: "the deferred caret scroll runs")
        DispatchQueue.main.async { turned.fulfill() }
        wait(for: [turned], timeout: 2)
        XCTAssertTrue(view.isCaretOnScreen,
                      "the caret scroll must be re-applied after the runloop turn, "
                      + "without another edit (offset \(view.contentOffset.y))")
    }

    // T6
    func testShiftReturnAtTheCapInsertsANewlineKeepsTheCaretVisibleAndDoesNotSend() {
        var sent = 0
        var edited: [(String, NSRange)] = []
        let representable = ComposerTextView(text: "",
                                             caret: 0,
                                             placeholder: "Message",
                                             onEdit: { text, range in edited.append((text, range)) },
                                             onSelection: { _ in },
                                             limits: .phone,
                                             onMeasure: { _ in },
                                             onReturn: { _ in sent += 1 },
                                             isShiftPressed: { true })
        let coordinator = representable.makeCoordinator()
        let view = makeInput(limits: .phone)
        view.delegate = coordinator
        coordinator.parent = representable

        let long = text(lines: 40)
        view.text = long
        view.selectedRange = NSRange(location: (long as NSString).length, length: 0)
        view.layoutIfNeeded()
        view.remeasure()
        view.frame = CGRect(x: 0, y: 0, width: 402, height: 88)
        XCTAssertTrue(view.isScrollEnabled)

        let range = view.selectedRange
        let allowed = coordinator.textView(view, shouldChangeTextIn: range, replacementText: "\n")
        XCTAssertTrue(allowed, "Shift+Return is a newline, not a refusal")
        XCTAssertEqual(sent, 0, "Shift+Return must not send")

        // What UIKit does next with an allowed change, through the same delegate callbacks.
        view.text = long + "\n"
        view.selectedRange = NSRange(location: (view.text as NSString).length, length: 0)
        coordinator.textViewDidChange(view)

        XCTAssertEqual(view.text.count, long.count + 1)
        XCTAssertEqual(edited.last?.0.count, long.count + 1, "the edit reaches the model")
        XCTAssertTrue(view.isScrollEnabled, "still past the cap")
        XCTAssertTrue(view.isCaretOnScreen, "the new empty line must be visible")
    }

    /// The policy is untouched: an unshifted Return at the cap still sends and refuses the change.
    func testReturnAtTheCapStillSendsAndDoesNotInsert() {
        var sent = 0
        let representable = ComposerTextView(text: "",
                                             caret: 0,
                                             placeholder: "Message",
                                             onEdit: { _, _ in },
                                             onSelection: { _ in },
                                             limits: .phone,
                                             onMeasure: { _ in },
                                             onReturn: { _ in sent += 1 },
                                             isShiftPressed: { false })
        let coordinator = representable.makeCoordinator()
        let view = makeInput(limits: .phone)
        view.delegate = coordinator
        coordinator.parent = representable
        enter(text(lines: 40), in: view)

        let allowed = coordinator.textView(view, shouldChangeTextIn: view.selectedRange,
                                            replacementText: "\n")
        XCTAssertFalse(allowed, "Return sends instead of inserting")
        XCTAssertEqual(sent, 1)
    }

    // T7
    func testANarrowerWidthReMeasuresTheHeight() {
        let view = makeInput(width: 402, limits: .phone)
        let report = Report()
        view.onMeasure = { report.record($0) }
        let wide = enter(String(repeating: "word ", count: 20), in: view)

        // The resize: same text, half the width. `layoutSubviews` is what the subclass listens to, so
        // the test changes the frame and lays out rather than calling `remeasure` itself.
        view.frame = CGRect(x: 0, y: 0, width: 200, height: view.frame.height)
        view.layoutIfNeeded()

        guard let wide, let narrow = view.measurement else { return XCTFail("no measurement") }
        XCTAssertEqual(view.frame.width, 200)
        XCTAssertGreaterThan(narrow.contentHeight, wide.contentHeight,
                             "the same text needs more lines at half the width")
        XCTAssertGreaterThan(narrow.height, wide.height, "the height must not stay stale")
        XCTAssertTrue(report.values.count >= 2,
                      "the resize must publish a new measurement: \(report.values)")
        XCTAssertEqual(report.values.last, narrow)
    }

    /// The Dynamic Type half of requirement 4. A Dynamic Type change reaches the view as **both** an
    /// environment change (which recomputes `limits`) and a new `preferredFont` (which `updateUIView`
    /// assigns before re-measuring); this drives the same pair, because only the two together are the
    /// production event. The limits assignment alone must also re-measure — that is the `didSet`.
    func testChangingTheLimitsReMeasuresTheSameText() {
        let view = makeInput(limits: .phone)
        let small = enter(text(lines: 3), in: view)
        let traits = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        view.font = UIFontMetrics(forTextStyle: .body)
            .scaledFont(for: .preferredFont(forTextStyle: .body), compatibleWith: traits)
        view.limits = .accessibility
        let large = view.measurement
        XCTAssertEqual(view.limits, .accessibility, "the limits assignment re-measured")
        XCTAssertFalse(view.isScrollEnabled, "three AX lines still fit 220")
        XCTAssertGreaterThan(large!.height, small!.height)
        XCTAssertGreaterThan(large!.contentHeight, small!.contentHeight)
        XCTAssertEqual(large?.limits, .accessibility)

        // And the AX floor applies to a one-line field at this size: it is at least 56, and above
        // that it is exactly what the (larger) font needs.
        guard let one = enter("hello", in: view) else { return XCTFail("no measurement") }
        XCTAssertGreaterThanOrEqual(one.height, 56)
        XCTAssertEqual(one.height, max(one.contentHeight, 56))
        XCTAssertFalse(one.scrolls)
    }

    /// A fast burst of insertions, the way a paste or a long `typeText` arrives: the delegate runs for
    /// every insertion, the field caps and scrolls, and the caret has to stay on screen. This is the
    /// unit-level shape of the live case that failed intermittently (`caret=0` for the whole poll).
    func testAFastBurstOfInsertionsKeepsTheCaretVisible() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UIViewController()
        let host = window.rootViewController!.view!
        let view = makeInput(width: 200, limits: .phone)
        host.addSubview(view)
        window.makeKeyAndVisible()
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 88)

        var sent = 0
        let representable = ComposerTextView(text: "",
                                             caret: 0,
                                             placeholder: "Message",
                                             onEdit: { _, _ in },
                                             onSelection: { _ in },
                                             limits: .phone,
                                             onMeasure: { _ in },
                                             onReturn: { _ in sent += 1 },
                                             isShiftPressed: { false })
        let coordinator = representable.makeCoordinator()
        coordinator.parent = representable
        view.delegate = coordinator
        view.becomeFirstResponder()

        let burst = String(repeating: "the quick brown fox jumps over the lazy dog ", count: 12)
        for _ in 0..<4 {
            view.insertText(burst)
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        XCTAssertGreaterThan(view.measurement!.contentHeight, 88, "the text must be past the cap")
        XCTAssertTrue(view.isScrollEnabled, "the field scrolls at the cap")
        XCTAssertEqual(sent, 0)
        XCTAssertTrue(view.isCaretOnScreen,
                      "a burst of insertions must leave the caret visible "
                      + "(offset \(view.contentOffset.y), caret \(String(describing: view.caretRectangle)), "
                      + "bounds \(view.bounds))")
        // The claim is "inside the visible text rect", not "within a point of it": the scroll has to
        // cover the caret's own rectangle, which hangs below the last glyph line (the live suite saw
        // `caretMaxY=1700.7` against `bounds=1694.3` — a caret cut in half).
        guard let caret = view.caretRectangle else { return XCTFail("no caret rect") }
        XCTAssertLessThanOrEqual(caret.maxY, view.bounds.maxY + 0.5,
                                 "the caret's bottom must be inside the field")
        XCTAssertGreaterThanOrEqual(caret.minY, view.bounds.minY - 0.5)
    }

    // MARK: - The two falsifiers the card asks for by name

    /// **Regression test for `isScrollEnabled = false`.** The same five-line text is under the tablet
    /// cap and over the phone cap, so the switch has to answer `false` *and* `true` for one text. A
    /// version of `remeasure` that (re)sets `isScrollEnabled = false` — the shape of the original
    /// defect — fails the first and third assertions, which is exactly the change this card reverts.
    func testTheScrollerFollowsTheMeasurementRatherThanAConstant() {
        let view = makeInput(width: 402, limits: .phone)
        let fiveLines = text(lines: 5)

        enter(fiveLines, in: view)
        XCTAssertTrue(view.isScrollEnabled,
                      "five lines are past the phone cap, so the field must scroll")
        XCTAssertGreaterThan(view.measurement!.contentHeight, 88)

        view.limits = .tablet
        XCTAssertFalse(view.isScrollEnabled,
                       "the same five lines fit the tablet cap, so the scroller must switch off")

        view.limits = .phone
        XCTAssertTrue(view.isScrollEnabled, "…and back on when the cap shrinks again")
    }

    /// **The cap + one line case.** The first line count whose measured content passes the cap is by
    /// construction "the cap plus part of a line": at most one line taller than the cap, and the field
    /// is already scrolling. Its predecessor still fits and does not scroll.
    func testTheFirstLineCountPastTheCapIsOneLinePastIt() {
        let view = makeInput(width: 402, limits: .phone)
        guard let oneLine = enter(text(lines: 1), in: view) else { return XCTFail("no measurement") }
        guard let twoLines = enter(text(lines: 2), in: view) else { return XCTFail("no measurement") }
        let lineHeight = twoLines.contentHeight - oneLine.contentHeight
        XCTAssertGreaterThan(lineHeight, 0)

        var firstPast: Int?
        for lines in 2...20 {
            guard let measured = enter(text(lines: lines), in: view) else { return XCTFail("no measurement") }
            if measured.contentHeight > 88 {
                firstPast = lines
                XCTAssertEqual(measured.height, 88, "the field stops exactly at the cap")
                XCTAssertTrue(measured.scrolls)
                XCTAssertLessThanOrEqual(measured.contentHeight, 88 + lineHeight + 1,
                                         "the first content past the cap is about one line past it")
                break
            }
        }
        guard let firstPast else { return XCTFail("twenty lines never passed the cap") }

        guard let justUnder = enter(text(lines: firstPast - 1), in: view) else {
            return XCTFail("no measurement")
        }
        XCTAssertLessThanOrEqual(justUnder.contentHeight, 88)
        XCTAssertEqual(justUnder.height, justUnder.contentHeight,
                       "below the cap the frame is the measured height")
        XCTAssertFalse(justUnder.scrolls)
    }

    /// Collects the measurements the view publishes. A class so the closure can mutate it.
    private final class Report {
        private(set) var values: [ComposerInputHeight.Measurement] = []
        func record(_ measurement: ComposerInputHeight.Measurement) { values.append(measurement) }
    }
}
