// T43: **one** high-water mark per server, for both mention inputs.
//
// Before this file, `MentionPoller` (T14) owned the persisted state outright: it loaded
// `ServerMentionState` from `AppPreferences` at the start of a poll and wrote it back at the end, so
// "what the poller has already seen" was a private fact. The socket input needs the *same* fact — a
// mention delivered live must not be delivered again by the next background poll, and the poller's
// `since=` window should not re-fetch a post the socket has already handled. Two ledgers would be two
// truths, which is exactly what the card's last acceptance criterion forbids.
//
// So the state moved into this one object and both callers use it. The *key* did not change
// (`mm.mentions.state.<serverUUID>`), so an install that already polled keeps its watermark.
//
// What the state means (unchanged from T14, now written down where both callers can see it):
//   * `watermarkTs` / `watermarkPostID` — the newest `create_at` (ms) this shell has handled. Both callers
//     only ever move it **forward**.
//   * `notifiedPostIDs` — a bounded ring of post ids already handled. Despite the name (T14's), it is
//     "already seen": the socket records every post it processes, not only the ones it notified, because
//     the ring is what stops a re-fetch from producing a second banner.
//   * `channelMentionCounts` — the poller's per-channel snapshot, used to decide which channels to fetch.
//     The socket input never writes it (it has no full snapshot) and never reads it.

import Foundation

@MainActor
final class MentionLedger {

    /// The persisted key. One definition, and it is T14's original key so existing installs keep their
    /// cursor (`MentionPoller.stateKey` forwards here).
    nonisolated static func stateKey(for serverID: UUID) -> String {
        "mm.mentions.state.\(serverID.uuidString)"
    }

    private let preferences: AppPreferences

    init(preferences: AppPreferences? = nil) {
        self.preferences = preferences ?? AppPreferences()
    }

    func state(for serverID: UUID) -> ServerMentionState {
        preferences.get(ServerMentionState.self, forKey: Self.stateKey(for: serverID))
            ?? ServerMentionState()
    }

    func save(_ state: ServerMentionState, for serverID: UUID) {
        preferences.set(state, forKey: Self.stateKey(for: serverID))
    }

    func hasHandled(_ postID: String, for serverID: UUID) -> Bool {
        !postID.isEmpty && state(for: serverID).hasNotified(postID)
    }

    /// Record one handled post: into the ring, and — when it is newer than anything seen — into the
    /// watermark. Returns the state as persisted, which is what the tests and the diagnostics read.
    @discardableResult
    func observe(postID: String, createAt: Int64, for serverID: UUID) -> ServerMentionState {
        var state = state(for: serverID)
        if !postID.isEmpty { state.recordNotified(postID) }
        if createAt > state.watermarkTs {
            state.watermarkTs = createAt
            state.watermarkPostID = postID
        }
        save(state, for: serverID)
        return state
    }

    /// Merge a poller-computed state into the persisted one, so a socket event that landed *while the
    /// poll was in flight* is not lost.
    ///
    /// The poller holds its state in memory across several network round trips. The socket input writes
    /// the same state concurrently (from the main actor, between the poller's awaits). A plain save would
    /// overwrite the socket's ring entry and re-open the duplicate the shared state exists to prevent, so
    /// the write is a union: the ring keeps both sets (newest first, capped), the watermark takes the later
    /// stamp, and the per-channel snapshot is the poller's (only it produces one).
    func merge(_ state: ServerMentionState, for serverID: UUID) {
        var current = self.state(for: serverID)
        var ring = current.notifiedPostIDs
        for id in state.notifiedPostIDs where !ring.contains(id) { ring.append(id) }
        current.notifiedPostIDs = Array(ring.prefix(ServerMentionState.maxNotifiedRing))
        if state.watermarkTs > current.watermarkTs {
            current.watermarkTs = state.watermarkTs
            current.watermarkPostID = state.watermarkPostID
        }
        current.channelMentionCounts = state.channelMentionCounts
        save(current, for: serverID)
    }

    /// Replace the poller's per-channel snapshot after a poll (the delta source for the next poll).
    func setChannelMentionCounts(_ counts: [String: Int], for serverID: UUID) {
        var state = state(for: serverID)
        state.channelMentionCounts = counts
        save(state, for: serverID)
    }

    /// Seed the watermark on a first run (T14: notify nothing older than the watermark). Kept here so the
    /// poller has no private write path left.
    func seed(watermarkTs: Int64, channelMentionCounts: [String: Int], for serverID: UUID) {
        var state = state(for: serverID)
        state.watermarkTs = watermarkTs
        state.channelMentionCounts = channelMentionCounts
        save(state, for: serverID)
    }
}
