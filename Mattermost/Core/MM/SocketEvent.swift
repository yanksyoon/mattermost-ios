// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0,
// `app/client/websocket/index.ts` (authentication_challenge on open, 30 s ping with a missed-pong
// timeout, sequence tracking, hello handling, reconnect after close) and
// `app/constants/websocket.ts` (event names). Own implementation per docs/path-b-adr.md §3 — the
// upstream client is a class wired to a singleton native socket registry; this one is an actor
// with an injected transport, clock and backoff, so reconnect and resync are testable without a
// network.
//
// Documented divergences (docs/t28-build-note.md §5):
//  - backoff is exponential with jitter (`Backoff`), where mobile uses a linear ladder
//    (`min(3s * failCount, 5min)` after 7 failures);
//  - reconnect resync is an injected closure (the caller refetches changed state), where mobile
//    calls a global sync routine;
//  - duplicate suppression across a reconnect is explicit and narrow (`SocketEvent.dedupeKey`:
//    post/user revisions and hello only), where mobile relies on the server replaying nothing for
//    non-reliable sockets. Events whose occurrence is itself the signal are never suppressed.

import Foundation

/// What a socket transport reports upward. Deliberately tiny: the client owns all protocol logic,
/// the transport owns the socket.
enum SocketTransportEvent: Equatable, Sendable {
    case opened
    case text(String)
    case closed(code: Int, reason: String?)
    case failed(String)
}

/// The WebSocket seam. `WebSocketTransport` is the `URLSessionWebSocketTask` implementation;
/// tests use a scripted fake.
protocol SocketTransport: AnyObject {
    var events: AsyncStream<SocketTransportEvent> { get }
    func resume()
    func send(text: String) async throws
    /// The binary path. It **must** be a protocol requirement, not only an extension method:
    /// `SocketClient` holds its transport as `SocketTransport?`, so a member that exists solely in
    /// an extension is statically dispatched and the default below would run for *every* conformer —
    /// including `WebSocketTransport`, whose implementation would never be reached (this is exactly
    /// the live `offer: binaryFramesUnsupported` failure T44d found). The throwing body stays as a
    /// default so a text-only test fake does not have to implement it.
    func send(data: Data) async throws
    func close()
}

/// The timing seam: reconnect backoff and the heartbeat both sleep through it, so tests run on a
/// deterministic clock instead of wall time.
protocol SocketClock: Sendable {
    func sleep(for seconds: TimeInterval) async
}

