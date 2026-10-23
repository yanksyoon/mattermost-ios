import Foundation
import Combine

/// The shell's user-settable application settings — native counterpart of the desktop
/// `LocalConfiguration` subset that maps onto iOS (design §4d `Settings` row: `SettingsView`
/// port driven by a persisted settings store rather than the renderer's IPC
/// `getLocalConfiguration`/`updateConfiguration`).
///
/// Each property mirrors a desktop `ConfigV4` / `defaultPreferences` key with a real meaning
/// on iOS:
///
///   - `themeSyncing`     == `themeSyncing` (General → CheckSetting/Toggle). When on, the
///     webview's `prefers-color-scheme` follows the server/OS theme decision (`ThemeSync`);
///     shell strings are authored in English today, so the server-theme half of the desktop
///     sync is applied by `ThemeSync` and this flag persists the user's intent.
///   - `downloadHistoryLimit` — the download journal cap (`DownloadHistory.maxRecords`).
///     Exercises the desktop `NumberSetting` (SwiftUI `Stepper`) against a number that
///     genuinely exists in the shell. The desktop's other `NumberSetting` (`viewLimit`,
///     max tabs+windows per server) has **no iOS analog**: iOS keeps exactly one webview per
///     server, so no limit row is shown. Documented in docs/t11-build-note.md.
///   - `appLanguage` == `appLanguage` (Language → SelectSetting/Picker). Persisted for the
///     future i18n pass; the shell is English-only today (desktop marks it beta as well).
///   - `logLevel`      == `logLevel` (Advanced → SelectSetting/Picker). Read by `Logger`
///     to gate `os_log` verbosity (error < warn < info < debug < verbose < silly).
///
/// Desktop rows deliberately not ported (no iOS analog, documented in the build note):
/// `autostart`/`hideOnStart`/`showTrayIcon`/`trayIconTheme`/`minimizeToTray`/
/// `startInFullscreen`/`useNativeTitleBar` (window/tray chrome — iOS has none),
/// `autoCheckForUpdates` (App Store owns updates), `enableMetrics`/`enableSentry` (no
/// analytics SDK mounted), `enableSessionAttributes`, `enableHardwareAcceleration` (always
/// on), `useSpellChecker`/`spellCheckerLocales` (WKWebView text inputs are not
/// shell-controllable), `notifications.bounceIconType`/`flashWindow` (no Dock/taskbar),
/// `downloadLocation` (sandbox fixes files into the app Downloads directory; shown read-only
/// in Settings).
@MainActor
final class AppSettings: ObservableObject {

    /// Keys this store persists under. Stable across releases.
    enum Keys {
        static let themeSyncing = "mm.settings.themeSyncing"
        static let downloadHistoryLimit = "mm.settings.downloadHistoryLimit"
        static let appLanguage = "mm.settings.appLanguage"
        static let logLevel = "mm.settings.logLevel"
    }

    /// Desktop `defaultPreferences.viewLimit` is 15 tabs; our journal default mirrors the
    /// existing `DownloadHistory.maxRecords`.
    static let defaultDownloadHistoryLimit = DownloadHistory.maxRecords
    /// Hard bounds for the Stepper row (min must keep at least one recent row visible).
    static let downloadHistoryLimitRange: ClosedRange<Int> = 1...100

    /// Desktop `defaultPreferences` values: `themeSyncing: true`, `logLevel: 'info'`,
    /// `appLanguage` undefined (system default), `showUnreadBadge: true` (owned by
    /// `SessionStore`).
    static let defaultLogLevel = "info"
    static let availableLogLevels = ["error", "warn", "info", "verbose", "debug", "silly"]

    /// Desktop `localeTranslations`-style list: shell is English-only, so the picker offers
    /// "Use system default" + the handful of locales the web shell ships strings for.
    static let availableLanguages: [(code: String?, label: String)] = [
        (nil, "Use system default"),
        ("en", "English"),
        ("de", "Deutsch"),
        ("es", "Español"),
        ("fr", "Français"),
        ("ja", "日本語"),
        ("ko", "한국어"),
        ("pt", "Português"),
        ("ru", "Русский"),
        ("zh", "中文"),
    ]

    @Published var themeSyncing: Bool {
        didSet {
            preferences.set(themeSyncing, forKey: Keys.themeSyncing)
        }
    }

    /// The retained-download journal cap. Changing it re-trims the journal immediately
    /// (`DownloadHistory.setMaxRecords`) exactly like the desktop re-applies config changes.
    @Published var downloadHistoryLimit: Int {
        didSet {
            preferences.set(downloadHistoryLimit, forKey: Keys.downloadHistoryLimit)
        }
    }

    /// `nil` == system default.
    @Published var appLanguage: String? {
        didSet {
            preferences.set(appLanguage, forKey: Keys.appLanguage)
        }
    }

    @Published var logLevel: String {
        didSet {
            preferences.set(logLevel, forKey: Keys.logLevel)
            Logger.setMinimumLevel(logLevel)
        }
    }

    private let preferences: AppPreferences

    init(preferences: AppPreferences = AppPreferences()) {
        self.preferences = preferences
        // AppPreferences persists Codable as JSON Data, so all reads go through the Codable
        // getter (the raw-String/Bool primitives cannot see stored JSON).
        self.themeSyncing = preferences.get(Bool.self, forKey: Keys.themeSyncing) ?? true
        let storedLimit = preferences.get(Int.self, forKey: Keys.downloadHistoryLimit)
            ?? Self.defaultDownloadHistoryLimit
        self.downloadHistoryLimit = min(max(storedLimit, Self.downloadHistoryLimitRange.lowerBound),
                                        Self.downloadHistoryLimitRange.upperBound)
        self.appLanguage = preferences.get(String.self, forKey: Keys.appLanguage)
        self.logLevel = preferences.get(String.self, forKey: Keys.logLevel) ?? Self.defaultLogLevel
        Logger.setMinimumLevel(self.logLevel)
    }

    /// Human label for the current `appLanguage`, or the desktop placeholder's system-default
    /// fallback when nil.
    var appLanguageLabel: String {
        guard let appLanguage else { return Self.availableLanguages[0].label }
        return Self.availableLanguages.first { $0.code == appLanguage }?.label ?? "Use system default"
    }
}
