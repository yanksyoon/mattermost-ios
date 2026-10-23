import Foundation
import Combine
import UserNotifications

/// Per-server mention/unread/expired accounting that drives the app-icon badge.
/// Native counterpart of desktop `src/common/appState.ts` (`AppState`) + the macOS branch of
/// `src/app/system/badge.ts`. Parity row: `AppState` -> `SessionStore`; `TrayIcon + badge` ->
/// `UIApplication.applicationIconBadgeNumber` (driven via `UNUserNotificationCenter.setBadgeCount`).
/// Status: native, T8.
///
/// Desktop flow being mirrored:
///   web app --`unreads-and-mentions`--> AppState.updateUnreadsAndMentionsPerServer(serverId, mentionCount, isUnread)
///   web app --`session_expired`--------> AppState.updateExpired(serverId, expired)
///   any change -> emitStatus() -> UPDATE_APPSTATE_TOTALS(sessionExpired, mentionCount, hasUnread)
///   badge.ts (macOS) -> app.dock.setBadge(mentionCount>0 ? String(mentionCount) : '•' : '!')
///   ServerManager SERVER_REMOVED -> drop that server's state and re-emit.
///
/// iOS renders badges as an integer, not a string, so the two non-numeric desktop glyphs map to
/// 1 (the closest "something needs attention" integer). Divergence documented in docs/t8-build-note.md.
@MainActor
final class SessionStore: ObservableObject {

    /// Per-server state — the three desktop maps (`expired`, `mentionsPerServer`,
    /// `unreadsPerServer`) folded into one struct, keyed by the same server uuid.
    struct ServerState: Equatable {
        var mentionCount: Int = 0
        var isUnread: Bool = false
        var isExpired: Bool = false
    }

    /// Observable per-server map (mirrors desktop `getExpired()` / `getMentionsPerServer()` /
    /// `getUnreadsPerServer()`; iOS has exactly one webview per server, so the desktop
    /// per-view maps collapse into this).
    @Published private(set) var states: [UUID: ServerState] = [:]

    /// Totals over every configured server (desktop UPDATE_APPSTATE_TOTALS arguments).
    @Published private(set) var totalMentions: Int = 0
    @Published private(set) var hasUnread: Bool = false
    @Published private(set) var anyExpired: Bool = false

    /// The app-icon badge number derived from the totals. Desktop macOS badge order:
    /// mentions > unread-dot > expired; iOS integer mapping: mentions, then 1 (dot), then 1 (!).
    @Published private(set) var badgeNumber: Int = 0

    /// "Show unread badge" app setting (desktop `defaultPreferences.showUnreadBadge`, default
    /// true). Changing it recomputes + re-applies the badge (desktop `setUnreadBadgeSetting`).
    @Published var showUnreadBadge: Bool {
        didSet {
            preferences.set(showUnreadBadge, forKey: AppPreferences.Keys.showUnreadBadge)
            recomputeTotals()
        }
    }

    private let preferences: AppPreferences
    private let badgeSetter: BadgeSettable
    private var removalCancellable: AnyCancellable?

    init(preferences: AppPreferences = AppPreferences(),
         badgeSetter: BadgeSettable = SystemBadge()) {
        self.preferences = preferences
        self.badgeSetter = badgeSetter
        // AppPreferences persists Codable as JSON Data, so read the setting through the Codable
        // getter (the raw-Bool primitive would never see a stored `false`).
        self.showUnreadBadge = preferences.get(Bool.self, forKey: AppPreferences.Keys.showUnreadBadge) ?? true
        recomputeTotals()
    }

    // MARK: - Updates (bridge events -> desktop AppState methods)

    /// `unreads-and-mentions` from a server's webview (desktop `updateUnreadsAndMentionsPerServer`).
    func updateMentions(serverID: UUID, mentionCount: Int, isUnread: Bool) {
        var state = states[serverID] ?? ServerState()
        state.mentionCount = max(0, mentionCount)
        state.isUnread = isUnread
        states[serverID] = state
        recomputeTotals()
    }

    /// `session_expired` from a server's webview (desktop `updateExpired`).
    func updateExpired(serverID: UUID, isExpired: Bool) {
        var state = states[serverID] ?? ServerState()
        state.isExpired = isExpired
        states[serverID] = state
        recomputeTotals()
    }

    /// Drop all state for a server — used when its session is signed out (desktop
    /// `clearServer` on SERVER_LOGGED_IN_CHANGED=false).
    func clear(serverID: UUID) {
        states[serverID] = nil
        recomputeTotals()
    }

    /// Drop a removed server's state (desktop AppState SERVER_REMOVED handler). Kept as an
    /// explicit callable so removal can also be bound from the store's events stream.
    func remove(serverID: UUID) {
        states[serverID] = nil
        recomputeTotals()
    }

    /// Subscribe to `ServerStore` removal events so state dies with its server (desktop:
    /// `ServerManager.on(SERVER_REMOVED, ...)`). Re-entrant safe: a later call replaces the
    /// prior subscription.
    func observeServerRemovals(from serverStore: ServerStore) {
        removalCancellable = serverStore.events
            .sink { [weak self] event in
                guard case .removed(let server) = event else { return }
                self?.remove(serverID: server.id)
            }
    }

    // MARK: - Totals + badge

    /// Pure badge math, mirroring desktop `showBadgeOSX` decision order. iOS has no dock
    /// string badge, so the unread-dot and the expired-mark both map to 1.
    nonisolated static func badgeNumber(mentions: Int, hasUnread: Bool, anyExpired: Bool,
                                       showUnreadBadge: Bool) -> Int {
        if mentions > 0 {
            return mentions
        }
        if hasUnread && showUnreadBadge {
            return 1
        }
        if anyExpired {
            return 1
        }
        return 0
    }

    private func recomputeTotals() {
        totalMentions = states.values.reduce(0) { $0 + $1.mentionCount }
        hasUnread = states.values.contains { $0.isUnread }
        anyExpired = states.values.contains { $0.isExpired }
        badgeNumber = Self.badgeNumber(mentions: totalMentions,
                                       hasUnread: hasUnread,
                                       anyExpired: anyExpired,
                                       showUnreadBadge: showUnreadBadge)
        badgeSetter.setBadge(badgeNumber)
    }
}

// MARK: - Badge application

/// Where the badge number goes. Injected so the badge math is unit-testable without the real
/// notification center (desktop `badge.ts` is the equivalent seam — it subscribes to AppState).
protocol BadgeSettable {
    func setBadge(_ count: Int)
}

/// Applies the badge via `UNUserNotificationCenter` (`applicationIconBadgeNumber` is
/// deprecated as of iOS 17; `setBadgeCount` is the supported path on the deployment target).
struct SystemBadge: BadgeSettable {
    func setBadge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count) { error in
            if let error {
                // Badge is non-critical; log and move on (e.g. badge display disabled in
                // system notification settings).
                Logger.debug("Badge", "setBadgeCount failed: \(error.localizedDescription)")
            }
        }
    }
}
