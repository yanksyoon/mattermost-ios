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
//
// The window's membership rule (T34-R5, finding T34-AV-F1) is stated once — `isTimelineRow` — and
// used by **both** halves: the page merge (`load`/`loadEarlier`) and the socket handler
// (`accepts(post:)`). Before that repair the page kept every post the server returned (replies
// included, drawn as top-level messages with no thread affordance) while the socket dropped them,
// so the same reply was a row or not depending only on how it arrived. A thread-collapsed Mattermost
// centre timeline shows top-level posts only, which is what both halves now do.
//
// T35 added the composer's write path (`ComposerPostSink`): the optimistic row, its replacement by
// the server's post **by `pending_post_id`**, the tombstone an edit/delete produces, and the
// "did it land anyway?" question a retry asks. The rules are here rather than in the composer
// because the composer cannot see the window: only the list knows whether the row is already on
// screen, whether the socket beat the REST answer, and where the row belongs in the order.

import Foundation
import Combine

/// One channel's post list: load, paginate, patch from the socket, keep the reader where they were.
@MainActor
final class ChannelViewModel: ObservableObject, ComposerPostSink {

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
        /// Points between the viewport's top edge and the post's top edge — **not** a position inside
        /// the scroll content, which grows as pages are prepended.
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
    /// The last reader-restore the view performed, and what it did.
    ///
    /// Published because the restore is otherwise invisible: the live anchor test asserts the
    /// user-visible property ("the row keeps its y"), which on iOS 18+ also holds when the restore is
    /// deleted outright (task t_a4d02070, `docs/t34qa-build-note.md` §8 mutation A). This report is the
    /// second, narrower signal — a restore that ran names its post, counts its frames and corrections,
    /// and says whether the layout settled — so "the restore path is wired" is assertable in a unit
    /// test (`T34ChannelViewRestoreWiringTests`) and through the `-uiTestExposeLoadEarlier` seam in the
    /// live suite.
    @Published private(set) var lastScrollRestore: ScrollRestoreReport?
    /// T39: a post a jump asked for. The view scrolls to it and calls `consumeJump()`.
    @Published private(set) var jumpTarget: String?
    /// T39: the post the jump landed on, drawn with a marking bar until the reader searches again.
    @Published private(set) var focusedPostID: String?
    /// T39: why a jump could not land (the post is gone, or it is another channel's).
    @Published private(set) var focusError: String?
    /// T39: set when the jump target is a **reply** — the view opens its thread instead (a reply is not
    /// a row of a thread-collapsed timeline).
    @Published private(set) var threadJumpRootID: String?
    /// The last socket event's effect, for diagnostics/tests (never rendered).
    @Published private(set) var lastEventOutcome: EventOutcome = .ignored
    /// T34-R5: how many reconnect refetches this window ran, and how many **new** rows the last one added.
    ///
    /// Diagnostics and tests: "never resyncs" and "resyncs on every connect" look identical on screen
    /// until one of them is counted, and the difference is what a lost frame costs. A failed refetch
    /// counts as an attempt (`lastResyncInsertedCount` stays 0); only the phase and the window are left
    /// alone, because the rows on screen are still the server's page as of the last load.
    private(set) var resyncCount = 0
    private(set) var lastResyncInsertedCount = 0

    /// How many posts the window holds (diagnostics/tests).
    var loadedCount: Int { posts.count }
    var loadedPostIDs: [String] { posts.map(\.id) }
    /// The oldest post the pane holds — the end that grows when an older page merges.
    var oldestLoadedPostID: String? { posts.last?.id }
    func post(id: String) -> MMPost? { postsByID[id] }

    // MARK: Collaborators

    private let service: ChannelServing
    private let now: () -> Date
    private let calendar: Calendar
    private let locale: Locale

    // MARK: The window

