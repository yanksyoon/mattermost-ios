// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/queries/servers/role.ts (observeCanManageChannelMembers / observeCanManageChannelSettings /
//        canLeave / canArchive / canUnarchive), app/screens/channel_info/index.ts (the same rules,
//        assembled for the screen), app/screens/channel_settings/index.ts, app/utils/role/index.ts
//        (`hasPermission` = union of the roles' `permissions`), app/utils/channel/index.ts
//        (isDefaultChannel / isDMorGM / validateDisplayName),
//        app/components/channel_actions/leave_channel_label/leave_channel_label.tsx (the DM/GM close
//        copy and the preference write it performs), app/screens/channel_settings/archive/archive.tsx
//        (archive/unarchive copy), app/screens/channel_settings/convert_private.tsx,
//        app/screens/manage_channel_members/manage_channel_members.tsx (`sortUsers`),
//        app/screens/channel_add_members/channel_add_members.tsx,
//        app/screens/browse_channels/browse_channels.tsx.
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §17; no
// upstream source copied. SwiftUI decomposition is this repo's own (docs/component-map.md §1).
//
// This file is **pure**: no I/O, no `AuthSession`, no `APIClient`. Every rule the card states as an
// acceptance criterion lives here so a unit test can assert it without a server:
//
//   * "permission-gated actions are hidden or disabled based on server permissions, not guessed from
//     role names" → `ChannelInfoCapabilities.derive` takes a `Set<String>` of permission ids and never
//     looks at a role name;
//   * "leaving a DM/GM behaves per Mattermost rules" → `ChannelLeavePrompt.make` says which of the two
//     writes the action performs (`DELETE …/members/me` vs the `direct_channel_show` preference);
//   * "joining a public channel from the browser navigates straight into it" →
//     `BrowseChannelsDerivation.joinTarget` answers the id or name the router needs.
//
// The field limits are the server's own, measured on 9.11.19 (docs/t40-build-note.md §2) because a
// client-side limit that disagrees with the server is either a form that cannot be saved or a request
// that comes back 400: purpose 250, header 1024, display name 64.

import Foundation

// MARK: - Channel kind

/// The four channel types, as the API spells them (`O`, `P`, `D`, `G`).
///
/// `MMChannel.type` is a raw `String` on the wire (T28 kept it that way so an unknown type from a newer
/// server could not fail a page), so every rule that cares about the type funnels through this enum
/// rather than comparing strings in three places.
enum ChannelInfoKind: String, Equatable, Sendable, CaseIterable {
    case open = "O"
    case privateChannel = "P"
    case direct = "D"
    case group = "G"

    /// A type this build does not know is treated as a **public** channel: that is the shape whose
    /// gates are the loosest, and a stricter guess would hide an action on a newer server.
    init(raw: String) {
        self = ChannelInfoKind(rawValue: raw) ?? .open
    }

    var isDirectOrGroup: Bool { self == .direct || self == .group }

    /// SF Symbol for the info header, matching upstream's compass icons.
    var glyph: String {
        switch self {
        case .open: return "number"
        case .privateChannel: return "lock"
        case .direct: return "person"
        case .group: return "person.3"
        }
    }

    var typeLabel: String {
        switch self {
        case .open: return "Public channel"
        case .privateChannel: return "Private channel"
        case .direct: return "Direct message"
        case .group: return "Group message"
        }
    }

    /// The noun upstream's archive confirmation substitutes for `{term}`
    /// (`channel_info.public_channel` / `channel_info.private_channel`).
    var archiveTerm: String {
        switch self {
        case .open: return "public channel"
        case .privateChannel: return "private channel"
        case .direct, .group: return "channel"
        }
    }
}

// MARK: - Permission ids

