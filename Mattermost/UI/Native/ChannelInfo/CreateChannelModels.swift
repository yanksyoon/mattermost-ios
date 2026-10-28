// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/create_or_edit_channel/ (create mode: the type toggle, the display name, the URL
//        name derived from it, `validateDisplayName`, the 64/250/1024 counters),
//        app/screens/home/channel_list/ (the `+` create menu: create a channel / browse channels /
//        create a direct message), app/client/rest/channels.ts (`createChannel` → `POST /channels`),
//        app/utils/channel/index.ts.
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §17; no
// upstream source copied. The SwiftUI decomposition is this repo's own (docs/component-map.md §1).
//
// This file is **pure**: no I/O, no `AuthSession`, no `APIClient`. Every rule the card names as an
// acceptance criterion is here, so a unit test can assert it without a server:
//
//   * the **name rule** — lower-case letters, numbers, `-`/`_`, 1–64 characters, and (measured on
//     9.11.19, scripts/t47_create_channel_probe.py) no leading `-`/`_`; a trailing `-` *is* accepted;
//   * the **URL name derived from the display name**, editable, and never rewritten once edited;
//   * the **ordered create menu**, gated on permission **ids** (`ChannelCreatePermissions.derive`), the
//     same rule `ChannelInfoCapabilities.derive` follows — never a role name;
//   * the `POST /channels` body, as one value.
//
// ## The measured facts these rules rest on (9.11.19, 2026-10-27)
//
//   * `POST /channels` answers **201** with the channel; the creator is added by the server
//     (`GET /channels/{id}/stats` → `member_count: 1`, and the channel is in
//     `GET /users/me/teams/{tid}/channels` with no second call);
//   * the answer carries `creator_id`, `team_id`, `type`, `name`, `display_name`, `purpose`, `header`;
//   * the URL-name refusal is `400 model.channel.is_valid.1_or_more.app_error`,
//     "Name must be 1 or more lowercase alphanumeric character." — measured for upper case, a space, a
//     dot, a leading hyphen, a leading underscore and the empty string;
//   * **65 characters answers 500 `app.channel.create_channel.internal_error`**, not a 400: the server's
//     length check is not reached when the name is otherwise well formed. The client therefore refuses
//     locally at 64 rather than learning it from a server that reports an internal error;
//   * duplicate name → `400 store.sql_channel.save_channel.exists.app_error`,
//     "A channel with that name already exists on the same team.";
//   * display name 64 accepted / 65 refused (`model.channel.is_valid.display_name.app_error`), empty
//     refused (`api.context.invalid_body_param.app_error`); purpose 250 / header 1024, the same limits
//     `ChannelPatchDraft` already models for the edit form;
//   * `type` is `O` or `P`; `D` is refused with
//     `api.channel.create_channel.direct_channel.app_error` ("Must use createDirectChannel API
//     service…"), which is why a direct message is never created through this call.

import Foundation

// MARK: - Permissions

/// The permission ids the create menu and the create form consult.
///
/// Ids, not role names — the same rule T40's `ChannelInfoCapabilities` follows: a server may rewrite a
/// role, so the client asks whether the **id** is in the union of the user's roles.
enum ChannelCreatePermissionID {
    static let createPublicChannel = "create_public_channel"
    static let createPrivateChannel = "create_private_channel"
    static let createDirectChannel = "create_direct_channel"
}

/// What the signed-in user may start, derived from the server's permission ids.
struct ChannelCreatePermissions: Equatable, Sendable {
    var canCreatePublic: Bool
    var canCreatePrivate: Bool
    var canBrowse: Bool
    var canCreateDirectMessage: Bool

    /// Nothing is possible. The **closed** default: a menu drawn before the permission answer arrives
    /// must not offer an action the model would then refuse.
    static let none = ChannelCreatePermissions(canCreatePublic: false,
                                               canCreatePrivate: false,
                                               canBrowse: false,
                                               canCreateDirectMessage: false)

