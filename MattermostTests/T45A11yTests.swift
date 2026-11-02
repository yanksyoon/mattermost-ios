import SwiftUI
import XCTest
@testable import Mattermost

/// T45 — the pure logic behind the accessibility pass.
///
/// What is not testable from a unit test is what the screen *looks* like; that is
/// the capture run in `docs/t45-a11y-*.png` and the live UI assertions in
/// `MattermostUITests/T45A11yUITests.swift`. What is testable — and what this file
/// pins — is every decision the pass makes about the user's settings:
///
///   * a designed point size resolves to exactly one Dynamic Type role, and the
///     resolution is monotone (bigger design -> bigger or equal role) and total
///     (no size maps to nothing);
///   * markdown heading levels keep their order after conversion, at every size;
///   * Reduce Motion turns incidental motion off and keeps essential motion, and
///     the transition form degrades to `.identity`;
///   * Increase Contrast strengthens a separator instead of leaving it;
///   * a one-line cap relaxes at accessibility text sizes.
final class T45A11yTests: XCTestCase {

    // MARK: - TypeRole: the mapping

    /// Every role knows its text style and the default size that style renders at.
    func testEveryRoleHasATextStyleAndAPlausibleDefaultSize() {
        for role in TypeRole.allCases {
            XCTAssertGreaterThan(role.defaultPointSize, 0, "\(role) has no default size")
            // The table is Apple's; these are the values the mapping measures against.
            XCTAssertTrue((9...40).contains(role.defaultPointSize),
                          "\(role) default size \(role.defaultPointSize) is outside the iOS ramp")
        }
    }

    /// `rank` is the order the ramp grows in, and `allCases` must agree with it —
    /// `nearest(to:)` sorts by rank, so a role added out of order would silently
    /// resolve to the wrong neighbour.
    func testRanksAreAscendingInCaseOrder() {
        let sizes = TypeRole.allCases.sorted { $0.rank < $1.rank }.map(\.defaultPointSize)
        XCTAssertEqual(sizes, sizes.sorted(), "rank order and point-size order disagree")
        XCTAssertEqual(TypeRole.allCases.count, Set(TypeRole.allCases.map(\.rank)).count,
                       "two roles share a rank")
    }

    /// The mapping is total: any size a designer could type resolves to a role.
    func testNearestIsTotalOverAFloorToCeilingSweep() {
        for size in stride(from: CGFloat(4), through: 80, by: 0.25) {
            _ = TypeRole.nearest(to: size)
        }
        XCTAssertEqual(TypeRole.nearest(to: 0), .caption2)
        XCTAssertEqual(TypeRole.nearest(to: 1_000), .largeTitle)
    }

    /// Exact table values resolve to themselves.
    func testEveryDefaultSizeResolvesToItsOwnRole() {
        for role in TypeRole.allCases {
            XCTAssertEqual(TypeRole.nearest(to: role.defaultPointSize), role)
        }
    }

    /// The sizes this app actually designs at, resolved as the pass intends.
    /// These are the numbers in the call sites; a change here is a look change and
    /// should be deliberate.
    func testDesignedSizesMapToTheExpectedRoles() {
        let expected: [CGFloat: TypeRole] = [
            9: .caption2,      // thread unread badge
            10: .caption2,     // composer attachment progress
            11: .caption2,     // timestamps, "Sending…"
            12: .caption,      // reaction counts, file subtitles
            13: .footnote,     // author name, previews
            13.5: .footnote,   // markdown tables
            14: .footnote,     // reaction sheet names — tie, resolves smaller
            15: .subheadline,  // post body
            16: .callout,      // file action label
            17: .body,         // body at Apple's default
            20: .title3,
            22: .title2,
            26: .title,        // an oversized glyph
            34: .largeTitle,
        ]
        for (size, role) in expected {
            XCTAssertEqual(TypeRole.nearest(to: size), role, "size \(size)")
        }
    }

    /// Bigger designed size -> bigger or equal role, across the whole range. This
    /// is the property that keeps a converted layout's hierarchy intact.
    func testNearestIsMonotoneNonDecreasing() {
        var previous = TypeRole.nearest(to: 4)
        for size in stride(from: CGFloat(4), through: 80, by: 0.25) {
            let role = TypeRole.nearest(to: size)
            XCTAssertGreaterThanOrEqual(role.rank, previous.rank,
                                        "size \(size) resolved below its predecessor")
            previous = role
        }
    }

    /// A tie resolves to the smaller role: 14 is exactly between `footnote` (13)
    /// and `subheadline` (15), and growing text nobody asked to grow is the worse
    /// error.
    func testTiesResolveToTheSmallerRole() {
        XCTAssertEqual(TypeRole.nearest(to: 14), .footnote)
        XCTAssertEqual(TypeRole.nearest(to: 12.5), .caption)
        XCTAssertEqual(TypeRole.nearest(to: 18.5), .body)
    }

    // MARK: - Markdown headings

    /// h1..h6 keep a non-increasing ramp once they are text styles, so no level
    /// renders larger than the level above it at any text size.
    func testHeadingRolesAreNonIncreasing() {
        var previous = MarkdownMetrics.headingRole(1)
        for level in 2...6 {
            let role = MarkdownMetrics.headingRole(level)
            XCTAssertLessThanOrEqual(role.rank, previous.rank,
                                     "h\(level) resolved above h\(level - 1)")
            previous = role
        }
    }

