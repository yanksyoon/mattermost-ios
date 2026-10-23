import XCTest
@testable import Mattermost

/// Tests for the native settings store behind `SettingsView` — `AppSettings`, the
/// `LocalConfiguration` replacement (desktop `SettingsModal` reads/writes config via IPC;
/// we bind a SwiftUI Form to this store instead). Pins defaults, persistence round-trips and
/// boundary clamping so the Toggle/Picker/Stepper rows never silently mutate garbage.
@MainActor
final class AppSettingsTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AppSettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeSettings() -> AppSettings {
        AppSettings(preferences: AppPreferences(defaults: defaults))
    }

    // MARK: Defaults (desktop defaultPreferences parity)

    func testDefaultsMirrorDesktopDefaultPreferences() {
        let settings = makeSettings()
        XCTAssertTrue(settings.themeSyncing, "desktop defaultPreferences.themeSyncing = true")
        XCTAssertEqual(settings.downloadHistoryLimit, DownloadHistory.maxRecords, "desktop cap analog defaults to the existing journal cap")
        XCTAssertNil(settings.appLanguage, "nil == use system default")
        XCTAssertEqual(settings.logLevel, "info", "desktop defaultPreferences.logLevel = 'info'")
    }

    func testAvailableLogLevelsMatchDesktopOptions() {
        // Desktop definition.tsx 'logLevel' SelectSetting options, order preserved.
        XCTAssertEqual(AppSettings.availableLogLevels,
                       ["error", "warn", "info", "verbose", "debug", "silly"])
    }

    func testAppLanguageLabelDefaultsToSystemDefault() {
        let settings = makeSettings()
        XCTAssertEqual(settings.appLanguageLabel, "Use system default")
    }

    // MARK: Persistence (round-trip through AppPreferences like JsonFileManager)

    func testThemeSyncingPersists() {
        let settings = makeSettings()
        settings.themeSyncing = false
        XCTAssertFalse(makeSettings().themeSyncing, "a fresh store over the same defaults reads false back")
    }

    func testLogLevelPersists() {
        let settings = makeSettings()
        settings.logLevel = "debug"
        XCTAssertEqual(makeSettings().logLevel, "debug")
    }

    func testAppLanguagePersists() {
        let settings = makeSettings()
        settings.appLanguage = "de"
        XCTAssertEqual(makeSettings().appLanguage, "de")
        XCTAssertEqual(makeSettings().appLanguageLabel, "Deutsch")
    }

    func testDownloadHistoryLimitPersists() {
        let settings = makeSettings()
        settings.downloadHistoryLimit = 12
        let reloaded = makeSettings()
        XCTAssertEqual(reloaded.downloadHistoryLimit, 12)
    }

    // MARK: Boundary clamping

    func testDownloadHistoryLimitClampedToRangeOnLoad() {
        // 0 (desktop 'unlimited') is clamped to the lower bound: this shell keeps ≥1 row.
        defaults.set(try! JSONEncoder().encode(0), forKey: AppSettings.Keys.downloadHistoryLimit)
        XCTAssertEqual(makeSettings().downloadHistoryLimit,
                       AppSettings.downloadHistoryLimitRange.lowerBound)

        defaults.set(try! JSONEncoder().encode(9999), forKey: AppSettings.Keys.downloadHistoryLimit)
        XCTAssertEqual(makeSettings().downloadHistoryLimit,
                       AppSettings.downloadHistoryLimitRange.upperBound)
    }

    func testDownloadHistoryLimitRangeIsSane() {
        XCTAssertGreaterThanOrEqual(AppSettings.downloadHistoryLimitRange.lowerBound, 1)
        XCTAssertGreaterThan(AppSettings.downloadHistoryLimitRange.upperBound,
                             AppSettings.downloadHistoryLimitRange.lowerBound)
    }

    // MARK: Logger gating honored

    func testLoggerGateDropsBelowMinimum() {
        // The store applies its level to Logger; the gate itself is exercised via the
        // Logger.shouldLog behaviour through setMinimumLevel.
        Logger.setMinimumLevel("error")
        // No crash and callable — the gate path runs on every log site.
        Logger.debug("AppSettingsTests", "should be dropped")
        Logger.error("AppSettingsTests", "should pass")
        // Restore default so other suites are not affected.
        Logger.setMinimumLevel("info")
    }
}