    /// - Parameter permissions: the union of my system + team roles' permission ids
    ///   (`ChannelPermissions.union(roles:)`). There is no channel role to add here: a channel that does
    ///   not exist yet has no membership.
    static func derive(from permissions: Set<String>) -> ChannelCreatePermissions {
        ChannelCreatePermissions(
            canCreatePublic: permissions.contains(ChannelCreatePermissionID.createPublicChannel),
            canCreatePrivate: permissions.contains(ChannelCreatePermissionID.createPrivateChannel),
            canBrowse: permissions.contains(ChannelPermissionID.listTeamChannels),
            canCreateDirectMessage: permissions.contains(ChannelCreatePermissionID.createDirectChannel))
    }

    /// Whether one channel kind may be created (`.open`/`.privateChannel`; a DM is not created here).
    func canCreate(_ kind: ChannelInfoKind) -> Bool {
        switch kind {
        case .open: return canCreatePublic
        case .privateChannel: return canCreatePrivate
        case .direct, .group: return false
        }
    }

    var canCreateAnyChannel: Bool { canCreatePublic || canCreatePrivate }

    /// The kinds the form's toggle may offer, in the order it draws them (public first, as upstream's
    /// segmented control does). Empty when the reader may create neither.
    var creatableKinds: [ChannelInfoKind] {
        var kinds: [ChannelInfoKind] = []
        if canCreatePublic { kinds.append(.open) }
        if canCreatePrivate { kinds.append(.privateChannel) }
        return kinds
    }
}

// MARK: - The create menu

/// The three entries of the channel list's create menu, in the order they are drawn.
enum ChannelCreateMenuActionID: String, Equatable, Sendable, CaseIterable {
    case createChannel
    case browseChannels
    case createDirectMessage

    /// The row's copy. (This repo's wording: upstream's strings live in its translation files and are
    /// not asserted here — see docs/t47-build-note.md.)
    var title: String {
        switch self {
        case .createChannel: return "Create a channel"
        case .browseChannels: return "Browse channels"
        case .createDirectMessage: return "Create a direct message"
        }
    }

    var systemImage: String {
        switch self {
        case .createChannel: return "plus.bubble"
        case .browseChannels: return "magnifyingglass.circle"
        case .createDirectMessage: return "envelope"
        }
    }

    /// The stable identifier the menu row carries (`nativeSidebarCreate.<id>`).
    var identifier: String { "nativeSidebarCreate.\(rawValue)" }
}

/// The ordered menu, derived. One list, so "a user with no create permission is offered nothing" is an
/// assertion about the whole menu rather than about one row somebody remembered to check.
enum ChannelCreateMenu {

    /// - Parameter permissions: the server's answer for this user and team.
    ///
    /// A row is offered only when the action behind it is performable **and** has somewhere to go:
    /// `createChannel` needs one of the two create ids; `browseChannels` needs `list_team_channels`;
    /// `createDirectMessage` needs `create_direct_channel`.
    static func orderedActions(for permissions: ChannelCreatePermissions) -> [ChannelCreateMenuActionID] {
        var actions: [ChannelCreateMenuActionID] = []
        if permissions.canCreateAnyChannel { actions.append(.createChannel) }
        if permissions.canBrowse { actions.append(.browseChannels) }
        if permissions.canCreateDirectMessage { actions.append(.createDirectMessage) }
        return actions
    }
}

// MARK: - The name rule

/// The server's URL-name rule, ported from the measurements at the top of this file.
///
/// Stated as a rule, not as a regex, because the three clauses fail for different reasons and the form's
/// sentence should say which one: length, characters, and a leading separator.
enum ChannelNameRule {
    /// `Channel.MAX_CHANNEL_NAME_LENGTH` upstream. 64 accepted, 65 → 500 (measured).
    static let maxLength = 64
    static let minLength = 1

    private static let allowedScalars: Set<Unicode.Scalar> = {
        var set = Set<Unicode.Scalar>()
        for scalar in "abcdefghijklmnopqrstuvwxyz0123456789-_".unicodeScalars { set.insert(scalar) }
        return set
    }()

    static func isAllowed(_ scalar: Unicode.Scalar) -> Bool { allowedScalars.contains(scalar) }

    /// Whether the server would accept this name.
    static func isValid(_ name: String) -> Bool {
        validationMessage(for: name) == nil
    }

