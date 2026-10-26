// Ported from mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: ios/Gekidou/Sources/Gekidou/DataTypes/Post.swift, PostResponse.swift, User.swift,
//        Channel.swift, Preference.swift, Status.swift, Reaction.swift
// Licence: Apache-2.0 (upstream LICENSE.txt) — ported with attribution per docs/THIRD_PARTY_NOTICES.md
//
// Divergences from upstream (recorded in docs/t28-build-note.md §5):
//  - `Int64` milliseconds instead of upstream's `Double` (Mattermost sends integer millis; Double
//    loses precision above 2^53 and imports floating-point noise into equality checks).
//  - tolerant decoding is kept, but defaults are type-correct and documented per field, since
//    T28 is the only decoder and every screen card inherits these shapes.
//  - `props` / `metadata` are `JSONValue` rather than upstream's `[String: Any]` (which is not
//    `Sendable` and forces a `Database.default.json(from:)` round-trip on every decode).

import Foundation

/// A Mattermost post (`GET /api/v4/posts/{id}`, the `posts` map of a post list, `posted` events).
struct MMPost: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var createAt: Int64
    var updateAt: Int64
    var editAt: Int64
    var deleteAt: Int64
    var isPinned: Bool
    var userId: String
    var channelId: String
    var rootId: String
    var originalId: String
    var message: String
    var messageSource: String
    var type: String
    var props: JSONValue?
    var metadata: JSONValue?
    var fileIds: [String]
    var replyCount: Int
    var lastReplyAt: Int64
    var isFollowing: Bool
    /// The client id a *sender* supplied on `POST /posts`, echoed by the server on the socket
    /// `posted` event. T35 (the composer) uses it to replace its optimistic row with the real post
    /// instead of guessing by message text. Empty for every post this app did not create.
    var pendingPostId: String
    /// CRT participants, when the server sends them (collapsed-thread mode).
    var participants: [MMUser]?

    enum CodingKeys: String, CodingKey {
        case id, message, type, props, metadata, participants
        case createAt = "create_at"
        case updateAt = "update_at"
        case editAt = "edit_at"
        case deleteAt = "delete_at"
        case isPinned = "is_pinned"
        case userId = "user_id"
        case channelId = "channel_id"
        case rootId = "root_id"
        case originalId = "original_id"
        case messageSource = "message_source"
        case fileIds = "file_ids"
        case replyCount = "reply_count"
        case lastReplyAt = "last_reply_at"
        case isFollowing = "is_following"
        case pendingPostId = "pending_post_id"
    }

    init(id: String,
         createAt: Int64 = 0,
         updateAt: Int64 = 0,
         editAt: Int64 = 0,
         deleteAt: Int64 = 0,
         isPinned: Bool = false,
         userId: String = "",
         channelId: String = "",
         rootId: String = "",
         originalId: String = "",
         message: String = "",
         messageSource: String = "",
         type: String = "",
         props: JSONValue? = nil,
         metadata: JSONValue? = nil,
         fileIds: [String] = [],
         replyCount: Int = 0,
         lastReplyAt: Int64 = 0,
         isFollowing: Bool = false,
         pendingPostId: String = "",
         participants: [MMUser]? = nil) {
        self.id = id
        self.createAt = createAt
        self.updateAt = updateAt
        self.editAt = editAt
        self.deleteAt = deleteAt
        self.isPinned = isPinned
        self.userId = userId
        self.channelId = channelId
        self.rootId = rootId
        self.originalId = originalId
        self.message = message
        self.messageSource = messageSource
        self.type = type
        self.props = props
        self.metadata = metadata
        self.fileIds = fileIds
        self.replyCount = replyCount
        self.lastReplyAt = lastReplyAt
        self.isFollowing = isFollowing
        self.pendingPostId = pendingPostId
        self.participants = participants
    }

    /// Tolerant decoding, upstream behaviour: a field the (older/newer) server omits becomes its
    /// zero value instead of failing the whole page. Only `id` is meaningful for identity.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? ""
        createAt = try values.decodeIfPresent(Int64.self, forKey: .createAt) ?? 0
        updateAt = try values.decodeIfPresent(Int64.self, forKey: .updateAt) ?? 0
        editAt = try values.decodeIfPresent(Int64.self, forKey: .editAt) ?? 0
        deleteAt = try values.decodeIfPresent(Int64.self, forKey: .deleteAt) ?? 0
        isPinned = try values.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        userId = try values.decodeIfPresent(String.self, forKey: .userId) ?? ""
        channelId = try values.decodeIfPresent(String.self, forKey: .channelId) ?? ""
        rootId = try values.decodeIfPresent(String.self, forKey: .rootId) ?? ""
        originalId = try values.decodeIfPresent(String.self, forKey: .originalId) ?? ""
        message = try values.decodeIfPresent(String.self, forKey: .message) ?? ""
        messageSource = try values.decodeIfPresent(String.self, forKey: .messageSource) ?? ""
        type = try values.decodeIfPresent(String.self, forKey: .type) ?? ""
        fileIds = try values.decodeIfPresent([String].self, forKey: .fileIds) ?? []
        replyCount = try values.decodeIfPresent(Int.self, forKey: .replyCount) ?? 0
        lastReplyAt = try values.decodeIfPresent(Int64.self, forKey: .lastReplyAt) ?? 0
        isFollowing = try values.decodeIfPresent(Bool.self, forKey: .isFollowing) ?? false
        pendingPostId = try values.decodeIfPresent(String.self, forKey: .pendingPostId) ?? ""
        participants = try? values.decodeIfPresent([MMUser].self, forKey: .participants)
        props = try? values.decodeIfPresent(JSONValue.self, forKey: .props)
        metadata = try? values.decodeIfPresent(JSONValue.self, forKey: .metadata)
    }
}

