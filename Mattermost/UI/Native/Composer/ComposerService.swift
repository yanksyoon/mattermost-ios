// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/actions/remote/post.ts (create/patch/delete, and the `pending_post_id` round trip),
//        app/actions/remote/file.ts (the upload queue: one file per request, progress, cancel),
//        app/actions/remote/user.ts + channel.ts (the autocomplete fan-in: users, channels),
//        app/client/rest/files.ts, users.ts, channels.ts.
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §11; no
// upstream source copied. The protocol/implementation split is this repo's own convention
// (`ChannelServing`, `ChannelSidebarServing`): the rules live in the view model against a fake, and
// the production implementation is the only thing that knows about `AuthSession`/`APIClient`.
//
// Why a protocol rather than calling `APIClient` from the view model: the composer's rules —
// optimistic send, retry, draft persistence, the autocomplete race — are exactly the parts that must
// be testable without a server. A fake service can make the create take two seconds, fail once, or
// answer a stale autocomplete term; the network cannot.

import Foundation

/// What one composer needs from a server.
@MainActor
protocol ComposerServing: AnyObject {
    func createPost(_ body: ComposerPostBody) async throws -> MMPost
    func patchPost(id: String, message: String, fileIDs: [String]) async throws -> MMPost
    func deletePost(id: String) async throws

    /// One file. `onProgress` receives `(bytesSent, bytesExpected)` from the transport.
    func upload(_ upload: ComposerUpload,
                channelID: String,
                onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> MMFileInfo

    /// `@` candidates for `term`, restricted to the channel's members by the server.
    func users(term: String, channelID: String, teamID: String?, limit: Int) async throws -> [MMUser]
    /// `#` candidates for `term`.
    func channels(term: String, teamID: String, limit: Int) async throws -> [MMChannel]
    /// The channel's member ids, and whether the whole list was read.
    func channelMembers(channelID: String) async throws -> ComposerMembership.MemberList
    /// The signed-in user, so an optimistic row has a real author.
    func me() async throws -> MMUser
}

extension ComposerServing {
    func users(term: String, channelID: String, teamID: String?,
               limit: Int = 20) async throws -> [MMUser] { [] }
    func channels(term: String, teamID: String, limit: Int = 20) async throws -> [MMChannel] { [] }
    func channelMembers(channelID: String) async throws -> ComposerMembership.MemberList {
        .unknown
    }
}

/// The production implementation: the session's own `APIClient`, resolved **per call** so a composer
/// created before the session finished restoring is not permanently signed out (the same reason
/// `SessionChannelService` resolves per call).
@MainActor
final class SessionComposerService: ComposerServing {
    private let resolve: () -> APIClient?
    /// How far the membership check pages before it stands down. 5 × 200 = 1,000 members: past that
    /// the list is treated as unknowable rather than half-read (see `ComposerMembership`).
    static let membershipPages = 5
    static let membershipPageSize = 200

    init(resolve: @escaping () -> APIClient?) {
        self.resolve = resolve
    }

    private func client() throws -> APIClient {
        guard let client = resolve() else { throw MMError.notSignedIn }
        return client
    }

    func createPost(_ body: ComposerPostBody) async throws -> MMPost {
        try await client().createPost(body)
    }

    func patchPost(id: String, message: String, fileIDs: [String]) async throws -> MMPost {
        try await client().patchPost(ComposerPostPatch(id: id, message: message, fileIds: fileIDs))
    }

    func deletePost(id: String) async throws {
        try await client().deletePost(id: id)
    }

    func upload(_ upload: ComposerUpload,
                channelID: String,
                onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> MMFileInfo {
        try await client().uploadFile(upload, channelID: channelID, onProgress: onProgress)
    }

    func users(term: String, channelID: String, teamID: String?, limit: Int) async throws -> [MMUser] {
        try await client().autocompleteUsers(term: term, inChannel: channelID,
                                             inTeam: teamID, limit: limit)
    }

    func channels(term: String, teamID: String, limit: Int) async throws -> [MMChannel] {
        guard !teamID.isEmpty else { return [] }
        return try await client().searchChannels(teamID: teamID, term: term, limit: limit)
    }

    func channelMembers(channelID: String) async throws -> ComposerMembership.MemberList {
        let client = try self.client()
        var ids: Set<String> = []
        for page in 0..<Self.membershipPages {
            let batch = try await client.channelMembers(channelID: channelID,
                                                        page: page,
                                                        perPage: Self.membershipPageSize)
            for member in batch where !member.userId.isEmpty {
                ids.insert(member.userId.lowercased())
            }
            if batch.count < Self.membershipPageSize {
                return ComposerMembership.MemberList(ids: ids, isComplete: true)
            }
        }
        // Truncated: the caller must not use this to hide candidates.
        return ComposerMembership.MemberList(ids: ids, isComplete: false)
    }

    func me() async throws -> MMUser {
        try await client().currentUser()
    }
}
