// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/components/channel_icon/ (the DM face and the GM composite), app/components/channel_item/
//        (the presence dot on that face), app/actions/websocket/user.ts (`status_change` →
//        PATCH_USER_STATUS), app/client/rest/users.ts (`getStatusesByIds`, batched), and
//        app/utils/user_helper.ts (`getUserIdFromChannelName` — the membership read that turns a DM's
//        `<id>__<id>` name into the other person). Licence: Apache-2.0 — behaviour ported with
//        attribution per docs/THIRD_PARTY_NOTICES.md §3; no upstream source copied.
//
// What this file is: the *person facts* a direct-message row needs — who the row is about, what the
// server says their presence is, and the rules that keep that answer cheap and honest. It is pure
// except for `SidebarPresenceStore`, which is the one object that may spend a request.
//
// Three decisions, because the card asks for them to be made and recorded:
//
//  1. **A GM draws a composite, not a status.** The first participant's face at full size, the
//     second's smaller in the corner, and a `+N` chip for a third and beyond. A single dot cannot
//     describe several people's statuses, so a GM row carries **no** presence dot — upstream draws
//     presence for a DM (one other person) and not for a group.
//  2. **Unknown is not offline, and offline is not absent.** A person whose presence has not been
//     read yet draws the same quiet ring as an offline person (`SidebarPresencePalette`), but the
//     row's accessibility value says nothing rather than claiming "Offline" (`word(for:)` returns
//     nil for `.unknown`). An offline person still draws a dot — hollow, quiet, not missing.
//  3. **A green dot has an expiry.** The server publishes `status_change`, but this client measured
//     that it addresses that frame to the account whose status changed (`docs/parity-legacy.md`,
//     T41 row: a peer's presence never arrives over the socket on 9.11.19), so a peer's "online" is
//     only true as of the last batch read. `staleAfter` turns an unconfirmed online/away/dnd into
//     offline: a stale green dot is a lie, and this card is about not telling it.

import Foundation
import SwiftUI

// MARK: - A person in a row

/// One participant of a DM/GM row: what the avatar is drawn from and who the presence belongs to.
struct SidebarParticipant: Identifiable, Equatable, Sendable {
    /// The account id — the avatar's cache key (`GET /users/{id}/image`) and the presence key.
    let userID: String
    /// The person's name as the row's label spells it (nickname, full name, else username).
    let displayName: String
    /// The fallback drawn under the picture, so a slow or missing image is initials and never a blank
    /// box (the same grapheme rule the member list uses).
    let initials: String

    var id: String { userID }

    init(userID: String, displayName: String, initials: String) {
        self.userID = userID
        self.displayName = displayName
        self.initials = initials
    }

    /// From the profile the label step already fetched — no name or initial is invented here.
    ///
    /// `@MainActor` because the name comes from `DirectLabelResolver.label(for:)`, the one rule the
    /// row's label and the quick switcher share; reading it anywhere else would be a second spelling
    /// of a person's name.
    @MainActor
    init(user: MMUser) {
        let name = DirectLabelResolver.label(for: user)
        self.init(userID: user.id,
                  displayName: name,
                  initials: ChannelMemberDerivation.initials(name))
    }
}

// MARK: - Presence

/// One account's presence **and when it was observed** — the second half is what makes a stale
/// "online" detectable at draw time.
struct SidebarPresenceSnapshot: Equatable, Sendable {
    var userID: String
    var presence: UserPresence
    /// When this value was read from the server (a batch answer or a socket frame).
    var observedAt: Date
}

/// Every rule the sidebar's presence obeys, as pure functions.
enum SidebarPresenceRules {

    /// The most ids one `POST /users/status/ids` carries. 200 DM rows are therefore two requests,
    /// not two hundred (the card's cost requirement, measured in
    /// `MattermostTests/T3ee44893SidebarAvatarPresenceTests.swift`).
    static let statusBatchSize = 100

    /// A snapshot younger than this is not re-requested: the answer a minute ago is the answer, and
    /// a redraw / scroll tick / second appearance costs nothing.
    static let refreshInterval: TimeInterval = 60

