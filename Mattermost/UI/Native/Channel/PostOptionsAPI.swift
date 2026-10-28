// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/client/rest/posts.ts (`markPostAsUnread`), app/client/rest/preferences.ts
//        (`savePreferences` / `deletePreferences`), app/client/rest/posts.ts (`pinPost`,
//        `unpinPost`), app/client/rest/threads.ts (`updateThreadFollowing`), app/queries/servers/
//        role.ts + app/actions/remote/post.ts (`markPostAsUnread`'s `getCurrentUserId` /
//        `getChannelMember` reads).
// Licence: Apache-2.0 — endpoints reimplemented against https://api.mattermost.com with attribution
// per docs/THIRD_PARTY_NOTICES.md §18; no upstream source copied.
//
// Only the one endpoint this card adds; the rest of the writes already exist and are **reused**, not
// redeclared: `SearchAPI.savePost/unsavePost/pinPost/unpinPost` (T39, measured), `ThreadAPI.followThread`
// (T36), `MMEndpoints.preferences`, `ChannelInfoAPI.roles/currentPrincipal/teamMembership`,
// `ChannelAPI.channelMembership`, `MMEndpoints.myTeams`.
//
// Measured on the pinned 9.11.19 server (`scripts/t48_post_options_probe.py`):
//
//   POST /users/{uid}/posts/{pid}/set_unread   body {"collapsed_threads_supported": true}
//     → 200 with the **channel membership row** (`msg_count` already decremented, `last_viewed_at`
//       moved). The counters are the server's own arithmetic, so the client applies them instead of
//       subtracting one. The same write publishes `post_unread` to my socket, which is what moves the
//       sidebar's badge.
//
// The route is the *user* route the card names, not a team-scoped one: the team is not part of the
// address and 9.11.19 resolves it from the post itself.

import Foundation

extension APIClient {

    /// `POST /users/{user_id}/posts/{post_id}/set_unread` — mark one post unread for me.
    ///
    /// Answers the membership row with the counters the server computed. `collapsed_threads_supported`
    /// is the body upstream sends (`app/client/rest/posts.ts`); it tells the server to apply CRT
    /// arithmetic to the root counters, and omitting it is not a documented equivalent.
    func markPostUnread(userID: String, postID: String) async throws -> MMChannelMember {
        try await post(MMChannelMember.self,
                       path: "/users/\(userID)/posts/\(postID)/set_unread",
                       body: SetPostUnreadBody())
    }

    /// The body of the mark-unread write, named once so a future field cannot be silently dropped.
    private struct SetPostUnreadBody: Encodable {
        let collapsedThreadsSupported: Bool

        enum CodingKeys: String, CodingKey {
            case collapsedThreadsSupported = "collapsed_threads_supported"
        }

        init() { collapsedThreadsSupported = true }
    }
}