/// A page of posts (`GET /api/v4/channels/{id}/posts`, `GET /api/v4/posts/{id}/thread`).
///
/// `order` is newest-first for a channel page and oldest-first for a thread; the pagination
/// helpers in `MMPagination.swift` rely on that and say so explicitly.
struct MMPostList: Codable, Equatable, Sendable {
    var order: [String]
    var posts: [String: MMPost]
    var nextPostID: String
    var prevPostID: String
    /// Some endpoints (threads) include this; absent means "unknown", not "no more".
    var hasNext: Bool?

    enum CodingKeys: String, CodingKey {
        case order, posts
        case nextPostID = "next_post_id"
        case prevPostID = "prev_post_id"
        case hasNext = "has_next"
    }

    init(order: [String] = [],
         posts: [String: MMPost] = [:],
         nextPostID: String = "",
         prevPostID: String = "",
         hasNext: Bool? = nil) {
        self.order = order
        self.posts = posts
        self.nextPostID = nextPostID
        self.prevPostID = prevPostID
        self.hasNext = hasNext
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        order = try values.decodeIfPresent([String].self, forKey: .order) ?? []
        posts = try values.decodeIfPresent([String: MMPost].self, forKey: .posts) ?? [:]
        nextPostID = try values.decodeIfPresent(String.self, forKey: .nextPostID) ?? ""
        prevPostID = try values.decodeIfPresent(String.self, forKey: .prevPostID) ?? ""
        hasNext = try values.decodeIfPresent(Bool.self, forKey: .hasNext)
    }

    /// The posts in server order, skipping ids the map does not carry.
    var orderedPosts: [MMPost] { order.compactMap { posts[$0] } }
}

/// A Mattermost user (`GET /api/v4/users/me`, `/users/ids`, `/users/usernames`, `user_updated`).
struct MMUser: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var username: String
    var email: String
    var firstName: String
    var lastName: String
    var nickname: String
    var deleteAt: Int64
    var updateAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, username, email, nickname
        case firstName = "first_name"
        case lastName = "last_name"
        case deleteAt = "delete_at"
        case updateAt = "update_at"
    }

    init(id: String,
         username: String = "",
         email: String = "",
         firstName: String = "",
         lastName: String = "",
         nickname: String = "",
         deleteAt: Int64 = 0,
         updateAt: Int64 = 0) {
        self.id = id
        self.username = username
        self.email = email
        self.firstName = firstName
        self.lastName = lastName
        self.nickname = nickname
        self.deleteAt = deleteAt
        self.updateAt = updateAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? ""
        username = try values.decodeIfPresent(String.self, forKey: .username) ?? ""
        email = try values.decodeIfPresent(String.self, forKey: .email) ?? ""
        firstName = try values.decodeIfPresent(String.self, forKey: .firstName) ?? ""
        lastName = try values.decodeIfPresent(String.self, forKey: .lastName) ?? ""
        nickname = try values.decodeIfPresent(String.self, forKey: .nickname) ?? ""
        deleteAt = try values.decodeIfPresent(Int64.self, forKey: .deleteAt) ?? 0
        updateAt = try values.decodeIfPresent(Int64.self, forKey: .updateAt) ?? 0
    }
}

