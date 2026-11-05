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

    /// Whether macOS has a notification-registration row for this bundle (card t_e4d5a252).
    ///
    /// This is deliberately separate from `authorizationStatus`: the system can answer `.authorized`
    /// and still have no row to deliver into (every install re-signs ad-hoc, which changes the code
    /// identity), and it can answer `.notDetermined` while a previous build's grant is already gone.
    /// The Settings row and the diagnostics line both read this fact, so neither can say "Allowed"
    /// while the OS has nowhere to put a banner.
    @Published private(set) var registrationState: NotificationRegistration = .unknown

    /// The delivery style the system says it will use (card t_e4d5a252).
    ///
    /// `alertStyle == "none"` is the state that looks like "notifications are broken" while every
    /// other read-out says "allowed": the request is accepted and delivered to Notification Center,
    /// but no banner is ever drawn. `UNNotificationSettings.alertStyle` is the only public answer,
    /// so it is read beside the status and named by the Settings row and the diagnostics line.
    @Published private(set) var deliverySettings: NotificationDeliverySettings = .unknown

    /// Whether this install has ever shown the system prompt (persisted; see
    /// `AppPreferences.Keys.notificationPermissionRequested`). Published because the Settings row
    /// reports it in the diagnostics line.
    ///
    /// **Diagnostic only since t_e4d5a252.** It records history, it never gates the ask: a persisted
    /// `true` from an earlier build must not swallow the prompt after the code identity changed and
    /// the OS forgot the grant. The gate is the OS's own status.
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

    /// What a tapped notification's conversation resolves to (this card).
    ///
    /// `nil` — the shipping default for every host that has not installed one — keeps the pre-card
    /// behaviour exactly: a tap opens the channel it names. The app installs
    /// `SessionNotificationTapResolver`, which answers the happy path from the loaded channel list and
    /// asks the server only when that list cannot say.
    ///
    /// Held **strongly**: the app creates it at bind time and the worker is then its one owner, while the
    /// resolver's own references back into the shell are weak (no cycle).
    var tapResolver: (any NotificationTapResolving)?

    /// The copy for the last tap that could not land, in upstream's words ("Message not found" plus one
    /// sentence). The shell draws it as an alert over the channel list the fallback lands on; `nil`
    /// means no alert is up.
    @Published private(set) var tapFailure: NotificationTapFailure?

    /// The alert's dismiss action.
    func dismissTapFailure() {
        tapFailure = nil
    }

    private let scheduling: NotificationScheduling
    private let preferences: AppPreferences
    private let registrationReader: any NotificationRegistrationReading

    /// Whether **this process** has already shown the system prompt.
    ///
    /// Not persisted on purpose (t_e4d5a252). The system prompt can only be answered once per
    /// code identity, but the *app* cannot know when that identity changed — macOS throws the
    /// grant away on every ad-hoc re-sign while `mm.notifications.permissionRequested` survives in
    /// UserDefaults. So the persisted flag is history, and this process-scoped bit is what keeps
    /// one run's repeated `prepareAuthorization()` calls (a mention, a Settings tap, a test banner)
    /// from re-asking while the alert is already up. A new launch asks again **iff the OS says
    /// `.notDetermined`**.
    private var didAskThisProcess = false

    /// Server ids whose SPA has signalled `react-app-initialized` (bridge). Used to decide
    /// whether a tapped notification can SPA-navigate immediately or must wait.
    private var reactAppInitializedServers: Set<UUID> = []
    /// A channel path queued for a server whose SPA was not yet initialized when tapped.
    private var pendingChannelPaths: [UUID: String] = [:]

    init(scheduling: NotificationScheduling = UNNotificationCenterAdapter(),
         preferences: AppPreferences = AppPreferences(),
         registration: any NotificationRegistrationReading = SystemNotificationRegistrationReader()) {
        self.scheduling = scheduling
        self.preferences = preferences
        self.registrationReader = registration
        // AppPreferences persists Codable as JSON Data, so the flag round-trips through the
        // Codable getter, not the raw-Bool primitive reader (which would miss `false`).
        self.hasRequestedAuthorization = preferences.get(Bool.self,
            forKey: AppPreferences.Keys.notificationPermissionRequested) ?? false
        super.init()
        // The registration fact is a cheap local file read: take it before the first frame so the
        // Settings row is truthful on an install whose grant never carried over.
        registrationState = registrationReader.registrationState()
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
        registrationState = registrationReader.registrationState()
        deliverySettings = await scheduling.deliverySettings()
        logDiagnostics("status-read")
    }

    // MARK: - Settings surface (this card: an always-available way to authorise)

    /// The plain-words state the Settings row draws. `notDetermined` is **not** silence: an install
    /// that has never been asked says so, because that is the reported failure (nothing ever asked).
    ///
    /// `registration` is the OS-side fact (card t_e4d5a252). It only changes the copy when the system
    /// answers "allowed": `.authorized` with no Notification Center row is the state in which every
    /// `add()` is dropped, so that combination must never read as "Allowed".
    nonisolated static func authorizationCopy(for status: UNAuthorizationStatus,
                                              registration: NotificationRegistration = .unknown,
                                              delivery: NotificationDeliverySettings = .unknown) -> String {
        switch status {
        case .authorized, .provisional, .ephemeral:
            if registration == .notRegistered {
                return "Not registered with macOS - nothing can appear"
            }
            if delivery.alertStyle == "none" {
                return "Allowed, but notifications are set to none - no banner can appear"
            }
            switch status {
            case .authorized: return "Allowed - notifications can appear"
            case .provisional: return "Allowed quietly - notifications may not interrupt"
            default: return "Allowed for this session"
            }
        case .denied: return "Not allowed - open System Settings"
        case .notDetermined: return "Not allowed yet - the app has not been allowed to notify you"
        @unknown default: return "Unknown - the system did not report a permission"
        }
    }

    /// The short form the row's leading label shows. Same rule as `authorizationCopy`: a bundle the
    /// OS has no row for, or a style the OS will not draw, is **not** plain "Allowed".
    nonisolated static func statusLabel(for status: UNAuthorizationStatus,
                                        registration: NotificationRegistration = .unknown,
                                        delivery: NotificationDeliverySettings = .unknown) -> String {
        switch status {
        case .authorized, .provisional, .ephemeral:
            if registration == .notRegistered { return "Not registered" }
            if delivery.alertStyle == "none" { return "No banners" }
            return "Allowed"
        case .denied: return "Not allowed"
        case .notDetermined: return "Not allowed yet"
        @unknown default: return "Unknown"
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
    var authorizationCopy: String {
        Self.authorizationCopy(for: authorizationStatus, registration: registrationState,
                               delivery: deliverySettings)
    }

    /// The short label for the current status, observed by the Settings row.
    var statusLabel: String {
        Self.statusLabel(for: authorizationStatus, registration: registrationState,
                         delivery: deliverySettings)
    }

    /// Whether the system reports this app as allowed (any allowed flavour).
    var isAllowed: Bool {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    /// Whether the reader has to leave the app to fix what this row reports.
    var needsSystemSettings: Bool {
        authorizationStatus == .denied
            || registrationState == .notRegistered
            || (deliverySettings.alertStyle == "none" && isAllowed)
    }

    /// The one diagnostics line this card adds. Answers "why do I get no notifications?" from a log
    /// or a shared diagnostics report without reading `ncprefs.plist`.
    ///
    /// `registration=` and `alerts=` were added by t_e4d5a252: without them the line could read
    /// `status=authorized` on an install where the OS has no row, or where the style is `none` and
    /// no banner can be drawn, and every request is dropped or delivered silently.
    var diagnosticsLine: String {
        "notifications=status=\(Self.statusToken(authorizationStatus)) "
            + "registration=\(registrationState.diagnosticsToken) "
            + "alerts=\(deliverySettings.alertStyle) "
            + "requested=\(hasRequestedAuthorization) lastSchedule=\(lastScheduleOutcome)"
    }

    /// The same line as value-type facts, for `DiagnosticsContext.step6` (the shareable report).
    var diagnosticsSnapshot: NotificationDiagnosticsSnapshot {
        NotificationDiagnosticsSnapshot(status: Self.statusToken(authorizationStatus),
                                        registration: registrationState.diagnosticsToken,
                                        alerts: deliverySettings.alertStyle,
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

    /// Ask for notification authorization, driven by the **OS state** rather than a persisted flag.
    ///
    /// This is the first-mention prompt T8 specifies. It is a method of its own because T54's in-app
    /// banner is a delivery that schedules nothing: the banner path still has to ask, or an install whose
    /// mentions all arrive in the foreground would never be authorized and its first *backgrounded* mention
    /// would be dropped by `.authorizationNotDetermined` (and written to the ledger as handled).
    ///
    /// Since this card it is also the `Enable notifications` control's action in Settings and the
    /// launch-time ask (see `askOnLaunchIfNeeded(hasSession:)`). iOS only ever presents its prompt
    /// once per code identity, so a `.denied` answer cannot be re-asked here — the copy tells the
    /// reader to open System Settings instead.
    ///
    /// **Why the persisted flag is not the gate (t_e4d5a252).** The reported failure was an install
    /// whose `mm.notifications.permissionRequested` said "already asked" from a previous build while
    /// the OS had no registration row at all — so this method returned without ever showing a prompt,
    /// and every `add()` was silently dropped. `didAskThisProcess` replaces it: one ask per process,
    /// and a new process asks again whenever the OS still answers `.notDetermined`.
    @discardableResult
    func prepareAuthorization(registeringAuthorizedInstall: Bool = false) async -> UNAuthorizationStatus {
        let statusBefore = await scheduling.authorizationStatus()
        if shouldAsk(status: statusBefore, includingAuthorized: registeringAuthorizedInstall) {
            didAskThisProcess = true
            hasRequestedAuthorization = true
            preferences.set(true, forKey: AppPreferences.Keys.notificationPermissionRequested)
            _ = try? await scheduling.requestAuthorization(options: [.alert, .sound, .badge])
        }
        let status = await scheduling.authorizationStatus()
        authorizationStatus = status
        registrationState = registrationReader.registrationState()
        deliverySettings = await scheduling.deliverySettings()
        return status
    }

    /// Whether this process still owes the system a registration call.
    ///
    /// `includingAuthorized` is true only for the launch reconciliation, never for a delivery: a
    /// mention must not turn into a permission round-trip on an install that already reads allowed.
    ///
    /// Two states deserve a call:
    /// * `.notDetermined` — the ordinary first-run prompt.
    /// * `.authorized` with `hasRequestedAuthorization == false` **at launch** — measured on this card:
    ///   macOS 26 answers `.authorized` for an app that has never asked (the launch log read
    ///   `status=authorized registration=registered alerts=banner requested=false`). One silent call
    ///   on launch makes `requested` a fact instead of a stale local flag.
    private func shouldAsk(status: UNAuthorizationStatus, includingAuthorized: Bool) -> Bool {
        guard !didAskThisProcess else { return false }
        if status == .notDetermined { return true }
        return includingAuthorized && status == .authorized && !hasRequestedAuthorization
    }

    /// Ask at launch, once, when this install has never been answered and a session exists.
    ///
    /// Why launch and not only Settings (card item 2): the runbook opens the app and reads a channel
    /// list; it never opens Settings → Notifications, so an install that only asks there is asked
    /// never. The call is deliberately gated on a **session**, because an install that has not signed
    /// in has nothing to notify about yet and a prompt at that moment is noise.
    ///
    /// The ask is not awaited by any UI: `MattermostApp` starts it from the `.task` that already runs
    /// after the first frame, and SwiftUI never blocks on the system alert.
    func askOnLaunchIfNeeded(hasSession: Bool) async {
        let status = await scheduling.authorizationStatus()
        authorizationStatus = status
        registrationState = registrationReader.registrationState()
        deliverySettings = await scheduling.deliverySettings()
        guard hasSession, shouldAsk(status: status, includingAuthorized: true) else {
            logDiagnostics("launch-ask-skipped")
            return
        }
        logDiagnostics("launch-ask")
        _ = await prepareAuthorization(registeringAuthorizedInstall: true)
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
            await self.route(userInfo: userInfo)
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

    /// Route a tapped mention's userInfo to its server + channel — and, when the conversation or the
    /// post it names no longer resolves, say so in the pinned client's own words and leave the reader
    /// on the channel list instead of a dead pane.
    ///
    /// Upstream's tap is `openNotification` (`app/actions/remote/notifications.ts`) →
    /// `fetchNotificationData`, and its outcomes are the sentences of `notificationError`
    /// (`app/utils/notification/index.ts`): a post that is gone is *"The message has not been found."*,
    /// a channel the reader left (or one whose row outlived it) is *"This message belongs to a channel
    /// where you are not a member."*, an unreachable server is the Connection sentence — and each of
    /// them is followed by `navigateToRoot()`, so the reader lands on the channel list.
    ///
    /// The order is what keeps a tap cheap:
    ///  1. **What the shell already knows** (`tapResolver.localMembership`, i.e. the loaded channel
    ///     list) decides the happy path, so a tap on a live conversation makes **no request at all**;
    ///  2. only an answer the local list cannot give asks the server — upstream's `fetchMyChannel`,
    ///     measured on 9.11.19 by `scripts/t14c_notification_tap_probe.py` (membership probe +
    ///     the channel's `delete_at`);
    ///  3. a **thread** mention (`root_id`) then asks whether the post it is about still exists: the
    ///     one case where the post itself is the destination, exactly as upstream's CRT path does;
    ///  4. otherwise the tap routes exactly as it always did.
    ///
    /// A probe that cannot answer is **not** a failure to route. `.unknown` — no resolver installed,
    /// no session, a transport failure on the *extra* probe — falls through to the pre-card behaviour,
    /// because a dead end invented by a flaky network is worse than an empty pane.
    @discardableResult
    func route(userInfo: [AnyHashable: Any]) async -> NotificationTapOutcome {
        guard let tap = NotificationTapPayload(userInfo: userInfo) else {
            Logger.debug("NotificationWorker", "tap ignored: not a mention payload")
            return .ignored
        }
        guard serverStore?.servers.contains(where: { $0.id == tap.serverID }) == true else {
            Logger.debug("NotificationWorker", "mention tap routed to unknown server \(tap.serverID)")
            return .noServer
        }

        if let resolver = tapResolver {
            var membership = resolver.localMembership(serverID: tap.serverID, channelID: tap.channelID,
                                                      teamID: tap.teamID)
            if membership == .unknown {
                membership = await resolver.remoteMembership(serverID: tap.serverID, channelID: tap.channelID)
            }
            switch membership {
            case .notMember:
                return fail(.notChannelMember, for: tap)
            case .gone:
                return fail(.channelGone, for: tap)
            case .unreachable:
                return fail(.unreachable, for: tap)
            // `.sessionExpired` routes: the shell's auth gate answers with the sign-in surface, which
            // is the honest destination for a tap whose server no longer accepts the session.
            case .member, .sessionExpired, .unknown:
                break
            }

            if let rootID = tap.rootID, !rootID.isEmpty {
                switch await resolver.postState(serverID: tap.serverID, postID: rootID) {
                case .gone:
                    return fail(.postNotFound, for: tap)
                case .notPermitted:
                    return fail(.notChannelMember, for: tap)
                case .unreachable:
                    return fail(.unreachable, for: tap)
                case .exists, .sessionExpired, .unknown:
                    break
                }
            }
        }

        // A thread mention names its *root*: that is the post the pane should open at, so it is what
        // the native funnel carries when the payload has no explicit post id.
        return routeToChannel(serverID: tap.serverID, channelID: tap.channelID,
                              teamID: tap.teamID, postID: tap.postID ?? tap.rootID)
    }

    /// Record the copy for a tap that cannot land, and put the reader where upstream's
    /// `navigateToRoot()` would: the channel list of the notification's server.
    private func fail(_ failure: NotificationTapFailure, for tap: NotificationTapPayload) -> NotificationTapOutcome {
        Logger.info("NotificationWorker", "mention tap fallback [\(failure.diagnosticsToken)] " +
            "server=\(tap.serverID.uuidString.prefix(8)) channel=\(tap.channelID)")
        tapFailure = failure
        landOnChannelList(serverID: tap.serverID)
        return .failed(failure)
    }

    /// The `navigateToRoot()` half of upstream's notification error.
    ///
    /// Native shell: the workspace root for that server is the channel list (`path` emptied, the
    /// sidebar is the screen again). Webview path: the SPA is sent to its server root through the same
    /// queue a cold-launch tap uses, so a tap that arrives before `react-app-initialized` still lands.
    private func landOnChannelList(serverID: UUID) {
        if let nativeNavigation, nativeNavigation.acceptsNativeRouting {
            _ = nativeNavigation.openHome(serverID: serverID)
            return
        }
        serverStore?.switchTo(id: serverID)
        viewStore?.setPrimary(serverID)
        if reactAppInitializedServers.contains(serverID) {
            pushChannelPath("/", toServerID: serverID)
        } else {
            pendingChannelPaths[serverID] = "/"
        }
    }

    /// Switch the shell to the mention's server and SPA-navigate to its channel. When the SPA
    /// is not initialized yet (cold launch), the path is queued and flushed on
    /// `reactAppInitialized(serverID:)`.
    @discardableResult
    func routeToChannel(serverID: UUID, channelID: String, teamID: String?,
                        postID: String? = nil) -> NotificationTapOutcome {
        guard let serverStore,
              let server = serverStore.servers.first(where: { $0.id == serverID }) else {
            Logger.debug("NotificationWorker", "mention tap routed to unknown server \(serverID)")
            return .noServer
        }

        // T30: while the native shell owns the pane there is no SPA to push into — the tap goes
        // through the same native funnel a deep link uses (so both land on one `NativeLocation`).
        // No queue is needed: the native router can hold a destination for a pane that has not
        // mounted yet, unlike the webview's SPA, which only exists after `react-app-initialized`.
        if let nativeNavigation, nativeNavigation.acceptsNativeRouting {
            let outcome = nativeNavigation.routeMention(serverID: serverID,
                                                        channelID: channelID,
                                                        teamID: teamID,
                                                        postID: postID)
            Logger.info("NotificationWorker", "mention tap -> native shell (\(outcome))")
            switch outcome {
            case .opened: return .routed
            case .needsAuth: return .needsAuth
            case .needsServerAdd: return .noServer
            case .unsupported: return .ignored
            }
        }

        serverStore.switchTo(id: server.id)
        viewStore?.setPrimary(server.id)
        Logger.info("NotificationWorker", "mention tap -> server \(server.name) channel \(channelID)")

        // The SPA path names the channel only: the web app focuses a message from its own route, and a
        // `postID` is not part of this shell's history push (the native path above carries it).
        let path = "/channels/\(channelID)"
        if reactAppInitializedServers.contains(serverID) {
            pushChannelPath(path, toServerID: serverID)
        } else {
            pendingChannelPaths[serverID] = path
        }
        return .routed
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

// MARK: - Tap resolution (a tap whose post/channel is gone)

/// The payload a mention tap carries, in the shape the push proxy writes it.
///
/// `server_id`, `channel_id` and `team_id` are what this worker schedules today; `post_id` and
/// `root_id` are the pinned client's own push fields (`NotificationWithData.payload`,
/// `app/utils/notification/index.ts`), read here so a payload produced by the real push path — or by
/// the in-app banner — is routed with the post it is about.
struct NotificationTapPayload: Equatable {
    var serverID: UUID
    var channelID: String
    var teamID: String?
    var postID: String?
    /// The thread root, when the mention was a reply. Upstream only looks the post up for these: a
    /// channel mention's destination is the channel, which does not need the post to exist.
    var rootID: String?

    /// `nil` for anything that is not a well-formed mention tap (a test banner, a download notice, a
    /// payload with no channel).
    init?(userInfo: [AnyHashable: Any]) {
        guard (userInfo["type"] as? String) == "mention",
              let rawServer = userInfo["server_id"] as? String,
              let serverID = UUID(uuidString: rawServer),
              let channelID = userInfo["channel_id"] as? String,
              !channelID.isEmpty else { return nil }
        self.serverID = serverID
        self.channelID = channelID
        let team = (userInfo["team_id"] as? String) ?? ""
        self.teamID = team.isEmpty ? nil : team
        self.postID = Self.nonEmpty(userInfo["post_id"] as? String)
        self.rootID = Self.nonEmpty(userInfo["root_id"] as? String)
    }

    init(serverID: UUID, channelID: String, teamID: String? = nil,
         postID: String? = nil, rootID: String? = nil) {
        self.serverID = serverID
        self.channelID = channelID
        self.teamID = teamID
        self.postID = postID
        self.rootID = rootID
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

/// Whether the signed-in account is in a channel, as far as anything can say.
///
/// The cases are the four answers the server actually gives, measured on 9.11.19 by
/// `scripts/t14c_notification_tap_probe.py` — `GET /channels/{id}/members/me` answers `200` for a
/// member, `404 app.channel.get_member.missing.app_error` when the account is not in it (as a system
/// admin) and `403 api.context.permissions.app_error` when it is not and may not even look (an
/// ordinary account, or an id that does not exist). Both are the caller's "not a member".
enum NotificationChannelMembership: Equatable {
    /// The list the shell has loaded contains it: it is one of the account's conversations.
    case member
    /// Whether the account is in it (left, removed, never joined) — measured as `404`/`403` on the
    /// membership probe, and the only answer that produces upstream's channel sentence.
    case notMember
    /// The channel no longer exists: the membership probe succeeded but `GET /channels/{id}` answered
    /// `404`, so the row outlived the channel. An **archived** channel is not this — it is a `.member`
    /// destination, because the pane draws its own archived banner and upstream navigates into it.
    case gone
    /// The server refused the session (`401`): the shell's re-auth surface is the answer, not a
    /// fallback sentence.
    case sessionExpired
    /// The server could not be reached, or answered something this client cannot interpret.
    case unreachable
    /// Nothing can say: no resolver, no loaded list, no session for the server. **Routes as before** —
    /// a guess here would invent dead ends.
    case unknown
}

/// Whether a post a tap names still exists.
enum NotificationPostState: Equatable {
    case exists
    /// Deleted (`404 app.post.get.app_error`, measured for a soft-deleted post and for an id that
    /// never existed — the server does not distinguish them, so neither does this).
    case gone
    /// `403`: the post belongs to a channel the account may not read.
    case notPermitted
    case sessionExpired
    case unreachable
    case unknown
}

/// The pinned client's tap-through copy — `mobile` `notificationError`
/// (`app/utils/notification/index.ts`), verbatim.
///
/// Every case is followed by `navigateToRoot()` upstream, which this shell mirrors by landing the
/// reader on the channel list (`NotificationWorker.landOnChannelList`). The title is one string for
/// all of them (`notification.message_not_found`); only the sentence differs.
enum NotificationTapFailure: String, Equatable, CaseIterable {
    /// `notification.no_post` — a post that is gone.
    case postNotFound
    /// `notification.not_channel_member` — left, removed, or the channel itself is gone. An *archived*
    /// channel is not this case: it routes, and the pane's composer banner explains it.
    case channelGone
    /// `notification.not_channel_member` — the same sentence, reached through a `403` on the channel
    /// or on its post. Kept apart from `channelGone` because the *reason* is different, and the log
    /// line is the only place that difference can be seen.
    case notChannelMember
    /// `notification.not_team_member` — no team membership for the notification's team.
    case notTeamMember
    /// `notification.no_connection` — the server could not be reached.
    case unreachable

    /// `notification.message_not_found`: the alert's title, the same for every case.
    static let title = "Message not found"

    var message: String {
        switch self {
        case .postNotFound:
            return "The message has not been found."
        case .channelGone, .notChannelMember:
            return "This message belongs to a channel where you are not a member."
        case .notTeamMember:
            return "This message belongs to a team where you are not a member."
        case .unreachable:
            return "The server is unreachable and it was not possible to retrieve the specific " +
                   "message information for the notification."
        }
    }

    /// The Settings/diagnostics token (the enum's own name, never the sentence).
    var diagnosticsToken: String { rawValue }
}

/// What a tap did, for tests and for the log.
enum NotificationTapOutcome: Equatable {
    /// The shell is showing the tapped conversation (native) or has pushed its path (webview).
    case routed
    /// The tapped server has no session: the shell is showing its auth surface.
    case needsAuth
    /// No configured server matches the payload's `server_id`.
    case noServer
    /// The conversation or post is gone: the copy was shown and the reader is on the channel list.
    case failed(NotificationTapFailure)
    /// Not a mention tap, or a route this shell cannot show.
    case ignored
}

/// What a tap can be checked against — the seam between `NotificationWorker` and the app.
///
/// Split in two on purpose, because the *cost* is the card's constraint:
///  - `localMembership` must be answerable **without a request** (the loaded channel list knows every
///    conversation the account is in), and is what keeps the happy path network-free;
///  - `remoteMembership` / `postState` are the pinned client's own probes, taken only when the local
///    answer is `.unknown`.
///
/// Every method has a default so a test (or a host with no session) implements only the branch it
/// exercises and everything else reads `.unknown`, i.e. "route as before".
@MainActor
protocol NotificationTapResolving: AnyObject {
    func localMembership(serverID: UUID, channelID: String,
                         teamID: String?) -> NotificationChannelMembership
    func remoteMembership(serverID: UUID, channelID: String) async -> NotificationChannelMembership
    func postState(serverID: UUID, postID: String) async -> NotificationPostState
}

extension NotificationTapResolving {
    func localMembership(serverID: UUID, channelID: String,
                         teamID: String?) -> NotificationChannelMembership { .unknown }
    func remoteMembership(serverID: UUID, channelID: String) async -> NotificationChannelMembership { .unknown }
    func postState(serverID: UUID, postID: String) async -> NotificationPostState { .unknown }
}

// MARK: - Scheduling seam

/// The delivery style the system will use for this app, as far as the public API reports it.
///
/// Only `alertStyle` is carried: `none` is the one value that explains "allowed, scheduled, and
/// nothing ever appears" without a second cause, and `UNNotificationSettings.alertStyle` is the
/// public way to read it. `unknown` is a host that could not answer (never rendered as a failure).
struct NotificationDeliverySettings: Equatable {
    /// `none`, `banner`, `alert`, or `unknown`.
    var alertStyle: String

    static let unknown = NotificationDeliverySettings(alertStyle: "unknown")
}

/// The notification-center surface the worker depends on. Abstracted so the worker's logic is
/// unit-testable without the real `UNUserNotificationCenter` (which cannot be instantiated).
protocol NotificationScheduling: AnyObject {
    /// The object that receives willPresent/didReceive callbacks (the worker).
    var delegate: UNUserNotificationCenterDelegate? { get set }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func authorizationStatus() async -> UNAuthorizationStatus
    func deliverySettings() async -> NotificationDeliverySettings
    func add(_ request: UNNotificationRequest) async throws
}

extension NotificationScheduling {
    /// A host that cannot report the style keeps the worker behaving exactly as before.
    func deliverySettings() async -> NotificationDeliverySettings { .unknown }
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

    func deliverySettings() async -> NotificationDeliverySettings {
        let settings = await center.notificationSettings()
        let style: String
        switch settings.alertStyle {
        case .none: style = "none"
        case .banner: style = "banner"
        case .alert: style = "alert"
        @unknown default: style = "unknown"
        }
        return NotificationDeliverySettings(alertStyle: style)
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await center.add(request)
    }
}