struct SystemSocketClock: SocketClock {
    func sleep(for seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// A binary frame could not be sent.
///
/// Failure is deliberately loud: the Calls `sdp` action exists **only** on the binary path (the
/// plugin drops a JSON-framed SDP — `docs/t44-build-note.md` §5.1), so a transport that silently
/// downgraded a binary frame to text would turn "call cannot start" into "call looks like it started
/// and then times out at 10 s". A transport that does not implement `send(data:)` gets this error.
enum SocketTransportError: Error, Equatable {
    case binaryFramesUnsupported
    case notConnected
}

extension SocketTransport {
    /// The binary send path. `WebSocketTransport` implements it with
    /// `URLSessionWebSocketTask.send(.data:)`; a test fake overrides it to record frames. The default
    /// is a hard failure rather than a silent text downgrade.
    func send(data: Data) async throws {
        throw SocketTransportError.binaryFramesUnsupported
    }
}

// MARK: - Protocol frames

/// A WebSocket v4 frame. Server events carry `event` + `seq` + `data`; replies to our own actions
/// carry `seq_reply` and `status` instead of `event`.
struct MMSocketFrame: Decodable, Equatable, Sendable {
    var event: String
    var seq: Int?
    var seqReply: Int?
    var status: String?
    var errorMessage: String?
    var data: MMRawJSON?
    /// The frame's routing envelope (T33-R). Most sidebar-relevant events carry the facts the client
    /// needs *only* here: `post_unread` names its channel in `broadcast.channel_id` and nothing in
    /// `data`, and `channel_deleted` only names its team in `broadcast.team_id`. Measured against the
    /// pinned 9.11.19 server (see docs/t33r-build-note.md §2).
    var broadcast: MMSocketBroadcast?

    private enum Keys: String, CodingKey {
        case event, seq, status, data, error, broadcast
    }

    private enum ExtraKeys: String, CodingKey {
        case seqReply = "seq_reply"
    }

    private struct ErrorPayload: Decodable {
        var message: String
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        event = try values.decodeIfPresent(String.self, forKey: .event) ?? ""
        seq = try values.decodeIfPresent(Int.self, forKey: .seq)
        status = try values.decodeIfPresent(String.self, forKey: .status)
        data = try values.decodeIfPresent(MMRawJSON.self, forKey: .data)
        broadcast = try values.decodeIfPresent(MMSocketBroadcast.self, forKey: .broadcast)
        let extra = try decoder.container(keyedBy: ExtraKeys.self)
        seqReply = try extra.decodeIfPresent(Int.self, forKey: .seqReply)
        if let payload = try? values.decodeIfPresent(ErrorPayload.self, forKey: .error) {
            errorMessage = payload.message
        }
    }
}

/// Who a frame was routed to (`broadcast` in the v4 envelope).
///
/// Only the three routing ids are typed: the envelope's `omit_users` / `connection_id` are the
/// server's business, and nothing in this client acts on them.
struct MMSocketBroadcast: Decodable, Equatable, Sendable {
    var userID: String
    var channelID: String
    var teamID: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case channelID = "channel_id"
        case teamID = "team_id"
    }

    init(userID: String = "", channelID: String = "", teamID: String = "") {
        self.userID = userID
        self.channelID = channelID
        self.teamID = teamID
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        userID = try values.decodeIfPresent(String.self, forKey: .userID) ?? ""
        channelID = try values.decodeIfPresent(String.self, forKey: .channelID) ?? ""
        teamID = try values.decodeIfPresent(String.self, forKey: .teamID) ?? ""
    }
}

// MARK: - Typed events

struct SocketHello: Equatable, Sendable {
    var connectionID: String
    var serverVersion: String
}

struct SocketTyping: Equatable, Sendable {
    var channelID: String
    var parentID: String
    var userID: String
}

struct SocketStatusChange: Equatable, Sendable {
    var userID: String
    var status: String
}

struct SocketChannelViewed: Equatable, Sendable {
    var channelID: String
    var userID: String
}

/// `sidebar_category_updated` — the server stored somebody's categories write (mine, or my own from
/// another client) and hands back the layout it kept.
///
/// The payload is a **JSON string** under `data.updatedCategories` (measured on the pinned 9.11.19
/// server, T33-R §2), the same escaping `posted` uses for its post. The event is team-scoped: the
/// categories themselves carry `team_id`, so an empty `broadcast` still attributes correctly.
struct SocketSidebarCategoryUpdate: Equatable, Sendable {
    var teamID: String
    var categories: [MMSidebarCategory]
}

/// `channel_created` / `channel_deleted` — a channel of a team appearing or leaving the sidebar.
struct SocketChannelEvent: Equatable, Sendable {
    var channelID: String
    var teamID: String
    /// `0` for `channel_created`; the server's archive timestamp for `channel_deleted`.
    var deleteAt: Int64 = 0
}

/// `channel_member_updated` — one membership row changed (a mute, a notify prop, "keep as unread").
///
/// The server sends the whole row as a JSON string under `data.channelMember`, addressed to the
/// member's own user id; there is no channel or team in the envelope. My own mute set from another
/// client arrives exactly here, which is what makes two clients agree on "muted".
struct SocketChannelMemberUpdate: Equatable, Sendable {
    var member: MMChannelMember
    var channelID: String { member.channelId }
    var userID: String { member.userId }
}

/// `user_added` / `user_removed` — somebody joined or was removed from a channel (T40).
///
/// Measured on the pinned 9.11.19 server (`docs/t40-build-note.md` §2): `data` is
/// `{team_id, user_id}` for an add and `{remover_id, user_id}` for a removal, and the **channel** is in
/// the envelope (`broadcast.channel_id`) rather than in `data`. The add carries
/// `broadcast.omit_users = {<added user>: true}`, i.e. the person added does not receive their own
/// event — which is why the app must not rely on the event alone to learn about its own membership.
struct SocketMembershipChange: Equatable, Sendable {
    var channelID: String
    var teamID: String
    /// The person who joined or was removed.
    var userID: String
    /// `user_removed` names who performed the removal; empty for an add (and for a stripped frame).
    var removerID: String

