// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/post_options/index.ts (which observable feeds which gate),
//        app/screens/post_options/options/mark_unread_option.tsx (`markPostAsUnread`),
//        app/components/common_post_options/save_option.tsx, pin_channel_option.tsx,
//        follow_thread_option.tsx, copy_permalink_option.tsx, app/actions/remote/preference.ts.
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §18; no
// upstream source copied. The view-model shape is this repo's own (component-map.md §1) and mirrors
// `ChannelInfoViewModel`: a service seam, a generation guard around activation, and every rule kept
// out of the view.
//
// This object owns the **state a row cannot know by itself** — my permissions in this channel, the
// saved set, follow/pin patches that arrive over the socket, the team's URL name, whether the channel
// is archived — and performs the writes. The ordered offer derivation itself lives in
// `PostOptionsCapabilities.derive`, so "which rows are offered" is one pure function and this object
// only fills in its facts.

import Foundation
import Combine

/// The result of pressing one option, as the sheet needs to render it.
enum PostOptionOutcome: Equatable, Sendable {
    /// A copy option: the exact string to put on the pasteboard.
    case copied(String)
    /// The write landed (or the socket/host action was taken); the sheet dismisses.
    case performed
    /// The write failed. The sheet stays open and says why — never a silent no-op (T40-AV F1/F2's
    /// precedent).
    case failed(String)

    /// Convenience for tests and the sheet's dismiss rule.
    var succeeded: Bool {
        switch self {
        case .copied, .performed: return true
        case .failed: return false
        }
    }
}

/// One channel's post-options state.
@MainActor
final class PostOptionsViewModel: ObservableObject {

    // MARK: Identity

    let channelID: String
    /// The team the channel belongs to, from the activation. The permalink and the follow write both
    /// need it; a post carries no team id.
    @Published private(set) var teamID: String = ""
    /// The server's base URL, for the permalink's first segment.
    let serverURL: String
    private let service: PostOptionsServing
    private let myUserID: String

    // MARK: State

    /// The permission union for this channel. `nil` = not answered (or the lookup failed), which is
    /// the **closed** state for permission-gated options (`PostOptionsGate.canPin`).
    @Published private(set) var permissions: Set<String>?
    /// The posts the server holds as saved for me (`flagged_post` preferences).
    @Published private(set) var savedPostIDs: Set<String> = []
    /// `root post id -> following`, patched by `thread_follow_changed` and by this device's own writes.
    @Published private(set) var followStates: [String: Bool] = [:]
    /// `post id -> pinned`, patched by `post_edited` and by this device's own writes, so a sheet that
    /// is already open moves when another client pins.
    @Published private(set) var pinStates: [String: Bool] = [:]
    /// The team's URL name, resolved once per channel when the caller did not already have it.
    @Published private(set) var teamName: String?
    @Published private(set) var isArchived = false
    /// The option whose write is in flight, so the sheet can disable it instead of sending twice.
    @Published private(set) var busyOption: PostOptionID?
    /// Set once `activate` has finished, for diagnostics and the sheet's "still checking" state.
    @Published private(set) var didActivate = false

    // MARK: Host hooks

    /// A pin write landed (or was patched by the socket): let the timeline move its pin badge **now**
    /// rather than on the next page load. `post_edited` is the confirmation.
    var onPinChange: ((String, Bool) -> Void)?
    /// A follow write landed: the channel's reply line/root row carries `is_following`.
    var onFollowChange: ((String, Bool) -> Void)?
    /// A mark-unread write answered with the server's membership row. The sidebar also receives
    /// `post_unread` on the socket; this is the same arithmetic for any host that wants it inline.
    var onUnreadChange: ((MMChannelMember) -> Void)?

    // MARK: Request state

    /// The identity of the last activation: a second appearance for the same channel/team must not
    /// re-issue four reads.
    private var activatedKey: String?
    /// Every activation and write bumps this, so a late answer cannot overwrite a newer one.
    private var generation = 0

    init(channelID: String,
         serverURL: String,
         myUserID: String,
         service: PostOptionsServing) {
        self.channelID = channelID
        self.serverURL = serverURL
        self.myUserID = myUserID
        self.service = service
    }

    // MARK: Derived

