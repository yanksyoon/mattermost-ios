// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/user_profile/ (the popover and the full profile screen), app/screens/custom_status/
//        + app/screens/custom_status_clear_after/ (the status setter and its expiry picker),
//        app/components/custom_status/ (the status dot, the emoji+text pill),
//        app/utils/custom_status.ts (`getCustomStatusExpiryTime`, the duration table),
//        app/utils/user/index.ts (`displayUsername`, `getFullName`, `isGuest`/`isSystemAdmin`,
//        `getLastActivity`, `getUserTimezone`), app/client/rest/users.ts (`status/custom`,
//        `users/status/ids`, `updateMe`, `getUser`) and app/actions/remote/user.ts (`setStatus`,
//        `setCustomStatus`).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §18; no
// upstream source copied. The SwiftUI decomposition is this repo's own (docs/component-map.md §1).
//
// Everything in this file is **pure**: decoding, derivation and formatting. No I/O, no SwiftUI, no
// clock of its own — every function that needs "now" is handed one, so the unit suite can pin the
// rules instead of the wall clock.
//
// ## What the server actually answers (measured, not read off a type definition)
//
// `scripts/t41_profile_probe.py` against Mattermost 9.11.19 at `127.0.0.1:8065`
// (transcript: `docs/t41-profile-probe-2026-10-26.log`):
//
//  1. `GET /users/{id}` carries `roles`, `position`, `nickname`, `timezone` and `props`, and
//     **no** `custom_status` field. The custom status lives inside `props.customStatus` as a
//     **JSON string**, e.g.
//     `{"emoji":"coffee","text":"Working remotely","duration":"one_hour","expires_at":"2026-10-26T21:15:00.712Z"}`.
//     So it has to be decoded twice, and a `user_updated` socket frame is how another client learns
//     about it (the server publishes one on `SetCustomStatus` — `sendUpdatedUserEvent` keeps `Props`).
//  2. `timezone.useAutomaticTimezone` is the **string** `"true"`/`"false"`, not a bool.
//  3. `is_bot` / `last_activity_at` are absent (or `null`) rather than `false`/`0`, so both decoders
//     are tolerant.
//  4. `PUT /users/{id}/status/custom` takes the custom status **flat** (not wrapped in
//     `custom_status`) and the body is a Go `time.Time` plus a fixed duration vocabulary:
//     `""`, `thirty_minutes`, `one_hour`, `four_hours`, `today`, `this_week`, `date_and_time`.
//     `"30m"`, `"1h"` and `"99y"` answer `400 invalid_body_param` ("Invalid or missing custom_status in
//     request body"), and a non-empty duration **without** a future `expires_at` answers the same 400
//     (both branches of `model.CustomStatus.AreDurationAndExpirationTimeValid`). `expires_at: ""`
//     fails too, because Go cannot parse an empty string into a time. This is why the encoder below
//     omits the key entirely when there is no expiry and always computes one when there is.
//  5. The stored status of "no expiry" is the Go zero time `0001-01-01T00:00:00Z`, which is a
//     perfectly ordinary *past* date — so `isExpired` must treat a year ≤ 1 as "never expires", not
//     as "expired in the year 1".
//  6. `PUT /users/me/status` takes `{user_id, status, dnd_end_time}`; `status` must be one of
//     `online`/`away`/`dnd`/`offline` (anything else is a 400) and `dnd_end_time` is epoch **ms**.
//     Setting `online` clears the server's `manual` flag; `away`/`dnd` set it. That asymmetry is what
//     makes auto-away revertible (§`AutoAwayRule`).
//  7. `POST /users/status/ids` answers `{user_id, status, manual, last_activity_at, dnd_end_time}`;
//     the socket's `status_change` frame carries **only** `user_id` + `status`, so a socket update
//     must not be allowed to erase what the batched read said about `manual`.

import Foundation

// MARK: - Timezone

/// A user's `timezone` object (`GET /users/{id}`).
///
/// `useAutomaticTimezone` is a string on the wire (measured — see the header). It is decoded from
/// either a bool or a string, because a future server or a proxy is free to normalise it and the
/// screen must not lose the whole profile over one field.
struct MMUserTimezone: Codable, Equatable, Sendable {
    var automaticTimezone: String
    var manualTimezone: String
    var useAutomatic: Bool

    enum CodingKeys: String, CodingKey {
        case automaticTimezone
        case manualTimezone
        case useAutomatic = "useAutomaticTimezone"
    }

    init(automaticTimezone: String = "", manualTimezone: String = "", useAutomatic: Bool = true) {
        self.automaticTimezone = automaticTimezone
        self.manualTimezone = manualTimezone
        self.useAutomatic = useAutomatic
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        automaticTimezone = try values.decodeIfPresent(String.self, forKey: .automaticTimezone) ?? ""
        manualTimezone = try values.decodeIfPresent(String.self, forKey: .manualTimezone) ?? ""
        if let flag = try? values.decodeIfPresent(Bool.self, forKey: .useAutomatic) {
            useAutomatic = flag
        } else if let text = try? values.decodeIfPresent(String.self, forKey: .useAutomatic) {
            useAutomatic = (text as NSString).boolValue
        } else {
            useAutomatic = true
        }
    }