    init(channelID: String = "", teamID: String = "", userID: String = "", removerID: String = "") {
        self.channelID = channelID
        self.teamID = teamID
        self.userID = userID
        self.removerID = removerID
    }
}

/// `multiple_channels_viewed` — "this user read these channels", the event the **view** call answers
/// with.
///
/// `POST /channels/members/{uid}/view` publishes this frame (plus `thread_read_changed`), **not**
/// `post_unread`: `data.channel_times` is a `{channel_id: last_viewed_at_ms}` map and the envelope
/// names neither a channel nor a team (`broadcast.user_id` = me, `channel_id`/`team_id` empty).
/// Measured on the pinned 9.11.19 server (docs/t33r2-build-note.md §2). The server publishes it only
/// when the view actually moved the read cursor, so a second view of a read channel emits nothing.
///
/// This is the reason a channel read in *another* client of mine clears its row here without a
/// relaunch (T33-AV2 F1): before this event was typed, the row kept its `Unread` badge until some
/// unrelated refresh recomputed the counters.
struct SocketMultipleChannelsViewed: Equatable, Sendable {
    /// The user whose read state moved (`broadcast.user_id`). Empty only on a stripped frame.
    var userID: String
    /// channel id → the server's `last_viewed_at` (ms). Never empty: a frame without the map is dropped.
    var channelTimes: [String: Int64]

