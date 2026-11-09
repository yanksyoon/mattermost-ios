import XCTest
@testable import Mattermost

/// Unit tests for the OS notification-table reader (cards t_e4d5a252, t_54798d27).
///
/// The reader answers one question the notification API cannot: does a **readable** system table
/// hold a notification settings row for this bundle? Its input is a file, so these tests write the
/// shapes that matter — a table that names the bundle, a table that does not, a missing table, a
/// table that exists but cannot be read — instead of touching the host's live tables.
///
/// Two measured corrections are pinned here:
///
/// 1. `com.apple.ncprefs.plist` stopped being updated on macOS 26, while
///    `group.com.apple.usernoted.plist` is the live store. The live table is consulted first and the
///    legacy one is the fallback.
/// 2. The live table is inside `group.com.apple.usernoted`, which a LaunchServices-launched app
///    bundle cannot read (`EPERM`). So "no readable table names the bundle" is `.settingsRowAbsent`,
///    not `.notRegistered` — the latter claimed a registration verdict the probe cannot reach. The
///    probe's per-table summary is asserted too, because that detail is what distinguishes "the store
///    was closed to us" from "the store has no row" (t_54798d27).
final class NotificationRegistrationTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("t_e4d5a252-notifreg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    /// Writes a table shaped like both real stores — a root dictionary whose `apps` array is exactly
    /// `bundleIDs` — and returns its URL.
    private func writeTable(bundleIDs: [String], name: String = "table.plist") throws -> URL {
        let root: [String: Any] = [
            "version": 2,
            "apps": bundleIDs.map { ["bundle-id": $0, "path": "/Applications/\($0).app"] },
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// A table path that `fileExists` reports but `contents(atPath:)` cannot read, i.e. the shape of
    /// `group.com.apple.usernoted/...` inside a LaunchServices-launched app. A directory at the path
    /// gives exactly that pair of answers without depending on file-mode quirks of the test host.
    private func unreadableTable(named name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testReadsRegisteredWhenTheBundleHasARow() throws {
        let url = try writeTable(bundleIDs: ["com.apple.mail", "com.mattermost.ios", "Mattermost.Desktop"])
        let reader = SystemNotificationRegistrationReader(preferencesURL: url,
                                                         bundleIdentifier: "com.mattermost.ios")

        XCTAssertEqual(reader.registrationState(), .registered)
    }

    func testReadsSettingsRowAbsentWhenTheTableHasNoRowForTheBundle() throws {
        // The table exists and lists other apps, not this one.
        let url = try writeTable(bundleIDs: ["com.apple.mail", "Mattermost.Desktop"])
        let reader = SystemNotificationRegistrationReader(preferencesURL: url,
                                                         bundleIdentifier: "com.mattermost.ios")

        XCTAssertEqual(reader.registrationState(), .settingsRowAbsent)
    }

    /// The live table answers on its own: a host whose legacy file is stale still reads `.registered`.
    func testLiveTableAloneIsEnough() throws {
        let live = try writeTable(bundleIDs: ["com.apple.mail", "com.mattermost.ios"], name: "live.plist")
        let stale = try writeTable(bundleIDs: ["com.apple.mail"], name: "ncprefs.plist")
        let reader = SystemNotificationRegistrationReader(tables: [live, stale],
                                                         bundleIdentifier: "com.mattermost.ios")

        XCTAssertEqual(reader.registrationState(), .registered)
    }

    /// Older macOS (or a host that keeps ncprefs current): the legacy table is the fallback.
    func testLegacyTableIsUsedWhenTheLiveOneLacksTheBundle() throws {
        let live = try writeTable(bundleIDs: ["com.apple.mail"], name: "live.plist")
        let legacy = try writeTable(bundleIDs: ["com.mattermost.ios"], name: "ncprefs.plist")
        let reader = SystemNotificationRegistrationReader(tables: [live, legacy],
                                                         bundleIdentifier: "com.mattermost.ios")

        XCTAssertEqual(reader.registrationState(), .registered)
    }

    /// No readable table names the bundle: the state the diagnostics must not call "unregistered".
    func testAbsentFromEveryReadableTableIsTheAbsentState() throws {
        let live = try writeTable(bundleIDs: ["com.apple.mail"], name: "live.plist")
        let legacy = try writeTable(bundleIDs: ["Mattermost.Desktop"], name: "ncprefs.plist")
        let reader = SystemNotificationRegistrationReader(tables: [live, legacy],
                                                         bundleIdentifier: "com.mattermost.ios")

        XCTAssertEqual(reader.registrationState(), .settingsRowAbsent)
        XCTAssertEqual(reader.registrationProbe().tableSummary, "live:absent,ncprefs:absent")
    }

    /// The measured macOS 26 shape inside the app: the live store exists but is closed to the
    /// process, and the legacy table is readable and does not name the bundle. That is
    /// `.settingsRowAbsent` with the *reason* visible — never `.unknown` (a table was read) and
    /// never a claim that the OS has no registration.
    func testUnreadableLiveStorePlusAbsentLegacyTableNamesBothFacts() throws {
        let live = try unreadableTable(named: "group.com.apple.usernoted.plist")
        let legacy = try writeTable(bundleIDs: ["Mattermost.Desktop"], name: "com.apple.ncprefs.plist")
        let reader = SystemNotificationRegistrationReader(tables: [live, legacy],
                                                         bundleIdentifier: "com.mattermost.ios")

        XCTAssertEqual(reader.registrationState(), .settingsRowAbsent)
        XCTAssertEqual(reader.registrationProbe().tableSummary, "usernoted:unreadable,ncprefs:absent")
    }

    /// An unreadable table is skipped, not treated as "no row".
    func testUnreadableLiveTableFallsBackToTheLegacyOne() throws {
        let missing = directory.appendingPathComponent("missing-live.plist")
        let legacy = try writeTable(bundleIDs: ["com.mattermost.ios"], name: "ncprefs.plist")
        let reader = SystemNotificationRegistrationReader(tables: [missing, legacy],
                                                         bundleIdentifier: "com.mattermost.ios")

        XCTAssertEqual(reader.registrationState(), .registered)
        XCTAssertEqual(reader.registrationProbe().tableSummary, "missing-live:missing,ncprefs:row")
    }

    /// A bundle id must match exactly: `Mattermost.Desktop` is a different app.
    func testSimilarBundleIdentifiersDoNotCount() throws {
        let url = try writeTable(bundleIDs: ["com.mattermost.ios.beta", "Mattermost.Desktop"])
        let reader = SystemNotificationRegistrationReader(preferencesURL: url,
                                                         bundleIdentifier: "com.mattermost.ios")

        XCTAssertEqual(reader.registrationState(), .settingsRowAbsent)
    }

    func testMissingTableIsUnknownNotAbsent() {
        let missing = directory.appendingPathComponent("does-not-exist.plist")
        let reader = SystemNotificationRegistrationReader(preferencesURL: missing,
                                                         bundleIdentifier: "com.mattermost.ios")

        XCTAssertEqual(reader.registrationState(), .unknown,
                       "a host with no such table (an iPhone) must not be reported as absent")
    }

    func testEmptyBundleIdentifierIsUnknown() throws {
        let url = try writeTable(bundleIDs: ["com.mattermost.ios"])
        let reader = SystemNotificationRegistrationReader(preferencesURL: url, bundleIdentifier: "")

        XCTAssertEqual(reader.registrationState(), .unknown)
    }

    func testUnparsableFileIsUnknown() throws {
        let url = directory.appendingPathComponent("broken.plist")
        try Data("not a plist".utf8).write(to: url)
        let reader = SystemNotificationRegistrationReader(preferencesURL: url,
                                                         bundleIdentifier: "com.mattermost.ios")

        XCTAssertEqual(reader.registrationState(), .unknown)
        XCTAssertEqual(reader.registrationProbe().tableSummary, "broken:unreadable")
    }

    /// Pins the default precedence: live usernoted table first, legacy ncprefs second.
    func testDefaultTablesPreferTheLiveStore() {
        let tables = SystemNotificationRegistrationReader.defaultTables
        XCTAssertEqual(tables.count, 2)
        XCTAssertTrue(tables[0].path.contains("group.com.apple.usernoted"),
                      "the live table must be consulted first, got \(tables[0].path)")
        XCTAssertTrue(tables[1].path.hasSuffix("Preferences/com.apple.ncprefs.plist"))
    }

    /// A fixed reader (the worker tests) still answers the probe with its state and no detail.
    func testFixedReaderAnswersTheProbe() {
        let probe = FixedNotificationRegistrationReader(.settingsRowAbsent).registrationProbe()
        XCTAssertEqual(probe.state, .settingsRowAbsent)
        XCTAssertEqual(probe.tableSummary, "")
    }

    /// The tokens are the diagnostics contract; pin them so a rename cannot silently change reports.
    func testDiagnosticsTokens() {
        XCTAssertEqual(NotificationRegistration.registered.diagnosticsToken, "registered")
        XCTAssertEqual(NotificationRegistration.settingsRowAbsent.diagnosticsToken, "settingsRowAbsent")
        XCTAssertEqual(NotificationRegistration.unknown.diagnosticsToken, "unknown")
    }
}
