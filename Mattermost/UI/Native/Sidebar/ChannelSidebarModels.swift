// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/utils/categories.ts (`makeCategoryChannelId`, `isUnreadChannel`, `sortChannels`,
//        `sortChannelsByName`, `getUnreadIds`), app/utils/channel/index.ts (`isDMorGM`,
//        `sortChannelsByDisplayName`, `getUserIdFromChannelName`, `isChannelVisible` rules),
//        app/screens/home/channel_list/categories_list/ (the drawn shape: one section per category,
//        favorites first, unread emphasis on the row label, mention badge on the right),
//        app/components/channel_item/channel_item.tsx + channel_body.tsx (icon per channel type,
//        bold label while unread, `#`/lock/person glyphs), app/components/channel_icon/ (the glyph
//        inventory), app/screens/find_channels/* (the quick switcher), and
//        app/client/rest/categories.ts + channels.ts + users.ts for the endpoint shapes.
// Web cross-check (behaviour only): `webapp/channels/src/packages/mattermost-redux/src/utils/
// channel_utils.ts` `calculateUnreadCount` (bold = mentions > 0 || (!muted && messages > 0)),
// `selectors/entities/channels.ts` `getUnreadStatus` ("muted channel will not be counted towards
// unreads"), and `components/sidebar/` for the row shape.
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §3; no
// upstream source copied. The Swift value types and the pure `ChannelSidebarDerivation` split are
// this repo's own (docs/component-map.md §1).

import Foundation

// MARK: - Channel kinds

/// The four channel types Mattermost's sidebar draws differently.
///
/// The raw values are the **server's** single-letter `channel.type` (`O` public, `P` private,
/// `D` direct, `G` group). Anything else (a plugin channel type, a newer server) decodes to `nil`
/// and the channel is drawn as an ordinary public-looking row rather than dropped: a channel you are
/// a member of must never vanish from the list because this build does not know its type.
enum SidebarChannelKind: String, Equatable, Sendable {
    case publicChannel = "O"
    case privateChannel = "P"
    case directMessage = "D"
    case groupMessage = "G"

    init?(channelType: String) {
        self.init(rawValue: channelType.uppercased())
    }

    /// DMs and GMs are the two kinds whose display name comes from *people*, not from the channel.
    var isDirect: Bool { self == .directMessage || self == .groupMessage }

    /// The glyph upstream draws (`channel_icon`): `#` for public, a lock for private, a person for a
    /// DM and a two-person glyph for a GM. SF Symbols stand in for compass-icons (MIT; see §3 of the
    /// notices) exactly as T32's team rail does.
    var symbolName: String {
        switch self {
        case .publicChannel: return "number"
        case .privateChannel: return "lock"
        case .directMessage: return "person.crop.circle"
        case .groupMessage: return "person.2"
        }
    }

    var accessibilityName: String {
        switch self {
        case .publicChannel: return "public channel"
        case .privateChannel: return "private channel"
        case .directMessage: return "direct message"
        case .groupMessage: return "group message"
        }
    }
}

/// The four category types the server stores (`sidebar_categories.type`).
enum SidebarCategoryKind: String, Equatable, Sendable {
    case favorites
    case custom
    case channels
    case directMessages = "direct_messages"

    /// The three categories every team starts with. Their ids are server-generated
    /// (`channels_<user>_<team>`), so the *type* is what identifies them for a UI test.
    var isDefault: Bool { self != .custom }

    var defaultDisplayName: String {
        switch self {
        case .favorites: return "Favorites"
        case .custom: return "Channels"
        case .channels: return "Channels"
        case .directMessages: return "Direct Messages"
        }
    }

    /// Which default category a channel belongs to when no category claims it.
    var fallbackForUnlistedChannels: SidebarCategoryKind? {
        switch self {
        case .channels: return .channels
        case .directMessages: return .directMessages
        case .favorites, .custom: return nil
        }
    }
}

extension MMSidebarCategory {
    var kind: SidebarCategoryKind { SidebarCategoryKind(rawValue: type) ?? .custom }

