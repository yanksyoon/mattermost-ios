// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/channel/channel_post_list/channel_post_list.tsx (load the page, keep the list
//        window, load older on reach-top), app/actions/remote/post.ts (`handlePosts` merge rules:
//        a post that arrives twice is replaced, not duplicated; a deleted post keeps its slot),
//        app/actions/websocket/posts.ts (posted/post_edited/post_deleted applied in place),
//        app/utils/post_list/index.ts (ordering), app/screens/channel/channel.tsx (the header title,
//        including a DM's other participant).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §10; no
// upstream source copied. The view model shape is this repo's own (docs/component-map.md §1), and
// mirrors `ChannelListViewModel` from T33: a generation guard, a service seam, no I/O in the rules.
//
// What this object owns, and what it deliberately does not:
//  - it owns the **loaded window** (newest N posts, growing backwards), the page cursor, the socket
//    patch rules and the scroll anchor;
//  - it does not own the composer, reactions writes, marking the channel read or the thread pane —
//    those are S14/S16/T35-T37 and each will call the same service seam;
//  - it does not read T29's SQLite store: no app-level `MMStore` is wired into the running app yet
//    (T29 delivered the store module; wiring it per server is not this card), so the window is
//    in-memory. The seam is `ChannelServing`, so a store-backed implementation can replace the
//    network one without touching the view or these rules (docs/t34-build-note.md §10).

import Foundation
import Combine

