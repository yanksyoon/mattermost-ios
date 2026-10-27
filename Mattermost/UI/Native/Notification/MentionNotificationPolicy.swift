// Behaviour reference: the Mattermost **server's** own notification decision
// (`app/notification.go` `sendNotification` — account `notify_props.desktop`, the channel member's
// `desktop` / `ignore_channel_mentions` / `mark_unread`, and `isUserMentioned`), which is what the push
// proxy notifies for; plus mattermost/mattermost-mobile @ v2.45.0's *notification props* screens
// (`app/screens/channel_notification_preferences/`, `app/constants/notification_level.ts`) for the
// vocabulary of the per-channel props. Licence: Apache-2.0 / documented server behaviour — the rules
// below are a reimplementation of the contract, no upstream source was copied.
//
// Everything here is **pure**: no network, no clock, no stores. The feed decides *what* happened; this
// file decides whether what happened is a notification, which is the part worth pinning in tests, and
// the formatting, which is the part that must stay byte-identical between the two inputs (`T43`'s
// acceptance criterion: a socket mention and a poller mention produce the same banner).
//
// Measured on the pinned 9.11.19 server (`scripts/t43_notification_probe.py`):
//   * the reader's `notify_props` is `{desktop: "mention", desktop_sound: "true", mention_keys: "",
//     channel: "true", first_name: "false"}` — the account-level inputs this file reads;
//   * a channel membership is `{desktop: "default", ignore_channel_mentions: "default",
//     mark_unread: "all"}` (or `mark_unread: "mention"` for a muted channel, which the sidebar already
//     calls muted — T33);
//   * a **muted** channel still moves the server's `mention_count` when somebody names the reader
//     (measured 0 -> 1), i.e. muting suppresses message notifications, not mentions. The policy below
//     follows the measurement rather than the folklore.

import Foundation

/// The facts about the reader that decide whether a post is *their* notification.
struct MentionReader: Equatable, Sendable {
    /// The signed-in account. Its own posts are never its own notification.
    var userID: String
    /// The account's mention keys (`@username`, extra keys, first name, `@channel`/`@all`/`@here`) —
    /// T42's `MentionKeys`, which is the same derivation the mentions window uses, so a live banner and
    /// the inbox cannot disagree about what counts as a mention.
    var keys: MentionKeys
    /// `notify_props.desktop`: `default` | `all` | `mention` | `none`. `none` = the reader turned
    /// desktop notifications off for every server.
    var desktopNotify: String
    /// `notify_props.desktop_sound`: `"false"` asks for a silent banner (the web app would pass
    /// `silent = true` over the bridge, so the native input maps it the same way).
    var desktopSound: Bool

    init(userID: String, keys: MentionKeys, desktopNotify: String = "default", desktopSound: Bool = true) {
        self.userID = userID
        self.keys = keys
        self.desktopNotify = desktopNotify
        self.desktopSound = desktopSound
    }

    /// Read the profile the way the server sends it: the flags are **strings** on the wire
    /// (`"true"`/`"false"`), the same shape `MentionKeys.derive` and `ProfileModels` already handle.
    static func make(from profile: ActivityProfile) -> MentionReader {
        let props = profile.notifyProps?.objectValue
        let desktop = props?["desktop"]?.stringValue ?? "default"
        let sound = props?["desktop_sound"]?.stringValue.map { $0.lowercased() == "true" }
            ?? props?["desktop_sound"]?.boolValue
            ?? true
        return MentionReader(userID: profile.id,
                             keys: MentionKeys.derive(profile),
                             desktopNotify: desktop,
                             desktopSound: sound)
    }
}

/// Why a `posted` event did or did not become a banner. Kept as a reason (not a bool) so the Settings
/// read-out and the logs can say *why* — "the socket path delivered nothing" and "the socket path
/// suppressed it because it was your own post" are very different facts during a validation run.
enum MentionDropReason: String, Equatable, Sendable {
    case deleted
    case ownPost
    case systemPost
    case notificationsDisabled
    case channelNotificationsOff
    case mentionsIgnored
    case notAMention
    case alreadyDelivered
    case noChannelContext

    /// T43-R (F1): whether this drop means **"the input that owns this post handled it"** — so the T14
    /// poll must not deliver it later — or "this input could not decide", in which case the post stays
    /// pollable.
    ///
    /// Only the reader's own configuration makes a drop definitive. `notAMention` is not a delivery
    /// decision (the server's own `mention_count` will not move for it, and the poller asks the server),
    /// and `noChannelContext` is a failed lookup that the next poll may well succeed at.
    var recordsAsHandled: Bool {
        switch self {
        case .notificationsDisabled, .channelNotificationsOff, .mentionsIgnored:
            return true
        case .deleted, .ownPost, .systemPost, .notAMention, .alreadyDelivered, .noChannelContext:
            return false
        }
    }

