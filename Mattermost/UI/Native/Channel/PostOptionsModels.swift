// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/post_options/index.ts (every gate, one observable per option),
//        app/screens/post_options/post_options.tsx (the **render order** — the list below is that
//        order, item for item), app/screens/post_options/options/{mark_unread_option,
//        pin_channel_option,edit_option,delete_post_option}.tsx,
//        app/components/common_post_options/{copy_permalink_option,follow_thread_option,
//        save_option}.tsx, app/client/rest/posts.ts (`markPostAsUnread` path and body),
//        app/actions/remote/post.ts (`markPostAsUnread` — the counters it writes afterwards).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §18; no
// upstream source copied. The SwiftUI decomposition is this repo's own (docs/component-map.md §1).
//
// This file is **pure**: no I/O, no `AuthSession`, no `APIClient`. Everything the card asks to be
// exhaustively assertable lives here:
//
//   * ONE ordered derivation (`PostOptionsCapabilities.derive` → `offeredOptions`) decides which
//     options the sheet draws, in upstream's order. The view draws exactly that array and nothing
//     else, so "this row offers nothing I cannot perform" is a property of one function.
//   * every gate that is not a post fact is read from the server's own data: permission **ids** for
//     pinning, the resolved team **name** for the permalink, the `flagged_post` preference for
//     saved state, the CRT thread row's **membership** for follow state. Nothing is guessed from a
//     role name, and nothing is read from a key the server does not send.
//
// Measured on the pinned 9.11.19 server (`scripts/t48_post_options_probe.py`,
// `scripts/t48_post_options_probe2.py`, `scripts/t48_post_options_socket_probe.py`; logs in
// `build/t48-post-options-*.log`):
//
//   * `POST /users/{uid}/posts/{pid}/set_unread` with `{"collapsed_threads_supported": true}` answers
//     the **channel membership row** with the new counters — no follow-up read is needed.
//   * pinning and unpinning publish `post_edited` carrying the whole post, `is_pinned` already set.
//   * saving publishes `preferences_changed`, unsaving publishes **`preferences_deleted`** (a frame of
//     its own — `SocketEvent.preferencesDeleted`), and both carry `flagged_post` rows.
//   * `thread_follow_changed` carries `{thread_id, state, reply_count}`.
//   * **no surface publishes `is_following`** (T48-AV-R3, `scripts/t48_follow_probe.py`): the channel
//     page's root row, `GET /posts/{root}` and the thread object all lack the key before a follow,
//     after one, and after an unfollow. Following is **membership**: the CRT endpoint
//     `GET /users/me/teams/{team}/threads/{root}` answers 404 while unfollowed and 200 while
//     followed, and `GET /users/me/teams/{team}/threads` contains the row only while followed. The
//     sheet reads the former (`PostOptionsServing.isFollowing`) every time it opens, because an
//     in-memory patch cannot survive a relaunch.
//   * `GET /users/me/teams/{team}/threads/{root}` answers 200 only once the root **has replies**:
//     9.11.19 has no thread row for a root with none (404), which is why Follow is offered only for a
//     root whose reply count is above zero.
//   * **no Mattermost server defines `pin_post`/`unpin_post`**: 0 of the 271 permission ids my
//     administrator union holds contain "pin", upstream master's permission table has none either, and
//     a plain `system_user` (50 ids) pinned and unpinned with 200. The ids are therefore honoured when
//     a future server carries them, and the rule otherwise falls back to `create_post` — the exact
//     population the endpoint lets pin today. See `PostOptionsGate.canPin`.

import Foundation

// MARK: - The options, in upstream's order

/// One row of the post options sheet.
///
/// The raw values are the accessibility identifiers (`postOptions.<rawValue>`) a UI test presses, and
/// the order of the cases here is **not** the render order — `PostOptionsCapabilities.offeredOptions`
/// is the one ordered list (upstream's `post_options.tsx`).
enum PostOptionID: String, Equatable, Sendable, CaseIterable {
    case react
    case reply
    /// Upstream's `FollowThreadOption`, both directions. It draws "Follow Message"/"Unfollow Message"
    /// when the thread has no replies; on 9.11.19 such a thread has no thread row at all, so this
    /// build only offers the Thread spelling (see the file header).
    case followThread
    case unfollowThread
    case markUnread
    /// Upstream's `CopyPermalinkOption` — the option is labelled "Copy Link".
    case copyLink
    case save
    case unsave
    case copyText
    case pin
    case unpin
    case edit
    case delete