    /// The channels this frame says are read, in a stable order (for tests and diagnostics).
    var channelIDs: [String] { channelTimes.keys.sorted() }
}

/// `post_unread` — the server's own unread arithmetic for one channel, sent to **me** when a post is
/// **marked unread**.
///
/// The trigger is `POST /users/{uid}/posts/{pid}/set_unread` (mattermost's `Client4.SetPostUnread`,
/// MM-17754) — *not* a view: reading a channel answers with `multiple_channels_viewed` instead
/// (measured on the pinned 9.11.19 server, docs/t33r2-build-note.md §2; the earlier "I viewed the
/// channel, or marked it unread" claim here was wrong).
///
/// The channel and team are only in the envelope (`broadcast.channel_id` / `.team_id`); `data` carries
/// the counters. Applying these is exact — no follow-up request is needed, and the number cannot
/// drift the way a local increment would.
struct SocketPostUnread: Equatable, Sendable {
    var channelID: String
    var teamID: String
    var msgCount: Int64
    var mentionCount: Int64
    var lastViewedAt: Int64
}

/// `thread_follow_changed` — a follow write landed, mine or (on another of my clients) my own.
///
/// Measured on the pinned 9.11.19 server (`scripts/t36_thread_probe.py`): `data` is
/// `{thread_id, state, reply_count}` and the envelope carries `broadcast.user_id` (me) and
/// `broadcast.team_id`. The event is what makes a follow pressed on one device appear on the other
/// without a refetch.
struct SocketThreadFollowChanged: Equatable, Sendable {
    var threadID: String
    var state: Bool
    var replyCount: Int
}

/// `thread_read_changed` — my read position in a thread moved (a `read` or `set_unread` write).
///
/// Measured: `data` is `{channel_id, thread_id, timestamp, unread_replies, unread_mentions,
/// previous_unread_replies, previous_unread_mentions}`. An **empty** `thread_id` means the whole
/// team's threads were marked read (`PUT …/threads/read`), which is why the id is not required.
struct SocketThreadReadChanged: Equatable, Sendable {
    var threadID: String
    var channelID: String
    /// The thread's new `last_viewed_at` (ms).
    var timestamp: Int64
    var unreadReplies: Int
    var unreadMentions: Int
    var previousUnreadReplies: Int
    var previousUnreadMentions: Int
}

/// `thread_updated` — the server recomputed a thread I follow (a new reply, an edit, a delete).
///
/// Measured: `data` is `{thread, previous_unread_replies, previous_unread_mentions}` where `thread`
/// is a **JSON string** (the same escaping `posted` uses for its post), and the envelope carries
/// `broadcast.team_id`. It is delivered only to followers, which is why applying it also means
/// "I follow this thread" (upstream `handleThreadUpdatedEvent` sets `is_following = true`).
struct SocketThreadUpdated: Equatable, Sendable {
    var thread: MMThread
    var previousUnreadReplies: Int
    var previousUnreadMentions: Int
}

/// The events the native client consumes, typed. `unhandled` keeps forward compatibility: a
/// newer server introducing an event must not break the stream.
enum SocketEvent: Equatable, Sendable {
    case hello(SocketHello)
    case posted(MMPost)
    case postEdited(MMPost)
    case postDeleted(MMPost)
    case channelViewed(SocketChannelViewed)
    /// My read state for one or more channels moved, as the **view** call reports it
    /// (`multiple_channels_viewed`).
    case multipleChannelsViewed(SocketMultipleChannelsViewed)
    case typing(SocketTyping)
    case statusChange(SocketStatusChange)
    case preferencesChanged([MMPreference])
    case userUpdated(MMUser)
    case reactionAdded(MMReaction)
    case reactionRemoved(MMReaction)
    /// The sidebar layout somebody wrote (`sidebar_category_updated`).
    case sidebarCategoryUpdated(SocketSidebarCategoryUpdate)
    /// A channel of a team appeared (`channel_created`).
    case channelCreated(SocketChannelEvent)
    /// A channel of a team was archived (`channel_deleted`).
    case channelDeleted(SocketChannelEvent)
    /// A channel's own fields changed — a rename, a purpose or a header edit, an archive
    /// (`channel_updated`). The payload is the whole channel as a **JSON string** under `data.channel`
    /// (measured, T40 §2), the same escaping `posted` uses for its post.
    case channelUpdated(MMChannel)
    /// An archived channel was restored (`channel_restored`). The payload names only the channel id, so
    /// the channel itself has to be re-read rather than guessed from the frame.
    case channelRestored(SocketChannelEvent)
    /// Somebody joined a channel (`user_added`) — T40's member list and its count.
    case userAdded(SocketMembershipChange)
    /// Somebody left or was removed from a channel (`user_removed`).
    case userRemoved(SocketMembershipChange)
    /// A membership row changed — mine, when another client mutes or marks a channel.
    case channelMemberUpdated(SocketChannelMemberUpdate)
    /// The server's unread counters for one channel of mine moved (`post_unread`).
    case postUnread(SocketPostUnread)
    /// A thread I follow was recomputed (`thread_updated`).
    case threadUpdated(SocketThreadUpdated)
    /// A thread follow write landed, from this device or another of mine (`thread_follow_changed`).
    case threadFollowChanged(SocketThreadFollowChanged)
    /// My read position in a thread (or in the whole team's threads) moved (`thread_read_changed`).
    case threadReadChanged(SocketThreadReadChanged)
    /// A **plugin** frame (`custom_<plugin id>_<event>`), carried with its payload intact.
    ///
    /// The core socket hands every plugin-prefixed frame to the plugin and publishes plugin events
    /// with the same prefix, so a plugin's protocol is a sub-protocol of this socket — not a second
    /// connection. Calls is the first consumer (`docs/t44-build-note.md` §4.1): its `signal`,
    /// `call_state` and `user_*` events all arrive here and are decoded by `CallsEvent(frame:)`.
    ///
    /// The payload is kept raw on purpose. A typed case per plugin would put the plugin's model in
    /// the core socket; this way the socket stays a transport and the *plugin* owns its decode.
    case plugin(name: String, data: MMRawJSON)
    /// An event this build does not model (still delivered, still counted).
    case unhandled(name: String)

