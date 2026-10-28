// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/thread/index.tsx (the screen's data pass and read marking),
//        app/screens/thread/thread_content.tsx (header + post list + composer),
//        app/screens/thread/thread_post_list/thread_post_list.tsx (the root first, then replies,
//        "load earlier" above), app/screens/thread/thread_follow_button/thread_follow.tsx (the
//        bell toggle), app/components/post_list/thread_overview/thread_overview.tsx (the reply
//        count + participant stack under a root).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §13; no
// upstream source copied.
//
// Layout note (Path A, iOS): upstream pushes a THREAD screen on a phone and shows it in the RHS on
// a tablet. This shell renders it as the same `NativeDestinationPaneView` detail in both layouts
// (pushed in compact, a detail column in regular), so the two layouts cannot drift — that is the
// T30 decision, not a T36 one.

import SwiftUI

/// The thread screen: one root post, its replies, a follow toggle and a reply composer.
struct ThreadPaneContent: View {
    let server: ServerConfig
    let rootID: String
    /// The root's channel when the caller knows it (opened from the channel timeline). Empty when the
    /// pane was reached by a permalink or the global list: the model fills it from the root post.
    var channelID: String = ""
    @ObservedObject var navigation: NativeNavigation

    @EnvironmentObject private var threads: ThreadCoordinator
    @EnvironmentObject private var panes: ChannelPaneCoordinator
    @EnvironmentObject private var resolver: SurfaceModeResolver
    /// T38: the app's one download journal (a reply's attachment saves to the same Downloads screen).
    @EnvironmentObject private var downloadWorker: DownloadWorker

    @State private var model: ThreadViewModel?
    @State private var composer: ComposerViewModel?
    @State private var imageStore: ChannelImageStore?
    /// This server's profile pictures (one cache per server; the reply rows draw the same faces the
    /// channel timeline does).
    @State private var avatarStore: AvatarImageStore?
    @State private var emoji: EmojiCatalogue?
    /// T37: recently-used emoji, the same store the channel pane records into.
    @State private var emojiRecents: EmojiRecentsStore?
    /// T38: attachment save state (shared per server with the channel pane).
    @State private var attachmentDownloads: AttachmentDownloads?
    /// T48: the root channel's post-options state (permissions, saved set, pin patches). Resolved once
    /// the thread's root names its channel — a permalink does not carry one.
    @State private var postOptions: PostOptionsViewModel?