/// A Mattermost channel (`GET /api/v4/channels/{id}`). `type` is `O`, `P`, `D` or `G`.
struct MMChannel: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var displayName: String
    var type: String
    var teamId: String
    var header: String
    var purpose: String
    var lastPostAt: Int64
    var totalMsgCount: Int64
    /// T33: `create_at` / `delete_at` are read by the sidebar. `delete_at` filters an archived
    /// channel out of the list (upstream `filterArchivedChannels`, which keeps only the channel you
    /// are currently looking at), and `create_at` is the fallback activity key for a channel that has
    /// never been posted in (`sortChannels(…, sorting: "recent")` uses `max(lastPostAt, createAt)`).
    var createAt: Int64
    var deleteAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, name, type, header, purpose
        case displayName = "display_name"
        case teamId = "team_id"
        case lastPostAt = "last_post_at"
        case totalMsgCount = "total_msg_count"
        case createAt = "create_at"
        case deleteAt = "delete_at"
    }

    init(id: String,
         name: String = "",
         displayName: String = "",
         type: String = "",
         teamId: String = "",
         header: String = "",
         purpose: String = "",
         lastPostAt: Int64 = 0,
         totalMsgCount: Int64 = 0,
         createAt: Int64 = 0,
         deleteAt: Int64 = 0) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.type = type
        self.teamId = teamId
        self.header = header
        self.purpose = purpose
        self.lastPostAt = lastPostAt
        self.totalMsgCount = totalMsgCount
        self.createAt = createAt
        self.deleteAt = deleteAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        displayName = try values.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        type = try values.decodeIfPresent(String.self, forKey: .type) ?? ""
        teamId = try values.decodeIfPresent(String.self, forKey: .teamId) ?? ""
        header = try values.decodeIfPresent(String.self, forKey: .header) ?? ""
        purpose = try values.decodeIfPresent(String.self, forKey: .purpose) ?? ""
        lastPostAt = try values.decodeIfPresent(Int64.self, forKey: .lastPostAt) ?? 0
        totalMsgCount = try values.decodeIfPresent(Int64.self, forKey: .totalMsgCount) ?? 0
        createAt = try values.decodeIfPresent(Int64.self, forKey: .createAt) ?? 0
        deleteAt = try values.decodeIfPresent(Int64.self, forKey: .deleteAt) ?? 0
    }
}

/// A user preference row (`GET /api/v4/users/{id}/preferences`).
struct MMPreference: Codable, Equatable, Sendable {
    var userId: String
    var category: String
    var name: String
    var value: String

    enum CodingKeys: String, CodingKey {
        case category, name, value
        case userId = "user_id"
    }

    init(userId: String = "", category: String, name: String, value: String) {
        self.userId = userId
        self.category = category
        self.name = name
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        userId = try values.decodeIfPresent(String.self, forKey: .userId) ?? ""
        category = try values.decodeIfPresent(String.self, forKey: .category) ?? ""
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        value = try values.decodeIfPresent(String.self, forKey: .value) ?? ""
    }
}

/// A reaction (`reaction_added` / `reaction_removed`).
///
/// `channelId` is the **routing** fact, not part of the stored reaction: 9.11.19 sends it inside the
/// event's reaction payload (measured — `av-ws-watch.log`, `docs/t37-build-note.md` §T37-R), and it is
/// what lets `TeamSocketScope` attribute an event the app did not write to the team on screen
/// (T37-R F1). A `metadata.reactions` row read back from the server also carries it.
struct MMReaction: Codable, Equatable, Sendable {
    var userId: String
    var postId: String
    var emojiName: String
    var createAt: Int64
    /// The channel the reacted post is in. Empty when the payload did not name it.
    var channelId: String

    enum CodingKeys: String, CodingKey {
        case createAt = "create_at"
        case userId = "user_id"
        case postId = "post_id"
        case emojiName = "emoji_name"
        case channelId = "channel_id"
    }

    init(userId: String = "", postId: String = "", emojiName: String = "", createAt: Int64 = 0,
         channelId: String = "") {
        self.userId = userId
        self.postId = postId
        self.emojiName = emojiName
        self.createAt = createAt
        self.channelId = channelId
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        userId = try values.decodeIfPresent(String.self, forKey: .userId) ?? ""
        postId = try values.decodeIfPresent(String.self, forKey: .postId) ?? ""
        emojiName = try values.decodeIfPresent(String.self, forKey: .emojiName) ?? ""
        createAt = try values.decodeIfPresent(Int64.self, forKey: .createAt) ?? 0
        channelId = try values.decodeIfPresent(String.self, forKey: .channelId) ?? ""
    }

