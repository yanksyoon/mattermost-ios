import Foundation
import Combine
import UserNotifications
import UIKit

/// Schedules local mention notifications from web-app `notify_mention` events and owns
/// notification authorization. Native counterpart of desktop `src/main/notifications`
/// (`NotificationManager.displayMention` + `Mention`) — parity row `NotificationWorker`
/// (design §2 native services). Status: native, T8.
///
/// Desktop flow being mirrored:
///   web app --`notify_mention`--> displayMention(title, body, channelId, teamId, url, silent,
///     webcontents, soundName) -> native Notification `"${serverName}: ${title}"`
///   First mention -> the OS permission prompt (desktop asks via the OS notification
///   permission flow; on iOS the task spec pins the request to the first mention).
///   Click -> focus the app on that server/channel (desktop NOTIFICATION_CLICKED).
///
/// iOS differences (honest, documented in docs/t8-build-note.md):
///   - DnD / Focus suppression is owned by the OS, not the shell (desktop polls
///     macos-notification-state); the system simply holds our banner until Focus allows it.
///   - Named desktop sounds (Ding/Bing/…) are bundled renderer assets; they map to the system
///     default alert sound rather than shipping server assets in the app binary.
///   - The desktop "primary view" guard is adapted for a phone: a mention is suppressed only
///     when the app is foreground **and** that mention's server is the scene on screen (the
///     user is looking at it). Backgrounded, any server's mention is delivered.
@MainActor
final class NotificationWorker: NSObject, ObservableObject, UNUserNotificationCenterDelegate {

    /// The one worker the whole shell shares — the foreground bridge path (T8) and the
    /// T14 background poller both deliver through it. A single `UNUserNotificationCenter`
    /// delegate means scheduling, badge, and tap-routing behave identically whichever path
    /// produced the request. `MattermostApp` routes its `@StateObject` through this.
    static let shared = NotificationWorker()

    // MARK: - Outcomes

    enum NotSentReason: Equatable {
        /// The mention's server UUID did not match a configured server.
        case missingServer
        /// Desktop `view_should_not_notify`: the app is foreground and the mention's server is
        /// the visible scene.
        case viewShouldNotNotify
        /// Permission not yet answered (the system prompt is showing for the first mention).
        case authorizationNotDetermined
        /// The user denied notification authorization for this app.
        case authorizationDenied
        /// `UNUserNotificationCenter.add` failed.
        case addFailed
    }

    enum PresentOutcome: Equatable {
        case scheduled(identifier: String)
        case notSent(NotSentReason)
    }

    // MARK: - State

    /// Latest authorization status, surfaced for Settings UI (T11).
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    /// Internal knob so tests can control the "app is foreground" decision without UIKit.
    var isAppActive: () -> Bool = { UIApplication.shared.applicationState == .active }

    /// The shell stores this worker drives (desktop NotificationManager consults ServerManager
    /// + ViewManager; weak refs mirror DeepLinkRouter's injection style).
    weak var serverStore: ServerStore?
    weak var viewStore: ViewStore?

    /// What the user is actually looking at, when the shell can say. `nil` (no provider installed) is
    /// treated as `.unknown` — the pre-T43 rule.
    ///
    /// T43 refined the foreground suppression: desktop's `view_should_not_notify` is about the
    /// **channel** being read, not the server being visible, and the old whole-server rule swallowed a
    /// mention in another channel of the visible server (the exact case T43's acceptance criterion
    /// requires to produce one banner). `MattermostApp` installs this from `NativeNavigation.location`, so
    /// the native input can compare channels; a webview-rendered surface answers `.unknown` and keeps the
    /// conservative rule, because the web app already suppresses its own focused-channel mentions and a
    /// second opinion there could only add noise.
    var visibleChannel: ((UUID) -> VisibleChannel)?

