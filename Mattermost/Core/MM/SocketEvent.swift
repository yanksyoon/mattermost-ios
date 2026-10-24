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

    private enum Keys: String, CodingKey {
        case event, seq, status, data, error
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
        let extra = try decoder.container(keyedBy: ExtraKeys.self)
        seqReply = try extra.decodeIfPresent(Int.self, forKey: .seqReply)
        if let payload = try? values.decodeIfPresent(ErrorPayload.self, forKey: .error) {
            errorMessage = payload.message
        }
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

/// The events the native client consumes, typed. `unhandled` keeps forward compatibility: a
/// newer server introducing an event must not break the stream.
enum SocketEvent: Equatable, Sendable {
    case hello(SocketHello)
    case posted(MMPost)
    case postEdited(MMPost)
    case postDeleted(MMPost)
    case channelViewed(SocketChannelViewed)
    case typing(SocketTyping)
    case statusChange(SocketStatusChange)
    case preferencesChanged([MMPreference])
    case userUpdated(MMUser)
    case reactionAdded(MMReaction)
    case reactionRemoved(MMReaction)
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
        default:
            self = .unhandled(name: name)
        }
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
        switch raw {
        case .string(let text):
            return try? JSONDecoder().decode(MMReaction.self, from: Data(text.utf8))
        default:
            return try? MMRawJSON(raw).decode(MMReaction.self)
        }
    }

    /// The event name as the server spelled it (for diagnostics and `unhandled`).
    var name: String {
        switch self {
        case .hello: return "hello"
        case .posted: return "posted"
        case .postEdited: return "post_edited"
        case .postDeleted: return "post_deleted"
        case .channelViewed: return "channel_viewed"
        case .typing: return "typing"
        case .statusChange: return "status_change"
        case .preferencesChanged: return "preferences_changed"
        case .userUpdated: return "user_updated"
        case .reactionAdded: return "reaction_added"
        case .reactionRemoved: return "reaction_removed"
        case .unhandled(let name): return name
        }
    }

    /// A stable identity for replay suppression **across a reconnect** — and only for identities
    /// that cannot legitimately recur: a post revision (`id` + `update_at` + `delete_at`), a user
    /// revision (`id` + `update_at`), and a `hello` (once per connection id).
    ///
    /// Everything whose *occurrence* is the signal is deliberately un-keyed: `typing` (transient),
    /// `channel_viewed` (the same user can view the same channel twice), `status_change`
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
        case .typing, .channelViewed, .statusChange, .preferencesChanged,
             .reactionAdded, .reactionRemoved, .unhandled:
            return nil
        }
    }
}