/// The permission ids this surface gates on, quoted from the server and from upstream's
/// `app/constants/permissions.ts`.
///
/// Deliberately a **list of values, not a role-name table**: a server may rename or rewrite a role (the
/// fixture's own `channel_user` carries `delete_public_channel`), so the client asks "does this
/// permission id appear in the union of my roles' `permissions`?" and nothing else.
enum ChannelPermissionID {
    static let managePublicChannelMembers = "manage_public_channel_members"
    static let managePrivateChannelMembers = "manage_private_channel_members"
    static let managePublicChannelProperties = "manage_public_channel_properties"
    static let managePrivateChannelProperties = "manage_private_channel_properties"
    static let deletePublicChannel = "delete_public_channel"
    static let deletePrivateChannel = "delete_private_channel"
    static let convertPublicChannelToPrivate = "convert_public_channel_to_private"
    static let manageTeam = "manage_team"
    static let listTeamChannels = "list_team_channels"
    static let joinPublicChannels = "join_public_channels"
    static let readChannel = "read_channel"

    /// Every id this surface consults. Kept as a list so a test can prove the set is closed (no gate
    /// reads a permission that is not named here).
    static let all: Set<String> = [
        managePublicChannelMembers, managePrivateChannelMembers,
        managePublicChannelProperties, managePrivateChannelProperties,
        deletePublicChannel, deletePrivateChannel,
        convertPublicChannelToPrivate, manageTeam,
        listTeamChannels, joinPublicChannels, readChannel,
    ]
}

/// The channel the UI calls the team's default channel (`town-square`, upstream `General.DEFAULT_CHANNEL`).
///
/// It is special in one place only: it cannot be left (except by a guest) and its **membership** cannot
/// be managed, because everybody in the team belongs to it. Upstream states both rules by name
/// (`isDefaultChannel`), not by `is_default` — the server has no such flag.
enum ChannelDefaults {
    static let defaultChannelName = "town-square"
}

// MARK: - Capabilities (the security-relevant derivation)

/// What the signed-in user may do with one channel, derived **only** from the permissions the server
/// returned for that user's roles.
///
/// Rule-for-rule port of upstream's three observers (see the file header). `derive` is the single place
/// any of these questions is answered: the view hides a row when the flag is false, and the view model
/// refuses the write when the flag is false, so "not offered" and "not performable" cannot disagree.
struct ChannelInfoCapabilities: Equatable, Sendable {
    /// Whether there is a channel at all. `false` is the "nothing loaded yet / no channel" state, which
    /// offers **no** rows — not even the member list, which would otherwise be the one row a screen with
    /// no channel still drew.
    var hasChannel: Bool
    var kind: ChannelInfoKind
    var isArchived: Bool
    /// Add/remove members, and the member list's manage mode.
    var canManageMembers: Bool
    /// Rename / purpose / header.
    var canManageSettings: Bool
    /// Leave the channel (or close a DM/GM).
    var canLeave: Bool
    /// Archive (`DELETE /channels/{id}`).
    var canArchive: Bool
    /// Unarchive (`POST /channels/{id}/restore`).
    var canUnarchive: Bool
    /// The channel browser itself (team-level `list_team_channels`).
    var canBrowseChannels: Bool
    /// Join a public channel from the browser (`join_public_channels`).
    var canJoinPublicChannels: Bool

    /// Nothing is possible: no channel, or no permission data yet.
    ///
    /// Deliberately the *closed* state. A screen that has not finished loading permissions must not
    /// flash an administrator action it will then take away (and, worse, must not offer one it cannot
    /// prove) — so the default answer is "no".
    static let none = ChannelInfoCapabilities(hasChannel: false,
                                              kind: .open,
                                              isArchived: false,
                                              canManageMembers: false,
                                              canManageSettings: false,
                                              canLeave: false,
                                              canArchive: false,
                                              canUnarchive: false,
                                              canBrowseChannels: false,
                                              canJoinPublicChannels: false)

