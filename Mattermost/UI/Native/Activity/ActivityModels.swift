// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: `app/screens/home/recent_mentions/recent_mentions.tsx` (the list, refreshed on focus),
//        `app/actions/remote/search.ts` `fetchRecentMentions` (the request: mention keys as search
//        terms, `is_or_search: true`, no team id → `POST /posts/search`), `app/database/models/server/
//        user.ts` (`mentionKeys` / `userMentionKeys`: `notify_props.mention_keys`, first name when
//        `notify_props.first_name === 'true'`, `@channel`/`@all`/`@here` when `notify_props.channel`,
//        then `@username`; the search terms drop the three special keys),
//        `app/utils/post/index.ts` (mention-key matching / `hasSpecialMentions`),
//        `app/components/post_with_channel_info/` (a mention row = the channel it came from, then the
//        post as the timeline draws it).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §19; no
// upstream source copied. The type decomposition is this repo's own (docs/component-map.md §1).
//
// Measured on the pinned 9.11.19 server (`scripts/t42_activity_probe.py`, transcript in
// `docs/t42-activity-probe-2026-10-27.log`) — every shape below is a statement about what this server
// actually answers, not about a type definition:
//
//  - `GET /users/me/mentions` **404s** (`api.context.404.app_error`), the path T14 recorded as absent.
//    So does `/users/me/teams/{team}/threads/mention_counts`.
//  - The mentions read is the search the official client uses: `POST /posts/search` (cross-team; the
//    team-scoped `POST /teams/{team}/posts/search` only covers one team) with the mention keys as
//    `terms` and `is_or_search: true`. It answers the **same 26-character post shape** as any other
//    read in this app, newest first, and it includes thread replies (`root_id != ""`).
//  - The search answer carries **no `props.mentions`** on this server (`"props": {}` on every row,
//    including a post that provably incremented the mention counter). Mention *detection* for live
//    socket events therefore cannot rely on that prop here, which is why `MentionKeys.matches` is a
//    text match over the reader's own keys — the same thing upstream's search terms ask the server
//    for. `props.mentions` is still honoured first when a server does send it.
//  - Paging: `page > 0` answers an empty `order` on the database backend (`ActiveSearchBackend:
//    database`), so the feed is one window and says so; `per_page` is not honoured either.
//  - Read state is per **channel cursor**: `last_viewed_at` from /users/me/teams/{team}/channels/
//    members (or /channels/{id}/members/{me} for a channel outside any team list). A root mention is
//    unread while `create_at > last_viewed_at`. A thread mention is read by the **thread** cursor
//    (`thread_read_changed` / `PUT …/threads/{id}/read/{ts}`), which the channel cursor does not move
//    under collapsed threads (`always_on` on the pinned server) — so replies use the thread list's
//    own `unread_mentions` when the thread is known.
//  - Marking read: there is **no** "read up to this post" endpoint (checked against the server's own
//    route table for 9.11: `api4/channel.go` has `viewChannel`, `readMultipleChannels` and the thread
//    read route, nothing finer). So a root row's action is `POST /channels/members/{me}/mark_read`,
//    which is literally "this channel is read", and a reply row's is the thread read — the two are
//    labelled for what they do rather than sharing one misleading "mark as read".

import Foundation

// MARK: - Wire shapes

/// `GET /users/me` — only what mention-key derivation needs.
///
/// Deliberately *not* `MMUser`: the keys live in `notify_props`, which the shared user decode does not
/// carry, and widening that decode for one screen would change every existing caller.
struct ActivityProfile: Codable, Equatable, Sendable {
    var id: String
    var username: String
    var firstName: String
    var lastName: String
    /// `notify_props` as the server sends it: `mention_keys`, `first_name` ("true"/"false"),
    /// `channel` ("true"/"false"). Kept as raw JSON so an absent prop is distinguishable from "".
    var notifyProps: JSONValue?

    enum CodingKeys: String, CodingKey {
        case id, username
        case firstName = "first_name"
        case lastName = "last_name"
        case notifyProps = "notify_props"
    }

    init(id: String = "", username: String = "", firstName: String = "", lastName: String = "",
         notifyProps: JSONValue? = nil) {
        self.id = id
        self.username = username
        self.firstName = firstName
        self.lastName = lastName
        self.notifyProps = notifyProps
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? ""
        username = try values.decodeIfPresent(String.self, forKey: .username) ?? ""
        firstName = try values.decodeIfPresent(String.self, forKey: .firstName) ?? ""
        lastName = try values.decodeIfPresent(String.self, forKey: .lastName) ?? ""
        notifyProps = try values.decodeIfPresent(JSONValue.self, forKey: .notifyProps)
    }
}