    /// The zone the profile draws its "local time" line in.
    ///
    /// The automatic zone wins while the user has not overridden it (upstream `getUserTimezone`),
    /// and an empty answer means the server has no idea — the screen then says so instead of
    /// pretending the reader's own zone is the other person's.
    var effectiveZoneID: String? {
        let automatic = automaticTimezone.trimmingCharacters(in: .whitespaces)
        let manual = manualTimezone.trimmingCharacters(in: .whitespaces)
        if useAutomatic {
            return automatic.isEmpty ? (manual.isEmpty ? nil : manual) : automatic
        }
        return manual.isEmpty ? (automatic.isEmpty ? nil : automatic) : manual
    }
}

// MARK: - Custom status

/// The custom status the server keeps in `User.Props["customStatus"]`.
///
/// `duration` stays a raw string on purpose: the server's own vocabulary is finite (measured, see the
/// header) but a server may answer a value this build does not know, and dropping it would make the
/// screen claim a different status than the one stored.
struct UserCustomStatus: Equatable, Sendable {
    var emoji: String
    var text: String
    var duration: String
    var expiresAt: Date?

    init(emoji: String = "", text: String = "", duration: String = "", expiresAt: Date? = nil) {
        self.emoji = emoji
        self.text = text
        self.duration = duration
        self.expiresAt = expiresAt
    }

    /// Whether there is anything to draw at all. Both empty is "no status" — the server rejects a
    /// write of both-empty as well (`api.custom_status.set_custom_statuses.update.app_error`).
    var isEmpty: Bool { emoji.isEmpty && text.isEmpty }

    /// Whether the status still applies at `now`.
    ///
    /// The no-expiry case is the Go zero time (`0001-01-01T00:00:00Z`), which is *before* every date
    /// this app will ever be handed; treating it as an expiry would report every status without a
    /// duration as already gone (measured, see the header — point 5).
    func isExpired(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        let year = Calendar(identifier: .gregorian)
            .component(.year, from: expiresAt)
        if year <= 1 { return false }
        return expiresAt <= now
    }

    /// Whether the status should be drawn at `now`.
    func isActive(at now: Date) -> Bool { !isEmpty && !isExpired(at: now) }

    /// The duration as the setter's own vocabulary, when this build knows it.
    var knownDuration: StatusDuration? {
        StatusDuration(wireValue: duration)
    }

    /// Decode the JSON string the server stores in `props.customStatus`.
    ///
    /// Returns `nil` for an absent, empty or unparseable value rather than throwing: a profile with a
    /// custom status an older build cannot parse still renders every other field.
    static func decode(propsValue: String?) -> UserCustomStatus? {
        guard let raw = propsValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw != "null",
              let data = raw.data(using: .utf8) else { return nil }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        if wire.emoji.isEmpty && wire.text.isEmpty { return nil }
        return UserCustomStatus(emoji: wire.emoji,
                                text: wire.text,
                                duration: wire.duration,
                                expiresAt: wire.expiresAt)
    }

    /// The wire shape the server stores (and answers inside `props`).
    struct Wire: Codable, Equatable, Sendable {
        var emoji: String
        var text: String
        var duration: String
        var expiresAt: Date?

        enum CodingKeys: String, CodingKey {
            case emoji, text, duration
            case expiresAt = "expires_at"
        }

        init(emoji: String = "", text: String = "", duration: String = "", expiresAt: Date? = nil) {
            self.emoji = emoji
            self.text = text
            self.duration = duration
            self.expiresAt = expiresAt
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            emoji = try values.decodeIfPresent(String.self, forKey: .emoji) ?? ""
            text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
            duration = try values.decodeIfPresent(String.self, forKey: .duration) ?? ""
            if let raw = try values.decodeIfPresent(String.self, forKey: .expiresAt) {
                expiresAt = ProfileTimestamp.date(fromServer: raw)
            } else {
                expiresAt = nil
            }
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(emoji, forKey: .emoji)
            try values.encode(text, forKey: .text)
            try values.encode(duration, forKey: .duration)
            if let expiresAt {
                try values.encode(ProfileTimestamp.string(from: expiresAt), forKey: .expiresAt)
            } else {
                // Never `""`: Go cannot parse it into a time and the server answers 400 (measured).
                try values.encode("0001-01-01T00:00:00Z", forKey: .expiresAt)
            }
        }
    }
}

// MARK: - Timestamps

