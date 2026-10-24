// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/components/team_sidebar/team_sidebar.tsx (rail width collapses to 0 when the user has
//        one team), app/components/team_sidebar/team_list/team_list.tsx + team_list/index.ts
//        (`myOrderedTeams`: the `teams_order` preference first, then displayName),
//        app/components/team_sidebar/team_list/team_item/team_item.tsx + team_icon.tsx (54pt item,
//        selected ring, badge = mention count, dot when unread but no mentions, initials fallback,
//        icon fetched from `/teams/{id}/image?_{last_team_icon_update}`),
//        app/actions/remote/team.ts `handleTeamChange` (no-op when the tapped team is already
//        current; otherwise current team changes and the current channel is cleared),
//        app/client/rest/teams.ts (`getMyTeams` `/users/me/teams`, `getMyTeamMembers`
//        `/users/me/teams/members`, `getTeamIconUrl`), app/screens/select_team/no_teams.tsx (copy of
//        the zero-team state), and `app/utils/` team unread reads (`/users/me/teams/unread`).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §3; no
// upstream source copied. SwiftUI/async-Swift decomposition is this repo's own
// (docs/component-map.md §1).

import Combine
import Foundation
import UIKit

// MARK: - Value types (pure; unit-tested without a server or a view)

/// One row of the team rail: everything the rail renders, derived once from the server's answer.
///
/// A value type on purpose (component-map §1): SwiftUI diffs it, so "the badge did not change" is a
/// real comparison rather than a re-render that happens to look the same.
struct TeamSidebarEntry: Identifiable, Equatable, Sendable {
    /// The team id — the API's identity for a team, and the key `handleTeamChange` switches on.
    let id: String
    /// The team *name* (the URL segment), which is what a deep link carries (`/{team}/channels/…`).
    /// Kept beside the id so a switch writes both into the one `NativeLocation`.
    let name: String
    let displayName: String
    /// Upstream draws `displayName.substring(0, 2).toUpperCase()` when there is no icon.
    let initials: String
    let mentionCount: Int
    let unreadCount: Int
    /// `last_team_icon_update`: `0` means "no icon uploaded", which is the initials fallback
    /// (upstream `nameOnly = imageError || !lastIconUpdate`).
    let lastIconUpdatedAt: Int64
    let isSelected: Bool

    /// The badge this row draws (mentions > dot > nothing, and nothing at all while selected).
    var badge: TeamSidebarBadge {
        TeamSidebarDerivation.badge(mentionCount: mentionCount,
                                    unreadCount: unreadCount,
                                    isSelected: isSelected)
    }

    /// The accessible sentence for the badge: the number alone reads as a bare digit to VoiceOver.
    var badgeAccessibilityLabel: String? {
        switch badge {
        case .none: return nil
        case .dot: return "Unread messages"
        case .count(let value):
            return value == 1 ? "1 mention" : "\(value > 99 ? "more than 99" : String(value)) mentions"
        }
    }
}

/// The badge on a team icon. Upstream's `TeamItem` collapses three states into one badge value
/// (`mentionCount`, `-1` for a bare unread dot, hidden when zero or selected).
enum TeamSidebarBadge: Equatable, Sendable {
    case none
    case dot
    case count(Int)

    /// What the badge draws, or `nil` for no badge. >99 renders `99+` (the count keeps growing
    /// server-side; the badge stops being readable past two digits).
    var text: String? {
        switch self {
        case .none: return nil
        case .dot: return nil
        case .count(let value): return value > 99 ? "99+" : String(value)
        }
    }

    var isDot: Bool { self == .dot }
}

/// What the team region shows. Four states, because they are four different things to draw:
/// nothing yet, a user with no teams, a user with exactly one team (no redundant chrome), and a
/// rail.
enum TeamSidebarContent: Equatable, Sendable {
    case loading
    case failed(String)
    case empty
    case single(TeamSidebarEntry)
    case rail([TeamSidebarEntry])
}

/// Everything one load of the team rail needs, straight off the wire.
struct TeamSidebarData: Equatable, Sendable {
    var teams: [MMTeam] = []
    var memberships: [MMTeamMembership] = []
    var unreads: [MMTeamUnread] = []
    /// The ids from the `teams_order` preference (mobile `Preferences.CATEGORIES.TEAMS_ORDER`).
    var order: [String] = []
    /// `true` when the unread counters could not be read this time: the rail keeps the numbers it
    /// already had and says they may be out of date, instead of drawing a confident `0`.
    var unreadsFailed = false
}

/// The decode/derive/format rules, separated from the view model so they can be tested exhaustively
/// without a network, a vault or a `NativeNavigation`.
enum TeamSidebarDerivation {