    /// Levels outside 1...6 (a parser bug, a future h7) still resolve, to the
    /// smallest role rather than to nothing.
    func testHeadingRolesAreDefinedOutsideTheDocumentedRange() {
        XCTAssertEqual(MarkdownMetrics.headingRole(0), .footnote)
        XCTAssertEqual(MarkdownMetrics.headingRole(7), .footnote)
    }

    // MARK: - Reduce Motion

    /// With Reduce Motion off, the caller's animation is passed through untouched.
    func testMotionPolicyPassesTheDesignAnimationThroughWhenReduceMotionIsOff() {
        let animation = Animation.easeOut(duration: 0.2)
        XCTAssertEqual(MotionPolicy.animation(animation, for: .incidental, reduceMotion: false),
                       animation)
        XCTAssertEqual(MotionPolicy.animation(animation, for: .essential, reduceMotion: false),
                       animation)
    }

    /// Incidental motion is dropped entirely: `nil` to `withAnimation` swaps state
    /// without animating.
    func testIncidentalMotionIsDroppedUnderReduceMotion() {
        XCTAssertNil(MotionPolicy.animation(.easeInOut(duration: 0.25),
                                            for: .incidental,
                                            reduceMotion: true))
    }

    /// Essential motion still happens, but short — a control that looks frozen is
    /// its own accessibility problem.
    func testEssentialMotionSurvivesReduceMotionShortened() {
        XCTAssertEqual(MotionPolicy.animation(.easeInOut(duration: 2), for: .essential, reduceMotion: true),
                       .linear(duration: MotionPolicy.essentialDuration))
        XCTAssertLessThanOrEqual(MotionPolicy.essentialDuration, 0.2)
    }

    /// A transition under Reduce Motion appears and disappears in place.
    ///
    /// `AnyTransition` is not `Equatable`, so the comparison is by description —
    /// `.identity` describes itself as its own type, which is exactly the claim.
    func testIncidentalTransitionsBecomeIdentityUnderReduceMotion() {
        XCTAssertEqual(String(describing: MotionPolicy.transition(.opacity, for: .incidental, reduceMotion: true)),
                       String(describing: AnyTransition.identity))
        XCTAssertEqual(String(describing: MotionPolicy.transition(.slide, for: .incidental, reduceMotion: false)),
                       String(describing: AnyTransition.slide))
        XCTAssertEqual(String(describing: MotionPolicy.transition(.slide, for: .essential, reduceMotion: true)),
                       String(describing: AnyTransition.slide))
    }

    // MARK: - Increase Contrast

    func testSeparatorOpacityIsUnchangedAtNormalContrast() {
        for base in [0.18, 0.2, 0.35, 1.0] {
            XCTAssertEqual(ContrastPolicy.separatorOpacity(base, contrast: .standard), base,
                           accuracy: 0.0001)
        }
    }

    func testSeparatorOpacityIncreasesAtIncreasedContrast() {
        for base in [0.18, 0.2, 0.35] {
            let increased = ContrastPolicy.separatorOpacity(base, contrast: .increased)
            XCTAssertGreaterThan(increased, base, "opacity \(base) was not strengthened")
        }
    }

    /// Stronger, not invisible: the multiplier never pushes past opaque, and never
    /// weakens a line that was already strong.
    func testSeparatorOpacityClampsAtOpaque() {
        XCTAssertEqual(ContrastPolicy.separatorOpacity(0.9, contrast: .increased), 1.0,
                       accuracy: 0.0001)
        XCTAssertEqual(ContrastPolicy.separatorOpacity(0.35, contrast: .increased), 0.77,
                       accuracy: 0.0001)
    }

    func testBorderWidthGrowsOnlyWhenItIsThin() {
        XCTAssertEqual(ContrastPolicy.borderWidth(1, contrast: .standard), 1)
        XCTAssertEqual(ContrastPolicy.borderWidth(1, contrast: .increased),
                       ContrastPolicy.increasedBorderWidth)
        XCTAssertEqual(ContrastPolicy.borderWidth(3, contrast: .increased), 3,
                       "a border that is already thick must not be thickened further")
    }

    // MARK: - Line limits

    /// A one-line row stays one line at ordinary sizes...
    func testLineLimitIsTheDesignCapBelowAccessibilitySizes() {
        for size in [DynamicTypeSize.xSmall, .small, .medium, .large, .xLarge,
                     .xxLarge, .xxxLarge] {
            XCTAssertFalse(size.isAccessibilitySize)
            XCTAssertEqual(LineLimitPolicy.limit(cap: 1, for: size), 1, "\(size)")
        }
    }

    /// ...and relaxes at every accessibility size, which is the card's AX3+
    /// criterion expressed as a number.
    func testLineLimitRelaxesAtEveryAccessibilitySize() {
        for size in [DynamicTypeSize.accessibility1, .accessibility2, .accessibility3,
                     .accessibility4, .accessibility5] {
            XCTAssertTrue(size.isAccessibilitySize)
            XCTAssertEqual(LineLimitPolicy.limit(cap: 1, for: size),
                           LineLimitPolicy.accessibilityLines, "\(size)")
        }
    }

    /// The relaxed cap is never below the requested one, so a caller that already
    /// asked for two lines does not get one back.
    func testLineLimitNeverTightensACallerCap() {
        XCTAssertEqual(LineLimitPolicy.limit(cap: 5, for: .accessibility5), 5)
        XCTAssertEqual(LineLimitPolicy.limit(cap: 3, for: .accessibility1), 3)
    }
}
