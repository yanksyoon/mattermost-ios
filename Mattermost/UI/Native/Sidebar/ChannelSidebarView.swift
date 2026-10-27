// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/home/channel_list/categories_list/ (one collapsible section per category, the
//        category header with its disclosure chevron and mute marker), categories_list/category_body
//        (rows in category order), app/components/channel_item/ (`#`/lock/person glyph, bold label
//        while unread, badge at the trailing edge), app/components/channel_icon/,
//        app/screens/find_channels/ + app/components/quick_switch (the quick switcher affordance).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §3; no
// upstream source copied. The SwiftUI decomposition is this repo's own (docs/component-map.md §1).

import SwiftUI

/// The native channel list: the sidebar's content once `sidebar=native` (S08/T33).
///
/// It is mounted exactly where T30's placeholder was — inside the team region
/// (`NativeTeamSidebarPane`), so the rail and the list share one lifetime, as they do upstream.
///
/// The pane's T30/T32 identifiers are deliberately preserved (`nativeSidebar`, `sidebarCurrentTeam`,
/// `nativeSidebarAllThreads`): the list replaces the *placeholder*, not the pane's contract, so every
/// shipped shell/rail test keeps resolving with the flag on.
struct NativeChannelSidebarContent: View {
    let server: ServerConfig
    @ObservedObject var navigation: NativeNavigation
    @ObservedObject var model: ChannelListViewModel
    /// The rail's model, read for the current team's *display* name (a location carries the URL
    /// name: `ops`, not `Operations`).
    @ObservedObject var teamModel: TeamSwitchViewModel
    @EnvironmentObject private var resolver: SurfaceModeResolver
    /// The owner of the per-server model. It is asked to `activate` because the first appearance is
    /// what turns "the shell is on this server" into a load (one model, one socket, no view state).
    @EnvironmentObject private var channels: ChannelSidebarCoordinator
    /// The threads coordinator, so this row can show how many threads are unread without the pane
    /// being open. The model it hands back is the same one the Threads pane uses.
    @EnvironmentObject private var threads: ThreadCoordinator

    @State private var quickSwitcherPresented = false
    /// T40: the channel browser (S24). Presented from this list because the list is where a missing
    /// channel would be looked for.
    @State private var browseChannelsPresented = false
    /// The team's global-thread list, resolved once the sidebar knows its team. Held so the row can
    /// draw the unread count live: a thread that arrives over the socket moves the badge the same
    /// way it moves the list.
    @State private var globalThreads: GlobalThreadsViewModel?

    var body: some View {
        List {
            workspaceSection
            channelSections
            footerSection
        }
        .listStyle(.sidebar)
        // The appearance pass: point the model at the shell's current team and load it. The
        // coordinator owns the model, so a re-mount (rotation, tab switch) does not reload it.
        .task { await channels.activate(server) }
        // The unread-thread count is the threads list's own view of the world — the same endpoint the
        // pane pages, asked once for the sidebar (and reused when the pane opens, so it is not paid
        // for twice). No team yet means nothing to count; the task re-runs when the team resolves.
        .task(id: model.teamID) {
            guard let teamID = model.teamID, !teamID.isEmpty else { return }
            let resolved = threads.globalModel(for: server, teamID: teamID)
            globalThreads = resolved
            await resolved.load(ifNeeded: true)
        }
        .sheet(isPresented: $quickSwitcherPresented) {
            QuickSwitcherView(model: model) { entry in
                open(entry)
                quickSwitcherPresented = false
            }
        }
        // T40: the channel browser. The team id is the model's current one, which `activate` has already
        // pinned to the shell's selected team (a browse list is always team-scoped).
        .sheet(isPresented: $browseChannelsPresented) {
            BrowseChannelsView(server: server, teamID: model.teamID ?? "")
        }
    }

    // MARK: Sections

