// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0,
// `ios/Gekidou/Sources/Gekidou/Networking/Network+{Posts,Channel,Users}.swift` — same endpoints
// and query shapes, own `async`/`await` surface per docs/path-b-adr.md §3.

import Foundation

/// The typed v4 endpoints T28 owns. Screen cards add their own endpoint groups on top of
/// `APIClient`; these exist because the transport's own acceptance criteria (pagination, auth,
/// socket resync) exercise them.
extension APIClient {

    /// `GET /system/ping` — unauthenticated liveness/version probe.
    func ping() async throws -> MMPing {
        try await get(MMPing.self, path: "/system/ping", requiresAuth: false, useETag: false)
    }

    /// `GET /users/me`.
    func currentUser() async throws -> MMUser {
        try await get(MMUser.self, path: "/users/me")
    }

    /// `GET /channels/{id}/posts` with the page cursor's query items (`page`/`per_page`,
    /// `before`, `after`, `since`).
    func posts(channelID: String,
               page: MMPostPage,
               collapsedThreads: Bool = false) async throws -> MMPostList {
        var query = page.queryItems
        if collapsedThreads {
            query.append(URLQueryItem(name: "collapsedThreads", value: "true"))
            query.append(URLQueryItem(name: "collapsedThreadsExtended", value: "true"))
        }
        return try await get(MMPostList.self, path: "/channels/\(channelID)/posts", query: query)
    }

    /// `GET /posts/{id}/thread` — the root plus replies, used by the socket resync path to refetch
    /// a thread that changed while the socket was down.
    func thread(rootPostID: String, perPage: Int = 60) async throws -> MMPostList {
        let query = [URLQueryItem(name: "perPage", value: String(max(1, perPage))),
                     URLQueryItem(name: "fromCreateAt", value: "0"),
                     URLQueryItem(name: "direction", value: "up")]
        return try await get(MMPostList.self, path: "/posts/\(rootPostID)/thread", query: query)
    }

    /// `GET /posts/{id}` — single post, used by resync for a single edited/deleted post.
    func post(id: String) async throws -> MMPost {
        try await get(MMPost.self, path: "/posts/\(id)")
    }

    /// `GET /channels/{id}`.
    func channel(id: String) async throws -> MMChannel {
        try await get(MMChannel.self, path: "/channels/\(id)")
    }

    /// The largest id list one `POST /users/ids` may carry.
    ///
    /// A workspace with hundreds of direct messages produces hundreds of ids, and one request with
    /// all of them is both the slowest step of a load and fragile (one failure loses every profile).
    /// Callers that need more than this get several requests, merged in input order.
    static let usersBatchSize = 100

    /// `POST /users/ids` (batched profile fetch; the API takes the ids in the body).
    ///
    /// - Chunked at `usersBatchSize`, merged: a DM sidebar on a large workspace asks for hundreds of
    ///   ids and must not put them in one body (card t_c0e42801).
    /// - Empty ids return `[]` without a request, and duplicate ids are sent once (the server answers
    ///   a list, not a bag).
    /// - Order is the caller's: each answer is appended in chunk order, so a screen that zips ids to
    ///   profiles still lines up.
    func users(ids: [String]) async throws -> [MMUser] {
        var seen = Set<String>()
        let ordered = ids.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !ordered.isEmpty else { return [] }
        guard ordered.count > Self.usersBatchSize else {
            return try await post([MMUser].self, path: "/users/ids", body: ordered)
        }
        var merged: [MMUser] = []
        for start in stride(from: 0, to: ordered.count, by: Self.usersBatchSize) {
            let chunk = Array(ordered[start..<min(start + Self.usersBatchSize, ordered.count)])
            merged += try await post([MMUser].self, path: "/users/ids", body: chunk)
        }
        return merged
    }

    /// `GET /users/{id}/preferences` — the server preferences that back theme/sidebar/display.
    func preferences(userID: String = "me") async throws -> [MMPreference] {
        try await get([MMPreference].self, path: "/users/\(userID)/preferences")
    }

    /// `GET /users/status/ids` is a POST in v4; kept here for the socket `status_change` resync.
    func statuses(ids: [String]) async throws -> [MMStatus] {
        try await post([MMStatus].self, path: "/users/status/ids", body: ids)
    }

    // MARK: - Teams (T32, S07/S08)

    /// `GET /users/me/teams` — the teams the signed-in user belongs to (upstream
    /// `app/client/rest/teams.ts` `getMyTeams`).
    ///
    /// ETag-conditional on purpose: the team list changes rarely (a join, a rename, a new icon), and
    /// a `304` replay is exactly the right answer for a rail that re-reads it on every appearance.
    func myTeams() async throws -> [MMTeam] {
        try await get([MMTeam].self, path: "/users/me/teams", useETag: true)
    }

    /// `GET /users/me/teams/members` — the user's team memberships, which is what tells a
    /// soft-deleted membership (left / removed team) apart from a live one.
    func myTeamMemberships() async throws -> [MMTeamMembership] {
        try await get([MMTeamMembership].self, path: "/users/me/teams/members", useETag: true)
    }

    /// `GET /users/me/teams/unread` — per-team mention and message counters (the rail's badges).
    ///
    /// **No ETag**: a replayed `304` body here would pin the badges to the numbers they had when the
    /// rail first appeared, which is precisely the staleness the card forbids. The endpoint is cheap
    /// (one row per team) and the client refreshes it on socket activity.
    func teamUnreads() async throws -> [MMTeamUnread] {
        try await get([MMTeamUnread].self, path: "/users/me/teams/unread", useETag: false)
    }

    /// `GET /teams/{team_id}/image` path + the `_` cache-buster upstream sends
    /// (`app/client/rest/teams.ts` `getTeamIconUrl`).
    func teamIconPath(teamID: String, lastUpdateAt: Int64) -> String {
        "/teams/\(teamID)/image"
    }

    /// Authenticated team-icon bytes. The endpoint is behind the session, so `AsyncImage` (which
    /// cannot send an `Authorization` header) is not an option; the bytes go through the same
    /// `APIClient` — and therefore the same 401 → re-auth path — as every other native call.
    func teamIconData(teamID: String, lastUpdateAt: Int64) async throws -> Data {
        var query: [URLQueryItem] = []
        if lastUpdateAt > 0 {
            query.append(URLQueryItem(name: "_", value: String(lastUpdateAt)))
        }
        return try await getData(path: teamIconPath(teamID: teamID, lastUpdateAt: lastUpdateAt),
                                 query: query,
                                 useETag: true)
    }
}