    /// The facts the offer derivation reads for one row, with every live value this object holds.
    func facts(for row: PostRowModel,
               actions: PostRowActions,
               surface: PostOptionsSurface) -> PostOptionFacts {
        var facts = PostOptionFacts()
        facts.viewerID = myUserID
        facts.authorID = row.post.userId
        facts.isSystem = row.isSystem
        facts.isDeleted = row.isDeleted
        facts.isPending = row.isPending
        facts.isWebhook = row.post.props?.objectValue?["from_webhook"]?.boolValue ?? false
        facts.isPinned = pinStates[row.id] ?? row.isPinned
        facts.isSaved = savedPostIDs.contains(row.id)
        facts.isRootPost = row.post.rootId.isEmpty
        facts.replyCount = row.replyCount
        if row.post.rootId.isEmpty, row.replyCount > 0 {
            facts.threadFollowing = ThreadFollowDerivation.state(socketPatched: followStates[row.id],
                                                                 row: row.post.isFollowing)
        }
        facts.message = row.post.message
        facts.canReact = actions.canReact
        facts.canReply = actions.canReply
        facts.canEdit = actions.canEdit
        facts.canDelete = actions.canDelete
        facts.permissions = permissions
        facts.teamName = teamName
        facts.surface = surface
        facts.isArchived = isArchived
        return facts
    }

    /// The one ordered list the sheet draws for a row.
    func offeredOptions(for row: PostRowModel,
                        actions: PostRowActions,
                        surface: PostOptionsSurface) -> [PostOptionID] {
        PostOptionsCapabilities.derive(facts(for: row, actions: actions, surface: surface)).offeredOptions
    }

    // MARK: Activation

