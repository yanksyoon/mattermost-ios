import Foundation
import UserNotifications

// MARK: - v4 REST subsets used by the poller

/// A post as returned by `/channels/{channel_id}/posts`. The shell reads only the fields
/// needed to build a `MentionNotification`.
struct MentionPost: Codable, Equatable, Identifiable {
    let id: String
    let createAt: Int64
    let userId: String
    let channelId: String
    let message: String

    enum CodingKeys: String, CodingKey {
        case id, message
        case createAt = "create_at"
        case userId = "user_id"
        case channelId = "channel_id"
    }
}

/// The `PostList` envelope (`{order, posts, next_post_id, prev_post_id}`). Posts are keyed
/// by id; the order array is ignored — the poller sorts by create time itself.
struct PostsSinceResponse: Codable {
    let order: [String]?
    let posts: [String: MentionPost]?
}

/// A `TeamUnread` row (taken from `/users/me/teams/unread`).
struct TeamUnread: Codable, Equatable {
    let teamId: String
    let mentionCount: Int
    let msgCount: Int

    enum CodingKeys: String, CodingKey {
        case teamId = "team_id"
        case mentionCount = "mention_count"
        case msgCount = "msg_count"
    }
}

/// A `ChannelUnread` row (taken from `/users/me/teams/{team_id}/channels/unread`).
struct ChannelUnread: Codable, Equatable {
    let teamId: String
    let channelId: String
    let msgCount: Int
    let mentionCount: Int

    enum CodingKeys: String, CodingKey {
        case teamId = "team_id"
        case channelId = "channel_id"
        case msgCount = "msg_count"
        case mentionCount = "mention_count"
    }
}

/// A channel (taken from `/channels/{channel_id}`) — display name for the notification
/// title and team id for the payload's `team_id` field.
struct MentionChannelInfo: Codable, Equatable {
    let id: String
    let name: String
    let displayName: String?
    let teamId: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case displayName = "display_name"
        case teamId = "team_id"
    }
}

/// A user (taken from `/users/{user_id}`) — username for the `@user: message` body.
struct MentionUserInfo: Codable, Equatable {
    let id: String
    let username: String?

    enum CodingKeys: String, CodingKey {
        case id, username
    }
}

// MARK: - Persisted per-server poll state

/// The T14 high-water-mark state for one server, persisted in `AppPreferences` under
/// `mm.mentions.state.<serverUUID>`. Shared by every poll run so a mention is only ever
/// delivered once:
///   - `watermarkTs` / `watermarkPostID` — the newest post create_at (ms) the shell has
///     seen; posts at-or-below it are never considered again ("no history replay").
///   - `notifiedPostIDs` — a bounded ring of post ids already handed to the notification
///     worker (dedupes re-fetches and the tie-break at the watermark).
///   - `channelMentionCounts` — the last poll's per-channel unread mention counts, used to
///     detect *new* mentions (a channel whose count increased gets its posts re-fetched).
struct ServerMentionState: Codable, Equatable {
    var watermarkTs: Int64 = 0
    var watermarkPostID: String = ""
    var notifiedPostIDs: [String] = []
    var channelMentionCounts: [String: Int] = [:]

    /// Cap on remembered post ids (a ring is enough: polls advance the watermark, so the
    /// set only needs to bridge re-fetches / tie-breaks).
    static let maxNotifiedRing = 500

    var isSeeded: Bool { watermarkTs > 0 }

    func hasNotified(_ postID: String) -> Bool {
        notifiedPostIDs.contains(postID)
    }

    mutating func recordNotified(_ postID: String) {
        notifiedPostIDs.removeAll { $0 == postID }
        notifiedPostIDs.insert(postID, at: 0)
        if notifiedPostIDs.count > Self.maxNotifiedRing {
            notifiedPostIDs = Array(notifiedPostIDs.prefix(Self.maxNotifiedRing))
        }
    }
}

// MARK: - The poller

