import XCTest
@testable import Mattermost

/// Unit tests for `ThemeSync` (desktop `themeManager.ts`) and its colour helpers:
/// the light/dark resolution decision and the injected CSS-variables JS.
final class ThemeSyncTests: XCTestCase {

    // MARK: isLightColor (desktop main/utils.ts HSP parity)

    func testLightColorIsLight() {
        XCTAssertTrue(isLightColor("#ffffff"))
        XCTAssertTrue(isLightColor("#f5f5f5"))
    }

    func testDarkColorIsNotLight() {
        XCTAssertFalse(isLightColor("#1f1f1f"))
        XCTAssertFalse(isLightColor("#000000"))
    }

    func testUnparsableColorDefaultsToLight() {
        // Desktop falls back to `#fff` when the theme has no background.
        XCTAssertTrue(isLightColor(""))
        XCTAssertTrue(isLightColor("garbage"))
    }

    // MARK: ServerTheme.appearance

    func testUsingSystemThemeRequestsSystemAppearance() {
        let theme = ServerTheme(isUsingSystemTheme: true, centerChannelBg: "#1f1f1f")
        XCTAssertEqual(theme.appearance, ThemeAppearance.system)
    }

    func testExplicitCentreChannelBgDrivesLightOrDark() {
        let light = ServerTheme(isUsingSystemTheme: false, centerChannelBg: "#ffffff")
        XCTAssertEqual(light.appearance, ThemeAppearance.light)
        let dark = ServerTheme(isUsingSystemTheme: false, centerChannelBg: "#24272e")
        XCTAssertEqual(dark.appearance, ThemeAppearance.dark)
    }

    // MARK: effectiveScheme

    func testServerThemeLightOverridesSystemDark() {
        let theme = ServerTheme(isUsingSystemTheme: false, centerChannelBg: "#ffffff")
        XCTAssertEqual(
            ThemeSync.effectiveScheme(for: theme, defaultAppearance: .system, systemScheme: .dark),
            ColorScheme.light
        )
    }

    func testServerThemeSystemFallsThroughToOsScheme() {
        let theme = ServerTheme(isUsingSystemTheme: true)
        XCTAssertEqual(
            ThemeSync.effectiveScheme(for: theme, defaultAppearance: .system, systemScheme: .dark),
            ColorScheme.dark
        )
    }

    func testNoServerThemeUsesDefaultAppearance() {
        XCTAssertEqual(
            ThemeSync.effectiveScheme(for: nil, defaultAppearance: .dark, systemScheme: .light),
            ColorScheme.dark
        )
        XCTAssertEqual(
            ThemeSync.effectiveScheme(for: nil, defaultAppearance: .system, systemScheme: .light),
            ColorScheme.light
        )
    }

    // MARK: CSS injection

    /// Regression: injecting only part of Mattermost's palette (sidebar + centre-channel) left
    /// the rest of the server theme intact. On a branded theme that painted white icons on a
    /// white sidebar, washed-out labels and a brand-coloured block over the message list. The
    /// shell declares the colour scheme and nothing else.
    func testShellInjectsNoPaletteOverrides() {
        XCTAssertTrue(ThemeSync.cssVariables(for: .light).isEmpty,
                      "the shell must not override the web app's palette")
        XCTAssertTrue(ThemeSync.cssVariables(for: .dark).isEmpty,
                      "the shell must not override the web app's palette")
    }

    func testInjectionJavascriptSetsColorSchemeOnly() {
        let js = ThemeSync.injectionJavascript(for: .dark)
        XCTAssertTrue(js.contains("colorScheme = 'dark'"), "must drive prefers-color-scheme")
        XCTAssertTrue(js.contains("mattermostTheme = 'dark'"), "must flag the applied theme")
        XCTAssertFalse(js.contains("--sidebar-bg"), "must not touch the theme palette")
        XCTAssertFalse(js.contains("--center-channel-bg"), "must not touch the theme palette")
    }
}