    private var workspaceSection: some View {
        Section {
            // The pane's anchor row carries `nativeSidebar` in every state (T32-R F2).
            NativeSidebarAnchorRow(server: server)

            if let title = teamTitle {
                HStack(spacing: 8) {
                    Image(systemName: "person.3")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(title)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("sidebarCurrentTeam")
            }

            // The Threads entry, above the categories — upstream mounts its Threads button in the
            // channel list's own body for exactly this reason (`categories_list.tsx` renders
            // `ThreadsButton` above the categories). Below the list it was unreachable in practice on a
            // real account: this server's `perfprobe` is in 11 categories / 347 channels, so the row sat
            // past hundreds of conversations and is not built at all until scrolled to (measured: the
            // live suite found no `nativeSidebarAllThreads` row, and the reader's report — "no place to
            // see unread threads" — is what that looks like from the outside).
            threadsEntry

            Button {
                quickSwitcherPresented = true
            } label: {
                Label("Jump to a channel…", systemImage: "magnifyingglass")
            }
            .accessibilityIdentifier("channelSidebar.quickSwitcher")
            // The desktop shortcut (cmd/ctrl-K) on a hardware keyboard; harmless where there is none.
            .keyboardShortcut("k", modifiers: .command)
            // T40: the channel browser (S24). It sits here, beside the switcher, because a `List` renders
            // its sections lazily — the same row at the bottom of a long channel list is not on screen and
            // therefore not reachable without scrolling, and "find a channel I am not in" belongs with
            // "find a channel I am in".
            if resolver.resolvedMode(for: .channelInfo) == .native {
                Button {
                    browseChannelsPresented = true
                } label: {
                    Label("Browse channels", systemImage: "magnifyingglass.circle")
                }
                .accessibilityIdentifier("nativeSidebarBrowseChannels")
            }
        } header: {
            Text("Workspace")
        }
    }

    @ViewBuilder
    private var channelSections: some View {
        if model.groups.isEmpty {
            Section {
                channelStateRow
            } header: {
                Text("Channels")
            }
        } else {
            ForEach(model.groups) { group in
                Section {
                    if !model.isCollapsed(categoryID: group.id) {
                        ForEach(group.entries) { entry in
                            ChannelSidebarRow(entry: entry,
                                              canMove: !group.entries.isEmpty && model.canWriteLayout) {
                                open(entry)
                            } onMove: { offset in
                                Task { await model.move(channelID: entry.id,
                                                        inCategory: group.id,
                                                        by: offset) }
                            } onMute: {
                                Task { await model.setMuted(!entry.isMuted, channelID: entry.id) }
                            } onFavorite: {
                                Task { await model.setFavorite(!entry.isFavorite, channelID: entry.id) }
                            }
                        }
                    }
                } header: {
                    CategoryHeader(group: group,
                                   isCollapsed: model.isCollapsed(categoryID: group.id)) {
                        Task {
                            await model.setCollapsed(!model.isCollapsed(categoryID: group.id),
                                                     categoryID: group.id)
                        }
                    }
                }
            }
        }
    }

    /// The rail's Threads entry (upstream `channel_list.threads.button`): the way into the
    /// followed-threads pane, and the only place that pane's unread state is visible while it is closed.
    @ViewBuilder
    private var threadsEntry: some View {
        if let globalThreads {
            ThreadsRailRow(model: globalThreads) { openThreads() }
        } else {
            // Before the team resolves there is no list to count. The row is still drawn — a row that
            // appears late would make the rail jump — but it carries no number.
            Button {
                openThreads()
            } label: {
                HStack(spacing: 6) {
                    Label("Threads", systemImage: "text.bubble")
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("nativeSidebarAllThreads")
        }
    }

    /// Open the followed-threads pane.
    ///
    /// Two layouts, two destinations, and the row must not be inert on either: the wide layout has no
    /// tab bar — its detail column follows `location.pane` — so selecting the tab alone left this row
    /// doing nothing on a Mac (measured: tapping it changed nothing, which is exactly what "I cannot
    /// see the unread threads" looked like when this card was reported).
    private func openThreads() {
        navigation.select(tab: .threads)
        navigation.openThreads(NativeChannelRequest(serverID: server.id, teamID: model.teamID))
    }

    private var footerSection: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "bell.badge")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                if let label = model.totals.accessibilityLabel {
                    Text(label)
                        .font(.footnote)
                } else {
                    Text("All caught up")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if model.countsAreStale {
                    // A count that could not be refreshed is never drawn as a confident number.
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Unread counts may be out of date")
                        .accessibilityIdentifier("channelSidebar.staleCounts")
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("channelSidebar.totals")

            if let actionError = model.actionError {
                Text(actionError)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("channelSidebar.actionError")
            }

            // The T26 escape hatch has to survive every native state of this pane.
            Button {
                resolver.forceWebForThisRun(SurfaceDefaults.paneHostSurface)
            } label: {
                Label("Use web view", systemImage: "safari")
            }
            .accessibilityIdentifier("revertToWeb\(SurfaceDefaults.paneHostSurface.rawValue)")
        } footer: {
            if model.groupingIsApproximate {
                Text("Your custom categories could not be loaded, so channels are grouped by type.")
                    .font(.footnote)
            }
        }
    }

    /// Loading / failed / empty, inside the Channels section so the pane keeps its own rows.
    @ViewBuilder
    private var channelStateRow: some View {
        switch model.phase {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading channels…")
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("channelSidebar.loading")
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Could not load your channels", systemImage: "exclamationmark.triangle")
                    .font(.subheadline.weight(.semibold))
                    // The identifier goes on the label, *not* on the stack: an identifier on a
                    // container makes one accessibility element and hides the retry button inside it
                    // (the class of bug T32-R found in the rail's empty/error screens).
                    .accessibilityIdentifier("channelSidebar.error")
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") {
                    Task { await model.reload() }
                }
                .accessibilityIdentifier("channelSidebar.retry")
            }
            .padding(.vertical, 2)
        case .loaded:
            Text(model.teamID == nil ? "Select a team to see its channels." : "No channels yet")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("channelSidebar.empty")
        }
    }

