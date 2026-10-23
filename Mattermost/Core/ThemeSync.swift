import Foundation
import WebKit

// MARK: - Color scheme model

/// The two appearances the shell can render. Native counterpart of the desktop app's
/// light/dark split (desktop `nativeTheme.themeSource` and the `DARK_MODE_CHANGE` config).
enum ColorScheme {
    case light
    case dark

    /// The CSS `color-scheme` literal the page should use (drives form controls/scrollbars
    /// and the `prefers-color-scheme` media query inside the webview).
    var cssValue: String {
        switch self { case .light: return "light"; case .dark: return "dark" }
    }
}

/// What the shell *wants* before resolving a specific server's theme. `system` means "follow
/// the OS / App appearance"; light/dark force the scheme regardless (desktop
/// `themeManager.updateMainViews` sets `nativeTheme.themeSource = light|dark` when a server's
/// theme is not using the system theme).
enum ThemeAppearance {
    case system
    case light
    case dark
}

// MARK: - Server theme (desktop ServerManager server.theme subset)

/// A server-supplied theme, the subset of the Mattermost Theme the shell needs to decide a
/// light/dark appearance. Mirrors desktop `server.theme` (`isUsingSystemTheme` +
/// `centerChannelBg`); the web app owns the full colour palette — the shell only has to pick
/// the right side of `prefers-color-scheme` and set the shell-facing CSS custom properties.
public struct ServerTheme: Codable, Equatable {
    /// When true the web app follows the OS appearance and the shell must not force a scheme.
    public var isUsingSystemTheme: Bool
    /// The `--center-channel-bg` hex (e.g. "#ffffff") used to derive light vs dark when
    /// `isUsingSystemTheme` is false (desktop `updateMainViews` + `isLightColor`).
    public var centerChannelBg: String?

    public init(isUsingSystemTheme: Bool = false, centerChannelBg: String? = nil) {
        self.isUsingSystemTheme = isUsingSystemTheme
        self.centerChannelBg = centerChannelBg
    }

    /// The appearance this server requests: `system` when it follows the OS, otherwise
    /// light/dark derived from its centre-channel background (desktop parity).
    var appearance: ThemeAppearance {
        if isUsingSystemTheme {
            return .system
        }
        guard let bg = centerChannelBg, bg.hasPrefix("#"), bg.count == 7 else {
            // No background to judge by: fall back to the OS like `isUsingSystemTheme`.
            return .system
        }
        return isLightColor(bg) ? .light : .dark
    }
}

/// Port of desktop `src/main/utils.ts` `isLightColor` (HSP model):
/// `hsp = sqrt(0.299*r² + 0.587*g² + 0.114*b²); light when hsp > 127.5`.
func isLightColor(_ hex: String) -> Bool {
    var raw = hex
    if raw.hasPrefix("#") { raw = String(raw.dropFirst()) }
    guard raw.count <= 6, let value = UInt64(raw, radix: 16) else {
        return true // unparsable => treat as light (matches desktop's `? '#fff' :` default)
    }
    let r = Int((value >> 16) & 0xff)
    let g = Int((value >> 8) & 0xff)
    let b = Int(value & 0xff)
    let r2 = Double(r * r) * 0.299
    let g2 = Double(g * g) * 0.587
    let b2 = Double(b * b) * 0.114
    let hsp = (r2 + g2 + b2).squareRoot()
    return hsp > 127.5
}

// MARK: - ThemeSync

/// Native counterpart of desktop `themeManager.ts`: keeps the shell in sync with each server's
/// theme and injects CSS into the webview so the hosted page renders the right appearance.
/// Parity row: `ThemeManager` -> `ThemeSync` (observe appearance -> inject CSS vars /
/// `prefers-color-scheme` into each webview). Status: native, Phase 2.
///
/// The desktop `ThemeManager` decides a light/dark theme source (`updateMainViews`) and pushes
/// it to every view (IPC `UPDATE_THEME`/`RESET_THEME`/`DARK_MODE_CHANGE`). Our webview has no
/// `prefers-color-scheme` <-> themeSource IPC channel, so `ThemeSync` applies the *same*
/// decision natively: it computes the effective `ColorScheme` from the OS appearance and the
/// active server's `ServerTheme`, sets it on the webview, and injects a small CSS-variables
/// block (`color-scheme` + the shell-facing `--center-channel-*`/`--sidebar-*` overrides) via
/// `evaluateJavaScript` — the JS-string equivalent of the desktop's IPC theme push.
///
/// Security boundary: the injected CSS is a fixed, allow-listed set of custom properties the
/// shell controls; it never routes page input back into the shell (mirrors how the desktop
/// preload only exposes the theme channel, never raw config).
final class ThemeSync: ObservableObject {

