// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: `app/actions/remote/search.ts` (`fetchRecentMentions` and the row context it loads afterwards —
//        authors and the channels the posts live in), `app/actions/local/thread.ts`
//        (`markThreadAsRead`), `app/actions/remote/channel.ts` (`markChannelAsRead`). Licence:
//        Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §19; no upstream
//        source copied.
//
// The protocol/implementation split is this repo's convention (`ChannelServing` T34, `ThreadServing`
// T36, `SearchServing` T39): the rules this card is judged on — which rows are unread, which rows a live
// socket event inserts, what a mark-read does to the counters — are pure or model-level, so the unit
// suite drives them with a fake, and the shipping implementation is the only place that knows about
// `AuthSession`/`APIClient`.

import Foundation

/// What the activity feed needs from one server.
@MainActor
protocol ActivityServing: AnyObject {
    /// `GET /users/me` — the reader's own mention keys.
    func profile() async throws -> ActivityProfile
    /// `POST /posts/search` — the cross-team mentions window.
    func mentions(terms: String, page: Int, perPage: Int) async throws -> MMSearchResults
    /// `GET /channels/{id}` — a row's channel (name **and** team, which is what the jump needs).
    func channel(id: String) async throws -> MMChannel
    /// `POST /users/ids` — the rows' authors.
    func users(ids: [String]) async throws -> [MMUser]
    /// `GET /users/{user}/teams/{team}/channels/members` — read cursors for one team.
    func channelReads(teamID: String, userID: String) async throws -> [MMChannelMember]
    /// `GET /channels/{channel}/members/{user}` — the read cursor for a channel outside any team list.
    func channelRead(channelID: String, userID: String) async throws -> MMChannelMember
    /// `POST /channels/members/{user}/mark_read` — mark channels read; the answer carries the new cursors.
    func markChannelsRead(channelIDs: [String], userID: String) async throws -> MMChannelViewResponse
    /// `GET /users/me/teams/{team}/threads?unread=true` — thread read state under collapsed threads.
    func unreadThreads(teamID: String) async throws -> [ActivityThreadUnread]
    /// `PUT /users/me/teams/{team}/threads/{root}/read/{ts}` — mark one thread read.
    func markThreadRead(teamID: String, rootID: String, at timestamp: Int64) async throws -> ActivityThreadUnread
    /// `GET /users/me/teams/unread` — the badge's input, the same request `MentionPoller` polls.
    func badgeCounters() async throws -> [MMTeamUnread]
    /// The window size the feed asks for; injectable so a test can page a three-post fixture.
    var pageSize: Int { get }
}

extension ActivityServing {
    var pageSize: Int { 60 }

    /// A service that cannot answer a row-context question simply has no name to add: the row falls back
    /// to the post's own author id / channel id rather than failing the whole feed. (Same rule
    /// `SearchServing` states for its batched lookups.)
    func users(ids: [String]) async throws -> [MMUser] { [] }
    func channelReads(teamID: String, userID: String) async throws -> [MMChannelMember] { [] }
    func unreadThreads(teamID: String) async throws -> [ActivityThreadUnread] { [] }
    func badgeCounters() async throws -> [MMTeamUnread] { [] }

    /// Writes must not silently do nothing: a tap that cannot be honoured has to be able to say so
    /// (the rule `ChannelServing.addReaction` states).
    func markChannelsRead(channelIDs: [String], userID: String) async throws -> MMChannelViewResponse {
        throw MMError.notSignedIn
    }

    func markThreadRead(teamID: String, rootID: String,
                        at timestamp: Int64) async throws -> ActivityThreadUnread {
        throw MMError.notSignedIn
    }
}

/// The production implementation: the session's own client, resolved **per call** so a service built
/// before the session restored is not permanently signed out (the note every other `Session…Service`
/// carries).
@MainActor
final class SessionActivityService: ActivityServing {
    private let resolve: () -> APIClient?
    let pageSize: Int

    init(pageSize: Int = 60, resolve: @escaping () -> APIClient?) {
        self.pageSize = pageSize
        self.resolve = resolve
    }

    private func client() throws -> APIClient {
        guard let client = resolve() else { throw MMError.notSignedIn }
        return client
    }

    func profile() async throws -> ActivityProfile {
        try await client().activityProfile()
    }

    func mentions(terms: String, page: Int, perPage: Int) async throws -> MMSearchResults {
        try await client().mentionSearch(terms: terms, page: page, perPage: perPage)
    }

    func channel(id: String) async throws -> MMChannel {
        // T28's `GET /channels/{id}` — the same read the channel pane uses, so a mention row and the
        // channel it opens cannot disagree about a channel's name or team.
        try await client().channel(id: id)
    }

    func users(ids: [String]) async throws -> [MMUser] {
        // A profile failure must not fail the list (the rule every other list follows): rows fall back
        // to the user id, which is honest and still ordered.
        (try? await client().users(ids: ids)) ?? []
    }

    func channelReads(teamID: String, userID: String) async throws -> [MMChannelMember] {
        try await client().channelMembersForTeam(teamID: teamID, userID: userID)
    }

    func channelRead(channelID: String, userID: String) async throws -> MMChannelMember {
        // T40's `GET /channels/{id}/members/{me}` — the row for a channel no team list covers (a DM/GM).
        try await client().channelMember(channelID: channelID, userID: userID)
    }

    func markChannelsRead(channelIDs: [String], userID: String) async throws -> MMChannelViewResponse {
        try await client().markChannelsRead(channelIDs: channelIDs, userID: userID)
    }

    func unreadThreads(teamID: String) async throws -> [ActivityThreadUnread] {
        // T36's thread read with `unread=true` — the only source of a reply's read state under collapsed
        // threads (a channel's `last_viewed_at` does not move when a thread is read).
        let list = try await client().userThreads(teamID: teamID, perPage: 200, unreadOnly: true)
        return list.threads.compactMap { thread in
            guard !thread.id.isEmpty else { return nil }
            return ActivityThreadUnread(rootID: thread.id,
                                        unreadReplies: thread.unreadReplies,
                                        unreadMentions: thread.unreadMentions,
                                        lastViewedAt: thread.lastViewedAt)
        }
    }

    func markThreadRead(teamID: String, rootID: String,
                        at timestamp: Int64) async throws -> ActivityThreadUnread {
        let thread = try await client().markThreadRead(teamID: teamID, threadID: rootID,
                                                       timestamp: timestamp)
        return ActivityThreadUnread(rootID: thread.id.isEmpty ? rootID : thread.id,
                                    unreadReplies: thread.unreadReplies,
                                    unreadMentions: thread.unreadMentions,
                                    lastViewedAt: thread.lastViewedAt)
    }

    func badgeCounters() async throws -> [MMTeamUnread] {
        // The **same** request `MentionPoller` polls in the background: `SessionStore.serverBadgeInput`
        // is the one place these numbers become a badge, so the foreground feed and the background poller
        // can never disagree about what the badge means.
        try await client().teamUnreads()
    }
}
