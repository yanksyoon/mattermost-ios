// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/components/team_sidebar/team_sidebar.tsx (the rail: fixed-width column, collapsed to 0
//        width when the user has one team, dark sidebar background, list grows from the top),
//        app/components/team_sidebar/team_list/team_list.tsx (one scrollable column of items),
//        app/components/team_sidebar/team_list/team_item/team_item.tsx (54pt item, 3pt selected
//        ring, badge hidden when selected), team_item/team_icon.tsx (rounded icon, display-name
//        initials when there is no icon update), app/components/badge (count / dot, red,
//        border-coloured), app/screens/select_team/no_teams.tsx (zero-team copy).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §3; no
// upstream source copied. SwiftUI decomposition is this repo's own (docs/component-map.md §1).

import SwiftUI
import UIKit

// MARK: - The pane

/// The team region of the sidebar, and the pane that hosts it.
///
/// Three of the card's acceptance criteria are encoded here rather than in prose:
///  - a user with **one** team gets no rail at all (`TeamSidebarContent.single` → the rail is not
///    built, only the channel list the user actually asked for);
///  - a user with **zero** teams gets an empty state with upstream's copy, not an empty rail;
///  - a load failure says what failed and offers a retry, and still offers the T26 escape hatch.
///
/// The rail is mounted *inside* the sidebar pane (upstream mounts `TeamSidebar` inside
/// `channel_list`, sharing its lifetime), so the channel list keeps owning its own scroll and the
/// rail cannot outlive the pane it belongs to.
struct NativeTeamSidebarPane<Content: View>: View {
    let server: ServerConfig
    @ObservedObject var navigation: NativeNavigation
    @ObservedObject var model: TeamSwitchViewModel
    @EnvironmentObject private var teams: TeamSidebarCoordinator

    private let content: () -> Content

    init(server: ServerConfig,
         navigation: NativeNavigation,
         model: TeamSwitchViewModel,
         @ViewBuilder content: @escaping () -> Content) {
        self.server = server
        self.navigation = navigation
        self.model = model
        self.content = content
    }

    var body: some View {
        Group {
            switch model.content {
            case .empty:
                TeamSidebarEmptyState(server: server, model: model)
            case .failed(let message) where model.entries.isEmpty:
                TeamSidebarFailureState(server: server, model: model, message: message)
            default:
                // Everything else — including the first load — draws the pane's own content. A rail
                // that has no answer yet must not blank the sidebar: the channel list below it is
                // the pane's T30 content and stays usable (and its identifiers stay on screen) while
                // the teams call is in flight. `.loading` simply has no rail to show yet.
                HStack(spacing: 0) {
                    if showsRail {
                        TeamSidebarRail(server: server, navigation: navigation, model: model)
                    }
                    content()
                }
            }
        }
        // The appearance pass: load the rail once and make sure this server's single socket is up.
        .task { await teams.activate(server) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nativeTeamSidebar")
    }

    /// Upstream collapses the rail's width to 0 when there is one team; a single icon beside a
    /// channel list is chrome that says nothing, so it is not built at all.
    private var showsRail: Bool {
        if case .rail = model.content { return true }
        return false
    }
}

// MARK: - The rail

/// The vertical team rail: one icon per team, the selected one ringed, mention counts on the rest.
struct TeamSidebarRail: View {
    let server: ServerConfig
    @ObservedObject var navigation: NativeNavigation
    @ObservedObject var model: TeamSwitchViewModel
    @EnvironmentObject private var teams: TeamSidebarCoordinator

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(model.entries) { entry in
                        TeamIconButton(entry: entry,
                                       model: model,
                                       server: server) {
                            switch teams.select(entry, on: server) {
                            case .switched:
                                break
                            case .alreadyCurrent:
                                break
                            case .needsReauth, .unavailable:
                                // The outcome is reported by the shell: a failed switch must not look
                                // like a switch (the ring stays where the location says it is).
                                break
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
            }

            if model.countsAreStale {
                // A count that could not be refreshed is not silently drawn as a fact.
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
                    .accessibilityLabel("Unread counts may be out of date")
                    .accessibilityIdentifier("teamSidebar.staleCounts")
            }
        }
        .frame(width: 64)
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .trailing) {
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("teamSidebar.rail")
    }
}

/// One team's icon: the server's uploaded image when it has one, otherwise the display-name
/// initials (upstream `TeamIcon`), ringed while selected, with the mention badge or unread dot.
struct TeamIconButton: View {
    let entry: TeamSidebarEntry
    @ObservedObject var model: TeamSwitchViewModel
    let server: ServerConfig
    let action: () -> Void