    /// Decode a frame into a typed event. Returns `nil` when the frame is a reply, or when the
    /// payload cannot be decoded (a malformed event is dropped, never surfaced as a wrong model).
    init?(frame: MMSocketFrame) {
        guard frame.seqReply == nil else { return nil }
        let name = frame.event
        switch name {
        case "hello":
            self = .hello(SocketHello(
                connectionID: frame.data?["connection_id"]?.stringValue ?? "",
                serverVersion: frame.data?["server_version"]?.stringValue ?? ""))
        case "posted":
            guard let post = Self.post(from: frame.data) else { return nil }
            self = .posted(post)
        case "post_edited":
            guard let post = Self.post(from: frame.data) else { return nil }
            self = .postEdited(post)
        case "post_deleted":
            guard let post = Self.post(from: frame.data) else { return nil }
            self = .postDeleted(post)
        case "channel_viewed":
            self = .channelViewed(SocketChannelViewed(
                channelID: frame.data?["channel_id"]?.stringValue ?? "",
                userID: frame.data?["user_id"]?.stringValue ?? ""))
        case "multiple_channels_viewed":
            // The view call's event: `data.channel_times` is the map, and the envelope names no
            // channel and no team — only the user whose read state moved.
            var channelTimes: [String: Int64] = [:]
            for (channelID, raw) in frame.data?["channel_times"]?.objectValue ?? [:] {
                guard !channelID.isEmpty, let viewedAt = raw.int64Value else { continue }
                channelTimes[channelID] = viewedAt
            }
            guard !channelTimes.isEmpty else { return nil }
            self = .multipleChannelsViewed(SocketMultipleChannelsViewed(
                userID: frame.broadcast?.userID ?? "",
                channelTimes: channelTimes))
        case "typing":
            self = .typing(SocketTyping(
                channelID: frame.data?["channel_id"]?.stringValue ?? "",
                parentID: frame.data?["parent_id"]?.stringValue ?? "",
                userID: frame.data?["user_id"]?.stringValue ?? ""))
        case "status_change":
            self = .statusChange(SocketStatusChange(
                userID: frame.data?["user_id"]?.stringValue ?? "",
                status: frame.data?["status"]?.stringValue ?? ""))
        case "preferences_changed":
            guard let raw = frame.data?["preferences"], let value = raw.arrayValue else { return nil }
            let preferences = value.compactMap { try? MMRawJSON($0).decode(MMPreference.self) }
            self = .preferencesChanged(preferences)
        case "user_updated":
            guard let raw = frame.data?["user"],
                  let user = try? MMRawJSON(raw).decode(MMUser.self) else { return nil }
            self = .userUpdated(user)
        case "reaction_added":
            guard let reaction = Self.reaction(from: frame.data) else { return nil }
            self = .reactionAdded(reaction)
        case "reaction_removed":
            guard let reaction = Self.reaction(from: frame.data) else { return nil }
            self = .reactionRemoved(reaction)
        case "sidebar_category_updated":
            guard let categories = Self.categories(from: frame.data?["updatedCategories"]),
                  !categories.isEmpty else { return nil }
            self = .sidebarCategoryUpdated(SocketSidebarCategoryUpdate(
                teamID: frame.broadcast?.teamID ?? categories.first?.teamId ?? "",
                categories: categories))
        case "channel_created":
            guard let channelID = frame.data?["channel_id"]?.stringValue
                    ?? frame.broadcast?.channelID, !channelID.isEmpty else { return nil }
            self = .channelCreated(SocketChannelEvent(
                channelID: channelID,
                teamID: frame.data?["team_id"]?.stringValue ?? frame.broadcast?.teamID ?? ""))
        case "channel_deleted":
            guard let channelID = frame.data?["channel_id"]?.stringValue
                    ?? frame.broadcast?.channelID, !channelID.isEmpty else { return nil }
            self = .channelDeleted(SocketChannelEvent(
                channelID: channelID,
                teamID: frame.data?["team_id"]?.stringValue ?? frame.broadcast?.teamID ?? "",
                deleteAt: frame.data?["delete_at"]?.int64Value ?? 0))
        case "channel_member_updated":
            guard let raw = frame.data?["channelMember"],
                  let member = try? Self.jsonStringOrObject(raw).decode(MMChannelMember.self),
                  !member.channelId.isEmpty else { return nil }
            self = .channelMemberUpdated(SocketChannelMemberUpdate(member: member))
        case "channel_updated":
            // `data.channel` is a JSON **string** (measured on 9.11.19, T40 §2).
            guard let raw = frame.data?["channel"],
                  let channel = try? Self.jsonStringOrObject(raw).decode(MMChannel.self),
                  !channel.id.isEmpty else { return nil }
            self = .channelUpdated(channel)
        case "channel_restored":
            // Only the id is in the payload; the team is in the envelope.
            guard let channelID = frame.data?["channel_id"]?.stringValue
                    ?? frame.broadcast?.channelID, !channelID.isEmpty else { return nil }
            self = .channelRestored(SocketChannelEvent(channelID: channelID,
                                                       teamID: frame.broadcast?.teamID ?? ""))
        case "user_added":
            // The channel lives only in the envelope; `data` carries `team_id` and `user_id`.
            guard let channelID = frame.broadcast?.channelID,
                  let userID = frame.data?["user_id"]?.stringValue,
                  !channelID.isEmpty, !userID.isEmpty else { return nil }
            self = .userAdded(SocketMembershipChange(channelID: channelID,
                                                     teamID: frame.data?["team_id"]?.stringValue
                                                        ?? frame.broadcast?.teamID ?? "",
                                                     userID: userID))
        case "user_removed":
            guard let channelID = frame.broadcast?.channelID,
                  let userID = frame.data?["user_id"]?.stringValue,
                  !channelID.isEmpty, !userID.isEmpty else { return nil }
            self = .userRemoved(SocketMembershipChange(channelID: channelID,
                                                       teamID: frame.broadcast?.teamID ?? "",
                                                       userID: userID,
                                                       removerID: frame.data?["remover_id"]?.stringValue
                                                        ?? ""))
        case "post_unread":
            // The channel and team live only in the envelope (`broadcast`), never in `data`.
            guard let channelID = frame.broadcast?.channelID, !channelID.isEmpty else { return nil }
            self = .postUnread(SocketPostUnread(
                channelID: channelID,
                teamID: frame.broadcast?.teamID ?? "",
                msgCount: frame.data?["msg_count"]?.int64Value ?? 0,
                mentionCount: frame.data?["mention_count"]?.int64Value ?? 0,
                lastViewedAt: frame.data?["last_viewed_at"]?.int64Value ?? 0))
        case "thread_updated":
            // `data.thread` is a JSON **string** (measured); some proxies relay the object itself.
            guard let raw = frame.data?["thread"],
                  let thread = try? Self.jsonStringOrObject(raw).decode(MMThread.self),
                  !thread.id.isEmpty else { return nil }
            self = .threadUpdated(SocketThreadUpdated(
                thread: thread,
                previousUnreadReplies: frame.data?["previous_unread_replies"]?.intValue ?? 0,
                previousUnreadMentions: frame.data?["previous_unread_mentions"]?.intValue ?? 0))
        case "thread_follow_changed":
            guard let threadID = frame.data?["thread_id"]?.stringValue, !threadID.isEmpty else {
                return nil
            }
            self = .threadFollowChanged(SocketThreadFollowChanged(
                threadID: threadID,
                state: frame.data?["state"]?.boolValue ?? false,
                replyCount: frame.data?["reply_count"]?.intValue ?? 0))
        case "thread_read_changed":
            // An empty `thread_id` is the "whole team marked read" form, so only the frame's own
            // presence is required — never the id.
            guard let data = frame.data, data["timestamp"] != nil else { return nil }
            self = .threadReadChanged(SocketThreadReadChanged(
                threadID: data["thread_id"]?.stringValue ?? "",
                channelID: data["channel_id"]?.stringValue ?? "",
                timestamp: data["timestamp"]?.int64Value ?? 0,
                unreadReplies: data["unread_replies"]?.intValue ?? 0,
                unreadMentions: data["unread_mentions"]?.intValue ?? 0,
                previousUnreadReplies: data["previous_unread_replies"]?.intValue ?? 0,
                previousUnreadMentions: data["previous_unread_mentions"]?.intValue ?? 0))
        default:
            // Plugin frames keep their payload: `custom_<plugin id>_<event>` is a sub-protocol of
            // this socket (T44c), and dropping the payload here would make it indistinguishable from
            // an event this build simply does not know.
            if name.hasPrefix("custom_") {
                self = .plugin(name: name, data: frame.data ?? MMRawJSON(.null))
            } else {
                self = .unhandled(name: name)
            }
        }
    }

