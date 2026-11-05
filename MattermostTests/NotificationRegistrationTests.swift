import XCTest
@testable import Mattermost

/// Unit tests for the OS registration reader (card t_e4d5a252).
///
/// The reader's whole job is to answer one question the notification API cannot: does the system
/// hold a notification-registration row for this bundle? Its input is a file, so these tests write
/// the shapes that matter — a table that names the bundle, a table that does not, a missing table —
/// instead of touching the host's live notification tables.
///
/// The two-table precedence is the measured correction to the card: `com.apple.ncprefs.plist`
/// stopped being updated on macOS 26 (absent: every app installed after 2026-02-25), while
/// `group.com.apple.usernoted.plist` is written on every register. So the live table must be enough
/// on its own, the legacy one must still work as a fallback, and only "absent from both readable
/// tables" may be reported as `.notRegistered`.
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

    func testReadsRegisteredWhenTheBundleHasARow() throws {
        let url = try writeTable(bundleIDs: ["com.apple.mail", "com.mattermost.ios", "Mattermost.Desktop"])
        let reader = SystemNotificationRegistrationReader(preferencesURL: url,
                                                         bundleIdentifier: "com.mattermost.ios")

        XCTAssertEqual(reader.registrationState(), .registered)
    }

    func testReadsNotRegisteredWhenTheTableHasNoRowForTheBundle() throws {
        // The failure state the card describes: the table exists and lists other apps, not this one.
        let url = try writeTable(bundleIDs: ["com.apple.mail", "Mattermost.Desktop"])
        let reader = SystemNotificationRegistrationReader(preferencesURL: url,
                                                         bundleIdentifier: "com.mattermost.ios")

        XCTAssertEqual(reader.registrationState(), .notRegistered)
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

    /// `.notRegistered` requires every readable table to lack the bundle.
    func testAbsentFromBothReadableTablesIsNotRegistered() throws {
        let live = try writeTable(bundleIDs: ["com.apple.mail"], name: "live.plist")
        let legacy = try writeTable(bundleIDs: ["Mattermost.Desktop"], name: "ncprefs.plist")
        let reader = SystemNotificationRegistrationReader(tables: [live, legacy],
                                                         bundleIdentifier: "com.mattermost.ios")

        XCTAssertEqual(reader.registrationState(), .notRegistered)
    }

    /// An unreadable table is skipped, not treated as "no row".
    func testUnreadableLiveTableFallsBackToTheLegacyOne() throws {
        let missing = directory.appendingPathComponent("missing-live.plist")
        let legacy = try writeTable(bundleIDs: ["com.mattermost.ios"], name: "ncprefs.plist")
        let reader = SystemNotificationRegistrationReader(tables: [missing, legacy],
                                                         bundleIdentifier: "com.mattermost.ios")

        XCTAssertEqual(reader.registrationState(), .registered)
    }

    /// A bundle id must match exactly: `Mattermost.Desktop` is a different app.
    func testSimilarBundleIdentifiersDoNotCount() throws {
        let url = try writeTable(bundleIDs: ["com.mattermost.ios.beta", "Mattermost.Desktop"])
        let reader = SystemNotificationRegistrationReader(preferencesURL: url,
                                                         bundleIdentifier: "com.mattermost.ios")

        XCTAssertEqual(reader.registrationState(), .notRegistered)
    }

    func testMissingTableIsUnknownNotAbsent() {
        let missing = directory.appendingPathComponent("does-not-exist.plist")
        let reader = SystemNotificationRegistrationReader(preferencesURL: missing,
                                                         bundleIdentifier: "com.mattermost.ios")

        XCTAssertEqual(reader.registrationState(), .unknown,
                       "a host with no such table (an iPhone) must not be reported as unregistered")
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
    }

    /// Pins the default precedence: live usernoted table first, legacy ncprefs second.
    func testDefaultTablesPreferTheLiveStore() {
        let tables = SystemNotificationRegistrationReader.defaultTables
        XCTAssertEqual(tables.count, 2)
        XCTAssertTrue(tables[0].path.contains("group.com.apple.usernoted"),
                      "the live table must be consulted first, got \(tables[0].path)")
        XCTAssertTrue(tables[1].path.hasSuffix("Preferences/com.apple.ncprefs.plist"))
    }

    /// The tokens are the diagnostics contract; pin them so a rename cannot silently change reports.
    func testDiagnosticsTokens() {
        XCTAssertEqual(NotificationRegistration.registered.diagnosticsToken, "registered")
        XCTAssertEqual(NotificationRegistration.notRegistered.diagnosticsToken, "notRegistered")
        XCTAssertEqual(NotificationRegistration.unknown.diagnosticsToken, "unknown")
    }
}
