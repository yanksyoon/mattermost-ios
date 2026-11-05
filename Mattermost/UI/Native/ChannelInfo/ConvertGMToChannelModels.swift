// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/convert_gm_to_channel/ (the screen, `convert_gm_to_channel_form`, `message_box`,
//        `no_common_teams_form`, `team_selector`, `channel_name_input`),
//        app/components/channel_actions/convert_to_channel/convert_to_channel_label.tsx (the row and
//        its icon), app/screens/channel_settings/index.ts (the `convertGMOptionAvailable` gate:
//        server ≥ 9.1 && channel type `G` && not a guest),
//        app/actions/remote/channel.ts (`convertGroupMessageToPrivateChannel` → name derived from the
//        display name, then `switchToChannelById`), app/client/rest/channels.ts
//        (`POST /channels/{id}/convert_to_channel?team-id=`).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §25; no
// upstream source copied. SwiftUI decomposition is this repo's own (docs/component-map.md §1).
//
// This file is **pure**: no I/O, no `AuthSession`, no `APIClient`. Everything the card states as an
// acceptance criterion is here, so a unit test can assert it without a server:
//
//   * **the gate** — `ConvertGMToChannelGate.isAvailable` is upstream's `convertGMOptionAvailable`:
//     a group message, a non-guest, not archived, and a server at 9.1 or later;
//   * **the body** — `ConvertGMToChannelDraft.body(channelID:)`, with the URL name derived by
//     `ChannelNameRule` (the very rule `CreateChannelDraft` uses, so the two screens cannot disagree
//     about what a legal channel address is);
//   * **the copy** — the warning that says the history becomes visible to anyone who can join, the
//     member list in it, and the "members are not on the same team" state.
//
// ## What was measured (9.11.19, 2026-11-05, scripts/td088_convert_gm_probe.py)
//
//   * the route is **`POST /channels/{id}/convert_to_channel?team-id={tid}`**, not the `/convert`
//     the card names: `/convert` answers `404 api.context.404.app_error` (measured). The body is
//     `{channel_id, team_id, display_name, name}`;
//   * **200** with the converted channel: `type: "P"`, the **same `id`**, `team_id` set to the target
//     team, `name`/`display_name` as requested. The id survives, which is what makes "navigate into the
//     converted channel" a selection of the channel already open rather than a lookup by name;
//   * `GET /teams/{tid}/channels/name/{name}` answers the same channel, and
//     `GET /users/me/teams/{tid}/channels` contains it — the client's proof that the write landed;
//   * the URL-name rule is the same one `POST /channels` enforces: lower-case letters/digits/`-`/`_`
//     accepted (an underscore in the middle is fine), upper case / space / dot / leading `-` / empty
//     refused with `model.channel.is_valid.1_or_more.app_error`; **65 characters answers 500
//     `app.channel.update_channel.internal_error`** (note: *update*, not create), which is why the
//     client refuses locally at 64;
//   * a taken name answers `400 store.sql_channel.save_channel.exists.app_error` ("A channel with that
//     name already exists on the same team.") — the sentence the form shows against the name field;
//   * a team whose membership does not cover every group member answers `400
//     app.channel.group_message_conversion.incorrect_team`; the `team-id` query is optional (the body's
//     `team_id` is enough) but is sent because that is the documented shape;
//   * a non-group channel answers `400 app.channel.get_common_teams.incorrect_channel_type` ("Channel
//     is not a group message.") — the server's own half of the gate;
//   * **a plain member (`team_user`) converts a group message they are in** (measured 200): there is no
//     channel permission to consult. That is why the gate is membership + type, not a permission id.

import Foundation

// MARK: - The gate

/// Whether "Convert to a private channel" is offered for one conversation.
///
/// Upstream's `convertGMOptionAvailable` is exactly three facts and one version floor. It is **not**
/// derived from a permission id: measured, a plain `team_user` who is in the group message converts it
/// (scripts/td088_convert_gm_probe.py §8), and `POST /channels`'s `create_private_channel` plays no
/// part. The membership is implicit — a reader only sees this screen for a conversation they are in.
enum ConvertGMToChannelGate {
    /// The server release that first answers the route (upstream `isMinimumServerVersion(v, 9, 1)`).
    static let minimumServer = (major: 9, minor: 1)

    /// - Parameters:
    ///   - kind: the conversation's type. Only `.group` may convert; the server refuses everything else
    ///     with `app.channel.get_common_teams.incorrect_channel_type`.
    ///   - isGuest: a guest is not offered the row (upstream `!u.isGuest`), and the server would refuse
    ///     the conversion's team check for them anyway.
    ///   - isArchived: an archived conversation has no conversion to perform.
    ///   - serverVersion: `X-Version-Id` as `major.minor.patch` (see `ServerVersionNumber`). An
    ///     **unreadable** version is treated as available: the version is a feature-availability
    ///     floor, not a security gate, and hiding a working action because one header could not be
    ///     parsed would be the worse error. The write itself is still the server's to refuse.
    static func isAvailable(kind: ChannelInfoKind,
                            isGuest: Bool,
                            isArchived: Bool,
                            serverVersion: String) -> Bool {
        guard kind == .group, !isGuest, !isArchived else { return false }
        guard let version = ServerVersionNumber(serverVersion) else { return true }
        return version.isAtLeast(major: minimumServer.major, minor: minimumServer.minor, patch: 0)
    }
}