/// T14 background mention poller (Option A). For each configured server with a stored
/// token in `SecureVault`, fetches new mentions over REST and hands each to
/// `NotificationWorker` so title/sound/threading/`userInfo` stay byte-identical to the
/// foreground bridge path. Driven by `BackgroundRefreshScheduler`'s `BGAppRefreshTask`.
///
/// API choice (verified against api.mattermost.com / mattermost-server, documented in
/// docs/t14-build-note.md): the v4 API has **no** `GET /users/me/mentions` endpoint, so the
/// task's prescribed fallback is used:
///   1. `GET /users/me/teams/unread?exclude_team=`        -> per-team unread mention counts
///   2. `GET /users/me/teams/{team_id}/channels/unread`   -> per-channel unread mention counts
///   3. `GET /channels/{channel_id}/posts?since=<mark>`   -> candidate posts in channels
///      whose unread mention count *increased* since the last poll
///   4. `GET /channels/{channel_id}` and `GET /users/{user_id}` -> title/team/user context
/// The mention-count delta is the server-authoritative "there is something new here"
/// signal; the `since` window (create_at > watermark, ring-deduped) supplies the posts.
///
/// Honest limits (recorded in the build note): DM/GM unread counts are not surfaced by
/// the teams-unread drill-down, so the background poller covers team-channel mentions
/// only; a brand-new mention in a channel the user has *not* read can be delivered once by
/// the foreground bridge and once by the poller (the poller cannot see the web app's
/// ephemeral notification); real-time presence cannot survive background suspension (see
/// the build note). None of these apply to the unit-tested contracts here.
@MainActor
final class MentionPoller {

    /// The shell-wide poller. Stores are bound by `MattermostApp.task` (same binding block
    /// that wires `NotificationWorker`); when unbound — e.g. a pure background launch that
    /// never created the scene — polling degrades to a logged no-op.
    static let shared = MentionPoller()

    /// Registry of configured servers. When nil, a fresh store over the standard
    /// `UserDefaults` is used so a background launch still sees persisted servers.
    weak var serverStore: ServerStore?

    /// Badge store. Only touched when bound (a fresh store would zero out other servers'
    /// contribution to the badge, so an unbound poller logs instead).
    weak var sessionStore: SessionStore?

    /// Token source. Defaults to `SecureVault` (Keychain/first, encrypted-file fallback on
    /// the ad-hoc Catalyst build). Never falls back to `UserDefaults`, never logged.
    var tokenProvider: (URL) -> String? = { url in
        SecureVault().getSecret(key: .authToken, serverURL: url)
    }

    /// Called when a poll gets a `401` — the stored token is no longer accepted.
    ///
    /// The poller cannot reuse the server's `AuthSession` client: it runs from a
    /// `BGAppRefreshTask` with no scene, so it owns an ephemeral `URLSession` that it can tear down
    /// on task expiration. Without this report a revoked token left polling failing silently while
    /// the shell still believed it was signed in (T31-AV F3). `MattermostApp.bindShellStores()`
    /// wires it to `AuthCoordinator.reportUnauthorized(_:)`, i.e. into the same single re-auth path
    /// every other authenticated call uses. Unbound → logged no-op.
    var unauthorizedReporter: ((ServerConfig) async -> Void)?