    /// T30: the native shell's router. Same rule as `DeepLinkRouter.nativeNavigation` — consulted at
    /// call time and only while the pane host surface resolves `native`, so a tap never lands in a
    /// router that is not on screen.
    weak var nativeNavigation: NativeNavigation?

    private let scheduling: NotificationScheduling
    private let preferences: AppPreferences

    /// Whether we have ever asked for authorization (persisted; asked exactly once per
    /// install — iOS presents the system prompt only once).
    private var hasRequestedAuthorization: Bool

    /// Server ids whose SPA has signalled `react-app-initialized` (bridge). Used to decide
    /// whether a tapped notification can SPA-navigate immediately or must wait.
    private var reactAppInitializedServers: Set<UUID> = []
    /// A channel path queued for a server whose SPA was not yet initialized when tapped.
    private var pendingChannelPaths: [UUID: String] = [:]

    init(scheduling: NotificationScheduling = UNNotificationCenterAdapter(),
         preferences: AppPreferences = AppPreferences()) {
        self.scheduling = scheduling
        self.preferences = preferences
        // AppPreferences persists Codable as JSON Data, so the flag round-trips through the
        // Codable getter, not the raw-Bool primitive reader (which would miss `false`).
        self.hasRequestedAuthorization = preferences.get(Bool.self,
            forKey: AppPreferences.Keys.notificationPermissionRequested) ?? false
        super.init()
        // The worker is the UNUserNotificationCenter delegate (willPresent / didReceive).
        // The center's delegate reference is weak; the app's @StateObject retains this worker.
        scheduling.delegate = self
        Task { await reloadAuthorizationStatus() }
    }

    /// (Re)read the authorization status. Called at launch and whenever the app foregrounds so
    /// Settings UI reflects a user changing the system permission.
    func activate() {
        Task { await reloadAuthorizationStatus() }
    }

    func reloadAuthorizationStatus() async {
        authorizationStatus = await scheduling.authorizationStatus()
    }

    // MARK: - Mention -> UNNotificationRequest (desktop displayMention)

