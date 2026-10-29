// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: `app/screens/home/search/search.tsx` (the field, the submit, the recent-searches list and the
//        modifier chips), `app/screens/home/search/initial/recent_searches/index.tsx` (a tapped
//        recent search re-runs it), `app/screens/home/search/initial/modifiers/index.tsx` (the chips
//        insert their prefix into the field), `app/screens/home/search/results/` (the list, its
//        summary, its empty state and its footer).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §16; no
// upstream source copied. The SwiftUI decomposition is this repo's own (component-map.md §1).
//
// Surface: `Surface.search` (S19). Until T39-AV approves the flip the surface resolves `.web`
// (`SurfaceDefaults.nativeApprovedSurfaces`), and this pane then says so instead of drawing a screen
// the dual-render switch says is not native. `-surfaceMode search=native` is the launch flag the UI
// test uses.

import SwiftUI

// MARK: - The tab's content (flag gate + model resolution)

/// The Search tab: the native screen when `search` resolves native, an honest note otherwise.
struct SearchPaneContent: View {
    let server: ServerConfig
    @ObservedObject var navigation: NativeNavigation

    @EnvironmentObject private var resolver: SurfaceModeResolver
    @EnvironmentObject private var coordinator: SearchCoordinator

    /// The team the shell is showing on this server — the search's scope. The rail sets it at start-up
    /// (`TeamSidebarCoordinator.applyDefaultTeamIfNeeded` → `openChannel(teamID:)`), so a session with
    /// teams always has one by the time a reader taps the tab.
    private var teamID: String? {
        navigation.location.serverID == server.id ? navigation.location.teamID : nil
    }

