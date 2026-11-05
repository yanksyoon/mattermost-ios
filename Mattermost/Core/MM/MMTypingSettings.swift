// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/components/post_draft/post_input/index.ts (the composer reads EnableUserTypingMessages +
//        TimeBetweenUserTypingUpdatesMilliseconds out of the server config and hands them to
//        post_input), app/components/post_draft/post_input/post_input.tsx:271-279 (the send gate:
//        a non-empty value, the interval since the last frame, and the server's switch),
//        app/actions/websocket/users.ts:91-127 (the receive side re-arms a
//        TimeBetweenUserTypingUpdatesMilliseconds timer per frame, and the client answers
//        `client?.sendUserTypingEvent(channelId, rootId)`).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §24; no
// upstream source copied.
//
// Measured on the pinned 9.11.19 fixture (`scripts/t4f_typing_probe.py`): an **authenticated**
// `GET /api/v4/config/client?format=old` carries
//
//     EnableUserTypingMessages = 'true'
//     TimeBetweenUserTypingUpdatesMilliseconds = '5000'
//     MaxNotificationsPerChannel = '1000'
//
// as *strings*, so the decoder below accepts string, number and bool spellings. The same probe
// measured the `typing` frame: `broadcast.channel_id` names the channel, `data.user_id` the typist,
// `data.parent_id` the thread root (`""` for a channel message), and the sender is **omitted** from
// its own broadcast (`broadcast.omit_users` carries the typist's id) — so a client never has to guess
// whether "you are typing" means itself.

import Foundation

/// The slice of the server's client config the typing indicator reads.
///
/// The defaults are the server's own documented defaults (config.go: `EnableUserTypingMessages: true`,
/// `TimeBetweenUserTypingUpdatesMilliseconds: 5000`, `MaxNotificationsPerChannel: 1000`). They are
/// used **only** where a key is absent from the answer — a server that answers at all always says
/// yes or no explicitly, and a server that cannot be asked leaves the feature silent (see
/// `ComposerTypingPolicy`), so a default is never a substitute for the server's answer.
struct MMTypingSettings: Equatable, Sendable {
    /// `EnableUserTypingMessages` — the server's switch. Off means the composer sends nothing.
    var isEnabled: Bool
    /// `TimeBetweenUserTypingUpdatesMilliseconds`, in seconds. Upstream uses it twice: as the send
    /// throttle and as the window a received frame stays on screen.
    var interval: TimeInterval
    /// `MaxNotificationsPerChannel` — upstream's third send gate
    /// (`membersInChannel < maxNotificationsPerChannel`): no typing announcement in a channel so
    /// large that the fan-out would cost the server more than the indicator is worth.
    var maxNotificationsPerChannel: Int

    static let `default` = MMTypingSettings()

    init(isEnabled: Bool = true, interval: TimeInterval = 5, maxNotificationsPerChannel: Int = 1000) {
        self.isEnabled = isEnabled
        self.interval = interval
        self.maxNotificationsPerChannel = maxNotificationsPerChannel
    }

    /// Decode `GET /api/v4/config/client?format=old`. Unknown keys are ignored; a malformed value
    /// takes the documented default rather than throwing, because one bad key must not silence the
    /// whole feature.
    init(clientConfig: [String: JSONValue]) {
        func flag(_ key: String) -> Bool? {
            switch clientConfig[key] {
            case .bool(let value)?: return value
            case .string(let text)?:
                switch text.lowercased() {
                case "true", "1": return true
                case "false", "0": return false
                default: return nil
                }
            case .number(let number)?: return number != 0
            default: return nil
            }
        }
        func integer(_ key: String) -> Int? {
            switch clientConfig[key] {
            case .number(let number)?: return Int(number)
            case .string(let text)?: return Int(text)
            default: return nil
            }
        }

        let fallback = MMTypingSettings()
        self.isEnabled = flag("EnableUserTypingMessages") ?? fallback.isEnabled
        // A zero or negative interval would make the composer emit a frame per keystroke (a flood)
        // and the row vanish instantly: both are refused, and the server's own default is kept.
        let milliseconds = integer("TimeBetweenUserTypingUpdatesMilliseconds") ?? 0
        self.interval = milliseconds > 0
            ? TimeInterval(milliseconds) / 1000
            : fallback.interval
        let maximum = integer("MaxNotificationsPerChannel") ?? 0
        self.maxNotificationsPerChannel = maximum > 0 ? maximum : fallback.maxNotificationsPerChannel
    }
}

extension APIClient {
    /// `GET /api/v4/config/client?format=old` — the server's typing switch and intervals.
    ///
    /// Public endpoint (the sign-in screen reads the same document for its password policy), so no
    /// credential is required; the call still goes through `APIClient` for the ETag cache, typed
    /// errors and retry. The ETag matters here: the composer and both panes ask for this document,
    /// and the second and later answers are `304`s.
    func typingSettings() async throws -> MMTypingSettings {
        let raw = try await get([String: JSONValue].self,
                                path: "/config/client",
                                query: [URLQueryItem(name: "format", value: "old")],
                                requiresAuth: false)
        return MMTypingSettings(clientConfig: raw)
    }
}