    // MARK: Actions

    private func open(_ entry: ChannelSidebarEntry) {
        navigation.openChannel(NativeChannelRequest(serverID: server.id,
                                                    teamID: model.teamID,
                                                    teamName: displayedTeamName,
                                                    channelID: entry.id,
                                                    channelName: entry.name))
    }

    /// The team as the location/rail spells it (the URL name — what a deep link carries).
    private var displayedTeamName: String? {
        if let location = navigation.location.serverID == server.id ? navigation.location : nil,
           let name = location.teamName, !name.isEmpty {
            return name
        }
        return teamModel.currentSelection?.name
    }

    /// The team as a person reads it: the rail knows the display name, the location the URL name.
    private var teamTitle: String? {
        if let selection = teamModel.currentSelection,
           let entry = teamModel.entries.first(where: { $0.id == selection.id }) {
            return entry.displayName
        }
        if let name = displayedTeamName, let entry = teamModel.entries.first(where: { $0.name == name }) {
            return entry.displayName
        }
        return displayedTeamName
    }
}

// MARK: - Category header

/// A section's header: disclosure chevron, the category's name, and its mute marker.
///
/// Collapsing is a control (upstream's header toggles the body); the whole header is the button so a
/// tap anywhere on it works, and it carries the category's stable identifier.
struct CategoryHeader: View {
    let group: ChannelSidebarGroup
    let isCollapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(group.displayName)
                    .lineLimit(1)
                if group.category.muted {
                    Image(systemName: "bell.slash")
                        .font(.caption2)
                        .accessibilityLabel("Category muted")
                }
                Spacer(minLength: 0)
            }
            // A `.plain` button hit-tests its label's content shape, not the row its frame fills;
            // without this the space after the Spacer would not take a tap even though the whole
            // header is reported as the control.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(group.identifier)
    }
}

// MARK: - A channel row

