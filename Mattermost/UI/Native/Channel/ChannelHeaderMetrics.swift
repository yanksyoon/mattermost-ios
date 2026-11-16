// t_bc22d0b3 — the channel header's trailing cluster, as numbers.
//
// The cluster used to be assembled out of per-control defaults: a 28 pt avatar in its own 34 pt
// frame beside glyph buttons that carried no frame at all, in a row that baseline-aligned its
// children, with the account control wedged between two glyphs. Upstream's right-hand cluster
// (`webapp/channels/src/components/global_header/right_controls/right_controls.tsx`) is one row of
// equal-weight buttons whose **last** item is `UserAccountMenu`; this file holds the numbers that
// give the native row that shape, plus the launch-argument-gated seam a live test measures it with.
//
// The numbers, and why these:
//
//   * `controlSide` 32 — one frame for every control in the cluster, which is also its hit target.
//     The pointer minimum the card names is 28; 32 is finger-sized and still fits a compact header.
//   * `glyphPointSize` 17 — an SF Symbol at 17 pt has a ~17×17 pt box, which is what the four glyph
//     buttons were already drawn at (a SwiftUI `Label`'s icon takes the body size by default), so
//     naming it changes no glyph: it is the weight the avatar is matched *to*.
//   * `controlSpacing` 6 — one gap between adjacent controls. The distance from the last control to
//     the header's trailing edge is not a second spacing constant: it is `horizontalPadding`, the
//     header's own padding, which is what makes the account control look flush with the edge.
//   * `horizontalPadding` 16 — SwiftUI's default for `padding(.horizontal)`, spelled out because the
//     live test compares the measured trailing gap against this number rather than "the default".
//
// The account control's own numbers live in `AccountMenuControlLayout` (Account/AccountMenuLayout.swift);
// it is 20 pt of avatar in the same 32 pt frame, ~1.2× the glyph box, the ratio upstream's web header
// uses for its 24 px avatar against ~20 px icons.

import SwiftUI

enum ChannelHeaderMetrics {
    /// The frame every control in the trailing cluster occupies — also its hit target.
    static let controlSide: CGFloat = 32
    /// The single gap between adjacent controls in the cluster.
    static let controlSpacing: CGFloat = 6
    /// The SF Symbol point size the info / pinned / Calls / Threads glyphs are drawn at.
    static let glyphPointSize: CGFloat = 17
    /// The header's horizontal padding — the gap from the last control to the trailing edge.
    static let horizontalPadding: CGFloat = 16
    /// The coordinate space the geometry seam reports frames in (anchored at the header's
    /// top-leading corner, so x = 0 is the header's leading edge and the padding is included).
    static let coordinateSpace = "channelHeader"
}

/// The frames the header's controls were laid out at, keyed by the element that produced them.
///
/// Only collected under `-uiTestExposeHeaderGeometry` (`ChannelUITestHook.exposesHeaderGeometry`);
/// a normal launch never attaches a `headerGeometry` probe, so this key stays at its default.
struct ChannelHeaderFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Put a glyph control in the cluster's one frame at the cluster's one glyph weight.
    ///
    /// Every control gets its frame from here rather than from its own padding, which is what makes
    /// the row measurable: `frame` is the hit target *and* the layout box, so adjacent controls are
    /// exactly `controlSpacing` apart and their `midY` is the same number.
    func trailingControl(_ id: String) -> some View {
        font(.system(size: ChannelHeaderMetrics.glyphPointSize))
            .frame(width: ChannelHeaderMetrics.controlSide,
                   height: ChannelHeaderMetrics.controlSide)
            .contentShape(Rectangle())
            .headerGeometry(id)
    }

    /// Publish this control's laid-out frame to the header's geometry seam.
    ///
    /// Identity unless `-uiTestExposeHeaderGeometry` is present, so a normal launch pays no extra
    /// geometry pass. The frame is read in `space` — `ChannelHeaderMetrics.coordinateSpace` by default
    /// — which is what lets the trailing gap and the badge rectangles be compared without mixing
    /// coordinate systems.
    ///
    /// `space` is a parameter because a `Menu`'s label is laid out outside the header's own subtree:
    /// a `.named` lookup that starts inside a label does not find the header's space and falls back
    /// to the window, which would report the badges in one space and the controls in another. The
    /// account control therefore publishes its own space (`AccountMenuControlLayout.coordinateSpace`)
    /// and the seam labels which rectangles came from which.
    @ViewBuilder
    func headerGeometry(_ id: String,
                        in space: String = ChannelHeaderMetrics.coordinateSpace) -> some View {
        if ChannelUITestHook.exposesHeaderGeometry {
            background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ChannelHeaderFramesKey.self,
                        value: [id: proxy.frame(in: .named(space))]
                    )
                }
            )
        } else {
            self
        }
    }
}

