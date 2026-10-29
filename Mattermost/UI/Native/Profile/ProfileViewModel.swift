// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/user_profile/index.ts (the load, "user not found" and retry states),
//        app/actions/remote/user.ts (`fetchUserIfNeeded`, `setStatus`, `setCustomStatus`,
//        `unsetCustomStatus` — all optimistic with a rollback), app/actions/websocket/user.ts
//        (`status_change` → USER_STATUS, `user_updated` → USER_PROFILE),
//        app/screens/custom_status_clear_after/ (the duration choice).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §18; no
// upstream source copied. Decomposition is this repo's own (`docs/component-map.md` §1).
//
// ## The rules this model exists to keep
//
//  1. **Fetched, not faked.** A profile the app has not stored is read from the server. If that read
//     fails there is an error with a retry, never a row assembled out of the user id: a colleague's
//     name is not something a client may invent.
//  2. **Only my own status is writable.** `PUT /users/{id}/status/custom` writes to the id in the
//     path, so the setter is drawn for me alone; on somebody else's profile the "Set a status" row is
//     absent rather than present-and-refused.
//  3. **A write that fails leaves the screen as it was.** Both writes are optimistic (the reader sees
//     the change immediately — that is what upstream does) and roll back on failure with a sentence
//     naming what failed. A status is a promise to colleagues; showing one that was rejected is worse
//     than showing a spinner.
//  4. **The socket is the source of live truth.** `status_change` patches presence in place;
//     `user_updated` re-reads the profile, because the server publishes that event when a custom
//     status changes (`App.SetCustomStatus` → `sendUpdatedUserEvent`, which keeps `Props`) and the
//     event's own payload is the app's older, props-less user model.

import Foundation
import Combine

@MainActor
final class ProfileViewModel: ObservableObject {

    /// What the screen is doing. `loaded` with a `nil` profile is not a state: a load either produced
    /// a profile or a failure.
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    let serverID: UUID
    /// The account this model is about.
    let userID: String

    private let service: ProfileServing
    /// Injected clock: expiry and "last active" are functions of time, and a test that had to sleep
    /// to observe an expiry would be testing the runner.
    private let now: () -> Date
    private let calendar: Calendar

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var profile: MMUserProfile?
    @Published private(set) var status: UserStatusSnapshot?
    /// My own id, so the screen knows whether this is me. Set by the coordinator.
    @Published private(set) var myUserID: String?
    /// The avatar bytes. `nil` draws initials — the normal case for accounts without a picture.
    @Published private(set) var avatar: Data?

    /// A write in flight (both writes share it: they are the same sheet and never run together).
    @Published private(set) var isWriting = false
    /// The last write's failure, reader-facing.
    @Published private(set) var banner: String?
    /// The conversation behind "Send message", once the server answered.
    @Published private(set) var conversation: MMChannel?
    /// Why "Send message" failed, when it did.
    @Published private(set) var conversationFailure: String?

    /// Told to the coordinator whenever my own presence changes, so the auto-away pass reasons about
    /// the status this app just wrote rather than a stale reading.
    var onMyStatusChanged: ((UUID, UserStatusSnapshot) -> Void)?

    private var loadGeneration = 0
    private var profileRefreshTask: Task<Void, Never>?

    init(serverID: UUID,
         userID: String,
         myUserID: String?,
         service: ProfileServing,
         now: @escaping () -> Date = Date.init,
         calendar: Calendar = .current) {
        self.serverID = serverID
        self.userID = userID
        self.myUserID = myUserID
        self.service = service
        self.now = now
        self.calendar = calendar
    }

    // MARK: Derived

    /// Whether this profile is the signed-in reader's own.
    var isMe: Bool {
        guard let myUserID, !myUserID.isEmpty else { return false }
        return myUserID == userID
    }

    /// The presence to draw. Unknown until a status read answers — never assumed offline.
    var presence: UserPresence { status?.presence ?? .unknown }