    /// Upstream badge rule (`team_item.tsx`): a selected team shows no badge at all; mentions win
    /// over a bare unread dot; otherwise a dot for unread messages.
    static func badge(mentionCount: Int, unreadCount: Int, isSelected: Bool) -> TeamSidebarBadge {
        guard !isSelected else { return .none }
        if mentionCount > 0 { return .count(mentionCount) }
        if unreadCount > 0 { return .dot }
        return .none
    }

    /// The initials fallback. **Grapheme clusters**, not UTF-16 units: `substring(0, 2)` in
    /// JavaScript is code-unit based and splits astral-plane characters (a flag, an emoji) in half,
    /// and it keeps a trailing space (`"🇯🇵 team"` → `"🇯🇵 "`, drawn as a one-glyph tile). The port
    /// takes the first two grapheme clusters of the name with its spaces removed.
    /// An empty display name falls back to the (already trimmed) team name at the call site.
    static func initials(_ displayName: String) -> String {
        let compact = displayName.filter { !$0.isWhitespace }
        return String(compact.prefix(2)).uppercased()
    }

    /// `teams_order` preference → an ordered id list. Mobile reads the first row of that category and
    /// splits its value on `,`; unknown ids are kept here and filtered against the membership list
    /// later, so a stale preference cannot hide a team.
    static func order(from preferences: [MMPreference]) -> [String] {
        for preference in preferences where preference.category == "teams_order" {
            let ids = preference.value
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !ids.isEmpty { return dedupe(ids) }
        }
        return []
    }

    /// Sort teams the way the rail draws them: the explicit order first, everything else
    /// alphabetically by display name (upstream sorts with `localeCompare` on a lowercased name).
    /// The id breaks ties so the rail cannot reshuffle between two identical display names.
    static func sorted(_ teams: [MMTeam], order: [String]) -> [MMTeam] {
        var positions: [String: Int] = [:]
        for (index, id) in order.enumerated() where positions[id] == nil {
            positions[id] = index
        }
        let ordered = teams
            .filter { positions[$0.id] != nil }
            .sorted { (positions[$0.id] ?? 0) < (positions[$1.id] ?? 0) }
        let rest = teams
            .filter { positions[$0.id] == nil }
            .sorted { lhs, rhs in
                let left = displaySortKey(lhs)
                let right = displaySortKey(rhs)
                if left == right { return lhs.id < rhs.id }
                return left.localizedStandardCompare(right) == .orderedAscending
            }
        return ordered + rest
    }

    /// Filter to the teams the user is *actually* in and project each one into a rail entry.
    ///
    /// - The membership list decides, when it is available: a soft-deleted membership
    ///   (`delete_at > 0`) removes the team, and a row for another user adds nothing.
    /// - When the memberships endpoint failed (an older server, a transient 500), `/users/me/teams`
    ///   is the authority instead — it already answers "my teams", and dropping the whole rail
    ///   because the second endpoint failed would be worse than drawing it.
    /// - Unread counters are per team; a team with no row has no count (and no badge).
    static func entries(from data: TeamSidebarData,
                        userID: String?,
                        selectedTeamID: String?,
                        selectedTeamName: String?) -> [TeamSidebarEntry] {
        var liveMemberships: Set<String>?
        if let userID, !data.memberships.isEmpty {
            liveMemberships = Set(
                data.memberships
                    .filter { $0.userId == userID && $0.deleteAt == 0 }
                    .map { $0.teamId }
            )
        }
        let unreadByTeam = Dictionary(data.unreads.map { ($0.teamId, $0) },
                                      uniquingKeysWith: { first, _ in first })

        let teams = data.teams.filter { team in
            guard team.deleteAt == 0 else { return false }
            guard let liveMemberships else { return true }
            return liveMemberships.contains(team.id)
        }

        return sorted(teams, order: data.order).map { team in
            let unread = unreadByTeam[team.id]
            let selected = isSelected(team, teamID: selectedTeamID, teamName: selectedTeamName)
            let displayName = team.displayName.isEmpty ? team.name : team.displayName
            return TeamSidebarEntry(id: team.id,
                                    name: team.name,
                                    displayName: displayName,
                                    initials: initials(displayName),
                                    mentionCount: unread?.mentionCount ?? 0,
                                    unreadCount: unread?.msgCount ?? 0,
                                    lastIconUpdatedAt: team.lastTeamIconUpdatedAt,
                                    isSelected: selected)
        }
    }

    /// Which entry the rail marks as current. An id is exact; a *name* is what a deep link carries
    /// (`mattermost://host/acme/channels/general` has no team id), so name matching is what keeps a
    /// deep link from leaving the rail pointing at the previously selected team.
    static func isSelected(_ team: MMTeam, teamID: String?, teamName: String?) -> Bool {
        if let teamID, !teamID.isEmpty { return team.id == teamID }
        if let teamName, !teamName.isEmpty { return team.name == teamName }
        return false
    }