    /// A stable handle for a UI test and VoiceOver. Default categories are addressed by type (their
    /// ids embed the user and team, which is noise in a test predicate); a custom one by its id.
    var sidebarIdentifier: String {
        kind.isDefault
            ? "channelSidebar.category.\(kind.rawValue)"
            : "channelSidebar.category.custom.\(id)"
    }
}

// MARK: - One drawn row

/// One channel as the sidebar draws it: everything the row renders, derived once.
///
/// A value type on purpose (component-map §1): SwiftUI diffs it, so "the bold state did not change"
/// is a real comparison, and the unread/bold/mention rules are testable without a view.
struct ChannelSidebarEntry: Identifiable, Equatable, Sendable {
    let id: String
    /// The channel's URL name (`ops-standup`, or `id__id` for a DM, an opaque hash for a GM).
    let name: String
    /// What the row shows. For a DM/GM this is the resolved person/people, not the channel name.
    let displayName: String
    let kind: SidebarChannelKind
    /// Unread **messages** for this user (`channel.total_msg_count − member.msg_count`).
    let unreadCount: Int
    let mentionCount: Int
    /// `member.notify_props.mark_unread == "mention"` — upstream's whole definition of "muted".
    let isMuted: Bool
    /// "Keep as unread" (`member.manually_unread`).
    let manuallyUnread: Bool
    let isFavorite: Bool
    let isSelected: Bool
    let lastPostAt: Int64
    let createdAt: Int64
    /// Extra names the quick switcher matches on (a DM's username/nickname/full name, a GM's
    /// members). The display name and the channel name are matched as well, always.
    let searchTerms: [String]

    /// Whether the row is **bold** (the sidebar's unread emphasis).
    ///
    /// Upstream's rule, from both clients: a mention always emphasises; unread messages emphasise
    /// only when the channel is not muted; "keep as unread" counts as unread. So a **muted channel
    /// shows no bold and no dot for ordinary traffic** — which is the whole point of muting — while
    /// an explicit mention still surfaces (that is exactly what `mark_unread = "mention"` means; the
    /// web app's `calculateUnreadCount` and mobile's `isUnreadChannel` agree, and matching the
    /// browser beside it is the acceptance criterion).
    var showsUnreadEmphasis: Bool {
        ChannelSidebarDerivation.showsUnread(mentionCount: mentionCount,
                                             unreadCount: unreadCount,
                                             isMuted: isMuted,
                                             manuallyUnread: manuallyUnread)
    }

    /// The right-hand badge: mention count beats a bare unread dot; a muted channel draws no dot.
    var badge: ChannelSidebarBadge {
        ChannelSidebarDerivation.badge(mentionCount: mentionCount,
                                       unreadCount: unreadCount,
                                       isMuted: isMuted,
                                       manuallyUnread: manuallyUnread)
    }

    var badgeText: String? { badge.text }

    var iconSymbolName: String { kind.symbolName }

    /// What VoiceOver reads after the channel name. The badge pill itself is decorative (its digits
    /// alone would read as a bare number).
    var accessibilityValue: String {
        var parts: [String] = []
        if isSelected { parts.append("Selected") }
        if isMuted { parts.append("Muted") }
        if mentionCount > 0 {
            parts.append(mentionCount == 1 ? "1 mention" : "\(mentionCount > 99 ? "more than 99" : String(mentionCount)) mentions")
        } else if manuallyUnread && unreadCount == 0 {
            parts.append("Kept unread")
        } else if showsUnreadEmphasis {
            parts.append("Unread")
        }
        if isFavorite { parts.append("Favorite") }
        return parts.joined(separator: ", ")
    }
}

/// The badge a channel row draws (mobile `channel_item`): a count, an unread dot, or nothing.
enum ChannelSidebarBadge: Equatable, Sendable {
    case none
    case dot
    case count(Int)

