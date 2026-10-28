// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: ios/Gekidou/Sources/Gekidou/DataTypes/Role.swift (the stored role row),
//        types/api/roles.d.ts (`Role`), app/client/rest/channels.ts (`getChannelStats`,
//        `patchChannel`, `getChannelMember`, `addToChannel`, `removeFromChannel`, `getChannels`,
//        `getArchivedChannels`), app/client/rest/users.ts (`getProfilesNotInChannel`),
//        app/constants/permissions.ts (the permission ids).
// Licence: Apache-2.0 (upstream LICENSE.txt) — reimplemented against https://api.mattermost.com per
// docs/path-b-adr.md §3, with attribution in docs/THIRD_PARTY_NOTICES.md §17. No upstream source is
// copied.
//
// Why these live in Core/MM rather than in the screen's own folder: they are wire shapes (the decoded
// body of a documented endpoint), and the screen card that consumes them is only one of the future
// callers (`ChannelInfoAPI` today, a member picker in T41's profile popover tomorrow). T39's
// `MMSearchResults` and T36's `MMThreadTypes` are the same precedent.
//
// Every shape here was measured against the pinned 9.11.19 server on 2026-10-26 (docs/t40-build-note.md
// §2); nothing is taken from a type definition alone.

import Foundation

/// One server role (`GET /roles/name/{name}`, `POST /roles/names`).
///
/// The **`permissions` array is the client's only gating source** (card T40): role *names* are
/// configuration a server administrator can rewrite, and this app must never infer a capability from
/// `name == "channel_admin"`. Measured on 9.11.19: the `channel_user` role of the local fixture carries
/// `manage_public_channel_members` and `delete_public_channel`, i.e. a role whose *name* says "user"
/// grants administrator actions on that server — a client that gated on the name would hide actions
/// the server allows, and (worse) a server that narrowed the role would still be shown the actions.
struct MMRole: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var displayName: String
    var description: String
    /// The permission ids the role grants (`manage_public_channel_members`, `read_channel`, …).
    var permissions: [String]
    /// `true` when the role belongs to a scheme rather than the built-in set.
    var schemeManaged: Bool
    var builtIn: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, description, permissions
        case displayName = "display_name"
        case schemeManaged = "scheme_managed"
        case builtIn = "built_in"
    }

    init(id: String,
         name: String = "",
         displayName: String = "",
         description: String = "",
         permissions: [String] = [],
         schemeManaged: Bool = false,
         builtIn: Bool = false) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.description = description
        self.permissions = permissions
        self.schemeManaged = schemeManaged
        self.builtIn = builtIn
    }

    /// Tolerant decoding, like every other model in this file's neighbourhood: a server that omits a
    /// field must not fail the whole permission lookup (a failed lookup would hide every gated action).
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        displayName = try values.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        description = try values.decodeIfPresent(String.self, forKey: .description) ?? ""
        permissions = try values.decodeIfPresent([String].self, forKey: .permissions) ?? []
        schemeManaged = try values.decodeIfPresent(Bool.self, forKey: .schemeManaged) ?? false
        builtIn = try values.decodeIfPresent(Bool.self, forKey: .builtIn) ?? false
    }
}

/// `GET /channels/{channel_id}/stats` — the channel's own counters.
///
/// Measured on 9.11.19: `{channel_id, member_count, guest_count, pinnedpost_count, files_count}`. The
/// channel object itself carries **no** member count, so this endpoint is the only honest source for
/// the "6 members" line in the info header (`GET /channels/{id}/members` would mean downloading every
/// row to count them).
struct MMChannelStats: Codable, Equatable, Sendable {
    var channelID: String
    var memberCount: Int64
    var guestCount: Int64
    var pinnedPostCount: Int64
    var filesCount: Int64

    enum CodingKeys: String, CodingKey {
        case channelID = "channel_id"
        case memberCount = "member_count"
        case guestCount = "guest_count"
        case pinnedPostCount = "pinnedpost_count"
        case filesCount = "files_count"
    }

    init(channelID: String = "",
         memberCount: Int64 = 0,
         guestCount: Int64 = 0,
         pinnedPostCount: Int64 = 0,
         filesCount: Int64 = 0) {
        self.channelID = channelID
        self.memberCount = memberCount
        self.guestCount = guestCount
        self.pinnedPostCount = pinnedPostCount
        self.filesCount = filesCount
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        channelID = try values.decodeIfPresent(String.self, forKey: .channelID) ?? ""
        memberCount = try values.decodeIfPresent(Int64.self, forKey: .memberCount) ?? 0
        guestCount = try values.decodeIfPresent(Int64.self, forKey: .guestCount) ?? 0
        pinnedPostCount = try values.decodeIfPresent(Int64.self, forKey: .pinnedPostCount) ?? 0
        filesCount = try values.decodeIfPresent(Int64.self, forKey: .filesCount) ?? 0
    }
}