/// The one place this surface turns dates into the strings the server parses.
///
/// The server's custom-status body is a Go `time.Time` (RFC 3339). Two details are pinned here
/// because both were paid for in probe runs: a fractional component is accepted and is what the
/// server itself answers with, and a *missing* `expires_at` means the zero time (no expiry) while an
/// **empty string** is a decode failure (400).
enum ProfileTimestamp {
    /// RFC 3339 with milliseconds, UTC — the shape the server answers with (measured).
    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// Parse any of the shapes this server (or an older one) may answer: with milliseconds, without,
    /// or the Go zero time.
    static func date(fromServer raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: trimmed) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: trimmed)
    }
}

// MARK: - Presence

/// A presence value, as the client draws it.
///
/// The server's vocabulary is exactly `online`/`away`/`dnd`/`offline` (measured: `bogus` answers
/// 400). Anything else this build is handed — including the empty string a stripped frame can carry —
/// is `unknown`, which is drawn as "unknown" and never as "offline": claiming somebody is offline
/// because a status was not read is the kind of lie that costs a reader.
enum UserPresence: String, CaseIterable, Identifiable, Sendable {
    case online
    case away
    case dnd
    case offline
    case unknown

    var id: String { rawValue }

    init(wire: String?) {
        guard let wire, let value = UserPresence(rawValue: wire.lowercased()) else {
            self = .unknown
            return
        }
        self = value
    }

    /// The four values the setter offers (an unknown presence is never a *choice*).
    static var selectable: [UserPresence] { [.online, .away, .dnd, .offline] }

    var title: String {
        switch self {
        case .online: return "Online"
        case .away: return "Away"
        case .dnd: return "Do not disturb"
        case .offline: return "Offline"
        case .unknown: return "Status unknown"
        }
    }

    /// What the dot means, in one sentence (upstream's status menu copy).
    var explanation: String {
        switch self {
        case .online: return "You are online and will receive notifications."
        case .away: return "You are away and will receive notifications."
        case .dnd: return "You will not receive notifications."
        case .offline: return "You are offline and will not receive notifications."
        case .unknown: return "This account's presence could not be read."
        }
    }

    /// SF Symbol for the row (a circle dot; `dnd` is the "minus" pill upstream draws).
    var glyph: String {
        switch self {
        case .online: return "circle.fill"
        case .away: return "circle.lefthalf.filled"
        case .dnd: return "minus.circle.fill"
        case .offline: return "circle"
        case .unknown: return "questionmark.circle"
        }
    }

    /// Whether the server will keep this value rather than ageing it out on its own.
    ///
    /// Read off the measured `manual` flags: `away`/`dnd` come back `manual: true`, `online` and
    /// `offline` `manual: false`. It is only a fallback for a status the batched read has not
    /// answered yet — the authoritative flag is the one the server sends.
    var setsManualFlag: Bool { self == .away || self == .dnd }
}

/// One presence row: what `POST /users/status/ids` answers and what the socket patches.
struct UserStatusSnapshot: Equatable, Sendable {
    var userID: String
    var presence: UserPresence
    /// The server's `manual` flag — a status the user picked rather than one the server derived.
    var manual: Bool
    var lastActivityAt: Date?
    var dndEndTime: Date?

    init(userID: String,
         presence: UserPresence,
         manual: Bool = false,
         lastActivityAt: Date? = nil,
         dndEndTime: Date? = nil) {
        self.userID = userID
        self.presence = presence
        self.manual = manual
        self.lastActivityAt = lastActivityAt
        self.dndEndTime = dndEndTime
    }

    /// The `status_change` frame carries only `user_id` + `status` (measured — see the header), so a
    /// socket update keeps the `manual`/`last_activity_at`/`dnd_end_time` the batched read supplied.
    /// Losing them would make the next auto-away pass think a deliberate `away` was automatic.
    func applying(socketStatus raw: String) -> UserStatusSnapshot {
        var copy = self
        copy.presence = UserPresence(wire: raw)
        return copy
    }

    /// Whether this row can serve as a choice for the setter's current value.
    var isManualChoice: Bool { manual || presence.setsManualFlag }
}

// MARK: - Status duration (the setter's vocabulary)

/// The durations the server accepts, and how this app turns them into an expiry.
///
/// The wire values are the server's own (`handler` `validCustomStatusDuration` in
/// `server/public/model/custom_status.go`, verified live: `"30m"` is a 400). They are **not**
/// human-readable, so the readable titles live here and nowhere else.
enum StatusDuration: String, CaseIterable, Identifiable, Sendable {
    case doNotClear
    case thirtyMinutes
    case oneHour
    case fourHours
    case today
    case thisWeek
    case dateAndTime

    var id: String { rawValue }

    /// The value the wire body carries. `doNotClear` is the empty string — and the body then omits
    /// `expires_at` entirely (see `CustomStatusBody`).
    var wireValue: String {
        switch self {
        case .doNotClear: return ""
        case .thirtyMinutes: return "thirty_minutes"
        case .oneHour: return "one_hour"
        case .fourHours: return "four_hours"
        case .today: return "today"
        case .thisWeek: return "this_week"
        case .dateAndTime: return "date_and_time"
        }
    }