    /// Derive every gate from the server's own permission ids.
    ///
    /// - Parameters:
    ///   - channel: the channel being inspected; `nil` yields `.none`.
    ///   - permissions: the **union** of every role the user holds on this server
    ///     (`system_user`, the team membership's roles and the channel membership's roles). The caller
    ///     builds it with `ChannelPermissions.union(roles:)`; nothing here inspects a role name.
    ///   - isGuest: a guest may leave the default channel (upstream's `canLeave`).
    static func derive(channel: MMChannel?,
                       permissions: Set<String>,
                       isGuest: Bool) -> ChannelInfoCapabilities {
        guard let channel else { return .none }
        let kind = ChannelInfoKind(raw: channel.type)
        let isArchived = channel.deleteAt != 0
        let isDefault = channel.name == ChannelDefaults.defaultChannelName

        let propertiesPermission = kind == .open
            ? ChannelPermissionID.managePublicChannelProperties
            : ChannelPermissionID.managePrivateChannelProperties

        // Upstream `observeCanManageChannelMembers`: no archived channel, no DM/GM, no default channel.
        let canManageMembers = Self.canManageMembers(channel: channel, permissions: permissions)
        // Upstream `observeCanManageChannelSettings`: no archived channel, no DM/GM (the default channel
        // *can* be renamed — the rule does not name it).
        let canManageSettings = !isArchived && !kind.isDirectOrGroup
            && permissions.contains(propertiesPermission)
        // Upstream `canLeave`: everybody but a non-guest member of the default channel.
        let canLeave = !isDefault || isGuest
        // Upstream `canArchive`: never a DM/GM, never an archived channel, and only when leaving is
        // possible at all (archiving the default channel somebody cannot leave is not offered).
        let canArchive = !kind.isDirectOrGroup && !isArchived && canLeave
            && permissions.contains(kind == .open
                                    ? ChannelPermissionID.deletePublicChannel
                                    : ChannelPermissionID.deletePrivateChannel)
        // Upstream `canUnarchive`: an archived, non-DM/GM channel, for a team administrator.
        let canUnarchive = !kind.isDirectOrGroup && isArchived
            && permissions.contains(ChannelPermissionID.manageTeam)

        return ChannelInfoCapabilities(hasChannel: true,
                                       kind: kind,
                                       isArchived: isArchived,
                                       canManageMembers: canManageMembers,
                                       canManageSettings: canManageSettings,
                                       canLeave: canLeave,
                                       canArchive: canArchive,
                                       canUnarchive: canUnarchive,
                                       canBrowseChannels: permissions.contains(ChannelPermissionID.listTeamChannels),
                                       canJoinPublicChannels: permissions.contains(ChannelPermissionID.joinPublicChannels))
    }

    /// The one rule for "may I add or remove members here?", lifted out of `derive` so the
    /// team-scoped Add-to-a-channel picker can apply it **per channel** (`t_8f9f5449` §6: one rule,
    /// two quantifiers — the profile row asks it of ∃ channel in the team, a picker row of that one
    /// channel).
    ///
    /// Upstream `observeCanManageChannelMembers`: never an archived channel, never a DM/GM, never the
    /// team's default channel (everybody in the team belongs to it), and only with the member
    /// permission that matches the channel's visibility.
    static func canManageMembers(channel: MMChannel, permissions: Set<String>) -> Bool {
        let kind = ChannelInfoKind(raw: channel.type)
        guard !kind.isDirectOrGroup else { return false }
        guard channel.deleteAt == 0 else { return false }
        guard channel.name != ChannelDefaults.defaultChannelName else { return false }
        let memberPermission = kind == .open
            ? ChannelPermissionID.managePublicChannelMembers
            : ChannelPermissionID.managePrivateChannelMembers
        return permissions.contains(memberPermission)
    }

    /// Every gated action this screen can draw, in the order the screen draws them. One list, so a test
    /// can assert "a user with no channel permissions is offered nothing" exhaustively instead of
    /// remembering each row.
    var offeredActions: [ChannelInfoActionID] {
        // No channel, nothing to offer. (Every other flag is already closed in that state; the member
        // list is the one row that is not permission-gated, so it needs this check explicitly.)
        guard hasChannel else { return [] }
        var actions: [ChannelInfoActionID] = []
        if canManageMembers { actions.append(.addMembers) }
        actions.append(.members)                       // the member list itself is not gated
        if canManageSettings { actions.append(.settings) }
        if canArchive { actions.append(.archive) }
        if canUnarchive { actions.append(.unarchive) }
        if canLeave { actions.append(.leave) }
        return actions
    }
}

/// The action rows the channel-info screen can draw.
enum ChannelInfoActionID: String, Equatable, Sendable, CaseIterable {
    case addMembers
    case members
    case settings
    case archive
    case unarchive
    case leave

    /// Accessible identifier suffix (`channelInfo.action.<id>`).
    var identifier: String { "channelInfo.action.\(rawValue)" }
}

