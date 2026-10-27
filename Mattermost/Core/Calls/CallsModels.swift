// Behaviour reference: mattermost-plugin-calls `server/websocket.go` + `public/Call.go` (read at the
// installed 0.29.8 build and at the pinned 1.x source), and mattermost/mattermost-mobile v2.45.0
// `app/products/calls/types/calls.ts` (Apache-2.0) for the field set a native client renders. Own
// implementation: the models below are decoded from the measured payloads
// (docs/t44-build-note.md §4.1, docs/t44b-calls-media-path.md), not ported.
//
// These models are pure Foundation: no WebRTC, no UIKit. That is deliberate — the whole call-state
// and SDP-value layer is unit-testable on a machine with no engine, no server and no microphone.

import Foundation

/// One participant session inside a call.
///
/// Measured shape (`call_state.call.sessions[]`): `{session_id, user_id, unmuted, raised_hand}`.
/// A session joins **unmuted: false** (`docs/t44b-calls-media-path.md` §6) — a client that never
/// sends `unmute` still transmits RTP, but the server-side session state says muted, which is what
/// every other participant's UI renders.
struct CallsSession: Equatable, Sendable {
    var sessionID: String
    var userID: String
    var unmuted: Bool
    /// When the hand went up, as **unix milliseconds** — `0` means lowered.
    ///
    /// Measured on the fixture (`call_state` verbatim, T44d): the plugin sends
    /// `"raised_hand": 1793094724582` / `"raised_hand": 0`, not a bool. Decoding that with
    /// `boolValue` (what T44c did) yields `nil` for every real payload, so every hand read as
    /// lowered. The *timestamp* is also the ordering key upstream uses between two raised hands
    /// (`sortSessions`), so it is the model's field and `raisedHand` is derived from it.
    var raisedHandAt: Int64

    /// Whether the hand is up. The wire's "true" is any non-zero timestamp; a bool-shaped payload
    /// (`true`) is stored as `1` by `timestamp(from:)`.
    var raisedHand: Bool { raisedHandAt > 0 }

    init(sessionID: String, userID: String, unmuted: Bool = false, raisedHandAt: Int64 = 0) {
        self.sessionID = sessionID
        self.userID = userID
        self.unmuted = unmuted
        self.raisedHandAt = raisedHandAt
    }

    /// Bool-shaped convenience (tests, and any caller that only knows "raised").
    init(sessionID: String, userID: String, unmuted: Bool = false, raisedHand: Bool) {
        self.init(sessionID: sessionID, userID: userID, unmuted: unmuted,
                  raisedHandAt: raisedHand ? 1 : 0)
    }

    /// `raised_hand` in either of the shapes a Calls build has used: a unix-millisecond number
    /// (`0` = down, measured) or a bool (`true` = up, the shape T44c's fixtures used).
    static func timestamp(from value: JSONValue?) -> Int64 {
        guard let value else { return 0 }
        switch value {
        case .bool(let raised): return raised ? 1 : 0
        case .number(let number): return number > 0 ? Int64(number) : 0
        case .string(let text): return Int64(text).flatMap { $0 > 0 ? $0 : 0 } ?? 0
        default: return 0
        }
    }
}

/// The call itself — the payload a native calls screen renders.
///
/// `call_state` carries it as a **JSON string** under `data.call` (measured). Some proxy paths hand
/// back the object instead, so both shapes are accepted (`fromPayload`).
struct CallsCall: Equatable, Sendable {
    var id: String
    var channelID: String
    var startAt: Int64
    var postID: String
    var threadID: String
    var ownerID: String
    var hostID: String
    var screenSharingSessionID: String
    var sessions: [CallsSession]

    init(id: String = "",
         channelID: String = "",
         startAt: Int64 = 0,
         postID: String = "",
         threadID: String = "",
         ownerID: String = "",
         hostID: String = "",
         screenSharingSessionID: String = "",
         sessions: [CallsSession] = []) {
        self.id = id
        self.channelID = channelID
        self.startAt = startAt
        self.postID = postID
        self.threadID = threadID
        self.ownerID = ownerID
        self.hostID = hostID
        self.screenSharingSessionID = screenSharingSessionID
        self.sessions = sessions
    }

    /// Decode the `call` value: a JSON **string** (measured) or the object itself.
    init(payload: JSONValue, channelID: String = "") throws {
        let object: JSONValue
        switch payload {
        case .string(let text):
            guard let data = text.data(using: .utf8) else {
                throw CallsDecodeError.malformedCallState("call string is not UTF-8")
            }
            object = try JSONDecoder().decode(JSONValue.self, from: data)
        case .null:
            throw CallsDecodeError.malformedCallState("call is null")
        default:
            object = payload
        }
        guard case .object(let fields) = object else {
            throw CallsDecodeError.malformedCallState("call is not a JSON object")
        }
        self.init(id: fields["id"]?.stringValue ?? "",
                  channelID: fields["channel_id"]?.stringValue ?? channelID,
                  startAt: fields["start_at"]?.int64Value ?? 0,
                  postID: fields["post_id"]?.stringValue ?? "",
                  threadID: fields["thread_id"]?.stringValue ?? "",
                  ownerID: fields["owner_id"]?.stringValue ?? "",
                  hostID: fields["host_id"]?.stringValue ?? "",
                  screenSharingSessionID: fields["screen_sharing_session_id"]?.stringValue ?? "",
                  sessions: Self.sessions(from: fields["sessions"]))
    }