    init?(wireValue: String) {
        guard let match = StatusDuration.allCases.first(where: { $0.wireValue == wireValue }) else {
            return nil
        }
        self = match
    }

    var title: String {
        switch self {
        case .doNotClear: return "Don't clear"
        case .thirtyMinutes: return "30 minutes"
        case .oneHour: return "1 hour"
        case .fourHours: return "4 hours"
        case .today: return "Today"
        case .thisWeek: return "This week"
        case .dateAndTime: return "Choose a date and time"
        }
    }

    /// The durations the *status setter* offers for a "do not disturb" end time. `dateAndTime` is
    /// absent because this card does not draw a date picker for DND; the custom-status editor does.
    static var dndChoices: [StatusDuration] {
        [.thirtyMinutes, .oneHour, .fourHours, .today]
    }

    /// The expiry this duration means, from `now`.
    ///
    /// `nil` for `doNotClear` (no expiry) and `dateAndTime` (the caller supplies the date — this
    /// function has no picker). `today`/`thisWeek` end at the last second of the day/week in `calendar`'s
    /// time zone, which is what the reader means by "today".
    func expiry(from now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .doNotClear, .dateAndTime:
            return nil
        case .thirtyMinutes:
            return now.addingTimeInterval(30 * 60)
        case .oneHour:
            return now.addingTimeInterval(60 * 60)
        case .fourHours:
            return now.addingTimeInterval(4 * 60 * 60)
        case .today:
            guard let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else {
                return nil
            }
            return end.addingTimeInterval(-1)
        case .thisWeek:
            guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return nil }
            return week.end.addingTimeInterval(-1)
        }
    }

    /// The same, for a DND end time, in the epoch **milliseconds** the status body wants.
    func dndEndTimeMillis(from now: Date, calendar: Calendar = .current) -> Int64? {
        guard let expiry = expiry(from: now, calendar: calendar) else { return nil }
        return Int64((expiry.timeIntervalSince1970 * 1000).rounded())
    }
}

// MARK: - The write bodies

/// `PUT /users/{id}/status/custom` — the custom status **flat**, with the expiry rules the server
/// enforces (measured; see the header).
struct CustomStatusBody: Encodable, Equatable, Sendable {
    var emoji: String
    var text: String
    var duration: String
    /// `nil` means "omit the key": the server's Go zero-value time is the no-expiry case, and an empty
    /// string is a 400.
    var expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case emoji, text, duration
        case expiresAt = "expires_at"
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(emoji, forKey: .emoji)
        try values.encode(text, forKey: .text)
        try values.encode(duration, forKey: .duration)
        if let expiresAt {
            try values.encode(ProfileTimestamp.string(from: expiresAt), forKey: .expiresAt)
        }
    }
}

/// `PUT /users/me/status` — the presence write.
struct PresenceUpdateBody: Encodable, Equatable, Sendable {
    var userID: String
    var status: String
    /// Epoch milliseconds; omitted when there is no DND end time.
    var dndEndTime: Int64?

    enum CodingKeys: String, CodingKey {
        case status
        case userID = "user_id"
        case dndEndTime = "dnd_end_time"
    }

    init(userID: String, presence: UserPresence, dndEndTime: Int64? = nil) {
        self.userID = userID
        self.status = presence.rawValue
        self.dndEndTime = dndEndTime
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(userID, forKey: .userID)
        try values.encode(status, forKey: .status)
        if let dndEndTime {
            try values.encode(dndEndTime, forKey: .dndEndTime)
        }
    }
}

// MARK: - The custom status draft (the editor's state, and its validation)

/// What the custom-status editor is holding, and the rules that decide whether it may be sent.
struct CustomStatusDraft: Equatable, Sendable {
    /// The server truncates at 100 **runes** (`CustomStatusTextMaxRunes`); the editor refuses instead
    /// of letting the message quietly lose its end.
    static let textLimit = 100

    var emoji: String = ""
    var text: String = ""
    var duration: StatusDuration = .doNotClear
    /// The date the reader picked, used only by `.dateAndTime`.
    var customExpiry: Date?

    init(emoji: String = "", text: String = "", duration: StatusDuration = .doNotClear,
         customExpiry: Date? = nil) {
        self.emoji = emoji
        self.text = text
        self.duration = duration
        self.customExpiry = customExpiry
    }

    /// Start the editor from the status the server holds.
    init(status: UserCustomStatus) {
        self.emoji = status.emoji
        self.text = status.text
        self.duration = status.knownDuration ?? .doNotClear
        self.customExpiry = self.duration == .dateAndTime ? status.expiresAt : nil
    }