    var title: String {
        switch self {
        case .react: return "React"
        case .reply: return "Reply"
        case .followThread: return "Follow Thread"
        case .unfollowThread: return "Unfollow Thread"
        case .markUnread: return "Mark as Unread"
        case .copyLink: return "Copy Link"
        case .save: return "Save"
        case .unsave: return "Unsave"
        case .copyText: return "Copy Text"
        case .pin: return "Pin to Channel"
        case .unpin: return "Unpin from Channel"
        case .edit: return "Edit"
        case .delete: return "Delete"
        }
    }

    var glyph: String {
        switch self {
        case .react: return "face.smiling"
        case .reply: return "arrowshape.turn.up.left"
        case .followThread: return "bell"
        case .unfollowThread: return "bell.slash"
        case .markUnread: return "envelope.badge"
        case .copyLink: return "link"
        case .save: return "bookmark"
        case .unsave: return "bookmark.slash"
        case .copyText: return "doc.on.doc"
        case .pin: return "pin"
        case .unpin: return "pin.slash"
        case .edit: return "pencil"
        case .delete: return "trash"
        }
    }

    /// `Cancel`-style rows are the only destructive one (upstream `DeletePostOption`).
    var isDestructive: Bool { self == .delete }

    var identifier: String { "postOptions.\(rawValue)" }

    /// The options that write nothing to the server: their effect is the pasteboard.
    var isCopy: Bool { self == .copyText || self == .copyLink }

    /// What a refusal names in the sheet's banner.
    var failureSubject: String {
        switch self {
        case .react: return "reaction"
        case .reply: return "reply"
        case .followThread, .unfollowThread: return "thread follow"
        case .markUnread: return "unread mark"
        case .save, .unsave: return "save"
        case .pin, .unpin: return "pin"
        case .edit: return "edit"
        case .delete: return "delete"
        case .copyText, .copyLink: return "copy"
        }
    }
}

// MARK: - Facts (the whole input to the derivation)

/// Which surface the sheet was opened from. Upstream's `sourceScreen`: Follow Thread is offered on
/// the channel screen only (`shouldRenderFollow = !(sourceScreen !== Screens.CHANNEL || !thread)`),
/// and the thread screen's own bell is that screen's affordance.
enum PostOptionsSurface: String, Equatable, Sendable {
    case channel
    case thread
}

/// Everything the derivation reads. Every field is a fact the host or the server answered — there is
/// no default that quietly offers an option.
struct PostOptionFacts: Equatable, Sendable {
    /// The signed-in account. Mark-unread is `viewer != author` (or a webhook post).
    var viewerID: String = ""
    var authorID: String = ""
    var isSystem: Bool = false
    var isDeleted: Bool = false
    var isPending: Bool = false
    /// `post.props.from_webhook` — upstream `isFromWebhook`: a webhook post **is** markable unread
    /// even when the account happens to be the one the webhook posts as.
    var isWebhook: Bool = false
    var isPinned: Bool = false
    var isSaved: Bool = false
    /// `post.rootId.isEmpty`: only a root can carry a thread row.
    var isRootPost: Bool = true
    /// The row's own reply count (`PostRowModel.replyCount`). On 9.11.19 a root with 0 replies has
    /// no thread row, so this is what decides whether Follow may be offered at all.
    var replyCount: Int = 0
    /// `nil` = the follow question has not been answered for this root yet (or there is no thread);
    /// then the Follow option is **absent**, not a guess.
    var threadFollowing: Bool? = nil
    var message: String = ""
    /// The row menu's own host facts (T35's `ComposerRowPermissions`, plus T37's reaction gate).
    var canReact: Bool = false
    var canReply: Bool = false
    var canEdit: Bool = false
    var canDelete: Bool = false
    /// The union of my role permissions on this server. `nil` = not loaded (or the lookup failed):
    /// permission-gated options are withheld rather than guessed.
    var permissions: Set<String>? = nil
    /// The team's URL **name** (not its id) — the permalink's middle segment. `nil`/empty = the name
    /// could not be resolved, so Copy Link is absent rather than a wrong path.
    var teamName: String? = nil
    var surface: PostOptionsSurface = .channel
    /// An archived channel offers no writes (upstream's `channelIsArchived`).
    var isArchived: Bool = false
}

