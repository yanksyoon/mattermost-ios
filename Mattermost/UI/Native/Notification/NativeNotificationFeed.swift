// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 `app/actions/websocket/posts.ts` (a
// `posted` event is what a running client reacts to) and the Mattermost **server's** notification
// contract (`app/notification.go` — the account's `notify_props`, the channel member's props, and
// `isUserMentioned`), which is what a push notification is decided from. Licence: Apache-2.0 /
// documented server behaviour — no upstream source copied.
//
// T43's input path, end to end:
//
//   socket `posted` ──► NativeNotificationFeed ──► MentionNotificationPolicy ──► NotificationWorker
//                              │                        (pure: is this my banner?)        │
//                              ├──► MentionLedger (the one high-water mark the T14 poller also uses)
//                              └──► SessionStore.applyServerCounters (the one badge arithmetic)
//
// Why a coordinator (the convention every T32+ surface follows, docs/component-map.md §1): the socket
// pump lives in `TeamSidebarCoordinator`, a view cannot subscribe to it, and the reader's mention keys
// and the per-server channel context cost requests that must not be repeated per event. One object per
// app owns that, and it is fed by the rail's single socket — **never a second connection** (the same rule
// T33/T39/T40/T41/T42 state).
//
// What it deliberately does *not* do:
//   * it does not schedule anything itself — `NotificationWorker` stays the one scheduler, so the
//     `userInfo` contract T13's Notification Service Extension and the tap router read is unchanged;
//   * it does not compute a badge number — `SessionStore.serverBadgeInput`/`applyServerCounters` is the
//     only arithmetic (T42's rule, and T14's poller goes through the same call);
//   * it does not fire while its input is not the live one. In `.bridge` mode (the default until an
//     `-AV` approves the flip) it delivers nothing **and writes nothing**: the page is the input, so a
//     post the socket sees must stay pollable rather than be marked handled here (T43-R F1).

import Foundation
import Combine
import UIKit

@MainActor
final class NativeNotificationFeed: ObservableObject {

    /// One processed socket post, for the Settings read-out and for tests and probes.
    struct Record: Equatable, Identifiable {
        var postID: String
        var channelID: String
        var channelLabel: String
        var serverID: UUID
        var serverName: String
        /// The banner the worker was handed (empty when the post was dropped before formatting).
        var title: String
        var body: String
        /// "delivered", or the reason it was not (`MentionDropReason.label`, or the worker's own reason).
        var outcome: String
        var delivered: Bool
        var at: Date
        /// T54: which surface showed it — "in-app banner" or "system notification". Empty for a drop, so
        /// the read-out can say *where* a delivered mention went instead of only that one was delivered.
        var surface: String = ""
        var id: String { postID }
    }

    /// How long badge counters are coalesced before one `GET /users/me/teams/unread`. Mentions are rare,
    /// so this only matters when a burst of mentions arrives at once — and then it is one request.
    var badgeRefreshDelay: TimeInterval = 1.5

    weak var serverStore: ServerStore?
    weak var sessionStore: SessionStore?
    /// T54: the shell's active server, for the presentation decision's "is anything of this mention's
    /// server on screen" question. Optional: a feed built without one simply never treats a mention's
    /// server as primary, which answers "show the banner" — the visible-surface decision is then made by
    /// `visibleChannel` alone.
    weak var viewStore: ViewStore?

    /// The arbitration state both inputs read (mode, per-server socket liveness, counters).
    let routing: NotificationInputRouting
    /// The one high-water mark, shared with `MentionPoller` (`MentionPoller.ledger`).
    let ledger: MentionLedger

    /// Test seams, in the shape the rest of the shell uses (`serviceFactory` / injected delivery).
    var serviceFactory: ((ServerConfig) -> ActivityServing)?
    var deliverMention: ((MentionNotification, UUID) async -> NotificationWorker.PresentOutcome)?

    /// T54: the app's one in-app banner slot. **`nil` means "this process has no in-app surface"**, and
    /// then the feed behaves exactly as it did before T54: every delivered mention goes to
    /// `NotificationWorker`. That is the unit-test host and any shell that has not mounted a banner — the
    /// app always installs one (`MattermostApp.bindShellStores`).
    weak var bannerCenter: InAppMentionBannerCenter?