    var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedEmoji: String {
        emoji.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A statement of what is missing, or `nil` when the draft can be sent.
    ///
    /// The server's own rules are the floor, not the ceiling: it accepts a write that is only an
    /// emoji, so this does too, and it rejects both-empty with a 400, so the editor disables the
    /// button instead of provoking the error.
    func validationMessage(at now: Date) -> String? {
        if trimmedEmoji.isEmpty && trimmedText.isEmpty {
            return "Add an emoji or some text — an empty status has nothing to show."
        }
        let runes = Array(trimmedText)
        if runes.count > Self.textLimit {
            return "This status is \(runes.count) characters. The server keeps \(Self.textLimit)."
        }
        switch duration {
        case .doNotClear:
            if let customExpiry {
                // duration "" plus a *future* expiry is a 400 on the server (measured): the two
                // branches of the validity check both fail.
                return "\"Don't clear\" cannot carry an end time. Choose a duration."
            }
            return nil
        case .dateAndTime:
            guard let customExpiry else {
                return "Choose the date and time this status should clear."
            }
            if customExpiry <= now {
                return "That date has already passed."
            }
            return nil
        default:
            return nil
        }
    }

    func canSave(at now: Date) -> Bool { validationMessage(at: now) == nil }

    /// The body to send, or `nil` when the draft is not sendable.
    ///
    /// This is the single place the duration/expiry pairing is decided, so "empty duration with a
    /// future expiry" (a 400) cannot be produced by one screen and not another.
    func body(at now: Date, calendar: Calendar = .current) -> CustomStatusBody? {
        guard canSave(at: now) else { return nil }
        let expiry: Date?
        switch duration {
        case .doNotClear:
            expiry = nil
        case .dateAndTime:
            expiry = customExpiry
        default:
            expiry = duration.expiry(from: now, calendar: calendar)
        }
        if duration != .doNotClear && duration != .dateAndTime && expiry == nil {
            // A calendar that cannot answer is a programming error, not a user error: refuse to send
            // rather than send the 400 the server would answer.
            return nil
        }
        return CustomStatusBody(emoji: trimmedEmoji, text: trimmedText,
                                duration: duration.wireValue, expiresAt: expiry)
    }
}

/// The emoji the custom-status editor offers.
///
/// A curated strip, not the full picker: T37's `EmojiPickerView` is a **sheet**, and the editor lives
/// inside the profile sheet — a sheet presented from a sheet is the exact defect T40's validator
/// measured (`AddMembersView`'s submit never ran), so this surface nests nothing. The names are
/// checked against the server by `scripts/t41_profile_probe.py`, which is what makes each one a
/// promise the server will accept (`confirmEmojiExists` rejects an unknown name with a 400).
enum CustomStatusEmoji {
    static let palette: [String] = [
        "speech_balloon", "coffee", "calendar", "palm_tree", "airplane",
        "house", "face_with_thermometer", "sick", "beach_with_umbrella", "hamburger",
        "car", "book", "pencil", "computer", "zzz",
        "no_entry_sign", "crescent_moon", "sunny", "umbrella", "tada",
    ]

    /// A readable name for the cell's accessibility label ("palm_tree" → "palm tree").
    static func spokenName(_ emoji: String) -> String {
        emoji.replacingOccurrences(of: "_", with: " ")
    }
}

// MARK: - The profile itself

/// A user, as `GET /users/{id}` answers it.
///
/// Distinct from the app's rendering model `MMUser` on purpose, and for the same reason T40 declared
/// `MMPrincipal`: the profile screen needs `roles`, `position`, `nickname`, `timezone` and `props`,
/// and none of them belong in the message/thread rows' model. Declaring them here keeps the store's
/// schema and every existing decoder untouched.
struct MMUserProfile: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var username: String
    var firstName: String
    var lastName: String
    var nickname: String
    var position: String
    var email: String
    /// Space-separated role names (`"system_admin system_user"`), exactly as the server sends them.
    var roles: String
    /// `props.customStatus` is a JSON string (measured); everything else in `props` is left opaque.
    var props: [String: String]
    var timezone: MMUserTimezone?
    var createAt: Int64
    var updateAt: Int64
    var deleteAt: Int64
    /// Absent on `/users/me` for an account that has never been seen active (measured `null`).
    var lastActivityAt: Int64
    var authService: String
    var isBot: Bool

    enum CodingKeys: String, CodingKey {
        case id, username, nickname, position, email, roles, props, timezone
        case firstName = "first_name"
        case lastName = "last_name"
        case createAt = "create_at"
        case updateAt = "update_at"
        case deleteAt = "delete_at"
        case lastActivityAt = "last_activity_at"
        case authService = "auth_service"
        case isBot = "is_bot"
    }