/// The body of `PUT /channels/{channel_id}/patch` (card S10/S22: rename, purpose, header).
///
/// Every field is optional so that a **purpose-only** edit does not rewrite the header: the synthesised
/// encoder emits `encodeIfPresent`, i.e. a `nil` field is absent from the JSON rather than `null`, which
/// matters because Mattermost treats a present `null` as "set this field to empty".
///
/// Upstream's edit form (`app/screens/create_or_edit_channel/create_or_edit_channel.tsx`) sends exactly
/// `{display_name, purpose, header}` for a channel and `{header}` alone for a DM/GM — a DM's display
/// name is derived from its members and cannot be patched.
struct MMChannelPatch: Codable, Equatable, Sendable {
    var displayName: String?
    /// The URL name. Upstream's edit form never sends it (it is the channel's address, and renaming it
    /// breaks every link to the channel), so this client does not either — the field exists because
    /// the endpoint accepts it and a future card may gate it behind a system-admin check.
    var name: String?
    var purpose: String?
    var header: String?

    enum CodingKeys: String, CodingKey {
        case name, purpose, header
        case displayName = "display_name"
    }

    init(displayName: String? = nil, name: String? = nil, purpose: String? = nil, header: String? = nil) {
        self.displayName = displayName
        self.name = name
        self.purpose = purpose
        self.header = header
    }

    /// Whether the patch would change anything (an empty patch is not sent at all).
    var isEmpty: Bool {
        displayName == nil && name == nil && purpose == nil && header == nil
    }
}

/// A page of channel memberships. The endpoint answers a bare array, so this is only a typealias with
/// a name for the paging rule the view model applies (`count == perPage` ⇒ there may be more).
typealias MMChannelMemberPage = [MMChannelMember]

/// The body of `POST /channels` — creating a public or private channel.
///
/// Every field is required by the server: an empty `display_name` answers
/// `400 api.context.invalid_body_param.app_error` (measured), and a `name` that is empty or malformed
/// answers `400 model.channel.is_valid.1_or_more.app_error`. Only `type` `O`/`P` is accepted here —
/// `D` is refused with `api.channel.create_channel.direct_channel.app_error`, because a direct message
/// is `POST /channels/direct`'s job.
///
/// The creator's membership is **the server's** to add: `POST /channels` answers 201 and
/// `GET /channels/{id}/stats` reports `member_count: 1` (measured on 9.11.19), so the client sends no
/// second membership write.
struct MMChannelCreate: Encodable, Equatable, Sendable {
    var teamID: String
    var name: String
    var displayName: String
    var type: String
    var purpose: String
    var header: String

    enum CodingKeys: String, CodingKey {
        case name, type, purpose, header
        case teamID = "team_id"
        case displayName = "display_name"
    }

    init(teamID: String,
         name: String,
         displayName: String,
         type: String,
         purpose: String = "",
         header: String = "") {
        self.teamID = teamID
        self.name = name
        self.displayName = displayName
        self.type = type
        self.purpose = purpose
        self.header = header
    }
}

/// `GET /users/me` reduced to the fields a permission decision needs.
///
/// Deliberately **not** `MMUser`: that model is the *rendering* user (name, nickname, avatar), it carries
/// no `roles`, and the SQLite `users` table does not persist roles — so loading a user from the store
/// would silently answer "no roles" and every gated action would disappear. A dedicated wire shape keeps
/// the permission path on the network where the answer is authoritative, and keeps a screen that draws a
/// name from depending on a permission field it does not use.
struct MMPrincipal: Codable, Equatable, Sendable {
    var id: String
    var username: String
    /// Space-separated role names, e.g. `system_user system_admin`.
    var roles: String
    var deleteAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, username, roles
        case deleteAt = "delete_at"
    }

    init(id: String = "", username: String = "", roles: String = "", deleteAt: Int64 = 0) {
        self.id = id
        self.username = username
        self.roles = roles
        self.deleteAt = deleteAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? ""
        username = try values.decodeIfPresent(String.self, forKey: .username) ?? ""
        roles = try values.decodeIfPresent(String.self, forKey: .roles) ?? ""
        deleteAt = try values.decodeIfPresent(Int64.self, forKey: .deleteAt) ?? 0
    }

    var roleNames: [String] { roles.split(separator: " ").map(String.init) }

    /// `system_guest` is the server's own marker; a guest may leave the default channel, which is the
    /// one place the guest distinction changes a gate (`ChannelInfoCapabilities.derive`).
    var isGuest: Bool { roleNames.contains("system_guest") }
}

/// The body of `PUT /users/{user_id}/preferences` for the DM/GM "close" write.
///
/// This is the Mattermost rule the card's second acceptance criterion names: **a DM or a GM is closed,
/// not left.** Upstream (`app/components/channel_actions/leave_channel_label/leave_channel_label.tsx`)
/// calls `setDirectChannelVisible(serverUrl, channelId, false)` for `D`/`G`, which writes the
/// `direct_channel_show` preference; the membership row is left alone (measured: after the write the
/// channel still has both members). Writing a `DELETE /channels/{id}/members/{me}` for a DM would
/// remove the *conversation* from the other person's sidebar as well, which is not what "Close direct
/// message" means.
enum MMDirectChannelVisibility {
    /// The preference category the server stores the DM/GM visibility under.
    static let category = "direct_channel_show"

    static func preference(userID: String, channelID: String, visible: Bool) -> MMPreference {
        MMPreference(userId: userID, category: category, name: channelID, value: visible ? "true" : "false")
    }
}
