// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: `app/screens/home/recent_mentions/recent_mentions.tsx` (the screen: a header with a subtitle, one
//        list, pull to refresh, an empty state), `app/screens/home/recent_mentions/components/empty`,
//        `app/components/post_with_channel_info/` (a row = the channel it came from, then the post as the
//        timeline draws it) and `app/components/post_list/post/` for the body itself.
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §19; no
// upstream source copied. The SwiftUI decomposition is this repo's own (docs/component-map.md §1).
//
// Surface: `Surface.activity` (S25). Until T42-AV approves the flip the surface resolves `.web`
// (`SurfaceDefaults.nativeApprovedSurfaces`), and this pane says so instead of drawing a screen the
// dual-render switch says is not native. `-surfaceMode activity=native` is the launch flag the UI test
// uses — and the same flag this app's own snapshot probe needs.
//
// The row's body is `PostRowView`, the same renderer the channel timeline and the search results use, so
// a mention reads exactly like the message it is (its markdown, its attachments, its reactions) instead of
// a second, thinner rendering of a post that would drift from the first.

import SwiftUI

// MARK: - The tab's content (flag gate + model resolution)

/// The Activity tab: the native feed when `activity` resolves native, an honest note otherwise.
struct MentionsPaneContent: View {
    let server: ServerConfig
    @ObservedObject var navigation: NativeNavigation

    @EnvironmentObject private var resolver: SurfaceModeResolver
    @EnvironmentObject private var coordinator: ActivityCoordinator