/// The answer to `POST /channels/members/{user_id}/mark_read` (and `POST …/view`): the server's own
/// `last_viewed_at` per channel, which is what makes "the read landed" observable instead of assumed.
struct MMChannelViewResponse: Decodable, Equatable, Sendable {
    var status: String
    var lastViewedAtTimes: [String: Int64]

    enum CodingKeys: String, CodingKey {
        case status
        case lastViewedAtTimes = "last_viewed_at_times"
    }

    init(status: String = "", lastViewedAtTimes: [String: Int64] = [:]) {
        self.status = status
        self.lastViewedAtTimes = lastViewedAtTimes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        status = try values.decodeIfPresent(String.self, forKey: .status) ?? ""
        lastViewedAtTimes = try values.decodeIfPresent([String: Int64].self,
                                                       forKey: .lastViewedAtTimes) ?? [:]
    }
}

// MARK: - Mention keys

/// One key that notifies this reader, and whether it is matched case-sensitively.
struct MentionKey: Equatable, Sendable {
    var key: String
    var caseSensitive: Bool

    init(_ key: String, caseSensitive: Bool = false) {
        self.key = key
        self.caseSensitive = caseSensitive
    }
}

/// The reader's notification keys — upstream `UserModel.mentionKeys` / `userMentionKeys`.
///
/// The derivation is upstream's, in upstream's order, because it decides both what the search asks for
/// and what a live socket event is filtered by:
///   1. `notify_props.mention_keys`, split on `,` (the account's own extra keys);
///   2. `first_name` **when `notify_props.first_name == "true"`** and the account has one — and this
///      key is matched **case-sensitively**, as upstream does (a first name is a name, not a token);
///   3. `@channel`, `@all`, `@here` when `notify_props.channel == "true"`;
///   4. `@username`, unless it is already present.
///
/// The **search terms** leave out the three special keys (`@all`, `@channel`, `@here`): asking the
/// server for "@channel" would return every broadcast in the workspace, which is not a mention of this
/// reader. Upstream filters them out in `userMentionKeys` for exactly that reason.
struct MentionKeys: Equatable, Sendable {
    var keys: [MentionKey]

    static let specialKeys: Set<String> = ["@all", "@channel", "@here"]

    init(keys: [MentionKey]) {
        self.keys = keys
    }

    /// The keys a *mention* is matched by: everything except the broadcast keys.
    var personalKeys: [MentionKey] {
        keys.filter { !Self.specialKeys.contains($0.key.lowercased()) }
    }

    /// `POST /posts/search`'s `terms`: the personal keys, space separated, with a trailing space.
    ///
    /// The trailing space is upstream's (`fetchRecentMentions` builds `keys.join(' ') + ' '`) and it
    /// matters on a database backend: a term without a separator at the end can greedily match a longer
    /// word.
    var searchTerms: String {
        let joined = personalKeys.map(\.key).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? "" : joined + " "
    }

    var isEmpty: Bool { personalKeys.isEmpty }

    /// Upstream `UserModel.mentionKeys` for a pair of facts, so the rule itself is testable.
    static func derive(username: String, firstName: String, notifyProps: JSONValue?,
                       firstNameMentions: Bool? = nil,
                       channelMentions: Bool? = nil,
                       extraKeys: [String]? = nil) -> MentionKeys {
        var keys: [MentionKey] = []
        let props = notifyProps?.objectValue

        // 1. the account's own keys (upstream splits on "," and keeps empty segments out; a trailing
        //    comma is common in the settings screen and would otherwise become a key that matches
        //    everything).
        let rawKeys = extraKeys ?? Self.split(props?["mention_keys"]?.stringValue ?? "")
        for key in rawKeys where !key.isEmpty {
            keys.append(MentionKey(key))
        }

        // 2. first name, case-sensitively, only when the account asked for it. The flag is a **string**
        //    on the wire ("true"/"false") — a Bool decode would be nil for both values and silently
        //    drop the key (`ProfileModels.swift` hit the same shape for `useAutomaticTimezone`).
        let firstNameFlag = firstNameMentions ?? Self.flag(props?["first_name"])
        if firstNameFlag, !firstName.isEmpty {
            keys.append(MentionKey(firstName, caseSensitive: true))
        }

        // 3. the broadcast keys, which a *search* must not ask for (see `personalKeys`).
        let channelFlag = channelMentions ?? Self.flag(props?["channel"])
        if channelFlag {
            keys.append(MentionKey("@channel"))
            keys.append(MentionKey("@all"))
            keys.append(MentionKey("@here"))
        }

        // 4. @username last, and only once.
        let usernameKey = "@" + username
        if !username.isEmpty, !keys.contains(where: { $0.key == usernameKey }) {
            keys.append(MentionKey(usernameKey))
        }
        return MentionKeys(keys: keys)
    }