    init(id: String,
         username: String = "",
         firstName: String = "",
         lastName: String = "",
         nickname: String = "",
         position: String = "",
         email: String = "",
         roles: String = "system_user",
         props: [String: String] = [:],
         timezone: MMUserTimezone? = nil,
         createAt: Int64 = 0,
         updateAt: Int64 = 0,
         deleteAt: Int64 = 0,
         lastActivityAt: Int64 = 0,
         authService: String = "",
         isBot: Bool = false) {
        self.id = id
        self.username = username
        self.firstName = firstName
        self.lastName = lastName
        self.nickname = nickname
        self.position = position
        self.email = email
        self.roles = roles
        self.props = props
        self.timezone = timezone
        self.createAt = createAt
        self.updateAt = updateAt
        self.deleteAt = deleteAt
        self.lastActivityAt = lastActivityAt
        self.authService = authService
        self.isBot = isBot
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? ""
        username = try values.decodeIfPresent(String.self, forKey: .username) ?? ""
        firstName = try values.decodeIfPresent(String.self, forKey: .firstName) ?? ""
        lastName = try values.decodeIfPresent(String.self, forKey: .lastName) ?? ""
        nickname = try values.decodeIfPresent(String.self, forKey: .nickname) ?? ""
        position = try values.decodeIfPresent(String.self, forKey: .position) ?? ""
        email = try values.decodeIfPresent(String.self, forKey: .email) ?? ""
        roles = try values.decodeIfPresent(String.self, forKey: .roles) ?? ""
        props = try values.decodeIfPresent([String: String].self, forKey: .props) ?? [:]
        timezone = try values.decodeIfPresent(MMUserTimezone.self, forKey: .timezone)
        createAt = try values.decodeIfPresent(Int64.self, forKey: .createAt) ?? 0
        updateAt = try values.decodeIfPresent(Int64.self, forKey: .updateAt) ?? 0
        deleteAt = try values.decodeIfPresent(Int64.self, forKey: .deleteAt) ?? 0
        lastActivityAt = try values.decodeIfPresent(Int64.self, forKey: .lastActivityAt) ?? 0
        authService = try values.decodeIfPresent(String.self, forKey: .authService) ?? ""
        isBot = try values.decodeIfPresent(Bool.self, forKey: .isBot) ?? false
    }

    // MARK: Derived identity

    /// The name to draw: first + last when the server has them, otherwise the username.
    ///
    /// Upstream `getFullName` does exactly this, and the nickname is deliberately not in the chain —
    /// a nickname is a field of its own, drawn under the name, not a replacement for it.
    var displayName: String {
        let full = [firstName, lastName]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return full.isEmpty ? username : full
    }

    /// Whether a separate full name exists (so the username is worth drawing as `@username`).
    var hasFullName: Bool { !firstName.isEmpty || !lastName.isEmpty }

    /// Up to two letters for the avatar fallback.
    ///
    /// Server-side profile images are optional (`GET /users/{id}/profile_image` answers 404 for an
    /// account without one — measured), so initials are the normal case, not an edge case.
    var initials: String {
        let first = firstName.trimmingCharacters(in: .whitespaces)
        let last = lastName.trimmingCharacters(in: .whitespaces)
        if !first.isEmpty || !last.isEmpty {
            let a = first.first.map(String.init) ?? ""
            let b = last.first.map(String.init) ?? ""
            let joined = (a + b).uppercased()
            return joined.isEmpty ? String(username.prefix(2)).uppercased() : joined
        }
        return String(username.prefix(2)).uppercased()
    }

    /// The role names, split the way the server joins them.
    var roleNames: [String] {
        roles.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    var isSystemAdmin: Bool { roleNames.contains("system_admin") }
    var isGuest: Bool { roleNames.contains("system_guest") }
    var isDeactivated: Bool { deleteAt > 0 }
    /// An SSO-only account cannot be invited to a DM by e-mail; the screen only states where the
    /// account signs in.
    var isSSOAccount: Bool { !authService.isEmpty }

    /// The badges the profile draws: system administrator, guest, bot.
    ///
    /// Order is fixed (administrator, then guest, then bot) so a test can assert the list instead of
    /// the rendering, and so two profiles with the same roles always draw the same rows.
    var roleLabels: [ProfileRoleLabel] {
        var labels: [ProfileRoleLabel] = []
        if isSystemAdmin { labels.append(.systemAdmin) }
        if isGuest { labels.append(.guest) }
        if isBot { labels.append(.bot) }
        return labels
    }

    /// The custom status the server has stored, if any.
    var customStatus: UserCustomStatus? {
        UserCustomStatus.decode(propsValue: props["customStatus"])
    }

    /// The zone the local-time line is drawn in (`nil` when the server has no idea).
    var localTimeZoneID: String? { timezone?.effectiveZoneID }

    /// Member since, as a date the formatter turns into text.
    var joinedAt: Date? {
        createAt > 0 ? Date(timeIntervalSince1970: Double(createAt) / 1000) : nil
    }

    /// The last time the server saw this account active.
    var lastActivityDate: Date? {
        lastActivityAt > 0 ? Date(timeIntervalSince1970: Double(lastActivityAt) / 1000) : nil
    }
}

/// The role badges the profile can draw.
enum ProfileRoleLabel: String, Identifiable, Sendable, CaseIterable {
    case systemAdmin
    case guest
    case bot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemAdmin: return "System admin"
        case .guest: return "Guest"
        case .bot: return "Bot"
        }
    }
}