    /// The channel on screen for a server — the **same** closure `NotificationWorker.visibleChannel` reads,
    /// installed once by `MattermostApp`, so the two surfaces cannot disagree about it.
    var visibleChannel: (@MainActor (UUID) -> VisibleChannel)?

    /// Whether the app is foreground. Same closure the worker uses (`NotificationWorker.isAppActive`).
    var isAppActive: () -> Bool = { UIApplication.shared.applicationState == .active }

    /// T54: ask for notification permission the way the first *system* mention would, without scheduling
    /// anything. A banner needs no permission, but if every mention a reader ever receives is foreground
    /// the OS prompt would never be asked — and the first backgrounded mention would then be dropped
    /// undelivered. Calling this on the banner path keeps T8's "asked once, on the first mention" promise.
    var askForNotificationPermission: (@MainActor () async -> Void)?

    /// Injectable clock so a record's timestamp is assertable.
    var now: () -> Date = Date.init

    @Published private(set) var lastRecord: Record?
    @Published private(set) var deliveredCount = 0
    @Published private(set) var droppedCount = 0

    /// The reader's mention keys and account notify props, read once per server (and refreshed when a
    /// server's session is replaced). A key change mid-run is a settings edit; the next mention re-reads
    /// if the cache was cleared by `authPhaseChanged`.
    private var readers: [UUID: MentionReader] = [:]
    private var channelCache: [UUID: [String: MMChannel]] = [:]
    private var pendingBadgeRefresh: [UUID: Task<Void, Never>] = [:]

    init(routing: NotificationInputRouting? = nil, ledger: MentionLedger? = nil) {
        // Built here, not as default arguments: a default argument is evaluated in a nonisolated
        // context and both of these are main-actor types (the note `TeamSidebarCoordinator` carries).
        self.routing = routing ?? NotificationInputRouting.shared
        self.ledger = ledger ?? MentionLedger()
        self.deliverMention = nil
    }

    // MARK: - Wiring

    /// The app's binding point (idempotent, called from `MattermostApp.bindShellStores`).
    func bind(serverStore: ServerStore?, sessionStore: SessionStore?, viewStore: ViewStore? = nil) {
        self.serverStore = serverStore
        self.sessionStore = sessionStore
        self.viewStore = viewStore
    }

    /// The rail's pump reporting its own lifetime. Under `.socket` mode a live pump is what makes this
    /// input authoritative for that server and therefore what refuses the bridge.
    func socketStateChanged(serverID: UUID, live: Bool) {
        routing.socketStateChanged(serverID: serverID, live: live)
        if !live { pendingBadgeRefresh[serverID]?.cancel(); pendingBadgeRefresh[serverID] = nil }
    }

    /// A sign-out or an expiry: the cached keys and channel rows were read with that credential.
    func authPhaseChanged(_ serverID: UUID) {
        readers[serverID] = nil
        channelCache[serverID] = nil
        pendingBadgeRefresh[serverID]?.cancel()
        pendingBadgeRefresh[serverID] = nil
    }

    // MARK: - The input