    /// How long an unconfirmed `online`/`away`/`dnd` is drawn as itself. Past this the dot goes quiet
    /// (offline) until a read confirms it again. An explicit `offline` never expires into anything
    /// else, so this only ever removes a *claim*, never adds one.
    static let staleAfter: TimeInterval = 10 * 60

    /// How often the sidebar re-reads the presence of the people it is drawing, while it is on
    /// screen. Equal to `refreshInterval`, so the poll is the thing that keeps the freshness window
    /// honest: one request per window for every DM row on the list.
    static let pollInterval: TimeInterval = 60

    /// Split `ids` into request-sized chunks (order-preserving, empty ids dropped).
    static func chunks(of ids: [String], size: Int = statusBatchSize) -> [[String]] {
        let clean = Array(Set(ids.filter { !$0.isEmpty })).sorted()
        guard size > 0, !clean.isEmpty else { return [] }
        return stride(from: 0, to: clean.count, by: size).map {
            Array(clean[$0..<min($0 + size, clean.count)])
        }
    }

    /// The ids with no snapshot, or with one older than `refreshInterval` (or stale past
    /// `staleAfter`, which the refresh interval is inside anyway). This is the cache: what is not
    /// in this list is not requested.
    static func idsNeedingRefresh(_ ids: [String],
                                  snapshots: [String: SidebarPresenceSnapshot],
                                  now: Date,
                                  interval: TimeInterval = refreshInterval) -> [String] {
        Array(Set(ids.filter { !$0.isEmpty })).sorted().filter { id in
            guard let snapshot = snapshots[id] else { return true }
            return now.timeIntervalSince(snapshot.observedAt) >= interval
        }
    }

    /// What the dot draws for `snapshot` at `now`. `nil` snapshot → `.unknown` (not `.offline`).
    static func effective(_ snapshot: SidebarPresenceSnapshot?,
                          now: Date,
                          staleAfter: TimeInterval = staleAfter) -> UserPresence {
        guard let snapshot else { return .unknown }
        switch snapshot.presence {
        case .online, .away, .dnd:
            return now.timeIntervalSince(snapshot.observedAt) <= staleAfter ? snapshot.presence : .offline
        case .offline:
            return .offline
        case .unknown:
            return .unknown
        }
    }

    /// The word the row's accessibility value gains ("Online", "Away", …). `nil` for an unread or
    /// unparseable status: VoiceOver is told what is known, never a guess at `Offline`.
    static func word(for presence: UserPresence) -> String? {
        presence == .unknown ? nil : presence.title
    }

    /// The snapshots a batch answer stands for, stamped with the read's own time.
    static func snapshots(from statuses: [MMStatus], at date: Date) -> [String: SidebarPresenceSnapshot] {
        var result: [String: SidebarPresenceSnapshot] = [:]
        for status in statuses where !status.userId.isEmpty {
            result[status.userId] = SidebarPresenceSnapshot(userID: status.userId,
                                                            presence: UserPresence(wire: status.status),
                                                            observedAt: date)
        }
        return result
    }

    /// One socket frame's snapshot. `status_change` carries only `user_id` + `status` (measured —
    /// see `UserStatusSnapshot.applying(socketStatus:)`), so the observation time is the frame's.
    static func snapshot(for userID: String, status: String, at date: Date) -> SidebarPresenceSnapshot? {
        guard !userID.isEmpty, !status.isEmpty else { return nil }
        return SidebarPresenceSnapshot(userID: userID,
                                       presence: UserPresence(wire: status),
                                       observedAt: date)
    }
}

// MARK: - The dot's colours

/// The presence dot's palette, in **one** place so a server theme can replace it without touching a
/// row.
///
/// The native shell has no server-theme palette today: `ThemeSync` carries only the light/dark
/// appearance (the server's own colours live in the webview's CSS). So these are the *system's*
/// semantic colours — the ones that follow light/dark and Increase Contrast — rather than literal
/// RGB values baked into the view, and the mapping is a function so a theme override is one change.
enum SidebarPresencePalette {