    /// The scheme currently applied to attached webviews.
    @Published private(set) var scheme: ColorScheme = .light

    /// The appearance the shell should resolve to when a server has no `ServerTheme.z`.
    @Published var defaultAppearance: ThemeAppearance = .system

    init(scheme: ColorScheme = .light, defaultAppearance: ThemeAppearance = .system) {
        self.scheme = scheme
        self.defaultAppearance = defaultAppearance
    }

    // MARK: Resolution

    /// The effective scheme for a webview: the server's requested appearance if it does not
    /// follow the system, otherwise the shell's default (which itself follows the OS when
    /// `defaultAppearance == .system`). Pure and unit-testable.
    static func effectiveScheme(for theme: ServerTheme?, defaultAppearance: ThemeAppearance,
                                systemScheme: ColorScheme) -> ColorScheme {
        let requested = theme?.appearance ?? defaultAppearance
        switch requested {
        case .light: return .light
        case .dark: return .dark
        case .system: return systemScheme
        }
    }

    // MARK: CSS injection

    /// The CSS custom properties the shell owns, as a fixed map per scheme. Everything here is
    /// allow-listed; the web app's own theme owns the rest. Grep: these mirror the desktop
    /// `centerChannelBg` / `sidebarBg` decisions without shipping the whole palette.
    static func cssVariables(for scheme: ColorScheme) -> [String: String] {
        switch scheme {
        case .light:
            return [
                "--center-channel-bg": "#ffffff",
                "--center-channel-color": "#1f1f1f",
                "--sidebar-bg": "#ffffff",
                "--sidebar-text": "#1f1f1f",
            ]
        case .dark:
            return [
                "--center-channel-bg": "#1f1f1f",
                "--center-channel-color": "#ffffff",
                "--sidebar-bg": "#1f1f1f",
                "--sidebar-text": "#ffffff",
            ]
        }
    }

    /// A JS statement that sets `color-scheme` and the shell-owned CSS custom properties on
    /// `:root`, then re-emits `prefers-color-scheme` for any live media-query listener. Returns
    /// the exact expression `evaluateJavaScript` will run; injectable and unit-testable.
    static func injectionJavascript(for scheme: ColorScheme) -> String {
        let vars = Self.cssVariables(for: scheme)
        var props = String()
        for (name, value) in vars {
            props += "'\(name)': '\(value)', "
        }
        return "(() => { document.documentElement.style.colorScheme = '\(scheme.cssValue)'; "
                    + "const s = document.documentElement.style; "
                    + "for (const [k,v] of Object.entries({ \(props)})) s.setProperty(k, v); "
                    + "document.documentElement.dataset.mattermostTheme = '\(scheme.cssValue)'; })();"
    }

    // MARK: Application

    /// Resolve the scheme for `theme` and inject it into `webView`. This is the webview-facing
    /// analogue of the desktop `view.send(UPDATE_THEME|DARK_MODE_CHANGE, ...)`.
    @MainActor
    func apply(to webView: WKWebView, theme: ServerTheme? = nil,
               systemScheme: ColorScheme = ColorScheme.light) {
        scheme = Self.effectiveScheme(for: theme, defaultAppearance: defaultAppearance,
                                      systemScheme: systemScheme)
        webView.evaluateJavaScript(Self.injectionJavascript(for: scheme))
    }

    /// Explicit scheme override (used when the shell itself drives appearance, no server theme).
    @MainActor
    func applyScheme(_ scheme: ColorScheme, to webView: WKWebView) {
        self.scheme = scheme
        webView.evaluateJavaScript(Self.injectionJavascript(for: scheme))
    }
}