// MARK: - Permissions union

/// The one place the permission union is computed.
///
/// Upstream `hasPermission(roles, permission)` is `roles.flatMap(\.permissions).contains(permission)`;
/// this is the same fold, with the roles already fetched by name. A role name the server did not answer
/// (a deleted scheme role, a typo in a membership row) simply contributes nothing — it must not fail the
/// whole lookup, and it must never be treated as "all permissions".
enum ChannelPermissions {
    static func union(roles: [MMRole]) -> Set<String> {
        roles.reduce(into: Set<String>()) { result, role in
            result.formUnion(role.permissions)
        }
    }

    /// The role names a user holds for one channel: system roles (`user.roles`), the team membership's
    /// roles and the channel membership's roles. Deduplicated, empty names dropped.
    ///
    /// All three matter: `manage_team` lives on the team membership (`team_admin`), the channel
    /// permissions on the channel membership (`channel_user`/`channel_admin`), and `system_admin` on the
    /// user row. Reading only one of them hides actions the server would allow (measured: an admin whose
    /// channel row says `channel_user` still holds `manage_system` from the user row).
    static func roleNames(systemRoles: String, teamRoles: String, channelRoles: String) -> [String] {
        let names = [systemRoles, teamRoles, channelRoles]
            .flatMap { $0.split(separator: " ").map(String.init) }
        var seen = Set<String>()
        return names.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

// MARK: - Header

/// What the info screen's header shows for one channel.
struct ChannelInfoHeader: Equatable, Sendable {
    var title: String
    var kind: ChannelInfoKind
    var purpose: String
    var header: String
    var isArchived: Bool
    /// `"6 members"`, `"1 member"`, or empty for a DM/GM (upstream shows the people, not a count).
    var membersText: String
    var typeLabel: String

    /// - Parameters:
    ///   - channel: the channel itself (`GET /channels/{id}`).
    ///   - stats: the member count (`GET /channels/{id}/stats`); `nil` until it answers, which draws no
    ///     count rather than a wrong one.
    ///   - fallbackTitle: the title the channel pane already computed (a DM/GM's display name is derived
    ///     from its members, and the server sends an empty `display_name` for a DM).
    static func derive(channel: MMChannel,
                       stats: MMChannelStats?,
                       fallbackTitle: String?) -> ChannelInfoHeader {
        let kind = ChannelInfoKind(raw: channel.type)
        let title = firstNonEmpty([channel.displayName, fallbackTitle, channel.name, "Channel"])
        let membersText: String
        if kind.isDirectOrGroup {
            membersText = ""
        } else if let stats {
            membersText = Self.membersText(count: stats.memberCount)
        } else {
            membersText = ""
        }
        return ChannelInfoHeader(title: title,
                                 kind: kind,
                                 purpose: channel.purpose,
                                 header: channel.header,
                                 isArchived: channel.deleteAt != 0,
                                 membersText: membersText,
                                 typeLabel: kind.typeLabel)
    }

    /// Pluralised the way upstream's `channel_info.members` counter is ("1 member", "N members").
    static func membersText(count: Int64) -> String {
        count == 1 ? "1 member" : "\(count) members"
    }

    private static func firstNonEmpty(_ candidates: [String?]) -> String {
        for candidate in candidates {
            if let candidate, !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return candidate
            }
        }
        return "Channel"
    }
}

// MARK: - Member rows

/// One row of the member list.
struct ChannelMemberRow: Identifiable, Equatable, Sendable {
    var id: String
    var displayName: String
    var username: String
    var isChannelAdmin: Bool
    var isMe: Bool
    /// `online` / `away` / `dnd` / `offline`; empty when the status lookup has not answered.
    var status: String
    var initials: String

    /// The role badge the row draws. Empty for an ordinary member (upstream annotates only the admins).
    var roleLabel: String { isChannelAdmin ? "Channel Admin" : "" }

    /// Accessibility label for the presence dot.
    var statusLabel: String {
        switch status {
        case "online": return "Online"
        case "away": return "Away"
        case "dnd": return "Do not disturb"
        case "offline": return "Offline"
        default: return "Unknown"
        }
    }
}

/// Turns the two API answers a member list needs (membership rows + profiles) into drawable rows.
enum ChannelMemberDerivation {

