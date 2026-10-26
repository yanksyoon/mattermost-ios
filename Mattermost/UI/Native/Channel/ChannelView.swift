// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/channel/channel_post_list/channel_post_list.tsx (the FlatList, the
//        "load more"/`onEndReached`-equivalent-at-top behaviour, `ListEmptyComponent`, the retry on
//        failure), app/screens/channel/channel_post_list/intro/intro.tsx (empty-channel copy),
//        app/components/post_list/ (item rendering), app/screens/channel/channel.tsx (header title,
//        the Threads affordance), post_textbox (the composer — not this card, S14/T35).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §10; no
// upstream source copied. SwiftUI decomposition is this repo's own (component-map.md §1).
//
// Scroll-position contract (the reason this file is not a bare `ForEach`):
// the reader's place is a **post + its offset from the top**, captured from row geometry, and after
// an older page is prepended the view scrolls back to *that post* — so the text the reader was
// reading does not move. `ChannelViewModel.pendingScrollRestore` is the handoff; this file is the only
// place that turns it into a scroll.

import SwiftUI

/// The sheets the channel window can present (T35 options, T37 picker and reactor list).
///
/// One item-bound sheet (`ChannelPostListView.sheet`) rather than one per feature, so a presentation
/// cannot be silently swallowed by a second `.sheet` modifier in the same view.
enum ChannelListSheet: Identifiable {
    case options(PostRowModel)
    /// The emoji picker, opened for one post's reaction.
    case picker(postID: String)
    /// Who reacted with one emoji.
    case reactors(postID: String, emojiName: String)
    /// T38: the full-screen image gallery for one post, starting at one image.
    case gallery(AttachmentGalleryTarget)
    /// T38: one file's preview (PDF, text, or the safe "not previewed" screen).
    case preview(AttachmentPreviewTarget)

    var id: String {
        switch self {
        case .options(let row): return "options.\(row.id)"
        case .picker(let postID): return "picker.\(postID)"
        case .reactors(let postID, let emojiName): return "reactors.\(postID).\(emojiName)"
        case .gallery(let target): return "gallery.\(target.id)"
        case .preview(let target): return "preview.\(target.id)"
        }
    }
}

/// The post list for one channel: rows, day separators, the unread divider, and the "load earlier"
/// sentinel that is also the pagination trigger.
struct ChannelPostListView: View {
    @ObservedObject var model: ChannelViewModel
    let imageStore: ChannelImageStore?
    var emoji: EmojiCatalogue?
    /// What a reader can do with a row (T35). Nil keeps the pre-T35 read-only rendering.
    var rowActions: ((PostRowModel) -> PostRowActions?)? = nil
    /// T36: what a tap on a root's reply line does — opens that thread. Nil leaves the line inert
    /// (a preview, or the web render of the pane).
    var onOpenThread: ((PostRowModel) -> Void)? = nil
    /// T37: the recently-used emoji the picker opens with. Nil is a picker with no recent row.
    var recents: EmojiRecentsStore? = nil
    /// T38: the per-server attachment download state. Nil leaves the attachment section inert (a
    /// preview host, or a pane whose host does not offer a write surface).
    var attachmentDownloads: AttachmentDownloads? = nil

    /// True while a top visit must not page: the reader has not been away from the top since the last
    /// auto-load, so this is the same visit. Cleared once the viewport is a screen away from the top.
    @State private var mustLeaveTopBeforePaging = true
    @State private var readerIsAtBottom = true
    @StateObject private var scrollController = ChannelScrollController()
    /// The one sheet this window presents (T35's options, T37's picker and reactor list).
    ///
    /// A single item-bound sheet rather than three `.sheet` modifiers: on the same view SwiftUI keeps
    /// only the last presentation in some states, and a row's overflow button, a pill's long press and
    /// a `+` chip all have to be able to win.
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

    // MARK: Sheets (T35 options, T37 picker and reactors)