/// A parsed `X-Version-Id`, which the server sends on **every** response as
/// `9.11.19.16643067630.729911b468d3b08e14e08ba4871cbc68.false` (measured).
///
/// Only the leading `major.minor.patch` is ordered: the rest is a build id and a Boolean, and comparing
/// those would make two builds of the same release incomparable. Anything unparseable answers `nil` rather
/// than a guess (an enterprise suffix, an empty header from a proxy that stripped it).
struct ServerVersionNumber: Equatable, Comparable, Sendable {
    var major: Int
    var minor: Int
    var patch: Int

    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Drop a leading `v` (git tags carry one) and stop at the first component that is not a number.
        var text = trimmed
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              let major = Int(parts[0]), let minor = Int(parts[1]) else { return nil }
        let patch = parts.count >= 3 ? Int(parts[2]) ?? 0 : 0
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    func isAtLeast(major: Int, minor: Int, patch: Int) -> Bool {
        self >= ServerVersionNumber(major: major, minor: minor, patch: patch)
    }

    private init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: ServerVersionNumber, rhs: ServerVersionNumber) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

// MARK: - The body

/// `POST /channels/{id}/convert_to_channel`'s body, as measured.
///
/// `channel_id` is duplicated in the body and in the path because the server documents both; the body is
/// what the conversion actually reads (measured §6: a request with no `team-id` query but a body
/// `team_id` succeeds).
struct ConvertGMToChannelBody: Encodable, Equatable, Sendable {
    var channelID: String
    var teamID: String
    var displayName: String
    var name: String

    enum CodingKeys: String, CodingKey {
        case name
        case channelID = "channel_id"
        case teamID = "team_id"
        case displayName = "display_name"
    }
}

// MARK: - The draft

/// The form's fields and the derived request.
///
/// The URL name follows the display name until the reader types it (`urlNameEdited`) — the same rule,
/// and the same `ChannelNameRule`, as `ChannelCreateDraft`. Nothing is sent from the view: `body(channelID:)`
/// is the only way to build the request.
struct ConvertGMToChannelDraft: Equatable, Sendable {
    var displayName: String = ""
    /// The URL name. Derived from `displayName` while `urlNameEdited` is false.
    var urlName: String = ""
    /// Whether the reader claimed the URL name. Once true, the display name stops rewriting it.
    var urlNameEdited: Bool = false
    /// The team the converted channel will live in. `nil` until the teams read answers; the screen
    /// preselects the first common team, as upstream's `useState(commonTeams[0])` does.
    var teamID: String?

    /// `Channel.MAX_CHANNEL_NAME_LENGTH`; the same limit the create form uses (measured 64 accepted,
    /// 65 → 500).
    static let maxDisplayNameLength = 64

    // MARK: Edits

    /// Type into the name. Rewrites the URL name while the reader has not claimed it.
    mutating func setDisplayName(_ value: String) {
        displayName = value
        if !urlNameEdited { urlName = ChannelNameRule.makeURLName(fromDisplayName: value) }
    }

    /// Type into the URL name: from now on it belongs to the reader.
    mutating func setURLName(_ value: String) {
        urlName = value
        urlNameEdited = true
    }

    /// The suggestion the form draws under the name field.
    var suggestedURLName: String { ChannelNameRule.makeURLName(fromDisplayName: displayName) }

    // MARK: Validation

    /// The reader-facing reason the draft cannot be sent, or `nil`.
    ///
    /// Order: a team is required (there is no default target team), then the display name (non-empty,
    /// 64 characters — the server's own limit), then the URL name by `ChannelNameRule`.
    func validation(teams: [MMTeam]) -> String? {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "A channel name is required." }
        if displayName.unicodeScalars.count > Self.maxDisplayNameLength {
            return "The name must be \(Self.maxDisplayNameLength) characters or fewer."
        }
        if let teamID, !teamID.isEmpty {
            guard teams.contains(where: { $0.id == teamID }) else {
                return "Choose a team the group's members all belong to."
            }
        } else {
            return "Choose a team for the new channel."
        }
        if let nameProblem = ChannelNameRule.validationMessage(for: urlName) { return nameProblem }
        return nil
    }

    func canSubmit(teams: [MMTeam]) -> Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && validation(teams: teams) == nil
    }

    /// The request body. Only call it on a validated draft: a malformed `name` answers 400, and a
    /// 65-character one answers a **500** (measured).
    func body(channelID: String) -> ConvertGMToChannelBody {
        ConvertGMToChannelBody(channelID: channelID,
                               teamID: teamID ?? "",
                               displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                               name: urlName)
    }
}

// MARK: - Copy

