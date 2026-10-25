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

    /// Row top edges in the scroll view's coordinate space, keyed by post id. The topmost one is the
    /// reader's anchor; the same dictionary is re-read after a page lands to measure the correction.
    @State private var frames: [String: CGFloat] = [:]

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
                            .background(geometryReader(for: item))
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
            .onPreferenceChange(RowGeometryPreferenceKey.self) { updated in
                frames = updated
                readerIsAtBottom = scrollController.distanceFromBottom <= 40
                // A top visit only means "load more" if the reader had been away from the top: on the
                // first layout of a fresh window the content estimate can be shorter than the viewport,
                // which reads as "at the top" — a live run paged a second window before the initial
                // scroll to the newest post had even landed (pane held 120 on open).
                if scrollController.distanceFromTop > 320 { mustLeaveTopBeforePaging = false }
                // A restore in flight owns the position: recording an anchor from the half-restored
                // layout would hand the next `loadEarlier` a place the reader never was.
                guard model.pendingScrollRestore == nil else { return }
                // Preference values are positions inside the scroll *content*; the reader's place is a
                // distance below the viewport's top edge, so the current offset is subtracted here
                // (T34-R3: without this the anchor was the first row of the window, whatever the
                // reader was actually looking at).
                if let candidate = ScrollRestorePlan.topVisible(rows: updated,
                                                                contentOffsetY: scrollController.offsetY) {
                    model.setScrollAnchor(ChannelViewModel.ScrollAnchor(postID: candidate.id,
                                                                        offsetFromTop: candidate.offsetFromTop))
                }
                // The latch and the top-visit check live in `pollReaderPosition()`: it reads UIKit's
                // real offset, so it does not depend on a row's frame changing at the right moment.
                if !mustLeaveTopBeforePaging, model.hasMore, !model.isLoadingMore,
                   model.loadEarlierError == nil, scrollController.distanceFromTop <= 8,
                   scrollController.isUserScrolling || scrollController.contentFitsViewport {
                    mustLeaveTopBeforePaging = true
                    Task { await model.loadEarlier() }
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
    /// The older page was inserted *above* the anchor, so the anchor's frame moved down by the height
    /// of that page; scrolling the content up by exactly that difference leaves the reader looking at
    /// the same pixels. The correction is applied through the scroll view's `contentOffset` (a point
    /// offset, not a row edge), which is what keeps a reader who was half-way through a post from
    /// being moved by up to a row height — the case `scrollTo(anchor: .top)` cannot express.
    ///
    /// The loop waits for SwiftUI's layout pass to publish the new frames: the first updates after the
    /// insert still carry the pre-insert values, and a correction computed from those would be zero.
    @MainActor
    private func restoreReader(_ restore: ChannelViewModel.ScrollAnchor,
                               proxy: ScrollViewProxy) async {
        // Converge rather than correct once — but at most once per *measured* position: the preference
        // values lag the scroll, so re-applying a correction computed from a stale frame would move the
        // reader twice as far (a live run showed the anchored post 585 pt off, the same distance twice).
        var correctedFor: CGFloat?
        for attempt in 0..<24 {
            // `frame` is inside the content; the reader's reference is the distance below the
            // viewport's top edge, exactly what was recorded.
            if let frame = frames[restore.postID], scrollController.isAttached {
                if frame != correctedFor {
                    let current = frame - scrollController.offsetY
                    let adjustment = ScrollRestorePlan.adjustment(
                        recordedOffsetFromTop: restore.offsetFromTop,
                        currentOffsetFromTop: current)
                    correctedFor = frame
                    if ScrollRestorePlan.isNoOp(adjustment) {
                        if attempt >= 3 {
                            model.consumeScrollRestore()
                            return
                        }
                    } else {
                        _ = scrollController.scroll(by: adjustment)
                    }
                } else if attempt >= 3 {
                    // The row has not been re-measured since the correction: there is nothing left to
                    // learn from waiting.
                    model.consumeScrollRestore()
                    return
                }
            }
            try? await Task.sleep(for: .milliseconds(32))
        }
        // No usable measurement: the anchored row is either not in `frames` (a page was inserted above
        // it, so `LazyVStack` has not measured it) or its preference value never moved. Align its top to
        // the viewport and put the recorded distance back above it — a point offset, so a reader
        // half-way through a post is not moved to a row edge. This *enforces* the recorded distance,
        // which is also the right answer when SwiftUI happened to preserve the position itself.
        proxy.scrollTo("post-\(restore.postID)", anchor: .top)
        try? await Task.sleep(for: .milliseconds(60))
        if !ScrollRestorePlan.isNoOp(restore.offsetFromTop) {
            _ = scrollController.scroll(by: -restore.offsetFromTop)
        }
        model.consumeScrollRestore()
    }

    @ViewBuilder
    private func geometryReader(for item: PostListItem) -> some View {
        // Only posts are anchors: a day separator or the unread divider has no id to restore to, and
        // letting it be the "topmost row" would hand the view model an anchor it cannot scroll to.
        if let postID = item.postID {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: RowGeometryPreferenceKey.self,
                    value: [postID: geometry.frame(in: .named("channelScroll")).minY])
            }
            .allowsHitTesting(false)
        }
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
        }
    }

    /// Expand or collapse a post without moving the post's own position on screen.
    ///
    /// A fold can change a row's height by thousands of points, and every row below it moves with it.
    /// The post being toggled is the reader's anchor here, and the same point-offset restore that
    /// serves `loadEarlier` puts it back.
    private func toggleExpanded(_ postID: String) {
        // Same reference as everywhere else: distance below the viewport's top edge, not a position
        // inside the content (`frames` values are content positions).
        if let current = frames[postID], scrollController.isAttached {
            model.requestScrollRestore(ChannelViewModel.ScrollAnchor(
                postID: postID,
                offsetFromTop: current - scrollController.offsetY))
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
        // The latch is re-armed only by the reader travelling away from the top *by hand*. A merge
        // lengthens the content above them, which also makes `distance` large — treating that as "they
        // left the top" is what let one visit page in three windows' worth of posts.
        if userScrolling, distance > 320 { mustLeaveTopBeforePaging = false }
        // Nothing to scroll at all: a window shorter than a screen is both ends at once and should
        // fill itself.
        if scrollController.contentFitsViewport { mustLeaveTopBeforePaging = false }
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

/// Row top edges in the scroll view's coordinate space, keyed by the post id the row names.
struct RowGeometryPreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { current, _ in current }
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