    @ViewBuilder
    private func sheetContent(_ sheet: ChannelListSheet) -> some View {
        switch sheet {
        case .options(let row):
            if let actions = actions(for: row) {
                PostOptionsSheet(rowID: row.id,
                                 authorName: row.author.displayName,
                                 actions: actions,
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

    /// The reaction write that failed, where the reader is looking. Dismissible, and only ever one at
    /// a time: the coordinator keeps the most recent failure, which is the one worth naming.
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
                .accessibilityIdentifier("channelReactions.error.dismiss")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .accessibilityIdentifier("channelReactions.error")
        }
    }

    // MARK: List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Finds the UIScrollView so a restore can use a point offset (see
                    // ChannelScrollPosition.swift). Zero-height, so it costs no layout.
                    ScrollViewResolver(controller: scrollController)
                        .frame(width: 0, height: 0)
                    loadEarlierSentinel
                    ForEach(model.items) { item in
                        rowView(item)
                            .id(item.id)
                    }
                    if model.hasMore {
                        ProgressView()
                            .padding(.vertical, 12)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.bottom, 12)
            }
            .coordinateSpace(name: "channelScroll")
            .accessibilityIdentifier("channelPostList")
            // T39: a jump (a tapped search result, a saved message, a pinned one) scrolls to its post.
            // The loop is deliberate: a jumped-to post that had to be *fetched* is merged into the
            // window at the same moment the scroll is asked for, and a `LazyVStack` measures a new row
            // a pass later — one `scrollTo` at that moment lands short of it or on nothing.
            .onChange(of: model.jumpTarget) { _, target in
                guard let target else { return }
                Task { @MainActor in
                    for _ in 0..<12 {
                        if scrollController.offsetFromTop(ofRow: target) != nil { break }
                        proxy.scrollTo("post-\(target)", anchor: .center)
                        try? await Task.sleep(for: .milliseconds(60))
                    }
                    proxy.scrollTo("post-\(target)", anchor: .center)
                    try? await Task.sleep(for: .milliseconds(120))
                    model.consumeJump()
                }
            }
            // A conversation opens at its newest message, the way every chat client does. On iOS 18
            // the anchor is scoped to the *initial* offset, so a post that expands above the reader
            // no longer scrolls them down the list; iOS 17 has no such scope, which is why the fold
            // toggle also runs the reader's restore (`toggleExpanded`).
            .modifier(InitialBottomAnchor())
            .onChange(of: model.items.count) { previous, current in
                // The first page arrives after the view exists, and `LazyVStack` measures rows as it
                // goes, so one scroll issued at that moment lands short of the end. Pin, re-measure,
                // pin again until the bottom is actually reached.
                guard previous == 0, current > 0 else { return }
                Task { @MainActor in await pinToBottom() }
            }
            .onChange(of: model.items.last?.id) { previous, current in
                // A post that arrives over the socket while the reader is looking at the newest
                // message must not leave them behind. `readerIsAtBottom` still holds the pre-insert
                // measurement here: preference changes land after this callback.
                guard previous != nil, current != nil, readerIsAtBottom else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(50))
                    scrollController.scrollToBottom()
                }
            }
            .onChange(of: model.pendingScrollRestore) { _, restore in
                guard let restore else { return }
                Task { @MainActor in
                    await restoreReader(restore, proxy: proxy)
                }
            }
            .task(id: model.channelID) {
                // The reader's position is owned by UIKit, so a timer on it is the only check that does
                // not depend on SwiftUI deciding that some row's frame changed. Cheap (8 Hz, and only
                // while this pane is on screen) and it is what makes "reaching the top pages older
                // posts in" a property of the scroll view rather than of a callback's timing.
                //
                // It is also what records the anchor: `loadEarlier()` refreshes it through
                // `readerAnchorProvider` before it sends the request, so the place the restore aims at
                // is taken from the same scroll view, at the same instant, as the request.
                model.readerAnchorProvider = { [weak scrollController] in
                    guard let scrollController else { return nil }
                    return scrollController.captureReaderPlace().map {
                        ChannelViewModel.ScrollAnchor(postID: $0.postID,
                                                      offsetFromTop: $0.offsetFromTop)
                    }
                }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled else { return }
                    pollReaderPosition()
                }
            }
        }
    }

    /// Put the anchored post back where the reader left it.
    ///
    /// The older page was inserted *above* the anchor, so the anchor moved down by the height of that
    /// page; scrolling the content up by exactly that difference leaves the reader looking at the same
    /// pixels. The correction is applied through the scroll view's `contentOffset` (a point offset, not
    /// a row edge), which keeps a reader who was half-way through a post from being moved by up to a
    /// row height — the case `scrollTo(anchor: .top)` cannot express.
    ///
    /// Every number in the loop is measured from the row's own `UIView` at the moment it is read
    /// (`ChannelScrollController.offsetFromTop`), so the loop is a closed control system: measure,
    /// correct the residual, measure again. That is why a correction cannot be applied twice — the
    /// second measurement *contains* the first correction, and reads ~0 if it was right. R3 combined a
    /// SwiftUI preference value from one layout pass with a content offset read a moment later; the
    /// mismatch reapplied the move, and the live anchor test measured the row 585 pt from where it was.
    ///
    /// The row can be un-laid-out after the insert (a page pushes it a few screens down, and a lazy
    /// stack drops off-screen rows). Then `ScrollViewReader` is asked to bring it back, and the loop
    /// measures again from there.
    @MainActor
    private func restoreReader(_ restore: ChannelViewModel.ScrollAnchor,
                               proxy: ScrollViewProxy) async {
        let baseHeight = scrollController.lastPlace?.contentHeight ?? scrollController.contentHeight
        var unchangedRuns = 0
        var previousHeight = scrollController.contentHeight
        for _ in 0..<75 {                      // ~1.2 s at 16 ms; the insert lays out in a frame or two
            try? await Task.sleep(for: .milliseconds(16))
            // A layout that has not run yet still reports the *old* positions, which read as "no
            // correction needed". Content height is what tells the two apart, so an early exit needs
            // both: the content has been re-laid-out *and settled*, and the anchor is where it belongs.
            let height = scrollController.contentHeight
            let laidOut = abs(height - baseHeight) > 1 && abs(height - previousHeight) <= 1
            previousHeight = height

            if let measured = scrollController.offsetFromTop(ofRow: restore.postID) {
                let adjustment = ScrollRestorePlan.adjustment(
                    recordedOffsetFromTop: restore.offsetFromTop,
                    currentOffsetFromTop: measured)
                if ScrollRestorePlan.isNoOp(adjustment) {
                    unchangedRuns = laidOut ? unchangedRuns + 1 : 0
                    if unchangedRuns >= 3 {
                        model.consumeScrollRestore()
                        return
                    }
                } else {
                    unchangedRuns = 0
                    _ = scrollController.scroll(by: adjustment)
                }
                continue
            }

            // Not laid out: bring it back with SwiftUI's own scroll-to, then put the recorded distance
            // back above it with a point offset.
            unchangedRuns = 0
            proxy.scrollTo("post-\(restore.postID)", anchor: .top)
            try? await Task.sleep(for: .milliseconds(16))
            if let measured = scrollController.offsetFromTop(ofRow: restore.postID) {
                let adjustment = ScrollRestorePlan.adjustment(
                    recordedOffsetFromTop: restore.offsetFromTop,
                    currentOffsetFromTop: measured)
                if !ScrollRestorePlan.isNoOp(adjustment) {
                    _ = scrollController.scroll(by: adjustment)
                }
            }
        }
        model.consumeScrollRestore()
    }

    @ViewBuilder
    private func rowView(_ item: PostListItem) -> some View {
        switch item {
        case .dateSeparator(let separator):
            PostDateSeparatorView(separator: separator)
        case .newMessages:
            NewMessagesDividerView()
        case .gap(let gap):
            PostListGapView(gap: gap)
        case .post(let row):
            PostRowView(row: row,
                        isExpanded: model.isExpanded(row.id),
                        imageStore: imageStore,
                        emoji: emoji,
                        onToggleExpanded: { toggleExpanded(row.id) },
                        actions: actions(for: row),
                        onOpenThread: onOpenThread.map { open in { open(row) } },
                        reactionActions: reactionActions(for: row),
                        attachmentActions: attachmentActions(for: row))
                // The row's own UIView, so the restore can measure where the reader is without
                // going through a SwiftUI preference (see ChannelScrollPosition.swift).
                .background(RowAnchorProbe(postID: row.id, controller: scrollController))
                // T39: the post a jump landed on keeps a marking bar until the reader searches again.
                // A leaf of its own (rather than an accessibility value on the row) so a UI test can
                // assert the jump landed without depending on how the row's element resolves.
                .overlay(alignment: .leading) {
                    if model.focusedPostID == row.id {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: 3)
                            .accessibilityElement()
                            .accessibilityLabel("Focused message")
                            .accessibilityIdentifier("postFocus.\(row.id)")
                    }
                }
        }
    }

    /// The row's actions, with the options presentation wired to this window.
    private func actions(for row: PostRowModel) -> PostRowActions? {
        guard var supplied = rowActions?(row) else { return nil }
        supplied.onShowOptions = { sheet = .options(row) }
        // A host that supplied row actions can always reach the picker: the menu is the way to react
        // to a message that has no pills yet (the bar only appears once there is something in it).
        supplied.canReact = true
        supplied.onReact = { sheet = .picker(postID: row.id) }
        return supplied
    }

    /// The row's reaction handlers, when this host is interactive at all.
    ///
    /// Gated on `rowActions` for the same reason the options sheet is: a preview or a read-only host
    /// (the web render's fallback) draws the pills but must not send a write.
    private func reactionActions(for row: PostRowModel) -> PostRowReactionActions? {
        guard rowActions != nil, !row.reactions.isEmpty else { return nil }
        return PostRowReactionActions(
            onToggle: { name in model.toggleReaction(postID: row.id, emojiName: name) },
            onShowReactors: { name in sheet = .reactors(postID: row.id, emojiName: name) },
            onAdd: { sheet = .picker(postID: row.id) })
    }

    /// The row's attachment handlers (T38).
    ///
    /// Gated on `attachmentDownloads` for the same reason the options sheet is gated on `rowActions`:
    /// a read-only host draws the thumbnails and rows but must not open a gallery whose Save button
    /// starts a download. The gallery target carries **this row's own** attachments, so the sheet can
    /// never show a different set than the row did.
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

    /// Expand or collapse a post without moving the post's own position on screen.
    ///
    /// A fold can change a row's height by thousands of points, and every row below it moves with it.
    /// The post being toggled is the reader's anchor here, and the same point-offset restore that
    /// serves `loadEarlier` puts it back.
    private func toggleExpanded(_ postID: String) {
        if let current = scrollController.offsetFromTop(ofRow: postID) {
            model.requestScrollRestore(ChannelViewModel.ScrollAnchor(postID: postID,
                                                                     offsetFromTop: current))
        }
        model.toggleExpanded(postID)
    }

    /// Reach the true bottom of a freshly loaded page.
    ///
    /// `LazyVStack` gives an unmeasured row an estimated height, so a single scroll computed when the
    /// first page lands can stop a screen short — a 600-line post that folds to 400 pt still measured
    /// as if it were one line. Repeat until two consecutive measurements agree that the end is here.
    @MainActor
    private func pinToBottom() async {
        var settled = 0
        for _ in 0..<25 {
            guard scrollController.isAttached else {
                try? await Task.sleep(for: .milliseconds(16))
                continue
            }
            if scrollController.isAtBottom {
                settled += 1
                if settled >= 2 { return }
            } else {
                settled = 0
                scrollController.scrollToBottom()
            }
            try? await Task.sleep(for: .milliseconds(32))
        }
    }

    /// One look at where the reader is: keep the anchor honest and page when they reach the top.
    ///
    /// Run from a timer rather than from a preference callback. `onPreferenceChange` only fires when a
    /// *row's* frame changes, and a fast swipe can take the viewport to the top between two such
    /// updates; a live UI run sat at the top for 40 s with the sentinel visible and nothing paging.
    private func pollReaderPosition() {
        guard scrollController.isAttached else { return }
        let distance = scrollController.distanceFromTop
        let userScrolling = scrollController.isUserScrolling
        readerIsAtBottom = scrollController.distanceFromBottom <= 40
        // The latch is re-armed only by the reader travelling away from the top *by hand*. A merge
        // lengthens the content above them, which also makes `distance` large — treating that as "they
        // left the top" is what let one visit page in three windows' worth of posts.
        if userScrolling, distance > 320 { mustLeaveTopBeforePaging = false }
        // Nothing to scroll at all: a window shorter than a screen is both ends at once and should
        // fill itself.
        if scrollController.contentFitsViewport { mustLeaveTopBeforePaging = false }
        // A restore in flight owns the position: recording an anchor from the half-restored layout
        // would hand the next `loadEarlier` a place the reader never was.
        if model.pendingScrollRestore == nil {
            scrollController.captureReaderPlace()   // also refreshes the anchor the next load uses
        }
        guard !mustLeaveTopBeforePaging, distance <= 8,
              model.hasMore, !model.isLoadingMore, model.loadEarlierError == nil,
              model.pendingScrollRestore == nil else { return }
        mustLeaveTopBeforePaging = true
        Task { await model.loadEarlier() }
    }

    /// The top of the loaded window. Tappable *and* auto-firing: reaching the top is how the reader
    /// asks for older posts, and a short window (fewer posts than a screen) should fill itself.
    private var loadEarlierSentinel: some View {
        Button {
            Task { await model.loadEarlier() }
        } label: {
            HStack(spacing: 8) {
                if model.isLoadingMore {
                    ProgressView().controlSize(.small)
                    Text("Loading earlier messages…")
                } else if let error = model.loadEarlierError {
                    Image(systemName: "exclamationmark.circle")
                    Text(error)
                } else if model.hasMore {
                    Image(systemName: "arrow.up.circle")
                    Text("Load earlier messages")
                } else {
                    Image(systemName: "checkmark.circle")
                    Text("This is the beginning of the channel")
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .disabled(!model.hasMore || model.isLoadingMore)
        .onAppear { requestEarlierIfTheReaderIsActuallyAtTheTop() }
        .accessibilityIdentifier("channelPostList.loadEarlier")
    }

    /// Auto-load older posts when the sentinel reaches the reader.
    ///
    /// `onAppear` in a `LazyVStack` fires whenever the row is *realized*, and every merge re-realizes it,
    /// so an unguarded `onAppear` turned "one page per visit to the top" into a cascade: a live run
    /// paged three windows in while the reader sat still (the pane's oldest post was the third page's,
    /// not the second's). The scroll position decides, not the callback: the sentinel is the first row
    /// of the content, so it is only on screen when the reader is within a screen of the top.
    private func requestEarlierIfTheReaderIsActuallyAtTheTop() {
        guard !mustLeaveTopBeforePaging, model.hasMore, !model.isLoadingMore,
              model.loadEarlierError == nil else { return }
        guard scrollController.distanceFromTop <= 320 else { return }
        mustLeaveTopBeforePaging = true
        Task { await model.loadEarlier() }
    }

    // MARK: States

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Loading messages…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("channelPostList.loading")
    }

    private func failureState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("channelPostList.error")
            Button("Try again") { Task { await model.retry() } }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("channelPostList.retry")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("No messages yet")
                .font(.headline)
            Text("This is the start of the channel. Say something to get it going.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("channelPostList.empty")
    }
}

// MARK: - Pane content

/// One channel's pane: header (title + Threads) over the post list, plus the composer's stand-in.
///
/// The header keeps `nativeChannelTitle` / `nativeChannelThreadsButton` from T30's placeholder — the
/// pane's contract does not change because its middle became real.
struct ChannelPaneContent: View {
    let server: ServerConfig
    let channelID: String
    let channelName: String?
    @ObservedObject var navigation: NativeNavigation
    /// T39: a post this pane must land on (a tapped search result, a saved or pinned message).
    ///
    /// Passed by the router (`NativeChannelPaneView` takes it from `NativeLocation.postID`), so a
    /// search result, a notification tap and a permalink all arrive the same way. The pane loads the
    /// channel first and then asks the model to focus the post — which fetches it when the first page
    /// does not hold it.
    var focusPostID: String? = nil

    @EnvironmentObject private var panes: ChannelPaneCoordinator
    @EnvironmentObject private var resolver: SurfaceModeResolver
    /// T38: the app's one download journal (`MattermostApp` mounts it), so a save from a row is the
    /// same record the Downloads screen lists.
    @EnvironmentObject private var downloadWorker: DownloadWorker
    @Environment(\.scenePhase) private var scenePhase

    @State private var model: ChannelViewModel?
    @State private var imageStore: ChannelImageStore?
    @State private var emoji: EmojiCatalogue?
    /// T37: the recently-used emoji, resolved once per server pane (see the coordinator's cache).
    @State private var emojiRecents: EmojiRecentsStore?
    @State private var composer: ComposerViewModel?
    /// T38: attachment save state for this server's rows.
    @State private var attachmentDownloads: AttachmentDownloads?
    /// T39: the pinned-messages sheet for this channel (S21).
    @State private var showsPinned = false
    /// T40: the channel-info sheet (S22/S23 + the member/settings screens behind it).
    @State private var showsChannelInfo = false

    /// Whether the write surface renders natively (T35's `.composer` surface).
    ///
    /// The composer is a surface of its own in the dual-render switch, not part of `.channelView`:
    /// a reader can have the native post list with the webview's composer right below it, which is
    /// exactly the state a partial migration is in. `-surfaceMode composer=native` turns it on; the
    /// default stays `.web` until T35-AV approves the flip (`SurfaceDefaults.nativeApprovedSurfaces`).
    private var composerIsNative: Bool {
        resolver.resolvedMode(for: .composer) == .native
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let focusError = model?.focusError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(focusError)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.12))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("channelFocusError")
            }
            Divider()
            if let model {
                ChannelPostListView(model: model,
                                    imageStore: imageStore,
                                    emoji: emoji,
                                    rowActions: rowActions,
                                    onOpenThread: { row in
                                        openThread(rootID: row.id, row: row)
                                    },
                                    recents: emojiRecents,
                                    attachmentDownloads: attachmentDownloads)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("channelPostList.loading")
            }
            Divider()
            if composerIsNative, let composer {
                ComposerView(model: composer, emoji: emoji, recents: emojiRecents)
            } else {
                composerPlaceholder
            }
        }
        // The model is created on first appearance and re-used from the coordinator afterwards, so a
        // rotation, a push and a return all keep the same window and scroll position.
        .task(id: channelID) {
            let resolved = panes.model(for: server, channelID: channelID, channelName: channelName)
            model = resolved
            imageStore = panes.imageStore(for: server)
            let catalogue = panes.emojiCatalogue(for: server)
            emoji = catalogue
            // T37: the picker's recent row and the reaction write record into one store, so a react
            // from the list shows up in the picker that is opened next.
            let recents = panes.emojiRecents(for: server)
            emojiRecents = recents
            resolved.onEmojiUsed = { name in recents.record(name) }
            // T38: one download coordinator per server, sharing the app's journal.
            attachmentDownloads = panes.attachmentDownloads(for: server, worker: downloadWorker)
            // T35: the composer is created beside the list and wired to it, so an optimistic row and
            // its reconciliation land in the same window the reader is looking at. Only when the
            // write surface is native: a webview composer must not open a draft database or a send
            // path it will never use.
            if composerIsNative {
                composer = panes.composer(for: server,
                                          channelID: channelID,
                                          channelName: channelName,
                                          teamID: navigation.location.request.teamID,
                                          emojiCatalogue: catalogue)
            }
            await panes.activate(server: server, channelID: channelID, channelName: channelName)
            // T39: land on the post the route named. After the page, because the window may already
            // hold it; `focus` fetches it when it does not (an old search result).
            if let focusPostID {
                await resolved.focus(postID: focusPostID)
            }
            // The server's custom emoji are drawn as images inside post bodies; the list is fetched
            // once per server and the catalogue is shared by every channel of it.
            await catalogue.loadNamesIfNeeded()
        }
        .onChange(of: model?.threadJumpRootID) { _, rootID in
            // The jump target turned out to be a reply: it is not a row of this timeline, so open the
            // thread it lives in (which is where the message is actually drawn).
            guard let rootID, let model else { return }
            model.consumeThreadJump()
            openThreadJump(rootID: rootID)
        }
        .sheet(isPresented: $showsPinned) {
            PinnedPostsView(server: server,
                            channelID: channelID,
                            channelName: channelName,
                            navigation: navigation,
                            onPinnedChange: { postID, pinned in
                                model?.applyPin(postID: postID, isPinned: pinned)
                            },
                            onClose: { showsPinned = false })
        }
        // T40: the channel-info sheet. Its own `.sheet` (not the row list's item-bound one) because it
        // is presented from the pane's header, which exists whether or not a row list has mounted.
        .sheet(isPresented: $showsChannelInfo) {
            ChannelInfoSheet(server: server,
                             channelID: channelID,
                             fallbackTitle: title)
        }
        .onChange(of: scenePhase) { _, phase in
            // Backgrounding is the moment the debounce may not have fired yet: a message typed and
            // then interrupted must still be on disk when the app is killed.
            guard phase != .active, let composer else { return }
            Task { await composer.saveDraftNow() }
        }
    }

    /// The row menu's callbacks. Edit and delete are only offered on my own post; the server enforces
    /// this too, but a menu item that always fails is not an affordance. Reply is offered only when
    /// the composer is native: the menu item opens *this* composer in reply mode, so it must not
    /// appear when the write surface is the webview's.
    /// T36: open a root's thread. The request carries both the post **and** the channel, so the thread
    /// pane knows the composer's channel without a second lookup, and Back returns to this
    /// conversation (`NativeNavigation` opens a thread on top of its channel for exactly that reason).
    private func openThread(rootID: String, row: PostRowModel) {
        var request = navigation.location.request
        request.postID = rootID
        if request.channelID == nil { request.channelID = row.post.channelId }
        if request.channelName == nil { request.channelName = channelName }
        navigation.openThreads(request)
    }

    /// T39: open the thread a jumped-to reply lives in. Same request as the reply line's tap, but
    /// without a row (the reply is not one).
    private func openThreadJump(rootID: String) {
        var request = navigation.location.request
        request.postID = rootID
        if request.channelID == nil { request.channelID = channelID }
        if request.channelName == nil { request.channelName = channelName }
        navigation.openThreads(request)
    }

    private var rowActions: (PostRowModel) -> PostRowActions? {
        { row in
            guard composerIsNative, let composer else { return nil }
            // Who may edit/delete is one pure rule (ComposerModels), not a comparison repeated here
            // — the live suite found the two copies disagreeing.
            let menu = ComposerRowPermissions.menu(postUserID: row.post.userId,
                                                  authorID: composer.authorID,
                                                  isSystem: row.isSystem,
                                                  isDeleted: row.isDeleted,
                                                  isPending: row.isPending)
            guard let menu else { return nil }
            return PostRowActions(canReply: menu.reply,
                                  canEdit: menu.edit,
                                  canDelete: menu.delete,
                                  onReply: {
                                      composer.beginReply(to: row.post,
                                                          authorLabel: row.author.displayName)
                                  },
                                  onEdit: { composer.beginEditing(row.post) },
                                  onDelete: {
                                      Task { await composer.delete(postID: row.post.id) }
                                  },
                                  // Replaced by the list, which owns the sheet (see
                                  // ChannelPostListView.actions(for:)).
                                  onShowOptions: {})
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: glyph)
                .font(.headline)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .lineLimit(2)
                .accessibilityIdentifier("nativeChannelTitle")
            Spacer(minLength: 8)
            if ChannelUITestHook.exposesLoadEarlier, let model {
                LoadEarlierSeamButton(model: model)
            }
            // T40 (S22/S23): the channel's own header opens its info screen. The web client makes the
            // channel *title* the affordance; a pane header that shows a title is the same place, so the
            // button sits first among the trailing controls rather than in a menu.
            if resolver.resolvedMode(for: .channelInfo) == .native {
                Button {
                    showsChannelInfo = true
                } label: {
                    Label("Channel info", systemImage: "info.circle")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel("Channel info")
                .accessibilityIdentifier("nativeChannelInfoButton")
            }
            // T39 (S21): the channel's pinned messages, behind the same `search` surface as the
            // search/saved screens (pinned is part of that card's lookup group).
            if resolver.resolvedMode(for: .search) == .native {
                Button {
                    showsPinned = true
                } label: {
                    Label("Pinned messages", systemImage: "pin")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel("Pinned messages")
                .accessibilityIdentifier("nativeChannelPinnedButton")
            }
            Button {
                navigation.openThreads(navigation.location.request)
            } label: {
                Label("Threads", systemImage: "text.bubble")
                    .labelStyle(.iconOnly)
            }
            .accessibilityLabel("Threads")
            .accessibilityIdentifier("nativeChannelThreadsButton")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var title: String {
        if let model, !model.title.isEmpty { return model.title }
        return channelName ?? "Channel"
    }

    /// A direct message gets a person glyph, a group message a people glyph, a channel a `#`.
    private var glyph: String {
        switch model?.channelType {
        case "D": return "person.crop.circle"
        case "G": return "person.2"
        default: return "number"
        }
    }

    /// S14 (T35) owns the composer. This stand-in is drawn when the `.composer` surface is rendering
    /// the webview (the default until T35-AV approves the flip), and for the frame between the pane
    /// appearing and the coordinator handing over the composer model.
    private var composerPlaceholder: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .foregroundStyle(.tertiary)
            Text(composerIsNative ? "Message input" : "Message input — web (S14/T35)")
                .font(.footnote)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("channelComposerPlaceholder")
    }
}

/// `defaultScrollAnchor(.bottom)`, scoped to the initial offset where the SDK allows it (iOS 18).
///
/// Both branches still get the exact `pinToBottom()` pass: the anchor alone is a hint applied before
/// lazy rows have real heights, and it is what leaves a list with tall folded posts short of the end.
private struct InitialBottomAnchor: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.defaultScrollAnchor(.bottom, for: .initialOffset)
        } else {
            content.defaultScrollAnchor(.bottom)
        }
    }
}

