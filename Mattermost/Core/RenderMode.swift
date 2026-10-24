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
    /// Login / auth flow. Today this runs inside the webview (SSO/OAuth); the webview stays
    /// the reference until a native auth screen card lands.
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
    /// T26 ships with zero approvals (no screen has been ported yet), so every surface
    /// defaults to `.web` and the webview remains a fully-working fallback. A screen card
    /// flips its own surface to native-by-default by appending its rawValue here **after**
    /// its `-AV` card has passed — this exact diff is what the validator checks.
    public static let nativeApprovedSurfaces: Set<Surface> = []

    /// The render mode a surface falls back to when no debug override and no remote/config
    /// default applies.
    public static func defaultMode(for surface: Surface) -> SurfaceRenderMode {
        nativeApprovedSurfaces.contains(surface) ? .native : .web
    }
}