    /// The reader-facing reason the name would be refused, or `nil` when it is acceptable.
    static func validationMessage(for name: String) -> String? {
        if name.isEmpty {
            return "A URL name is required. Use lowercase letters, numbers, hyphens or underscores."
        }
        if name.unicodeScalars.count > maxLength {
            return "The URL name must be \(maxLength) characters or fewer."
        }
        if let offending = name.unicodeScalars.first(where: { !isAllowed($0) }) {
            return "The URL name cannot contain “\(String(Character(offending)))”. "
                + "Use lowercase letters, numbers, hyphens or underscores."
        }
        if let first = name.unicodeScalars.first, first == "-" || first == "_" {
            return "The URL name cannot start with a hyphen or underscore."
        }
        return nil
    }

    /// The URL name suggested for a display name.
    ///
    /// Diacritics are folded first (`Café` → `cafe`) so a name in a language with accents still gets a
    /// usable address; everything else outside the allowed set becomes a single `-` between words, and
    /// the separators are trimmed from both ends (the server refuses a leading one, and a trailing one is
    /// legal but is not how anybody writes a channel address). A display name with **no** usable
    /// characters (`日本語`) yields an empty suggestion — which is an honest "the reader has to type
    /// this", never a made-up name.
    static func makeURLName(fromDisplayName displayName: String) -> String {
        let folded = displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()

        var slug = ""
        var pendingSeparator = false
        for scalar in folded.unicodeScalars {
            if isAllowed(scalar) {
                if pendingSeparator, !slug.isEmpty { slug.append("-") }
                pendingSeparator = false
                slug.unicodeScalars.append(scalar)
            } else {
                // A run of unusable characters is one separator, not one per character.
                pendingSeparator = !slug.isEmpty
            }
        }
        slug = trimSeparators(slug)
        if slug.unicodeScalars.count > maxLength {
            slug = String(String.UnicodeScalarView(slug.unicodeScalars.prefix(maxLength)))
            slug = trimSeparators(slug)
        }
        return slug
    }

    /// Strip leading `-`/`_` and trailing `-` (the two shapes the server refuses / nobody writes).
    private static func trimSeparators(_ value: String) -> String {
        var trimmed = value
        while let first = trimmed.unicodeScalars.first, first == "-" || first == "_" {
            trimmed.removeFirst()
        }
        while let last = trimmed.last, last == "-" {
            trimmed.removeLast()
        }
        return trimmed
    }
}

// MARK: - Draft

/// The create form's fields, the server's limits, and the `POST /channels` body.
///
/// A **draft**, like `ChannelPatchDraft`: the view holds no rules, and the body is derived here so the
/// call site cannot assemble a different shape.
struct ChannelCreateDraft: Equatable, Sendable {
    var displayName: String
    /// The URL name. Derived from the display name until the reader types it (`urlNameEdited`).
    var urlName: String
    /// Whether the reader has typed the URL name. Once true, the display name stops rewriting it — a
    /// reader who deliberately chose an address must not have it changed under them by a further edit.
    var urlNameEdited: Bool
    var purpose: String
    var header: String
    /// `.open` or `.privateChannel`.
    var kind: ChannelInfoKind

    /// The same limits the edit form models (`ChannelPatchDraft`), because it is the same server field.
    static let maxDisplayNameLength = ChannelPatchDraft.maxDisplayNameLength
    static let maxPurposeLength = ChannelPatchDraft.maxPurposeLength
    static let maxHeaderLength = ChannelPatchDraft.maxHeaderLength

    init(displayName: String = "",
         urlName: String = "",
         urlNameEdited: Bool = false,
         purpose: String = "",
         header: String = "",
         kind: ChannelInfoKind = .open) {
        self.displayName = displayName
        self.urlName = urlName
        self.urlNameEdited = urlNameEdited
        self.purpose = purpose
        self.header = header
        self.kind = kind
    }

    // MARK: Field edits

    /// Type into the display name. Rewrites the URL name while the reader has not claimed it.
    mutating func setDisplayName(_ value: String) {
        displayName = value
        if !urlNameEdited {
            urlName = ChannelNameRule.makeURLName(fromDisplayName: value)
        }
    }

    /// Type into the URL name: from now on it belongs to the reader.
    mutating func setURLName(_ value: String) {
        urlName = value
        urlNameEdited = true
    }