    /// Gate consulted before the delivery loop. Exists so the poller never triggers the
    /// system permission prompt from a background launch (`presentMention` requests the
    /// prompt on first mention — appropriate only while foregrounded).
    var authorizationGate: () async -> Bool = {
        let worker = NotificationWorker.shared
        await worker.reloadAuthorizationStatus()
        switch worker.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    // MARK: Result types

    struct ServerPollResult: Equatable {
        enum Outcome: Equatable {
            /// No token stored for this server — nothing to fetch.
            case skippedNoToken
            /// First run: watermark seeded, nothing older than it was notified.
            case seeded
            /// Real poll completed (possibly with zero new mentions).
            case polled(notifiedCount: Int, watermarkTs: Int64)
            /// Transport/auth failure — logged no-op, state untouched.
            case failed(String)
        }
        var serverID: UUID
        var outcome: Outcome
    }

    // MARK: Plumbing

    enum PollError: LocalizedError, Equatable {
        case transport(String)
        case httpStatus(Int)
        case decoding(String)

        /// A `401`: the stored token was rejected. Distinct from any other HTTP failure because it
        /// is not the poll's problem — it is the session's, and it aborts the whole poll.
        var isSessionExpiry: Bool {
            if case .httpStatus(401) = self { return true }
            return false
        }

        var errorDescription: String? {
            switch self {
            case .transport(let m): return "transport: \(m)"
            case .httpStatus(let s): return "HTTP \(s)"
            case .decoding(let m): return "decode: \(m)"
            }
        }
    }

    private let preferences: AppPreferences
    private let injectedSession: URLSession?
    private var ownSession: URLSession?
    private let deliverMention: (MentionNotification, UUID) async -> NotificationWorker.PresentOutcome
    private let nowMs: () -> Int64

    static func stateKey(for serverID: UUID) -> String {
        "mm.mentions.state.\(serverID.uuidString)"
    }

    init(preferences: AppPreferences = AppPreferences(),
         session: URLSession? = nil,
         deliverMention: ((MentionNotification, UUID) async -> NotificationWorker.PresentOutcome)? = nil,
         nowMs: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.preferences = preferences
        self.injectedSession = session
        self.nowMs = nowMs
        self.deliverMention = deliverMention ?? { mention, serverID in
            await NotificationWorker.shared.presentMention(mention, fromServerID: serverID)
        }
    }

    /// The session to use: an injected one (tests) or a lazily created self-owned
    /// ephemeral session (production).
    private func networkSession() -> URLSession {
        if let injectedSession { return injectedSession }
        if let ownSession { return ownSession }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config)
        ownSession = session
        return session
    }

    /// Expiration-handler path (BGTask about to be killed): tear the self-owned session
    /// down so in-flight `data(for:)` calls fail fast instead of leaving the task hanging.
    /// Injected sessions are left alone (the test owns them).
    func cancelInFlight() {
        guard injectedSession == nil else { return }
        ownSession?.invalidateAndCancel()
        ownSession = nil
        Logger.info("MentionPoller", "in-flight URLSession work cancelled (task expiration)")
    }

    // MARK: - Entry points

    /// Poll every configured server that has a stored token. Never throws; per-server
    /// failures degrade to logged no-ops. Returns a per-server result for tests/diagnostics.
    @discardableResult
    func pollAllServers() async -> [ServerPollResult] {
        let servers = serverStore?.servers ?? ServerStore(preferences: preferences).servers
        guard !servers.isEmpty else {
            Logger.debug("MentionPoller", "no servers configured; nothing to poll")
            return []
        }
        var results: [ServerPollResult] = []
        for server in servers {
            guard let token = tokenProvider(server.url), !token.isEmpty else {
                results.append(ServerPollResult(serverID: server.id, outcome: .skippedNoToken))
                Logger.debug("MentionPoller", "\(server.name): skipped — no stored token")
                continue
            }
            results.append(await poll(server: server, token: token))
        }
        return results
    }