    /// Whether the write surface renders natively (T35's `.composer` surface). The thread's reply box
    /// is that same surface: with it on `.web` the reader gets the webview's composer, so the native
    /// pane must not open a second, competing draft/send path.
    private var composerIsNative: Bool {
        resolver.resolvedMode(for: .composer) == .native
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let model {
                ThreadPostListView(model: model,
                                   imageStore: imageStore,
                                   emoji: emoji,
                                   rowActions: rowActions,
                                   recents: emojiRecents,
                                   attachmentDownloads: attachmentDownloads,
                                   postOptions: postOptions)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("threadPane.loading")
            }
            Divider()
            if composerIsNative, let composer {
                ComposerView(model: composer, emoji: emoji, recents: emojiRecents)
            } else {
                composerPlaceholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("threadPane")
        .environment(\.avatarImages, avatarStore)
        .task(id: rootID) {
            imageStore = panes.imageStore(for: server)
            avatarStore = panes.avatarStore(for: server)
            let catalogue = panes.emojiCatalogue(for: server)
            emoji = catalogue
            let recents = panes.emojiRecents(for: server)
            emojiRecents = recents
            attachmentDownloads = panes.attachmentDownloads(for: server, worker: downloadWorker)
            let resolved = await threads.activate(server: server,
                                                  rootID: rootID,
                                                  channelID: channelID.isEmpty ? nil : channelID)
            model = resolved
            // T37: a react recorded here is the same list the channel pane's picker shows.
            resolved.onEmojiUsed = { name in recents.record(name) }
            // Opening a thread is reading it. Upstream marks the thread read on mount, and this
            // write is the only thing that can clear a badge: the server's `PUT …/read/{ts}`
            // answers the thread with its counters already applied (`ThreadViewModel.markRead`
            // takes that answer, and swallowing a failure is deliberate — reading must not become
            // an error screen). Without this call a thread's unread counter never moves after a
            // reader opened the pane, which is what left criterion 4 unobservable (T36-AV F4).
            await resolved.markRead()
            // T48: the post-options state for the root's channel. Created after the load because a
            // permalink reaches this pane without a channel id; the surface is `.thread`, so the sheet
            // withholds Follow (the bell above is this screen's follow affordance — upstream's own
            // `sourceScreen !== CHANNEL` rule).
            if let rootChannel = resolved.root?.channelId, !rootChannel.isEmpty {
                let options = panes.postOptions(for: server, channelID: rootChannel)
                options.onPinChange = { postID, pinned in
                    resolved.applyPin(postID: postID, isPinned: pinned)
                }
                postOptions = options
                await options.activate(teamID: navigation.location.request.teamID ?? "",
                                       teamName: navigation.location.request.teamName)
            }
            // The composer needs the root's channel, which a permalink does not carry: it is created
            // after the load, not before.
            if composerIsNative, let built = threads.composer(for: server, model: resolved,
                                                              emojiCatalogue: catalogue) {
                composer = built
            }
            await catalogue.loadNamesIfNeeded()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Thread")
                    .font(.headline)
                    .accessibilityIdentifier("threadPane.title")
                if let model {
                    Text(subtitle(model))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("threadPane.subtitle")
                }
            }
            Spacer(minLength: 8)
            if let model, model.phase == .loaded {
                ThreadFollowButton(model: model)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    /// "3 replies · #dev — last reply 2:15 PM". The count is the server's when it has one (a thread
    /// can have more replies than this pane has loaded), otherwise what is on screen.
    private func subtitle(_ model: ThreadViewModel) -> String {
        var parts: [String] = []
        if let count = ThreadDerivation.replyLabel(model.replyCount) {
            parts.append(count)
        } else {
            parts.append("No replies yet")
        }
        if let name = model.root?.channelId, !name.isEmpty, let channelName = navigation.location.channelName,
           navigation.location.channelID == name {
            parts.append("#\(channelName)")
        }
        if let badge = model.unread.badge {
            parts.append(badge)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Row menu

    /// The same menu the channel timeline offers, pointed at this thread's composer: Reply stays in
    /// this thread (the root is the thread), edit/delete stay mine-only.
    ///
    /// T48: as in the channel pane, the overflow button no longer requires a native composer — the
    /// options that do not touch it (copy text/link, save, pin, mark unread) are offered either way.
    private var rowActions: (PostRowModel) -> PostRowActions? {
        { row in
            guard !row.isSystem, !row.isDeleted, !row.isPending else { return nil }
            var menu: (reply: Bool, edit: Bool, delete: Bool)?
            if composerIsNative, let composer {
                menu = ComposerRowPermissions.menu(postUserID: row.post.userId,
                                                   authorID: composer.authorID,
                                                   isSystem: row.isSystem,
                                                   isDeleted: row.isDeleted,
                                                   isPending: row.isPending)
            }
            return PostRowActions(canReply: menu?.reply ?? false,
                                  canEdit: menu?.edit ?? false,
                                  canDelete: menu?.delete ?? false,
                                  onReply: {
                                      // `root_id` is the thread's ROOT, never the tapped reply's
                                      // id: a thread nests one level, so a nested id either errors
                                      // or orphans the post (t_56159748, defect 2). The banner
                                      // still addresses the person whose row was tapped — the
                                      // label and the root are different things, which is why the
                                      // rule lives in one place (`ThreadViewModel.replyTarget`).
                                      guard let model,
                                            let target = model.replyTarget(from: row) else { return }
                                      composer?.beginReply(to: target.root,
                                                           authorLabel: target.authorLabel)
                                  },
                                  onEdit: { composer?.beginEditing(row.post) },
                                  onDelete: {
                                      guard let composer else { return }
                                      Task { await composer.delete(postID: row.post.id) }
                                  },
                                  onShowOptions: {})
        }
    }

    /// Drawn when the `.composer` surface is the webview's (the default until T35-AV approves the
    /// flip), and for the frame before the root's channel is known.
    private var composerPlaceholder: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrowshape.turn.up.left")
                .foregroundStyle(.secondary)
            Text(model == nil ? "Reply" : "Reply in the web view")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .accessibilityIdentifier("threadPane.composerPlaceholder")
    }
}

/// The bell: follow / unfollow this thread (`thread_follow_button`).
struct ThreadFollowButton: View {
    @ObservedObject var model: ThreadViewModel

    var body: some View {
        Button {
            Task { await model.toggleFollow() }
        } label: {
            Image(systemName: model.isFollowing ? "bell.fill" : "bell.slash")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(model.isFollowing ? Color.accentColor : .secondary)
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.followState == .unknown)
        .accessibilityLabel(model.isFollowing ? "Following thread" : "Follow thread")
        .accessibilityValue(model.isFollowing ? "on" : "off")
        .accessibilityIdentifier("threadPane.follow")
    }
}

/// The thread's post list: "load earlier" above, then the root and its replies.
struct ThreadPostListView: View {
    @ObservedObject var model: ThreadViewModel
    let imageStore: ChannelImageStore?
    var emoji: EmojiCatalogue?
    var rowActions: ((PostRowModel) -> PostRowActions?)? = nil
    /// T37: the picker's recently-used row, shared with the channel pane's store.
    var recents: EmojiRecentsStore? = nil
    /// T38: the per-server attachment download state (nil leaves the section inert).
    var attachmentDownloads: AttachmentDownloads? = nil
    /// T48: the root channel's post-options state. Nil keeps the pre-T48 sheet.
    var postOptions: PostOptionsViewModel? = nil

    /// One item-bound sheet for this list (options, T37's picker and reactor list).
    @State private var sheet: ChannelListSheet?

    var body: some View {
        Group {
            switch model.phase {
            case .idle, .loading:
                loadingState
            case .failed(let message):
                failureState(message)
            case .loaded:
                if model.items.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { failureBanner }
        .sheet(item: $sheet) { sheet in
            sheetContent(sheet)
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: ChannelListSheet) -> some View {
        switch sheet {
        case .options(let row):
            if let actions = actions(for: row), let postOptions {
                PostOptionsSheet(rowID: row.id,
                                 authorName: row.author.displayName,
                                 row: row,
                                 actions: actions,
                                 surface: .thread,
                                 options: postOptions,
                                 onDismiss: { self.sheet = nil })
            }
        case .picker(let postID):
            EmojiPickerView(
                model: EmojiPickerViewModel(mode: .reaction,
                                            catalogue: emoji,
                                            recents: recents,
                                            onPick: { item in
                                                self.sheet = nil
                                                model.toggleReaction(postID: postID,
                                                                     emojiName: item.name)
                                            }),
                emoji: emoji)
        case .reactors(let postID, let emojiName):
            ReactionSheetView(source: model,
                              postID: postID,
                              initialEmoji: emojiName,
                              emojiCatalogue: emoji)
        case .gallery(let target):
            AttachmentGalleryView(target: target,
                                  imageStore: imageStore,
                                  downloads: attachmentDownloads,
                                  onClose: { self.sheet = nil })
        case .preview(let target):
            AttachmentPreviewView(target: target,
                                  imageStore: imageStore,
                                  downloads: attachmentDownloads,
                                  onClose: { self.sheet = nil })
        }
    }

    /// A failed react inside the thread, where the reader is looking (`ReactionCoordinator` keeps the
    /// most recent one).
    @ViewBuilder
    private var failureBanner: some View {
        if let failure = model.reactions.lastFailure {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                Text(failure)
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    model.reactions.clearFailure()
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                }
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier("threadReactions.error.dismiss")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .accessibilityIdentifier("threadReactions.error")
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    loadEarlier
                    ForEach(model.items) { item in
                        rowView(item)
                            .id(item.id)
                    }
                }
                .padding(.bottom, 12)
            }
            .accessibilityIdentifier("threadPostList")
            // A thread opens at its newest reply: the root's context is one screen up, and the reply
            // the notification/mention pointed at is what the reader came for.
            .onChange(of: model.items.count) { previous, current in
                guard current > previous, let last = model.items.last else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onAppear {
                guard let last = model.items.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private var loadEarlier: some View {
        if model.hasMore || model.isLoadingMore || model.loadEarlierError != nil {
            HStack(spacing: 8) {
                Button {
                    Task { await model.loadEarlier() }
                } label: {
                    if model.isLoadingMore {
                        ProgressView()
                    } else {
                        Text("Load earlier replies")
                            .font(.footnote.weight(.semibold))
                    }
                }
                .disabled(model.isLoadingMore)
                .accessibilityIdentifier("threadPostList.loadEarlier")
                if let error = model.loadEarlierError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("threadPostList.loadEarlierError")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private func rowView(_ item: PostListItem) -> some View {
        switch item {
        case .dateSeparator(let separator):
            PostDateSeparatorView(separator: separator)
        case .newMessages:
            NewMessagesDividerView()
        case .gap(let gap):
            // A thread's window is loaded whole (root + every reply), so it never produces one; the
            // case is drawn anyway rather than swallowing it, so the two lists cannot drift.
            PostListGapView(gap: gap)
        case .post(let row):
            PostRowView(row: row,
                        isExpanded: model.isExpanded(row.id),
                        imageStore: imageStore,
                        emoji: emoji,
                        onToggleExpanded: { model.toggleExpanded(row.id) },
                        actions: actions(for: row),
                        reactionActions: reactionActions(for: row),
                        attachmentActions: attachmentActions(for: row))
                // A reply in a thread can itself be a root for the channel's reply line but never
                // opens a second thread: the reply line is withheld here.
                .accessibilityIdentifier("thread.post.\(row.id)")
        }
    }

    private func actions(for row: PostRowModel) -> PostRowActions? {
        guard var supplied = rowActions?(row) else { return nil }
        supplied.onShowOptions = { sheet = .options(row) }
        supplied.canReact = true
        supplied.onReact = { sheet = .picker(postID: row.id) }
        // T48: the sheet is only drawable when this list has the state it derives from.
        supplied.showsOptions = postOptions != nil
        return supplied
    }

    /// The row's attachment handlers (T38) — the same rule as the channel list: gated on a download
    /// coordinator, and the gallery target carries this row's own attachments.
    private func attachmentActions(for row: PostRowModel) -> PostRowAttachmentActions? {
        guard let attachmentDownloads else { return nil }
        return PostRowAttachmentActions(
            downloads: attachmentDownloads,
            onOpenImage: { fileID in
                guard row.attachments.contains(where: { $0.id == fileID }) else { return }
                sheet = .gallery(AttachmentGalleryTarget(postID: row.id,
                                                         attachments: row.attachments,
                                                         startFileID: fileID))
            },
            onOpenFile: { fileID in
                guard let attachment = row.attachments.first(where: { $0.id == fileID }) else {
                    return
                }
                sheet = .preview(AttachmentPreviewTarget(postID: row.id, attachment: attachment))
            })
    }

    /// Pills are pressable when this host supplied a row menu (the write surface is native) and the
    /// post has something in its bar. A thread replies live in the same coordinator as the channel
    /// pane, so a react here reaches the same post there.
    private func reactionActions(for row: PostRowModel) -> PostRowReactionActions? {
        guard rowActions != nil, !row.reactions.isEmpty else { return nil }
        return PostRowReactionActions(
            onToggle: { name in model.toggleReaction(postID: row.id, emojiName: name) },
            onShowReactors: { name in sheet = .reactors(postID: row.id, emojiName: name) },
            onAdd: { sheet = .picker(postID: row.id) })
    }

    // MARK: States

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Loading thread…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("threadPostList.loading")
    }

    private func failureState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.bubble")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Try again") {
                Task { await model.retry() }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("threadPostList.retry")
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("threadPostList.failed")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("This thread is empty.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("threadPostList.empty")
    }
}