    /// One event from the server's socket — **every** event, delivered by the rail *before* its team
    /// scope decides anything, because a mention is not team-scoped: a mention in another team is still a
    /// mention of the reader.
    func handle(_ event: SocketEvent, server: ServerConfig) async {
        guard case .posted(let post) = event else { return }
        guard !post.channelId.isEmpty, !post.id.isEmpty else { return }

        // **T43-R (F1): the gate comes before every ledger write.**
        //
        // The ring in `MentionLedger` is not "posts this process looked at" — `MentionPoller.isNew`
        // refuses anything in it, so an entry means "this mention has been handled; do not deliver it
        // again". Only the input that *owns* the mention may put it there. Writing it first (the T43
        // implementation did) meant the socket marked a mention handled in the shipped `.bridge` mode —
        // where the page is the input and the socket delivers nothing — and T14's poll then refused it
        // for ever: measured on post `rfu9jjxubtrdxm5kb4sipmfjkw`, no banner anywhere, yet
        // `notifiedPostIDs` gained that id and `watermarkTs` its `create_at`. The same hole applied to a
        // dual-render pane, where the gate also answers "not me".
        //
        // The rule now: a post this input is not allowed to deliver stays **pollable**.
        guard routing.gate.acceptsSocket(serverID: server.id) else {
            // Seen, but not this input's to handle: counted for the read-out, recorded nowhere.
            routing.noteSocketPost(isMention: false)
            return
        }

        // **Read before write:** `alreadyHandled` is captured first, so a replayed frame — or a post the
        // T14 poller already notified — is refused as a duplicate instead of being mistaken for new
        // (recording first and checking after made every first mention look like a replay).
        let alreadyHandled = ledger.hasHandled(post.id, for: server.id)

        if alreadyHandled {
            // The ring is shared with the poller: a mention the background poll already delivered must not
            // be delivered again by the live path. The socket does not replay, so this means the poller got
            // there first — which is exactly the duplicate the shared state exists to prevent.
            record(Record(postID: post.id, channelID: post.channelId, channelLabel: "",
                          serverID: server.id, serverName: server.name, title: "", body: "",
                          outcome: MentionDropReason.alreadyDelivered.label, delivered: false,
                          at: now()), delivered: false,
                   reason: MentionDropReason.alreadyDelivered.label)
            return
        }

        // The reader is identified first (its id and mention keys decide everything); the profile is read
        // once per server and cached, so the common case below costs no request at all.
        let reader: MentionReader
        do {
            reader = try await self.reader(for: server)
        } catch {
            record(Record(postID: post.id, channelID: post.channelId, channelLabel: "",
                          serverID: server.id, serverName: server.name, title: "", body: "",
                          outcome: "the reader's profile could not be read (\(error))",
                          delivered: false, at: now()), delivered: false, reason: "profile unavailable")
            return
        }
        if post.userId == reader.userID { routing.noteSocketPost(isMention: false); return }
        if post.type.hasPrefix("system_") { routing.noteSocketPost(isMention: false); return }

        // The channel context: its display name is the banner's title, its team id is the `userInfo`
        // `team_id`, and its member row carries the per-channel notify props the policy reads.
        let channel: MMChannel?
        let membership: MMChannelMember?
        do {
            channel = try await self.channel(for: post.channelId, server: server)
            membership = try? await service(for: server).channelRead(channelID: post.channelId,
                                                                     userID: reader.userID)
        } catch {
            routing.noteSocketPost(isMention: false)
            record(Record(postID: post.id, channelID: post.channelId, channelLabel: "",
                          serverID: server.id, serverName: server.name, title: "", body: "",
                          outcome: MentionDropReason.noChannelContext.label,
                          delivered: false, at: now()), delivered: false,
                   reason: MentionDropReason.noChannelContext.label)
            return
        }
        guard let channel else {
            routing.noteSocketPost(isMention: false)
            return
        }

        let decision = MentionNotificationPolicy.decision(post: post, reader: reader,
                                                         channel: channel, membership: membership)
        switch decision {
        case .drop(let reason):
            // A non-mention is the overwhelmingly common case (every message in a busy channel arrives
            // here), so it is counted but not recorded as an event worth showing.
            if reason != .notAMention {
                record(Record(postID: post.id, channelID: post.channelId,
                              channelLabel: channel.displayName, serverID: server.id,
                              serverName: server.name, title: "", body: "",
                              outcome: reason.label, delivered: false, at: now()),
                       delivered: false, reason: reason.label)
            }
            // T43-R (F1): the ring is written by the input that **decided**, and only for a decision the
            // reader's own configuration made (notifications off, mentions ignored). "Not a mention" and
            // "the channel could not be resolved" are not decisions about delivery — they stay pollable,
            // so the T14 poll can still deliver a mention this path could not classify.
            if reason.recordsAsHandled {
                ledger.observe(postID: post.id, createAt: post.createAt, for: server.id)
            }
            routing.noteSocketPost(isMention: false)

        case .deliver(let silent):
            routing.noteSocketPost(isMention: true)
            let username = (try? await service(for: server).users(ids: [post.userId]))?
                .first(where: { $0.id == post.userId })?.username
            let mention = MentionNotificationFormatting.mention(
                title: MentionNotificationFormatting.title(channelDisplayName: channel.displayName),
                body: MentionNotificationFormatting.body(message: post.message, username: username),
                channelID: post.channelId,
                teamID: channel.teamId,
                serverURL: server.url.absoluteString,
                silent: silent)

            // **T54: one decision, two presentations.**
            //
            // The `decision` above is the only mention rule in the app. This second, smaller decision asks
            // *where* to show it, from facts about what the reader is looking at. With no banner surface in
            // the process (`bannerCenter == nil` — a unit host, or a shell that has not mounted one) the
            // answer is the pre-T54 one: hand it to `NotificationWorker`.
            let bannerCenter = self.bannerCenter
            let presentation = bannerCenter == nil
                ? MentionPresentation.systemNotification(silent: silent)
                : MentionPresentationPolicy.presentation(for: decision,
                                                         channelID: post.channelId,
                                                         surface: surfaceContext(for: server))
            switch presentation {
            case .inAppBanner:
                // The in-app surface. The ledger is written by the surface that **did** show it (T43-R F1),
                // which is what stops the T14 poll from turning the same post into a second banner.
                ledger.observe(postID: post.id, createAt: post.createAt, for: server.id)
                let banner = MentionBanner(serverID: server.id,
                                           serverName: server.name,
                                           teamID: channel.teamId,
                                           channelID: post.channelId,
                                           channelLabel: channel.displayName,
                                           postID: post.id,
                                           author: username,
                                           body: mention.body,
                                           silent: silent,
                                           receivedAt: now())
                let shown = bannerCenter?.present(banner) ?? .ignoredIncomplete
                let refusal = "the in-app banner refused it (" + shown.label + ")"
                record(Record(postID: post.id, channelID: post.channelId,
                              channelLabel: channel.displayName, serverID: server.id,
                              serverName: server.name, title: mention.title, body: mention.body,
                              outcome: shown == .ignoredIncomplete ? refusal : "delivered",
                              delivered: shown != .ignoredIncomplete, at: now(),
                              surface: "in-app banner"),
                       delivered: shown != .ignoredIncomplete,
                       reason: shown == .ignoredIncomplete ? shown.label : nil)
                if shown != .ignoredIncomplete { scheduleBadgeRefresh(server: server) }

                // T8's once-per-install permission prompt still has to happen (a banner needs none, but the
                // first *backgrounded* mention would otherwise be dropped), and it must **not** gate the
                // banner: `requestAuthorization` suspends until the reader answers the modal system alert.
                // Awaiting it here held the first mention's banner back for as long as the alert was up —
                // measured on the live run (the app sat behind the alert with no `mentionBanner` element for
                // the whole 45 s wait, while later runs with the permission already answered showed it at
                // once). So the ask is fired *after* the banner is on screen, off the delivery path.
                if let askForNotificationPermission {
                    Task { await askForNotificationPermission() }
                }

            case .suppressed(let block):
                // Both surfaces are the wrong answer: this is the conversation on screen (or, in Path A, the
                // page owns it). T43's rule is kept verbatim — the drop is recorded, and the post counts as
                // handled, because the worker's own `viewShouldNotNotify` denial used to write the ring for
                // exactly the same reason.
                ledger.observe(postID: post.id, createAt: post.createAt, for: server.id)
                record(Record(postID: post.id, channelID: post.channelId,
                              channelLabel: channel.displayName, serverID: server.id,
                              serverName: server.name, title: "", body: "",
                              outcome: block.label, delivered: false, at: now()),
                       delivered: false, reason: block.label)

            case .systemNotification:
                let outcome = await deliver(mention, serverID: server.id)
                // Record the attempt whatever the outcome, the poller's rule: a denied permission must not be
                // retried on every message, and the ring is "already handled", not "already shown".
                //
                // T43-R (F1): this is the **only** place the socket input writes the ring, and it is written
                // by the delivery that actually happened — which is what makes the ledger honest for the
                // poller that reads it.
                ledger.observe(postID: post.id, createAt: post.createAt, for: server.id)
                switch outcome {
                case .scheduled:
                    record(Record(postID: post.id, channelID: post.channelId,
                                  channelLabel: channel.displayName, serverID: server.id,
                                  serverName: server.name, title: mention.title, body: mention.body,
                                  outcome: "delivered", delivered: true, at: now(),
                                  surface: "system notification"),
                           delivered: true, reason: nil)
                case .notSent(let reason):
                    let label = Self.label(for: reason)
                    record(Record(postID: post.id, channelID: post.channelId,
                                  channelLabel: channel.displayName, serverID: server.id,
                                  serverName: server.name, title: mention.title, body: mention.body,
                                  outcome: label, delivered: false, at: now()),
                           delivered: false, reason: label)
                }
                // The badge follows the same server counters the poller reads (never a local increment).
                scheduleBadgeRefresh(server: server)
            }
        }
    }

