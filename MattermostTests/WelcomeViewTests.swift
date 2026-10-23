import XCTest
@testable import Mattermost

/// Tests for the `WelcomeView` onboarding pager's state machine, `WelcomePagerModel` — the
/// native counterpart of the desktop `Carousel` component's index/`autoChange` logic.
/// The view itself is exercised via the simulator launch; these pin the wrap, navigation and
/// auto-advance semantics that drive the UI.
@MainActor
final class WelcomePagerModelTests: XCTestCase {

    func testStartsAtRequestedIndex() {
        let model = WelcomePagerModel(pageCount: 4, startIndex: 0)
        XCTAssertEqual(model.currentIndex, 0)
        XCTAssertTrue(model.autoAdvances)
    }

    func testGoNextMovesForward() {
        let model = WelcomePagerModel(pageCount: 4)
        model.goNext()
        XCTAssertEqual(model.currentIndex, 1)
    }

    func testGoPrevMovesBackward() {
        let model = WelcomePagerModel(pageCount: 4, startIndex: 3)
        model.goPrev()
        XCTAssertEqual(model.currentIndex, 2)
    }

    func testNextWrapsToFirst() {
        let model = WelcomePagerModel(pageCount: 4, startIndex: 3)
        model.goNext()
        XCTAssertEqual(model.currentIndex, 0, "advancing past the last slide wraps to the first")
    }

    func testPrevWrapsToLast() {
        let model = WelcomePagerModel(pageCount: 4, startIndex: 0)
        model.goPrev()
        XCTAssertEqual(model.currentIndex, 3, "decreasing before the first slide wraps to the last")
    }

    func testManualNavigationDisablesAutoAdvance() {
        let model = WelcomePagerModel(pageCount: 4)
        XCTAssertTrue(model.autoAdvances)
        model.goNext()
        XCTAssertFalse(model.autoAdvances, "a manual click turns auto-advance off (desktop autoChange)")
        model.goPrev()
        XCTAssertFalse(model.autoAdvances)
        model.jump(to: 2)
        XCTAssertFalse(model.autoAdvances)
    }

    func testSwipeJumpDisablesAutoAdvance() {
        let model = WelcomePagerModel(pageCount: 4)
        model.jump(to: 2)
        XCTAssertEqual(model.currentIndex, 2)
        XCTAssertFalse(model.autoAdvances)
    }

    func testAdvanceAutoCyclesThroughAllPages() {
        let model = WelcomePagerModel(pageCount: 4)
        for _ in 0..<4 { model.advanceAuto() }
        XCTAssertEqual(model.currentIndex, 0, "4 auto ticks over 4 pages returns to the first")
        XCTAssertTrue(model.autoAdvances, "auto ticks never disable auto-advance")
    }

    func testAdvanceAutoIsNoOpAfterManualInteraction() {
        let model = WelcomePagerModel(pageCount: 4, startIndex: 1)
        model.goNext() // disables auto-advance
        let frozen = model.currentIndex
        model.advanceAuto()
        model.advanceAuto()
        XCTAssertEqual(model.currentIndex, frozen, "auto-advance must not move once disabled")
    }

    func testAdvanceAutoSinglePageDoesNotWrap() {
        let model = WelcomePagerModel(pageCount: 1)
        XCTAssertTrue(model.disableNavigation)
        model.advanceAuto()
        XCTAssertEqual(model.currentIndex, 0)
        model.goNext()
        XCTAssertEqual(model.currentIndex, 0, "single page stays put")
    }

    func testDisableNavigationOnlyWhenMultiplePages() {
        XCTAssertTrue(WelcomePagerModel(pageCount: 1).disableNavigation)
        XCTAssertFalse(WelcomePagerModel(pageCount: 2).disableNavigation)
        XCTAssertFalse(WelcomePagerModel(pageCount: 4).disableNavigation)
    }

    func testDefaultSlidesRoundingOutDesktopCopy() {
        let slides = WelcomeSlide.defaultSlides
        XCTAssertEqual(slides.count, 4)
        XCTAssertTrue(slides[0].isMain, "the welcome slide is the desktop 'main' slide")
        XCTAssertEqual(slides.map(\.title),
                       ["Welcome", "Collaborate in real-time", "Start secure calls instantly", "Integrate with your systems"])
    }
}