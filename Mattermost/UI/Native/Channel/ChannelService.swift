// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/actions/remote/post.ts (the load order: channel page, then the profiles the rows need,
//        then a per-file download only when a row draws it), app/client/rest/posts.ts,
//        app/client/rest/users.ts, app/client/rest/files.ts.
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §10; no
// upstream source copied. The protocol/implementation split is this repo's own (component-map.md §1),
// matching `ChannelSidebarServing` in T33.

import Foundation

/// What the channel view needs from one server. Split from the view model so the rules that matter
/// (ordering, pagination, socket patch, scroll anchor) are testable against a fake, with the
/// production implementation the only place that knows about `AuthSession`/`APIClient`.
@MainActor
protocol ChannelServing: AnyObject {
    /// The channel itself (header title/type).
    func channel(id: String) async throws -> MMChannel
    /// One page. `before == nil` asks for the newest page.
    ///
    /// The production implementation asks the server for a **thread-collapsed** page
    /// (`collapsedThreads=true`), i.e. top-level posts only — the channel timeline's membership rule
    /// (T34-AV-F1). A service that answers with replies mixed in is still handled: the view model
    /// filters every page through `ChannelViewModel.isTimelineRow`.
    func posts(channelID: String, before: String?, perPage: Int) async throws -> MMPostList
    /// Author profiles for the ids on screen, in one batched request.
    func users(ids: [String]) async throws -> [MMUser]
    /// Bytes for an attachment thumbnail (or the file itself when the server has no thumbnail).
    func fileData(fileID: String, preferThumbnail: Bool) async throws -> Data

    /// My membership row for the channel — `last_viewed_at` places the unread divider. Optional so a
    /// service that has already been handed a read position need not implement it.
    func membership(channelID: String) async throws -> MMChannelMember?

    /// One page of the team's custom emoji (`GET /emoji`), newest-first pages of `perPage`.
    ///
    /// Defaults to an empty page: a service that has not implemented it simply has no custom emoji,
    /// and the renderer keeps the `:name:` shortcode — never a crash and never a fake glyph.
    func customEmoji(page: Int, perPage: Int) async throws -> [MMEmoji]

    /// The image bytes for one custom emoji (`GET /emoji/{id}/image`).
    func emojiImage(emojiID: String) async throws -> Data

    /// `POST /reactions` — add one reaction (S16/T37).
    ///
    /// Defaults to a failure: a service that has not implemented the write path still *draws*
    /// reactions, and a tap on it then reports an error instead of silently doing nothing (the same
    /// degradation rule as `customEmoji`).
    func addReaction(postID: String, emojiName: String, userID: String) async throws -> MMReaction

    /// `DELETE /users/{user_id}/posts/{post_id}/reactions/{emoji_name}`.
    func removeReaction(postID: String, emojiName: String, userID: String) async throws

    /// Page size, injectable so a test can page a fixture without 60 real posts.
    var pageSize: Int { get }
}

extension ChannelServing {
    var pageSize: Int { 60 }
    func membership(channelID: String) async throws -> MMChannelMember? { nil }
    func customEmoji(page: Int, perPage: Int) async throws -> [MMEmoji] { [] }
    func emojiImage(emojiID: String) async throws -> Data { throw MMError.notFound }
    func addReaction(postID: String, emojiName: String, userID: String) async throws -> MMReaction {
        throw MMError.notFound
    }
    func removeReaction(postID: String, emojiName: String, userID: String) async throws {
        throw MMError.notFound
    }
}

/// The production implementation: the server's own `AuthSession.client`, resolved **per call** so a
/// service created before the session finished restoring is not a permanently signed-out one (the
/// same reason `SessionChannelSidebarService` resolves per call).
@MainActor
final class SessionChannelService: ChannelServing {
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

    func channel(id: String) async throws -> MMChannel {
        try await client().channel(id: id)
    }

    func posts(channelID: String, before: String?, perPage: Int) async throws -> MMPostList {
        let page = MMPostPage(cursor: before.map { .before($0) } ?? .page(0), perPage: perPage)
        // `collapsedThreads: true` is explicit, not left to the API default: this is the rule that
        // keeps replies out of the channel timeline (T34-AV-F1, measured in `ChannelAPI`).
        return try await client().channelPosts(channelID: channelID, page: page,
                                               collapsedThreads: true)
    }

    func users(ids: [String]) async throws -> [MMUser] {
        // A profile failure must not fail the page: the rows fall back to the username carried in
        // `props` (system messages) or to "Unknown user", which is honest and still ordered.
        (try? await client().users(ids: ids)) ?? []
    }

    func fileData(fileID: String, preferThumbnail: Bool) async throws -> Data {
        let client = try client()
        if preferThumbnail, let thumbnail = try? await client.fileBytes(fileID: fileID,
                                                                       thumbnail: true) {
            return thumbnail
        }
        return try await client.fileBytes(fileID: fileID, thumbnail: false)
    }

    func membership(channelID: String) async throws -> MMChannelMember? {
        // A missing membership row is not a reason to fail the page: without `last_viewed_at` the
        // list simply draws no unread divider (`nil` = unknown, never "everything is read").
        try? await client().channelMembership(channelID: channelID)
    }

    func customEmoji(page: Int, perPage: Int) async throws -> [MMEmoji] {
        try await client().customEmoji(page: page, perPage: perPage)
    }

    func emojiImage(emojiID: String) async throws -> Data {
        try await client().emojiImage(emojiID: emojiID)
    }

    /// S16/T37: the write half. The alias the caller passes is already canonical (`thumbsup` → `+1`),
    /// so this sends exactly one spelling per pill.
    func addReaction(postID: String, emojiName: String, userID: String) async throws -> MMReaction {
        try await client().addReaction(postID: postID, emojiName: emojiName, userID: userID)
    }

    func removeReaction(postID: String, emojiName: String, userID: String) async throws {
        try await client().removeReaction(postID: postID, emojiName: emojiName, userID: userID)
    }
}
