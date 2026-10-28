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
    /// T47: the owner of the create form's model and the direct-message picker's model. The create
    /// **menu** and the create **form** must agree about what this reader may create, and the permission
    /// answer is one value — so both read the same model.
    @EnvironmentObject private var channelInfo: ChannelInfoCoordinator
    /// T8f: the phone draws the channel list on the grouped background `List(.sidebar)` used; the
    /// regular layout keeps the pane's own background.
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var quickSwitcherPresented = false
    /// T40: the channel browser (S24). Presented from this list because the list is where a missing
    /// channel would be looked for.
    @State private var browseChannelsPresented = false
    /// T47: the create menu (the `+` upstream draws in the channel list header), the create form, and the
    /// direct-message picker.
    @State private var createChannelPresented = false
    @State private var newDirectMessagePresented = false
    @State private var createModel: ChannelCreateViewModel?
    @State private var directMessageModel: NewDirectMessageViewModel?
    /// The team's global-thread list, resolved once the sidebar knows its team. Held so the row can
    /// draw the unread count live: a thread that arrives over the socket moves the badge the same
    /// way it moves the list.
    @State private var globalThreads: GlobalThreadsViewModel?

    /// The channel list's scroll surface (T8f). The suites reveal a row that is beyond the fold by
    /// swiping this element; it replaces the `List`'s `UICollectionView` that
    /// `T33ChannelSidebarUITests.revealRow` used to grab with `collectionViews.firstMatch`
    /// (`ShellSettle.channelSidebarScroll` is the one reader).
    static let scrollIdentifier = "channelSidebar.scroll"

    var body: some View {
        // T8f: `ScrollView` + `LazyVStack`, not `List`.
        //
        // Why: after T8e every row is one accessibility element, but a row in this `List` still
        // cost **7** snapshot elements — `Cell` plus five empty `Other` wrappers around the row's
        // own element. They are the `List`'s scaffolding, not row content: measured in the same
        // snapshot, the team rail (built `ScrollView` + `VStack`) costs 1 per row. Removing them is
        // the whole remaining gap to the card's "well under 120" (docs/t8f-sidebar-list-swap.md).
        //
        // What the `List` gave us, and where each behaviour went:
        //  - **laziness** — kept: `LazyVStack` realises only what is near the viewport, so a row
        //    below the fold is still absent from the tree (the suites rely on that, and it is why
        //    `revealRow` has to scroll). The realised window is *larger* than the `List`'s was
        //    (measured: 26–36 rows per tree against 7–21), which is why one snapshot of this screen
        //    can hold more rows than before;
        //  - **sticky section headers** — **not reproduced.** They are requested with
        //    `pinnedViews: [.sectionHeaders]`, but measured on the drawn shell they do not stick:
        //    in the T33 live run's scrolled frames the top of the list is a channel row while the
        //    enclosing category's header is above the viewport, and no header element in any of
        //    that run's serialised trees sits at the top of the scroll view. Recorded as a known
        //    loss in `docs/t8f-sidebar-list-swap.md` §4;
        //  - **the grouped row chrome** (`.listStyle(.sidebar)` on a phone: rows on a grouped
        //    surface, inset separators, uppercase secondary header) — re-drawn by
        //    `channelSidebarRowSurface()` / `channelSidebarSectionHeaderSurface()` below;
        //  - **row separators** — re-drawn per row (they were the style's, not ours);
        //  - **selection** — nothing to keep: this `List` never had a `selection:` binding. A row is
        //    a `Button` that routes through `NativeNavigation`, and `.isSelected` rides the row's
        //    accessibility traits (T8e), so there was no list-level selection state.
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                workspaceSection
                channelSections
                footerSection
            }
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .background(sizeClass == .compact ? Color(.systemGroupedBackground) : Color.clear)
        // The sidebar's own scroll surface. A suite that has to reveal a row below the fold swipes
        // **this** (`ShellSettle.channelSidebarScroll`); it used to reach into the `List`'s
        // `UICollectionView`, which no longer exists.
        .accessibilityIdentifier(NativeChannelSidebarContent.scrollIdentifier)
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
            // T47: resolve the create menu's model (and its permission answer) for the team on screen.
            // Loaded here rather than when the menu opens so the `+` is drawn only once the server has
            // said what this reader may create — the menu never lists an action that would be refused.
            let create = channelInfo.createModel(for: server, teamID: teamID)
            createModel = create
            if create.phase != .ready { await create.load() }
            let directMessages = channelInfo.directMessageModel(for: server, teamID: teamID)
            directMessageModel = directMessages
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
        // T47: the create form and the direct-message picker. Both land on the new conversation through
        // `NativeNavigation.openChannel` — the one funnel — so the phone push and the split-view
        // selection agree.
        .sheet(isPresented: $createChannelPresented) {
            if let createModel {
                CreateChannelView(model: createModel) { channel in
                    land(on: channel)
                }
            }
        }
        .sheet(isPresented: $newDirectMessagePresented) {
            if let directMessageModel {
                NewDirectMessageView(model: directMessageModel) { channel in
                    land(on: channel)
                }
            }
        }
        // The create menu lives in the section header's `+` (`ChannelCreateMenuButton`), which observes
        // the model itself — a `@State`-held model read here would never re-render, and the `+` would be
        // born hidden while the permission answer was still in flight (the defect T40-R measured).
    }

    /// Land on a channel that was just created (or a DM that was just opened).
    ///
    /// Two steps, in this order: reload the list, then route. The reload is not decoration — the
    /// location is resolved against the loaded channel list, and a channel the list does not know yet
    /// would open a pane titled with the URL slug (the T40-R defect) or leave the sidebar without the
    /// row the reader is standing in. The list comes from the server (`GET
    /// /users/me/teams/{tid}/channels`), so the row's presence is the server's answer, not local state.
    private func land(on channel: MMChannel) {
        Task {
            await model.reload()
            navigation.openChannel(NativeChannelRequest(serverID: server.id,
                                                        teamID: model.teamID ?? channel.teamId,
                                                        teamName: displayedTeamName,
                                                        channelID: channel.id,
                                                        channelName: channel.name))
        }
    }

    // MARK: Sections

    private var workspaceSection: some View {
        Section {
            // The pane's anchor row carries `nativeSidebar` in every state (T32-R F2).
            NativeSidebarAnchorRow(server: server)
                .channelSidebarRowContent()
                .channelSidebarRowSurface(separator: false)

            if let title = teamTitle {
                HStack(spacing: 8) {
                    Image(systemName: "person.3")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(title)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
                // T8e: `.combine` did not merge the pair — the serialised tree still had
                // `StaticText(sidebarCurrentTeam)` with an `Image('person.3')` child, so VoiceOver
                // read the symbol name and every snapshot paid for it. The representation is one
                // element; the identifier and the label the suites assert are unchanged.
                .accessibilityRepresentation {
                    Text(title)
                        .accessibilityIdentifier("sidebarCurrentTeam")
                }
                .accessibilityIdentifier("sidebarCurrentTeam")
                .channelSidebarRowContent()
                .channelSidebarRowSurface()
            }

            // The Threads entry, above the categories — upstream mounts its Threads button in the
            // channel list's own body for exactly this reason (`categories_list.tsx` renders
            // `ThreadsButton` above the categories). Below the list it was unreachable in practice on a
            // real account: this server's `perfprobe` is in 11 categories / 347 channels, so the row sat
            // past hundreds of conversations and is not built at all until scrolled to (measured: the
            // live suite found no `nativeSidebarAllThreads` row, and the reader's report — "no place to
            // see unread threads" — is what that looks like from the outside).
            threadsEntry
                .channelSidebarRowSurface()

            Button {
                quickSwitcherPresented = true
            } label: {
                Label("Jump to a channel…", systemImage: "magnifyingglass")
                    .channelSidebarRowContent()
            }
            .accessibilityIdentifier("channelSidebar.quickSwitcher")
            .channelSidebarRowSurface()
            // The desktop shortcut (cmd/ctrl-K) on a hardware keyboard; harmless where there is none.
            .keyboardShortcut("k", modifiers: .command)

            // T40: the channel browser (S24). It sits here, beside the switcher, because a lazy list
            // renders its sections lazily — the same row at the bottom of a long channel list is not
            // on screen and therefore not reachable without scrolling, and "find a channel I am not
            // in" belongs with "find a channel I am in".
            if resolver.resolvedMode(for: .channelInfo) == .native {
                Button {
                    browseChannelsPresented = true
                } label: {
                    Label("Browse channels", systemImage: "magnifyingglass.circle")
                        .channelSidebarRowContent()
                }
                .accessibilityIdentifier("nativeSidebarBrowseChannels")
                .channelSidebarRowSurface()
            }
        } header: {
            HStack(spacing: 6) {
                Text("Workspace")
                Spacer(minLength: 0)
                // T47: the `+` upstream draws in the channel list header (S09/S10's create entry).
                if let createModel {
                    ChannelCreateMenuButton(model: createModel,
                                            createChannel: $createChannelPresented,
                                            browseChannels: $browseChannelsPresented,
                                            directMessage: $newDirectMessagePresented)
                }
            }
            .channelSidebarSectionHeaderSurface()
        }
    }

    @ViewBuilder
    private var channelSections: some View {
        if model.groups.isEmpty {
            Section {
                channelStateRow
                    .channelSidebarRowContent()
                    .channelSidebarRowSurface(separator: false)
            } header: {
                Text("Channels")
                    .channelSidebarSectionHeaderSurface()
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
                            // The `List` drew a separator above every row but the first; so does
                            // the card (`channelSidebarRowSurface`).
                            .channelSidebarRowSurface(separator: entry.id != group.entries.first?.id)
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
                    .channelSidebarSectionHeaderSurface()
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
                .channelSidebarRowContent()
            }
            .buttonStyle(.plain)
            .accessibilityRepresentation {
                Button("Threads", action: openThreads)
                    .accessibilityIdentifier("nativeSidebarAllThreads")
            }
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

    /// What the footer says, as one sentence: the counts, or "All caught up", plus the stale warning
    /// when the counts could not be refreshed (T8e — the footer is one accessibility element).
    private var countsSentence: String {
        let base = model.totals.accessibilityLabel ?? "All caught up"
        return model.countsAreStale ? "\(base). Unread counts may be out of date" : base
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
            // One element (T8e): the bell glyph, the counts sentence and the stale marker were three
            // elements in every snapshot. `.combine` did not merge them (measured); the representation
            // does, and keeps the stale warning as part of what VoiceOver reads.
            .accessibilityRepresentation {
                Text(countsSentence)
                    .accessibilityIdentifier("channelSidebar.totals")
            }
            .accessibilityIdentifier("channelSidebar.totals")
            .channelSidebarRowContent()
            .channelSidebarRowSurface(separator: false)
            // The footer is its own group with no header of its own; the `List` gave it a gap and
            // so does this (applied outside the surface, so the gap is the grouped background).
            .padding(.top, 16)

            if let actionError = model.actionError {
                Text(actionError)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("channelSidebar.actionError")
                    .channelSidebarRowContent()
                    .channelSidebarRowSurface()
            }

            // The T26 escape hatch has to survive every native state of this pane.
            Button {
                resolver.forceWebForThisRun(SurfaceDefaults.paneHostSurface)
            } label: {
                Label("Use web view", systemImage: "safari")
                    .channelSidebarRowContent()
            }
            .accessibilityIdentifier("revertToWeb\(SurfaceDefaults.paneHostSurface.rawValue)")
            .channelSidebarRowSurface()
        } footer: {
            if model.groupingIsApproximate {
                Text("Your custom categories could not be loaded, so channels are grouped by type.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 32)
                    .padding(.top, 4)
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
        // One header, one element (T8e): the disclosure chevron, the name and the mute marker were
        // three elements — `Image('chevron.down')`, `StaticText`, `Image('bell.slash')`. The name stays
        // the label; the mute fact moves into the value so VoiceOver still says it (a `Button`'s label
        // children are not merged by `.combine`, measured — see `docs/t8e-a11y-tree-decision.md`).
        .accessibilityRepresentation {
            Button(group.displayName, action: onToggle)
                .accessibilityIdentifier(group.identifier)
                .accessibilityValue(group.category.muted ? "Muted" : "")
        }
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
            // a tap, the space after the Spacer does not. The shape makes the touch target and the
            // reported frame agree, and (T8f, no `List` row any more) it is also what gives the row
            // its insets and 44 pt height.
            .channelSidebarRowContent()
        }
        .buttonStyle(.plain)
        // One row, one accessibility element (T8e). A `Button` whose label is an `HStack` exposes its
        // label's children as separate elements — measured: every channel row in the drawn shell was
        // `Button + Image('number') + StaticText`, and `.accessibilityElement(children: .ignore)` on the
        // button only *wrapped* it (`Other(id) → Button`). `.accessibilityRepresentation` replaces the
        // row's accessibility subtree with this one button: 9 elements per row → 7, and VoiceOver gets
        // one stop named by the channel instead of "General", "3", "unread".
        .accessibilityRepresentation {
            Button(entry.displayName, action: action)
                .accessibilityIdentifier("channelSidebar.channel.\(entry.id)")
                .accessibilityValue(entry.accessibilityValue)
                .accessibilityAddTraits(entry.isSelected ? [.isSelected] : [])
        }
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
            // Spacer would not take a tap even though the row is reported as the control. T8f: with
            // no `List` row any more, the same modifier is what gives the row its insets and height.
            .channelSidebarRowContent()
        }
        .buttonStyle(.plain)
        // PROBE (t_ce08486d): does a representation drop the `Label`'s symbol Image?
        .accessibilityRepresentation {
            Button("Threads", action: action)
                .accessibilityIdentifier("nativeSidebarAllThreads")
                .accessibilityValue(entry.accessibilityValue)
        }
        .accessibilityIdentifier("nativeSidebarAllThreads")
    }
}

// MARK: - The create menu

/// The channel list's `+`: upstream's create menu, in the section header where upstream draws it.
///
/// Its own view for one reason: it **observes** `ChannelCreateViewModel`. The permission answer arrives
/// after the sidebar's first paint (`POST /roles/names`), and a model held in the parent's `@State` and
/// read there would never re-render — the `+` would keep the "no permissions" shape it was born with and
/// the create path would be unreachable while every unit test stayed green (the defect T40-R measured on
/// three other surfaces).
///
/// A model that has answered and offers nothing draws no `+` at all: a create entry that opens an empty
/// sheet is worse than no entry.
private struct ChannelCreateMenuButton: View {
    @ObservedObject var model: ChannelCreateViewModel
    @Binding var createChannel: Bool
    @Binding var browseChannels: Bool
    @Binding var directMessage: Bool

    @State private var menuPresented = false

    var body: some View {
        if !model.menuActions.isEmpty {
            Button {
                menuPresented = true
            } label: {
                Image(systemName: "plus")
                    .font(.footnote.weight(.semibold))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Create")
            .accessibilityIdentifier("nativeSidebarCreateMenu")
            // An action sheet rather than a `Menu`: the three rows are ordinary buttons that keep their
            // accessibility identifiers (a `Menu` synthesises its children into the popover, and the
            // identifiers are the first thing to go — measured on the same class of control in T40).
            .confirmationDialog("Create", isPresented: $menuPresented, titleVisibility: .visible) {
                ForEach(model.menuActions, id: \.rawValue) { action in
                    Button(action.title) {
                        // One run-loop turn later, not in this one: the dialog is still dismissing, and
                        // presenting the form's sheet in the same turn is dropped by UIKit
                        // ("…which is already presenting <UIAlertController>"). Measured under a relay hop
                        // (`docs/t47-relay-witness-2026-10-27.log`): the direct-message sheet then never
                        // appeared at all, while the tap on the row had registered.
                        DispatchQueue.main.async {
                            switch action {
                            case .createChannel: createChannel = true
                            case .browseChannels: browseChannels = true
                            case .createDirectMessage: directMessage = true
                            }
                        }
                    }
                    .accessibilityIdentifier(action.identifier)
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

// MARK: - Row metrics (T8f)
//
// These three modifiers are what `List` + `.listStyle(.sidebar)` used to draw on a phone, written
// out because the channel list is a `ScrollView` + `LazyVStack` now
// (`docs/t8f-sidebar-list-swap.md`):
//
//  * `channelSidebarRowContent` — the row's own insets (16 pt), its 44 pt minimum height and the
//    full-width hit area. It goes **inside** a row's `Button` label, so the whole row takes a tap
//    (a `.plain` button otherwise hit-tests only its label's content shape);
//  * `channelSidebarRowSurface` — the surface the row is drawn on: on the phone a row of the
//    grouped background with a hairline separator above every row but the first; on the regular
//    (iPad) layout nothing, because `.sidebar` draws flat rows there. It is applied to the row
//    view, outside the `Button` (or to a plain row, which needs both);
//  * `channelSidebarSectionHeaderSurface` — the small, upper-cased, secondary caption above a
//    group, with an opaque background of its own so a **pinned** header — when the platform pins
//    it — hides the rows sliding under it (measured: the pinned headers are requested but do not
//    stick; see the note).
//
// None of the three is an accessibility element: a `Rectangle`/`Color` carries no label, and
// padding/frames do not move an identifier (the T8e contract is untouched — every row is still
// exactly one element).

/// The insets and hit area a row used to inherit from its `List` row.
private struct ChannelSidebarRowContent: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
    }
}

/// The surface a row stands on — the phone's grouped background and its inset separator.
private struct ChannelSidebarRowSurface: ViewModifier {
    var separator: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        // `compact` is the phone: `.listStyle(.sidebar)` drew grouped rows there. The regular
        // (iPad/Mac) sidebar drew flat rows, so nothing is painted there — the pane's own
        // background shows through, as it did before.
        let grouped = sizeClass == .compact
        return content
            .background(grouped ? Color(.secondarySystemGroupedBackground) : Color.clear)
            .overlay(alignment: .top) {
                if separator && grouped {
                    Rectangle()
                        .fill(Color(.separator))
                        .frame(height: 0.5)
                        .padding(.leading, 16)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, grouped ? 16 : 0)
    }
}

/// The section header: the caption above a group, on its own opaque surface while pinned.
private struct ChannelSidebarSectionHeaderSurface: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        let grouped = sizeClass == .compact
        return content
            .font(.footnote)
            // `.sidebar` upper-cased the header's text. `textCase` is presentation only — a header
            // whose accessibility label is set explicitly (`CategoryHeader`'s representation) keeps
            // the server's own category name, exactly as the suites assert it.
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.horizontal, grouped ? 32 : 16)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(grouped ? Color(.systemGroupedBackground) : Color(.systemBackground))
    }
}

private extension View {
    /// A row's insets, minimum height and full-width hit area. Applied inside a row's label.
    func channelSidebarRowContent() -> some View {
        modifier(ChannelSidebarRowContent())
    }

    /// The surface a row is drawn on, and (unless it is the first row of a group) its separator.
    func channelSidebarRowSurface(separator: Bool = true) -> some View {
        modifier(ChannelSidebarRowSurface(separator: separator))
    }

    /// The caption above a group, with the opaque background a pinned header needs.
    func channelSidebarSectionHeaderSurface() -> some View {
        modifier(ChannelSidebarSectionHeaderSurface())
    }
}
