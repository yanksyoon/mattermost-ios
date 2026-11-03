// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/channel_notification_preferences/ (the per-channel notification screen: the
//        "Notifications" level, "Mute channel", and "Ignore @mentions"), app/utils/notification/
//        index.ts (`isChannelMuted`, the `mark_unread` vocabulary), app/client/rest/channels.ts
//        (`updateChannelNotifyProps` → `PUT /channels/{id}/members/{uid}/notify_props`).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §17; no
// upstream source copied. The Swift decomposition is this repo's own (docs/component-map.md §1).
//
// This file is **pure**: no I/O, no SwiftUI. It answers three questions the card states as
// acceptance criteria, so each is unit-testable without a server:
//
//   1. which levels the three per-channel preference fields have, and what each is called;
//   2. what a *write* may carry — only fields the reader actually changed, and only values this
//      build understands (a `PUT` that echoes an unrecognised server value back is a guess about the
//      server's vocabulary, and the server accepts arbitrary strings — measured: `desktop: "nonsense"`
//      answers 200 and is stored verbatim);
//   3. what an **unreadable or unrecognised** level reads as: the server's own value, shown as such,
//      never a default level the reader never chose.
//
// Measured on the pinned 9.11.19 server (docs/t52-build-note.md §2):
//   * a membership's `notify_props` is
//     `{desktop: "default", email: "default", ignore_channel_mentions: "default", mark_unread: "all",
//      push: "default", channel_auto_follow_threads: "off"}`;
//   * `PUT …/notify_props` with a partial body merges: sending `{desktop: "mention"}` left
//     `mark_unread` and `ignore_channel_mentions` exactly as they were;
//   * `GET …/members/{uid}` answers the stored values, so a write is proven by a read, not by the
//     optimistic `200 {"status":"OK"}`;
//   * an unknown level (`desktop: "nonsense"`) is accepted and stored — the server does not validate
//     it, which is exactly why the client must not invent a mapping for what it reads back.

import Foundation

// MARK: - The three levels

/// `notify_props.desktop` — when this channel notifies the reader.
enum ChannelNotifyDesktopLevel: String, CaseIterable, Sendable {
    /// The server's "follow my account default" value.
    case defaultValue = "default"
    case all
    case mention
    case none

    var label: String {
        switch self {
        case .defaultValue: return "Account default"
        case .all: return "All activity"
        case .mention: return "Mentions and keywords"
        case .none: return "Never"
        }
    }
}

/// `notify_props.mark_unread` — `"mention"` is Mattermost's whole definition of a muted channel
/// (upstream `isChannelMuted`), so the mute switch is this field and nothing else.
enum ChannelNotifyMarkUnread: String, CaseIterable, Sendable {
    case all
    case mention

    var label: String {
        switch self {
        case .all: return "All new messages"
        case .mention: return "Only mentions and keywords"
        }
    }
}

/// `notify_props.ignore_channel_mentions` — `"on"` asks the server not to notify this reader for
/// `@channel`/`@all`/`@here` in this channel.
enum ChannelNotifyIgnoreMentions: String, CaseIterable, Sendable {
    case defaultValue = "default"
    case on
    case off

    var label: String {
        switch self {
        case .defaultValue: return "Account default"
        case .on: return "Ignore @channel, @all and @here"
        case .off: return "Notify me"
        }
    }
}

// MARK: - The draft

/// The per-channel notification preferences, held as the **server's own strings**.
///
/// Deliberately not a struct of three enums: the server accepts and stores strings it does not
/// validate (measured), so a value this build has never heard of must survive a round trip untouched.
/// The typed accessors answer `nil` for such a value, and the screen draws the raw value beside them —
/// "fail to the server's current value, never a guess".
struct ChannelNotifyDraft: Equatable, Sendable {
    static let desktopKey = "desktop"
    static let markUnreadKey = "mark_unread"
    static let ignoreMentionsKey = "ignore_channel_mentions"

    /// Only the three keys this screen owns. `email`, `push` and `channel_auto_follow_threads` live on
    /// the same object and are **not** this screen's to touch, so they are not carried here at all.
    private(set) var values: [String: String]

    init(values: [String: String] = [:]) {
        self.values = values
    }

    /// Read a membership row. A missing `notify_props` (a server that omits it, or a fake that did not
    /// model it) yields no values — the screen then says it cannot read them rather than assuming
    /// "default".
    init(member: MMChannelMember) {
        let object = member.notifyProps?.objectValue ?? [:]
        var values: [String: String] = [:]
        for key in [Self.desktopKey, Self.markUnreadKey, Self.ignoreMentionsKey] {
            if let value = object[key]?.stringValue { values[key] = value }
        }
        self.values = values
    }