    var text: String? {
        switch self {
        case .none, .dot: return nil
        case .count(let value): return value > 99 ? "99+" : String(value)
        }
    }

    var isDot: Bool { self == .dot }
}

/// One drawn section: a category and the rows in it, in draw order.
struct ChannelSidebarGroup: Identifiable, Equatable, Sendable {
    let category: MMSidebarCategory
    var entries: [ChannelSidebarEntry]

    var id: String { category.id }
    var kind: SidebarCategoryKind { category.kind }
    var identifier: String { category.sidebarIdentifier }
    var displayName: String {
        category.displayName.isEmpty ? category.kind.defaultDisplayName : category.displayName
    }
}

/// The aggregate the sidebar shows at its foot, and the numbers the app badge should use.
///
/// Desktop/web explicitly exclude muted channels from the unread status
/// (`getUnreadStatus`: "muted channel will not be counted towards unreads"), which is what makes
/// "mute it and the badge total drops" true. The same exclusion applies to mentions there.
struct ChannelSidebarTotals: Equatable, Sendable {
    var messages = 0
    var mentions = 0
    var unreadChannels = 0

    var isEmpty: Bool { messages == 0 && mentions == 0 }

    /// One sentence for VoiceOver / a UI test, or `nil` when there is nothing to say.
    var accessibilityLabel: String? {
        guard !isEmpty else { return nil }
        var parts: [String] = []
        if mentions > 0 {
            parts.append(mentions == 1 ? "1 mention" : "\(mentions) mentions")
        }
        if messages > 0 {
            parts.append(messages == 1 ? "1 unread message" : "\(messages) unread messages")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - One load of the sidebar

/// Everything one load of the channel sidebar needs, straight off the wire.
struct ChannelSidebarData: Equatable, Sendable {
    /// `GET /users/me/teams/{team_id}/channels` for the selected team.
    var channels: [MMChannel] = []
    /// `GET /users/me/channel_members` (filtered to `channels` by the derivation).
    var members: [MMChannelMember] = []
    /// `GET /users/{uid}/teams/{tid}/channels/categories`.
    var categories: [MMSidebarCategory] = []
    var categoryOrder: [String] = []
    /// channel id → the label a DM/GM row shows (the other people's names).
    var directLabels: [String: String] = [:]
    /// channel id → extra names to match in the quick switcher (usernames, nicknames, full names).
    var searchTerms: [String: [String]] = [:]
    /// `GET /users/{uid}/preferences` — read only for the **legacy** favourite preference, used when
    /// a server has no categories endpoint (or the call failed).
    var preferences: [MMPreference] = []
    /// The categories call failed: the sidebar is drawn from the channels themselves with the two
    /// default categories (see `ChannelSidebarDerivation.defaultCategories`), and the model says the
    /// grouping may not be the user's.
    var categoriesFailed = false
    /// The members call failed: unread counters are unknown, so the rows do not claim any.
    var membersFailed = false

    func member(for channelID: String) -> MMChannelMember? {
        members.first { $0.channelId == channelID }
    }

    /// Replace the two endpoints that change on socket activity, keeping the category layout and the
    /// resolved DM/GM labels (which do not).
    ///
    /// Returns whether the membership rows could be trusted. A **non-empty** channels answer with an
    /// **empty** membership answer is not "everything is read": it is the shape a swallowed
    /// `/users/me/channel_members` failure takes (T33-AV F5), and treating it as authoritative zeroes
    /// every badge while claiming freshness. In that case the previous rows stay and `membersFailed`
    /// is set, so the caller draws the stale marker instead of a wrong number.
    @discardableResult
    mutating func replaceCounters(channels: [MMChannel],
                                  members: [MMChannelMember],
                                  membersFailed: Bool = false) -> Bool {
        self.channels = channels
        if membersFailed || (members.isEmpty && !channels.isEmpty && !self.members.isEmpty) {
            self.membersFailed = true
            return false
        }
        self.members = members
        self.membersFailed = false
        return true
    }
}

/// A cheap refresh: the two counter-bearing endpoints only.
struct ChannelSidebarRefresh: Equatable, Sendable {
    var channels: [MMChannel]
    var members: [MMChannelMember]
    /// The membership call failed (a non-401 error): `members` is empty and **not** authoritative.
    var membersFailed = false
}

// MARK: - The rules

/// Every decode/derive/format rule the channel sidebar has, as pure functions.
///
/// Keeping them here (rather than in the view model) is what lets the card's acceptance criteria be
/// unit-tested without a network, a vault, a socket or a `NativeNavigation`.
enum ChannelSidebarDerivation {

    /// How a muted channel is spelled in `notify_props.mark_unread` (upstream `General.MENTION`),
    /// and what unmuting restores (`General.ALL`).
    static let mutedMarkUnread = "mention"
    static let unmutedMarkUnread = "all"

    // MARK: Membership + counters

    static func kind(of channel: MMChannel) -> SidebarChannelKind? {
        SidebarChannelKind(channelType: channel.type)
    }

    /// Upstream's entire definition of a muted channel (`isChannelMuted`):
    /// `notify_props.mark_unread === "mention"`.
    static func isMuted(_ member: MMChannelMember?) -> Bool {
        guard let props = member?.notifyProps else { return false }
        return props["mark_unread"]?.stringValue == mutedMarkUnread
    }

    /// The notify-props value that mutes (`mention`) or unmutes (`all`) a channel.
    static func markUnread(forMuted muted: Bool) -> String {
        muted ? mutedMarkUnread : unmutedMarkUnread
    }

    /// Unread **messages**: the channel's total post count minus what this user has seen.
    /// Never negative (a `channel_viewed` can land after a refresh), which is why this is not a
    /// plain subtraction at the call site.
    static func unreadMessages(channel: MMChannel, member: MMChannelMember?) -> Int {
        guard let member else { return 0 }
        let delta = channel.totalMsgCount - member.msgCount
        return delta > 0 ? Int(delta) : 0
    }

    /// The bold rule (see `ChannelSidebarEntry.showsUnreadEmphasis`).
    static func showsUnread(mentionCount: Int,
                            unreadCount: Int,
                            isMuted: Bool,
                            manuallyUnread: Bool) -> Bool {
        if mentionCount > 0 { return true }
        guard !isMuted else { return false }
        return unreadCount > 0 || manuallyUnread
    }

    /// The badge rule. Mentions beat a dot; a muted channel has no message-unread state at all
    /// (`showsUnread` above already folded the mute in), so it draws nothing unless mentioned.
    static func badge(mentionCount: Int,
                      unreadCount: Int,
                      isMuted: Bool,
                      manuallyUnread: Bool) -> ChannelSidebarBadge {
        if mentionCount > 0 { return .count(mentionCount) }
        if showsUnread(mentionCount: mentionCount,
                       unreadCount: unreadCount,
                       isMuted: isMuted,
                       manuallyUnread: manuallyUnread) {
            return .dot
        }
        return .none
    }

    // MARK: Favourites

    /// The favourite channel ids for this team.
    ///
    /// The v9+ server stores them as the `channel_ids` of the `favorites` category. Older servers (and
    /// any server whose categories call failed) store one `favorite_channel` preference per channel
    /// with the channel id as its *name* and `"true"` as its value — that is the fallback, applied
    /// only when no favourites category exists, so a stale preference cannot re-favourite something
    /// the user removed through the categories API.
    static func favoriteIDs(from data: ChannelSidebarData) -> Set<String> {
        if let favorites = data.categories.first(where: { $0.kind == .favorites }) {
            return Set(favorites.channelIds)
        }
        var ids = Set<String>()
        for preference in data.preferences
        where preference.category == "favorite_channel" && preference.value == "true" {
            ids.insert(preference.name)
        }
        return ids
    }

    // MARK: Entries

    /// Project every channel of the team into a row.
    ///
    /// Ordering is *not* decided here (a category decides it); this is the unordered set of rows,
    /// with selection, mute, favourites and counters resolved.
    static func entries(from data: ChannelSidebarData,
                        selectedChannelID: String?,
                        selectedChannelName: String?) -> [ChannelSidebarEntry] {
        let favorites = favoriteIDs(from: data)
        let membersByChannel = Dictionary(data.members.map { ($0.channelId, $0) },
                                          uniquingKeysWith: { first, _ in first })
        return data.channels.compactMap { channel in
            // A channel type this build does not know (a plugin channel) is drawn as an ordinary
            // named channel rather than dropped: being a member of it is what puts it in the list.
            let kind = kind(of: channel) ?? .publicChannel
            // Archived channels are hidden, except the one on screen (upstream
            // `filterArchivedChannels`: hiding the conversation you are reading is worse than
            // showing it with its archive badge).
            let isSelected = selected(channel,
                                      channelID: selectedChannelID,
                                      channelName: selectedChannelName)
            guard channel.deleteAt == 0 || isSelected else { return nil }

            let member = membersByChannel[channel.id]
            let label = displayName(channel: channel, kind: kind, data: data)
            return ChannelSidebarEntry(
                id: channel.id,
                name: channel.name,
                displayName: label,
                kind: kind,
                unreadCount: unreadMessages(channel: channel, member: member),
                mentionCount: Int(member?.mentionCount ?? 0),
                isMuted: isMuted(member),
                manuallyUnread: member?.manuallyUnread ?? false,
                isFavorite: favorites.contains(channel.id),
                isSelected: isSelected,
                lastPostAt: channel.lastPostAt,
                createdAt: channel.createAt,
                searchTerms: searchTerms(channel: channel, kind: kind, label: label, data: data)
            )
        }
    }

    /// The label a row shows. A named channel uses its display name (falling back to its URL name);
    /// a DM/GM uses the people, which the service resolved (`directLabels`), and only then the
    /// server's own `display_name`. Never an `id__id` string: that is a database key, not a name.
    static func displayName(channel: MMChannel,
                            kind: SidebarChannelKind,
                            data: ChannelSidebarData) -> String {
        if kind.isDirect {
            if let label = data.directLabels[channel.id], !label.isEmpty { return label }
            if !channel.displayName.isEmpty { return channel.displayName }
            return kind == .directMessage ? "Direct message" : "Group message"
        }
        if !channel.displayName.isEmpty { return channel.displayName }
        return channel.name
    }

    static func searchTerms(channel: MMChannel,
                            kind: SidebarChannelKind,
                            label: String,
                            data: ChannelSidebarData) -> [String] {
        var terms = Set<String>()
        terms.insert(label)
        if !channel.name.isEmpty { terms.insert(channel.name) }
        if !channel.displayName.isEmpty { terms.insert(channel.displayName) }
        for term in data.searchTerms[channel.id] ?? [] where !term.isEmpty { terms.insert(term) }
        return terms.sorted()
    }

    static func selected(_ channel: MMChannel,
                         channelID: String?,
                         channelName: String?) -> Bool {
        if let channelID, !channelID.isEmpty { return channel.id == channelID }
        if let channelName, !channelName.isEmpty { return channel.name == channelName }
        return false
    }

    // MARK: Grouping

    /// Group the rows into the server's categories, in the server's order.
    ///
    /// The rules, all upstream (`app/utils/categories.ts` + `categories_list`):
    /// 1. The `order` array decides the drawn order; categories missing from it are appended by
    ///    `sort_order` and then id (a server that answers a partial order must not hide a
    ///    category).
    /// 2. A category owns exactly the channels in its `channel_ids`, in its own sorting.
    /// 3. A channel **no** category claims (a channel joined after the category list was written, or
    ///    a server whose categories call failed) is appended to the default category for its type —
    ///    the `channels` category for a public/private channel, `direct_messages` for a DM/GM. It is
    ///    never dropped: you are a member of it, so it belongs in your sidebar.
    /// 4. An empty favourites/custom category is not drawn (nothing to show and no drop target on a
    ///    touch screen); an empty default category is not drawn either.
    static func groups(from data: ChannelSidebarData,
                       selectedChannelID: String?,
                       selectedChannelName: String?) -> [ChannelSidebarGroup] {
        let entries = entries(from: data,
                              selectedChannelID: selectedChannelID,
                              selectedChannelName: selectedChannelName)
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var categories = ordered(data.categories, order: data.categoryOrder)

        // Claimed channels, and the leftovers per default category.
        var claimed = Set<String>()
        var leftovers: [SidebarCategoryKind: [ChannelSidebarEntry]] = [:]
        for category in categories {
            for id in category.channelIds { claimed.insert(id) }
        }
        for entry in entries where !claimed.contains(entry.id) {
            let target: SidebarCategoryKind = entry.kind.isDirect ? .directMessages : .channels
            leftovers[target, default: []].append(entry)
        }

        if categories.isEmpty {
            // No categories at all (an old server, or the call failed): synthesise the two defaults
            // so the list is still grouped the way a Mattermost sidebar is.
            categories = defaultCategories(userID: data.categories.first?.userId ?? "",
                                           teamID: data.categories.first?.teamId ?? "")
            claimed = []
            leftovers = [.channels: entries.filter { !$0.kind.isDirect },
                         .directMessages: entries.filter { $0.kind.isDirect }]
        }

        var groups: [ChannelSidebarGroup] = []
        // The server keeps a channel in one category; a stale or hand-written layout can list one
        // twice, and drawing it in two places would duplicate a row (and make a reorder ambiguous).
        // The first category in draw order wins.
        var drawn: Set<String> = []
        for category in categories {
            let listed = category.channelIds.compactMap { byID[$0] }.filter { !drawn.contains($0.id) }
            var rows = sorted(listed, category: category)
            let extra = (leftovers[category.kind] ?? []).filter { !drawn.contains($0.id) }
            if !extra.isEmpty {
                rows += sorted(extra, category: category)
            }
            guard !rows.isEmpty else { continue }
            drawn.formUnion(rows.map(\.id))
            groups.append(ChannelSidebarGroup(category: category, entries: rows))
        }

        // A leftover whose default category is missing entirely (a server with a `channels`-less
        // category list, e.g. every channel moved into custom categories): draw it rather than lose
        // it.
        let orphans = entries.filter { !drawn.contains($0.id) }
        if !orphans.isEmpty {
            let kind: SidebarCategoryKind = orphans.contains(where: { !$0.kind.isDirect }) ? .channels : .directMessages
            let category = defaultCategory(kind, userID: "", teamID: "")
            groups.append(ChannelSidebarGroup(category: category,
                                              entries: sorted(orphans, category: category)))
        }
        return groups
    }

    /// The drawn order to use after the server answered a categories **write**.
    ///
    /// The write's answer is a bare array (the GET's `order` array is not in it), and its order is
    /// the request's — which is `data.categories`, and a category the order array omitted is drawn by
    /// `sort_order` instead, so the two are not necessarily the same. So: keep the order the sidebar
    /// already had for every category that still exists, then append a category the answer introduced
    /// (a `favorites` category created by a first favourite) in the server's own position. Drawn
    /// categories therefore never jump because of a channel move — only a category the server newly
    /// created is new to the order.
    static func order(afterSaved saved: [MMSidebarCategory], previous: [String]) -> [String] {
        let ids = Set(saved.map(\.id))
        var order = previous.filter { ids.contains($0) }
        var seen = Set(order)
        for category in saved where !seen.contains(category.id) {
            order.append(category.id)
            seen.insert(category.id)
        }
        return order
    }

    /// `order` first, then anything it omitted by `sort_order`, then id.
    static func ordered(_ categories: [MMSidebarCategory], order: [String]) -> [MMSidebarCategory] {
        var positions: [String: Int] = [:]
        for (index, id) in order.enumerated() where positions[id] == nil {
            positions[id] = index
        }
        let listed = categories
            .filter { positions[$0.id] != nil }
            .sorted { (positions[$0.id] ?? 0) < (positions[$1.id] ?? 0) }
        let rest = categories
            .filter { positions[$0.id] == nil }
            .sorted { lhs, rhs in
                if lhs.sortOrder == rhs.sortOrder { return lhs.id < rhs.id }
                return lhs.sortOrder < rhs.sortOrder
            }
        return listed + rest
    }

    /// The two default categories a team starts with, for a server that did not answer with any.
    static func defaultCategories(userID: String, teamID: String) -> [MMSidebarCategory] {
        [
            defaultCategory(.favorites, userID: userID, teamID: teamID),
            defaultCategory(.channels, userID: userID, teamID: teamID),
            defaultCategory(.directMessages, userID: userID, teamID: teamID),
        ]
    }

    static func defaultCategory(_ kind: SidebarCategoryKind,
                                userID: String,
                                teamID: String) -> MMSidebarCategory {
        // The ids mirror the server's own scheme (`<type>_<user>_<team>`); a synthesised id keeps
        // that shape so a later write round-trips, and stays stable across launches.
        MMSidebarCategory(id: "\(kind.rawValue)_\(userID)_\(teamID)",
                          userId: userID,
                          teamId: teamID,
                          sortOrder: kind == .favorites ? 0 : (kind == .channels ? 10 : 20),
                          sorting: kind == .directMessages ? "recent" : "",
                          type: kind.rawValue,
                          displayName: kind.defaultDisplayName)
    }

    /// Sort one category's rows the way upstream's `sortChannels` does:
    ///  - `manual` — the category's `channel_ids` order (the position is the manual sort key);
    ///  - `recent` — most recent activity first, `max(lastPostAt, createAt)` so a channel that has
    ///    never been posted in still sorts by when it was created;
    ///  - anything else (`alpha`, or the server's empty default) — muted channels last, then
    ///    `localizedStandardCompare` on the display name, with the id as the final tiebreak so two
    ///    identically named channels cannot swap places between renders.
    static func sorted(_ entries: [ChannelSidebarEntry],
                       category: MMSidebarCategory) -> [ChannelSidebarEntry] {
        switch category.sorting.lowercased() {
        case "manual":
            var positions: [String: Int] = [:]
            for (index, id) in category.channelIds.enumerated() where positions[id] == nil {
                positions[id] = index
            }
            let unpositioned = entries
                .filter { positions[$0.id] == nil }
                .sorted(by: alphabetical)
            return entries
                .filter { positions[$0.id] != nil }
                .sorted { (positions[$0.id] ?? 0) < (positions[$1.id] ?? 0) } + unpositioned
        case "recent":
            return entries.sorted { lhs, rhs in
                let left = max(lhs.lastPostAt, lhs.createdAt)
                let right = max(rhs.lastPostAt, rhs.createdAt)
                if left == right { return alphabetical(lhs, rhs) }
                return left > right
            }
        default:
            return entries.sorted { lhs, rhs in
                // Muted channels last (upstream `sortChannelsByName`).
                if lhs.isMuted != rhs.isMuted { return !lhs.isMuted }
                return alphabetical(lhs, rhs)
            }
        }
    }

    /// Alphabetical by display name, case-insensitively and number-aware (`ops-2` before `ops-10`),
    /// with the id breaking ties.
    static func alphabetical(_ lhs: ChannelSidebarEntry, _ rhs: ChannelSidebarEntry) -> Bool {
        let left = lhs.displayName
        let right = rhs.displayName
        if left == right { return lhs.id < rhs.id }
        return left.localizedStandardCompare(right) == .orderedAscending
    }

    // MARK: Totals

    /// The sidebar's aggregate, **desktop-exact**: a muted channel contributes nothing at all —
    /// neither its messages nor its mentions.
    ///
    /// Web/desktop skip a muted channel before either count is added
    /// (`selectors/entities/channels.ts` `getTeamsUnreadStatuses`: "if channel is muted, we skip its
    /// count"). The row still shows an explicit mention (that is exactly what `mark_unread: mention`
    /// keeps), but the footer's badge total does not — criterion 3 says the totals exclude muted
    /// channels "the same way desktop does", and T33-AV F2 measured the previous rule against that
    /// criterion and lost.
    ///
    /// The consequence is recorded in `docs/parity.md`: the T32 rail above this footer badges the
    /// server's `teams/unread`, which is **not** mute-aware, so a muted mention can make the rail and
    /// the footer disagree for one moment. They are two different read-outs (the server's team total
    /// vs. this client's badge total, computed like desktop's) and this footer deliberately follows
    /// desktop rather than the rail.
    static func totals(_ groups: [ChannelSidebarGroup]) -> ChannelSidebarTotals {
        var totals = ChannelSidebarTotals()
        for entry in groups.flatMap(\.entries) {
            guard !entry.isMuted else { continue }
            totals.messages += entry.unreadCount
            totals.mentions += entry.mentionCount
            if entry.showsUnreadEmphasis { totals.unreadChannels += 1 }
        }
        return totals
    }

    // MARK: Quick switcher

    /// Fuzzy-match channels and DMs.
    ///
    /// The ranking is deliberately a *scoring* function rather than a filter, because a quick
    /// switcher's job is order as much as membership: exact name, then prefix, then a word-start,
    /// then a substring, then a subsequence (`stdp` finds `standup`). Ties break on unread first, then
    /// alphabetically, so "the channel I am looking for" is at the top even when several match.
    static func search(_ query: String, in entries: [ChannelSidebarEntry]) -> [ChannelSidebarEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries.sorted(by: alphabetical) }
        return entries
            .compactMap { entry -> (ChannelSidebarEntry, Int)? in
                guard let score = matchScore(query: trimmed, entry: entry) else { return nil }
                return (entry, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                if lhs.0.showsUnreadEmphasis != rhs.0.showsUnreadEmphasis {
                    return lhs.0.showsUnreadEmphasis
                }
                return alphabetical(lhs.0, rhs.0)
            }
            .map(\.0)
    }

    /// The best score of `query` against any of an entry's names, or `nil` when it matches none.
    static func matchScore(query: String, entry: ChannelSidebarEntry) -> Int? {
        var candidates = entry.searchTerms
        candidates.append(entry.displayName)
        candidates.append(entry.name)
        return candidates.compactMap { score(query: query, candidate: $0) }.max()
    }

    /// How well `query` matches one string. Higher is better; `nil` is "no match".
    ///
    /// Every tier strips a leading `#`/`@` from the query so `#standup` and `@ada` behave the way a
    /// person types them.
    static func score(query: String, candidate: String) -> Int? {
        var needle = query.lowercased()
        if needle.hasPrefix("#") || needle.hasPrefix("@") { needle.removeFirst() }
        guard !needle.isEmpty else { return nil }
        let haystack = candidate.lowercased()
        guard !haystack.isEmpty else { return nil }

        if haystack == needle { return 1000 }
        if haystack.hasPrefix(needle) { return 900 - haystack.count }
        // A word start: "stand" should beat "understand".
        let words = haystack.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" || $0 == "." })
        if words.contains(where: { $0.hasPrefix(needle) }) { return 800 - haystack.count }
        if let range = haystack.range(of: needle) {
            let offset = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
            return 600 - offset * 5 - haystack.count
        }
        // Subsequence: every character of the needle appears in order. Penalise the gaps.
        var gaps = 0
        var lastIndex: String.Index?
        var searchStart = haystack.startIndex
        for character in needle {
            guard let found = haystack[searchStart...].firstIndex(of: character) else { return nil }
            if let last = lastIndex {
                gaps += haystack.distance(from: haystack.index(after: last), to: found)
            }
            lastIndex = found
            searchStart = haystack.index(after: found)
        }
        return 400 - gaps * 3 - haystack.count
    }
}