/// One channel's post list: load, paginate, patch from the socket, keep the reader where they were.
@MainActor
final class ChannelViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// Where the reader is, expressed as a post and its distance from the top of the viewport.
    ///
    /// Expressed relative to a *post*, not a pixel offset, because the offset is only meaningful with
    /// the row heights that produced it: after an older page is prepended, the same post keeps the
    /// same id and the view scrolls back to it (see `pendingScrollRestore`).
    struct ScrollAnchor: Equatable {
        var postID: String
        var offsetFromTop: CGFloat
    }

    /// What one socket event did to this list.
    enum EventOutcome: Equatable {
        case ignored
        case appended
        case patched
        case deleted
        case reactions
        case viewed
    }

    // MARK: State

    @Published private(set) var phase: Phase = .idle
    /// The rendered list, oldest first (top to bottom).
    @Published private(set) var items: [PostListItem] = []
    /// The channel's title as the header draws it (a DM's other participant where the server's own
    /// `display_name` is `id__id`).
    @Published private(set) var title: String
    @Published private(set) var channelType: String = ""
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasMore = false
    /// A failed "load earlier" is reported next to the sentinel instead of replacing the list: the
    /// posts already on screen are still valid.
    @Published private(set) var loadEarlierError: String?
    /// Posts the reader expanded ("Show more").
    @Published private(set) var expandedPostIDs: Set<String> = []
    /// Set after an older page lands, consumed by the view to scroll back to the reader's post.
    @Published private(set) var pendingScrollRestore: ScrollAnchor?
    /// The last socket event's effect, for diagnostics/tests (never rendered).
    @Published private(set) var lastEventOutcome: EventOutcome = .ignored

    /// How many posts the window holds (diagnostics/tests).
    var loadedCount: Int { posts.count }
    var loadedPostIDs: [String] { posts.map(\.id) }
    func post(id: String) -> MMPost? { postsByID[id] }

    // MARK: Collaborators

    private let service: ChannelServing
    private let now: () -> Date
    private let calendar: Calendar
    private let locale: Locale

    // MARK: The window

    /// Newest first — the server's own order, kept as the single source for pagination order.
    private var posts: [MMPost] = []
    private var postsByID: [String: MMPost] = [:]
    private var users: [String: MMUser] = [:]
    /// `channel_member.last_viewed_at`, used to place the unread divider. `nil` = unknown.
    private var lastViewedAt: Int64?
    /// True once `lastViewedAt` came from a caller or the server, so the load does not overwrite it
    /// with a second (slower) answer.
    private var lastViewedAtIsAuthoritative: Bool
    private var myUserID: String?
    /// The channel this model is showing. Set by the coordinator; empty until then.
    private(set) var channelID: String
    /// Every load takes a number; a response that arrives after a newer load is dropped instead of
    /// merged (a fast channel switch otherwise mixes two channels' posts).
    private var generation = 0
    private var scrollAnchor: ScrollAnchor?

    init(channelID: String,
         channelName: String? = nil,
         service: ChannelServing,
         myUserID: String? = nil,
         lastViewedAt: Int64? = nil,
         now: @escaping () -> Date = { Date() },
         calendar: Calendar = .current,
         locale: Locale = .current) {
        self.channelID = channelID
        self.title = channelName ?? ""
        self.service = service
        self.myUserID = myUserID
        self.lastViewedAt = lastViewedAt
        self.lastViewedAtIsAuthoritative = lastViewedAt != nil
        self.now = now
        self.calendar = calendar
        self.locale = locale
    }

    // MARK: - Loading

    /// Load (or reload) the newest page. `force: false` answers a re-mount from the window it already
    /// has, so a rotation or a tab switch does not refetch and lose the reader's place.
    func load(ifNeeded: Bool = true) async {
        if ifNeeded, phase == .loaded { return }
        await performInitialLoad()
    }

    func reload() async {
        await performInitialLoad()
    }

    func retry() async {
        await performInitialLoad()
    }

    private func performInitialLoad() async {
        guard !channelID.isEmpty else {
            phase = .failed("No channel is selected.")
            return
        }
        generation += 1
        let requested = generation
        phase = .loading
        loadEarlierError = nil
        do {
            let page = try await service.posts(channelID: channelID, before: nil,
                                              perPage: service.pageSize)
            guard requested == generation else { return }

            posts = Self.sortedNewestFirst(page.orderedPosts)
            postsByID = Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) })
            hasMore = Self.morePages(after: page, pageSize: service.pageSize)
            // Where the reader stopped last time: the membership row's `last_viewed_at` is what places
            // the "New messages" line. A caller-supplied value wins (the sidebar already holds it).
            if !lastViewedAtIsAuthoritative,
               let member = try? await service.membership(channelID: channelID) {
                lastViewedAt = member.lastViewedAt
                lastViewedAtIsAuthoritative = true
            }
            await loadProfiles(for: Array(Set(posts.map(\.userId))))
            guard requested == generation else { return }
            await loadChannelHeader()
            guard requested == generation else { return }
            rebuild()
            phase = .loaded
        } catch {
            guard requested == generation else { return }
            phase = .failed(Self.message(for: error))
        }
    }

    /// Load one older page. Returns whether the window grew.
    @discardableResult
    func loadEarlier() async -> Bool {
        guard phase == .loaded, hasMore, !isLoadingMore, let oldest = posts.last?.id else {
            return false
        }
        isLoadingMore = true
        loadEarlierError = nil
        defer { isLoadingMore = false }
        let requested = generation
        do {
            let page = try await service.posts(channelID: channelID, before: oldest,
                                               perPage: service.pageSize)
            guard requested == generation else { return false }
            let known = Set(posts.map(\.id))
            let fresh = page.orderedPosts.filter { !known.contains($0.id) }
            guard !fresh.isEmpty else {
                // The server answered with a page we already hold (a stale cursor, or the very
                // oldest page repeated). Nothing to merge, and stopping here is what prevents an
                // infinite "load more" loop.
                hasMore = false
                return false
            }
            posts = Self.sortedNewestFirst(posts + fresh)
            for post in fresh { postsByID[post.id] = post }
            await loadProfiles(for: Array(Set(fresh.map(\.userId))))
            guard requested == generation else { return false }
            // A short page is the last page; `has_next: false` is authoritative when the server sent
            // it (some endpoints send the flag, a channel page usually does not).
            hasMore = Self.morePages(after: page, pageSize: service.pageSize)
            rebuild()
            // The reader was looking at `anchor`; the view scrolls back to it after this publish.
            pendingScrollRestore = scrollAnchor
            return true
        } catch {
            guard requested == generation else { return false }
            loadEarlierError = Self.message(for: error)
            return false
        }
    }

    private func loadProfiles(for userIDs: [String]) async {
        let missing = userIDs.filter { users[$0] == nil }
        guard !missing.isEmpty else { return }
        // A profile failure must not fail the page (rows fall back to the username in `props`).
        let loaded = (try? await service.users(ids: missing)) ?? []
        for user in loaded { users[user.id] = user }
    }

    /// The header title. A DM's `name` is `<userID>__<userID>` and a GM's is an opaque hash; the only
    /// source of a human label is the participant, so the other id is resolved through the same
    /// batched profile request the rows use (this is the T33 note's "header shows id__id" gap).
    private func loadChannelHeader() async {
        guard let channel = try? await service.channel(id: channelID) else { return }
        channelType = channel.type
        switch channel.type {
        case "D":
            let parts = channel.name.components(separatedBy: "__")
            let other = parts.first(where: { $0 != myUserID && !$0.isEmpty }) ?? parts.first ?? ""
            if users[other] == nil, !other.isEmpty {
                await loadProfiles(for: [other])
            }
            if let user = users[other] {
                title = PostListDerivation.displayName(for: user)
            } else if !title.isEmpty {
                // Keep whatever the shell already had (a resolved channel name) rather than the id.
            } else {
                title = "Direct message"
            }
        case "G":
            title = "Group message"
        default:
            title = channel.displayName.isEmpty ? channel.name : channel.displayName
        }
    }

    // MARK: - Socket

    /// Apply one event from the server's socket (already scoped to the team by `TeamSocketScope`).
    ///
    /// The rules, each of which a test pins:
    ///  - only posts of **this** channel, and only top-level posts (a reply belongs to the thread
    ///    pane, S13/T36 — the channel list must not show it);
    ///  - a `posted` for an id already in the window **replaces** it (a reconnect replay or a race with
    ///    the page load must not duplicate the row);
    ///  - an edit keeps the row's position (a post does not move because it was edited);
    ///  - a delete keeps the row and marks it (the tombstone is in place, which is what a reader
    ///    expects after watching a message disappear);
    ///  - a reaction patches the row's summary in place;
    ///  - `channel_viewed` by me clears the unread divider.
    @discardableResult
    func handle(_ event: SocketEvent) -> EventOutcome {
        let outcome: EventOutcome
        switch event {
        case .posted(let post):
            guard accepts(post: post) else { return record(.ignored) }
            if postsByID[post.id] != nil {
                replace(post)
                outcome = .patched
            } else {
                posts.append(post)
                postsByID[post.id] = post
                posts = Self.sortedNewestFirst(posts)
                // A new author (a bot, a guest) must not render as "Unknown user" until a reload.
                scheduleProfileLoad(for: post.userId)
                outcome = .appended
            }
        case .postEdited(let post):
            guard accepts(post: post), postsByID[post.id] != nil else { return record(.ignored) }
            replace(post)
            outcome = .patched
        case .postDeleted(let post):
            guard postsByID[post.id] != nil else { return record(.ignored) }
            var tombstone = postsByID[post.id] ?? post
            tombstone.deleteAt = post.deleteAt > 0 ? post.deleteAt : Int64(now().timeIntervalSince1970 * 1000)
            tombstone.message = ""
            tombstone.fileIds = []
            tombstone.props = nil
            tombstone.metadata = nil
            replace(tombstone)
            outcome = .deleted
        case .reactionAdded(let reaction):
            guard postsByID[reaction.postId] != nil, appendReaction(reaction) else {
                return record(.ignored)
            }
            outcome = .reactions
        case .reactionRemoved(let reaction):
            guard postsByID[reaction.postId] != nil, removeReaction(reaction) else {
                return record(.ignored)
            }
            outcome = .reactions
        case .channelViewed(let viewed):
            guard viewed.channelID == channelID, viewed.userID == myUserID else {
                return record(.ignored)
            }
            lastViewedAt = posts.first?.createAt ?? lastViewedAt
            outcome = .viewed
        case .multipleChannelsViewed(let viewed):
            // My own `view` call can mark several channels read at once. This pane only cares when its
            // own channel is in the map, and the server's timestamp is the honest value to draw the
            // divider against (unlike `channel_viewed`, which carries no time).
            guard viewed.userID == myUserID, let viewedAt = viewed.channelTimes[channelID] else {
                return record(.ignored)
            }
            lastViewedAt = max(lastViewedAt ?? 0, viewedAt)
            outcome = .viewed
        case .hello, .typing, .statusChange, .preferencesChanged, .userUpdated,
             .sidebarCategoryUpdated, .channelCreated, .channelDeleted, .channelMemberUpdated,
             .postUnread, .unhandled:
            return record(.ignored)
        }
        rebuild()
        return record(outcome)
    }

    private func record(_ outcome: EventOutcome) -> EventOutcome {
        lastEventOutcome = outcome
        return outcome
    }

    private func accepts(post: MMPost) -> Bool {
        post.channelId == channelID && post.rootId.isEmpty && !post.id.isEmpty
    }

    private func replace(_ post: MMPost) {
        guard let index = posts.firstIndex(where: { $0.id == post.id }) else { return }
        posts[index] = post
        postsByID[post.id] = post
    }

    private func scheduleProfileLoad(for userID: String) {
        guard !userID.isEmpty, users[userID] == nil else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.loadProfiles(for: [userID])
            self.rebuild()
        }
    }

    // MARK: - Reactions (rendered here, added/removed by S16/T37)

    private func appendReaction(_ reaction: MMReaction) -> Bool {
        guard var post = postsByID[reaction.postId] else { return false }
        var list = post.metadata?["reactions"]?.arrayValue ?? []
        if list.contains(where: { value in
            let existing = try? MMRawJSON(value).decode(MMReaction.self)
            return existing?.userId == reaction.userId && existing?.emojiName == reaction.emojiName
        }) {
            return false     // already counted (a replayed event)
        }
        list.append(Self.jsonValue(of: reaction))
        post.metadata = Self.metadata(post.metadata, settingReactions: list)
        replace(post)
        return true
    }

    private func removeReaction(_ reaction: MMReaction) -> Bool {
        guard var post = postsByID[reaction.postId] else { return false }
        var list = post.metadata?["reactions"]?.arrayValue ?? []
        let before = list.count
        list.removeAll { value in
            let existing = try? MMRawJSON(value).decode(MMReaction.self)
            return existing?.userId == reaction.userId && existing?.emojiName == reaction.emojiName
        }
        guard list.count != before else { return false }
        post.metadata = Self.metadata(post.metadata, settingReactions: list)
        replace(post)
        return true
    }

    private static func jsonValue(of reaction: MMReaction) -> JSONValue {
        guard let data = try? JSONEncoder().encode(reaction),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .object([:])
        }
        return value
    }

    private static func metadata(_ metadata: JSONValue?, settingReactions reactions: [JSONValue]) -> JSONValue {
        var object = metadata?.objectValue ?? [:]
        object["reactions"] = .array(reactions)
        return .object(object)
    }

    // MARK: - Reader state

    func setScrollAnchor(_ anchor: ScrollAnchor?) {
        scrollAnchor = anchor
    }

    /// Ask the view to put `anchor` back where it is now.
    ///
    /// An older page is not the only thing that moves content under the reader: expanding a folded
    /// post grows every row below it, and with the list bottom-anchored that scrolls the reader away
    /// from the post they just tapped. The same restore serves both cases.
    func requestScrollRestore(_ anchor: ScrollAnchor?) {
        guard let anchor else { return }
        scrollAnchor = anchor
        pendingScrollRestore = anchor
    }

    /// The view calls this once it has scrolled back (`ScrollViewReader.scrollTo`), so the anchor is
    /// not applied twice.
    func consumeScrollRestore() {
        pendingScrollRestore = nil
    }

    func toggleExpanded(_ postID: String) {
        if expandedPostIDs.contains(postID) {
            expandedPostIDs.remove(postID)
        } else {
            expandedPostIDs.insert(postID)
        }
        rebuild()
    }

    func isExpanded(_ postID: String) -> Bool { expandedPostIDs.contains(postID) }

    /// The id the view scrolls back to after an older page lands.
    var pendingScrollTarget: String? { pendingScrollRestore?.postID }

    // MARK: - Derivation

    private func rebuild() {
        items = PostListDerivation.items(posts: posts,
                                         users: users,
                                         myUserID: myUserID,
                                         lastViewedAt: lastViewedAt,
                                         expandedPostIDs: expandedPostIDs,
                                         now: now(),
                                         calendar: calendar,
                                         locale: locale)
    }

    /// Newest first, `create_at` descending with the id as a deterministic tiebreak.
    static func sortedNewestFirst(_ posts: [MMPost]) -> [MMPost] {
        posts.sorted { lhs, rhs in
            if lhs.createAt != rhs.createAt { return lhs.createAt > rhs.createAt }
            return lhs.id > rhs.id
        }
    }

    /// Whether an older page exists after `page`.
    ///
    /// `has_next == false` is authoritative when the server sends it; otherwise a page shorter than
    /// the request is the last page. A full page may still be the last one, so this can cost one
    /// empty request — cheaper than a phantom "load more" that never resolves.
    static func morePages(after page: MMPostList, pageSize: Int) -> Bool {
        if let hasNext = page.hasNext { return hasNext }
        return page.order.count >= pageSize
    }

    static func message(for error: Error) -> String {
        if let mm = error as? MMError {
            switch mm {
            case .offline:
                return "You are offline. This channel will load when the connection is back."
            case .timeout:
                return "The server did not answer in time."
            case .unauthorized:
                return "Your session has expired. Sign in again to read this channel."
            case .forbidden:
                return "You do not have permission to read this channel."
            case .notFound:
                return "This channel no longer exists."
            case .rateLimited:
                return "The server is rate limiting this app. Try again shortly."
            default:
                break
            }
            return mm.errorDescription ?? "The channel could not be loaded."
        }
        return error.localizedDescription
    }
}
