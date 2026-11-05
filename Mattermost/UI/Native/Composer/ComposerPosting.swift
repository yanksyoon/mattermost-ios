// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/components/post_draft/post_draft.tsx (the precedence: an archived channel first, then a
//        read-only membership, and only then the draft input), app/components/post_draft/index.ts
//        (the derivation: `channel.deleteAt !== 0`, `observeIsReadOnlyChannel`,
//        `observePermissionForChannel(… CREATE_POST, true)`), app/queries/servers/channel.ts
//        (`observeIsReadOnlyChannel`), app/queries/servers/role.ts (`observePermissionForChannel`),
//        app/utils/role/index.ts (`hasPermission` = the union of the roles' `permissions`),
//        app/components/post_draft/archived/index.tsx and
//        app/components/post_draft/read_only/index.tsx (the copy each banner draws).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §12; no
// upstream source copied.
//
// ## What this file is for
//
// Upstream decides "may I post here?" in the observable that feeds `PostDraft`, and then *replaces
// the whole composer* with a banner when the answer is no — so a reader in an archived channel never
// gets an input whose Send can only fail. This build had the input and no state at all
// (`ComposerView.swift`'s header said so outright: no archived-channel state, no read-only
// membership), which is the defect kanban t_03411e94 is about.
//
// The answer is one enum, derived from **two facts the server owns** and nothing else:
//
//   * the channel's `delete_at` (`GET /channels/{id}`) — non-zero means archived;
//   * the permission ids of the roles the signed-in user holds **on that channel, its team and the
//     server** (`POST /roles/names` over `user.roles` + the team membership's roles + the channel
//     membership's roles) — `create_post` present or not.
//
// Role *names* are never inspected, exactly as everywhere else in this client (T40's rule): a server
// administrator can rewrite a scheme, and `channel_user` on the local 9.11.19 fixture already carries
// administrator permissions.
//
// ## The two upstream triggers this does **not** model, and why
//
// 1. `deactivatedChannel` — a DM whose other participant has `delete_at != 0` draws the *archived*
//    banner with different copy ("… with a deactivated user"). Deciding it needs the other member's
//    profile `delete_at`, which is a third read on a DM's composer open; the archived copy itself is
//    still drawn when the channel is archived, and a deactivated DM's channel is not archived. Left
//    out deliberately rather than guessed at, and named here so the next reader sees the gap.
// 2. `channelIsReadOnly` — `ExperimentalTownSquareIsReadOnly` turned on for the team's default
//    channel, for a non-admin. It is a *config* flag (`/config/client`) and the same permission union
//    below already answers the case that matters in practice: with that flag on, the server removes
//    `create_post` from `channel_user`, so `.readOnly` is still derived — from the permission the
//    server enforces, not from a config document this client would have to keep in step.
//
// ## Why `permissions == nil` reads as "open"
//
// Upstream reads roles from its local database, so "not loaded yet" is a frame, not a state. This
// client has no wired store: the facts come from the server, and a failed lookup is **not** a denial
// (the same rule the typing transport states for `/config/client`). A composer that went read-only
// on a dropped `POST /roles/names` would refuse to write in a channel the server would happily accept
// — the defect this card fixes, in the other direction. So an unanswered lookup leaves the composer
// open and the send reaches the server, whose refusal is drawn by the failure banner as before.

import Foundation

// MARK: - The state

/// Whether the composer may post in this channel, and — when it may not — the sentence that says why.
///
/// One string serves both jobs (`message`): the banner's copy and the refusal's reason. They are the
/// same sentence in upstream (the banner *is* the explanation) and they are deliberately one value
/// here so a reader can never see two different explanations of one refusal.
enum ComposerPostingState: Equatable, Sendable {
    /// The input is drawn and a send may go out.
    case open
    /// The channel is archived (`delete_at`): upstream `post_draft/archived/index.tsx`.
    case archived
    /// The membership's roles do not carry `create_post`: upstream `post_draft/read_only/index.tsx`.
    case readOnly

    /// Whether the write surface (input, toolbar, send) may be drawn at all.
    var canPost: Bool { self == .open }

    /// The banner's copy, and the refusal's sentence.
    ///
    /// Upstream's strings (`archivedChannelMessage`, `mobile.create_post.read_only`), with the
    /// markdown emphasis dropped: the banner draws a plain `Text`, and `**archived channel**` would
    /// otherwise be read out loud with the asterisks by VoiceOver.
    var message: String {
        switch self {
        case .open: return ""
        case .archived: return "You are viewing an archived channel. New messages cannot be posted."
        case .readOnly: return "This channel is read-only."
        }
    }

    /// The SF Symbol the banner draws — upstream's `CompassIcon` names: `archive-outline` for the
    /// archived banner, `glasses` for the read-only one.
    var glyph: String {
        switch self {
        case .open: return ""
        case .archived: return "archivebox"
        case .readOnly: return "eyeglasses"
        }
    }