// MARK: - Auto-away

/// What a background/foreground transition should do to my presence.
enum AutoAwayAction: Equatable, Sendable {
    /// Change nothing (a deliberate status, or no session to write with).
    case none
    /// I was online and the app went to the background: show as away.
    case setAway
    /// The app came back and the absence was this client's own doing: put the reader's status back.
    case restore(UserPresence)
}

/// The auto-away rules, as pure functions.
///
/// The programme's premise is a client that behaves like the web client without keeping a page alive;
/// presence is where that is observable. The rules are deliberately conservative, because a wrong
/// one is a reader telling colleagues they are unavailable:
///
///  * **Background**: only a status the server derived (`online`, `manual == false`) is aged to
///    `away`. A deliberate `away`/`dnd`/`offline` is left alone — the reader chose it and this client
///    does not overrule a choice.
///  * **Foreground**: the status is only restored when *this* client was the one that set `away`
///    (`didAutoAway`), the server still shows a non-manual `away` (nothing else has changed it since),
///    and the stored preference differs from what is there. Otherwise nothing is written: a `dnd`
///    somebody set from another device while the app was backgrounded must survive the return.
enum AutoAwayRule {

    /// Whether the app going to the background should set `away`.
    static func onBackground(current: UserStatusSnapshot?) -> AutoAwayAction {
        guard let current else { return .none }
        guard current.presence == .online, !current.manual else { return .none }
        return .setAway
    }

    /// Whether a `status_change` frame about **my own** account should become the reader's stored
    /// preference — the status a return to the foreground restores.
    ///
    /// It must not when the frame is the server echoing this client's own auto-away write. Measured:
    /// the echo arrives within milliseconds, and adopting it set the preference to `away`, so the
    /// return found "the preferred status is already what is here" and never put the reader back
    /// online — the second half of the defect the live auto-away test found.
    static func adoptsSocketStatus(_ presence: UserPresence, owningAutoAway: Bool) -> Bool {
        !(owningAutoAway && presence == .away)
    }

    /// Whether coming back to the foreground should restore the reader's own status.
    ///
    /// `ownWrite` is the server's answer to *this client's* auto-away write. It has to be passed in
    /// because `away` comes back `manual: true` (measured): without it the "somebody else changed my
    /// status while I was away" guard would match the app's own write and refuse to undo it — which is
    /// exactly the defect the live auto-away test found (background aged to `away`, and the app then
    /// never put `online` back).
    ///
    /// The bound this leaves, stated rather than hidden: a manual `away` written by *another* client
    /// while the app was backgrounded is indistinguishable from our own on the wire (both are
    /// `away`, `manual: true`), so returning to the foreground can restore over it. Any *other*
    /// value somebody chose (dnd, offline) is respected.
    static func onForeground(current: UserStatusSnapshot?,
                             preferred: UserPresence,
                             didAutoAway: Bool,
                             ownWrite: UserStatusSnapshot? = nil) -> AutoAwayAction {
        guard didAutoAway else { return .none }
        if let current {
            // Something changed my status while I was away (another client, the server's own idle
            // timer): that is newer information than this client's memory, so leave it — unless what
            // is there is the `away` this client itself just wrote.
            let isOurOwnWrite = ownWrite.map {
                $0.presence == current.presence && $0.manual == current.manual
            } ?? false
            if current.manual && !isOurOwnWrite { return .none }
            if current.presence == preferred { return .none }
        }
        return .restore(preferred)
    }
}

// MARK: - The DM shortcut

/// The rules behind "Send message" on a profile.
enum DMShortcut {

    /// Whether the button is offered at all.
    ///
    /// Not on my own profile (there is no conversation with myself), and not on a deactivated
    /// account: the server would answer a DM channel whose other half can never read it. A **bot** is
    /// allowed — that is how an integration is reached, and upstream offers it too.
    static func canMessage(profile: MMUserProfile, myUserID: String?) -> Bool {
        guard let myUserID, !myUserID.isEmpty else { return false }
        guard profile.id != myUserID else { return false }
        return !profile.isDeactivated
    }

    /// Why the button is not offered, when the profile can say something more useful than nothing.
    static func unavailableReason(profile: MMUserProfile, myUserID: String?) -> String? {
        guard !canMessage(profile: profile, myUserID: myUserID) else { return nil }
        if let myUserID, profile.id == myUserID {
            return "This is your own profile."
        }
        if profile.isDeactivated {
            return "This account has been deactivated, so it cannot be messaged."
        }
        return "Your account is not loaded yet, so a conversation cannot be started."
    }

    /// The button's title (upstream: "Message" in the popover, "Send message" on the full profile).
    static func title(profile: MMUserProfile, myUserID: String?) -> String {
        guard let myUserID, profile.id == myUserID else { return "Send message" }
        return "Message yourself"
    }
}

// MARK: - Formatting