    /// The four states of the region (see `TeamSidebarContent`).
    static func content(phase: TeamSwitchViewModel.Phase,
                        entries: [TeamSidebarEntry]) -> TeamSidebarContent {
        if entries.isEmpty {
            switch phase {
            case .idle, .loading: return .loading
            case .failed(let message): return .failed(message)
            case .loaded: return .empty
            }
        }
        if entries.count == 1 { return .single(entries[0]) }
        return .rail(entries)
    }

    private static func displaySortKey(_ team: MMTeam) -> String {
        (team.displayName.isEmpty ? team.name : team.displayName).lowercased()
    }

    private static func dedupe(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}

// MARK: - What the screen needs from the server

/// One server's team data. Split from the view model so a test can hand in fixtures, and so the
/// production implementation is the only place that knows about `AuthSession`.
@MainActor
protocol TeamSidebarServing: AnyObject {
    /// `GET /users/me/teams` + `/users/me/teams/members` + `/users/me/teams/unread` + the
    /// `teams_order` preference, as one answer.
    func load() async throws -> TeamSidebarData
    /// Just the counters — the cheap refresh the socket drives.
    func unreads() async throws -> [MMTeamUnread]
    /// Authenticated team-icon bytes, or `nil` when the team has no icon.
    func icon(for teamID: String, lastUpdateAt: Int64) async -> Data?
}

/// The production implementation: the server's own `AuthSession.client`, so a 401 from any of these
/// calls lands in the app's one re-auth path (`AuthCoordinator.reportUnauthorized`) for free — the
/// rule `AuthCoordinator` states for every later screen.
///
/// The client is resolved **per call**, not captured: the rail is created when the shell first draws
/// it, which can be before the server's session has finished restoring, and a captured `APIClient`
/// would then be a permanently signed-out one.
@MainActor
final class SessionTeamSidebarService: TeamSidebarServing {
    private let resolve: () -> (client: APIClient, userID: String?)?

    init(resolve: @escaping () -> (client: APIClient, userID: String?)?) {
        self.resolve = resolve
    }

    private func resolved() throws -> (client: APIClient, userID: String?) {
        guard let value = resolve() else { throw MMError.notSignedIn }
        return value
    }

    func load() async throws -> TeamSidebarData {
        let (client, userID) = try resolved()
        // The team list is the one required answer: without it there is no rail to draw, and its
        // error is the error the rail shows. The other three are enrichments, each with a defined
        // degraded behaviour (see `TeamSidebarData` and `entries(from:)`).
        let teams = try await client.myTeams()

        var data = TeamSidebarData(teams: teams)
        data.memberships = (try? await client.myTeamMemberships()) ?? []
        do {
            data.unreads = try await client.teamUnreads()
        } catch {
            data.unreadsFailed = true
            // A 401 is not a per-endpoint hiccup: it is the session, and it must reach re-auth
            // rather than be logged as a missing badge count.
            if case MMError.unauthorized = error { throw error }
        }
        if let userID {
            data.order = TeamSidebarDerivation.order(from: (try? await client.preferences(userID: userID)) ?? [])
        }
        return data
    }

    func unreads() async throws -> [MMTeamUnread] {
        let (client, _) = try resolved()
        return try await client.teamUnreads()
    }

    func icon(for teamID: String, lastUpdateAt: Int64) async -> Data? {
        guard let (client, _) = try? resolved() else { return nil }
        return try? await client.teamIconData(teamID: teamID, lastUpdateAt: lastUpdateAt)
    }
}

// MARK: - The view model (one per server, owned by `TeamSidebarCoordinator`)

/// One server's team rail: what to draw, how to refresh it, and how to switch teams.
///
/// **The selection is not stored here.** It is read from `NativeNavigation.location`, the single
/// value every entry point writes (a rail tap, a deep link, a notification), so the rail cannot
/// disagree with the destination the rest of the shell is showing. The coordinator pushes that
/// selection in with `setSelection(teamID:teamName:)`.
@MainActor
final class TeamSwitchViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    let server: ServerConfig

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var entries: [TeamSidebarEntry] = []
    /// Unread counters could not be refreshed: keep the last numbers and label them.
    @Published private(set) var countsAreStale = false
    /// A refresh is in flight while a rail is already on screen (no spinner over the rail).
    @Published private(set) var isRefreshing = false

    private let service: TeamSidebarServing
    private let userID: () -> String?
    private var data = TeamSidebarData()
    private var selectedTeamID: String?
    private var selectedTeamName: String?
    /// Every load takes a number; a load that finishes after a newer one has started (or after a
    /// switch invalidated it) is dropped instead of writing stale data over fresh data.
    private var generation = 0
    private var icons: [String: UIImage] = [:]
    /// team id → the icon update stamp already requested (so a team with no icon is asked once).
    private var iconStamps: [String: Int64] = [:]