/// The words the screen shows, per state.
enum ConvertGMToChannelCopy {
    /// The warning header (upstream `channel_info.convert_gm_to_channel.warning.header`).
    static let warningHeader = "Conversation history will be visible to any channel members"

    /// The warning body, with the other members named. `memberNames` is formatted by `list(_:)`.
    static func warningBody(memberNames: [String]) -> String {
        "You are about to convert the Group Message with \(list(memberNames)) to a Channel. "
            + "This cannot be undone."
    }

    /// Upstream's `formatList` for the people in the conversation: `yourself` when the list is empty,
    /// `A`, `A and B`, `A, B and C`. The reader's own row is not in `memberNames` (upstream filters
    /// `currentUserId` out before formatting), so "yourself" is what a two-person conversation shows.
    static func list(_ names: [String]) -> String {
        let spoken = names.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        switch spoken.count {
        case 0: return "yourself"
        case 1: return spoken[0]
        case 2: return "\(spoken[0]) and \(spoken[1])"
        default:
            return spoken.dropLast().joined(separator: ", ") + " and " + (spoken.last ?? "")
        }
    }

    /// The "no team in common" state (upstream `no_common_teams_form`).
    static let noCommonTeamsHeader =
        "Unable to convert to a channel because group members are part of different teams"
    static let noCommonTeamsBody =
        "Group Message cannot be converted to a channel because members are not a part of the same team. "
        + "Add all members to a single team to convert this group message to a channel."

    /// The row's label (upstream `channel_info.convert_gm_to_channel`).
    static let actionTitle = "Convert to a private channel"

    /// The confirmation the button carries while the write is in flight.
    static let convertingTitle = "Converting…"

    /// The failure sentence when the server answered nothing usable (upstream
    /// `channel_info.convert_gm_to_channel.conversion_error`).
    static let conversionFailed =
        "Something went wrong. Failed to convert Group Message to Private Channel."

    /// The refusal this client adds: the screen was asked to convert something the gate closes.
    static let refused = "Only a group message can be converted to a channel."
}

// MARK: - Failure copy

/// Which control a failed conversion's sentence belongs under.
///
/// Upstream puts the duplicate name under the name field (`isServerError && DUPLICATE_CHANNEL_NAME`)
/// and everything else in one error line. This client's `MMError` carries the status and the server's
/// human message but not its `id` (`app/client/rest/error.ts`'s `server_error_id` is not modelled), so
/// the classification reads the two sentences the server actually sends — both measured:
/// `A channel with that name already exists on the same team.` and `The specified team ID in conversion
/// request does not contain all the group message members`.
enum ConvertGMToChannelFailure {
    enum Field: Equatable, Sendable {
        case name
        case team
        /// The screen's own error line.
        case banner
    }

    struct Answer: Equatable, Sendable {
        var field: Field
        var message: String
    }

    static func classify(_ error: Error) -> Answer {
        if case .client(let status, let message) = error as? MMError ?? .notFound,
           status == 400, let message, !message.isEmpty {
            let lower = message.lowercased()
            if lower.contains("already exists") {
                return Answer(field: .name, message: message)
            }
            if lower.contains("group message members") || lower.contains("all the group") {
                return Answer(field: .team,
                              message: "The group's members do not all belong to that team. Pick a team "
                                  + "they all are in, or add them to one first.")
            }
            if lower.contains("not a group message") {
                return Answer(field: .banner, message: ConvertGMToChannelCopy.refused)
            }
            return Answer(field: .banner, message: message)
        }
        return Answer(field: .banner,
                      message: MMErrorCopy.message(
                          for: error,
                          offline: "You appear to be offline. The conversation was not converted.",
                          timeout: "The server took too long to answer. The conversation was not converted.",
                          unauthorized: "Your session has expired. Sign in again to convert this conversation.",
                          forbidden: "You do not have permission to convert this conversation.",
                          notFound: "This conversation no longer exists.",
                          rateLimited: "The server is busy. Try again shortly.",
                          fallback: ConvertGMToChannelCopy.conversionFailed))
    }
}

// MARK: - Where the screen lands

/// The channel the screen navigates into after a conversion.
///
/// The **id does not change** (measured), so this is the conversation already open — now a private
/// channel in `teamID`. The name travels with it because a route carries both keys and a sidebar row
/// that arrives from a socket may not have the new name yet.
struct ConvertedChannelTarget: Equatable, Sendable {
    var channelID: String
    var channelName: String
    var teamID: String

    /// - Parameter channel: the server's answer to the conversion.
    /// - Returns: `nil` when the answer is not a private channel. Navigating to a conversation the server
    ///   did not convert would be a lie, so the caller reports the failure instead (the same rule as
    ///   `ChannelCreateViewModel.create()` checking the answered type).
    init?(channel: MMChannel, requestedTeamID: String) {
        guard !channel.id.isEmpty, channel.type == ChannelInfoKind.privateChannel.rawValue else {
            return nil
        }
        self.channelID = channel.id
        self.channelName = channel.name
        self.teamID = channel.teamId.isEmpty ? requestedTeamID : channel.teamId
    }
}