    /// A payload that may be a JSON **string** (the escaping `posted`/`reaction_added`/`category`
    /// events use) or the object/array itself (some proxies and newer builds).
    private static func jsonStringOrObject(_ raw: JSONValue) -> MMRawJSON {
        if let text = raw.stringValue, let data = text.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) {
            return MMRawJSON(decoded)
        }
        return MMRawJSON(raw)
    }

    /// `data.updatedCategories` → the categories the server keeps.
    private static func categories(from raw: JSONValue?) -> [MMSidebarCategory]? {
        guard let raw else { return nil }
        return try? jsonStringOrObject(raw).decode([MMSidebarCategory].self)
    }

    /// Mattermost sends `data.post` / `data.reaction` as a **JSON string**; newer server builds
    /// and some proxies send the object directly. Both shapes are accepted.
    private static func post(from data: MMRawJSON?) -> MMPost? {
        guard let raw = data?["post"] else { return nil }
        switch raw {
        case .string(let text):
            return try? JSONDecoder().decode(MMPost.self, from: Data(text.utf8))
        default:
            return try? MMRawJSON(raw).decode(MMPost.self)
        }
    }

    private static func reaction(from data: MMRawJSON?) -> MMReaction? {
        guard let raw = data?["reaction"] else { return nil }
        let decoded: MMReaction?
        switch raw {
        case .string(let text):
            decoded = try? JSONDecoder().decode(MMReaction.self, from: Data(text.utf8))
        default:
            decoded = try? MMRawJSON(raw).decode(MMReaction.self)
        }
        guard var reaction = decoded else { return nil }
        // 9.11.19 puts `channel_id` *inside* the reaction payload (measured, `av-ws-watch.log`), which
        // is what lets the scope attribute the event to a team (T37-R F1). A frame that names the
        // channel only in the envelope still gets it, so a proxy that strips one form is not a
        // silently unroutable event.
        if reaction.channelId.isEmpty {
            reaction.channelId = data?["channel_id"]?.stringValue ?? ""
        }
        return reaction
    }