    init(server: ServerConfig,
         service: TeamSidebarServing,
         userID: @escaping () -> String? = { nil }) {
        self.server = server
        self.service = service
        self.userID = userID
    }

    /// What the region draws right now.
    var content: TeamSidebarContent { TeamSidebarDerivation.content(phase: phase, entries: entries) }

    /// The team the rail currently marks selected, as far as this model knows.
    var currentSelection: (id: String, name: String)? {
        guard let entry = entries.first(where: { $0.isSelected }) else { return nil }
        return (entry.id, entry.name)
    }

    /// The selection, as the shell is showing it. Idempotent: only a change re-derives the entries,
    /// so a `navigation.$location` subscription can fire as often as it likes.
    func setSelection(teamID: String?, teamName: String?) {
        let normalisedID = teamID?.isEmpty == false ? teamID : nil
        let normalisedName = teamName?.isEmpty == false ? teamName : nil
        guard normalisedID != selectedTeamID || normalisedName != selectedTeamName else { return }
        selectedTeamID = normalisedID
        selectedTeamName = normalisedName
        rebuild()
    }

    /// First load for this server. `ifNeeded` makes the appearance pass cheap: an already-loaded
    /// rail is not re-fetched when SwiftUI re-mounts the sidebar (a tab switch, a rotation).
    func load(ifNeeded: Bool = true) async {
        if ifNeeded, phase == .loaded || phase == .loading { return }
        await performLoad()
    }

    /// An explicit reload: the rail's "Try again", or a foreground/appearance pass that must not
    /// trust what it has.
    func reload() async {
        phase = entries.isEmpty ? .loading : phase
        await performLoad()
    }

    /// Counter-only refresh (socket activity, or a pull-to-refresh once the rail scrolls).
    ///
    /// A failure here never clears the numbers it already has: the badge would then claim "no
    /// mentions" while the server says otherwise, which is the exact wrong direction for a badge.
    func refreshUnreads() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let requestedGen = generation
        do {
            let unreads = try await service.unreads()
            guard requestedGen == generation else { return }
            data.unreads = unreads
            data.unreadsFailed = false
            countsAreStale = false
            if phase == .idle { phase = .loaded }
            rebuild()
        } catch {
            guard requestedGen == generation else { return }
            countsAreStale = true
        }
    }

    /// The authenticated icon for an entry, cached per `id + last_team_icon_update`.
    ///
    /// Cached because the rail re-renders on every badge change and a 54pt icon is not worth a
    /// request each time; keyed on the update stamp so a *changed* icon is fetched rather than
    /// served from the old bytes.
    func icon(for entry: TeamSidebarEntry) async -> UIImage? {
        guard entry.lastIconUpdatedAt > 0 else { return nil }
        let key = "\(entry.id):\(entry.lastIconUpdatedAt)"
        if let cached = icons[key] { return cached }
        // A team whose icon update stamp has already been asked for and produced nothing keeps the
        // initials tile: re-asking on every redraw would be a request per frame for most teams (they
        // have no icon at all). A *new* stamp is a new icon and is asked for again.
        if iconStamps[entry.id] == entry.lastIconUpdatedAt { return nil }
        iconStamps[entry.id] = entry.lastIconUpdatedAt
        guard let bytes = await service.icon(for: entry.id, lastUpdateAt: entry.lastIconUpdatedAt),
              let image = UIImage(data: bytes) else { return nil }
        icons[key] = image
        return image
    }

    // MARK: Internals

    private func performLoad() async {
        generation += 1
        let mine = generation
        if entries.isEmpty { phase = .loading }
        do {
            let next = try await service.load()
            guard mine == generation else { return }
            data = next
            countsAreStale = next.unreadsFailed
            phase = .loaded
            rebuild()
        } catch {
            guard mine == generation else { return }
            if let mmError = error as? MMError, case .unauthorized = mmError {
                // The session is gone; `AuthCoordinator` owns that transition. Leaving the rail in
                // its previous state is honest — the shell is about to show re-auth.
                return
            }
            phase = .failed(Self.message(for: error))
            rebuild()
        }
    }

    private func rebuild() {
        entries = TeamSidebarDerivation.entries(from: data,
                                                userID: userID(),
                                                selectedTeamID: selectedTeamID,
                                                selectedTeamName: selectedTeamName)
    }

    /// Error copy for the rail. A transport failure gets the app's existing wording
    /// (`MMError.errorDescription`); anything else gets a sentence a person can act on.
    static func message(for error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        return "Could not load your teams."
    }
}