    /// The sentence the Settings read-out shows (the strings are user-facing there, so they are not the
    /// enum's raw values).
    var label: String {
        switch self {
        case .deleted: return "the post is deleted"
        case .ownPost: return "your own post"
        case .systemPost: return "a system message"
        case .notificationsDisabled: return "desktop notifications are off for this account"
        case .channelNotificationsOff: return "notifications are off for this channel"
        case .mentionsIgnored: return "this channel is set to ignore mentions"
        case .notAMention: return "the message does not mention you"
        case .alreadyDelivered: return "already notified for this post"
        case .noChannelContext: return "the channel could not be resolved"
        }
    }
}

enum MentionDecision: Equatable, Sendable {
    case deliver(silent: Bool)
    case drop(MentionDropReason)
}

/// The notification decision for one socket post. Pure, and the single place the rule is written.
enum MentionNotificationPolicy {

    /// Decide whether `post` should become a banner for `reader`.
    ///
    /// Inputs are the three things the decision needs on this server: the post, the reader (account
    /// props + mention keys) and the channel context (the channel's type and the reader's membership —
    /// the per-channel notify props). A channel that could not be resolved is not a reason to guess:
    /// `channel == nil` means the input path has no context, and the feed asks for it rather than
    /// notifying blind (that is why `.noChannelContext` is a drop reason and not a default).
    nonisolated static func decision(post: MMPost,
                                     reader: MentionReader,
                                     channel: MMChannel?,
                                     membership: MMChannelMember?) -> MentionDecision {
        // 1. A deleted post is not a notification (an edit-then-delete round trip must not resurrect
        //    one), and the reader's own post is never their own notification.
        if post.deleteAt != 0 { return .drop(.deleted) }
        if !post.id.isEmpty, !reader.userID.isEmpty, post.userId == reader.userID {
            return .drop(.ownPost)
        }
        if post.type.hasPrefix("system_") { return .drop(.systemPost) }

        // 2. Account level: `desktop: "none"` means "do not notify me", whatever the channel says.
        if reader.desktopNotify.lowercased() == "none" { return .drop(.notificationsDisabled) }

        // 3. Channel level. `desktop` is the per-channel override of the *account* setting;
        //    `ignore_channel_mentions: "on"` explicitly asks not to be notified for @mentions here.
        let props = membership?.notifyProps?.objectValue
        let channelDesktop = props?["desktop"]?.stringValue ?? "default"
        let muted = (props?["mark_unread"]?.stringValue ?? "all") == "mention"
        let ignoresMentions = (props?["ignore_channel_mentions"]?.stringValue ?? "default") == "on"
        if channelDesktop.lowercased() == "none" { return .drop(.channelNotificationsOff) }
        if ignoresMentions { return .drop(.mentionsIgnored) }

        // 4. What kind of post is it?
        //    - a DM/GM notifies as a *message* (upstream notifies direct messages without a mention),
        //      so for those the trigger is the channel and its mute state, not the mention keys;
        //    - a channel post notifies only when it names the reader.
        let isDirect = channel?.type == "D" || channel?.type == "G"
        if isDirect {
            // Measured: a DM membership reports `desktop: "default"` and `mark_unread: "all"`, i.e. the
            // default is "all messages in this conversation notify". Muting the conversation is the way
            // to stop that, and muting is exactly `mark_unread: "mention"`.
            if muted { return .drop(.channelNotificationsOff) }
            return .deliver(silent: !reader.desktopSound)
        }

        // A muted channel still notifies a real mention (measured: the mention counter moves), so
        // `muted` is deliberately **not** consulted here.
        //
        // The match includes the broadcast keys: an account that enabled channel mentions is notified by
        // `@channel`, which is the server's own rule. (The inbox uses the personal-keys-only rule; see
        // `MentionKeys.matchesIncludingBroadcasts` for why the two questions differ.)
        guard reader.keys.matchesIncludingBroadcasts(post.message) else {
            return .drop(.notAMention)
        }
        return .deliver(silent: !reader.desktopSound)
    }
}

/// The banner's own text, in one place, so the socket input and the T14 poller cannot drift:
/// desktop's `"server: title"` title, the channel's display name as the title (or the same default the
/// web app falls back to), and upstream's `@user: message` body.
enum MentionNotificationFormatting {

    /// The desktop default title (`main.notifications.mention.title`, "Someone mentioned you") when the
    /// channel has no name to show.
    static let defaultTitle = "Someone mentioned you"

    nonisolated static func title(channelDisplayName: String?) -> String {
        guard let name = channelDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return defaultTitle }
        return name
    }

    /// `@username: message`, falling back to the bare message when the author is unknown (the poller's
    /// fail-soft rule, kept identical here).
    nonisolated static func body(message: String, username: String?) -> String {
        guard let username, !username.isEmpty else { return message }
        return "@\(username): \(message)"
    }

    /// Assemble the notification both inputs hand to `NotificationWorker.presentMention`.
    nonisolated static func mention(title: String,
                                    body: String,
                                    channelID: String,
                                    teamID: String,
                                    serverURL: String,
                                    silent: Bool,
                                    soundName: String? = nil) -> MentionNotification {
        MentionNotification(title: title, body: body, channelID: channelID, teamID: teamID,
                            serverURL: serverURL, silent: silent, soundName: soundName)
    }
}