// MARK: - Permissions

/// The permission ids this surface consults, quoted from the server and from upstream's
/// `app/constants/permissions.ts`.
enum PostOptionsPermissionID {
    /// The ids the T48 card names for pinning. **No Mattermost server defines them** (measured — see
    /// the file header); they are consulted first so a server that adds them is honoured.
    static let pinPost = "pin_post"
    static let unpinPost = "unpin_post"
    /// The fallback gate for pinning: may this account write in the channel at all? That is the
    /// population 9.11.19's endpoint lets pin (measured: a `system_user` with 50 permissions got 200).
    static let createPost = "create_post"

    /// The ids the T48 note's Edit row and Delete row name. **These do exist**, unlike the pin ids:
    /// measured on 9.11.19, the administrator union of 271 ids holds all three
    /// (`scripts/t48av_r4_permission_probe.py`; upstream's `app/constants/permissions.ts` has the same
    /// spellings). They are required, not a fallback — a server defines them precisely so that editing
    /// and deleting can be granted apart from posting.
    static let editPost = "edit_post"
    static let deletePost = "delete_post"
    /// Upstream `canDeletePost`'s second branch: a moderator may delete somebody else's post. Read
    /// here as an additional grant for the delete gate; the host still decides *whose* rows carry the
    /// action (a row's `canDelete` is its author check).
    static let deleteOthersPosts = "delete_others_posts"

    static let all: Set<String> = [pinPost, unpinPost, createPost,
                                   editPost, deletePost, deleteOthersPosts]
}

enum PostOptionsGate {
    /// Whether pin/unpin may be offered.
    ///
    /// - The permission lookup must have answered at all (`nil`/empty is the closed state, the same
    ///   rule as `ChannelInfoCapabilities.none`).
    /// - `pin_post`/`unpin_post` win when present.
    /// - Otherwise the account must hold `create_post`. This is deliberate and measured: no
    ///   Mattermost release has ever defined a pin permission, so requiring one would hide the action
    ///   on every real server forever. The server still enforces the write; this gate only stops the
    ///   menu from offering it to an account that cannot post in the channel.
    static func canPin(permissions: Set<String>?) -> Bool {
        guard let permissions, !permissions.isEmpty else { return false }
        if permissions.contains(PostOptionsPermissionID.pinPost)
            || permissions.contains(PostOptionsPermissionID.unpinPost) {
            return true
        }
        return permissions.contains(PostOptionsPermissionID.createPost)
    }

    /// Upstream `canEditPost`: `isMine && hasPermission(EDIT_POST) && !channelIsArchived && !isSystem`.
    ///
    /// `hostAllows` is that ownership/system answer (`ComposerRowPermissions.menu` as the pane wired
    /// it); the two terms this gate adds are the ones T48-AV F5 measured missing — the server's
    /// `edit_post` id and the archived channel. Both are required: an archived channel is read-only
    /// for everyone, and a revoked `edit_post` is a grant the server withdrew.
    ///
    /// Unlike `canPin`, there is no `create_post` fallback. `edit_post` exists on every release
    /// (measured, see `PostOptionsPermissionID.editPost`), so falling back to "may post" would put the
    /// row back where the defect was.
    static func canEditPost(hostAllows: Bool,
                            isArchived: Bool,
                            permissions: Set<String>?) -> Bool {
        guard hostAllows, !isArchived else { return false }
        guard let permissions, !permissions.isEmpty else { return false }
        return permissions.contains(PostOptionsPermissionID.editPost)
    }

    /// Upstream `canDeletePost`: `(isMine && hasPermission(DELETE_POST) && !archived)
    /// || hasPermission(DELETE_OTHERS_POSTS)`.
    ///
    /// Same shape as `canEditPost`. `delete_others_posts` is accepted in place of `delete_post`
    /// because it is a superset grant on the same rows; which rows carry the action is still the
    /// host's `canDelete` (its author check), which is why `hostAllows` is required here too.
    static func canDeletePost(hostAllows: Bool,
                              isArchived: Bool,
                              permissions: Set<String>?) -> Bool {
        guard hostAllows, !isArchived else { return false }
        guard let permissions, !permissions.isEmpty else { return false }
        return permissions.contains(PostOptionsPermissionID.deletePost)
            || permissions.contains(PostOptionsPermissionID.deleteOthersPosts)
    }
}

