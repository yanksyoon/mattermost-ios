// T45 — Dynamic Type for the native surfaces.
//
// The problem this replaces: 49 pieces of *user text* in the native shell were
// pinned with `.font(.system(size: 13))`. A fixed point size is not scaled by
// Dynamic Type at all, so at AX3 (and at AX5, which is twice that) those lines
// kept their designed size while the semantic styles around them grew. A
// two-scale layout at accessibility sizes is a clipped or overlapping layout,
// not merely small text.
//
// The replacement keeps the designed point size as the *input* — the numbers in
// the call sites are the ones the component map specifies — and resolves it to
// the nearest Dynamic Type text style, which the system then scales:
//
//     .font(.system(size: 13, weight: .semibold))   // frozen at 13 pt
//     .font(.scaled(13, weight: .semibold))         // footnote, semibold
//
// `TypeRole.nearest(to:)` is the whole mapping, it is pure, and
// `MattermostTests/T45A11yTests.swift` pins it (totality, monotonicity, and the
// exact sizes this app uses).
//
// Two things deliberately stay in fixed points, and the inventory test enforces
// that the list is exactly these two kinds:
//
//   * **glyph geometry** — an `Image(systemName:)` point size is a drawn
//     dimension inside a fixed control (an 11 pt chevron, a 34 pt toolbar
//     button). Scaling it alone clips it in its container. The large standalone
//     empty-state glyphs are the exception and use `.scaledSymbol`, which keeps
//     the designed size at the default setting and scales from there.
//   * **avatar initials** — sized from the circle (`size * 0.45`), so they must
//     track the circle. Apple does not scale avatars either.

import SwiftUI

/// The Dynamic Type text styles this app designs against, ordered by size.
///
/// `headline` is omitted on purpose: it is `body` at a heavier weight, and this
/// API takes weight separately, so a role for it would be a second way to say
/// the same thing.
enum TypeRole: String, CaseIterable, Hashable {
    case caption2
    case caption
    case footnote
    case subheadline
    case callout
    case body
    case title3
    case title2
    case title
    case largeTitle

    /// The style the system scales from — the only part that reaches SwiftUI.
    var textStyle: Font.TextStyle {
        switch self {
        case .caption2: return .caption2
        case .caption: return .caption
        case .footnote: return .footnote
        case .subheadline: return .subheadline
        case .callout: return .callout
        case .body: return .body
        case .title3: return .title3
        case .title2: return .title2
        case .title: return .title
        case .largeTitle: return .largeTitle
        }
    }

    /// The point size the style renders at the default (`.large`) setting, on the
    /// iOS text-style table. These are the numbers `nearest(to:)` measures against,
    /// so a caller's designed size is preserved at default and scales from there.
    var defaultPointSize: CGFloat {
        switch self {
        case .caption2: return 11
        case .caption: return 12
        case .footnote: return 13
        case .subheadline: return 15
        case .callout: return 16
        case .body: return 17
        case .title3: return 20
        case .title2: return 22
        case .title: return 28
        case .largeTitle: return 34
        }
    }

    /// Position in the ramp, ascending. Used to order roles without relying on
    /// `allCases` order (a test asserts the two agree).
    var rank: Int {
        switch self {
        case .caption2: return 0
        case .caption: return 1
        case .footnote: return 2
        case .subheadline: return 3
        case .callout: return 4
        case .body: return 5
        case .title3: return 6
        case .title2: return 7
        case .title: return 8
        case .largeTitle: return 9
        }
    }

    /// The role whose default size is closest to `pointSize`.
    ///
    /// Ties resolve to the **smaller** role: a designed 14 pt is exactly between
    /// `footnote` (13) and `subheadline` (15), and growing text that the design
    /// did not ask for is the worse error of the two — the caller can always ask
    /// for the bigger role by naming it.
    static func nearest(to pointSize: CGFloat) -> TypeRole {
        var best = TypeRole.body
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for role in TypeRole.allCases.sorted(by: { $0.rank < $1.rank }) {
            let distance = abs(role.defaultPointSize - pointSize)
            if distance < bestDistance {
                best = role
                bestDistance = distance
            }
        }
        return best
    }
}

extension Font {
    /// A Dynamic Type text style for text designed at `pointSize`.
    ///
    /// Replacement for `.system(size:)` on `Text`/`AttributedString`. The
    /// designed size survives at the default setting (within a point); from
    /// there the style scales with the user's setting, up to AX5.
    static func scaled(_ pointSize: CGFloat,
                       weight: Font.Weight? = nil,
                       design: Font.Design? = nil) -> Font {
        .system(TypeRole.nearest(to: pointSize).textStyle, design: design, weight: weight)
    }
}

extension View {
    /// Keeps an SF Symbol's designed point size at the default text size, then
    /// scales it with the user's setting — for glyphs that stand alone (empty
    /// states, big toolbar buttons) rather than inside a fixed control.
    func scaledSymbol(_ pointSize: CGFloat, weight: Font.Weight? = nil) -> some View {
        modifier(ScaledSymbolModifier(pointSize: pointSize, weight: weight))
    }

    /// A width chosen for the default text size that grows with the user's
    /// setting.
    ///
    /// For the columns that hold text or a scaled glyph: a 36 pt timestamp
    /// gutter is right for 11 pt type and clips "3:47 PM" at AX3, and a 16 pt
    /// icon column clips a `footnote` symbol once `footnote` is 24 pt. Grows by
    /// the same metric as body text, capped at 2.6x so one row cannot eat the
    /// whole timeline.
    func scaledColumn(width: CGFloat, alignment: Alignment = .center) -> some View {
        modifier(ScaledColumnModifier(width: width, alignment: alignment))
    }
}

private struct ScaledSymbolModifier: ViewModifier {
    @ScaledMetric private var pointSize: CGFloat
    private let weight: Font.Weight?

    init(pointSize: CGFloat, weight: Font.Weight?) {
        _pointSize = ScaledMetric(wrappedValue: pointSize, relativeTo: .body)
        self.weight = weight
    }

    func body(content: Content) -> some View {
        content.font(.system(size: pointSize, weight: weight ?? .regular))
    }
}

private struct ScaledColumnModifier: ViewModifier {
    @ScaledMetric private var scaled: CGFloat
    private let designed: CGFloat
    private let alignment: Alignment

    init(width: CGFloat, alignment: Alignment) {
        designed = width
        self.alignment = alignment
        _scaled = ScaledMetric(wrappedValue: width, relativeTo: .body)
    }

    func body(content: Content) -> some View {
        content.frame(width: min(scaled, designed * 2.6), alignment: alignment)
    }
}
