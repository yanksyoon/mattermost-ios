import Foundation

// The OS-side fact the app has never been able to see (card t_e4d5a252).
//
// Why this exists: on macOS a locally-built Catalyst app is re-signed ad-hoc on every install
// (`codesign --force --deep -s -`). That changes the code identity, and Notification Center drops
// the bundle's row while `UNUserNotificationCenter.notificationSettings()` can still answer
// `.authorized` from the old identity — or `.notDetermined` on a genuinely fresh install. In both
// cases `UNUserNotificationCenter.add()` accepts the request and the OS silently drops it, so
// "scheduled" in the app's own words proved nothing.
//
// There is no public API for "does Notification Center know this bundle?", so this reads the one
// place the OS writes the answer: `~/Library/Preferences/com.apple.ncprefs.plist`, whose `apps`
// array carries one `{ "bundle-id": …, "path": … }` dictionary per app that has ever been granted
// a row. Measured on this host (2026-11-05): 114 bundle ids, `Mattermost.Desktop` among them, and
// **no** `com.mattermost.ios` — the exact state in which every banner is dropped.
//
// The reader is a protocol seam so tests can answer without a real `ncprefs.plist`, and so a
// non-macOS host (where the file does not exist) answers `.unknown` rather than inventing a
// failure. `.unknown` must never be shown as "not registered": a phone has no such table.

/// Whether the OS holds a notification-registration row for this app's bundle.
enum NotificationRegistration: Equatable {
    /// The bundle has a row in the system's notification table: a request can be presented.
    case registered
    /// The table exists and this bundle is **not** in it: every `add()` is dropped.
    case notRegistered
    /// The table cannot be read (no `ncprefs.plist`, an unparsable file, or a platform that has no
    /// such table). Never rendered as a failure.
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

/// The real reader: parses the `apps` array of `com.apple.ncprefs.plist`.
///
/// `preferencesURL` and `bundleIdentifier` are injectable so the parser is unit-tested against a
/// fixture instead of the host's live table.
struct NCPrefsNotificationRegistrationReader: NotificationRegistrationReading {
    var preferencesURL: URL
    var bundleIdentifier: String

    init(preferencesURL: URL = NCPrefsNotificationRegistrationReader.defaultPreferencesURL,
         bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "") {
        self.preferencesURL = preferencesURL
        self.bundleIdentifier = bundleIdentifier
    }

    /// `~/Library/Preferences/com.apple.ncprefs.plist` for the current user.
    ///
    /// Built from the user-domain Library directory rather than `homeDirectoryForCurrentUser` (which
    /// the iOS SDK does not expose): on a Mac — sandbox disabled, as this build is — that is the real
    /// `~/Library`; on iOS it is the app container's Library, where no such file exists, which the
    /// reader reports as `.unknown`.
    static var defaultPreferencesURL: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return library.appendingPathComponent("Preferences/com.apple.ncprefs.plist")
    }

    func registrationState() -> NotificationRegistration {
        guard !bundleIdentifier.isEmpty,
              let data = FileManager.default.contents(atPath: preferencesURL.path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let root = plist as? [String: Any],
              let apps = root["apps"] as? [[String: Any]] else {
            return .unknown
        }
        let registered = apps.contains { entry in
            (entry["bundle-id"] as? String) == bundleIdentifier
        }
        return registered ? .registered : .notRegistered
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