/// Launch-argument seams for this screen's UI tests.
///
/// The same shape `MattermostApp` uses for `-uiTestSeedServer`: read `ProcessInfo` at launch, never a
/// persisted setting, so a real build launched by a person cannot reach this code path.
enum ChannelUITestHook {
    /// `-uiTestExposeLoadEarlier` draws a header button that calls `ChannelViewModel.loadEarlier()`
    /// directly. The scroll-driven path is proved separately (swiping to the sentinel); this seam
    /// exists so the *anchor* measurement can be taken across exactly one page insert.
    static var exposesLoadEarlier: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTestExposeLoadEarlier")
    }
}

/// The `-uiTestExposeLoadEarlier` button, as a view that **observes** the model.
///
/// It is its own view for one reason: the pane's header does not observe `ChannelViewModel`, so an
/// accessibility value rendered there would keep whatever `loadedCount` was at first draw. Observing
/// here publishes "<n> posts loaded" — a page insert changes it, and a UI test can therefore assert
/// that a load really merged instead of inferring it from where the lazy list happens to have
/// scrolled. Mounted only under the launch argument; a normal launch renders nothing.
private struct LoadEarlierSeamButton: View {
    @ObservedObject var model: ChannelViewModel

    var body: some View {
        Button("Load earlier") {
            Task { await model.loadEarlier() }
        }
        .accessibilityLabel("Load earlier")
        // The pane's own answer to "what do you hold", so a UI test can prove a merge happened and
        // which end of the window it grew — without inferring it from wherever the lazy list happens
        // to have scrolled.
        .accessibilityValue("\(model.loadedCount) posts loaded, oldest \(model.oldestLoadedPostID ?? "none")")
        .accessibilityIdentifier("channelPostList.forceLoadEarlier")
    }
}