/// `-uiTestExposeHeaderGeometry`: the header's measured geometry as one accessibility value.
///
/// The four glyph controls are accessibility elements in their own right, so a UI test reads their
/// frames from the OS. The avatar's two badges are decoration (`accessibilityHidden`), and an `HStack`'s
/// own bounds are not an element at all — so without a seam, "the dot and the emoji do not overlap"
/// and "the last control is `padding` from the trailing edge" would be unmeasurable claims. This
/// element is drawn only under the launch argument, reports the rects the layout actually produced,
/// and is otherwise absent from the tree (a normal launch has no `channelHeader.geometry`).
///
/// **Two spaces, labelled.** The header's own rect and the four glyph controls are measured in the
/// header's space (`space=channelHeader`, x = 0 at the header's leading edge, so `padding` is a number
/// inside that space). The account control's avatar and badges are measured in the control's own
/// space (`controlSpace=accountMenuControl`, x = 0 at the control's top-leading corner) because a
/// `Menu`'s label is laid out outside the header's subtree and a `.named` lookup from inside it falls
/// back to the window. The value says which is which so no reader — or test — has to guess.
struct ChannelHeaderGeometrySeam: View {
    let frames: [String: CGRect]
    let padding: CGFloat

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 6, height: 6)
            .accessibilityElement()
            .accessibilityLabel("Header geometry")
            .accessibilityIdentifier("channelHeader.geometry")
            .accessibilityValue(report)
            // Also logged, because the seam has two readers: an XCUITest (the accessibility value)
            // and a person on a host where the UI-test bundle cannot run (`drawHierarchy` capture
            // plus this line is the whole measurement). Only ever reached under the launch argument.
            .onAppear { Logger.info("Tbc22d0b3", "header geometry \(report)") }
            .onChange(of: report) { _, value in
                Logger.info("Tbc22d0b3", "header geometry \(value)")
            }
    }

    private var report: String {
        // Fixed order so a reader (and the test's parser) sees the cluster left-to-right.
        let keys = ["header", "nativeChannelInfoButton", "nativeChannelPinnedButton",
                    "calls.joinButton", "nativeChannelThreadsButton", "accountMenuButton",
                    "accountMenu.avatar", "accountMenu.presenceDot", "accountMenu.customStatusEmoji"]
        var parts = ["padding=" + Self.number(padding),
                     "space=" + ChannelHeaderMetrics.coordinateSpace,
                     "controlSpace=" + AccountMenuControlLayout.coordinateSpace,
                     "side=" + Self.number(ChannelHeaderMetrics.controlSide)]
        for key in keys { parts.append(key + "=" + Self.rect(frames[key])) }
        return parts.joined(separator: " ")
    }

    private static func rect(_ rect: CGRect?) -> String {
        guard let rect else { return "none" }
        return [rect.minX, rect.minY, rect.width, rect.height]
            .map(number)
            .joined(separator: ",")
    }

    private static func number(_ value: CGFloat) -> String {
        String(format: "%.1f", value)
    }
}
