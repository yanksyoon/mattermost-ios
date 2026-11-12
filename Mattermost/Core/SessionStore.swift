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
/// iOS renders badges as an integer, not a string, so the two non-numeric desktop glyphs are the last
/// resort: `!` maps to 1, and the unread dot maps to **the number of unread messages** when this client
/// knows it (card `t_93eca948` — the sidebar rows count now, and the icon must not be the one place
/// still saying "something"), falling back to 1 only when the read-out said nothing more than "unread".
/// Divergence documented in docs/t8-build-note.md and docs/t_93eca948-build-note.md.
@MainActor
final class SessionStore: ObservableObject {

    /// Per-server state — the three desktop maps (`expired`, `mentionsPerServer`,
    /// `unreadsPerServer`) folded into one struct, keyed by the same server uuid.
    struct ServerState: Equatable {
        var mentionCount: Int = 0
        /// Unread **messages** for this server, when the client actually knows the number
        /// (`GET /users/me/teams/unread`'s `msg_count`). `nil` is "something is unread, but this
        /// read-out did not say how many" — the webview's `unreads-and-mentions` event carries no
        /// message count, and the badge falls back to desktop's dot (`1`) rather than inventing one.
        var unreadMessages: Int? = nil
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

    /// Unread **messages** across servers, as far as the client knows them (a server whose read-out
    /// carried no number contributes 1 — see `recomputeTotals`). Card `t_93eca948`: the icon shows
    /// this number instead of desktop's dot whenever it is available.
    @Published private(set) var totalUnreadMessages: Int = 0

    /// The app-icon badge number derived from the totals. Desktop macOS badge order:
    /// mentions > unread > expired; the unread step is a **count** here, and integer `1` only when the
    /// number is unknown or the expired mark (`!`) is all there is.
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
    ///
    /// `unreadMessages` is optional because that bridge event carries only `isUnread` + the mention
    /// count: passing `nil` leaves whatever number the last native counter read supplied, and a
    /// server that has never had one keeps `nil` (the app icon falls back to desktop's dot, `1`).
    func updateMentions(serverID: UUID,
                        mentionCount: Int,
                        unreadMessages: Int? = nil,
                        isUnread: Bool) {
        var state = states[serverID] ?? ServerState()
        state.mentionCount = max(0, mentionCount)
        state.isUnread = isUnread
        if !isUnread {
            state.unreadMessages = 0
        } else if let unreadMessages {
            state.unreadMessages = max(0, unreadMessages)
        }
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

    /// One channel on this device was just read (card t_e9550303).
    ///
    /// Its mentions leave the badge **in the same tick** the server answered the view — the owner's
    /// defect was a badge that only moved when some later poll happened to run. Only the mention
    /// component is adjusted here, and deliberately so: whether the server still has *any* unread
    /// message is a cross-channel, cross-team fact that one channel cannot answer, and guessing it
    /// downwards would clear the dot while another conversation is still waiting. The view path
    /// therefore also asks the server for its counters and applies them through
    /// `applyServerCounters` when they land; this call is what makes the number move now.
    func noteChannelRead(serverID: UUID, clearedMentions: Int) {
        guard clearedMentions > 0, var state = states[serverID] else { return }
        state.mentionCount = max(0, state.mentionCount - clearedMentions)
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

    /// Pure badge math, mirroring desktop `showBadgeOSX` decision order. iOS has no dock string
    /// badge, so the expired mark maps to 1 — and the unread mark maps to **the number of unread
    /// messages** when the client knows it (card `t_93eca948`, requirement 7: the dot must not be the
    /// last count-less indicator once the sidebar rows count), falling back to 1 when the only thing
    /// this server said was "unread".
    nonisolated static func badgeNumber(mentions: Int,
                                       unreadMessages: Int?,
                                       isUnread: Bool,
                                       anyExpired: Bool,
                                       showUnreadBadge: Bool) -> Int {
        if mentions > 0 {
            return mentions
        }
        if isUnread && showUnreadBadge {
            return max(1, unreadMessages ?? 0)
        }
        if anyExpired {
            return 1
        }
        return 0
    }

    /// The three numbers a server's per-team unread counters imply
    /// (`GET /users/me/teams/unread`).
    ///
    /// **This is the one place those counters become badge inputs.** Two callers feed it and neither
    /// keeps its own arithmetic: `MentionPoller` (the T14 background poll) and the T42 activity feed
    /// (foreground). Before T42 the poller did the sum inline; the feed would have had to either repeat
    /// it — two sources of truth for the badge, which is exactly what its acceptance criterion forbids —
    /// or invent a badge of its own. One function, two callers, one badge.
    ///
    /// `isUnread` is the desktop `unreads-and-mentions` "has any unread message" input: a mention implies
    /// it, and so does any unread message. `messages` is the sum the app icon shows while there is no
    /// mention waiting (card `t_93eca948` — before it, the icon showed a dot-as-1 even when it knew the
    /// number).
    nonisolated static func serverBadgeInput(mentionCounts: [Int],
                                             messageCounts: [Int]) -> (mentions: Int,
                                                                       messages: Int,
                                                                       isUnread: Bool) {
        let mentions = mentionCounts.reduce(0) { $0 + max(0, $1) }
        let messages = messageCounts.reduce(0) { $0 + max(0, $1) }
        return (mentions, messages, mentions > 0 || messages > 0)
    }

    /// Apply a `GET /users/me/teams/unread` answer for one server (the poller's and the feed's shared
    /// landing point — see `serverBadgeInput`).
    func applyServerCounters(serverID: UUID, mentionCounts: [Int], messageCounts: [Int]) {
        let input = Self.serverBadgeInput(mentionCounts: mentionCounts, messageCounts: messageCounts)
        updateMentions(serverID: serverID,
                       mentionCount: input.mentions,
                       unreadMessages: input.messages,
                       isUnread: input.isUnread)
    }

    private func recomputeTotals() {
        totalMentions = states.values.reduce(0) { $0 + $1.mentionCount }
        hasUnread = states.values.contains { $0.isUnread }
        anyExpired = states.values.contains { $0.isExpired }
        // A server whose only unread fact is "something" (no number) contributes the dot's 1, so
        // "unread somewhere, count unknown" can never read as zero on the icon.
        totalUnreadMessages = states.values.reduce(0) { sum, state in
            guard state.isUnread else { return sum }
            return sum + max(1, state.unreadMessages ?? 0)
        }
        badgeNumber = Self.badgeNumber(mentions: totalMentions,
                                       unreadMessages: totalUnreadMessages,
                                       isUnread: hasUnread,
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