    @State private var image: UIImage?

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                icon
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    // A white plate around the icon, so the selection ring has a gap on *both*
                    // kinds of tile: an uploaded icon can be any colour (the seeded one is solid
                    // blue), and an accent ring drawn straight onto a blue tile is invisible.
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 13))
                    .frame(width: 52, height: 52)
                    .overlay {
                        RoundedRectangle(cornerRadius: 13)
                            .strokeBorder(entry.isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                                          lineWidth: entry.isSelected ? 2 : 1)
                    }

                badge
            }
        }
        .buttonStyle(.plain)
        // The identifier carries the team id, so a test (or a future UI automation) can address one
        // team without depending on how many rows came before it.
        .accessibilityIdentifier("teamSidebar.team.\(entry.id)")
        .accessibilityLabel(entry.displayName)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(entry.isSelected ? [.isSelected] : [])
        .task(id: entry.lastIconUpdatedAt) {
            image = await model.icon(for: entry)
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: 9))
        } else {
            Text(entry.initials)
                .font(.headline.weight(.semibold))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .foregroundStyle(entry.isSelected ? Color.accentColor : .secondary)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var badge: some View {
        switch entry.badge {
        case .none:
            EmptyView()
        case .dot:
            Circle()
                .fill(Color.red)
                .frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(Color(.secondarySystemBackground), lineWidth: 1.5))
                .offset(x: 5, y: -3)
                .accessibilityHidden(true)
        case .count:
            Text(entry.badge.text ?? "")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.red, in: Capsule())
                .overlay(Capsule().strokeBorder(Color(.secondarySystemBackground), lineWidth: 1.5))
                .offset(x: 6, y: -4)
                // The pill's own text would read as a bare digit; the button's value already says
                // "3 mentions", so the decorative pill stays out of the accessibility tree.
                .accessibilityHidden(true)
        }
    }

    /// What VoiceOver (and a UI test) reads for this team: the selected state and the badge in words.
    private var accessibilityValue: String {
        var parts: [String] = []
        if entry.isSelected { parts.append("Current team") }
        if let badge = entry.badgeAccessibilityLabel { parts.append(badge) }
        if model.countsAreStale { parts.append("Unread counts may be out of date") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Non-rail states

/// Zero teams. Upstream `select_team/no_teams.tsx` copy, with a retry (a list can be empty because
/// the request failed, and the rail is the only place the user could notice).
struct TeamSidebarEmptyState: View {
    let server: ServerConfig
    @ObservedObject var model: TeamSwitchViewModel
    @EnvironmentObject private var resolver: SurfaceModeResolver

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: "person.3.sequence.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text("No teams are available to join")
                            .font(.headline)
                    }
                    Text("To join a team, ask a team admin for an invite, or create your own team. "
                         + "You may also want to check your email inbox for an invitation.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.countsAreStale {
                        Text("Unread counts may be out of date.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityIdentifier("teamSidebar.empty")
            }

            Section {
                Button {
                    Task { await model.reload() }
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("teamSidebar.retry")

                // The T26 escape hatch has to survive every native state of this pane, including
                // this one: a pane that resolves native can always be handed back to the web view.
                Button {
                    resolver.forceWebForThisRun(SurfaceDefaults.paneHostSurface)
                } label: {
                    Label("Use web view", systemImage: "safari")
                }
                .accessibilityIdentifier("revertToWeb\(SurfaceDefaults.paneHostSurface.rawValue)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("teamSidebar.emptyState")
    }
}

/// The rail could not be loaded and there is nothing to draw.
struct TeamSidebarFailureState: View {
    let server: ServerConfig
    @ObservedObject var model: TeamSwitchViewModel
    let message: String
    @EnvironmentObject private var resolver: SurfaceModeResolver

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Could not load your teams", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
                .accessibilityIdentifier("teamSidebar.error")
            }
            Section {
                Button {
                    Task { await model.reload() }
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("teamSidebar.retry")
                Button {
                    resolver.forceWebForThisRun(SurfaceDefaults.paneHostSurface)
                } label: {
                    Label("Use web view", systemImage: "safari")
                }
                .accessibilityIdentifier("revertToWeb\(SurfaceDefaults.paneHostSurface.rawValue)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("teamSidebar.errorState")
    }
}


