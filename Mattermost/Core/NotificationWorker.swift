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

    /// Whether this install has ever shown the system prompt (persisted; see
    /// `AppPreferences.Keys.notificationPermissionRequested`). Published because the Settings row
    /// reports it in the diagnostics line.
    @Published private(set) var hasRequestedAuthorization: Bool

    /// How the last scheduling attempt ended, in one word, for the Settings diagnostics line.
    /// `none` until something has been attempted in this process. Values: `scheduled`, `denied`,
    /// `notDetermined`, `addFailed`, `suppressed`, `missingServer`, `none`.
    @Published private(set) var lastScheduleOutcome: String = "none"

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
        // Read the OS answer once at launch, so Settings can say `denied` / `not allowed yet`
        // instead of looking broken on an install whose system prompt was never shown (this card).
        Task { await reloadAuthorizationStatus() }
    }

    /// (Re)read the authorization status. Called at launch and whenever the app foregrounds so
    /// Settings UI reflects a user changing the system permission.
    func activate() {
        Task { await reloadAuthorizationStatus() }
    }

    func reloadAuthorizationStatus() async {
        authorizationStatus = await scheduling.authorizationStatus()
        logDiagnostics("status-read")
    }

    // MARK: - Settings surface (this card: an always-available way to authorise)

    /// The plain-words state the Settings row draws. `notDetermined` is **not** silence: an install
    /// that has never been asked says so, because that is the reported failure (nothing ever asked).
    nonisolated static func authorizationCopy(for status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "Allowed - notifications can appear"
        case .provisional: return "Allowed quietly - notifications may not interrupt"
        case .ephemeral: return "Allowed for this session"
        case .denied: return "Not allowed - open System Settings"
        case .notDetermined: return "Not allowed yet - the app has not been allowed to notify you"
        @unknown default: return "Unknown - the system did not report a permission"
        }
    }

    /// The same fact in a diagnostics-token shape: `authorized`, `denied`, `notDetermined`, …
    nonisolated static func statusToken(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        case .denied: return "denied"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    /// The plain-words copy for the current status, observed by the Settings row.
    var authorizationCopy: String { Self.authorizationCopy(for: authorizationStatus) }

    /// The one diagnostics line this card adds. Answers "why do I get no notifications?" from a log
    /// or a shared diagnostics report without reading `ncprefs.plist`.
    var diagnosticsLine: String {
        "notifications=status=\(Self.statusToken(authorizationStatus)) "
            + "requested=\(hasRequestedAuthorization) lastSchedule=\(lastScheduleOutcome)"
    }

    /// The same line as value-type facts, for `DiagnosticsContext.step6` (the shareable report).
    var diagnosticsSnapshot: NotificationDiagnosticsSnapshot {
        NotificationDiagnosticsSnapshot(status: Self.statusToken(authorizationStatus),
                                        requested: hasRequestedAuthorization,
                                        lastSchedule: lastScheduleOutcome)
    }

    private func logDiagnostics(_ event: String) {
        Logger.info("NotificationWorker", "\(diagnosticsLine) event=\(event)")
    }

    /// Record what a scheduling attempt did (Settings line + diagnostics) and hand the outcome back
    /// unchanged, so every exit from `presentMention` reports through one place.
    private func record(_ outcome: PresentOutcome) -> PresentOutcome {
        switch outcome {
        case .scheduled:
            lastScheduleOutcome = "scheduled"
        case .notSent(let reason):
            switch reason {
            case .missingServer: lastScheduleOutcome = "missingServer"
            case .viewShouldNotNotify: lastScheduleOutcome = "suppressed"
            case .authorizationNotDetermined: lastScheduleOutcome = "notDetermined"
            case .authorizationDenied: lastScheduleOutcome = "denied"
            case .addFailed: lastScheduleOutcome = "addFailed"
            }
        }
        logDiagnostics("schedule")
        return outcome
    }

    /// Ask for notification authorization exactly once per install, and report the answer.
    ///
    /// This is the first-mention prompt T8 specifies. It is a method of its own because T54's in-app
    /// banner is a delivery that schedules nothing: the banner path still has to ask, or an install whose
    /// mentions all arrive in the foreground would never be authorized and its first *backgrounded* mention
    /// would be dropped by `.authorizationNotDetermined` (and written to the ledger as handled).
    ///
    /// Since this card it is also the `Enable notifications` control's action in Settings: the user can
    /// ask without waiting for a mention to reach the delivery path. iOS only ever presents its prompt
    /// once, so a `.denied` answer cannot be re-asked here — the copy tells the reader to open System
    /// Settings instead.
    @discardableResult
    func prepareAuthorization() async -> UNAuthorizationStatus {
        let statusBefore = await scheduling.authorizationStatus()
        if statusBefore == .notDetermined && !hasRequestedAuthorization {
            hasRequestedAuthorization = true
            preferences.set(true, forKey: AppPreferences.Keys.notificationPermissionRequested)
            _ = try? await scheduling.requestAuthorization(options: [.alert, .sound, .badge])
        }
        let status = await scheduling.authorizationStatus()
        authorizationStatus = status
        return status
    }

    // MARK: - Mention -> UNNotificationRequest (desktop displayMention)

    /// Handle one `notify_mention` bridge event. Returns the scheduling outcome for tests /
    /// diagnostics.
    func presentMention(_ mention: MentionNotification,
                        fromServerID: UUID?) async -> PresentOutcome {
        guard let serverID = fromServerID,
              let server = serverStore?.servers.first(where: { $0.id == serverID }) else {
            Logger.debug("NotificationWorker", "mention dropped: no configured server for \(fromServerID.map(String.init(describing:)) ?? "<nil>")")
            return record(.notSent(.missingServer))
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
                return record(.notSent(.viewShouldNotNotify))
            }
        }

        // First mention -> ask once, and only when the OS hasn't already decided (task T8 spec:
        // request permission on first mention; never re-prompt an already-granted/denied state).
        switch await prepareAuthorization() {
        case .authorized, .provisional, .ephemeral:
            break
        case .denied:
            return record(.notSent(.authorizationDenied))
        case .notDetermined:
            return record(.notSent(.authorizationNotDetermined))
        @unknown default:
            return record(.notSent(.authorizationNotDetermined))
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

        let identifier = Self.notificationIdentifier(serverID: serverID, channelID: mention.channelID)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await scheduling.add(request)
            Logger.info("NotificationWorker", "scheduled mention \(content.title) -> \(identifier)")
            return record(.scheduled(identifier: identifier))
        } catch {
            Logger.error("NotificationWorker", "failed to schedule mention: \(error)")
            return record(.notSent(.addFailed))
        }
    }

    // MARK: - Test notification (Settings button; same request path as a mention)

    /// The identifier shape every local notification this worker schedules carries. Shared by the
    /// mention path and the Settings test button so a test proves the **same** request shape, not a
    /// second, parallel one: `mention.<server uuid>.<channel id>.<request uuid>`.
    nonisolated static func notificationIdentifier(serverID: UUID, channelID: String) -> String {
        "mention.\(serverID.uuidString).\(channelID).\(UUID().uuidString)"
    }

    /// The Settings `Send a test notification` action: ask if nothing has asked yet, then schedule
    /// exactly one local banner through the same `UNNotificationRequest` path a mention uses.
    ///
    /// The `userInfo.type` is `test`, not `mention`, on purpose: a tap on this banner must not
    /// navigate anywhere (`route(userInfo:)` only accepts `mention`), because a test banner names no
    /// real channel. Everything else — content shape, identifier shape, sound, `add` — is the
    /// mention path's.
    @discardableResult
    func sendTestNotification() async -> PresentOutcome {
        switch await prepareAuthorization() {
        case .authorized, .provisional, .ephemeral:
            break
        case .denied:
            return record(.notSent(.authorizationDenied))
        case .notDetermined:
            return record(.notSent(.authorizationNotDetermined))
        @unknown default:
            return record(.notSent(.authorizationNotDetermined))
        }

        let server = serverStore?.servers.first { $0.id == viewStore?.primaryServerID }
            ?? serverStore?.servers.first
        let serverID = server?.id ?? UUID()
        let channelID = "test-notification"

        let content = UNMutableNotificationContent()
        content.title = Self.displayTitle(serverName: server?.name, title: "Test notification")
        content.body = "If you can see this, notifications are allowed on this device."
        content.threadIdentifier = channelID
        content.userInfo = [
            "server_id": serverID.uuidString,
            "channel_id": channelID,
            "type": "test",
        ]
        content.sound = .default

        let identifier = Self.notificationIdentifier(serverID: serverID, channelID: channelID)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await scheduling.add(request)
            Logger.info("NotificationWorker", "scheduled test notification -> \(identifier)")
            return record(.scheduled(identifier: identifier))
        } catch {
            Logger.error("NotificationWorker", "failed to schedule test notification: \(error)")
            return record(.notSent(.addFailed))
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