    /// - Parameters:
    ///   - members: `GET /channels/{id}/members` (ids + roles + `scheme_admin`).
    ///   - users: the profiles for those ids (`POST /users/ids`); a missing profile falls back to the id,
    ///     never to a made-up name.
    ///   - statuses: `POST /users/status/ids`; missing means "unknown", not "offline".
    ///   - myUserID: marks the reader's own row.
    ///
    /// Order is upstream's `sortUsers`: the display name, locale-aware and case-insensitive, with the
    /// username as the tiebreak (two people can share a display name). The reader is **not** moved to the
    /// top: upstream does not, and a list that reorders itself by who is looking is harder to scan.
    static func rows(members: [MMChannelMember],
                     users: [String: MMUser],
                     statuses: [String: MMStatus],
                     myUserID: String?) -> [ChannelMemberRow] {
        let rows = members.map { member -> ChannelMemberRow in
            let user = users[member.userId]
            let displayName = user.map { PostListDerivation.displayName(for: $0) } ?? member.userId
            let username = user?.username ?? ""
            // `scheme_admin` is the server's own flag; the roles string is the fallback for a server
            // that omits it (T33 met the same split on the membership row).
            let isAdmin = member.schemeAdmin
                || member.roles.split(separator: " ").contains(where: { $0 == "channel_admin" })
            return ChannelMemberRow(id: member.userId,
                                    displayName: displayName,
                                    username: username,
                                    isChannelAdmin: isAdmin,
                                    isMe: member.userId == myUserID,
                                    status: statuses[member.userId]?.status ?? "",
                                    initials: initials(displayName))
        }
        return rows.sorted { lhs, rhs in
            let comparison = lhs.displayName.compare(rhs.displayName,
                                                      options: [.caseInsensitive, .diacriticInsensitive])
            if comparison == .orderedSame { return lhs.username < rhs.username }
            return comparison == .orderedAscending
        }
    }

    /// Grapheme-safe initials (T32's `TeamSidebarDerivation.initials` rule, applied to a person): the
    /// first character of the first two words, never a UTF-16 slice.
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "." }).prefix(2)
        let letters = words.compactMap { $0.first }
        if letters.isEmpty { return "?" }
        return String(letters).uppercased()
    }
}

// MARK: - The settings form

/// The editable fields of a channel, with the server's own limits.
///
/// The patch body is derived, never hand-assembled at the call site: a purpose-only edit must send only
/// `purpose` (a `nil` field is omitted by the encoder), and a DM/GM may send `header` and nothing else
/// (upstream's edit form does exactly that — a DM's display name comes from its members).
struct ChannelPatchDraft: Equatable, Sendable {
    var displayName: String
    var purpose: String
    var header: String

    /// `Channel.MAX_CHANNEL_NAME_LENGTH` upstream; the server's own limit, measured
    /// (`model.channel.is_valid.display_name.app_error` at 65 characters).
    static let maxDisplayNameLength = 64
    /// Measured: 251 characters is `model.channel.is_valid.purpose.app_error`.
    static let maxPurposeLength = 250
    /// Measured: 1025 characters is `model.channel.is_valid.header.app_error`.
    static let maxHeaderLength = 1024

    init(displayName: String = "", purpose: String = "", header: String = "") {
        self.displayName = displayName
        self.purpose = purpose
        self.header = header
    }

    /// Start from the channel's current values (the form's initial state).
    init(channel: MMChannel) {
        self.displayName = channel.displayName
        self.purpose = channel.purpose
        self.header = channel.header
    }

    /// The reader-facing error, or `nil` when the draft may be saved.
    ///
    /// Upstream's `validateDisplayName` order: empty → max length. The purpose/header limits are the
    /// server's, so the client refuses the request the server would refuse.
    func validation(for kind: ChannelInfoKind) -> String? {
        if kind.isDirectOrGroup {
            // A DM/GM has no display name to edit; only the header is sent.
            if header.count > Self.maxHeaderLength {
                return "The header must be \(Self.maxHeaderLength) characters or fewer."
            }
            return nil
        }
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty { return "A channel name is required." }
        if displayName.count > Self.maxDisplayNameLength {
            return "The name must be \(Self.maxDisplayNameLength) characters or fewer."
        }
        if purpose.count > Self.maxPurposeLength {
            return "The purpose must be \(Self.maxPurposeLength) characters or fewer."
        }
        if header.count > Self.maxHeaderLength {
            return "The header must be \(Self.maxHeaderLength) characters or fewer."
        }
        return nil
    }

