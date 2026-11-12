// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/actions/remote/post.ts (create/patch/delete, and the `pending_post_id` round trip),
//        app/actions/remote/file.ts (the upload queue: one file per request, progress, cancel),
//        app/actions/remote/user.ts + channel.ts (the autocomplete fan-in: users, channels),
//        app/client/rest/files.ts, users.ts, channels.ts.
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §12; no
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

    /// `@` candidates for `term`, in the three bands the server knows (in channel, not in channel,
    /// agents). No longer a flat `[MMUser]`: the split is the answer, and flattening it in the
    /// service is what made a bot invisible (kanban t_03f2dbfd).
    func users(term: String, channelID: String, teamID: String?, limit: Int) async throws -> ComposerUserCandidates
    /// The channel's members, as profiles — the local half of the `@` list.
    ///
    /// Read when the composer appears, not when `@` is typed: it is what lets a bare `@` draw real
    /// names in the first frame instead of waiting on a request.
    func channelPeople(channelID: String) async throws -> [MMUser]
    /// The server's bot accounts, by user id. Used only to label a row "Bot".
    func botUserIDs() async throws -> Set<String>
    /// `#` candidates for `term`.
    func channels(term: String, teamID: String, limit: Int) async throws -> [MMChannel]
    /// The channel's member ids, and whether the whole list was read.
    func channelMembers(channelID: String) async throws -> ComposerMembership.MemberList
    /// The signed-in user, so an optimistic row has a real author.
    func me() async throws -> MMUser

    /// `GET /commands?team_id=` — the team's slash commands, unfiltered (the caller's
    /// `ComposerCommandList.offered(_:)` decides which rows may be drawn).
    func commands(teamID: String) async throws -> [MMCommand]
    /// `POST /commands/execute` — run `command` (`/help`, `/invite @kim`) in the composer's channel.
    func executeCommand(_ command: String,
                        channelID: String,
                        teamID: String?,
                        rootID: String?) async throws -> ComposerCommandResponse

    /// Whether this line has to bypass `/commands/execute` for the Apps framework.
    ///
    /// Upstream asks two questions before it executes anything (`app/actions/remote/command.ts:
    /// 48-54`): is the framework switched on, and is this line one of an app's bindings. The answer
    /// decides the endpoint, so it belongs on the service — but it is allowed to fail *quietly*:
    /// every failure means "no app commands", which sends the line down the ordinary path (the way
    /// upstream behaves on a server with no apps bindings). A command must never be refused because
    /// the apps question could not be answered.
    func appsPosture(channelID: String, teamID: String?, userID: String) async -> ComposerAppsPosture
}