    static func derive(_ profile: ActivityProfile) -> MentionKeys {
        derive(username: profile.username, firstName: profile.firstName,
               notifyProps: profile.notifyProps)
    }

    private static func split(_ raw: String) -> [String] {
        raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func flag(_ raw: JSONValue?) -> Bool {
        if let text = raw?.stringValue { return text.lowercased() == "true" }
        if let bool = raw?.boolValue { return bool }
        return false
    }

    /// Whether `message` mentions the reader through one of these keys.
    ///
    /// Matching is upstream's: the key must not be glued to a word character on either side (`@perf`,
    /// not `@perfprobe`) and a case-insensitive key ignores case. This is the same notion the server's
    /// search applies to `terms`, so the live path and the loaded window agree on what a mention is.
    func matches(_ message: String, caseSensitive: Bool? = nil) -> Bool {
        guard !message.isEmpty else { return false }
        for key in personalKeys where !key.key.isEmpty {
            let sensitive = caseSensitive ?? key.caseSensitive
            if Self.contains(message, key.key, caseSensitive: sensitive) { return true }
        }
        return false
    }

    /// The key that matched, for diagnostics/tests.
    func matchedKey(in message: String) -> String? {
        for key in personalKeys where Self.contains(message, key.key, caseSensitive: key.caseSensitive) {
            return key.key
        }
        return nil
    }

    /// Whether `message` names the reader through **any** key, broadcast keys (`@channel`, `@all`,
    /// `@here`) included.
    ///
    /// `matches` is the *inbox* rule and deliberately leaves the broadcast keys out: the mentions window is
    /// a personal-mentions search, and asking the server for `@channel` would return every broadcast post on
    /// the server. A **notification** is the other question — the server notifies a reader who enabled
    /// "channel mentions", so T43's policy asks this one instead. Same whole-token matching, so
    /// `@perf` is still not `@perfprobe`.
    func matchesIncludingBroadcasts(_ message: String, caseSensitive: Bool? = nil) -> Bool {
        guard !message.isEmpty else { return false }
        for key in keys where !key.key.isEmpty {
            let sensitive = caseSensitive ?? key.caseSensitive
            if Self.contains(message, key.key, caseSensitive: sensitive) { return true }
        }
        return false
    }

    /// A whole-token match: the character before and after the key is not a word character.
    nonisolated static func contains(_ message: String, _ key: String, caseSensitive: Bool) -> Bool {
        guard !key.isEmpty else { return false }
        let haystack = caseSensitive ? message : message.lowercased()
        let needle = caseSensitive ? key : key.lowercased()
        var searchStart = haystack.startIndex
        while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            let before = range.lowerBound == haystack.startIndex
                ? nil
                : haystack[haystack.index(before: range.lowerBound)]
            let after = range.upperBound == haystack.endIndex
                ? nil
                : haystack[range.upperBound]
            let gluedBefore = before.map { Self.isWordCharacter($0) } ?? false
            let gluedAfter = after.map { Self.isWordCharacter($0) } ?? false
            if !gluedBefore && !gluedAfter { return true }
            searchStart = haystack.index(after: range.lowerBound)
            if searchStart >= haystack.endIndex { break }
        }
        return false
    }

    nonisolated static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}

// MARK: - Read state

/// The reader's read cursor for one channel (`last_viewed_at`, ms).
struct ActivityChannelCursor: Equatable, Sendable {
    var channelID: String
    var lastViewedAt: Int64
    /// The server's own unread mention count for the channel, kept for diagnostics (the badge comes
    /// from the team counters, never from these — see `SessionStore.serverBadgeInput`).
    var mentionCount: Int

    init(channelID: String, lastViewedAt: Int64, mentionCount: Int = 0) {
        self.channelID = channelID
        self.lastViewedAt = lastViewedAt
        self.mentionCount = mentionCount
    }
}

