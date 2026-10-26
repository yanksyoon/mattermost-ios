// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: `app/actions/remote/search.ts` (the search action: query, then the row context a result list
//        needs — author profiles and the channels the posts live in), `app/actions/remote/post.ts`
//        (saved/pinned reads), `app/actions/remote/preference.ts` (save/unsave), `app/client/rest/`.
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §16; no
// upstream source copied. The protocol/implementation split is this repo's own (component-map.md §1),
// matching `ChannelServing` (T34) and `ThreadServing` (T36).
//
// Why a protocol: the rules this card is judged on (which terms are highlighted, when a page is
// exhausted, what an invalid query says, whether an unpin removes the row in place) are all pure or
// model-level. `SearchServing` is the seam that lets the unit suite drive them with a fake, while the
// shipping implementation is the only place that knows about `AuthSession`/`APIClient`.

import Foundation

/// What the search, saved and pinned screens need from one server.
@MainActor
protocol SearchServing: AnyObject {
    /// `POST /teams/{team_id}/posts/search`.
    func search(teamID: String, body: SearchQuery.Body) async throws -> MMSearchResults
    /// `GET /users/me/posts/flagged` (with the team-scoped `posts/saved` fallback).
    func savedPosts(teamID: String?, page: Int, perPage: Int) async throws -> MMPostList
    /// `GET /channels/{channel_id}/pinned`.
    func pinnedPosts(channelID: String, page: Int, perPage: Int) async throws -> MMPostList
    /// `GET /posts/{id}` — the jump path needs a post that the loaded window may not hold.
    func post(id: String) async throws -> MMPost
    /// `POST /users/ids` — author profiles for the rows on screen.
    func users(ids: [String]) async throws -> [MMUser]
    /// `POST /teams/{team_id}/channels/ids` — the channels the result rows name.
    func channels(ids: [String], teamID: String) async throws -> [MMChannel]
    /// Save/unsave a post (the `flagged_post` preference on the server that has no flag route).
    func setSaved(postID: String, saved: Bool, userID: String) async throws
    /// `POST /posts/{id}/pin` / `/unpin`.
    func setPinned(postID: String, pinned: Bool) async throws
    /// Page size, injectable so a test can page a fixture with three posts.
    var pageSize: Int { get }
}

extension SearchServing {
    var pageSize: Int { 60 }
    /// A service that has not implemented a batched lookup simply has no names to add: the rows fall
    /// back to whatever the post carries rather than failing the search.
    func users(ids: [String]) async throws -> [MMUser] { [] }
    func channels(ids: [String], teamID: String) async throws -> [MMChannel] { [] }
    /// Writes degrade to a readable error rather than a silent no-op (the rule `ChannelServing`'s
    /// `addReaction` states): a tap that cannot be honoured must say so.
    func setSaved(postID: String, saved: Bool, userID: String) async throws { throw MMError.notSignedIn }
    func setPinned(postID: String, pinned: Bool) async throws { throw MMError.notSignedIn }
}

/// The production implementation: the session's own client, resolved **per call** so a service built
/// before the session restored is not permanently signed out (the same note as `SessionChannelService`).
@MainActor
final class SessionSearchService: SearchServing {
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

    func search(teamID: String, body: SearchQuery.Body) async throws -> MMSearchResults {
        try await client().searchPosts(teamID: teamID, body: body)
    }

    func savedPosts(teamID: String?, page: Int, perPage: Int) async throws -> MMPostList {
        try await client().savedPosts(teamID: teamID, page: page, perPage: perPage)
    }

    func pinnedPosts(channelID: String, page: Int, perPage: Int) async throws -> MMPostList {
        try await client().pinnedPosts(channelID: channelID, page: page, perPage: perPage)
    }

    func post(id: String) async throws -> MMPost {
        try await client().post(id: id)
    }

    func users(ids: [String]) async throws -> [MMUser] {
        guard !ids.isEmpty else { return [] }
        return try await client().users(ids: ids)
    }

    func channels(ids: [String], teamID: String) async throws -> [MMChannel] {
        try await client().channels(ids: ids, teamID: teamID)
    }

    func setSaved(postID: String, saved: Bool, userID: String) async throws {
        let client = try client()
        if saved {
            try await client.savePost(postID: postID, userID: userID)
        } else {
            try await client.unsavePost(postID: postID, userID: userID)
        }
    }

    func setPinned(postID: String, pinned: Bool) async throws {
        let client = try client()
        if pinned {
            try await client.pinPost(id: postID)
        } else {
            try await client.unpinPost(id: postID)
        }
    }
}
