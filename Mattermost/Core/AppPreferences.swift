import Foundation

/// Generic atomic persistence base over `UserDefaults` (native counterpart of desktop
/// `JsonFileManager.ts`). Parity row: `JsonFileManager` -> `AppPreferences` / `UserDefaults`
/// atomic store. Status: native, P0.
///
/// Uses `JSONEncoder`/`JSONDecoder` with sorted keys and `.fullPrecision` float strategy for
/// deterministic, stable output. Represents the "write file atomically" behaviour of the
/// desktop `JsonFileManager` (which writes via tmp + rename); `UserDefaults` gives atomicity
/// for free at this layer.
public final class AppPreferences {

    /// Keys used by the shell. Keep stable across releases.
    public enum Keys {
        public static let servers = "mm.servers"
        public static let appVersion = "mm.app.version"
        public static let onboardingCompleted = "mm.onboarding.completed"
        /// The persistent download journal (`[DownloadRecord]`), keyed for `DownloadHistory`.
        public static let downloadsHistory = "mm.downloads.history"
        /// "Show unread badge" app setting (desktop `defaultPreferences.showUnreadBadge`, default true).
        public static let showUnreadBadge = "mm.settings.showUnreadBadge"
        /// Whether the shell has ever asked for notification authorization (asked once per install;
        /// iOS itself only presents the system prompt once, and desktop permission requests are
        /// deferred to the first mention — see T8 `NotificationWorker`).
        public static let notificationPermissionRequested = "mm.notifications.permissionRequested"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Primitive read/write (generic Codable via JSON)

    public func set<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else {
            Logger.error("AppPreferences", "Failed to encode value for key \(key)")
            return
        }
        defaults.set(data, forKey: key)
        defaults.synchronize()
    }

    public func get<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    public func removeObject(forKey key: String) {
        defaults.removeObject(forKey: key)
    }

    /// Whether a value has ever been written for `key` (distinguishes \"explicitly empty\" from
    /// \"never touched\"). Lets the shell seed defaults only on a true first run.
    public func contains(_ key: String) -> Bool {
        defaults.object(forKey: key) != nil
    }

    public func bool(forKey key: String, default defaultValue: Bool = false) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }

    public func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }
}