/// The reader's unread state for one followed thread (`GET /users/me/teams/{team}/threads`'s rows).
struct ActivityThreadUnread: Equatable, Sendable {
    var rootID: String
    var unreadReplies: Int
    var unreadMentions: Int
    var lastViewedAt: Int64

    init(rootID: String, unreadReplies: Int, unreadMentions: Int, lastViewedAt: Int64 = 0) {
        self.rootID = rootID
        self.unreadReplies = unreadReplies
        self.unreadMentions = unreadMentions
        self.lastViewedAt = lastViewedAt
    }

    var isUnread: Bool { unreadMentions > 0 || unreadReplies > 0 }
}

// MARK: - Rows

/// Which of the feed's two filters is on. Both are the same list, filtered — upstream has one list and
/// no filter, but the card asks for filtering and "unread" is the only split the data supports without
/// inventing a category.
enum ActivityFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case unread

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .unread: return "Unread"
        }
    }
}

/// One mention as the feed draws it: where it came from, the post, and whether it is still unread.
struct ActivityRow: Identifiable, Equatable, Sendable {
    var model: PostRowModel
    var channelID: String
    var channelLabel: String
    /// The channel's team, when the feed knows it (`GET /channels/{id}` carries it). The jump needs it:
    /// a mention can be in a team that is not the one on screen.
    var teamID: String?
    var isUnread: Bool
    /// Whether read state came from the thread cursor (`true`) or the channel cursor (`false`) — a
    /// distinction the row's action depends on, and the reason the two actions are labelled differently.
    var isThreadRow: Bool

    var id: String { model.id }
    var postID: String { model.post.id }
    var createAt: Int64 { model.post.createAt }
    var rootID: String { model.post.rootId }

    /// Where tapping the row goes. Reuses the search surface's own rule (a root post opens its channel
    /// *at that post*, a reply opens its thread) rather than inventing a second jump rule.
    var jump: SearchJumpTarget { SearchJump.target(for: model.post) }
}

// MARK: - Derivation

enum ActivityDerivation {

    /// Build the rows from one server window.
    ///
    /// - Parameters:
    ///   - posts: the search answer's posts, in the server's order (newest first, measured). Sorted here
    ///     anyway: the answer's order is not part of the contract and a re-inserted live row has to land
    ///     in the same place the server would put it.
    ///   - channels: `channel_id → MMChannel`, best effort. A row whose channel was not resolved keeps
    ///     its id and says "channel" rather than guessing a name.
    ///   - users: `user_id → MMUser`, best effort (the post still draws with its author id as a fallback).
    ///   - cursors: the channel read cursors.
    ///   - threadUnread: root id → thread read state, from the team thread lists. Empty means "unknown",
    ///     in which case a reply falls back to the channel cursor and says so in `isThreadRow`.
    static func rows(posts: [MMPost],
                     channels: [String: MMChannel],
                     users: [String: MMUser],
                     myUserID: String?,
                     cursors: [String: ActivityChannelCursor],
                     threadUnread: [String: ActivityThreadUnread]) -> [ActivityRow] {
        let rows = posts.map { post -> ActivityRow in
            let channel = channels[post.channelId]
            let isReply = !post.rootId.isEmpty
            let thread = isReply ? threadUnread[post.rootId] : nil
            let unread: Bool
            let fromThread: Bool
            if let thread {
                unread = thread.isUnread
                fromThread = true
            } else {
                unread = isUnread(post, cursor: cursors[post.channelId])
                fromThread = false
            }
            let label = channel.map { SearchResultCopy.channelLabel($0) } ?? "channel"
            return ActivityRow(model: PostListDerivation.row(post: post, users: users,
                                                             myUserID: myUserID, grouped: false),
                               channelID: post.channelId,
                               channelLabel: label,
                               teamID: channel.flatMap { $0.teamId.isEmpty ? nil : $0.teamId },
                               isUnread: unread,
                               isThreadRow: fromThread)
        }
        return sorted(rows)
    }

    /// Newest first, `create_at` descending with the id as a deterministic tiebreak — the same order the
    /// channel timeline uses (`ChannelViewModel.sortedNewestFirst`), so the two surfaces read alike.
    static func sorted(_ rows: [ActivityRow]) -> [ActivityRow] {
        rows.sorted { lhs, rhs in
            if lhs.createAt != rhs.createAt { return lhs.createAt > rhs.createAt }
            return lhs.postID > rhs.postID
        }
    }

