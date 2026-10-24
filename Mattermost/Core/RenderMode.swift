import Foundation

/// A distinct renderable region of the Mattermost client (T26 dual-render harness).
///
/// Each surface can render either **natively** — a SwiftUI "screen card" driven by the
/// Mattermost REST API v4 + WebSocket v4 (Path B) — or through the **webview escape hatch**
/// — the web app in `WKWebView` (Path A) — independently of every other surface.
///
/// Port role: `Surface` is the key of the per-surface dual-render switch. A screen card names
/// its own surface when it opts in; there is deliberately no global "port everything" switch.
/// See `docs/dual-render.md` for the opt-in contract.
public enum Surface: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Login / auth flow. SSO/OAuth still runs inside the webview (the IdP hand-off), while the
    /// sign-in form, the MFA step and the expiry banner are the native S01/S02/S03 cards — native by
    /// default since the T31-AV approval (T31-R).
    case auth
    /// Left channel/team sidebar.
    case sidebar
    /// The main channel view: channel header + post list. This is the surface the single
    /// per-server WKWebView pane maps to in the current Path A shell.
    case channelView
    /// The message composer (new post).
    case composer
    /// Threads ("view thread" / replies).
    case threads
    /// Global / in-channel search.
    case search
    /// The user's own profile.
    case profile
    /// Mentions / activity list.
    case activity
    /// Settings. The shell's settings are already a native SwiftUI `SettingsView`.
    case settings
    /// Channel info / members panel.
    case channelInfo
    /// Mattermost Calls.
    case calls
    /// Plugin surfaces (Boards, Playbooks, custom slash-apps).
    case plugins

    public var id: String { rawValue }

    /// Human-readable title for the Surface inspector (debug-only).
    public var title: String {
        switch self {
        case .auth: return "Auth / Login"
        case .sidebar: return "Sidebar"
        case .channelView: return "Channel view"
        case .composer: return "Composer"
        case .threads: return "Threads"
        case .search: return "Search"
        case .profile: return "Profile"
        case .activity: return "Activity"
        case .settings: return "Settings"
        case .channelInfo: return "Channel info"
        case .calls: return "Calls"
        case .plugins: return "Plugins"
        }
    }
}

/// How a `Surface` renders right now. The switch is binary: the webview, or a native screen.
public enum SurfaceRenderMode: String, CaseIterable, Codable, Sendable {
    /// The webview renders this surface (the web app — Path A fallback).
    case web
    /// A native SwiftUI screen card renders this surface (Path B).
    case native
}

/// Compile-time render defaults, including the native-by-default approval registry.
///
/// This is the **single structural gate** that prevents a screen card from silently shipping
/// native-by-default: a surface is `native` *by default* only if it is listed in
/// `nativeApprovedSurfaces`, and adding to that set is the one edit the paired `-AV`
/// adversarial validator audits. Everything not approved defaults to `.web`, so an unapproved
/// card can never take its surface native without the validator seeing the change.
public enum SurfaceDefaults {

    /// Surfaces whose native screen card has passed its `-AV` adversarial validation.
    ///
    /// **Approval ledger** (each entry is one `-AV` sign-off, and the doc row it cites):
    ///
    /// | Surface | Approved by | Evidence |
    /// |---|---|---|
    /// | `.auth` | T31-AV (`t_c57a7551`, verdict `PASS-WITH-FINDINGS`, F8 = approve) | `docs/t31r-patch-note.md` §5; findings F1–F4 repaired by T31-R before the flip was treated as final |
    ///
    /// Everything not listed here defaults to `.web`, so an unapproved card can never ship its
    /// surface native. A card flips its own surface to native-by-default by appending its rawValue
    /// **after** its `-AV` card has passed, in its own clearly-labelled commit — that exact diff is
    /// what the next validator audits (`scripts/verify-dual-render-gates.sh` gate 5 fails on a
    /// non-empty registry unless `--allow-approved-registry` accompanies the approval commit).
    public static let nativeApprovedSurfaces: Set<Surface> = [.auth]

    /// Surfaces whose native card renders the *entire* per-server work area — every region the
    /// one-per-server WKWebView paints (sidebar, channel header, post list, composer, RHS). Empty:
    /// no card owns a pane yet. `paneOwningSurfaces ⊆ nativeApprovedSurfaces` is enforced by
    /// `scripts/verify-dual-render-gates.sh`; appending here is an `-AV` claim, not a build flag.
    ///
    /// Pane ownership is the *third* condition of the webview release policy
    /// (`docs/dual-render.md` §12.1): a surface may only trigger `ViewStore.release(...)` when its
    /// native card really replaces the webview, which is a stronger claim than "a screen card
    /// renders this region" and therefore stricter than `nativeApprovedSurfaces` — the subset
    /// check in the gate script is what keeps the two from drifting.
    public static let paneOwningSurfaces: Set<Surface> = []

    /// The surface whose native branch takes the webview's place — the region the single
    /// per-server `WKWebView` maps to, and therefore the surface the release policy watches.
    ///
    /// Named once here so no view or store hard-codes `.channelView` (the resolver's `-surfaceMode`
    /// tests and `ContentView`'s `SurfaceHost` both read this). Reassigned only by a card that moves
    /// the pane host, which is a structural change, not a per-surface decision.
    public static let paneHostSurface: Surface = .channelView

    /// Launch-argument alias for `paneHostSurface` (T30).
    ///
    /// The T30 card's acceptance criterion spells its flag `-surfaceMode shell=native`, because the
    /// thing that card mounts is the *shell* — the native equivalent of the whole workspace chrome
    /// (sidebar + channel view + threads), which is exactly what the pane host surface maps to. The
    /// alias exists so that flag works as written, and it is **launch-only**: there is no
    /// `Surface.shell` case (the 12 surfaces are the inventory-driven render regions, and a "shell"
    /// region would duplicate `channelView` in the inspector, in `mm.surfaceModes`, and in the
    /// approval registry). It is parsed in the DEBUG-only launch tier (`parseLaunchOverrides`), so
    /// it cannot steer a Release build — same rule as every other launch override.
    public static let paneHostAlias = "shell"

    /// The render mode a surface falls back to when no debug override and no remote/config
    /// default applies.
    public static func defaultMode(for surface: Surface) -> SurfaceRenderMode {
        nativeApprovedSurfaces.contains(surface) ? .native : .web
    }
}