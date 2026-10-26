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
        case .multipleChannelsViewed(let viewed):
            // The view call's event: no channel and no team in the envelope, but the map names every
            // channel whose read cursor moved. It may be delivered when *any* of them is in the team
            // on screen; the model applies it per row and skips the rest.
            return viewed.channelTimes.keys.contains(where: isInActiveTeam)
        case .postUnread(let unread):
            // `post_unread` is the server's unread arithmetic for *my* membership of one channel;
            // it belongs to the team that channel is on.
            return isInActiveTeam(channelID: unread.channelID)
        case .channelMemberUpdated(let update):
            // My mute/notify row for a channel: the row names a channel, not a team.
            return isInActiveTeam(channelID: update.channelID)
        case .channelCreated(let created):
            return created.teamID.isEmpty
                ? isInActiveTeam(channelID: created.channelID)
                : created.teamID == teamID
        case .channelDeleted(let deleted):
            return isInActiveTeam(channelID: deleted.channelID)
                || (!deleted.teamID.isEmpty && deleted.teamID == teamID)
        case .channelUpdated(let channel):
            // A rename/purpose/header edit names its channel (and its team, in the payload as well as
            // the envelope). T40's info screen is the consumer.
            return isInActiveTeam(channelID: channel.id)
                || (!channel.teamId.isEmpty && channel.teamId == teamID)
        case .channelRestored(let restored):
            return isInActiveTeam(channelID: restored.channelID)
                || (!restored.teamID.isEmpty && restored.teamID == teamID)
        case .userAdded(let change), .userRemoved(let change):
            // A membership change names its channel in the envelope; the team is in the payload on an
            // add and absent on many removals, so the channel→team map is what usually attributes it.
            return isInActiveTeam(channelID: change.channelID)
                || (!change.teamID.isEmpty && change.teamID == teamID)
        case .threadUpdated(let update):
            // A thread update names its root post, which names its channel — the same attribution a
            // `posted` gets (T36).
            return isInActiveTeam(channelID: update.thread.post.channelId)
        case .threadFollowChanged, .threadReadChanged:
            // These carry a thread id and no channel (measured), so this scope cannot attribute them
            // to a team. They are still accepted: a thread id is globally unique and every consumer
            // matches it exactly (`change.threadID == rootID` / a row's own id), so a delivery into
            // the wrong team's surface reaches no model at all — refusing it would only make an open
            // thread miss its own follow/read change. Same reasoning as `preferencesChanged`, but for
            // identity rather than scope.
            return true
        case .sidebarCategoryUpdated(let update):
            // A layout write is team-scoped: it can only change the list of the team it names.
            // An envelope without a team (a stripped proxy frame) is accepted rather than dropped —
            // the payload itself carries `team_id`, and drawing the same layout twice is harmless.
            return update.teamID.isEmpty || update.teamID == teamID
        case .reactionAdded(let reaction), .reactionRemoved(let reaction):
            // A reaction names a post **and** a channel: 9.11.19 puts `channel_id` inside the event's
            // reaction payload (measured — `av-ws-watch.log` carried it twice for one add), so the same
            // attribution every other channel-scoped event gets applies here.
            //
            // T37 shipped this as `return false`, on the stated grounds that a reaction "names a post,
            // not a channel" and so could not be attributed to a team. It can be — and refusing it was
            // the whole of T37-AV F1: this scope is the only route from the server's one socket into
            // the panes, so `.reactionAdded`/`.reactionRemoved` handling in `ChannelViewModel` and
            // `ThreadViewModel` was unreachable in the running app and a reaction another client wrote
            // never drew a pill.
            //
            // A payload that names no channel is **accepted** rather than dropped, and each pane keeps
            // only its own posts (`postsByID[reaction.postId] != nil`), so a delivery into the wrong
            // team's surface reaches no model at all. Same reasoning as `threadFollowChanged` below:
            // refusing an unattributable event only makes an open pane miss its own.
            return reaction.channelId.isEmpty || isInActiveTeam(channelID: reaction.channelId)
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
