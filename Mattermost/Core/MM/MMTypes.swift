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

    enum CodingKeys: String, CodingKey {
        case id, name, type, header, purpose
        case displayName = "display_name"
        case teamId = "team_id"
        case lastPostAt = "last_post_at"
        case totalMsgCount = "total_msg_count"
    }

    init(id: String,
         name: String = "",
         displayName: String = "",
         type: String = "",
         teamId: String = "",
         header: String = "",
         purpose: String = "",
         lastPostAt: Int64 = 0,
         totalMsgCount: Int64 = 0) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.type = type
        self.teamId = teamId
        self.header = header
        self.purpose = purpose
        self.lastPostAt = lastPostAt
        self.totalMsgCount = totalMsgCount
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
struct MMReaction: Codable, Equatable, Sendable {
    var userId: String
    var postId: String
    var emojiName: String
    var createAt: Int64

    enum CodingKeys: String, CodingKey {
        case createAt = "create_at"
        case userId = "user_id"
        case postId = "post_id"
        case emojiName = "emoji_name"
    }

    init(userId: String = "", postId: String = "", emojiName: String = "", createAt: Int64 = 0) {
        self.userId = userId
        self.postId = postId
        self.emojiName = emojiName
        self.createAt = createAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        userId = try values.decodeIfPresent(String.self, forKey: .userId) ?? ""
        postId = try values.decodeIfPresent(String.self, forKey: .postId) ?? ""
        emojiName = try values.decodeIfPresent(String.self, forKey: .emojiName) ?? ""
        createAt = try values.decodeIfPresent(Int64.self, forKey: .createAt) ?? 0
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