    var body: some View {
        Group {
            if resolver.resolvedMode(for: .activity) == .native {
                ActivityFeedView(server: server,
                                 navigation: navigation,
                                 model: coordinator.model(for: server))
            } else {
                note(systemImage: "bell.badge",
                     title: "Mentions are rendered by the web app",
                     body: "The dual-render switch still resolves the activity surface as web "
                         + "(`activity=web`), so the native feed is off for this run. Launch with "
                         + "`-surfaceMode activity=native`, or switch the surface in the inspector, to "
                         + "use it.")
                    .accessibilityIdentifier("activityWebFallback")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nativeActivityPane")
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
                .frame(maxWidth: 380)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - The screen

/// S25: one list of everything that mentions this reader, from every channel and team.
struct ActivityFeedView: View {
    let server: ServerConfig
    @ObservedObject var navigation: NativeNavigation
    @ObservedObject var model: MentionsViewModel

    /// T5449: whether a mention's author offers the profile tap.
    ///
    /// This feed draws its own rows, so **`.activity`'s** resolution is the gate
    /// (`ProfilePopoverPolicy.offersAuthorTap(rowHost:profileSurface:)`); `.profile`'s own answer is
    /// passed through and ignored (the truth table's regression pin). `MentionsPaneContent` only mounts
    /// this feed while `.activity` resolves native, so a `.web` answer here is belt-and-braces.
    @EnvironmentObject private var resolver: SurfaceModeResolver

    /// T5449: the one profile this feed may have open (a one-slot machine — a second tap re-aims it).
    @State private var profilePopover = ProfilePopoverState()

    private var offersAuthorProfile: Bool {
        ProfilePopoverPolicy.offersAuthorTap(
            rowHost: resolver.resolvedMode(for: .activity),
            profileSurface: resolver.resolvedMode(for: .profile))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let message = model.actionError {
                banner(message)
            }
            content
        }
        // The feed is refetched whenever the reader comes back to it — a tab switch, a push's return, a
        // rotation. That is upstream's `useIsFocused` refetch, and it is what makes a mention that arrived
        // while the app was elsewhere appear (the socket path only covers the open feed).
        .task {
            await model.load(ifNeeded: false)
        }
        // T5449: the rows' author tap. The container decides how it presents (spec §2.2): a sheet from
        // the compact tab, a push inside the regular layout's lookup sheet.
        .profilePresentationHost($profilePopover, server: server, navigation: navigation)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "bell.badge")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Recent mentions")
                    .font(.headline)
                    .accessibilityIdentifier("activity.title")
                Spacer(minLength: 8)
                Button {
                    Task { await model.reload() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel("Refresh mentions")
                .accessibilityIdentifier("activity.refresh")
                .disabled(model.phase == .loading)
                Button {
                    Task { await model.markAllRead() }
                } label: {
                    Label("Mark all read", systemImage: "checkmark.circle")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel("Mark all read")
                .accessibilityIdentifier("activity.markAllRead")
                .disabled(model.unreadCount == 0 || model.isMarking)
            }
            HStack(spacing: 10) {
                // Watching the model directly, not through this parent: a `@State`-held `ObservableObject`
                // read in the parent's body does not re-render on its own `@Published` changes (the bug
                // T36-AV F3 measured on the threads header) — the two small subviews below are what
                // subscribe.
                ActivitySubtitleLine(model: model)
                    .accessibilityIdentifier("activity.subtitle")
                Spacer(minLength: 8)
                Picker("Filter", selection: Binding(get: { model.filter },
                                                    set: { model.select(filter: $0) })) {
                    ForEach(ActivityFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 180)
                .accessibilityIdentifier("activity.filter")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private func banner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("activity.banner")
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            loading
        case .loading:
            // A refresh on top of rows keeps the rows visible (the pull-to-refresh spinner is the only
            // "loading" the reader needs); with nothing yet, the spinner is the whole pane.
            if model.loadedCount == 0 { loading } else { rowsOrEmpty }
        case .loaded:
            rowsOrEmpty
        case .failed(let message):
            failure(message)
        }
    }

    private var loading: some View {
        ProgressView("Loading mentions…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("activity.loading")
    }

    @ViewBuilder
    private var rowsOrEmpty: some View {
        if model.visibleRows.isEmpty {
            empty
        } else {
            list
        }
    }

    private var list: some View {
        List {
            ForEach(model.visibleRows) { row in
                ActivityRowView(row: row,
                                isNew: row.postID == model.insertedRowID,
                                isMarking: model.isMarking,
                                onOpen: { open(row) },
                                onMarkRead: { Task { await model.markRead(row) } },
                                // T5449: gated on the callback only, so `.profile` resolving web cannot
                                // take the tap off a row drawn natively.
                                onShowProfile: offersAuthorProfile
                                    ? { userID in profilePopover.present(userID: userID) }
                                    : nil)
                    .accessibilityIdentifier("activity.row.\(row.postID)")
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button {
                            Task { await model.markRead(row) }
                        } label: {
                            Label(row.isThreadRow ? "Mark thread read" : "Mark channel read",
                                  systemImage: "checkmark.circle")
                        }
                        .tint(.accentColor)
                        .accessibilityIdentifier("activity.markRead.\(row.postID)")
                    }
            }
        }
        .listStyle(.plain)
        .refreshable { await model.reload() }
        .accessibilityIdentifier("activity.list")
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "bell.slash")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(model.filter == .unread ? "Nothing unread" : "No mentions yet")
                .font(.headline)
            Text(model.emptyCopy)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("activity.empty")
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
                .accessibilityIdentifier("activity.error")
            Button("Try again") {
                Task { await model.reload() }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("activity.retry")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Opening a mention

    /// Jump to the message: a root post opens its channel **at that post**, a reply opens its thread — the
    /// same rule the search results use (`SearchJump`), through the same router a deep link uses
    /// (`NativeNavigation`), so a mention tap and a permalink land in the same place.
    ///
    /// The team is carried because a mention can belong to a team that is not the one on screen; the rail
    /// reacts to `location.teamID`, so the jump switches teams as part of routing rather than as a side
    /// effect of it.
    private func open(_ row: ActivityRow) {
        var request = NativeChannelRequest(serverID: server.id,
                                           teamID: row.teamID,
                                           channelID: row.channelID)
        switch row.jump {
        case .channel(let postID):
            request.postID = postID
            navigation.openChannel(request)
        case .thread(let rootID):
            request.postID = rootID
            navigation.openThreads(request)
        }
    }
}

/// The header's counter line, observing the model it describes.
struct ActivitySubtitleLine: View {
    @ObservedObject var model: MentionsViewModel

    var body: some View {
        Text(model.subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// MARK: - A row

/// One mention: the channel it came from, then the post exactly as the timeline draws it, with the unread
/// dot the reader's cursor implies.
///
/// **The row is not a `Button`** (T5449, spec §3): it used to be one with `PostRowView` inside its label,
/// so the author's avatar and name were buttons inside a button's label — not a reliable target in
/// SwiftUI, and the profile tap never fired. A plain `VStack` with a tap gesture and the button trait
/// re-added for VoiceOver keeps both: the row still jumps (everywhere but the author's own two buttons),
/// and the author opens their profile (`ReactionBarView` records the same reasoning).
///
/// One labelled element per row (T8e), with an explicit `Open profile` action. Measured on this tree
/// (`build/logs/t5449c2-live1.log`), `.accessibilityElement(children: .combine)` does not swallow the
/// row's leaves: `PostRowView` is itself `.contain` and an outer `.combine` does not flatten a nested
/// container, so `post.<id>.avatar`/`.author` stay addressable inside the row and are what the live
/// test taps. A coordinate inside the row is not equivalent — on a row that draws a channel line,
/// (0.18, 0.22) lands in that line and opens the post instead.
struct ActivityRowView: View {
    let row: ActivityRow
    /// True for the row a live socket event just added.
    let isNew: Bool
    let isMarking: Bool
    var onOpen: () -> Void
    var onMarkRead: () -> Void
    /// T5449: a tap on the author's avatar or name opens that account's profile. Nil keeps both inert
    /// (a preview, or a host whose `.activity` surface resolved web — see `ProfilePopoverPolicy`).
    var onShowProfile: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(row.isUnread ? Color.accentColor : Color.clear)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(row.channelLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if row.isThreadRow {
                    Label("thread", systemImage: "text.bubble")
                        .labelStyle(.iconOnly)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("thread reply")
                }
                Spacer(minLength: 0)
                if isNew {
                    Text("New")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                }
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
        }
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
        .accessibilityAddTraits(.isButton)
        // One combined element rather than three: SwiftUI keeps only the first child of a multi-child
        // label, so the row says the whole thing itself (channel, unread state, author and message) —
        // the same reason `SearchResultRowView` does.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAction(named: Text(row.isThreadRow ? "Mark thread read" : "Mark channel read")) {
            onMarkRead()
        }
        // T5449: the author tap as a VoiceOver action — the same callback the avatar and the name call.
        .accessibilityAction(named: Text("Open profile")) {
            onShowProfile?(row.model.author.id)
        }
    }

    private var accessibilityText: String {
        let state = row.isUnread ? "unread" : "read"
        let kind = row.isThreadRow ? "thread reply" : "message"
        return "\(row.channelLabel), \(state) \(kind), \(row.model.author.displayName): "
            + row.model.accessibleText
    }
}
