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

/// The post list for one channel: rows, day separators, the unread divider, and the "load earlier"
/// sentinel that is also the pagination trigger.
struct ChannelPostListView: View {
    @ObservedObject var model: ChannelViewModel
    let imageStore: ChannelImageStore?
    var emoji: EmojiCatalogue?

    /// True while a top visit must not page: the reader has not been away from the top since the last
    /// auto-load, so this is the same visit. Cleared once the viewport is a screen away from the top.
    @State private var mustLeaveTopBeforePaging = true
    @State private var readerIsAtBottom = true
    @StateObject private var scrollController = ChannelScrollController()

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
        case .post(let row):
            PostRowView(row: row,
                        isExpanded: model.isExpanded(row.id),
                        imageStore: imageStore,
                        emoji: emoji,
                        onToggleExpanded: { toggleExpanded(row.id) },
                        onRetryAttachment: { _ in })
                // The row's own UIView, so the restore can measure where the reader is without
                // going through a SwiftUI preference (see ChannelScrollPosition.swift).
                .background(RowAnchorProbe(postID: row.id, controller: scrollController))
        }
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

    @EnvironmentObject private var panes: ChannelPaneCoordinator

    @State private var model: ChannelViewModel?
    @State private var imageStore: ChannelImageStore?
    @State private var emoji: EmojiCatalogue?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let model {
                ChannelPostListView(model: model, imageStore: imageStore, emoji: emoji)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("channelPostList.loading")
            }
            Divider()
            composerPlaceholder
        }
        // The model is created on first appearance and re-used from the coordinator afterwards, so a
        // rotation, a push and a return all keep the same window and scroll position.
        .task(id: channelID) {
            let resolved = panes.model(for: server, channelID: channelID, channelName: channelName)
            model = resolved
            imageStore = panes.imageStore(for: server)
            let catalogue = panes.emojiCatalogue(for: server)
            emoji = catalogue
            await panes.activate(server: server, channelID: channelID, channelName: channelName)
            // The server's custom emoji are drawn as images inside post bodies; the list is fetched
            // once per server and the catalogue is shared by every channel of it.
            await catalogue.loadNamesIfNeeded()
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

    /// S14 (T35) owns the composer. A stand-in keeps the pane's bottom edge where the real input bar
    /// will be, so the list is not laid out against a moving target.
    private var composerPlaceholder: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .foregroundStyle(.tertiary)
            Text("Message input — S14 (T35)")
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
