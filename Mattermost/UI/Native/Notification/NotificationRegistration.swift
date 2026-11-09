import Foundation

// The OS-side fact the app has never been able to see (cards t_e4d5a252, t_54798d27).
//
// Why this exists: on macOS a locally-built Catalyst app is re-signed ad-hoc on every install
// (`codesign --force --deep -s -`). That changes the code identity, and the system's notification
// bookkeeping is keyed to it. `UNUserNotificationCenter.notificationSettings()` answers from the
// app's own authorization record, not from the table the delivery daemon reads, so an install can
// read "allowed" in the app while the system has nowhere to put a banner.
//
// ## What the probe reads, and what it can actually see (measured 2026-11-09, macOS 26.3.1)
//
// Two plists carry a per-bundle `apps` array:
//
//   * `~/Library/Group Containers/group.com.apple.usernoted/Library/Preferences/
//     group.com.apple.usernoted.plist` — the live table the delivery daemon maintains. This bundle
//     **is** in it (verified from a Terminal with `plutil`, and the daemon's own database
//     `group.com.apple.usernoted/db2/db` has `app.identifier = com.mattermost.ios`).
//   * `~/Library/Preferences/com.apple.ncprefs.plist` — the legacy table. It stopped being written
//     on 2026-02-25 on this host and does not contain this bundle (only `Mattermost.Desktop`).
//
// **But the app cannot read the live table.** A LaunchServices-launched app bundle (the shipping
// shape of this app, sandbox entitlements or not) gets `EPERM` on everything inside
// `group.com.apple.usernoted` — `fileExists` is true, `isReadableFile` is false, `Data(contentsOf:)`
// fails with `NSCocoaErrorDomain 257` / `errno 1`. The same binary run directly from a terminal can
// read it. `t_54798d27` measured both shapes with an instrumented Catalyst probe. So, inside the
// app, the only readable table is the legacy one, and "this bundle is not in a table I could read"
// is a statement about **what the app can see**, not about whether the OS registered it.
//
// At the same time the app is demonstrably working: the daemon's `record` table holds 12 rows for
// this bundle with `presented = 1`, the most recent on 2026-11-09, and its `app` row carries a
// non-zero badge. So "no row in the readable table" must never be rendered as "nothing can appear".
//
// That is why the failure-ish case is named `.settingsRowAbsent`, not `.notRegistered`: the old
// token claimed something the probe cannot know. The probe also reports, per table, whether the row
// was found, the table was readable and lacked it, was missing, or existed but could not be read —
// `tables=usernoted:unreadable,ncprefs:absent` is the diagnostics shape on this OS.

/// Whether a readable OS notification table holds a row for this app's bundle.
enum NotificationRegistration: Equatable {
    /// A readable table names the bundle.
    case registered
    /// No readable table names the bundle. This says **nothing** about whether the OS registered
    /// the app: on macOS 26 the authoritative table is unreadable from inside an app bundle, so the
    /// only fact established is that no readable settings row exists.
    case settingsRowAbsent
    /// No table could be parsed at all (no such file, an unparsable file, or a platform without
    /// one). Never rendered as a failure.
    case unknown

    /// The token the diagnostics line and the shareable report carry.
    var diagnosticsToken: String {
        switch self {
        case .registered: return "registered"
        case .settingsRowAbsent: return "settingsRowAbsent"
        case .unknown: return "unknown"
        }
    }
}

/// What the probe saw, per table, in one value.
///
/// `tableSummary` is a comma-joined list in the reader's precedence order, e.g.
/// `usernoted:unreadable,ncprefs:absent` or `usernoted:row`. It exists because the *reason* a row
/// was not found is the difference between "the app cannot read the store" and "the store has no
/// row" — the two states t_54798d27 could not tell apart.
struct NotificationRegistrationProbe: Equatable {
    var state: NotificationRegistration
    var tableSummary: String

    init(state: NotificationRegistration, tableSummary: String = "") {
        self.state = state
        self.tableSummary = tableSummary
    }
}

/// The seam: an object that can say what the OS tables hold for this bundle.
protocol NotificationRegistrationReading {
    func registrationState() -> NotificationRegistration
    /// The same answer plus the per-table detail the diagnostics line carries.
    func registrationProbe() -> NotificationRegistrationProbe
}

extension NotificationRegistrationReading {
    /// A reader with no table detail (tests, fixed answers) still reports the state.
    func registrationProbe() -> NotificationRegistrationProbe {
        NotificationRegistrationProbe(state: registrationState())
    }
}

/// The real reader: parses the `apps` array of the system's notification tables.
///
/// `tables` and `bundleIdentifier` are injectable so the parser is unit-tested against fixtures
/// instead of the host's live table.
struct SystemNotificationRegistrationReader: NotificationRegistrationReading {
    /// The tables to consult, in precedence order. The first one that names the bundle answers
    /// `.registered`; `.settingsRowAbsent` means no **readable** table names it.
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
        registrationProbe().state
    }

    func registrationProbe() -> NotificationRegistrationProbe {
        guard !bundleIdentifier.isEmpty else {
            return NotificationRegistrationProbe(state: .unknown)
        }
        var outcomes: [String] = []
        var readAnyTable = false
        for (index, url) in tables.enumerated() {
            let name = Self.tableName(for: url, index: index)
            guard let data = FileManager.default.contents(atPath: url.path) else {
                // A table that exists but cannot be read (EPERM inside a LaunchServices app) is
                // not evidence of absence; record it so the diagnostics say which it was.
                let exists = FileManager.default.fileExists(atPath: url.path)
                outcomes.append("\(name):\(exists ? "unreadable" : "missing")")
                continue
            }
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let root = plist as? [String: Any],
                  let apps = root["apps"] as? [[String: Any]] else {
                outcomes.append("\(name):unreadable")
                continue
            }
            readAnyTable = true
            if apps.contains(where: { ($0["bundle-id"] as? String) == bundleIdentifier }) {
                outcomes.append("\(name):row")
                return NotificationRegistrationProbe(state: .registered,
                                                      tableSummary: outcomes.joined(separator: ","))
            }
            outcomes.append("\(name):absent")
        }
        let state: NotificationRegistration = readAnyTable ? .settingsRowAbsent : .unknown
        return NotificationRegistrationProbe(state: state, tableSummary: outcomes.joined(separator: ","))
    }

    /// A stable short name for the log: the two real tables get their familiar names, a custom
    /// fixture keeps its file stem so a test failure still says which table answered.
    static func tableName(for url: URL, index: Int) -> String {
        switch url.lastPathComponent {
        case "group.com.apple.usernoted.plist": return "usernoted"
        case "com.apple.ncprefs.plist": return "ncprefs"
        default:
            let stem = url.deletingPathExtension().lastPathComponent
            return stem.isEmpty ? "table\(index)" : stem
        }
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