    /// The reader's read state for a post, from the channel cursor.
    ///
    /// `last_viewed_at == 0` means "never read this channel on this account" — every post is unread,
    /// which is what the server's own counters say too (measured: a fresh channel member row answers
    /// `mention_count` > 0 with `last_viewed_at: 0`).
    static func isUnread(_ post: MMPost, cursor: ActivityChannelCursor?) -> Bool {
        guard let cursor, cursor.lastViewedAt > 0 else { return true }
        return post.createAt > cursor.lastViewedAt
    }

    /// Apply the filter. `all` keeps everything; `unread` keeps the rows the reader has not caught up
    /// with.
    static func visible(_ rows: [ActivityRow], filter: ActivityFilter) -> [ActivityRow] {
        switch filter {
        case .all: return rows
        case .unread: return rows.filter(\.isUnread)
        }
    }

    /// The header line: how many mentions the window holds, and how many are unread.
    static func subtitle(rows: [ActivityRow]) -> String {
        guard !rows.isEmpty else { return "No mentions yet" }
        let unread = rows.filter(\.isUnread).count
        let mentions = "\(rows.count) mention\(rows.count == 1 ? "" : "s")"
        guard unread > 0 else { return "\(mentions) · all read" }
        return "\(mentions) · \(unread) unread"
    }

    /// The empty state's copy — different when the filter is on, so "no unread mentions" does not read
    /// as "you have never been mentioned".
    static func emptyCopy(filter: ActivityFilter, totalRows: Int) -> String {
        switch filter {
        case .all:
            return "Messages that mention you appear here — from every channel and team."
        case .unread:
            return totalRows == 0
                ? "You have no mentions yet."
                : "You have read every mention in this window."
        }
    }

    /// Whether a **live** socket post is a mention of this reader.
    ///
    /// The server's own `props.mentions` is used first when it is present (it is the
    /// notification-accurate answer, and it already excludes the author and ignored channels). The
    /// pinned server sends no such prop — measured, `"props": {}` on a post that incremented the mention
    /// counter — so the fallback is the same text match the search terms ask the server for. A post by
    /// the reader is never their own mention (upstream's notification code excludes the author, and
    /// `@me` typed at yourself is not a notification).
    static func isLiveMention(_ post: MMPost,
                              myUserID: String?,
                              keys: MentionKeys,
                              channel: MMChannel? = nil) -> Bool {
        guard !post.id.isEmpty, post.deleteAt == 0 else { return false }
        if let myUserID, !myUserID.isEmpty, post.userId == myUserID { return false }
        if let mentions = post.props?.objectValue?["mentions"]?.objectValue, !mentions.isEmpty {
            guard let myUserID, !myUserID.isEmpty else { return true }
            return mentions[myUserID] != nil
        }
        // A direct/group message is not a mention in the inbox sense (upstream's mentions search asks
        // for the mention keys, not for DMs), so a DM's text is still filtered by the keys below.
        return keys.matches(post.message)
    }

    /// Insert (or refresh) one row from a live event, keeping the list in the same order the server
    /// would produce.
    static func inserting(_ row: ActivityRow, into rows: [ActivityRow]) -> [ActivityRow] {
        var copy = rows.filter { $0.id != row.id }
        copy.append(row)
        return sorted(copy)
    }

    /// The channel ids a "mark all read" action would touch: every unread row's channel, once.
    static func unreadChannelIDs(_ rows: [ActivityRow]) -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for row in rows where row.isUnread {
            if seen.insert(row.channelID).inserted { ids.append(row.channelID) }
        }
        return ids
    }

    /// The teams the window's rows belong to — what the read-state pass has to ask for.
    static func teamIDs(_ rows: [ActivityRow]) -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for row in rows {
            guard let teamID = row.teamID, !teamID.isEmpty, seen.insert(teamID).inserted else { continue }
            ids.append(teamID)
        }
        return ids.sorted()
    }

    /// The author + channel ids the rows need resolved, in a stable order (so a repeat load hits cache).
    static func profileIDs(_ posts: [MMPost]) -> [String] {
        Array(Set(posts.map(\.userId).filter { !$0.isEmpty })).sorted()
    }

    static func channelIDs(_ posts: [MMPost]) -> [String] {
        Array(Set(posts.map(\.channelId).filter { !$0.isEmpty })).sorted()
    }
}