// MARK: - The derivation

/// What the sheet offers for one post, and the one ordered list it draws.
struct PostOptionsCapabilities: Equatable, Sendable {
    var facts: PostOptionFacts

    var offersFollow: Bool
    var offersMarkUnread: Bool
    var offersCopyLink: Bool
    var offersSave: Bool
    var offersCopyText: Bool
    var offersPin: Bool
    /// T48-AV F5: Reply, Edit and Delete used to be the host's own bit alone. Reply gains the archive
    /// term the note's table always claimed; Edit and Delete gain it plus the server's id.
    var offersReply: Bool
    var offersEdit: Bool
    var offersDelete: Bool

    /// The option rows, in upstream's render order (`post_options.tsx`): react, reply, follow,
    /// mark unread, copy link, (translation — deferred), save/unsave, copy text, pin/unpin, edit,
    /// delete.
    var offeredOptions: [PostOptionID] {
        var options: [PostOptionID] = []
        if facts.canReact { options.append(.react) }
        if offersReply { options.append(.reply) }
        if offersFollow, let following = facts.threadFollowing {
            options.append(following ? .unfollowThread : .followThread)
        }
        if offersMarkUnread { options.append(.markUnread) }
        if offersCopyLink { options.append(.copyLink) }
        if offersSave { options.append(facts.isSaved ? .unsave : .save) }
        if offersCopyText { options.append(.copyText) }
        if offersPin { options.append(facts.isPinned ? .unpin : .pin) }
        if offersEdit { options.append(.edit) }
        if offersDelete { options.append(.delete) }
        return options
    }

    /// The single derivation. Rule for rule from upstream's `post_options/index.ts` and
    /// `post_options.tsx`; the deviations are stated where they are made and in the file header.
    static func derive(_ facts: PostOptionFacts) -> PostOptionsCapabilities {
        let readable = !facts.isSystem && !facts.isDeleted && !facts.isPending
        let canWrite = readable && !facts.isArchived

        // Upstream `shouldRenderFollow`: channel screen only, and only when a thread exists.
        let hasThread = facts.isRootPost && facts.replyCount > 0
        let offersFollow = canWrite && facts.surface == .channel && hasThread
            && facts.threadFollowing != nil

        // Upstream `canMarkAsUnread`: `!isArchived && ((user.id !== post.userId && !isSystemMessage)
        // || isFromWebhook)`.
        let offersMarkUnread = readable && !facts.isArchived
            && ((facts.viewerID != facts.authorID && !facts.isSystem) || facts.isWebhook)

        // Upstream `canCopyPermalink`: `!isSystemPost && copy-protection off`. The protection is an
        // EMM managed-config value this build does not read; the team name is the part a native
        // client cannot invent, so its presence is the gate here.
        let team = facts.teamName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let offersCopyLink = readable && !team.isEmpty

        // Upstream `canSavePost`: no permission, any readable post (including my own).
        let offersSave = readable

        // Upstream `canCopyText`: a permalink AND a message to copy.
        let offersCopyText = offersCopyLink
            && !facts.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // Upstream `canPin`: not a system post, not archived. The permission check is this build's
        // addition (the card requires one, and `PostOptionsGate.canPin` explains the measured shape).
        let offersPin = canWrite && PostOptionsGate.canPin(permissions: facts.permissions)

        // Upstream `canEditPost` / `canDeletePost` (T48-AV F5). The host's `canEdit`/`canDelete` are
        // its ownership answer; both gates add `edit_post`/`delete_post` and the archived channel.
        // Applied here as well as in `PostOptionsViewModel.facts` on purpose: `derive` is the one
        // place that decides what is drawn, so a host that fills the facts itself cannot over-offer.
        //
        // Reply carries the archive term alone: the note's table has always said "channel not
        // archived, post not deleted" for it, and the row host (`ComposerRowPermissions.menu`) does
        // not know `delete_at`, so nothing upstream of here could apply it.
        let offersReply = canWrite && facts.canReply
        let offersEdit = canWrite && PostOptionsGate.canEditPost(hostAllows: facts.canEdit,
                                                                 isArchived: facts.isArchived,
                                                                 permissions: facts.permissions)
        let offersDelete = canWrite && PostOptionsGate.canDeletePost(hostAllows: facts.canDelete,
                                                                     isArchived: facts.isArchived,
                                                                     permissions: facts.permissions)

        return PostOptionsCapabilities(facts: facts,
                                       offersFollow: offersFollow,
                                       offersMarkUnread: offersMarkUnread,
                                       offersCopyLink: offersCopyLink,
                                       offersSave: offersSave,
                                       offersCopyText: offersCopyText,
                                       offersPin: offersPin,
                                       offersReply: offersReply,
                                       offersEdit: offersEdit,
                                       offersDelete: offersDelete)
    }
}