    /// Whether saving would change anything. Save is disabled otherwise (upstream's `canSave`).
    func isDirty(comparedTo channel: MMChannel, kind: ChannelInfoKind) -> Bool {
        if header != channel.header { return true }
        if kind.isDirectOrGroup { return false }
        return displayName != channel.displayName || purpose != channel.purpose
    }

    /// The patch body, or `nil` when nothing changed (in which case no request is sent at all).
    ///
    /// Only the fields that actually changed travel: `PATCH /channels/{id}` treats a field it receives as
    /// "set this value", so echoing an unchanged `header` back would write the same string again — and if
    /// the reader edited only the purpose, that rewrite is a chance to overwrite an edit somebody else
    /// made between this screen's read and this save. A `nil` field is omitted by the synthesized
    /// encoder (never sent as `null`, which the server reads as *empty*).
    func patch(comparedTo channel: MMChannel, kind: ChannelInfoKind) -> MMChannelPatch? {
        guard isDirty(comparedTo: channel, kind: kind) else { return nil }
        if kind.isDirectOrGroup {
            return MMChannelPatch(header: header)
        }
        var patch = MMChannelPatch()
        if displayName != channel.displayName { patch.displayName = displayName }
        if purpose != channel.purpose { patch.purpose = purpose }
        if header != channel.header { patch.header = header }
        return patch
    }
}

// MARK: - Leave / close

/// Which write "leave" performs.
enum ChannelLeaveAction: Equatable, Sendable {
    /// `DELETE /channels/{id}/members/{me}` — a public or private channel.
    case leave
    /// `PUT /users/{me}/preferences` `direct_channel_show` = `false` — a DM or GM is **closed**, not left:
    /// the membership row stays, and the conversation leaves this reader's sidebar only.
    case closeDirectMessage
}

/// The confirmation the leave action shows, with upstream's exact wording per channel type.
struct ChannelLeavePrompt: Equatable, Sendable {
    var title: String
    var message: String
    var confirmTitle: String
    var action: ChannelLeaveAction

    static func make(kind: ChannelInfoKind, displayName: String) -> ChannelLeavePrompt {
        switch kind {
        case .open:
            return ChannelLeavePrompt(
                title: "Leave channel",
                message: "Are you sure you want to leave the public channel \(displayName)? You can always rejoin.",
                confirmTitle: "Leave",
                action: .leave)
        case .privateChannel:
            return ChannelLeavePrompt(
                title: "Leave channel",
                message: "Are you sure you want to leave the private channel \(displayName)? You cannot rejoin the channel unless you're invited again.",
                confirmTitle: "Leave",
                action: .leave)
        case .direct:
            return ChannelLeavePrompt(
                title: "Close direct message",
                message: "Are you sure you want to close this direct message? This will remove it from your home screen, but you can always open it again.",
                confirmTitle: "Close",
                action: .closeDirectMessage)
        case .group:
            return ChannelLeavePrompt(
                title: "Close group message",
                message: "Are you sure you want to close this group message? This will remove it from your home screen, but you can always open it again.",
                confirmTitle: "Close",
                action: .closeDirectMessage)
        }
    }
}

// MARK: - Archive / unarchive

/// The archive and unarchive confirmations (upstream `archive.tsx`).
struct ChannelArchivePrompt: Equatable, Sendable {
    var title: String
    var message: String

