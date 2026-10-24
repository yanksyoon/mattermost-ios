// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/client/websocket/index.ts (one socket per *server*; every team's events arrive on it),
//        app/actions/websocket/*.ts (handlers that drop events whose `channel_id` is not in the
//        currently selected team's channel set), app/constants/websocket.ts (event names).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §3; no
// upstream source copied. The type decomposition is this repo's own (docs/component-map.md §1).

import Foundation

/// What the **active team** is allowed to see from the server's one WebSocket.
///
/// ## Why a scope, and not "reconnect on switch"
///
/// Mattermost's WebSocket v4 is **server-scoped**: one connection carries every team's events for
/// that user (`app/client/websocket/index.ts`), and upstream switches teams by changing which team's
/// channels the handlers accept — it does not tear the socket down and open another. Reconnecting on
/// every tap would be strictly worse: a reconnect costs a handshake, an `authentication_challenge`
/// and a resync, and ten rapid taps would leave ten sockets racing to deliver.
///
/// So the honest statement of "the socket subscription follows the switch" in this client is:
/// **one connection per server, one scope per connection, the scope is replaced atomically when the
/// team changes.** The pump is never duplicated (`TeamSidebarCoordinator.subscriptionCount` is 1),
/// and an event that belongs to the team the user just left is not delivered to the active surface.
///
/// ## The rule
///
/// - No team selected → accept everything. Nothing is on screen to leak into, and dropping events
///   before the first team is resolved would lose the very events that update the badges.
/// - A channel is in the active team when it **is** the open channel, or when the channel directory
///   (`channelTeams`, filled by the channel list, S08/T33) says it belongs to that team.
/// - An event whose channel is unknown is **refused** while a team is selected. That is the
///   conservative direction: an un-attributable post could belong to any team, and the cost of
///   refusing it is a refresh (the reachability path — `TeamSidebarCoordinator` refetches counters on
///   post activity), whereas the cost of accepting it is another team's message appearing in the
///   conversation the user is reading.
struct TeamSocketScope: Equatable, Sendable {
    /// The team whose surface is on screen.
    var teamID: String? = nil
    /// The channel that surface is showing (nil on a team root / the channel list).
    var activeChannelID: String? = nil
    /// channel id → team id. Empty until the channel list lands (S08/T33); the open channel is
    /// therefore matched through `activeChannelID`, which is always known.
    var channelTeams: [String: String] = [:]

    /// Whether `event` may be delivered to the active team's surface.
    func accepts(_ event: SocketEvent) -> Bool {
        guard let teamID, !teamID.isEmpty else { return true }
        switch event {
        case .posted(let post), .postEdited(let post), .postDeleted(let post):
            return isInActiveTeam(channelID: post.channelId)
        case .typing(let typing):
            return isInActiveTeam(channelID: typing.channelID)
        case .channelViewed(let viewed):
            return isInActiveTeam(channelID: viewed.channelID)
        case .reactionAdded, .reactionRemoved:
            // A reaction names a post, not a channel: without a post → channel map this scope cannot
            // attribute it to a team, so it is refused rather than delivered into whichever team's
            // conversation happens to be open. Reactions are the channel view's (T34) to resolve.
            return false
        case .hello, .statusChange, .preferencesChanged, .userUpdated, .unhandled:
            // Server-wide facts: presence, preferences, profile updates and protocol events belong
            // to no team (and to every team).
            return true
        }
    }

    private func isInActiveTeam(channelID: String) -> Bool {
        if let activeChannelID, channelID == activeChannelID { return true }
        return channelTeams[channelID] == teamID
    }
}