    /// Newest first — the server's own order, kept as the single source for pagination order.
    /// Holds **rows only** (see `isTimelineRow`), never a reply.
    private var posts: [MMPost] = []
    private var postsByID: [String: MMPost] = [:]
    /// Author profiles for the rows on screen, and — for T37 — the names the reactor sheet draws.
    private(set) var users: [String: MMUser] = [:]
    /// The newest page's oldest post id as the **server** answered it — the next `before` cursor.
    ///
    /// Kept apart from `oldestLoadedPostID` on purpose: a page can carry posts this window drops (a
    /// reply), and the server's `before` is exclusive, so a cursor taken from the last row *kept*
    /// would ask for a window that starts after the page's real end — or, on a page that is entirely
    /// replies, would not advance at all and stall paging (T34-R5).
    private var pageCursor: String?
    /// `channel_member.last_viewed_at`, used to place the unread divider. `nil` = unknown.
    private var lastViewedAt: Int64?
    /// The oldest `create_at` the window loaded **contiguously** (T39).
    ///
    /// The newest page and every older page `loadEarlier` appends are continuous with each other, so
    /// this is simply the oldest row's `create_at` after each of those merges. A post a jump fetched
    /// by id and merged (`mergeJumpedPost`) is deliberately *not* included: it is older, isolated and
    /// unknown-gap distance from the window, and `PostListDerivation.items` draws a `.gap` separator
    /// at that boundary. Loading earlier pages far enough to reach it drops the floor below it and
    /// the separator disappears on its own — the list is then honestly continuous again.
    private var contiguousFloorCreateAt: Int64?
    /// True once `lastViewedAt` came from a caller or the server, so the load does not overwrite it
    /// with a second (slower) answer.
    private var lastViewedAtIsAuthoritative: Bool
    /// The session user, as the reactions write needs it: a react is always *my* reaction, and the
    /// pill's highlight is "this is mine".
    private(set) var myUserID: String?
    /// The channel this model is showing. Set by the coordinator; empty until then.
    private(set) var channelID: String
    /// Every load takes a number; a response that arrives after a newer load is dropped instead of
    /// merged (a fast channel switch otherwise mixes two channels' posts).
    private var generation = 0
    private var scrollAnchor: ScrollAnchor?
    /// T35: rows the composer inserted optimistically, drawn with a "Sending…" status until the
    /// server's answer (over REST or the socket) replaces them.
    private var pendingPostIDs: Set<String> = []
    /// The client id the sender supplied → the row id that currently represents it. A row keeps its
    /// pending id until the server's post lands, then the **real** post id is remembered here, so a
    /// retry can ask "did this already arrive?" instead of posting the same message twice.
    private var pendingRowIDs: [String: String] = [:]
    /// Client id → the server's post, once it is known. Kept even for a post that is not a row of this
    /// channel (a reply, or a post in another channel), so the composer's retry check can answer for
    /// every send it made.
    private var pendingResolvedPosts: [String: MMPost] = [:]
    /// Subscriptions that forward a collaborator's published state as this model's (T37: the reaction
    /// coordinator's failure banner lives in the list's overlay).
    private var cancellables = Set<AnyCancellable>()

    /// How the view answers "where is the reader right now", measured from its scroll view.
    ///
    /// `loadEarlier()` asks before it sends the request, so the place the restore aims at is taken at
    /// the instant the page is requested instead of from the last periodic sample. A model used
    /// without a view (unit tests, a future non-SwiftUI host) leaves it nil and keeps whatever anchor
    /// `setScrollAnchor` was given.
    var readerAnchorProvider: (() -> ScrollAnchor?)?

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

