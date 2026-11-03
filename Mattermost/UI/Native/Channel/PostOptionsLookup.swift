// T48-AV-R1 (card `t_29925e81`) — the post options menu on the **lookup** rows.
//
// T48 (`00cd217`) mounted `PostOptionsSheet` in the channel pane and the thread pane only. Three
// other hosts draw the same `PostRowView` for the same kind of post and passed no `actions:`, so
// `PostRowView` built no ellipsis at all (`if let actions, actions.hasAnyAction …`,
// `PostRowView.swift:258`):
//
//   * `SearchResultRowView` — search results (`SearchView.swift`),
//   * `ActivityRowView` — the mentions feed (`MentionsView.swift`),
//   * `PostCollectionView` — the saved and pinned lists (`SavedPinnedViews.swift`), which are
//     exactly the surfaces where "unsave/unpin from the menu" is most wanted.
//
// Measured live in the shipped configuration (`app.launchArguments = []`, Release):
// `docs/t636e6483-ship-shaped-qa.md` §F1 — `post.<id>.menu is not in the tree` — and read off the
// call sites in `docs/t48-av-build-note.md` §F1.
//
// ## Why a presenter and not a closure
//
// A lookup row names a post from **any** channel of the team, so the host cannot hand the row a
// single channel's `PostOptionsViewModel`. `PostOptionsViewModel` is also per channel on purpose:
// the permission union, the archived flag and the saved set are channel facts, and a menu opened on
// a search result must not decide from whatever channel the pane last showed
// (`ChannelPaneCoordinator.postOptions(for:channelID:)` caches one model per channel — that cache is
// reused here, so a sheet opened from a lookup row and the same channel's own pane share one model
// and one socket feed).
//
// The row raises a **value** (`PostOptionsPresentation`) that names the tapped row and the model for
// *that row's* channel; one presentation slot per pane, so a second tap re-aims it instead of
// stacking. This mirrors `ProfilePresentationHost` (`ProfilePresentation`), which solved the same
// "one slot, two legal containers" problem for the author popover after T40 measured a nested sheet
// whose confirmation action never ran (`docs/t_8f9f5449-profile-popover-parity.md` §2.2).
//
// ## What the lookup sheet offers
//
// `PostOptionsCapabilities.derive` for the row's own channel — the same one function the channel
// pane uses. The four **host** options (react / reply / edit / delete) are not offered here: each
// needs the channel pane's composer, emoji picker or draft sink, and this host has none of them.
// The sheet's contract is "every row it draws can be performed", so a lookup row draws the options
// whose writes this host really sends (save/unsave, pin/unpin, mark unread, follow, copy link, copy
// text) rather than dead entries. That is also why `canReact`/`canReply`/`canEdit`/`canDelete` are
// false in `PostOptionsLookupActions` — the derivation reads them as facts, not as styling.
//
// ## The channel's team, never the pane's
//
// `activate(teamID:teamName:)` is called with **no** team hint. A lookup row can belong to a team
// that is not the one the shell is showing (the mentions feed spans teams), and the permalink's
// segment plus the permission union belong to the channel's own team — which `activate` resolves
// from `GET /channels/{id}`. Passing the pane's team here would reintroduce the wrong-team permalink
// that `t9acf2b1c` (R2) repairs in the channel pane; with no hint, a failed channel-team read hides
// Copy Link instead of building a link to the wrong team.
//
// ## Identifiers an XCUITest can rely on
//
//   post.<id>.menu       the row's ellipsis (drawn by `PostRowView` now that it has actions)
//   postOptions.<id>     the options list, when it arrived as a **sheet**
//   postOptionsPush      the *pushed* form (regular layout's lookup sheet, the pinned sheet) — it
//                        must be absent when the options arrived as a sheet, mirroring `profilePush`
//   postOptions.<option> one derived option (e.g. `postOptions.save`, `postOptions.unpin`), in both
//                        forms
//   postOptions.error    a refused write, drawn in place (the presentation stays up)
//
// The pushed form is identified by `postOptionsPush` and not by `postOptions.<id>`: identifiers on a
// `List` are not reliably in this runtime's tree once it is a push destination (the same finding
// `t636e6483` recorded for the pinned list, `T93BNativeByDefaultUITests`' `revealSavedOrPinned`), so
// the form's own wrapper carries the identifier and the option rows carry theirs.

import SwiftUI

// MARK: - The presentation