    /// The fill of a presence dot. Offline/unknown are the quiet grey that reads as "nothing to
    /// report", never a colour that claims activity.
    static func dot(_ presence: UserPresence) -> Color {
        switch presence {
        case .online: return .green
        case .away: return .orange
        case .dnd: return .red
        case .offline, .unknown: return Color.secondary.opacity(0.55)
        }
    }

    /// Whether the dot is drawn as a ring rather than a disc: offline is visually quiet, not absent.
    static func isHollow(_ presence: UserPresence) -> Bool {
        presence == .offline || presence == .unknown
    }
}

// MARK: - The store

/// The sidebar's presence memory: what has been read, when, and what still needs asking.
///
/// `@MainActor` like the rest of the screen's state: it is read while the rows are built and written
/// after an `await` back on the main actor, so there is no lock and no second copy. It is not an
/// `ObservableObject` — presence reaches the screen through `ChannelSidebarEntry` on the model's
/// rebuild, which is already a published value (a second publisher would repaint the same rows twice).
@MainActor
final class SidebarPresenceStore {

    /// `POST /users/status/ids` — injected so a test drives it without a server.
    private let load: ([String]) async throws -> [MMStatus]
    private let now: () -> Date

    private(set) var snapshots: [String: SidebarPresenceSnapshot] = [:]

    /// Diagnostics — and the numbers the card's cost note is written from.
    private(set) var requests = 0
    private(set) var requestedIDs = 0
    private(set) var cachedIDs = 0
    private(set) var failures = 0

    init(load: @escaping ([String]) async throws -> [MMStatus],
         now: @escaping () -> Date = Date.init) {
        self.load = load
        self.now = now
    }

    /// The stored snapshot, as read (no ageing) — the decay rule is applied where it is drawn.
    func snapshot(for userID: String) -> SidebarPresenceSnapshot? {
        snapshots[userID]
    }

    /// The presence the dot draws for `userID`, aged by the rules.
    func effective(for userID: String) -> UserPresence {
        SidebarPresenceRules.effective(snapshots[userID], now: now())
    }

    /// Adopt answers already in hand (the load's own read, a test fixture).
    func adopt(_ next: [String: SidebarPresenceSnapshot]) {
        for (id, snapshot) in next { snapshots[id] = snapshot }
    }

    /// Read whatever is missing or older than `refreshInterval`, in chunks of `statusBatchSize`.
    ///
    /// - Returns: how many requests were made (0 when every id was fresh — the cache doing its job).
    /// A failed chunk is **not** an answer: nothing is written for its ids, so the next read tries
    /// again and the rows keep what they had.
    @discardableResult
    func refresh(_ ids: [String], force: Bool = false) async -> Int {
        let unique = Array(Set(ids.filter { !$0.isEmpty })).sorted()
        let needed = force
            ? unique
            : SidebarPresenceRules.idsNeedingRefresh(unique, snapshots: snapshots, now: now())
        cachedIDs += max(0, unique.count - needed.count)
        guard !needed.isEmpty else { return 0 }

        var made = 0
        for chunk in SidebarPresenceRules.chunks(of: needed) {
            if Task.isCancelled { return made }
            made += 1
            requests += 1
            requestedIDs += chunk.count
            do {
                let statuses = try await load(chunk)
                adopt(SidebarPresenceRules.snapshots(from: statuses, at: now()))
            } catch {
                failures += 1
            }
        }
        return made
    }

    /// One `status_change` frame. Returns whether this account is one the sidebar is drawing —
    /// a frame about somebody with no DM row here must not cause a rebuild.
    @discardableResult
    func apply(userID: String, status: String, tracked: Set<String>) -> Bool {
        guard tracked.contains(userID),
              let snapshot = SidebarPresenceRules.snapshot(for: userID, status: status, at: now())
        else { return false }
        snapshots[userID] = snapshot
        return true
    }

    /// One line for the log and the build note.
    var diagnosticLine: String {
        "presence requests=\(requests) ids=\(requestedIDs) cached=\(cachedIDs) "
            + "failures=\(failures) known=\(snapshots.count)"
    }
}