    /// The custom status the profile draws, when it is still in force.
    var activeCustomStatus: UserCustomStatus? {
        guard let status = profile?.customStatus, status.isActive(at: now()) else { return nil }
        return status
    }

    /// "Send message" is offered only when it can work (see `DMShortcut`).
    var canMessage: Bool {
        guard let profile else { return false }
        return DMShortcut.canMessage(profile: profile, myUserID: myUserID)
    }

    var messageUnavailableReason: String? {
        guard let profile else { return nil }
        return DMShortcut.unavailableReason(profile: profile, myUserID: myUserID)
    }

    /// The permission-gated rows this popover offers (`ProfileActionSet`): Message for somebody
    /// else, the status entries on my own profile, nothing for a deactivated account. The screen
    /// draws *this*, so the matrix the card specifies is one pure rule instead of three `if`s in the
    /// view that could drift apart.
    var actions: ProfileActionSet {
        guard let profile else {
            return ProfileActionSet(offered: [], messageUnavailableReason: nil)
        }
        return ProfileActionSet.resolve(profile: profile,
                                        myUserID: myUserID,
                                        hasCustomStatus: activeCustomStatus != nil)
    }

    /// The setter's current value: the row that is ticked.
    var selectedPresence: UserPresence? {
        guard isMe, let status, status.presence != .unknown else { return nil }
        return status.presence
    }

    // MARK: Load

    /// Read the profile and its presence from the server.
    ///
    /// A **warm** model (the coordinator kept it after the sheet closed, see `ProfileCoordinator`'s
    /// LRU) does not re-read the profile — that would blink a screen whose content the server has
    /// not changed — but it does read *presence* once, because the sheet may have been closed for
    /// minutes and this server never sends a colleague's `status_change` (T41-AV F2: reopening a
    /// warm profile showed the cached dot until the first poll, 15 s later). `force` re-reads both
    /// and is what pull-to-refresh uses.
    func load(force: Bool = false) async {
        if !force, phase == .loaded {
            await refreshPresence()
            return
        }
        if phase != .loaded { phase = .loading }
        banner = nil
        loadGeneration += 1
        let generation = loadGeneration
        guard !userID.isEmpty else {
            phase = .failed("This account could not be identified.")
            return
        }
        do {
            // Both reads in parallel: the profile and the presence are independent facts and the
            // screen needs both before it can draw a dot that means anything.
            async let profileRead = service.profile(id: userID)
            async let statusRead = service.statuses(ids: [userID])
            let (loaded, statuses) = try await (profileRead, statusRead)
            guard generation == loadGeneration else { return }
            guard !loaded.id.isEmpty else {
                phase = .failed("The server answered a profile without an id.")
                return
            }
            profile = loaded
            if let match = statuses.first(where: { $0.userId == userID }) {
                status = Self.snapshot(from: match)
            } else if status == nil {
                status = UserStatusSnapshot(userID: userID, presence: .unknown)
            }
            phase = .loaded
            await loadAvatar(for: loaded)
        } catch {
            guard generation == loadGeneration else { return }
            // A failed read keeps whatever was already drawn (the screen is not blanked) and names
            // the failure; with nothing drawn it is a failure state with a retry.
            if profile == nil {
                phase = .failed(Self.loadFailureCopy(error))
            } else {
                banner = Self.loadFailureCopy(error)
            }
        }
    }

    /// The avatar, fetched only when the profile is drawn (one request, no retry storm).
    private func loadAvatar(for profile: MMUserProfile) async {
        guard avatar == nil else { return }
        avatar = await service.profileImage(userID: profile.id, lastUpdateAt: profile.updateAt)
    }

    // MARK: Presence refresh — why a socket cannot carry a colleague's status