    private static func sessions(from raw: JSONValue?) -> [CallsSession] {
        guard case .array(let entries)? = raw else { return [] }
        return entries.compactMap { entry in
            guard case .object(let fields) = entry,
                  let sessionID = fields["session_id"]?.stringValue, !sessionID.isEmpty,
                  let userID = fields["user_id"]?.stringValue, !userID.isEmpty else { return nil }
            return CallsSession(sessionID: sessionID,
                                userID: userID,
                                unmuted: fields["unmuted"]?.boolValue ?? false,
                                raisedHandAt: CallsSession.timestamp(from: fields["raised_hand"]))
        }
    }

    // MARK: - Derived

    /// The session the local user is in, if this payload includes it (it always does for the
    /// caller's own join: the `call_state` that follows `join` lists every session).
    func session(forUser userID: String) -> CallsSession? {
        sessions.first { $0.userID == userID }
    }

    func isUnmuted(userID: String) -> Bool {
        session(forUser: userID)?.unmuted ?? false
    }

    func hasRaisedHand(userID: String) -> Bool {
        session(forUser: userID)?.raisedHand ?? false
    }

    /// Who is sharing their screen, if anyone (`screen_sharing_session_id`), resolved to a user.
    var screenSharingUserID: String? {
        guard !screenSharingSessionID.isEmpty else { return nil }
        return sessions.first { $0.sessionID == screenSharingSessionID }?.userID
    }

    /// The host is not always the owner (host transfer), so it is modelled separately.
    func isHost(userID: String) -> Bool {
        !hostID.isEmpty ? hostID == userID : ownerID == userID
    }
}

/// `call_start` — the call was started while this client was watching the channel.
struct CallsStartedCall: Equatable, Sendable {
    var id: String
    var postID: String
    var threadID: String
    var startAt: Int64
    var ownerID: String
    var hostID: String
}

/// A `{type, sdp}` description, as it travels on the wire.
///
/// Kept free of WebRTC types so the codec and its tests need no framework: the engine converts to
/// and from `RTCSessionDescription` at the boundary.
struct CallsSessionDescription: Equatable, Sendable {
    enum Kind: String, Sendable {
        case offer
        case answer
        case pranswer
        case rollback
    }

    var kind: Kind
    var sdp: String

    init(kind: Kind, sdp: String) {
        self.kind = kind
        self.sdp = sdp
    }

    /// Decode the inner JSON of a `signal` event (`{"type":"answer","sdp":"v=0…"}`).
    init(json: String) throws {
        guard let data = json.data(using: .utf8) else {
            throw CallsDecodeError.malformedSignal("signal description is not UTF-8")
        }
        let object = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(let fields) = object,
              let type = fields["type"]?.stringValue,
              let kind = Kind(rawValue: type) else {
            throw CallsDecodeError.malformedSignal("signal description has no known type")
        }
        guard let sdp = fields["sdp"]?.stringValue, !sdp.isEmpty else {
            throw CallsDecodeError.malformedSignal("signal description has no sdp")
        }
        self.init(kind: kind, sdp: sdp)
    }

    /// The body that goes into `zlib(JSON({type, sdp}))` for the `sdp` action.
    var jsonBody: Data {
        // `JSONEncoder` is what escapes the SDP's CRLFs correctly; the plugin hands the decoded
        // bytes straight to pion, which needs a real JSON string.
        let object: [String: String] = ["type": kind.rawValue, "sdp": sdp]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            return Data("{\"type\":\"\(kind.rawValue)\",\"sdp\":\"\"}".utf8)
        }
        return data
    }
}

/// An ICE candidate in `RTCIceCandidateInit` shape — the value the plugin's `ice` action expects as
/// a JSON **string** under `data.data` (measured: `webapp/src/client.ts` `ws.send('ice', {data:
/// JSON.stringify(candidate)})`, and `server/websocket.go` requires `req.Data["data"]` to be a
/// `string`).
struct CallsIceCandidate: Equatable, Sendable {
    /// `candidate:<foundation> <component> <transport> <priority> <ip> <port> typ host …`.
    var candidate: String
    var sdpMid: String?
    var sdpMLineIndex: Int32?
    var usernameFragment: String?

    init(candidate: String, sdpMid: String? = nil, sdpMLineIndex: Int32? = nil,
         usernameFragment: String? = nil) {
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
        self.usernameFragment = usernameFragment
    }

    /// Decode the `candidate` object inside a `signal` event.
    init?(payload: JSONValue) {
        guard case .object(let fields) = payload,
              let text = fields["candidate"]?.stringValue, !text.isEmpty else { return nil }
        self.init(candidate: text,
                  sdpMid: fields["sdpMid"]?.stringValue,
                  sdpMLineIndex: fields["sdpMLineIndex"]?.intValue.map(Int32.init),
                  usernameFragment: fields["usernameFragment"]?.stringValue)
    }

    /// The exact JSON the `ice` action carries.
    var jsonString: String {
        var object: [String: Any] = ["candidate": candidate]
        if let sdpMid { object["sdpMid"] = sdpMid }
        if let sdpMLineIndex { object["sdpMLineIndex"] = Int(sdpMLineIndex) }
        if let usernameFragment { object["usernameFragment"] = usernameFragment }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The candidate's address and port, for logs and diagnostics (never for routing decisions).
    var hostAndPort: String? {
        let parts = candidate.split(separator: " ")
        guard parts.count >= 6 else { return nil }
        return "\(parts[4]):\(parts[5])/\(parts[2])"
    }
}

enum CallsDecodeError: Error, Equatable, CustomStringConvertible {
    case malformedCallState(String)
    case malformedSignal(String)
    case malformedEvent(String)

    var description: String {
        switch self {
        case .malformedCallState(let why): return "call state: \(why)"
        case .malformedSignal(let why): return "signal: \(why)"
        case .malformedEvent(let why): return "event: \(why)"
        }
    }
}