    /// A reaction the pane applies locally is written back into the row's `metadata.reactions`; the
    /// channel is routing and is left out unless the payload actually carried it, so the JSON this
    /// client stores keeps the shape the server's own rows have.
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(userId, forKey: .userId)
        try values.encode(postId, forKey: .postId)
        try values.encode(emojiName, forKey: .emojiName)
        try values.encode(createAt, forKey: .createAt)
        if !channelId.isEmpty { try values.encode(channelId, forKey: .channelId) }
    }
}

/// A presence row (`status_change`, `GET /api/v4/users/status/ids`).
struct MMStatus: Codable, Equatable, Sendable {
    var userId: String
    var status: String
    var manual: Bool
    var lastActivityAt: Int64

    enum CodingKeys: String, CodingKey {
        case status, manual
        case userId = "user_id"
        case lastActivityAt = "last_activity_at"
    }

    init(userId: String = "", status: String = "offline", manual: Bool = false, lastActivityAt: Int64 = 0) {
        self.userId = userId
        self.status = status
        self.manual = manual
        self.lastActivityAt = lastActivityAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        userId = try values.decodeIfPresent(String.self, forKey: .userId) ?? ""
        status = try values.decodeIfPresent(String.self, forKey: .status) ?? "offline"
        manual = try values.decodeIfPresent(Bool.self, forKey: .manual) ?? false
        lastActivityAt = try values.decodeIfPresent(Int64.self, forKey: .lastActivityAt) ?? 0
    }
}

/// `GET /api/v4/system/ping` (unauthenticated liveness probe).
struct MMPing: Codable, Equatable, Sendable {
    var status: String
    var version: String

    init(status: String = "OK", version: String = "") {
        self.status = status
        self.version = version
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        status = try values.decodeIfPresent(String.self, forKey: .status) ?? ""
        version = try values.decodeIfPresent(String.self, forKey: .version) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case status, version }
}

/// The server's error body (`app.AppError` JSON), used only for the human-readable message and
/// to detect the MFA challenge. Behaviour reference: mattermost/mattermost-mobile @ v2.45.0,
/// `app/client/rest/error.ts` — own implementation per docs/path-b-adr.md §3.
struct MMServerErrorPayload: Codable, Equatable, Sendable {
    var id: String
    var message: String
    var detailedError: String
    var requestID: String
    var statusCode: Int

    enum CodingKeys: String, CodingKey {
        case id, message
        case detailedError = "detailed_error"
        case requestID = "request_id"
        case statusCode = "status_code"
    }

    init(id: String = "", message: String = "", detailedError: String = "",
         requestID: String = "", statusCode: Int = 0) {
        self.id = id
        self.message = message
        self.detailedError = detailedError
        self.requestID = requestID
        self.statusCode = statusCode
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? ""
        message = try values.decodeIfPresent(String.self, forKey: .message) ?? ""
        detailedError = try values.decodeIfPresent(String.self, forKey: .detailedError) ?? ""
        requestID = try values.decodeIfPresent(String.self, forKey: .requestID) ?? ""
        statusCode = try values.decodeIfPresent(Int.self, forKey: .statusCode) ?? 0
    }

    /// The server's documented MFA challenge id (`POST /users/login` with MFA enabled).
    static let mfaRequiredID = "api.context.mfa_required"
}

// MARK: - Teams (T32)

/// A `TeamUnread` row: `GET /api/v4/users/me/teams/unread`.
///
/// The server sends a dozen counters here (`mention_count_root`, `msg_count_root`, `thread_count`,
/// `thread_mention_count`, `thread_urgent_mention_count`, …). This client renders the two the team
/// rail's badge is defined by — `mention_count` (the number in the badge) and `msg_count` (the dot
/// when there are unread messages but no mentions) — and tolerates the rest being present or absent,
/// so a newer or older server cannot fail the whole rail.
struct MMTeamUnread: Codable, Equatable, Identifiable, Sendable {
    var teamId: String
    var mentionCount: Int
    var msgCount: Int

    var id: String { teamId }

    enum CodingKeys: String, CodingKey {
        case teamId = "team_id"
        case mentionCount = "mention_count"
        case msgCount = "msg_count"
    }

    init(teamId: String = "", mentionCount: Int = 0, msgCount: Int = 0) {
        self.teamId = teamId
        self.mentionCount = mentionCount
        self.msgCount = msgCount
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        teamId = try values.decodeIfPresent(String.self, forKey: .teamId) ?? ""
        mentionCount = try values.decodeIfPresent(Int.self, forKey: .mentionCount) ?? 0
        msgCount = try values.decodeIfPresent(Int.self, forKey: .msgCount) ?? 0
    }
}

