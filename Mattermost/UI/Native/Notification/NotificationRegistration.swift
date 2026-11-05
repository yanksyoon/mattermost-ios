import Foundation

// The OS-side fact the app has never been able to see (card t_e4d5a252).
//
// Why this exists: on macOS a locally-built Catalyst app is re-signed ad-hoc on every install
// (`codesign --force --deep -s -`). That changes the code identity, and the system's notification
// bookkeeping is keyed to it. `UNUserNotificationCenter.notificationSettings()` answers from the
// app's own authorization record, not from the table the delivery daemon reads, so an install can
// read "allowed" in the app while the system has nowhere to put a banner.
//
// ## Which file is the table (measured 2026-11-05, macOS 26.3.1)
//
// There are two candidate stores, and the obvious one is stale on this OS:
//
//   * `~/Library/Preferences/com.apple.ncprefs.plist` — the legacy per-app table. Its mtime is
//     **2026-02-25**, and it contains no app registered after that date: Firefox (installed
//     2026-09-17), ego lite (09-08), Cap (05-13), CapCut (03-15) and this bundle (11-05) are all
//     missing from it, while every one of them has a row in the live store. Reading only this file
//     would report "not registered" for every app installed this year.
//   * `~/Library/Group Containers/group.com.apple.usernoted/Library/Preferences/
//     group.com.apple.usernoted.plist` — the live table, written whenever an app registers or
//     re-registers (mtime 2026-11-05 21:20 during this card). It carries the same `apps` array
//     shape, one dictionary per bundle, with `bundle-id`, `path`, `auth`, `flags` and a `src` list
//     of code requirements. `com.mattermost.ios` **is** in it, with one `src` entry per ad-hoc
//     build this checkout has ever produced.
//
// So the reader prefers the live table and falls back to the legacy one (older macOS, or a host
// that keeps ncprefs current). Only when **both** readable tables lack the bundle is the answer
// `.notRegistered`; when neither can be read it is `.unknown`, which is never rendered as a
// failure — a phone has no such table at all.

/// Whether the OS holds a notification-registration row for this app's bundle.
enum NotificationRegistration: Equatable {
    /// The bundle has a row in a readable system notification table.
    case registered
    /// Every readable table exists and this bundle is **not** in any of them.
    case notRegistered
    /// No table can be read (no such file, an unparsable file, or a platform without one). Never
    /// rendered as a failure.
    case unknown

    /// The token the diagnostics line and the shareable report carry.
    var diagnosticsToken: String {
        switch self {
        case .registered: return "registered"
        case .notRegistered: return "notRegistered"
        case .unknown: return "unknown"
        }
    }
}

/// The seam: an object that can say whether the OS has registered this bundle.
protocol NotificationRegistrationReading {
    func registrationState() -> NotificationRegistration
}

/// The real reader: parses the `apps` array of the system's notification tables.
///
/// `tables` and `bundleIdentifier` are injectable so the parser is unit-tested against fixtures
/// instead of the host's live table.
struct SystemNotificationRegistrationReader: NotificationRegistrationReading {
    /// The tables to consult, in precedence order. The first one that names the bundle answers
    /// `.registered`; `.notRegistered` requires **all readable** tables to lack it.
    var tables: [URL]
    var bundleIdentifier: String

    init(tables: [URL] = SystemNotificationRegistrationReader.defaultTables,
         bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "") {
        self.tables = tables
        self.bundleIdentifier = bundleIdentifier
    }

    /// One-table convenience for tests and for a host that wants a single source.
    init(preferencesURL: URL, bundleIdentifier: String) {
        self.init(tables: [preferencesURL], bundleIdentifier: bundleIdentifier)
    }

    /// The live usernoted table first, then the legacy `ncprefs.plist`.
    ///
    /// Built from the user-domain Library directory rather than `homeDirectoryForCurrentUser` (which
    /// the iOS SDK does not expose): on a Mac — sandbox disabled, as this build is — that is the real
    /// `~/Library`; on iOS it is the app container's Library, where neither file exists, which the
    /// reader reports as `.unknown`.
    static var defaultTables: [URL] {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return [
            library.appendingPathComponent(
                "Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist"),
            library.appendingPathComponent("Preferences/com.apple.ncprefs.plist"),
        ]
    }

    func registrationState() -> NotificationRegistration {
        guard !bundleIdentifier.isEmpty else { return .unknown }
        var readAnyTable = false
        for url in tables {
            guard let data = FileManager.default.contents(atPath: url.path),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let root = plist as? [String: Any],
                  let apps = root["apps"] as? [[String: Any]] else {
                continue
            }
            readAnyTable = true
            if apps.contains(where: { ($0["bundle-id"] as? String) == bundleIdentifier }) {
                return .registered
            }
        }
        return readAnyTable ? .notRegistered : .unknown
    }
}

/// A fixed answer, for tests and for a host that wants to say `.unknown` explicitly.
struct FixedNotificationRegistrationReader: NotificationRegistrationReading {
    var state: NotificationRegistration

    init(_ state: NotificationRegistration) {
        self.state = state
    }

    func registrationState() -> NotificationRegistration { state }
}