    /// Handle one `notify_mention` bridge event. Returns the scheduling outcome for tests /
    /// diagnostics.
    func presentMention(_ mention: MentionNotification,
                        fromServerID: UUID?) async -> PresentOutcome {
        guard let serverID = fromServerID,
              let server = serverStore?.servers.first(where: { $0.id == serverID }) else {
            Logger.debug("NotificationWorker", "mention dropped: no configured server for \(fromServerID.map(String.init(describing:)) ?? "<nil>")")
            return .notSent(.missingServer)
        }

        // Desktop `view_should_not_notify`: the user is looking at this mention right now — the web app
        // suppresses its own focused mentions, and a banner here would be noise. T43: the comparison is
        // per **channel** when the shell can say which channel is on screen (`visibleChannel`); the
        // T8 whole-server rule survives only for `.unknown` (a webview-rendered surface).
        if isAppActive() && serverID == viewStore?.primaryServerID {
            let visible = visibleChannel?(serverID) ?? .unknown
            let isBeingRead: Bool
            switch visible {
            case .unknown:
                // Path A: the shell cannot see the web app's channel. Keep the conservative rule.
                isBeingRead = true
            case .noChannel:
                // The native shell is on this server but nothing is open: nothing is being read.
                isBeingRead = false
            case .channel(let channelID):
                isBeingRead = channelID == mention.channelID
            }
            if isBeingRead {
                Logger.debug("NotificationWorker", "mention suppressed: \(mention.channelID) is the channel on screen")
                return .notSent(.viewShouldNotNotify)
            }
        }

        // First mention -> ask once, and only when the OS hasn't already decided (task T8 spec:
        // request permission on first mention; never re-prompt an already-granted/denied state).
        let statusBefore = await scheduling.authorizationStatus()
        if statusBefore == .notDetermined && !hasRequestedAuthorization {
            hasRequestedAuthorization = true
            preferences.set(true, forKey: AppPreferences.Keys.notificationPermissionRequested)
            _ = try? await scheduling.requestAuthorization(options: [.alert, .sound, .badge])
        }
        switch await scheduling.authorizationStatus() {
        case .authorized, .provisional, .ephemeral:
            break
        case .denied:
            return .notSent(.authorizationDenied)
        case .notDetermined:
            return .notSent(.authorizationNotDetermined)
        @unknown default:
            return .notSent(.authorizationNotDetermined)
        }

        let content = UNMutableNotificationContent()
        content.title = Self.displayTitle(serverName: server.name, title: mention.title)
        content.body = mention.body
        // Group per channel like desktop's Windows per-channel de-duping; iOS stacks natively.
        content.threadIdentifier = mention.channelID
        // Keys mirror the Mattermost push proxy's APNs `data.*` fields so T13's Notification
        // Service Extension and click-routing can reuse the same contract.
        content.userInfo = [
            "server_id": serverID.uuidString,
            "channel_id": mention.channelID,
            "team_id": mention.teamID,
            "url": mention.serverURL,
            "type": "mention",
        ]
        if Self.mentionSound(silent: mention.silent, soundName: mention.soundName) == .systemDefault {
            content.sound = .default
        }

        let identifier = "mention.\(serverID.uuidString).\(mention.channelID).\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await scheduling.add(request)
            Logger.info("NotificationWorker", "scheduled mention \(content.title) -> \(identifier)")
            return .scheduled(identifier: identifier)
        } catch {
            Logger.error("NotificationWorker", "failed to schedule mention: \(error)")
            return .notSent(.addFailed)
        }
    }

    // MARK: - Pure helpers (unit-tested)

    /// Desktop `Mention.ts` sound logic: `!silent && (soundName !== 'None' && soundName)` plays
    /// a sound, everything else is silent. Named server sounds are bundled desktop renderer
    /// assets; on iOS they fall back to the system default alert (documented divergence).
    nonisolated static func mentionSound(silent: Bool, soundName: String?) -> MentionSound {
        if silent { return .none }
        if let name = soundName?.trimmingCharacters(in: .whitespacesAndNewlines), name == "None" {
            return .none
        }
        return .systemDefault
    }

    /// Desktop: `options.title = \`${serverName}: ${title}\`` with the default title
    /// `'Someone mentioned you'` (localizeMessage main.notifications.mention.title) when empty.
    nonisolated static func displayTitle(serverName: String?, title: String) -> String {
        let base = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Someone mentioned you"
            : title
        guard let serverName, !serverName.isEmpty else { return base }
        return "\(serverName): \(base)"
    }

    // MARK: - Tap routing (desktop notification click -> NOTIFICATION_CLICKED)

    /// Entry from `UNUserNotificationCenterDelegate` (local notification tapped).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        Task { @MainActor in
            self.route(userInfo: userInfo)
            completionHandler()
        }
    }

    /// Entry for foreground presentation: desktop shows the native banner even while the app is
    /// open (e.g. a mention from a non-visible server); mirror that by presenting in-app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in
            let content = notification.request.content
            let options: UNNotificationPresentationOptions = content.sound == nil
                ? [.banner, .list]
                : [.banner, .sound, .list]
            completionHandler(options)
        }
    }

    /// Route a tapped mention's userInfo to its server + channel.
    func route(userInfo: [AnyHashable: Any]) {
        guard (userInfo["type"] as? String) == "mention" else { return }
        let serverIDRaw = userInfo["server_id"] as? String
        let serverID = serverIDRaw.flatMap(UUID.init(uuidString:))
        let channelID = (userInfo["channel_id"] as? String) ?? ""
        let teamID = userInfo["team_id"] as? String
        guard let serverID, !channelID.isEmpty else {
            Logger.debug("NotificationWorker", "mention tap missing server/channel ids")
            return
        }
        routeToChannel(serverID: serverID, channelID: channelID, teamID: teamID)
    }

    /// Switch the shell to the mention's server and SPA-navigate to its channel. When the SPA
    /// is not initialized yet (cold launch), the path is queued and flushed on
    /// `reactAppInitialized(serverID:)`.
    func routeToChannel(serverID: UUID, channelID: String, teamID: String?) {
        guard let serverStore,
              let server = serverStore.servers.first(where: { $0.id == serverID }) else {
            Logger.debug("NotificationWorker", "mention tap routed to unknown server \(serverID)")
            return
        }

        // T30: while the native shell owns the pane there is no SPA to push into — the tap goes
        // through the same native funnel a deep link uses (so both land on one `NativeLocation`).
        // No queue is needed: the native router can hold a destination for a pane that has not
        // mounted yet, unlike the webview's SPA, which only exists after `react-app-initialized`.
        if let nativeNavigation, nativeNavigation.acceptsNativeRouting {
            let outcome = nativeNavigation.routeMention(serverID: serverID,
                                                        channelID: channelID,
                                                        teamID: teamID)
            Logger.info("NotificationWorker", "mention tap -> native shell (\(outcome))")
            return
        }

        serverStore.switchTo(id: server.id)
        viewStore?.setPrimary(server.id)
        Logger.info("NotificationWorker", "mention tap -> server \(server.name) channel \(channelID)")

        let path = "/channels/\(channelID)"
        if reactAppInitializedServers.contains(serverID) {
            pushChannelPath(path, toServerID: serverID)
        } else {
            pendingChannelPaths[serverID] = path
        }
    }

    /// The bridge's `react-app-initialized` signal: flush any queued channel push for this server.
    func reactAppInitialized(serverID: UUID) {
        reactAppInitializedServers.insert(serverID)
        if let path = pendingChannelPaths.removeValue(forKey: serverID) {
            pushChannelPath(path, toServerID: serverID)
        }
    }

    private func pushChannelPath(_ path: String, toServerID serverID: UUID) {
        guard let store = viewStore?.view(forServerID: serverID),
              let delegate = store.bridge.delegate else {
            pendingChannelPaths[serverID] = path
            return
        }
        delegate.pushBrowserHistory(path: path)
    }
}

