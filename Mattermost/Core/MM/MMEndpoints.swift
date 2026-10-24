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

    /// `POST /users/ids` (batched profile fetch; the API takes the ids in the body).
    func users(ids: [String]) async throws -> [MMUser] {
        try await post([MMUser].self, path: "/users/ids", body: ids)
    }

    /// `GET /users/{id}/preferences` — the server preferences that back theme/sidebar/display.
    func preferences(userID: String = "me") async throws -> [MMPreference] {
        try await get([MMPreference].self, path: "/users/\(userID)/preferences")
    }

    /// `GET /users/status/ids` is a POST in v4; kept here for the socket `status_change` resync.
    func statuses(ids: [String]) async throws -> [MMStatus] {
        try await post([MMStatus].self, path: "/users/status/ids", body: ids)
    }
}
