// t_e9550303 — where one landed read goes.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
//   - `app/actions/remote/channel.ts:746` — the view call, then `markChannelAsViewed` with
//     `onlyCounts = true`: the local row's counts clear **and** `viewedAt`/`lastViewedAt` move
//     (`app/actions/local/channel.ts:175`).
//   - `app/actions/websocket/channel.ts:141` — the same local clear for a channel another device read.
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §10; no
// upstream source copied.
//
// Why a separate type rather than two closures inside `MattermostApp`:
//
// The card's third acceptance criterion is that three derived values move **together** — the row's
// emphasis, the group's roll-up and `SessionStore`'s badge. In the app those live in two different
// objects, and a wiring that is only spelled inline in `bindShellStores` cannot be tested. This is the
// one function both the app and the unit suite call, so "the same answer clears all three" is a
// property of production code rather than of a test's private imitation.

import Foundation

/// Apply one pane's landed view to the sidebar and the badge (card t_e9550303).
@MainActor
enum ChannelReadApplication {

    /// The synchronous half — run in the same tick the server's answer arrives.
    ///
    /// * the channel's own row loses its mentions, its unread count and "keep as unread" (which
    ///   re-derives `showsUnreadEmphasis`, its badge and every group's `unreadChannels`);
    /// * `SessionStore` loses this channel's mention share, so the app-icon badge's dominant number
    ///   drops now rather than at the next poll.
    ///
    /// `isUnread` is deliberately **not** guessed at here: whether the account still has an unread
    /// message anywhere is a cross-channel, cross-team fact that one row cannot answer.
    /// `applyCounters` settles it with the server's own numbers.
    ///
    /// - Returns what the sidebar cleared, or `nil` when that sidebar has no loaded row for the
    ///   channel (a read in a team the list has not loaded — the counter read is then the only fact we
    ///   can add).
    @discardableResult
    static func apply(channelID: String,
                      response: MMChannelViewResponse,
                      sidebar: ChannelListViewModel?,
                      sessionStore: SessionStore?,
                      serverID: UUID) -> ChannelReadOutcome? {
        let outcome = sidebar?.applyRead(channelID: channelID, cursors: response.lastViewedAtTimes)
        if let outcome, let sessionStore {
            sessionStore.noteChannelRead(serverID: serverID, clearedMentions: outcome.clearedMentions)
        }
        return outcome
    }

    /// The authoritative half: `GET /users/me/teams/unread`, the request the mention poller makes.
    ///
    /// `SessionStore.serverBadgeInput` is still the one place those numbers become a badge, so the
    /// foreground read path and the background poller cannot disagree. `nil`/empty means the read
    /// failed: keep the numbers we have (never clear a badge on a failed request).
    static func applyCounters(_ counters: [MMTeamUnread]?,
                              sessionStore: SessionStore?,
                              serverID: UUID) {
        guard let counters, !counters.isEmpty, let sessionStore else { return }
        sessionStore.applyServerCounters(serverID: serverID,
                                         mentionCounts: counters.map(\.mentionCount),
                                         messageCounts: counters.map(\.msgCount))
    }
}
