// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: `app/actions/local/team.ts` (`addSearchToTeamSearchHistory`, `MAX_TEAM_SEARCHES = 15`,
//        newest first, trimmed to the newest fifteen), `app/screens/home/search/initial/recent_searches/`
//        (the list the reader taps to re-run a search).
// Licence: Apache-2.0 — behaviour reimplemented; no upstream source copied.
// Attribution: docs/THIRD_PARTY_NOTICES.md §16.
//
// Upstream keeps search history **on the device**, per team, in its local database; there is no
// server-side search-history API (`GET /users/me/preferences` carries no such category, and the
// workspace-wide history the web app shows is derived from the channels, not from a search log).
// The equivalent here is `UserDefaults`, keyed by server id **and** team id so two teams — or two
// accounts on one server — never see each other's history.
//
// The list rules (dedupe, ordering, cap) are pure and live in `RecentSearches`; the store only moves
// strings in and out, which is what lets the unit suite pin the rules without a defaults domain.

import Foundation

/// The recent-search list, as a value.
struct RecentSearches: Equatable, Sendable {
    /// Most recent first.
    private(set) var entries: [String] = []
    /// Upstream's `MAX_TEAM_SEARCHES`.
    static let limit = 15

    init(entries: [String] = []) {
        self.entries = Self.trimmed(entries)
    }

    /// Record a submitted query at the front, dropping an earlier copy of it.
    ///
    /// The comparison is case-insensitive and whitespace-trimmed: "Deploy" and "deploy " are the same
    /// search to a reader, and keeping both makes the list useless. The *stored* text is the newest
    /// spelling, so tapping the row re-runs what the reader last typed.
    mutating func record(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var next = entries.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        next.insert(trimmed, at: 0)
        entries = Self.trimmed(next)
    }

    mutating func remove(_ query: String) {
        entries.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
    }

    mutating func removeAll() {
        entries = []
    }

    /// At most `limit` entries, and never an empty or duplicated one.
    static func trimmed(_ entries: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for entry in entries {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed.lowercased()).inserted else { continue }
            out.append(trimmed)
            if out.count >= limit { break }
        }
        return out
    }
}

/// Where the list lives between launches.
protocol RecentSearchStoring: AnyObject {
    func load(key: String) -> [String]
    func save(_ entries: [String], key: String)
}

/// The shipping store: one `UserDefaults` array per (server, team).
///
/// Not the Keychain: a search string is not a credential, and putting it in the vault would make the
/// vault's contents depend on what the reader typed. Not the network either — there is nothing to
/// sync it to (see the file comment).
final class UserDefaultsRecentSearchStore: RecentSearchStoring {
    private let defaults: UserDefaults
    private let prefix: String

    init(defaults: UserDefaults = .standard, prefix: String = "mm.recentSearches") {
        self.defaults = defaults
        self.prefix = prefix
    }

    /// `serverID` + `teamID`: a team's history is the team's.
    static func key(serverID: UUID, teamID: String) -> String {
        "\(serverID.uuidString).\(teamID)"
    }

    func load(key: String) -> [String] {
        defaults.stringArray(forKey: "\(prefix).\(key)") ?? []
    }

    func save(_ entries: [String], key: String) {
        defaults.set(entries, forKey: "\(prefix).\(key)")
    }
}

/// The in-memory list plus its store: what the screen reads and what a submit writes.
@MainActor
final class RecentSearchesStore: ObservableObject {
    @Published private(set) var searches: RecentSearches

    private let store: RecentSearchStoring
    private let key: String

    init(store: RecentSearchStoring, key: String) {
        self.store = store
        self.key = key
        self.searches = RecentSearches(entries: store.load(key: key))
    }

    var entries: [String] { searches.entries }

    func record(_ query: String) {
        var next = searches
        next.record(query)
        guard next != searches else { return }
        searches = next
        store.save(next.entries, key: key)
    }

    func remove(_ query: String) {
        var next = searches
        next.remove(query)
        searches = next
        store.save(next.entries, key: key)
    }

    func removeAll() {
        searches.removeAll()
        store.save([], key: key)
    }
}