/// A `TeamMember` row: `GET /api/v4/users/me/teams/members`.
///
/// The team rail needs the *membership* rather than the team: a soft-deleted membership
/// (`delete_at > 0`) means the user is no longer in that team even though `/users/me/teams` may
/// still list it, and a membership row for somebody else (the endpoint can be asked for other
/// users) must not put a team in this rail. Only those three fields are consumed.
struct MMTeamMembership: Codable, Equatable, Sendable {
    var userId: String
    var teamId: String
    var roles: String
    var deleteAt: Int64

    enum CodingKeys: String, CodingKey {
        case roles
        case userId = "user_id"
        case teamId = "team_id"
        case deleteAt = "delete_at"
    }

    init(userId: String = "", teamId: String = "", roles: String = "", deleteAt: Int64 = 0) {
        self.userId = userId
        self.teamId = teamId
        self.roles = roles
        self.deleteAt = deleteAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        userId = try values.decodeIfPresent(String.self, forKey: .userId) ?? ""
        teamId = try values.decodeIfPresent(String.self, forKey: .teamId) ?? ""
        roles = try values.decodeIfPresent(String.self, forKey: .roles) ?? ""
        deleteAt = try values.decodeIfPresent(Int64.self, forKey: .deleteAt) ?? 0
    }
}

/// One server-side sidebar category (`GET/PUT /users/{user_id}/teams/{team_id}/channels/categories`).
///
/// T33 (S08). This is the v9+ replacement for the old `sidebar_settings` preference blob: the
/// server stores the ordered category list, each category's channel list and its sorting, so a
/// reorder made on one device is what the next device (and the next launch) reads back. The mobile
/// client's write path is `PUT …/channels/categories` with the **whole** array
/// (`app/client/rest/categories.ts` `updateChannelCategories`), which is what
/// `APIClient.updateSidebarCategories` sends.
///
/// Tolerant decoding on purpose: an older server that omits `muted`/`collapsed` must not fail the
/// whole sidebar, and `type` is compared as a string (the three defaults are `favorites`,
/// `channels`, `direct_messages`; user-made ones are `custom`).
struct MMSidebarCategory: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var userId: String
    var teamId: String
    var sortOrder: Int
    /// `"manual"`, `"alpha"`, `"recent"`, or `""` for the server/client default.
    var sorting: String
    var type: String
    var displayName: String
    var muted: Bool
    var collapsed: Bool
    var channelIds: [String]

    enum CodingKeys: String, CodingKey {
        case id, sorting, type, muted, collapsed
        case userId = "user_id"
        case teamId = "team_id"
        case sortOrder = "sort_order"
        case displayName = "display_name"
        case channelIds = "channel_ids"
    }

    init(id: String,
         userId: String = "",
         teamId: String = "",
         sortOrder: Int = 0,
         sorting: String = "",
         type: String = "",
         displayName: String = "",
         muted: Bool = false,
         collapsed: Bool = false,
         channelIds: [String] = []) {
        self.id = id
        self.userId = userId
        self.teamId = teamId
        self.sortOrder = sortOrder
        self.sorting = sorting
        self.type = type
        self.displayName = displayName
        self.muted = muted
        self.collapsed = collapsed
        self.channelIds = channelIds
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? ""
        userId = try values.decodeIfPresent(String.self, forKey: .userId) ?? ""
        teamId = try values.decodeIfPresent(String.self, forKey: .teamId) ?? ""
        sortOrder = try values.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        sorting = try values.decodeIfPresent(String.self, forKey: .sorting) ?? ""
        type = try values.decodeIfPresent(String.self, forKey: .type) ?? ""
        displayName = try values.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        muted = try values.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        collapsed = try values.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        channelIds = try values.decodeIfPresent([String].self, forKey: .channelIds) ?? []
    }
}

/// The categories endpoint's answer: the categories plus the order to draw them in.
///
/// `order` is a list of category **ids**, not the `sort_order` integers: the server keeps both, and
/// the order array is the one the web app and mobile client honour (a `sort_order` of 10/20/30 is
/// the default, `order` is what a drag produces). When `order` is empty/incomplete the remaining
/// categories are appended by `sort_order`, then by id — never dropped.
struct MMSidebarCategories: Codable, Equatable, Sendable {
    var categories: [MMSidebarCategory]
    var order: [String]

    enum CodingKeys: String, CodingKey { case categories, order }

    init(categories: [MMSidebarCategory] = [], order: [String] = []) {
        self.categories = categories
        self.order = order
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        categories = try values.decodeIfPresent([MMSidebarCategory].self, forKey: .categories) ?? []
        order = try values.decodeIfPresent([String].self, forKey: .order) ?? []
    }
}