    /// The suggestion for the current display name, whether or not the reader has claimed the field.
    var suggestedURLName: String { ChannelNameRule.makeURLName(fromDisplayName: displayName) }

    /// Whether the URL name still follows the display name (the form's "regenerate" affordance).
    var isURLNameDerived: Bool { !urlNameEdited }

    // MARK: Validation

    /// The reason this draft cannot be sent, or `nil`. Order: permission (the security gate), then the
    /// display name (upstream's `validateDisplayName`), then the URL name, then the two long fields.
    func validation(permissions: ChannelCreatePermissions) -> String? {
        guard permissions.canCreate(kind) else {
            return kind == .privateChannel
                ? "You do not have permission to create private channels on this team."
                : "You do not have permission to create public channels on this team."
        }
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedDisplayName.isEmpty { return "A channel name is required." }
        if displayName.unicodeScalars.count > Self.maxDisplayNameLength {
            return "The name must be \(Self.maxDisplayNameLength) characters or fewer."
        }
        if let nameProblem = ChannelNameRule.validationMessage(for: urlName) { return nameProblem }
        if purpose.unicodeScalars.count > Self.maxPurposeLength {
            return "The purpose must be \(Self.maxPurposeLength) characters or fewer."
        }
        if header.unicodeScalars.count > Self.maxHeaderLength {
            return "The header must be \(Self.maxHeaderLength) characters or fewer."
        }
        return nil
    }

    func canSubmit(permissions: ChannelCreatePermissions) -> Bool {
        validation(permissions: permissions) == nil
    }

    /// The request body. Only call it on a draft that validated: `POST /channels` refuses an empty URL
    /// name with a 400, and a 65-character one with a **500**.
    func body(teamID: String) -> MMChannelCreate {
        MMChannelCreate(teamID: teamID,
                        name: urlName,
                        displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                        type: kind.createType ?? ChannelInfoKind.open.rawValue,
                        purpose: purpose,
                        header: header)
    }
}

extension ChannelInfoKind {
    /// The `type` a create request may carry. `nil` for a DM/GM: those are created by
    /// `POST /channels/direct`, and `POST /channels` refuses a `D` outright (measured).
    var createType: String? {
        switch self {
        case .open: return "O"
        case .privateChannel: return "P"
        case .direct, .group: return nil
        }
    }
}

// MARK: - People to message

/// One row of the "create a direct message" picker.
struct DirectMessageCandidate: Identifiable, Equatable, Sendable {
    var id: String
    var displayName: String
    var username: String
    var initials: String
    var status: String

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

/// The picker's rows: team members other than me, filtered by a term.
enum DirectMessageDerivation {

    /// - Parameters:
    ///   - users: `GET /users?in_team={tid}` (the opening list) or `POST /users/search` (a term).
    ///   - statuses: `POST /users/status/ids`; a missing status is "unknown", never "offline".
    ///   - myUserID: my own row is never offered — a conversation with myself is not what the entry
    ///     means.
    ///   - term: matched against the display name **and** the username, because a reader who knows
    ///     `@alice` types that.
    static func rows(users: [MMUser],
                     statuses: [String: MMStatus],
                     myUserID: String?,
                     term: String) -> [DirectMessageCandidate] {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidates = users
            .filter { $0.id != myUserID }
            .filter { user in
                guard !needle.isEmpty else { return true }
                let displayName = PostListDerivation.displayName(for: user)
                return displayName.lowercased().contains(needle)
                    || user.username.lowercased().contains(needle)
            }
            .map { user -> DirectMessageCandidate in
                let displayName = PostListDerivation.displayName(for: user)
                return DirectMessageCandidate(id: user.id,
                                              displayName: displayName,
                                              username: user.username,
                                              initials: ChannelMemberDerivation.initials(displayName),
                                              status: statuses[user.id]?.status ?? "")
            }
        return candidates.sorted { lhs, rhs in
            let comparison = lhs.displayName.compare(rhs.displayName,
                                                      options: [.caseInsensitive, .diacriticInsensitive])
            if comparison == .orderedSame { return lhs.username < rhs.username }
            return comparison == .orderedAscending
        }
    }
}
