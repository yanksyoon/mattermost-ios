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

    func testCssVariablesDifferPerScheme() {
        let light = ThemeSync.cssVariables(for: .light)
        let dark = ThemeSync.cssVariables(for: .dark)
        XCTAssertNotEqual(light["--center-channel-bg"], dark["--center-channel-bg"])
        XCTAssertEqual(light["--sidebar-bg"], "#ffffff")
        XCTAssertEqual(dark["--sidebar-bg"], "#1f1f1f")
    }

    func testInjectionJavascriptSetsColorSchemeAndVars() {
        let js = ThemeSync.injectionJavascript(for: .dark)
        XCTAssertTrue(js.contains("colorScheme = 'dark'"), "must drive prefers-color-scheme")
        XCTAssertTrue(js.contains("--center-channel-bg"), "must inject the shell-owned css vars")
        XCTAssertTrue(js.contains("'#1f1f1f'"), "must contain the dark theme value")
        XCTAssertTrue(js.contains("mattermostTheme = 'dark'"), "must flag the applied theme")
    }
}