    /// How often an open profile re-reads presence.
    ///
    /// **Measured, and it changes what "live" means here** (`scripts/t41_profile_probe.py` §5): the
    /// server publishes `status_change` with `broadcast.user_id` set to the account that changed
    /// (`app/platform/status.go`: `NewWebSocketEvent(StatusChange, "", "", status.UserId, …)`), so that
    /// frame reaches **that account's own connections only**. The probe's own transcript shows the
    /// negative with its control: in one 12 s window my socket receives no `status_change` for the
    /// buddy, yet it does receive the buddy's team-scoped `posted` — so "nothing arrived" is not a
    /// dead listener. A raw client subscribed to a team receives `posted` and friends for everybody but
    /// never another account's `status_change`; the browser cannot be learning a colleague's presence
    /// from the socket either. It learns it from the batched read, `POST /users/status/ids`, which is
    /// why this loop exists: the sheet reads presence once on open (`load()`) and then keeps it current
    /// here.
    static var defaultPresenceInterval: TimeInterval = 15

    /// Re-read presence until the caller's task is cancelled (the sheet's `.task`, i.e. until the
    /// profile closes). A cancelled sleep returns immediately, so closing the sheet stops the requests.
    func runPresenceUpdates(interval: TimeInterval? = nil) async {
        let period = max(0.05, interval ?? Self.defaultPresenceInterval)
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(period * 1_000_000_000))
            if Task.isCancelled { return }
            await refreshPresence()
        }
    }

    /// One batched presence read for this account. Silent on failure: the row already on screen is not
    /// wrong, and a background poll must never put a banner over a profile the reader is reading.
    func refreshPresence() async {
        guard phase == .loaded, !isWriting else { return }
        guard let rows = try? await service.statuses(ids: [userID]),
              let match = rows.first(where: { $0.userId == userID }) else { return }
        var fresh = Self.snapshot(from: match)
        // The batched row is authoritative for presence, `manual` and activity. It is *not* where a
        // do-not-disturb end time comes from for a peer (that field is only populated on the write's
        // answer), so an unchanged presence keeps the end time this screen already holds.
        if fresh.presence == status?.presence { fresh.dndEndTime = status?.dndEndTime }
        guard fresh != status else { return }
        status = fresh
        if isMe { onMyStatusChanged?(serverID, fresh) }
    }

    // MARK: Presence (my own only)

    /// Set my presence, with an optional "do not disturb" end time.
    ///
    /// `nil` `dndDuration` means "no end time". Anything but `.dnd` with a duration is a caller bug,
    /// so this refuses it rather than sending a body the server would silently keep forever.
    func setPresence(_ presence: UserPresence, dndDuration: StatusDuration? = nil) async {
        guard isMe else {
            banner = "You can only change your own status."
            return
        }
        guard !isWriting else { return }
        guard presence != .unknown else { return }
        var endMillis: Int64?
        if presence == .dnd, let dndDuration, dndDuration != .doNotClear {
            endMillis = dndDuration.dndEndTimeMillis(from: now(), calendar: calendar)
        }
        let previous = status
        isWriting = true
        banner = nil
        // Optimistic: the dot and the row change before the round trip, which is what makes the
        // control feel like a switch rather than a form.
        status = UserStatusSnapshot(userID: userID,
                                    presence: presence,
                                    manual: presence.setsManualFlag,
                                    lastActivityAt: previous?.lastActivityAt,
                                    dndEndTime: endMillis.map { Date(timeIntervalSince1970: Double($0) / 1000) })
        do {
            let answer = try await service.setPresence(presence,
                                                       dndEndTime: endMillis,
                                                       userID: userID)
            isWriting = false
            // The server's own row is the truth (it normalises `manual` — measured: `online` comes
            // back `manual: false`, `away`/`dnd` `manual: true`).
            let confirmed = Self.snapshot(from: answer)
            status = confirmed
            onMyStatusChanged?(serverID, confirmed)
        } catch {
            isWriting = false
            status = previous
            banner = Self.writeFailureCopy(error, what: "status")
        }
    }

    /// Apply my status as the coordinator learned it (auto-away writes, or a socket frame), so an
    /// open profile does not disagree with the app.
    func applyMyStatus(_ snapshot: UserStatusSnapshot) {
        guard snapshot.userID == userID else { return }
        status = snapshot
    }

    // MARK: Custom status (my own only)

    /// Save a custom status. Returns `true` when the server accepted it.
    @discardableResult
    func saveCustomStatus(_ draft: CustomStatusDraft) async -> Bool {
        guard isMe else {
            banner = "You can only change your own custom status."
            return false
        }
        guard !isWriting else { return false }
        let moment = now()
        guard let body = draft.body(at: moment, calendar: calendar) else {
            banner = draft.validationMessage(at: moment) ?? "That status cannot be sent."
            return false
        }
        let previous = profile
        isWriting = true
        banner = nil
        // Optimistic: the pill draws the new status while the write is in flight.
        profile = Self.profile(profile, applying: body)
        do {
            try await service.setCustomStatus(userID: userID, body: body)
            isWriting = false
            return true
        } catch {
            isWriting = false
            profile = previous
            banner = Self.writeFailureCopy(error, what: "custom status")
            return false
        }
    }

    /// Clear the custom status. Returns `true` when the server accepted it.
    @discardableResult
    func clearCustomStatus() async -> Bool {
        guard isMe else {
            banner = "You can only change your own custom status."
            return false
        }
        guard !isWriting else { return false }
        let previous = profile
        isWriting = true
        banner = nil
        profile = Self.profile(profile, clearingCustomStatus: true)
        do {
            try await service.clearCustomStatus(userID: userID)
            isWriting = false
            return true
        } catch {
            isWriting = false
            profile = previous
            banner = Self.writeFailureCopy(error, what: "custom status")
            return false
        }
    }

    // MARK: The DM shortcut

    /// Create-or-find the conversation with this account (`POST /channels/direct`).
    ///
    /// The channel is published rather than navigated to here: the view owns presentation, and the
    /// model has no navigation authority (the same split as T40's browse model, which hands its join
    /// target back to the host).
    func openConversation() async {
        guard let profile, let myUserID, !myUserID.isEmpty else {
            conversationFailure = messageUnavailableReason ?? "A conversation cannot be started."
            return
        }
        guard DMShortcut.canMessage(profile: profile, myUserID: myUserID) else {
            conversationFailure = messageUnavailableReason
            return
        }
        guard !isWriting else { return }
        isWriting = true
        conversationFailure = nil
        do {
            let channel = try await service.directChannel(myUserID: myUserID, otherUserID: profile.id)
            isWriting = false
            guard channel.id.isEmpty == false else {
                conversationFailure = "The server answered a conversation without an id."
                return
            }
            guard channel.type.isEmpty || channel.type == "D" else {
                // `POST /channels/direct` is documented to answer a `D` channel; anything else means
                // the answer cannot be drawn as a conversation, and saying so is better than opening
                // a pane for the wrong channel.
                conversationFailure = "The server answered a channel this app cannot open as a conversation."
                return
            }
            conversation = channel
        } catch {
            isWriting = false
            conversationFailure = MMErrorCopy.message(
                for: error,
                offline: "You appear to be offline. The conversation was not created.",
                timeout: "The server took too long to answer. The conversation was not created.",
                unauthorized: "Your session has expired. Sign in again to send a message.",
                forbidden: "You do not have permission to message this account.",
                notFound: "That account no longer exists.",
                rateLimited: "The server is busy. Try again shortly.",
                fallback: "The conversation could not be created."
            )
        }
    }

    /// The host consumed the navigation (the sheet is closing).
    func consumeConversation() { conversation = nil }

    func consumeBanner() { banner = nil }

    // MARK: Socket

    /// One event from the server's socket (the rail's single connection — see the coordinator).
    func handle(_ event: SocketEvent) {
        switch event {
        case .statusChange(let change) where change.userID == userID:
            // The frame carries only the status: keep the `manual`/`last_activity_at`/`dnd_end_time`
            // the batched read supplied, or the auto-away pass would mistake a deliberate `away` for
            // its own doing.
            if let current = status {
                status = current.applying(socketStatus: change.status)
            } else {
                status = UserStatusSnapshot(userID: userID, presence: UserPresence(wire: change.status))
            }
        case .userUpdated(let user) where user.id == userID:
            // A rename, a role change or a custom status set from another client. The event carries
            // the app's props-less rendering model, so the profile is re-read rather than patched.
            scheduleProfileRefresh()
        default:
            break
        }
    }

    /// Re-read once per burst. A `user_updated` storm (a display-name batch job) must not turn into a
    /// request storm on a screen that is open.
    private func scheduleProfileRefresh() {
        profileRefreshTask?.cancel()
        profileRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await self?.refreshProfileOnly()
        }
    }

    /// Re-read the profile without touching the presence row (`GET /users/{id}` only).
    private func refreshProfileOnly() async {
        loadGeneration += 1
        let generation = loadGeneration
        do {
            let loaded = try await service.profile(id: userID)
            guard generation == loadGeneration, !loaded.id.isEmpty else { return }
            profile = loaded
            if phase != .loaded { phase = .loaded }
        } catch {
            // Silent on purpose: the profile that is already drawn is not wrong, and a banner for a
            // background refresh would be noise.
            return
        }
    }

    // MARK: Internals

    /// `MMStatus` (the wire row) → the model's snapshot.
    ///
    /// The batched read and the presence write answer the same shape, so both go through here — and
    /// `dnd_end_time` is kept: without it a do-not-disturb can only be drawn as permanent, and the
    /// server *does* send the end time (measured; `MMStatus.dndEndTime`).
    static func snapshot(from status: MMStatus) -> UserStatusSnapshot {
        UserStatusSnapshot(
            userID: status.userId,
            presence: UserPresence(wire: status.status),
            manual: status.manual,
            lastActivityAt: status.lastActivityAt > 0
                ? Date(timeIntervalSince1970: Double(status.lastActivityAt) / 1000)
                : nil,
            dndEndTime: status.dndEndTime > 0
                ? Date(timeIntervalSince1970: Double(status.dndEndTime) / 1000)
                : nil
        )
    }

    /// The profile with the custom status this draft describes, so the optimistic draw is the one the
    /// server is being asked to store (not a second rendering of the same fields).
    static func profile(_ profile: MMUserProfile?, applying body: CustomStatusBody) -> MMUserProfile? {
        guard var copy = profile else { return nil }
        let wire = UserCustomStatus.Wire(emoji: body.emoji, text: body.text,
                                         duration: body.duration, expiresAt: body.expiresAt)
        setCustomStatus(wire, in: &copy)
        return copy
    }

    static func profile(_ profile: MMUserProfile?, clearingCustomStatus clear: Bool) -> MMUserProfile? {
        guard var copy = profile, clear else { return profile }
        copy.props["customStatus"] = ""
        return copy
    }

    /// Write the status JSON into `props` exactly the way the server does (a JSON string).
    private static func setCustomStatus(_ status: UserCustomStatus.Wire, in profile: inout MMUserProfile) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(status),
              let json = String(data: data, encoding: .utf8) else { return }
        profile.props["customStatus"] = json
    }

    static func loadFailureCopy(_ error: Error) -> String {
        MMErrorCopy.message(
            for: error,
            offline: "You appear to be offline, so this profile could not be read.",
            timeout: "The server took too long to answer.",
            unauthorized: "Your session has expired. Sign in again to see this profile.",
            forbidden: "You do not have permission to see this profile.",
            notFound: "That account no longer exists on this server.",
            rateLimited: "The server is busy. Try again shortly.",
            fallback: "This profile could not be read."
        )
    }

    static func writeFailureCopy(_ error: Error, what: String) -> String {
        MMErrorCopy.message(
            for: error,
            offline: "You appear to be offline, so your \(what) was not saved.",
            timeout: "The server took too long to answer, so your \(what) was not saved.",
            unauthorized: "Your session has expired. Sign in again to change your \(what).",
            forbidden: "You do not have permission to change your \(what).",
            notFound: "The server could not find that account.",
            rateLimited: "The server is busy. Your \(what) was not saved.",
            fallback: "Your \(what) was not saved."
        )
    }
}