/// One channel: glyph, name (bold while unread), mute marker, mention badge.
///
/// The row's actions live in a context menu (secondary click on Catalyst, long press on touch), which
/// is also how a reorder is expressed without drag-and-drop: "Move up"/"Move down" writes the
/// category's manual order, the same write a drag makes.
struct ChannelSidebarRow: View {
    let entry: ChannelSidebarEntry
    let canMove: Bool
    let action: () -> Void
    let onMove: (Int) -> Void
    let onMute: () -> Void
    let onFavorite: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: entry.iconSymbolName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(entry.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // The name wins the horizontal space: without this the badge and the mute glyph
                    // squeeze a short name into "Off-…" in the 240 pt sidebar.
                    .layoutPriority(1)
                    // The unread emphasis: bold (upstream's `fontWeight` on the label).
                    .fontWeight(entry.showsUnreadEmphasis ? .bold : .regular)
                if entry.isMuted {
                    Image(systemName: "bell.slash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 4)
                badge
            }
            // A `.plain` button hit-tests its label's content shape: the name, glyph and badge take
            // a tap, the space after the Spacer does not — while VoiceOver/XCUITest report the whole
            // row as the control. The shape makes the touch target and the reported frame agree.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("channelSidebar.channel.\(entry.id)")
        .accessibilityLabel(entry.displayName)
        .accessibilityValue(entry.accessibilityValue)
        .accessibilityAddTraits(entry.isSelected ? [.isSelected] : [])
        .contextMenu {
            if canMove {
                Button {
                    onMove(-1)
                } label: {
                    Label("Move up", systemImage: "arrow.up")
                }
                Button {
                    onMove(1)
                } label: {
                    Label("Move down", systemImage: "arrow.down")
                }
            }
            Button(action: onFavorite) {
                Label(entry.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                      systemImage: entry.isFavorite ? "star.slash" : "star")
            }
            Button(action: onMute) {
                Label(entry.isMuted ? "Unmute channel" : "Mute channel",
                      systemImage: entry.isMuted ? "bell" : "bell.slash")
            }
        }
    }

    @ViewBuilder
    private var badge: some View {
        switch entry.badge {
        case .none:
            EmptyView()
        case .dot:
            Circle()
                .fill(Color.accentColor)
                .frame(width: 7, height: 7)
                // The row's value already says "Unread"; the dot is decoration.
                .accessibilityHidden(true)
        case .count:
            Text(entry.badgeText ?? "")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.red, in: Capsule())
                .accessibilityHidden(true)
        }
    }
}

/// The rail's Threads entry: the way into the followed-threads pane, and the only place that pane's
/// unread state is visible while it is closed.
///
/// One `@ObservedObject` subview rather than a read in `NativeChannelSidebarContent.body`: a model held
/// in `@State` and read directly in the parent does **not** re-render when its `@Published` counters
/// change — T36-AV F3 shipped exactly that defect in the pane's header, where "No threads yet" stayed
/// drawn over a full page of rows. A badge that only moved on the next unrelated redraw would make
/// this number a lie for as long as the reader stayed on the list.
///
/// The copy is upstream's (`app/components/threads_button/threads_button.tsx`): the entry is named
/// "Threads", it is bold while anything is unread, and it carries a badge for the count. The number is
/// the unread **thread** count, so it agrees with the pane's own counter line one tap away; the
/// thread-mention count rides along in the accessibility value (`ThreadsRailEntry.accessibilityValue`).
private struct ThreadsRailRow: View {
    @ObservedObject var model: GlobalThreadsViewModel
    let action: () -> Void

    var body: some View {
        let entry = model.railEntry
        return Button(action: action) {
            HStack(spacing: 6) {
                Label("Threads", systemImage: "text.bubble")
                    // Upstream's unread emphasis: the row is bold while anything is waiting.
                    .fontWeight(entry.isUnread ? .bold : .regular)
                Spacer(minLength: 4)
                if let text = entry.badgeText {
                    Text(text)
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor))
                        // Decoration: the row's own value carries the sentence (the same split
                        // `ChannelSidebarRow` uses for its badges, and for the same reason — a
                        // `Button` merges its label's children into one accessibility element).
                        .accessibilityHidden(true)
                }
            }
            // A `.plain` button hit-tests its label's content shape; without this the space after the
            // Spacer would not take a tap even though the row is reported as the control.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("nativeSidebarAllThreads")
        .accessibilityValue(entry.accessibilityValue)
    }
}
