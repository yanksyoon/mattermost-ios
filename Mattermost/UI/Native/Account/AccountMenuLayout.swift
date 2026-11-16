// t_bc22d0b3 — the account control's geometry, as four rectangles.
//
// The trigger used to be a 28 pt avatar in a 34 pt frame, with the presence dot at the
// bottom-trailing corner and the custom-status emoji at the top-trailing corner, each placed by its
// own `alignment:` + `offset:` pair on top of that frame. Two consequences:
//
//   * the emoji's offset put it 4 pt *outside* the avatar's box and only inside the target because
//     the target was 6 pt larger than the picture — a layout that looks right at one size and drifts
//     the moment either number changes;
//   * nothing tied the two marks to opposite corners. Both offsets were independent numbers in the
//     view body, so a later edit (or a copy of the pattern) can put both in the same corner and the
//     only thing that would notice is a reader looking at the picture.
//
// This turns the picture into arithmetic: the avatar, the dot and the badge are rects in the
// control's own 32 pt frame, computed in one place, so a unit test checks the properties the card
// asks for (the disc matches the glyph weight, the badges are in different corners and do not
// intersect, the dot stays legible on a disc of that size) and the view cannot drift from them.
//
// ## Why both marks are drawn
//
// Upstream's trigger (`user_account_menuButton.tsx`) draws the custom-status emoji and the presence
// mark as **two visible things**, not one: a `CustomStatusEmoji` with a 6 px margin beside the
// avatar, and a `userStatusIconWrapper` holding the 16 px status icon. Both are visible at once, so
// "the emoji replaces the dot" is not what upstream does; what upstream has is a *wider* trigger
// that can afford two marks side by side. This control is one 32 pt square in a run of 17 pt glyphs,
// so the two marks share the avatar instead: presence at the bottom-trailing corner (the corner
// every avatar in this app puts its dot on — `ProfileView`'s `PresenceDot`) and the custom status at
// the top-trailing, 9.5 pt apart at the nearest edges. That keeps both facts visible as upstream
// does, and the rectangles are reported by the header's seam so "both legible" is measured rather
// than asserted.

import CoreGraphics

enum AccountMenuControlLayout {
    /// The control's frame: the same 32 pt frame every header control occupies
    /// (`ChannelHeaderMetrics.controlSide`), so the avatar sits *in* the icon run instead of in a
    /// target of its own.
    static let controlSide: CGFloat = ChannelHeaderMetrics.controlSide

    /// The avatar's visible diameter. A filled disc reads heavier than a stroked glyph of the same
    /// bounding box, so the disc is 20 pt against the glyphs' ~17 pt box — the ~1.2× ratio upstream's
    /// web header uses (a 24 px avatar beside ~20 px icons), rather than the 28 pt disc this control
    /// used to draw beside them.
    static let avatarSide: CGFloat = 20

    /// The presence dot: large enough to read on a 20 pt disc (upstream: 8 px on 24 px), and small
    /// enough that its 1 pt background ring does not eat the presence colour.
    static let presenceDotSide: CGFloat = 7

    /// The custom-status emoji badge. Upstream draws a 14 px emoji on a 24 px avatar (~0.58 of the
    /// disc); 13 pt on a 20 pt disc is the same proportion.
    static let customStatusBadgeSide: CGFloat = 13

    /// The control's own coordinate space, used only by the geometry seam: a `Menu`'s label is laid
    /// out outside the header's subtree, so the header's `.named` space cannot be resolved from
    /// inside it and the badges are reported relative to this control instead.
    static let coordinateSpace = "accountMenuControl"

    /// The avatar, centred in the control's frame.
    static var avatarRect: CGRect {
        let inset = (controlSide - avatarSide) / 2
        return CGRect(x: inset, y: inset, width: avatarSide, height: avatarSide)
    }

    /// The presence dot, straddling the avatar's **bottom-trailing** corner: its centre is the
    /// corner, so half of it hangs past the disc (which is how the dot reads as attached to the
    /// picture) and half sits on it. Still wholly inside the 32 pt control frame.
    static var presenceDotRect: CGRect {
        let avatar = avatarRect
        return CGRect(x: avatar.maxX - presenceDotSide / 2,
                      y: avatar.maxY - presenceDotSide / 2,
                      width: presenceDotSide,
                      height: presenceDotSide)
    }

    /// The custom-status emoji, at the **top-trailing** corner of the control's frame: the corner the
    /// presence dot does not use, wholly inside the frame.
    static var customStatusBadgeRect: CGRect {
        CGRect(x: controlSide - customStatusBadgeSide,
               y: 0,
               width: customStatusBadgeSide,
               height: customStatusBadgeSide)
    }

    /// The gap between the presence dot and the custom-status badge at their nearest edges. Positive
    /// means "two marks, not one", and it is the number the unit test pins.
    static var badgeSeparation: CGFloat {
        let dot = presenceDotRect
        let badge = customStatusBadgeRect
        // They are separated vertically (dot below, badge above); the horizontal overlap is
        // expected — both hang over the avatar's trailing half.
        return max(0, dot.minY - badge.maxY)
    }
}