    /// Poll one server. Test-facing; `pollAllServers()` is what the BGTask drives.
    func poll(server: ServerConfig, token: String) async -> ServerPollResult {
        let session = networkSession()
        let apiBase = server.url.appendingPathComponent("api/v4")
        var state = loadState(for: server.id)

        do {
            // 1. Per-team unread mention counts (+ the badge input).
            let teamsUnread: [TeamUnread] = try await getJSON(
                session, apiBase: apiBase,
                path: "users/me/teams/unread",
                query: [URLQueryItem(name: "exclude_team", value: "")],
                token: token)
            let mentionTotal = teamsUnread.reduce(0) { $0 + $1.mentionCount }
            let unreadTotal = teamsUnread.reduce(0) { $0 + $1.msgCount }
            if let sessionStore {
                sessionStore.updateMentions(serverID: server.id, mentionCount: mentionTotal,
                                            isUnread: mentionTotal > 0 || unreadTotal > 0)
            } else {
                Logger.debug("MentionPoller", "\(server.name): sessionStore unbound — badge not updated")
            }

            // 2. Per-channel unread mention counts for teams reporting mentions.
            var currentCounts: [String: Int] = [:]
            for team in teamsUnread where team.mentionCount > 0 {
                do {
                    let channels: [ChannelUnread] = try await getJSON(
                        session, apiBase: apiBase,
                        path: "users/me/teams/\(team.teamId)/channels/unread",
                        token: token)
                    for channel in channels where channel.mentionCount > 0 {
                        currentCounts[channel.channelId] = channel.mentionCount
                    }
                } catch {
                    // Auth failure is not this team's problem: abort the poll so it reaches the
                    // re-auth path instead of being logged as a per-team hiccup.
                    if Self.isSessionExpiry(error) { throw error }
                    // Per-team tolerance: one team's unread fetch failing must not kill the
                    // whole poll. That team's channels keep their old snapshot entries, so
                    // the next poll will still see the delta.
                    Logger.debug("MentionPoller", "\(server.name): team \(team.teamId) unread fetch failed: \(error)")
                }
            }

            // 3. First run seeds the watermark and notifies nothing older than it.
            guard state.isSeeded else {
                state.watermarkTs = nowMs()
                state.channelMentionCounts = currentCounts
                persist(state, for: server.id)
                Logger.info("MentionPoller", "\(server.name): first run — seeded watermark \(state.watermarkTs), notifying nothing older than the watermark")
                return ServerPollResult(serverID: server.id, outcome: .seeded)
            }

            // 4. Channels whose unread mention count went UP since the last snapshot carry
            //    the new mentions.
            let increasedChannels = currentCounts.filter { channelID, count in
                let previous = state.channelMentionCounts[channelID] ?? 0
                return count > previous
            }

            var newPosts: [(post: MentionPost, channel: MentionChannelInfo?)] = []
            var maxFetchedTs = state.watermarkTs
            var maxFetchedPostID = state.watermarkPostID
            var fetchedAny = false
            for (channelID, _) in increasedChannels {
                do {
                    let postsResponse: PostsSinceResponse = try await getJSON(
                        session, apiBase: apiBase,
                        path: "channels/\(channelID)/posts",
                        query: [URLQueryItem(name: "since", value: String(state.watermarkTs))],
                        token: token)
                    fetchedAny = true
                    for post in (postsResponse.posts?.values).map(Array.init) ?? [] {
                        if post.createAt > maxFetchedTs {
                            maxFetchedTs = post.createAt
                            maxFetchedPostID = post.id
                        }
                        if Self.isNew(post, relativeTo: state) {
                            newPosts.append((post, nil))
                        }
                    }
                } catch {
                    // As above: a 401 aborts; any other per-channel failure is tolerated.
                    if Self.isSessionExpiry(error) { throw error }
                    // Per-channel tolerance as above: log, skip, keep old snapshot entry.
                    Logger.debug("MentionPoller", "\(server.name): channel \(channelID) posts fetch failed: \(error)")
                }
            }

            // 5. Deliver ascending (oldest first), exactly one notification per mention.
            newPosts.sort { lhs, rhs in
                lhs.post.createAt != rhs.post.createAt
                    ? lhs.post.createAt < rhs.post.createAt
                    : lhs.post.id < rhs.post.id
            }
            var delivered = 0
            if !newPosts.isEmpty {
                if await authorizationGate() {
                    for item in newPosts {
                        let channel = await resolvedChannel(for: item, session: session, apiBase: apiBase, token: token)
                        // Poster username for the webapp-parity "@user: message" body;
                        // fail-soft to the bare message when the profile fetch fails.
                        let user = try? await getJSON(session, apiBase: apiBase,
                                                      path: "users/\(item.post.userId)", token: token) as MentionUserInfo
                        let mention = Self.makeMention(post: item.post, channel: channel, user: user, server: server)
                        let outcome = await deliverMention(mention, server.id)
                        // Record the attempt regardless of outcome: a denied/unavailable
                        // permission shouldn't be retried on every poll.
                        state.recordNotified(item.post.id)
                        if case .scheduled = outcome { delivered += 1 }
                    }
                } else {
                    // Notifications not authorized: record the mentions as seen so the
                    // watermark still advances and nothing replays when permission appears.
                    for item in newPosts { state.recordNotified(item.post.id) }
                    Logger.debug("MentionPoller", "\(server.name): \(newPosts.count) new mention(s) recorded but not delivered — notifications not authorized")
                }
            }
            // Advance the high-water mark over every post actually fetched (notified or
            // not) so nothing is re-fetched/re-considered by later polls.
            if fetchedAny, maxFetchedTs > state.watermarkTs {
                state.watermarkTs = maxFetchedTs
                state.watermarkPostID = maxFetchedPostID
            }
            state.channelMentionCounts = currentCounts
            persist(state, for: server.id)
            Logger.info("MentionPoller", "\(server.name): polled — \(delivered) new mention(s) notified, watermark \(state.watermarkTs)")
            return ServerPollResult(serverID: server.id, outcome: .polled(notifiedCount: delivered, watermarkTs: state.watermarkTs))
        } catch {
            if Self.isSessionExpiry(error) {
                Logger.info("MentionPoller", "\(server.name): the stored token was rejected (401) — requesting re-auth")
                if let reporter = unauthorizedReporter {
                    await reporter(server)
                } else {
                    Logger.debug("MentionPoller", "\(server.name): no re-auth reporter bound; the shell will notice at the next restore")
                }
                return ServerPollResult(serverID: server.id, outcome: .failed("session expired"))
            }
            Logger.debug("MentionPoller", "\(server.name): poll failed — \(error)")
            return ServerPollResult(serverID: server.id, outcome: .failed(error.localizedDescription))
        }
    }