/// The strings the profile draws, as pure functions of a date, a zone and a locale.
///
/// Two rules hold everywhere here:
///  * **no fabrication** — a value the server did not send is described as unknown, never filled in
///    from the device's own zone or from an empty string;
///  * **injectable clock and locale** — every function takes `now`/`locale`/`timeZone`, so the unit
///    suite pins exact strings instead of "whatever the runner's locale does".
enum ProfileDateFormat {

    /// The other person's local time, e.g. `3:41 PM`. `nil` when the server sent no usable zone.
    static func localTime(zoneID: String?, at now: Date, locale: Locale = .current) -> String? {
        guard let zoneID, let zone = TimeZone(identifier: zoneID) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: now)
    }

    /// The zone's abbreviation, e.g. `PDT` — drawn beside the time so "3:41 PM" is not mistaken for
    /// the reader's own clock.
    static func zoneAbbreviation(zoneID: String?, at now: Date) -> String? {
        guard let zoneID, let zone = TimeZone(identifier: zoneID) else { return nil }
        return zone.abbreviation(for: now)
    }

    /// The full "local time" line, or the sentence that says it cannot be drawn.
    static func localTimeSentence(zoneID: String?, at now: Date, locale: Locale = .current) -> String {
        guard let time = localTime(zoneID: zoneID, at: now, locale: locale) else {
            return "Local time unknown"
        }
        if let abbreviation = zoneAbbreviation(zoneID: zoneID, at: now) {
            return "\(time) local time (\(abbreviation))"
        }
        return "\(time) local time"
    }

    /// "Joined 12 March 2024" — the account's `create_at`, in the reader's own zone.
    static func joined(ms: Int64, timeZone: TimeZone = .current, locale: Locale = .current) -> String? {
        guard ms > 0 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        return "Joined \(formatter.string(from: date))"
    }

    /// "Last active 5 minutes ago", "Active now", or "Last active unknown".
    ///
    /// Hand-rolled rather than `RelativeDateTimeFormatter` so the wording is stable across locales
    /// and testable: the profile of a colleague is not the place to discover that the runner's
    /// language renders "vor 5 Minuten".
    static func lastActive(presence: UserPresence,
                           lastActivity: Date?,
                           now: Date) -> String {
        if presence == .online { return "Active now" }
        guard let lastActivity else { return "Last active unknown" }
        return "Last active \(relativeText(from: lastActivity, to: now))"
    }

    /// A relative duration in words: "just now", "5 minutes ago", "3 hours ago", "2 days ago",
    /// "more than a month ago".
    static func relativeText(from date: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago" }
        let hours = minutes / 60
        if hours < 24 { return hours == 1 ? "1 hour ago" : "\(hours) hours ago" }
        let days = hours / 24
        if days <= 30 { return days == 1 ? "1 day ago" : "\(days) days ago" }
        return "more than a month ago"
    }

    /// When a custom status clears: `until 4:15 PM` for today, `until 30 Nov` for another day, or
    /// `nil` when it does not clear.
    static func customStatusExpiry(_ status: UserCustomStatus,
                                   now: Date,
                                   timeZone: TimeZone = .current,
                                   locale: Locale = .current) -> String? {
        guard let expiry = status.expiresAt else { return nil }
        let year = Calendar(identifier: .gregorian).component(.year, from: expiry)
        if year <= 1 { return nil }
        if status.isExpired(at: now) { return "cleared" }
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        if calendar.isDate(expiry, inSameDayAs: now) {
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return "until \(formatter.string(from: expiry))"
        }
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "until \(formatter.string(from: expiry))"
    }

    /// The custom status as the profile's one line: "☕ Working remotely · until 4:15 PM".
    ///
    /// The emoji is the server's **name** (`coffee`), not a character; the view resolves it through
    /// the app's emoji catalogue, so this function returns the text half only and the view composes.
    static func customStatusText(_ status: UserCustomStatus,
                                 now: Date,
                                 timeZone: TimeZone = .current,
                                 locale: Locale = .current) -> String? {
        guard status.isActive(at: now) else { return nil }
        let text = status.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if !text.isEmpty { parts.append(text) }
        if let expiry = customStatusExpiry(status, now: now, timeZone: timeZone, locale: locale) {
            parts.append(expiry)
        }
        if parts.isEmpty && !status.emoji.isEmpty { return nil }   // emoji alone: the pill draws it
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The DND line, e.g. "Do not disturb until 4:15 PM".
    static func dndSentence(_ snapshot: UserStatusSnapshot?,
                            now: Date,
                            timeZone: TimeZone = .current,
                            locale: Locale = .current) -> String? {
        guard let snapshot, snapshot.presence == .dnd, let end = snapshot.dndEndTime else { return nil }
        if end <= now { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        if Calendar.current.isDate(end, inSameDayAs: now) {
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        } else {
            formatter.dateStyle = .short
            formatter.timeStyle = .short
        }
        return "Do not disturb until \(formatter.string(from: end))"
    }
}