            // The window keeps the page's top-level posts; the cursor keeps the page's oldest id,
            // whatever the page held (T34-R5: the two must not be the same expression).
            pageCursor = page.orderedPosts.last?.id
            posts = Self.sortedNewestFirst(Self.timelineRows(page.orderedPosts, channelID: channelID))
            postsByID = Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) })
            contiguousFloorCreateAt = posts.last?.createAt
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
            adoptReactionState(for: posts)
            rebuild()
            phase = .loaded
        } catch {
            guard requested == generation else { return }
            phase = .failed(Self.message(for: error))
        }
    }

    // MARK: - Resync after a reconnect (T34-R5)

    /// Repair the window after the socket dropped and came back.
    ///
    /// A reconnect is the one moment this client *knows* it may have missed events: the server does not
    /// replay what it published while the connection was down, and `SocketClient` reports the reconnect
    /// only as a message to the app (`resync`, once per reconnect). Nothing passed that closure until
    /// T34-R5 measured a `posted` that never reached this model, which meant a message lost in that
    /// window stayed lost until the app was relaunched.
    ///
    /// What it does, and what it deliberately does not:
    ///  - it refetches the **newest page** and merges it: rows it does not hold are inserted, rows it does
    ///    hold are replaced by the server's copy (an edit made while the socket was down), and **nothing
    ///    is dropped** — a reader who has scrolled back through older pages keeps them;
    ///  - it does not reset the window (`reload()` does), the paging cursor or `hasMore`, so a resync can
    ///    neither move the reader nor make the older end unreachable;
    ///  - it adopts a `last_viewed_at` that moved **forward** (the channel was read on another client),
    ///    which is what moves the unread divider, and never moves it back;
    ///  - it is a no-op on a model that never loaded: its first load fetches the newest page anyway.
    ///
    /// Returns how many rows were added (`0` when the window was already current or the request failed —
    /// a failed resync is not a failed pane; the rows on screen are still the server's page as of the last
    /// load, and the next reconnect tries again).
    @discardableResult
    func resyncAfterReconnect() async -> Int {
        guard phase == .loaded else { return 0 }
        let requested = generation
        // Counted before the request: the attempt is what a diagnostic needs to see, and a refetch that
        // fails is still a refetch the app made.
        resyncCount += 1
        lastResyncInsertedCount = 0
        do {
            let page = try await service.posts(channelID: channelID, before: nil, perPage: service.pageSize)
            guard requested == generation else { return 0 }
            let rows = Self.timelineRows(page.orderedPosts, channelID: channelID)
            let known = Set(posts.map(\.id))
            // A page cannot reorder what is already loaded: a row that is held keeps its position and
            // only its content is refreshed.
            for row in rows where known.contains(row.id) { replace(row) }
            let fresh = rows.filter { !known.contains($0.id) }
            if !fresh.isEmpty {
                for row in fresh { postsByID[row.id] = row }
                posts = Self.sortedNewestFirst(posts + fresh)
            }
            await loadProfiles(for: Array(Set(fresh.map(\.userId))))
            guard requested == generation else { return 0 }
            adoptReactionState(for: rows)
            if let member = try? await service.membership(channelID: channelID),
               member.lastViewedAt > (lastViewedAt ?? 0) {
                lastViewedAt = member.lastViewedAt
            }
            guard requested == generation else { return 0 }
            rebuild()
            lastResyncInsertedCount = fresh.count
            return fresh.count
        } catch {
            return 0
        }
    }

    /// How many pages one "load earlier" will consume while they yield no new row.
    ///
    /// A page can legitimately hold nothing this window keeps — a run of 60 replies under one root is
    /// exactly that — and ending the window there would leave the sentinel saying "This is the
    /// beginning of the channel" with posts still unread. The walk therefore advances the server
    /// cursor and asks again, up to this many pages per call; past it, `hasMore` stays true and the
    /// reader's next reach at the top continues from the advanced cursor. The production request asks
    /// the server for top-level posts only, so a page normally yields rows and one hop is the norm.
    static let maximumPageHops = 10

    /// Load one older page. Returns whether the window grew.
    @discardableResult
    func loadEarlier() async -> Bool {
        guard phase == .loaded, hasMore, !isLoadingMore,
              let cursor = pageCursor ?? posts.last?.id else {
            return false
        }
        // Take the reader's place *now*, from the view, before anything is inserted: after the merge
        // the same post sits further down, so a later reading would record the moved position.
        if let provider = readerAnchorProvider, let place = provider() {
            scrollAnchor = place
        }
        isLoadingMore = true
        loadEarlierError = nil
        defer { isLoadingMore = false }
        let requested = generation
        var rows: [MMPost] = []
        var nextCursor = cursor
        var more = hasMore
        var hops = 0
        do {
            while true {
                hops += 1
                let page = try await service.posts(channelID: channelID, before: nextCursor,
                                                   perPage: service.pageSize)
                guard requested == generation else { return false }
                let raw = page.orderedPosts
                let known = Set(posts.map(\.id)).union(rows.map(\.id))
                let fresh = Self.timelineRows(raw, channelID: channelID)
                    .filter { !known.contains($0.id) }
                rows.append(contentsOf: fresh)
                // A short page is the last page. `has_next` is *not* consulted: the pinned server
                // answers `false` on every channel page, including the first of six (see `morePages`).
                more = Self.morePages(after: page, pageSize: service.pageSize)
                // The cursor advances to the page's oldest id. `before` is exclusive, so a page that
                // ends on the cursor itself means the server ignored `before` (a stale cursor, or the
                // very oldest page repeated): the only honest advance left is the oldest *new* id on
                // the page, and a page with nothing new at all is no progress — stop, never spin.
                let pageOldest = raw.last?.id
                let advanced = pageOldest != nextCursor ? pageOldest : fresh.last?.id
                guard let advanced, advanced != nextCursor else {
                    more = false
                    break
                }
                nextCursor = advanced
                if !fresh.isEmpty || !more || hops >= Self.maximumPageHops { break }
            }
            pageCursor = nextCursor
            hasMore = more
            guard !rows.isEmpty else {
                // Every page read was made of posts this window does not keep. The window is unchanged
                // (so the reader is not moved), and the cursor has advanced for the next reach.
                return false
            }
            posts = Self.sortedNewestFirst(posts + rows)
            for post in rows { postsByID[post.id] = post }
            // The page is continuous with the window it was appended to (`before` is exclusive but
            // adjacent), so the contiguous floor follows the page's oldest new row. It is taken from
            // `rows`, never from `posts`: a jumped-to post merged by `mergeJumpedPost` may be older
            // still, and it is *not* contiguous with anything.
            if let oldestOfPage = rows.map(\.createAt).min() {
                contiguousFloorCreateAt = min(contiguousFloorCreateAt ?? oldestOfPage, oldestOfPage)
            }
            await loadProfiles(for: Array(Set(rows.map(\.userId))))
            guard requested == generation else { return false }
            adoptReactionState(for: rows)
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
    ///  - only posts of **this** channel, and only top-level posts: a reply belongs to the thread pane
    ///    (S13/T36), so the channel list must not show it — and the page merge applies the *same*
    ///    rule (`isTimelineRow`), so a reply is a row or not for exactly the same reason however it
    ///    arrived (T34-AV-F1);
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
            // A send this app started (T35): the server echoes the client's `pending_post_id`. The
            // optimistic row must be replaced **by that id** before `accepts` runs, because a reply is
            // not a row of this channel but its pending row still has to be withdrawn.
            if !post.pendingPostId.isEmpty, pendingRowIDs[post.pendingPostId] != nil {
                reconcile(pendingID: post.pendingPostId, with: post)
                rebuild()
                return record(.patched)
            }
            guard post.rootId.isEmpty == true else {
                // A reply is not a row of this timeline (`isTimelineRow`), but its root's reply count
                // and participant stack are drawn here — the gap T34 named ("a reply arriving over the
                // socket does not refresh its root's reply_count until the pane is reopened") closes
                // here (T36).
                outcome = recordReply(post, delta: 1)
                break
            }
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
            if postsByID[post.id] != nil {
                applyTombstone(post)
                outcome = .deleted
            } else if !post.rootId.isEmpty, postsByID[post.rootId] != nil {
                // A reply's removal moves its root's count down; the row for the reply was never here.
                outcome = recordReply(post, delta: -1)
            } else {
                return record(.ignored)
            }
        case .reactionAdded(let reaction):
            guard postsByID[reaction.postId] != nil else { return record(.ignored) }
            // The post changes through the same function an optimistic tap uses. Whether it changed
            // anything or not, the write machine is told: an event can be the echo of our own tap
            // (nothing to apply) and still be the proof the server accepted it.
            let added = appendReaction(reaction)
            reactions.noteSocketEvent(reaction, adding: true)
            guard added else { return record(.ignored) }
            outcome = .reactions
        case .reactionRemoved(let reaction):
            guard postsByID[reaction.postId] != nil else { return record(.ignored) }
            let removed = removeReaction(reaction)
            reactions.noteSocketEvent(reaction, adding: false)
            guard removed else { return record(.ignored) }
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
        case .threadUpdated(let update):
            outcome = applyThread(update.thread)
        case .threadFollowChanged(let change):
            guard var root = postsByID[change.threadID] else { return record(.ignored) }
            root.replyCount = max(change.replyCount, 0)
            // T48: the follow flag is part of the row (the channel page sends `is_following`, and the
            // row menu derives Follow/Unfollow from it). Before this the event moved only the reply
            // count, so a follow pressed in another client left the menu offering "Follow Thread".
            root.isFollowing = change.state
            replace(root)
            outcome = .patched
        case .threadReadChanged:
            // A thread's read position is the thread pane's business (and the global list's); the
            // channel timeline draws no per-thread read state.
            return record(.ignored)
        case .hello, .typing, .statusChange, .preferencesChanged, .preferencesDeleted, .userUpdated,
             .sidebarCategoryUpdated, .channelCreated, .channelDeleted, .channelMemberUpdated,
             .channelUpdated, .channelRestored, .userAdded, .userRemoved,
             .postUnread, .plugin, .unhandled:
            // `.plugin` is a plugin's own sub-protocol (`custom_<id>_<event>`), consumed by that
            // plugin's client code — for Calls, `CallsSignallingPort` reads it off the socket
            // directly. A channel timeline has nothing to do with it.
            return record(.ignored)
        }
        rebuild()
        return record(outcome)
    }

    private func record(_ outcome: EventOutcome) -> EventOutcome {
        lastEventOutcome = outcome
        return outcome
    }

    /// The window's membership rule, stated **once** and used by both halves (T34-AV-F1).
    ///
    /// A row of a channel's centre timeline is a top-level post of that channel. A reply
    /// (`root_id != ""`) is drawn by the thread pane (S11/T36), exactly as a thread-collapsed
    /// Mattermost client draws its centre channel — never as a top-level row with no way to see what
    /// it is answering. `load`/`loadEarlier` filter a page through `timelineRows`, and
    /// `handle(.posted)` refuses a post that fails `isTimelineRow`, so the same post is a row or not
    /// for the same reason on both paths.
    static func timelineRows(_ posts: [MMPost], channelID: String) -> [MMPost] {
        posts.filter { isTimelineRow($0, channelID: channelID) }
    }

    static func isTimelineRow(_ post: MMPost, channelID: String) -> Bool {
        !post.id.isEmpty && post.rootId.isEmpty && post.channelId == channelID
    }

    private func accepts(post: MMPost) -> Bool {
        Self.isTimelineRow(post, channelID: channelID)
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

    // MARK: - A reply moves its root (T36, S13)

    /// A reply landed or left for a root this window holds: move the root's reply count and its
    /// participant stack **without** adding a row for the reply.
    ///
    /// The count is incremented only for a reply strictly newer than the root's `last_reply_at`: a
    /// replayed `posted` (a reconnect, a REST/socket race) carries the reply's original `create_at`,
    /// which the root has already counted, so the same event twice cannot inflate the number. A
    /// delete always decrements (its arrival was counted once and the socket dedupes a replay by
    /// `id|update_at|delete_at`), and never below zero.
    private func recordReply(_ post: MMPost, delta: Int) -> EventOutcome {
        guard var root = postsByID[post.rootId] else { return .ignored }
        if delta > 0, post.createAt <= root.lastReplyAt { return .ignored }
        root.replyCount = max(0, root.replyCount + delta)
        if post.createAt > root.lastReplyAt { root.lastReplyAt = post.createAt }
        if post.deleteAt == 0, !post.userId.isEmpty {
            var participants = root.participants ?? []
            participants.removeAll { $0.id == post.userId }
            participants.insert(MMUser(id: post.userId), at: 0)
            root.participants = participants
            scheduleProfileLoad(for: post.userId)
        }
        replace(root)
        return .patched
    }

    /// `thread_updated`: the server's own recomputation of a thread, which is exact — the count it
    /// carries is what the reply line must show, and its participant list is ordered by activity.
    private func applyThread(_ thread: MMThread) -> EventOutcome {
        guard var root = postsByID[thread.id] else { return .ignored }
        root.replyCount = max(0, thread.replyCount)
        root.lastReplyAt = max(root.lastReplyAt, thread.lastReplyAt)
        if !thread.participants.isEmpty {
            root.participants = thread.participants
            let missing = thread.participants.map(\.id).filter { users[$0] == nil }
            if !missing.isEmpty {
                Task { [weak self] in
                    guard let self else { return }
                    await self.loadProfiles(for: missing)
                    self.rebuild()
                }
            }
        }
        replace(root)
        return .patched
    }

    /// Patch a root's reply activity from outside the socket path — the thread pane's own count after
    /// a reply it sent or observed (so the two panes cannot disagree about the same thread).
    func applyReplyActivity(rootID: String,
                            count: Int,
                            lastReplyAt: Int64,
                            participants: [MMUser]? = nil) {
        guard var root = postsByID[rootID] else { return }
        root.replyCount = max(0, count)
        root.lastReplyAt = max(root.lastReplyAt, lastReplyAt)
        if let participants, !participants.isEmpty { root.participants = participants }
        replace(root)
        rebuild()
    }

    /// Mark a post deleted the one way this client does it: keep the row, empty it, and let the row
    /// draw "This message was deleted". The socket's `post_deleted` and the composer's own delete use
    /// **the same** function, so a message deleted from this device and one deleted from another
    /// device land in the same state and the second event becomes a no-op (`replace` keeps the slot).
    private func applyTombstone(_ post: MMPost) {
        var tombstone = postsByID[post.id] ?? post
        tombstone.deleteAt = post.deleteAt > 0 ? post.deleteAt : Int64(now().timeIntervalSince1970 * 1000)
        tombstone.message = ""
        tombstone.fileIds = []
        tombstone.props = nil
        tombstone.metadata = nil
        replace(tombstone)
    }

    // MARK: - The composer's writes (T35, S14)

    /// Show the composer's optimistic row. Its id is the client's `pending:<uuid>` and its
    /// `pendingPostId` is that same string, which is the key the server echoes back.
    ///
    /// A reply is deliberately not inserted (the composer does not call this for one): a reply is not
    /// a row of this channel (`isTimelineRow`), so an optimistic row for it could never be reconciled
    /// here and would be a permanent phantom. The thread pane (S13/T36) draws its own.
    func insertPendingPost(_ post: MMPost) {
        guard !post.id.isEmpty, post.channelId == channelID, post.rootId.isEmpty else { return }
        if let index = posts.firstIndex(where: { $0.id == post.id }) {
            posts[index] = post
        } else {
            posts.append(post)
        }
        postsByID[post.id] = post
        posts = Self.sortedNewestFirst(posts)
        pendingPostIDs.insert(post.id)
        if !post.pendingPostId.isEmpty { pendingRowIDs[post.pendingPostId] = post.id }
        // The author of an optimistic row is the signed-in user, whose profile the pane may never have
        // fetched (it only loads the authors of posts the server sent).
        scheduleProfileLoad(for: post.userId)
        rebuild()
    }

    /// The REST answer landed: replace the optimistic row with the server's post.
    func confirmPendingPost(id pendingID: String, with post: MMPost) {
        let rowID = pendingRowIDs[pendingID] ?? pendingID
        if !post.id.isEmpty {
            pendingRowIDs[pendingID] = post.id
            pendingResolvedPosts[pendingID] = post
        }
        pendingPostIDs.remove(rowID)
        let showsInChannel = post.rootId.isEmpty && post.channelId == channelID && !post.id.isEmpty
        if rowID != post.id { removeRow(rowID) }
        guard showsInChannel else {
            // A reply sent from this pane's composer: not a row here, but the root it answers is.
            if !post.rootId.isEmpty, postsByID[post.rootId] != nil {
                _ = recordReply(post, delta: 1)
            }
            rebuild()
            return
        }
        if postsByID[post.id] != nil {
            replace(post)
        } else {
            posts.append(post)
            postsByID[post.id] = post
            posts = Self.sortedNewestFirst(posts)
            scheduleProfileLoad(for: post.userId)
        }
        rebuild()
    }

    /// The send failed: take the optimistic row away. The text stays in the composer (T35).
    func removePendingPost(id pendingID: String) {
        let rowID = pendingRowIDs[pendingID] ?? pendingID
        pendingRowIDs[pendingID] = nil
        pendingPostIDs.remove(rowID)
        removeRow(rowID)
        rebuild()
    }

    /// An edit the composer saved. A post outside the loaded window is simply not here to patch — the
    /// server has it, and the next page load draws it correctly.
    func replacePost(_ post: MMPost) {
        guard postsByID[post.id] != nil else { return }
        replace(post)
        rebuild()
    }

    /// A delete the composer made: the same tombstone the socket's `post_deleted` produces, so the row
    /// keeps its slot and the socket echo (if any) becomes a no-op.
    func tombstonePost(id: String) {
        guard let post = postsByID[id] else { return }
        applyTombstone(post)
        rebuild()
    }

    /// Did a post with this client id arrive anyway? A failed request whose message did land is the one
    /// case where a blind retry would post twice; the composer asks this before it re-sends.
    ///
    /// A row that is **still pending** is not a landed post: it is this device's own optimistic row,
    /// and answering "yes" for it would make every retry a no-op that silently drops the message.
    func post(withPendingID pendingID: String) -> MMPost? {
        if let resolved = pendingResolvedPosts[pendingID] { return resolved }
        guard let rowID = pendingRowIDs[pendingID], !pendingPostIDs.contains(rowID) else {
            return nil
        }
        return postsByID[rowID]
    }

    /// Diagnostics/tests: the ids currently drawn as "Sending…".
    var pendingRowIDsForTests: Set<String> { pendingPostIDs }

    /// The socket echo of a send this app started: one row, in the server's own order.
    ///
    /// Two orders are possible and both must end with exactly one row:
    ///  - REST first (`confirmPendingPost` already replaced the row and remembered `post.id`), then the
    ///    echo arrives with the same id → replace, never append;
    ///  - socket first (the echo beats the REST answer) → the pending row is withdrawn and the server's
    ///    post takes its place; the REST answer then finds the id already present.
    private func reconcile(pendingID: String, with post: MMPost) {
        let rowID = pendingRowIDs[pendingID] ?? pendingID
        pendingPostIDs.remove(rowID)
        if !post.id.isEmpty {
            pendingRowIDs[pendingID] = post.id
            pendingResolvedPosts[pendingID] = post
        }
        let showsInChannel = post.rootId.isEmpty && post.channelId == channelID && !post.id.isEmpty
        if rowID == post.id {
            if showsInChannel { replace(post) } else { removeRow(rowID) }
            return
        }
        removeRow(rowID)
        guard showsInChannel else {
            if !post.rootId.isEmpty, postsByID[post.rootId] != nil {
                _ = recordReply(post, delta: 1)
            }
            return
        }
        if postsByID[post.id] != nil {
            replace(post)
        } else {
            posts.append(post)
            postsByID[post.id] = post
            posts = Self.sortedNewestFirst(posts)
            scheduleProfileLoad(for: post.userId)
        }
    }

    private func removeRow(_ id: String) {
        postsByID[id] = nil
        posts.removeAll { $0.id == id }
    }

    // MARK: - Reactions (rendered here, added/removed by S16/T37)

    // MARK: Write path (T37)

    /// T37: the host side of the reaction write.
    ///
    /// `ReactionCoordinator` calls this for its optimistic apply and its rollback, and the socket
    /// handler above calls the same function for `reaction_*` — so a tap and a server event mutate the
    /// post through **one** rule. That rule is set-shaped (this user's reaction on this emoji is
    /// present or not), which is why a socket echo of our own write cannot double the count.
    @discardableResult
    func applyReaction(_ reaction: MMReaction, adding: Bool) -> Bool {
        let changed = adding ? appendReaction(reaction) : removeReaction(reaction)
        // `items` is derived from the stored posts, so a write that only mutated the store would leave
        // the pill drawing the old count until some unrelated rebuild (the socket path rebuilds for
        // itself; an optimistic tap has no such caller).
        if changed { rebuild() }
        return changed
    }

    /// The profiles the reactor sheet draws — the same ones the rows already resolved.
    var reactionUserProfiles: [String: MMUser] { users }

    /// The reactor sheet asks for the names it does not hold yet: one batched `/users/ids`.
    func loadReactionProfiles(for userIDs: [String]) async {
        await loadProfiles(for: userIDs)
    }

    /// The pane's reaction writes. Created on first use: a channel where nobody reacts (and where no
    /// socket event about a reaction ever arrives) never builds one.
    private var reactionCoordinator: ReactionCoordinator?

    var reactions: ReactionCoordinator {
        if let reactionCoordinator { return reactionCoordinator }
        // The closures keep the pane's own service seam (`ChannelServing`), so a test stub that
        // implements the write half drives the real coordinator.
        let coordinator = ReactionCoordinator(
            add: { [weak self] postID, emoji, userID in
                guard let self else { throw MMError.notSignedIn }
                return try await self.service.addReaction(postID: postID, emojiName: emoji,
                                                          userID: userID)
            },
            remove: { [weak self] postID, emoji, userID in
                guard let self else { throw MMError.notSignedIn }
                try await self.service.removeReaction(postID: postID, emojiName: emoji,
                                                      userID: userID)
            },
            target: self,
            onReactionAdded: { [weak self] name in self?.onEmojiUsed?(name) })
        // The pill is a row of this list, so the coordinator's published state (a failure banner, a
        // rollback) has to reach the list: forward its change notifications as ours.
        coordinator.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        reactionCoordinator = coordinator
        return coordinator
    }

    /// Called after a react succeeded, so the picker's "recently used" row records what was used.
    var onEmojiUsed: ((String) -> Void)?

    /// Tap a reaction pill: optimistic toggle, then the write.
    @discardableResult
    func toggleReaction(postID: String, emojiName: String) -> Bool {
        reactions.toggle(postID: postID, emojiName: emojiName)
    }

    /// After a page merge the server's copy of a post is the strongest truth: align the write machine
    /// with it for the pairs it is tracking. A window with no reaction writes in flight is untouched.
    private func adoptReactionState(for posts: [MMPost]) {
        guard let reactionCoordinator, !reactionCoordinator.toggles.toggles.isEmpty else { return }
        for post in posts { reactionCoordinator.adoptServerState(postID: post.id) }
    }

    // MARK: Applying one reaction to the window

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
    /// Two things move content under the reader: an older page is prepended above, and a fold toggle
    /// changes the height of the row that was tapped. Both record a *viewport-relative* distance
    /// (`ScrollAnchor.offsetFromTop`), so the same restore serves both.
    func requestScrollRestore(_ anchor: ScrollAnchor?) {
        guard let anchor else { return }
        scrollAnchor = anchor
        pendingScrollRestore = anchor
    }

    /// The view calls this once it has scrolled back, so the anchor is not applied twice.
    func consumeScrollRestore() {
        pendingScrollRestore = nil
    }

    /// The view's record of the restore it just performed (see `lastScrollRestore`).
    func recordScrollRestore(_ report: ScrollRestoreReport) {
        lastScrollRestore = report
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

    // MARK: - Jumping to one post (T39)

    /// Land on one post: scroll to it when the window holds it, otherwise **fetch it** and merge it.
    ///
    /// That fetch is what makes "jump to a search result in a channel that was never opened" work: the
    /// pane's first page is the newest 60 posts, and a result can be far older. The merged post is one
    /// row at the older end of the window, and the list is **not** contiguous there: the messages
    /// between it and the newest page were never fetched, so `PostListDerivation` draws a `.gap`
    /// separator at that boundary instead of pretending the two blocks touch (T39-AV F2).
    ///
    /// A **reply** cannot be a row here at all (`isTimelineRow` keeps replies out of a thread-collapsed
    /// timeline), so its jump is its thread: `threadJumpRootID` tells the view to open the thread pane,
    /// which is where the reply is actually drawn.
    func focus(postID: String) async {
        guard !postID.isEmpty else { return }
        focusError = nil
        if let post = postsByID[postID] {
            if post.rootId.isEmpty {
                jumpTarget = postID
                focusedPostID = postID
            } else {
                threadJumpRootID = post.rootId
            }
            return
        }
        do {
            let fetched = try await service.post(id: postID)
            guard fetched.channelId == channelID else {
                focusError = "That message belongs to a different channel."
                return
            }
            guard fetched.rootId.isEmpty else {
                threadJumpRootID = fetched.rootId
                return
            }
            mergeJumpedPost(fetched)
            jumpTarget = postID
            focusedPostID = postID
        } catch {
            focusError = Self.focusMessage(for: error)
        }
    }

    /// The view has scrolled to `jumpTarget`: clear it so a re-render does not scroll again.
    func consumeJump() {
        jumpTarget = nil
    }

    /// The view opened the thread a reply jump asked for: clear the request.
    func consumeThreadJump() {
        threadJumpRootID = nil
    }

    /// Drop the marking bar (the reader moved to another post or channel).
    func clearFocus() {
        focusedPostID = nil
    }

    /// A pin/unpin written from the pinned sheet: flip the row **in place**, no refetch.
    ///
    /// This is the card's "un-pinning updates in place": the sheet writes, the channel's own row learns
    /// the new state from the same call, and neither screen reloads a page to find it out.
    func applyPin(postID: String, isPinned: Bool) {
        guard var post = postsByID[postID], post.isPinned != isPinned else { return }
        post.isPinned = isPinned
        replace(post)
        rebuild()
    }

    /// T48: the thread's follow state moved for this root — my write from the row menu, or another
    /// client's (`thread_follow_changed`). The row draws no follow badge today, but the **menu**
    /// derives Follow/Unfollow from `is_following`, so keeping the post honest is what makes a second
    /// client's change move the sheet without a reload.
    func applyFollow(rootID: String, isFollowing: Bool) {
        guard var post = postsByID[rootID], post.isFollowing != isFollowing else { return }
        post.isFollowing = isFollowing
        replace(post)
        rebuild()
    }

    private func mergeJumpedPost(_ post: MMPost) {
        guard postsByID[post.id] == nil else { return }
        posts.append(post)
        postsByID[post.id] = post
        posts = Self.sortedNewestFirst(posts)
        // The floor is intentionally untouched: this post joins the window from outside it, so the
        // derivation keeps a `.gap` between it and the contiguous block (`contiguousFloorCreateAt`).
        rebuild()
        // The jumped-to author may never have been on screen; without a profile the row would read
        // "Unknown user" even though the post is the one the reader asked for.
        scheduleProfileLoad(for: post.userId)
    }

    static func focusMessage(for error: Error) -> String {
        // A missing post is the common case (deleted between the search and the tap) and deserves its
        // own sentence rather than "the channel could not be loaded".
        if case MMError.notFound = error {
            return "That message no longer exists on the server."
        }
        return MMErrorCopy.message(for: error,
                                   offline: "You are offline. This message will open when the connection is back.",
                                   timeout: "The server did not answer in time.",
                                   unauthorized: "Your session has expired. Sign in again to open this message.",
                                   forbidden: "You do not have permission to read this message.",
                                   notFound: "That message no longer exists on the server.",
                                   rateLimited: "The server is rate limiting this app. Try again shortly.",
                                   fallback: "That message could not be opened.")
    }

    // MARK: - Derivation

    private func rebuild() {
        items = PostListDerivation.items(posts: posts,
                                         users: users,
                                         myUserID: myUserID,
                                         lastViewedAt: lastViewedAt,
                                         expandedPostIDs: expandedPostIDs,
                                         pendingPostIDs: pendingPostIDs,
                                         contiguousFloorCreateAt: contiguousFloorCreateAt,
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
    /// **`has_next` is not trustworthy on this endpoint.** Measured on the pinned server (Mattermost
    /// 9.11.19, `perf-feed`, 503 posts): `GET /channels/{id}/posts?per_page=60` answers
    /// `has_next: false` on *every* page — the first one included — while `before=<oldest>` keeps
    /// answering the next 60 with no overlap. Trusting it stopped paging after one page and left the
    /// sentinel saying "This is the beginning of the channel" with 440 posts still unread (T34-R3:
    /// found by the live suite, `has_next` was false on the first of six pages).
    ///
    /// So the page length is the only signal: a full page means "ask again", and a short or empty page
    /// ends the window. A full page that happens to be the last one costs exactly one more request,
    /// which `loadEarlier` turns into `hasMore = false` when nothing fresh comes back.
    static func morePages(after page: MMPostList, pageSize: Int) -> Bool {
        page.order.count >= pageSize
    }

    static func message(for error: Error) -> String {
        MMErrorCopy.message(for: error,
                            offline: "You are offline. This channel will load when the connection is back.",
                            timeout: "The server did not answer in time.",
                            unauthorized: "Your session has expired. Sign in again to read this channel.",
                            forbidden: "You do not have permission to read this channel.",
                            notFound: "This channel no longer exists.",
                            rateLimited: "The server is rate limiting this app. Try again shortly.",
                            fallback: "The channel could not be loaded.")
    }
}

// MARK: - ReactionTarget (S16/T37)

/// The channel pane is one of the two hosts a reaction write can target. Nothing is added here: the
/// conformance is the statement that the *existing* window (its `post(id:)`, its socket patch and its
/// profile cache) is what the coordinator drives, rather than a second copy of the message state.
extension ChannelViewModel: ReactionTarget {}