/// Which sound a mention carries (desktop `Mention.getNotificationSound`).
enum MentionSound: Equatable {
    case none
    case systemDefault
}

/// What the shell can say about the channel the user is looking at, for the foreground suppression rule.
///
/// `.unknown` is a real state, not a failure: it is what a webview-rendered pane answers (the channel lives
/// inside the page, not in the shell). Collapsing it into "no channel" would make the worker notify for
/// mentions the web app already decided to suppress; collapsing it into "a channel" is the T8 rule.
enum VisibleChannel: Equatable {
    /// The shell does not know which channel is on screen (Path A).
    case unknown
    /// The native shell is on this server with no channel open.
    case noChannel
    /// The native shell is showing this channel.
    case channel(String)
}

// MARK: - Scheduling seam

/// The notification-center surface the worker depends on. Abstracted so the worker's logic is
/// unit-testable without the real `UNUserNotificationCenter` (which cannot be instantiated).
protocol NotificationScheduling: AnyObject {
    /// The object that receives willPresent/didReceive callbacks (the worker).
    var delegate: UNUserNotificationCenterDelegate? { get set }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func authorizationStatus() async -> UNAuthorizationStatus
    func add(_ request: UNNotificationRequest) async throws
}

/// Concrete adapter over `UNUserNotificationCenter` (the only place the framework is touched).
final class UNNotificationCenterAdapter: NSObject, NotificationScheduling {
    private let center = UNUserNotificationCenter.current()

    weak var notificationDelegate: UNUserNotificationCenterDelegate?

    var delegate: UNUserNotificationCenterDelegate? {
        get { notificationDelegate }
        set {
            notificationDelegate = newValue
            center.delegate = newValue
        }
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await center.requestAuthorization(options: options)
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await center.add(request)
    }
}
