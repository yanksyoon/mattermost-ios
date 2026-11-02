// T45 — the three accessibility policies that are not Dynamic Type.
//
// Each is a pure function of the user's setting and a design constant, so each is
// unit-tested in `MattermostTests/T45A11yTests.swift` and each appears at its call
// sites through a one-line modifier. Before T45 the repo had **zero** uses of
// `accessibilityReduceMotion` and **zero** of `colorSchemeContrast`: the four
// animations always ran, and every separator kept its light-mode opacity.

import SwiftUI

// MARK: - Reduce Motion

/// Whether an animation is load-bearing.
///
/// Under Reduce Motion, essential motion (a progress indicator, a control that
/// would otherwise look frozen) still runs; incidental motion (a decorative
/// slide, a fade on a row that is already in place) must not.
enum MotionPolicy {
    enum Essence {
        /// Motion carries meaning — it is the only feedback that something is
        /// happening. Kept, but short.
        case essential
        /// Motion decorates a change that is complete with or without it.
        case incidental
    }

    /// The duration an essential animation falls back to under Reduce Motion.
    static let essentialDuration: Double = 0.1

    /// `nil` under Reduce Motion for incidental motion: passing `nil` to
    /// `withAnimation`/`animation(_:value:)` swaps without animating.
    static func animation(_ animation: Animation?,
                          for essence: Essence,
                          reduceMotion: Bool) -> Animation? {
        guard reduceMotion else { return animation }
        switch essence {
        case .essential:
            return .linear(duration: essentialDuration)
        case .incidental:
            return nil
        }
    }

    /// The same decision for a `transition`: `.identity` means the view appears
    /// and disappears in place instead of sliding or fading.
    static func transition(_ transition: AnyTransition,
                           for essence: Essence,
                           reduceMotion: Bool) -> AnyTransition {
        guard reduceMotion, essence == .incidental else { return transition }
        return .identity
    }
}

extension View {
    /// `.animation(_:value:)` that honours Reduce Motion.
    func mmAnimation<V: Equatable>(_ animation: Animation,
                                   value: V,
                                   essence: MotionPolicy.Essence = .incidental,
                                   reduceMotion: Bool) -> some View {
        self.animation(MotionPolicy.animation(animation, for: essence, reduceMotion: reduceMotion),
                       value: value)
    }
}

// MARK: - Increase Contrast

/// Separators and borders under **Increase Contrast**.
///
/// The app draws its own hairlines (row separators, quote bars, code-block
/// borders) at low opacity because a 1 pt line at full strength is heavy at the
/// default setting. Under Increase Contrast those same lines are the ones a
/// low-vision user needs to find the structure of the screen with, so they get
/// stronger — not merely "not transparent".
enum ContrastPolicy {
    /// How much darker a separator gets under Increase Contrast.
    static let increasedMultiplier: Double = 2.2

    /// Border width bump for boxes that are the only cue for a boundary.
    static let increasedBorderWidth: CGFloat = 1.5

    /// Scales a design opacity for the current contrast setting, clamped to 1.
    static func separatorOpacity(_ designOpacity: Double,
                                 contrast: ColorSchemeContrast) -> Double {
        guard contrast == .increased else { return designOpacity }
        return min(1, designOpacity * increasedMultiplier)
    }

    /// Scales a design border width for the current contrast setting.
    static func borderWidth(_ designWidth: CGFloat,
                            contrast: ColorSchemeContrast) -> CGFloat {
        guard contrast == .increased else { return designWidth }
        return max(designWidth, increasedBorderWidth)
    }
}

// MARK: - Line limits

/// Text that was capped to one line so a row stays a row.
///
/// `.lineLimit(1)` is the other half of the Dynamic Type problem: the moment the
/// text style scales, a single line is a truncation, and the card's criterion is
/// that nothing is truncated at AX3+. At an accessibility size the cap is
/// raised instead of removed — a bound keeps a pathological name from pushing the
/// rest of the row off screen, and three lines is more than any label this shell
/// draws needs.
enum LineLimitPolicy {
    static let accessibilityLines = 3

    static func limit(cap: Int, for size: DynamicTypeSize) -> Int {
        size.isAccessibilitySize ? max(cap, accessibilityLines) : cap
    }
}

extension View {
    /// A line cap that relaxes at accessibility text sizes.
    func mmLineLimit(_ cap: Int) -> some View {
        modifier(VariableLineLimit(cap: cap))
    }
}

private struct VariableLineLimit: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize
    let cap: Int

    func body(content: Content) -> some View {
        content.lineLimit(LineLimitPolicy.limit(cap: cap, for: typeSize))
    }
}