extension ComposerServing {
    func users(term: String, channelID: String, teamID: String?,
               limit: Int = 20) async throws -> ComposerUserCandidates { ComposerUserCandidates() }
    /// A service that cannot name the channel's members still offers the server's answer; a bare
    /// `@` then simply has no local rows.
    func channelPeople(channelID: String) async throws -> [MMUser] { [] }
    /// A service that cannot read the bot list labels nothing — every row still appears.
    func botUserIDs() async throws -> Set<String> { [] }
    func channels(term: String, teamID: String, limit: Int = 20) async throws -> [MMChannel] { [] }
    func channelMembers(channelID: String) async throws -> ComposerMembership.MemberList {
        .unknown
    }
    /// A service that predates commands (a test double for the draft rules) offers none. The
    /// *execute* call has no default: a composer that believes it ran a command it never sent is
    /// worse than one that does not compile.
    func commands(teamID: String) async throws -> [MMCommand] { [] }
    /// A service that cannot answer the apps question sends every command down the ordinary path —
    /// which is what upstream does on a server with no apps bindings, so this default is the honest
    /// one and not a stub.
    func appsPosture(channelID: String, teamID: String?, userID: String) async -> ComposerAppsPosture {
        .unavailable
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
    /// How far the local `@` preview pages the member list: one screenful is the point, and a
    /// 1,000-member channel must not turn "type `@`" into a directory download.
    static let peoplePages = 2

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

    func users(term: String, channelID: String, teamID: String?, limit: Int) async throws -> ComposerUserCandidates {
        try await client().autocompleteUsers(term: term, inChannel: channelID,
                                             inTeam: teamID, limit: limit)
    }

    /// The channel's members as profiles: `GET /channels/{id}/members` for the ids, then the
    /// batched `POST /users/ids` for the names (there is no member-profiles endpoint on 9.11.19 —
    /// `GET /channels/{id}/users` is a 404 `api.context.404.app_error`, measured).
    ///
    /// Bounded on purpose: the preview list wants a screenful, not a directory. Two pages of 200
    /// is the ceiling; past it the answer is still a useful local list rather than a slow one.
    func channelPeople(channelID: String) async throws -> [MMUser] {
        let client = try self.client()
        var ids: [String] = []
        var seen: Set<String> = []
        for page in 0..<Self.peoplePages {
            let batch = try await client.channelMembers(channelID: channelID,
                                                        page: page,
                                                        perPage: Self.membershipPageSize)
            for member in batch where !member.userId.isEmpty && seen.insert(member.userId).inserted {
                ids.append(member.userId)
            }
            if batch.count < Self.membershipPageSize { break }
        }
        guard !ids.isEmpty else { return [] }
        let users = try await client.users(ids: ids)
        return users
            .filter { $0.deleteAt == 0 && !$0.username.isEmpty }
            .sorted { $0.username.lowercased() < $1.username.lowercased() }
    }

    /// `GET /bots` — the ids only. Any failure (a `403` for a non-admin caller, a timeout) is not an
    /// error worth surfacing: it costs the rows their "Bot" label, nothing else. The rows still
    /// appear, and the mention still works.
    func botUserIDs() async throws -> Set<String> {
        do {
            return Set(try await client().bots().filter(\.isLive).map(\.userId))
        } catch {
            MMLog.debug("MMComposer", "bot list unavailable, rows are unlabelled: \(error)")
            return []
        }
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

    func commands(teamID: String) async throws -> [MMCommand] {
        guard !teamID.isEmpty else { return [] }
        return try await client().commands(teamID: teamID)
    }

    func executeCommand(_ command: String,
                        channelID: String,
                        teamID: String?,
                        rootID: String?) async throws -> ComposerCommandResponse {
        let body = ComposerCommandBody(command: command,
                                       channelId: channelID,
                                       teamId: teamID.flatMap { $0.isEmpty ? nil : $0 },
                                       rootId: rootID.flatMap { $0.isEmpty ? nil : $0 })
        return try await client().executeCommand(body)
    }

    /// The apps question, asked exactly the way upstream asks it — and swallowed exactly the way
    /// upstream swallows it.
    ///
    /// 1. `FeatureFlagAppsEnabled` from `/config/client`. `false` (or unreadable) ends it: this
    ///    server cannot have app commands, and the line goes to `/commands/execute`.
    /// 2. The `command` bindings from the apps runtime. This is the step that 404s on a server
    ///    without the apps plugin (measured), and a 404 there is not a failure — it is "no app
    ///    commands". Upstream's `AppsManager.handleError` does the same thing for the same reason:
    ///    it turns `enabled` off and lets commands run the ordinary way.
    ///
    /// One read per command-send, cached for the life of this service object: bindings are a
    /// per-channel document a plugin reload changes, and the cache dies with the composer that owns
    /// it (a channel switch rebuilds the composer), so a stale answer cannot outlive the screen.
    func appsPosture(channelID: String, teamID: String?, userID: String) async -> ComposerAppsPosture {
        if let cached = cachedAppsPosture { return cached }
        guard let client = resolve() else { return .unavailable }
        guard let enabled = try? await client.clientConfigFlag("FeatureFlagAppsEnabled"),
              enabled else {
            cachedAppsPosture = .unavailable
            return .unavailable
        }
        let labels = (try? await client.appsCommandLabels(userID: userID,
                                                          channelID: channelID,
                                                          teamID: teamID)) ?? []
        let posture = ComposerAppsPosture(isEnabled: true, commandLabels: labels)
        cachedAppsPosture = posture
        return posture
    }

    /// The apps answer, kept for the life of **this** service — which is one composer (the
    /// coordinators build a fresh service per composer), so a channel switch re-asks and a plugin
    /// installed mid-session is seen on the next composer rather than never. A failed read is
    /// cached too, deliberately: an apps plugin that is down must not put two extra requests in
    /// front of every command the reader sends.
    private var cachedAppsPosture: ComposerAppsPosture?
}