// MARK: - The permalink

/// The link the server itself would serve, built from the team's **name**.
///
/// Measured on 9.11.19: `GET /perf/pl/<post>` answers 200 `text/html`, and so does the id spelling —
/// the name is the one every Mattermost deployment documents and the one the web client writes, so it
/// is the one this build copies (`docs/t48-build-note.md` §2).
enum PostPermalink {
    /// `{server}/{team}/pl/{post_id}`, or `nil` when any component is missing.
    static func string(serverURL: String,
                       teamName: String,
                       postID: String) -> String? {
        let server = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let team = teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        let post = postID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !server.isEmpty, !team.isEmpty, !post.isEmpty else { return nil }
        guard let url = URL(string: server), url.scheme != nil, url.host != nil else { return nil }
        var base = server
        while base.hasSuffix("/") { base.removeLast() }
        // The team segment is a path component: a name a server allows but a URL does not (a space in
        // an old deployment) must be escaped rather than pasted raw.
        let encodedTeam = team.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? team
        return "\(base)/\(encodedTeam)/pl/\(post)"
    }
}

// MARK: - Saved state (the `flagged_post` preference)

/// The saved/unsaved derivation, kept beside the socket patches so both read one rule.
enum SavedPostDerivation {
    /// Upstream `Preferences.CATEGORIES.SAVED_POST`; the same constant `APIClient.savedPostCategory`
    /// writes with.
    static let category = APIClient.savedPostCategory

    /// The post ids the server currently holds as saved (`value != "false"`).
    static func savedIDs(from preferences: [MMPreference]) -> Set<String> {
        Set(preferences
            .filter { $0.category == category && $0.value != "false" }
            .map(\.name)
            .filter { !$0.isEmpty })
    }

    /// Apply one frame's worth of preference rows.
    ///
    /// - `deleted` is the `preferences_deleted` direction (measured: unsaving publishes that frame,
    ///   not a `changed` with `false`).
    static func updated(_ existing: Set<String>,
                        with preferences: [MMPreference],
                        deleted: Bool) -> Set<String> {
        var result = existing
        for preference in preferences where preference.category == category && !preference.name.isEmpty {
            if deleted || preference.value == "false" {
                result.remove(preference.name)
            } else {
                result.insert(preference.name)
            }
        }
        return result
    }
}

// MARK: - Thread follow state

/// Where the sheet's follow answer comes from.
///
/// **Measured on 9.11.19 (`scripts/t48_follow_probe.py`, log `build/logs/t48r3-follow-probe.log`): no
/// surface publishes `is_following`.** The channel page's root row, `GET /posts/{root}` and the CRT
/// thread object all carried no such key before a follow, after a follow and after an unfollow
/// (`is_following_key_anywhere: false`). What *does* move is membership of the CRT endpoint:
/// `GET /users/me/teams/{team}/threads/{root}` → **404** never followed, **200** after `PUT
/// …/following`, **404** after `DELETE …/following` (and the team threads list contains the row only
/// while followed). That 200/404 is the read `PostOptionsServing.isFollowing` performs.
///
/// The build before this repair derived the state from `row.post.isFollowing` — a non-Optional Bool
/// that decodes a key the server never sends, so it was always `false`: every sheet opened after a
/// relaunch offered Follow Thread and never Unfollow Thread (T48-AV §F3, card `t_b28e8cfc`).
enum ThreadFollowDerivation {
    /// The answer the sheet draws, or `nil` when nothing has answered.
    ///
    /// `socketPatched` is this device's own write or a `thread_follow_changed` frame: both are newer
    /// than any read that was in flight, so they win. With neither, the server's read answers; with
    /// no answer at all the option is **absent**, never a guess — the same closed direction the
    /// permission and team-name gates use.
    static func state(socketPatched: Bool?, serverRead: Bool?) -> Bool? {
        socketPatched ?? serverRead
    }
}