    var body: some View {
        Group {
            if resolver.resolvedMode(for: .search) == .native {
                if let teamID {
                    SearchView(server: server,
                               teamID: teamID,
                               navigation: navigation,
                               model: coordinator.search(for: server, teamID: teamID))
                } else {
                    note(systemImage: "person.3",
                         title: "No team selected",
                         body: "Search runs in one team at a time. Pick a team in the sidebar first.")
                        .accessibilityIdentifier("searchNoTeam")
                }
            } else {
                note(systemImage: "magnifyingglass",
                     title: "Search is rendered by the web app",
                     body: "The dual-render switch still resolves the search surface as web "
                         + "(`search=web`), so the native screen is off for this run. Launch with "
                         + "`-surfaceMode search=native`, or switch the surface in the inspector, to "
                         + "use it.")
                    .accessibilityIdentifier("searchWebFallback")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nativeSearchPane")
    }

    private func note(systemImage: String, title: String, body: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(body)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - The screen

/// S19: one search field, the recent searches and modifier chips before the first search, the result
/// list after one.
struct SearchView: View {
    let server: ServerConfig
    let teamID: String
    @ObservedObject var navigation: NativeNavigation
    @ObservedObject var model: SearchViewModel

    /// T5449: whether a result's author offers the profile tap.
    ///
    /// This list draws its own rows, so **its** surface resolution is the gate
    /// (`ProfilePopoverPolicy.offersAuthorTap(rowHost:profileSurface:)`), and `.profile`'s own
    /// resolution is passed through and deliberately ignored — the truth table's regression pin.
    /// The pane itself only draws this screen while `.search` resolves native (`SearchPaneContent`), so
    /// on `.web` the answer is a belt-and-braces `false` on a list that is already the web app's.
    @EnvironmentObject private var resolver: SurfaceModeResolver

    /// T5449: the one profile this screen may have open. A one-slot machine: a second tap re-aims it.
    @State private var profilePopover = ProfilePopoverState()

    @FocusState private var fieldFocused: Bool

    private var offersAuthorProfile: Bool {
        ProfilePopoverPolicy.offersAuthorTap(
            rowHost: resolver.resolvedMode(for: .search),
            profileSurface: resolver.resolvedMode(for: .profile))
    }

    var body: some View {
        VStack(spacing: 0) {
            field
            if let message = model.validationMessage {
                banner(message, systemImage: "exclamationmark.magnifyingglass",
                       identifier: "searchValidationError")
            } else if let error = model.errorMessage, model.phase != .failed(error) {
                // A paging failure leaves the rows on screen, so it is a banner rather than a screen.
                banner(error, systemImage: "wifi.exclamationmark", identifier: "searchError")
            }
            Divider()
            content
        }
        .task(id: teamID) {
            model.teamID = teamID
        }
        // T5449: the result rows' author tap. One helper, and this host never chooses the presentation
        // itself: as a compact tab (nothing above it) it is a **sheet**; inside the regular layout's
        // lookup sheet it is a **push** on that `NavigationStack` (spec §2.2).
        .profilePresentationHost($profilePopover, server: server, navigation: navigation)
    }

    // MARK: Field

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search messages", text: $model.query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .focused($fieldFocused)
                .onSubmit { run() }
                .accessibilityIdentifier("searchField")
            if !model.query.isEmpty {
                Button {
                    model.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("searchClear")
            }
            Button("Search") { run() }
                .buttonStyle(.borderedProminent)
                .disabled(model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("searchSubmit")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func run() {
        fieldFocused = false
        Task { await model.submit(teamID: teamID) }
    }

    private func banner(_ text: String, systemImage: String, identifier: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
        // T8e: `.combine` left the warning glyph in the tree (`Image('exclamationmark.magnifyingglass')`
        // under this element) — VoiceOver read the symbol name and every snapshot paid for it.
        .accessibilityRepresentation {
            Text(text)
                .accessibilityIdentifier(identifier)
        }
        .accessibilityIdentifier(identifier)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            initialContent
        case .searching:
            VStack(spacing: 8) {
                ProgressView()
                Text("Searching…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("searchProgress")
        case .failed(let message):
            failure(message)
        case .results:
            if model.rows.isEmpty {
                empty
            } else {
                results
            }
        }
    }

    /// Before a search: what to search for, and what was searched before.
    private var initialContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Modifiers")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    // Upstream's chips insert their prefix into the field so the reader completes it.
                    FlowRow(spacing: 8) {
                        ForEach(SearchModifierKind.allCases, id: \.rawValue) { kind in
                            Button(kind.title) { insert(kind.token) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .accessibilityIdentifier("searchModifier.\(kind.rawValue)")
                        }
                    }
                }

                if !model.recents.entries.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Recent searches")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            // Upstream's per-team history can be cleared; without this the list grew
                            // forever with no way to forget what the reader typed (T39-AV F7).
                            Button("Clear") {
                                model.recents.removeAll()
                            }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("searchRecentsClear")
                        }
                        ForEach(Array(model.recents.entries.enumerated()), id: \.offset) { index, text in
                            HStack(spacing: 8) {
                                Button {
                                    Task { await model.repeatSearch(text, teamID: teamID) }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "clock.arrow.circlepath")
                                            .foregroundStyle(.secondary)
                                            .accessibilityHidden(true)
                                        Text(text)
                                            .lineLimit(2)
                                        Spacer(minLength: 0)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("searchRecent.\(index)")

                                // Forgetting one entry, upstream's `removeSearchFromTeamSearchHistory`.
                                Button {
                                    model.recents.remove(text)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove \(text) from recent searches")
                                .accessibilityIdentifier("searchRecentRemove.\(index)")
                            }
                            .padding(.vertical, 6)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("searchRecents")
                } else {
                    Text("Your recent searches appear here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private func insert(_ token: String) {
        if model.query.isEmpty {
            model.query = token
        } else if model.query.hasSuffix(" ") {
            model.query += token
        } else {
            model.query += " " + token
        }
        fieldFocused = true
    }

    private var results: some View {
        List {
            if let summary = model.summary {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("searchSummary")
                    .accessibilityValue(model.pagingStateDescription)
                    .listRowSeparator(.hidden)
            }
            ForEach(model.rows) { row in
                SearchResultRowView(row: row,
                                    onOpen: { open(row) },
                                    // T5449: gated on the callback only, so a `.profile` that resolves web
                                    // cannot take the author tap off a natively drawn row.
                                    onShowProfile: offersAuthorProfile
                                        ? { userID in profilePopover.present(userID: userID) }
                                        : nil)
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
            }
            if model.canLoadMore {
                Button {
                    Task { await model.loadMore() }
                } label: {
                    HStack(spacing: 8) {
                        if model.isLoadingMore { ProgressView() }
                        Text(model.isLoadingMore ? "Loading…" : "Load more results")
                    }
                }
                .accessibilityIdentifier("searchLoadMore")
                .accessibilityValue(model.pagingStateDescription)
            }
            if let note = model.windowNote {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("searchWindowNote")
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("searchResults")
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(model.emptyCopy)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("searchEmpty")
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("searchError")
            Button("Try again") { run() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("searchRetry")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Opening a result

    /// Jump to the message: a root post opens its channel *at that post*, a reply opens its thread
    /// (the channel timeline is thread-collapsed, so a reply is not a row to scroll to). Both go
    /// through `NativeNavigation`, the same funnel a deep link uses, so the pane and the compact push
    /// agree.
    private func open(_ row: SearchResultRow) {
        var request = NativeChannelRequest(serverID: server.id,
                                           teamID: teamID,
                                           channelID: row.channelID)
        request.channelName = navigation.location.channelName
        switch SearchJump.target(for: row.model.post) {
        case .channel(let postID):
            request.postID = postID
            navigation.openChannel(request)
        case .thread(let rootID):
            request.postID = rootID
            navigation.openThreads(request)
        }
    }
}

// MARK: - A result row

/// One result: the channel it lives in, then the post exactly as the timeline draws it (so a result is
/// recognisable), with the query's terms highlighted inside the body.
///
/// **The row is not a `Button`** (T5449, spec §3). It used to be one, with `PostRowView` inside its
/// label — and a `Button` inside another `Button`'s label is not a reliable tap target in SwiftUI, so
/// the author affordance (the avatar and the name, which `PostRowView` draws as real `Button`s) either
/// never fired or fired the row's jump. The row is now the same visual `VStack` with a tap gesture and
/// the button trait re-added for VoiceOver — the same shape `ReactionBarView` uses, and for the same
/// reason: the inner controls have to stay reachable.
///
/// Accessibility: the row is **one labelled element** (the `T8e` rule: a 60-row list must not become 180
/// VoiceOver stops), and it carries an explicit `Open profile` action. Measured on this tree
/// (`build/logs/t5449c2-live1.log`), `.accessibilityElement(children: .combine)` here does **not**
/// swallow the row's leaves: `PostRowView` is itself `.accessibilityElement(children: .contain)`, and
/// an outer `.combine` does not flatten a nested container — so `post.<id>.avatar` and
/// `post.<id>.author` stay addressable inside the row. That is what the live test taps; a coordinate
/// inside the row is *not* equivalent, because (0.18, 0.22) of a row that draws a channel line lands in
/// that line and opens the post.
struct SearchResultRowView: View {
    let row: SearchResultRow
    let onOpen: () -> Void
    /// T5449: a tap on the author's avatar or name opens that account's profile. Nil keeps both inert
    /// (a preview, or a host whose `.search` surface resolved web — see `ProfilePopoverPolicy`).
    var onShowProfile: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(row.channelLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            PostRowView(row: row.model,
                        isExpanded: false,
                        imageStore: nil,
                        emoji: nil,
                        onToggleExpanded: {},
                        onShowProfile: onShowProfile)
                // The highlight the renderer applies inside the body runs (MarkdownView reads this
                // environment value). Scoped to this row so a channel pane's own rows are never
                // highlighted by a search the reader has left behind.
                .environment(\.searchHighlightTerms, row.highlight)
        }
        // The whole row jumps to the message; the author's two buttons keep their own areas (a tap on
        // them never reaches this gesture — SwiftUI hit-tests the inner control first).
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
        .accessibilityAddTraits(.isButton)
        // A combined element reads its own label, not its children's: SwiftUI kept only the first child
        // of the old button's label (the channel line), so a row announced "#t34-showcase" and nothing
        // else. The row says the whole thing instead: channel, author, and the message as plain text.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.channelLabel), \(row.model.author.displayName): "
                            + row.model.accessibleText)
        .accessibilityHint("Opens this message")
        // The author tap, reachable without hitting a precise pixel: the same callback the avatar and
        // the name call, offered as a VoiceOver custom action (spec §3).
        .accessibilityAction(named: Text("Open profile")) {
            onShowProfile?(row.model.author.id)
        }
        .accessibilityIdentifier("searchResult.\(row.id)")
    }
}

// MARK: - Layout helpers

/// A wrapping row of chips. `Layout` is iOS 16+, which is this app's floor.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