    /// The accessibility identifier of the banner, so a UI test addresses the banner and not a colour.
    var identifier: String {
        switch self {
        case .open: return ""
        case .archived: return "channelComposer.archivedBanner"
        case .readOnly: return "channelComposer.readOnlyBanner"
        }
    }
}

// MARK: - The facts

/// Everything the posting state is derived from, and nothing else.
///
/// `channel` is the server's own row (`GET /channels/{id}`), kept whole because the socket patches it
/// (`channel_updated` carries a channel, `channel_deleted` carries a `delete_at`): the state is then
/// re-derived from the patched facts without asking the server again.
struct ComposerPostingFacts: Equatable, Sendable {
    var channel: MMChannel
    /// The union of the permission ids of every role the reader holds here (system + team + channel
    /// membership). `nil` = **the server did not answer** — not "no permissions" (see the header).
    var permissions: Set<String>?
}

extension ComposerPostingState {

    /// The precedence, rule for rule: archived wins over read-only (`post_draft.tsx` returns the
    /// archived banner first), and an unanswered permission lookup is not a denial.
    static func derive(_ facts: ComposerPostingFacts) -> ComposerPostingState {
        if facts.channel.deleteAt != 0 { return .archived }
        guard let permissions = facts.permissions else { return .open }
        return permissions.contains(ChannelPermissionID.createPost) ? .open : .readOnly
    }

    /// `true` when a permission lookup **answered** and the answer excludes `create_post`: the one
    /// case where the read-only banner is a server fact rather than a client guess. Used by the
    /// tests and by nothing else — `derive` is the single place the rule lives.
    static func deniesPosting(permissions: Set<String>?) -> Bool {
        guard let permissions else { return false }
        return !permissions.contains(ChannelPermissionID.createPost)
    }
}

// MARK: - The seam

/// What the composer needs to answer "may I post here?": one read, on demand.
///
/// One method rather than five (`channel`, `principal`, memberships, roles) so the rules above stay
/// testable against a fake that answers *facts*, not against a fake that has to model the server's
/// four-call fan-in — and so a host with no server (a preview, the composer's own draft fixtures)
/// simply passes `nil` and keeps the pre-existing behaviour.
@MainActor
protocol ComposerPostingPolicyServing: AnyObject {
    /// The facts, or `nil` when the server could not be asked.
    ///
    /// Never throws and never invents: `nil` means "no answer", and the composer stays **open** on it
    /// (see the header). The caller re-asks on the next channel event, so a transient failure is not
    /// permanent.
    func facts(channelID: String, teamID: String?) async -> ComposerPostingFacts?
}

/// The production policy: the session's own `APIClient`, resolved **per call** (a composer created
/// before the session finished restoring must not be permanently blind).
///
/// The fan-in is the same one `ChannelInfoViewModel.refreshPermissions` makes, and for the same
/// reason: the three role sources are all required. `manage_team` lives on the team membership,
/// `channel_user`/`channel_admin` (and any scheme role) on the channel membership, `system_admin` on
/// the user row — reading only one hides a permission the server would allow.
@MainActor
final class SessionComposerPostingPolicy: ComposerPostingPolicyServing {

    private let resolve: () -> APIClient?

    init(resolve: @escaping () -> APIClient?) {
        self.resolve = resolve
    }

    func facts(channelID: String, teamID: String?) async -> ComposerPostingFacts? {
        guard let client = resolve() else { return nil }
        do {
            let channel = try await client.channel(id: channelID)
            let principal = try await client.currentPrincipal()
            // A membership row that cannot be read contributes no role names: it must not fail the
            // whole answer (a DM opened from a permalink can have no team membership at all).
            let channelRoles = (try? await client.channelMembership(channelID: channelID))?.roles ?? ""
            let team = channel.teamId.isEmpty ? (teamID ?? "") : channel.teamId
            var teamRoles = ""
            if !team.isEmpty,
               let membership = try? await client.teamMembership(teamID: team, userID: principal.id) {
                teamRoles = membership.roles
            }
            let names = ChannelPermissions.roleNames(systemRoles: principal.roles,
                                                     teamRoles: teamRoles,
                                                     channelRoles: channelRoles)
            let roles = try await client.roles(names: names)
            // Not one role came back: the server knows none of these names, or the lookup failed.
            // That is "no answer", not "no permissions" — the same reading `ChannelInfoViewModel`
            // gives it, and the direction this file's header argues for.
            let permissions = roles.isEmpty ? nil : ChannelPermissions.union(roles: roles)
            return ComposerPostingFacts(channel: channel, permissions: permissions)
        } catch {
            return nil
        }
    }
}