    /// Whether `error` is a `401` from any depth of the poll (top level or a per-team/per-channel
    /// fetch that would otherwise be tolerated).
    nonisolated static func isSessionExpiry(_ error: Error) -> Bool {
        (error as? PollError)?.isSessionExpiry ?? false
    }

    // MARK: - Pure helpers (unit-tested)

    /// Whether a post is new relative to the high-water mark: strictly newer in time, or
    /// at the same millisecond but different from the post id that marked it. The notified
    /// ring overrides both (dedupe across polls).
    nonisolated static func isNew(_ post: MentionPost, relativeTo state: ServerMentionState) -> Bool {
        guard !state.hasNotified(post.id) else { return false }
        if post.createAt > state.watermarkTs { return true }
        if post.createAt == state.watermarkTs, post.id != state.watermarkPostID { return true }
        return false
    }

    /// Build the `MentionNotification` the foreground bridge would have produced: channel
    /// display name (or the desktop default) as title, `@username: message` as body,
    /// channel/team ids and server URL filled for the push-proxy-parity `userInfo`.
    nonisolated static func makeMention(post: MentionPost,
                                        channel: MentionChannelInfo?,
                                        user: MentionUserInfo?,
                                        server: ServerConfig) -> MentionNotification {
        let title = channel?.displayName.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }?
            .nilIfEmpty ?? "Someone mentioned you"
        let body: String
        if let username = user?.username, !username.isEmpty {
            body = "@\(username): \(post.message)"
        } else {
            body = post.message
        }
        return MentionNotification(title: title, body: body,
                                   channelID: post.channelId,
                                   teamID: channel?.teamId ?? "",
                                   serverURL: server.url.absoluteString,
                                   silent: false, soundName: nil)
    }

    // MARK: - State persistence

    func loadState(for serverID: UUID) -> ServerMentionState {
        preferences.get(ServerMentionState.self, forKey: Self.stateKey(for: serverID))
            ?? ServerMentionState()
    }

    private func persist(_ state: ServerMentionState, for serverID: UUID) {
        preferences.set(state, forKey: Self.stateKey(for: serverID))
    }

    // MARK: - Fetch plumbing

    private func resolvedChannel(for item: (post: MentionPost, channel: MentionChannelInfo?),
                                 session: URLSession, apiBase: URL, token: String) async -> MentionChannelInfo? {
        if let channel = item.channel { return channel }
        return try? await getJSON(session, apiBase: apiBase, path: "channels/\(item.post.channelId)", token: token)
    }

    private func getJSON<T: Decodable>(_ session: URLSession, apiBase: URL, path: String,
                                       query: [URLQueryItem] = [], token: String) async throws -> T {
        var components = URLComponents(url: apiBase.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PollError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw PollError.transport("non-HTTP response") }
        guard (200..<300).contains(http.statusCode) else { throw PollError.httpStatus(http.statusCode) }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw PollError.decoding(error.localizedDescription)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
