// t_bc22d0b3 — the header's trailing cluster, as arithmetic.
//
// The live suite (`MattermostUITests/Tbc22d0b3HeaderClusterUITests`) measures the row the app
// actually drew: order, one `midY`, equal gaps, and the two account badges not overlapping. This
// file pins the numbers that row is *built from*, so a failure can be located without a simulator —
// if these are green and the live test is red, the layout is right and the view drifted from it.
//
// Everything here is the defect the card reports, stated as a property:
//
//   * the account control used to be a 28 pt avatar in a 34 pt frame beside ~17 pt glyphs with no
//     frame at all — 1.65× the glyph box, and no shared control height;
//   * its two badges were placed by two independent `alignment:` + `offset:` pairs, one of which put
//     the emoji 4 pt *outside* the picture it was attached to;
//   * nothing made "one mark per corner" a property, so stacking both in the same corner was a
//     one-line edit away.

import CoreGraphics
import XCTest
@testable import Mattermost

final class Tbc22d0b3HeaderGeometryTests: XCTestCase {

    // MARK: - One row, one frame

    /// The cluster is one row because every control occupies the *same* square — including the
    /// account control, which used to carry a frame of its own (34 pt) that no other control had.
    func testEveryHeaderControlOccupiesTheSameSquareFrame() {
        XCTAssertEqual(AccountMenuControlLayout.controlSide,
                       ChannelHeaderMetrics.controlSide,
                       "the account control must sit in the cluster's frame, not one of its own")
        XCTAssertGreaterThanOrEqual(ChannelHeaderMetrics.controlSide, 28,
                                    "the card's pointer minimum is a 28×28 hit target")
        XCTAssertGreaterThan(ChannelHeaderMetrics.controlSpacing, 0,
                             "adjacent controls need a gap; zero would read as one blob")
        XCTAssertLessThan(ChannelHeaderMetrics.controlSpacing,
                          ChannelHeaderMetrics.controlSide,
                          "the gap must stay smaller than a control, or the row reads as two groups")
    }

    /// `midY` alignment needs every control centred in the same frame — the avatar is centred, and
    /// the glyphs are drawn in the frame's centre by construction, so this pins the avatar's half.
    func testTheAvatarIsCentredInTheClusterFrame() {
        let avatar = AccountMenuControlLayout.avatarRect
        XCTAssertEqual(avatar.midX, ChannelHeaderMetrics.controlSide / 2, accuracy: 0.001)
        XCTAssertEqual(avatar.midY, ChannelHeaderMetrics.controlSide / 2, accuracy: 0.001)
    }

    // MARK: - Optical weight

    /// The reported "wrong optical weight": 28 pt of filled disc beside a ~17 pt stroked glyph.
    /// Match the glyph box instead — the ~1.2× upstream's own header uses (a `size='sm'` 24 px
    /// avatar beside ~20 px icons).
    func testTheAvatarMatchesTheGlyphWeightInsteadOfToweringOverIt() {
        let glyph = ChannelHeaderMetrics.glyphPointSize
        let avatar = AccountMenuControlLayout.avatarSide
        XCTAssertGreaterThan(avatar, glyph,
                             "an avatar smaller than the glyphs would read as a bullet, not an identity")
        XCTAssertLessThanOrEqual(avatar, glyph * 1.3,
                                 "a disc more than ~1.3× the glyph box reads as a heavier object "
                                 + "(the defect: 28 against 17 was 1.65×)")
        XCTAssertLessThanOrEqual(avatar, ChannelHeaderMetrics.controlSide,
                                 "the avatar must fit inside the cluster's frame")
    }

    // MARK: - Badges: two marks, two corners

    /// The presence dot straddles the avatar's **bottom-trailing** corner (its centre on the corner,
    /// so half hangs past the disc) — the convention every avatar in this app uses.
    func testThePresenceDotStraddlesTheAvatarsBottomTrailingCorner() {
        let avatar = AccountMenuControlLayout.avatarRect
        let dot = AccountMenuControlLayout.presenceDotRect
        XCTAssertEqual(dot.midX, avatar.maxX, accuracy: 0.001)
        XCTAssertEqual(dot.midY, avatar.maxY, accuracy: 0.001)
        XCTAssertEqual(dot.width, AccountMenuControlLayout.presenceDotSide, accuracy: 0.001,
                       "the dot is drawn at the size the layout names, not at the size of its frame")
    }

    /// The custom-status badge is the **top**-trailing corner: wholly inside the control's frame, on
    /// the avatar's trailing half. (Before this card it was offset 4 pt past a 28 pt avatar — outside
    /// the picture it annotates.)
    func testTheCustomStatusBadgeIsInsideTheFrameOnTheTrailingHalf() {
        let avatar = AccountMenuControlLayout.avatarRect
        let badge = AccountMenuControlLayout.customStatusBadgeRect
        XCTAssertGreaterThanOrEqual(badge.minX, avatar.midX,
                                    "the badge belongs over the avatar's trailing half")
        XCTAssertLessThanOrEqual(badge.maxX, ChannelHeaderMetrics.controlSide + 0.001,
                                 "the badge must not hang outside the control's frame")
        XCTAssertGreaterThanOrEqual(badge.minY, 0, "the badge must not hang above the frame")
        XCTAssertLessThanOrEqual(badge.maxY, avatar.midY + AccountMenuControlLayout.avatarSide,
                                 "the badge must stay over the avatar, not drift into the row")
    }

    /// The regression this card's fourth test exists for: with a custom status set, the two marks
    /// are in different corners and do not intersect.
    func testTheTwoBadgesNeverIntersect() {
        let dot = AccountMenuControlLayout.presenceDotRect
        let badge = AccountMenuControlLayout.customStatusBadgeRect
        XCTAssertFalse(dot.intersects(badge),
                       "presence \(dot) and the custom-status badge \(badge) must not overlap")
        XCTAssertLessThan(badge.maxY, dot.minY,
                          "the badge is the upper mark and the dot the lower one")
        XCTAssertGreaterThanOrEqual(AccountMenuControlLayout.badgeSeparation, 6,
                                    "less than 6 pt apart and the two marks read as one smeared blob")
    }

    /// Both marks are on the *same* avatar: that is what makes them legible as one control rather
    /// than two stray glyphs in the row.
    func testBothBadgesTouchTheAvatar() {
        let avatar = AccountMenuControlLayout.avatarRect
        let dot = AccountMenuControlLayout.presenceDotRect
        let badge = AccountMenuControlLayout.customStatusBadgeRect
        XCTAssertTrue(avatar.insetBy(dx: -0.001, dy: -0.001).contains(CGPoint(x: dot.midX, y: dot.midY)),
                      "the dot's centre is on the avatar's corner: \(dot) vs \(avatar)")
        XCTAssertTrue(avatar.intersects(badge),
                      "the badge overlaps the avatar it annotates: \(badge) vs \(avatar)")
    }
}