    /// Whether the server answered anything for the three fields this screen owns.
    var isReadable: Bool { !values.isEmpty }

    var desktop: String? { values[Self.desktopKey] }
    var markUnread: String? { values[Self.markUnreadKey] }
    var ignoreMentions: String? { values[Self.ignoreMentionsKey] }

    var desktopLevel: ChannelNotifyDesktopLevel? { desktop.flatMap(ChannelNotifyDesktopLevel.init(rawValue:)) }
    var markUnreadLevel: ChannelNotifyMarkUnread? { markUnread.flatMap(ChannelNotifyMarkUnread.init(rawValue:)) }
    var ignoreMentionsLevel: ChannelNotifyIgnoreMentions? {
        ignoreMentions.flatMap(ChannelNotifyIgnoreMentions.init(rawValue:))
    }

    /// The mute switch's value. A channel is muted exactly when `mark_unread == "mention"`; anything
    /// else (including an unrecognised value) is not muted, which is the state the sidebar draws too.
    var isMuted: Bool { markUnreadLevel == .mention }

    /// Whether this channel ignores `@channel`/`@all`/`@here` for this reader.
    var ignoresChannelMentions: Bool { ignoreMentionsLevel == .on }

    /// The unrecognised values, as `(field label, raw value)`, for the note the screen draws. A value
    /// this build *does* understand never appears here.
    var unrecognisedValues: [(field: String, value: String)] {
        var result: [(field: String, value: String)] = []
        if let raw = desktop, desktopLevel == nil { result.append(("Notifications", raw)) }
        if let raw = markUnread, markUnreadLevel == nil { result.append(("Mute channel", raw)) }
        if let raw = ignoreMentions, ignoreMentionsLevel == nil {
            result.append(("Ignore @mentions", raw))
        }
        return result
    }

    // MARK: Changing one field

    func setting(desktop level: ChannelNotifyDesktopLevel) -> ChannelNotifyDraft {
        var copy = self
        copy.values[Self.desktopKey] = level.rawValue
        return copy
    }

    func setting(markUnread level: ChannelNotifyMarkUnread) -> ChannelNotifyDraft {
        var copy = self
        copy.values[Self.markUnreadKey] = level.rawValue
        return copy
    }

    func setting(ignoreMentions level: ChannelNotifyIgnoreMentions) -> ChannelNotifyDraft {
        var copy = self
        copy.values[Self.ignoreMentionsKey] = level.rawValue
        return copy
    }

    /// The request body: exactly the fields that changed **to a known value**.
    ///
    /// Three refusals are encoded here, each for a measured reason:
    ///   * an unchanged field is not sent, so a save cannot rewrite a setting somebody else changed
    ///     between this screen's read and its write (the same rule as `ChannelPatchDraft.patch`);
    ///   * a field whose server value is unrecognised is not echoed back when the reader did not touch
    ///     it — the client does not know what it means, and re-sending it would claim it does;
    ///   * a field whose stored value is unrecognised and whose draft value is **still** that raw
    ///     value is not sent either: selecting a level is what makes it a write.
    func changedFields(comparedTo server: ChannelNotifyDraft) -> [String: String] {
        var body: [String: String] = [:]
        if let level = desktopLevel, desktop != server.desktop {
            body[Self.desktopKey] = level.rawValue
        }
        if let level = markUnreadLevel, markUnread != server.markUnread {
            body[Self.markUnreadKey] = level.rawValue
        }
        if let level = ignoreMentionsLevel, ignoreMentions != server.ignoreMentions {
            body[Self.ignoreMentionsKey] = level.rawValue
        }
        return body
    }
}

// MARK: - The row's copy

/// What the channel-info row says under "Notification preferences", derived from the server's values.
enum ChannelNotifyRowSummary {
    /// "Mentions and keywords", "Muted", "Never"…
    ///
    /// A muted channel says so first, because that is the fact a reader came to this row to check.
    /// An unrecognised level is quoted verbatim rather than mapped to "Account default".
    static func subtitle(for draft: ChannelNotifyDraft?) -> String {
        guard let draft, draft.isReadable else { return "" }
        if draft.isMuted { return "Muted" }
        if let level = draft.desktopLevel {
            return level == .defaultValue ? "Account default" : level.label
        }
        if let raw = draft.desktop { return "Server setting: \(raw)" }
        return "Account default"
    }
}