    /// - Parameter canViewArchivedChannels: the server's `ExperimentalViewArchivedChannels`. This client
    ///   cannot read it (`GET /config/client` does not carry it — measured, docs/t40-build-note.md §2), so
    ///   it passes `false` and shows the copy that does not promise continued access. That is the honest
    ///   direction to be wrong in: the reader is not told they will keep seeing a channel they may not.
    static func archive(kind: ChannelInfoKind,
                        displayName: String,
                        canViewArchivedChannels: Bool = false) -> ChannelArchivePrompt {
        let term = kind.archiveTerm
        let body = canViewArchivedChannels
            ? "This will archive the channel from the team. Channel contents will still be accessible by channel members.\n\nAre you sure you wish to archive the \(term) \(displayName)?"
            : "This will archive the channel from the team and remove it from the user interface. Archived channels can be unarchived if needed again.\n\nAre you sure you wish to archive the \(term) \(displayName)?"
        return ChannelArchivePrompt(title: "Archive \(term)", message: body)
    }

    static func unarchive(kind: ChannelInfoKind, displayName: String) -> ChannelArchivePrompt {
        let term = kind.archiveTerm
        return ChannelArchivePrompt(title: "Unarchive \(term)",
                                    message: "Are you sure you want to unarchive the \(term) \(displayName)?")
    }
}

// MARK: - The channel browser

/// One row of the browse-channels screen.
struct BrowseChannelEntry: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var displayName: String
    var kind: ChannelInfoKind
    var isMember: Bool
    var isArchived: Bool

    /// What a tap does: nothing for a channel we are already in (the screen navigates instead), a join
    /// for a joinable public channel, and a refusal for an archived one (the server answers 400 to
    /// `addToChannel` on an archived channel — measured in upstream's browse screen comment and
    /// reproduced here as "existing members only").
    var isJoinable: Bool { kind == .open && !isMember && !isArchived }
}

/// The browse-channels derivation: which channels the team has, which of them I am in, and what a term
/// filters out.
enum BrowseChannelsDerivation {

    /// - Parameters:
    ///   - channels: `GET /teams/{tid}/channels` (public channels of the team) merged with
    ///     `GET /teams/{tid}/channels/deleted` when the reader may see archived ones.
    ///   - joined: the ids of my channels (`GET /users/me/teams/{tid}/channels`).
    ///   - term: the search field; matching is diacritic/case-insensitive on the display name **and** the
    ///     URL name, because a reader who knows `#off-topic` types that.
    static func entries(channels: [MMChannel],
                        joined: Set<String>,
                        term: String) -> [BrowseChannelEntry] {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let entries = channels
            .filter { ChannelInfoKind(raw: $0.type) != .direct && ChannelInfoKind(raw: $0.type) != .group }
            .filter { channel in
                guard !needle.isEmpty else { return true }
                return matches(channel, needle: needle)
            }
            .map { channel in
                BrowseChannelEntry(id: channel.id,
                                   name: channel.name,
                                   displayName: channel.displayName.isEmpty ? channel.name : channel.displayName,
                                   kind: ChannelInfoKind(raw: channel.type),
                                   isMember: joined.contains(channel.id),
                                   isArchived: channel.deleteAt != 0)
            }
        return entries.sorted { lhs, rhs in
            let comparison = lhs.displayName.compare(rhs.displayName,
                                                      options: [.caseInsensitive, .diacriticInsensitive])
            if comparison == .orderedSame { return lhs.name < rhs.name }
            return comparison == .orderedAscending
        }
    }

    /// Diacritic- and case-insensitive prefix-or-substring match on the display name or the URL name.
    static func matches(_ channel: MMChannel, needle: String) -> Bool {
        let haystacks = [channel.displayName, channel.name].map { $0.lowercased() }
        return haystacks.contains { $0.contains(needle) || $0.folding(options: [.diacriticInsensitive],
                                                                    locale: nil).contains(needle) }
    }

    /// The two sections the screen draws: the channels I am in, then everything else.
    static func sections(_ entries: [BrowseChannelEntry]) -> (joined: [BrowseChannelEntry],
                                                              others: [BrowseChannelEntry]) {
        (entries.filter(\.isMember), entries.filter { !$0.isMember })
    }

    /// Where a tapped row navigates: the router needs an id **and** a name (the name is what a deep link
    /// would carry), and joining answers the channel that must now be opened.
    struct JoinTarget: Equatable, Sendable {
        var channelID: String
        var channelName: String
        var alreadyMember: Bool
    }

    static func joinTarget(for entry: BrowseChannelEntry) -> JoinTarget {
        JoinTarget(channelID: entry.id, channelName: entry.name, alreadyMember: entry.isMember)
    }
}