    /// Read the state a row cannot know. Idempotent per (channel, team): the first appearance loads,
    /// every later one is free.
    ///
    /// Each read degrades on its own. A failed permission lookup leaves `permissions` nil, which hides
    /// the permission-gated rows; a failed saved read leaves the set empty, which offers Save rather
    /// than a wrong Unsave; a failed team-name lookup hides Copy Link rather than inventing a path.
    func activate(teamID: String, teamName suppliedTeamName: String?) async {
        let key = "\(teamID)|\(suppliedTeamName ?? "")"
        if activatedKey == key { return }
        activatedKey = key
        if !teamID.isEmpty { self.teamID = teamID }
        generation += 1
        let token = generation

        if let suppliedTeamName, !suppliedTeamName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            teamName = suppliedTeamName
        }
        if let archived = try? await service.isArchived(channelID: channelID), token == generation {
            isArchived = archived
        }
        // The channel's own team wins over the route's: a deep link carries no team, and a route the
        // shell kept from another team must not put the wrong team name in the permalink.
        var effectiveTeamID = teamID
        if let resolved = try? await service.channelTeamID(channelID: channelID), !resolved.isEmpty,
           token == generation {
            effectiveTeamID = resolved
            self.teamID = resolved
        }
        if !effectiveTeamID.isEmpty,
           let resolved = try? await service.teamName(teamID: effectiveTeamID),
           token == generation {
            teamName = resolved
        } else if let suppliedTeamName, teamName == nil,
                  !suppliedTeamName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            teamName = suppliedTeamName
        }
        if let ids = try? await service.savedPostIDs(), token == generation {
            savedPostIDs = ids
        }
        do {
            let resolved = try await service.permissions(channelID: channelID,
                                                         teamID: effectiveTeamID,
                                                         userID: myUserID)
            if token == generation { permissions = resolved }
        } catch {
            // Closed direction: the permission-gated rows stay hidden, and the reason is in the log
            // rather than guessed at.
            Logger.error("T48", "could not read permissions: \(error)")
        }
        guard token == generation else { return }
        didActivate = true
    }

    // MARK: The writes

    /// Perform one option for one post.
    ///
    /// Copy options return the string to put on the pasteboard (the sheet does that — the model has no
    /// UIKit). Host options (react/reply/edit/delete) are **not** handled here: they are closures the
    /// pane owns, and the sheet calls them directly. Everything else is a request; a failure comes back
    /// as `.failed` with the reader's wording.
    @discardableResult
    func perform(_ option: PostOptionID,
                 row: PostRowModel) async -> PostOptionOutcome {
        guard busyOption == nil else { return .failed("Another action is still in progress.") }
        switch option {
        case .copyText:
            let text = row.post.message
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failed("This message has no text to copy.")
            }
            return .copied(text)
        case .copyLink:
            guard let link = PostPermalink.string(serverURL: serverURL,
                                                 teamName: teamName ?? "",
                                                 postID: row.id) else {
                return .failed("This message's link could not be built. Try again once the channel has loaded.")
            }
            return .copied(link)
        case .save, .unsave, .pin, .unpin, .markUnread, .followThread, .unfollowThread:
            break
        case .react, .reply, .edit, .delete:
            // Reached only if a host wired the sheet without its own handler; refusing loudly is better
            // than a row that appears to work.
            return .failed("This action is not available in this window.")
        }

        busyOption = option
        defer { busyOption = nil }
        do {
            switch option {
            case .save:
                try await service.setSaved(postID: row.id, saved: true, userID: myUserID)
                savedPostIDs.insert(row.id)
            case .unsave:
                try await service.setSaved(postID: row.id, saved: false, userID: myUserID)
                savedPostIDs.remove(row.id)
            case .pin:
                try await service.setPinned(postID: row.id, pinned: true)
                pinStates[row.id] = true
                onPinChange?(row.id, true)
            case .unpin:
                try await service.setPinned(postID: row.id, pinned: false)
                pinStates[row.id] = false
                onPinChange?(row.id, false)
            case .markUnread:
                let membership = try await service.markUnread(postID: row.id, userID: myUserID)
                onUnreadChange?(membership)
            case .followThread, .unfollowThread:
                let following = option == .followThread
                let rootID = row.post.rootId.isEmpty ? row.id : row.post.rootId
                try await service.setFollowing(teamID: teamID, rootID: rootID, following: following)
                followStates[rootID] = following
                onFollowChange?(rootID, following)
            default:
                return .failed("This action is not available in this window.")
            }
            return .performed
        } catch {
            return .failed(Self.writeMessage(for: error, option: option))
        }
    }

    // MARK: The socket

    /// Apply one event. The menu must stay honest when **another client** changes the state it derives
    /// from — that is what makes the rows worth offering at all.
    ///
    /// Measured (`scripts/t48_post_options_socket_probe.py`): saving publishes `preferences_changed`,
    /// unsaving publishes `preferences_deleted`, pinning publishes `post_edited` with the whole post,
    /// following publishes `thread_follow_changed`.
    func handle(_ event: SocketEvent) {
        switch event {
        case .preferencesChanged(let preferences):
            savedPostIDs = SavedPostDerivation.updated(savedPostIDs,
                                                       with: preferences,
                                                       deleted: false)
        case .preferencesDeleted(let preferences):
            savedPostIDs = SavedPostDerivation.updated(savedPostIDs,
                                                       with: preferences,
                                                       deleted: true)
        case .threadFollowChanged(let change):
            followStates[change.threadID] = change.state
            onFollowChange?(change.threadID, change.state)
        case .postEdited(let post):
            pinStates[post.id] = post.isPinned
        case .hello, .posted, .postDeleted, .channelViewed, .multipleChannelsViewed, .typing,
             .statusChange, .userUpdated, .reactionAdded, .reactionRemoved,
             .sidebarCategoryUpdated, .channelCreated, .channelDeleted, .channelUpdated,
             .channelRestored, .userAdded, .userRemoved, .channelMemberUpdated, .postUnread,
             .threadUpdated, .threadReadChanged, .plugin, .unhandled:
            break
        }
    }

    // MARK: Copy

    /// The reader's wording for a failed write. Same funnel as the other native screens, with the
    /// option named so "it did not work" is never the whole message.
    static func writeMessage(for error: Error, option: PostOptionID) -> String {
        let base = MMErrorCopy.message(for: error,
                                       offline: "You are offline. This will happen when the connection is back.",
                                       timeout: "The server did not answer in time.",
                                       unauthorized: "Your session has expired. Sign in again.",
                                       forbidden: "You do not have permission to do that.",
                                       notFound: "It is no longer on the server.",
                                       rateLimited: "Too many requests — try again in a moment.",
                                       fallback: "The server refused the request.")
        return "Could not \(option.failureSubject). \(base)"
    }
}