/// One lookup row's menu, as the pane presents it.
///
/// The row and the model are immutable facts of the presentation: the sheet observes `options`, so
/// the list it draws moves when another client pins or saves the post, while the row it was opened
/// for never changes under it.
struct PostOptionsPresentation: Identifiable {
    /// The row the reader tapped. Its id/author/message are what the sheet was opened for.
    let row: PostRowModel
    /// Where it was opened from. A lookup row is a channel post, so `.channel` — the same surface
    /// rule the channel pane uses (Follow Thread is offered on the channel screen, not the thread).
    let surface: PostOptionsSurface
    /// The post-options state **of this row's own channel** (`row.post.channelId`).
    let options: PostOptionsViewModel

    var id: String { row.id }
}

/// Identity for the item-bound presentations below.
///
/// `navigationDestination(item:)` requires `Hashable` and `PostOptionsViewModel` is a reference to
/// live state, not a value: the identity of a presentation is the post it names (opening the same
/// row twice is the same destination), and the model is compared by reference so two panes holding
/// two models for one post id still read as different presentations.
extension PostOptionsPresentation: Hashable {
    static func == (lhs: PostOptionsPresentation, rhs: PostOptionsPresentation) -> Bool {
        lhs.id == rhs.id && lhs.options === rhs.options
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - How a host may present it

/// How a host may present the options screen.
///
/// The hosts are not at the same level of the presentation stack, so the **same screen** has two
/// legal presentations depending on who hosts it:
///
///   host                                        container                          legal form
///   Search / Saved / Mentions, compact layout   a `TabView` tab (no stack above)    sheet
///   the same three, regular layout              `NativeShellView`'s `lookupSheet`   push on that stack
///   `PostCollectionView` in `PinnedPostsView`   a sheet with its own stack          push on that stack
///
/// A sheet is the compact answer because there is no stack to push onto; a push is the answer
/// *inside* a presentation, because a nested sheet is the shape T40 measured failing (its
/// confirmation action never ran — zero requests on the wire).
enum PostOptionsPresentationMode: Equatable, Sendable {
    case sheet
    case push
}

private struct PostOptionsPresentationKey: EnvironmentKey {
    static let defaultValue: PostOptionsPresentationMode = .sheet
}

extension EnvironmentValues {
    /// How this host presents the post options screen. Default `.sheet` (see
    /// `PostOptionsPresentationMode`).
    var postOptionsPresentation: PostOptionsPresentationMode {
        get { self[PostOptionsPresentationKey.self] }
        set { self[PostOptionsPresentationKey.self] = newValue }
    }
}

// MARK: - The row's actions

/// What a **lookup** row can do, and nothing it cannot.
///
/// `PostRowActions` is also the derivation's host-fact input (`canReply`/`canEdit`/`canDelete`/
/// `canReact`), so this is where "this host draws no composer, picker or draft sink" is stated once:
/// the sheet then cannot offer Reply, React, Edit or Delete on a row whose host could not perform
/// them. The menu itself is always drawn (`showsOptions`), because the six server-backed options are
/// exactly what the lookup surfaces are for.
enum PostOptionsLookupActions {

    /// The actions a lookup row hands `PostRowView`.
    ///
    /// `nil` for a row with no channel id (nothing to resolve a model for, so no ellipsis: an
    /// ellipsis that opens an empty sheet is worse than none — `hasAnyAction`'s own rule).
    static func rowActions(for row: PostRowModel,
                           onShowOptions: @escaping () -> Void) -> PostRowActions? {
        guard !row.post.channelId.isEmpty else { return nil }
        return PostRowActions(canReply: false,
                              canEdit: false,
                              canDelete: false,
                              onReply: {},
                              onEdit: {},
                              onDelete: {},
                              onShowOptions: onShowOptions,
                              canReact: false,
                              onReact: {},
                              showsOptions: true)
    }

    /// The actions the **sheet** derives from. The same four host facts (all false) and the same
    /// `showsOptions`; the sheet's host options are never offered, so their closures never run.
    static var menuOnly: PostRowActions {
        PostRowActions(canReply: false,
                       canEdit: false,
                       canDelete: false,
                       onReply: {},
                       onEdit: {},
                       onDelete: {},
                       onShowOptions: {},
                       canReact: false,
                       onReact: {},
                       showsOptions: true)
    }
}

// MARK: - Resolving the row's channel

enum PostOptionsLookup {

    /// The presentation for one tapped lookup row, or `nil` when the row names no channel.
    ///
    /// The model comes from the coordinator's per-channel cache — the same instance the channel pane
    /// would use — so the sheet, the channel's own menu and the socket feed can never disagree about
    /// this post. It is **not** activated here: the presented screen activates it, so the request
    /// belongs to the sheet that needs the answer (and a sheet dismissed before it lands costs
    /// nothing but the request already sent).
    @MainActor
    static func presentation(for row: PostRowModel,
                             surface: PostOptionsSurface = .channel,
                             server: ServerConfig,
                             panes: ChannelPaneCoordinator) -> PostOptionsPresentation? {
        let channelID = row.post.channelId
        guard !channelID.isEmpty else { return nil }
        return PostOptionsPresentation(row: row,
                                       surface: surface,
                                       options: panes.postOptions(for: server, channelID: channelID))
    }

    /// The read a lookup sheet makes when it opens.
    ///
    /// **No team hint on purpose.** A lookup row can belong to a team that is not the one the shell
    /// is showing (the mentions feed spans teams), and the permalink's segment plus the permission
    /// union belong to the channel's own team — which `activate` resolves from `GET /channels/{id}`.
    /// Handing it the pane's team would reintroduce the wrong-team permalink that `t9acf2b1c` (R2)
    /// repairs in the channel pane; with no hint, a failed channel-team read hides Copy Link instead
    /// of building a link to the wrong team.
    ///
    /// A seam rather than an inline call in the view so the rule is pinned by the unit target
    /// (`T48R1LookupPostOptionsTests`) and not only readable here.
    @MainActor
    static func activate(_ presentation: PostOptionsPresentation) async {
        await presentation.options.activate(teamID: "", teamName: nil)
    }
}

// MARK: - The attach point

/// The one helper a lookup host calls: it reads the container's declared presentation and attaches
/// either `.sheet(item:)` or `.navigationDestination(item:)`.
///
/// Attached to the **list** that raises it (not to the pane's outer view): these panes already carry
/// their author-popover presentation on the outer view, and two `.sheet` modifiers on one view is the
/// shape that silently drops presentations (spec finding F2 in
/// `docs/t_8f9f5449-profile-popover-parity.md` §2.2). One modifier per node, one slot per list.
struct PostOptionsPresentationHost: ViewModifier {
    @Binding var presentation: PostOptionsPresentation?
    /// A write that landed, so a list can settle itself (the Saved tab drops an unsaved row, the
    /// pinned sheet drops an unpinned one). `nil` on hosts whose list is a query snapshot.
    var onPerformed: ((PostOptionID, String) -> Void)?

    @Environment(\.postOptionsPresentation) private var mode

    @ViewBuilder
    func body(content: Content) -> some View {
        switch mode {
        case .sheet:
            content.sheet(item: $presentation) { presented in
                LookupPostOptionsScreen(presentation: presented,
                                        onPerformed: onPerformed,
                                        onClose: { presentation = nil })
            }
        case .push:
            // iOS 17 floor: the item-bound form, so the destination cannot outlive (or contradict)
            // the state. Legal only inside a `NavigationStack` — both push hosts above are.
            content.navigationDestination(item: $presentation) { presented in
                LookupPostOptionsScreen(presentation: presented, pushed: true,
                                        onPerformed: onPerformed)
            }
        }
    }
}

extension View {
    /// Attach this list's post-options presentation (sheet or push — see
    /// `PostOptionsPresentationMode`).
    func postOptionsPresentationHost(_ presentation: Binding<PostOptionsPresentation?>,
                                     onPerformed: ((PostOptionID, String) -> Void)? = nil) -> some View {
        modifier(PostOptionsPresentationHost(presentation: presentation, onPerformed: onPerformed))
    }
}

// MARK: - The screen both forms draw

/// `PostOptionsSheet` plus the one thing a lookup row needs and a channel row does not: the read
/// that answers "what may I do in *this* channel".
///
/// The activation runs while the sheet is already up: the option rows that need no channel state
/// (copy text, save) are usable at once, and the ones that do (pin, copy link, unsave) appear when
/// their answer lands rather than being guessed.
private struct LookupPostOptionsScreen: View {
    let presentation: PostOptionsPresentation
    var pushed = false
    var onPerformed: ((PostOptionID, String) -> Void)?
    var onClose: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        content
            // No team hint: a lookup row's team is the channel's own (`GET /channels/{id}`), not
            // the team the shell happens to be showing — `PostOptionsLookup.activate` states it and
            // the unit target pins it.
            .task { await PostOptionsLookup.activate(presentation) }
    }

    @ViewBuilder
    private var content: some View {
        if pushed {
            sheet(showsCancel: false)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("postOptionsPush")
        } else {
            sheet(showsCancel: true)
        }
    }

    private func sheet(showsCancel: Bool) -> some View {
        PostOptionsSheet(rowID: presentation.row.id,
                         authorName: presentation.row.author.displayName,
                         row: presentation.row,
                         actions: PostOptionsLookupActions.menuOnly,
                         surface: presentation.surface,
                         options: presentation.options,
                         onDismiss: pushed ? { dismiss() } : onClose,
                         showsCancel: showsCancel,
                         onPerformed: onPerformed)
    }
}