    // MARK: - Badge

    /// What the shell is showing for a server, in the terms `MentionPresentationPolicy` reads.
    ///
    /// Both facts come from the shell's own objects, never from a guess: the primary server is the
    /// `ViewStore`'s (the same value the notification worker compares against), and the conversation on
    /// screen is the closure `MattermostApp` installs on **both** this feed and the worker.
    private func surfaceContext(for server: ServerConfig) -> MentionSurfaceContext {
        let primary = viewStore?.primaryServerID ?? serverStore?.activeServerID
        return MentionSurfaceContext(appIsActive: isAppActive(),
                                     isPrimaryServer: primary == server.id,
                                     onScreen: visibleChannel?(server.id) ?? .unknown)
    }

    /// One `GET /users/me/teams/unread` per burst, applied through `SessionStore`'s single arithmetic.
    private func scheduleBadgeRefresh(server: ServerConfig) {
        guard pendingBadgeRefresh[server.id] == nil else { return }
        pendingBadgeRefresh[server.id] = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(max(0, self.badgeRefreshDelay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.pendingBadgeRefresh[server.id] = nil
            guard let counters = try? await self.service(for: server).badgeCounters() else { return }
            guard let sessionStore = self.sessionStore else { return }
            sessionStore.applyServerCounters(serverID: server.id,
                                             mentionCounts: counters.map(\.mentionCount),
                                             messageCounts: counters.map(\.msgCount))
            Logger.debug("NativeNotificationFeed",
                         "\(server.name): badge counters refreshed (\(counters.count) team rows)")
        }
    }

    // MARK: - Test/diagnostic surface

    /// Apply a socket mention synchronously in a unit test: awaits the coalesced badge refresh too, so a
    /// test can assert what reached `SessionStore` without sleeping.
    func flushBadgeRefresh(for serverID: UUID) async {
        guard let task = pendingBadgeRefresh[serverID] else { return }
        await task.value
    }

    // MARK: - Plumbing

    private func deliver(_ mention: MentionNotification,
                         serverID: UUID) async -> NotificationWorker.PresentOutcome {
        if let deliverMention { return await deliverMention(mention, serverID) }
        return await NotificationWorker.shared.presentMention(mention, fromServerID: serverID)
    }

    private func record(_ record: Record, delivered: Bool, reason: String?) {
        lastRecord = record
        if delivered { deliveredCount += 1 } else { droppedCount += 1 }
        routing.noteSocketDelivery(delivered: delivered, reason: reason)
        Logger.info("NativeNotificationFeed",
                    "posted \(record.postID) on \(record.serverName) -> \(record.outcome)")
    }

    private func reader(for server: ServerConfig) async throws -> MentionReader {
        if let cached = readers[server.id] { return cached }
        let profile = try await service(for: server).profile()
        let reader = MentionReader.make(from: profile)
        readers[server.id] = reader
        return reader
    }

    private func channel(for channelID: String, server: ServerConfig) async throws -> MMChannel? {
        if let cached = channelCache[server.id]?[channelID] { return cached }
        let channel = try await service(for: server).channel(id: channelID)
        guard !channel.id.isEmpty else { return nil }
        channelCache[server.id, default: [:]][channelID] = channel
        return channel
    }

    private func service(for server: ServerConfig) -> ActivityServing {
        if let serviceFactory { return serviceFactory(server) }
        // The app installs its factory in `MattermostApp.bindShellStores()` (only it holds the
        // `AuthCoordinator`). This fallback is deliberately a service that resolves to no client: a feed
        // that was never bound fails closed with `MMError.notSignedIn` and says so, rather than fetching
        // with a credential it does not own.
        Logger.error("NativeNotificationFeed",
                     "\(server.name): no service factory installed — the native input cannot fetch")
        return SessionActivityService { nil }
    }

    static func label(for reason: NotificationWorker.NotSentReason) -> String {
        switch reason {
        case .missingServer: return "the server is no longer configured"
        case .viewShouldNotNotify: return "you are looking at this channel"
        case .authorizationNotDetermined: return "notification permission has not been answered"
        case .authorizationDenied: return "notification permission was denied"
        case .addFailed: return "the system refused to schedule the notification"
        }
    }
}