    /// The event name as the server spelled it (for diagnostics and `unhandled`).
    var name: String {
        switch self {
        case .hello: return "hello"
        case .posted: return "posted"
        case .postEdited: return "post_edited"
        case .postDeleted: return "post_deleted"
        case .channelViewed: return "channel_viewed"
        case .multipleChannelsViewed: return "multiple_channels_viewed"
        case .typing: return "typing"
        case .statusChange: return "status_change"
        case .preferencesChanged: return "preferences_changed"
        case .userUpdated: return "user_updated"
        case .reactionAdded: return "reaction_added"
        case .reactionRemoved: return "reaction_removed"
        case .sidebarCategoryUpdated: return "sidebar_category_updated"
        case .channelCreated: return "channel_created"
        case .channelDeleted: return "channel_deleted"
        case .channelUpdated: return "channel_updated"
        case .channelRestored: return "channel_restored"
        case .userAdded: return "user_added"
        case .userRemoved: return "user_removed"
        case .channelMemberUpdated: return "channel_member_updated"
        case .postUnread: return "post_unread"
        case .threadUpdated: return "thread_updated"
        case .threadFollowChanged: return "thread_follow_changed"
        case .threadReadChanged: return "thread_read_changed"
        case .plugin(let name, _): return name
        case .unhandled(let name): return name
        }
    }

    /// A stable identity for replay suppression **across a reconnect** — and only for identities
    /// that cannot legitimately recur: a post revision (`id` + `update_at` + `delete_at`), a user
    /// revision (`id` + `update_at`), and a `hello` (once per connection id).
    ///
    /// Everything whose *occurrence* is the signal is deliberately un-keyed: `typing` (transient),
    /// `channel_viewed` (the same user can view the same channel twice), `multiple_channels_viewed`
    /// (the same view can legitimately repeat for the same channel), `status_change`
    /// (away → away is a real event), `preferences_changed`, and reactions (add → remove → add is
    /// three real events). Content-hashing those over a global window silently swallowed genuine
    /// events (T28-AV finding F3). The residual risk — a server replaying one of them after a
    /// reconnect — costs a redundant UI refresh instead of a lost event, which is the right trade.
    var dedupeKey: String? {
        switch self {
        case .hello(let hello):
            return "hello|\(hello.connectionID)|\(hello.serverVersion)"
        case .posted(let post), .postEdited(let post), .postDeleted(let post):
            return "\(name)|\(post.id)|\(post.updateAt)|\(post.deleteAt)"
        case .userUpdated(let user):
            return "user_updated|\(user.id)|\(user.updateAt)"
        case .typing, .channelViewed, .multipleChannelsViewed, .statusChange, .preferencesChanged,
             .reactionAdded, .reactionRemoved, .sidebarCategoryUpdated,
             .channelCreated, .channelDeleted, .channelUpdated, .channelRestored,
             .userAdded, .userRemoved, .channelMemberUpdated, .postUnread,
             .threadUpdated, .threadFollowChanged, .threadReadChanged,
             .plugin, .unhandled:
            return nil
        }
    }
}
