import XCTest
@testable import Mattermost

/// Unit tests for the OS registration reader (card t_e4d5a252).
///
/// The reader's whole job is to answer one question the notification API cannot: does macOS hold a
/// notification-registration row for this bundle? Its input is a file, so these tests write the two
/// shapes that matter — a table that names the bundle, and a table that does not — instead of
/// touching the host's live `ncprefs.plist`.
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

    /// Writes a `com.apple.ncprefs.plist`-shaped table whose `apps` array is exactly `bundleIDs`.
    private func writeTable(bundleIDs: [String]) throws -> URL {
        let root: [String: Any] = [
            "version": 2,
            "apps": bundleIDs.map { ["bundle-id": $0, "path": "/Applications/\($0).app"] },
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        let url = directory.appendingPathComponent("com.apple.ncprefs.plist")
        try data.write(to: url)
        return url
    }

    func testReadsRegisteredWhenTheBundleHasARow() throws {
        let url = try writeTable(bundleIDs: ["com.apple.mail", "com.mattermost.ios", "Mattermost.Desktop"])
        let reader = NCPrefsNotificationRegistrationReader(preferencesURL: url,
                                                          bundleIdentifier: "com.mattermost.ios")

        XCTAssertEqual(reader.registrationState(), .registered)
    }

    func testReadsNotRegisteredWhenTheTableHasNoRowForTheBundle() throws {
        // The measured failure state: the table exists and lists other apps, but not this bundle.
        let url = try writeTable(bundleIDs: ["com.apple.mail", "Mattermost.Desktop"])
        let reader = NCPrefsNotificationRegistrationReader(preferencesURL: url,
                                                          bundleIdentifier: "com.mattermost.ios")

        XCTAssertEqual(reader.registrationState(), .notRegistered)
    }

    /// A bundle id must match exactly: `Mattermost.Desktop` is a different app.
    func testSimilarBundleIdentifiersDoNotCount() throws {
        let url = try writeTable(bundleIDs: ["com.mattermost.ios.beta", "Mattermost.Desktop"])
        let reader = NCPrefsNotificationRegistrationReader(preferencesURL: url,
                                                          bundleIdentifier: "com.mattermost.ios")

        XCTAssertEqual(reader.registrationState(), .notRegistered)
    }

    func testMissingTableIsUnknownNotAbsent() {
        let missing = directory.appendingPathComponent("does-not-exist.plist")
        let reader = NCPrefsNotificationRegistrationReader(preferencesURL: missing,
                                                          bundleIdentifier: "com.mattermost.ios")

        XCTAssertEqual(reader.registrationState(), .unknown,
                       "a host with no such table (an iPhone) must not be reported as unregistered")
    }

    func testEmptyBundleIdentifierIsUnknown() throws {
        let url = try writeTable(bundleIDs: ["com.mattermost.ios"])
        let reader = NCPrefsNotificationRegistrationReader(preferencesURL: url, bundleIdentifier: "")

        XCTAssertEqual(reader.registrationState(), .unknown)
    }

    func testUnparsableFileIsUnknown() throws {
        let url = directory.appendingPathComponent("broken.plist")
        try Data("not a plist".utf8).write(to: url)
        let reader = NCPrefsNotificationRegistrationReader(preferencesURL: url,
                                                          bundleIdentifier: "com.mattermost.ios")

        XCTAssertEqual(reader.registrationState(), .unknown)
    }

    /// The tokens are the diagnostics contract; pin them so a rename cannot silently change reports.
    func testDiagnosticsTokens() {
        XCTAssertEqual(NotificationRegistration.registered.diagnosticsToken, "registered")
        XCTAssertEqual(NotificationRegistration.notRegistered.diagnosticsToken, "notRegistered")
        XCTAssertEqual(NotificationRegistration.unknown.diagnosticsToken, "unknown")
    }
}
