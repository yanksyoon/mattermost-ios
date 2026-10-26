// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/client/rest/reactions.ts (`addReaction` → `POST /reactions`, `removeReaction` →
//        `DELETE /users/{user_id}/posts/{post_id}/reactions/{emoji_name}`),
//        app/actions/remote/reactions.ts (the canonical-alias write rule).
// Licence: Apache-2.0 — endpoints reimplemented against https://api.mattermost.com with attribution
// per docs/THIRD_PARTY_NOTICES.md §14; no upstream source copied.
//
// Measured on the pinned 9.11.19 server (`scripts/t37_reaction_probe.py`, which is the evidence):
//  * `POST /posts/{post_id}/reactions` — the path T37's card wording suggests — is a **404**
//    `api.context.404.app_error`. The create is `POST /reactions` with the post id in the body.
//  * a duplicate add answers 200 and updates the *existing* row (`create_at` unchanged), so a replayed
//    add cannot produce two rows;
//  * removing a reaction that is not there is also 200, so a replayed remove is harmless;
//  * an unknown shortcode is `404 app.emoji.get_by_name.no_result` — the client must not offer one.
//
// The delete path carries the emoji name in a path segment. Both the raw `+1` and the encoded `%2B1`
// were measured to answer 200, and `MMBaseURL.apiV4` builds the path through `URLComponents`, which
// leaves `+` alone (it is path-legal) — so the name is passed through unmodified rather than
// pre-encoded, which would be encoded a second time.

import Foundation

extension APIClient {

    /// `POST /reactions` — create one reaction for `userID` on `postID`.
    ///
    /// The server's answer is the stored row (`user_id`, `post_id`, `emoji_name`, `create_at`), which
    /// is what the optimistic apply is reconciled against.
    func addReaction(postID: String, emojiName: String, userID: String) async throws -> MMReaction {
        struct ReactionBody: Encodable {
            var userID: String
            var postID: String
            var emojiName: String
            enum CodingKeys: String, CodingKey {
                case userID = "user_id"
                case postID = "post_id"
                case emojiName = "emoji_name"
            }
        }
        return try await post(MMReaction.self,
                              path: "/reactions",
                              body: ReactionBody(userID: userID, postID: postID, emojiName: emojiName))
    }

    /// `DELETE /users/{user_id}/posts/{post_id}/reactions/{emoji_name}`.
    ///
    /// Idempotent on the server (a missing reaction is still 200), which is what lets the toggle
    /// machine retry a remove after a lost answer without asking the reader anything.
    func removeReaction(postID: String, emojiName: String, userID: String) async throws {
        try await delete(path: "/users/\(userID)/posts/\(postID)/reactions/\(emojiName)")
    }

    /// `GET /posts/{post_id}/reactions` — every reaction on one post.
    ///
    /// Not used by the pane (a channel page already carries `metadata.reactions`). It is the
    /// reconciliation escape hatch a single post has after a page merge, and what the live UI test
    /// uses as an *independent* oracle for the count it asserts on screen.
    func reactions(postID: String) async throws -> [MMReaction] {
        try await get([MMReaction].self, path: "/posts/\(postID)/reactions")
    }
}

/// What a reaction write needs from one server.
///
/// Split from the coordinator for the same reason `ChannelServing` is split from `ChannelViewModel`:
/// the toggle rules (optimistic apply, coalescing, rollback, socket reconcile) are the things under
/// test, and they must not need a network to run.
@MainActor
protocol ReactionServing: AnyObject {
    func add(postID: String, emojiName: String, userID: String) async throws -> MMReaction
    func remove(postID: String, emojiName: String, userID: String) async throws
}

/// The production implementation: the session's `APIClient`, resolved **per call** so a service built
/// before the session finished restoring is not a permanently signed-out one.
@MainActor
final class SessionReactionService: ReactionServing {
    private let resolve: () -> APIClient?

    init(resolve: @escaping () -> APIClient?) {
        self.resolve = resolve
    }

    private func client() throws -> APIClient {
        guard let client = resolve() else { throw MMError.notSignedIn }
        return client
    }

    func add(postID: String, emojiName: String, userID: String) async throws -> MMReaction {
        try await client().addReaction(postID: postID, emojiName: emojiName, userID: userID)
    }

    func remove(postID: String, emojiName: String, userID: String) async throws {
        try await client().removeReaction(postID: postID, emojiName: emojiName, userID: userID)
    }
}
