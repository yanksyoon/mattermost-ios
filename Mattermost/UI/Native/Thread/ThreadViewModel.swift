// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/thread/thread_post_list/thread_post_list.tsx (root + replies as one list,
//        `onEndReached` paging with `fromPost`/`fromCreateAt`, mark-read on mount and on a new reply
//        while the pane is open), app/actions/websocket/threads.ts (`thread_updated`,
//        `thread_follow_changed`, `thread_read_changed` applied to the open thread),
//        app/actions/remote/thread.ts (`updateThreadFollowing`, `markThreadAsRead`/`Unread`).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §13; no
// upstream source copied. The model shape is this repo's own (docs/component-map.md §1), mirroring
// `ChannelViewModel`: a generation-guarded load, a service seam, socket patch rules that a test pins.
//
// What this object owns, and what it deliberately does not:
//  - it owns **one thread's chain** (root + replies), its page cursor, its follow state, its unread
//    counters and the socket reconciliation for that thread;
//  - the composer (send/edit/delete/uploads/drafts) is T35's `ComposerViewModel`; this model is only
//    its `ComposerPostSink`, so a reply is drawn optimistically here and reconciled by the server's
//    answer exactly like a channel post is in `ChannelViewModel`;
//  - the channel timeline is not touched directly: a reply count change is published through
//    `onReplyActivity` so the pane that owns the root row patches it (one writer per row).

import Foundation
import Combine

/// One thread: load its chain, keep it current from the socket, follow/unfollow, track unread.
@MainActor
final class ThreadViewModel: ObservableObject, ComposerPostSink {

    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// Whether this client follows the thread. `unknown` until the server has answered (a 404 from
    /// `GET …/threads/{id}` means "not following", so the state is only unknown for one round trip).
    enum FollowState: Equatable {
        case unknown
        case following
        case notFollowing

        var isFollowing: Bool { self == .following }
    }

    /// What one socket event did to this thread.
    enum EventOutcome: Equatable {
        case ignored
        case appended
        case patched
        case deleted
        case reactions
        case following
        case unread
    }

    // MARK: Identity

    let rootID: String
    /// The root post's channel. Known up front when the pane is opened from the channel timeline;
    /// empty when it is opened from a link or the global list, and filled in from the root post the
    /// thread endpoint returns (the composer needs it to post a reply).
    private(set) var channelID: String
    let teamID: String

    // MARK: Published state

    @Published private(set) var phase: Phase = .idle
    /// The rendered chain: date separators, the unread divider, and one row per post.
    @Published private(set) var items: [PostListItem] = []
    @Published private(set) var root: MMPost?
    @Published private(set) var replyCount: Int = 0
    @Published private(set) var participants: [PostAuthor] = []
    @Published private(set) var followState: FollowState = .unknown
    @Published private(set) var unread: ThreadUnread = .none
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasMore = false
    @Published private(set) var loadEarlierError: String?
    /// The posts the reader expanded ("Show more").
    @Published private(set) var expandedPostIDs: Set<String> = []
    /// The last socket event's effect (diagnostics/tests; never rendered).
    @Published private(set) var lastEventOutcome: EventOutcome = .ignored
    /// True once the pane has asked the server to mark this thread read.
    @Published private(set) var didMarkRead = false

    /// How many gap sweeps this pane ran, and how many replies the last one inserted.
    ///
    /// Diagnostics and tests, the same pair `ChannelViewModel` carries: "never resyncs" and "resyncs
    /// on every gap" look identical on screen until one of them is counted, and the difference is what
    /// a lost reply costs. A failed refetch counts as an attempt (`lastResyncInsertedCount` stays 0);
    /// only the phase and the chain are left alone, because the rows on screen are still the server's
    /// page as of the last load.
    private(set) var resyncCount = 0
    private(set) var lastResyncInsertedCount = 0

    var isFollowing: Bool { followState == .following }

    /// The root's author as the composer's reply banner names them ("Replying to Ana").
    var rootAuthorLabel: String {
        guard let root else { return "" }
        return PostListDerivation.author(for: root, users: users).displayName
    }

    /// The root's own `PostRowModel`, for the thread header (its avatar and time).
    var rootRow: PostRowModel? {
        if case .post(let row)? = items.first(where: { $0.postID == rootID }) { return row }
        return nil
    }

    /// Diagnostics/tests.
    var loadedCount: Int { replies.count }
    var loadedReplyIDs: [String] { replies.map(\.id) }
    var lastLoadedReplyID: String? { replies.last?.id }
    func reply(id: String) -> MMPost? { repliesByID[id] }
    /// The post the pane's unread divider is drawn in front of (`nil` when there is no divider).
    /// Diagnostics/tests: the line is an item between rows, so a test that asks "where is the divider"
    /// should not have to re-implement the list walk.
    var unreadDividerPostID: String? {
        guard let index = items.firstIndex(of: .newMessages), items.indices.contains(index + 1) else {
            return nil
        }
        return items[index + 1].postID
    }

    // MARK: Collaborators

    private let service: ThreadServing
    private let now: () -> Date
    private let calendar: Calendar
    private let locale: Locale
    /// The session user, as the reaction write needs it (S16/T37: a react is always mine).
    let myUserID: String?

    /// Publishes a reply-count change to the pane that owns the root row (the channel timeline).
    /// Called with the root id, the count to draw and the thread's newest reply instant.
    var onReplyActivity: ((String, Int, Int64) -> Void)?

    // MARK: Private state

    private var replies: [MMPost] = []
    private var repliesByID: [String: MMPost] = [:]
    /// Profiles for the chain (and, for T37, the reactor sheet).
    private(set) var users: [String: MMUser] = [:]
    /// The thread row the server answered (`GET …/threads/{id}`), when it answered at all.
    private var threadRow: MMThread?
    /// Where the unread divider goes: `thread_row.last_viewed_at`, or the value a `thread_read_changed`
    /// frame carried. `nil` = unknown, so no divider is invented.
    ///
    /// This is the *server's* read position — the one the unread counters are about. It is **not**
    /// what the pane's divider is drawn from; see `dividerViewedAt`.
    private var lastViewedAt: Int64?
    /// The read position the pane's unread divider is drawn from — upstream's `thread.viewed_at`,
    /// which is deliberately a different value from the thread's `last_viewed_at`
    /// (`app/database/models/server/thread.ts:43` vs `:58`; `thread_post_list.tsx:89` reads
    /// `thread?.viewedAt`).
    ///
    /// Taken **once**, when the thread row arrives with the load, from its `last_viewed_at`: where the
    /// reader left off, so the line sits in front of the first reply they have not read. It is not
    /// moved by this pane's own read — `markRead` on mount answers a thread whose `last_viewed_at` is
    /// *now*, and upstream skips `viewed_at` for a thread that is on screen
    /// (`isThreadVisible` in `app/actions/websocket/threads.ts`). Without that rule the divider exists
    /// only for the frames between the load and the read answer, which is unobservable in the app and
    /// unassertable in a live test. It moves only when the read position changes **outside** this
    /// pane: a whole-team mark-read, or "mark as unread" (which stamps one millisecond before that
    /// post, `app/actions/remote/thread.ts` `markThreadAsUnread`).
    private var dividerViewedAt: Int64?
    /// Whether `dividerViewedAt` has been taken from a thread row yet. A thread the reader does not
    /// follow has no row, so no read position — and therefore no divider.
    private var hasTakenDividerPosition = false
    /// Rows the composer inserted optimistically (`pending:<uuid>`).
    private var pendingReplyIDs: Set<String> = []
    /// Client id → the row id currently representing it.
    private var pendingRowIDs: [String: String] = [:]
    /// Client id → the server's post, once it is known (for "did the retry already land?").
    private var pendingResolvedPosts: [String: MMPost] = [:]
    private var generation = 0
    /// Subscriptions that forward a collaborator's published state as this model's (T37: the reaction
    /// coordinator's failure banner and rollback).
    private var cancellables = Set<AnyCancellable>()

    // MARK: Init

    init(rootID: String,
         channelID: String,
         teamID: String,
         service: ThreadServing,
         myUserID: String? = nil,
         now: @escaping () -> Date = { Date() },
         calendar: Calendar = .current,
         locale: Locale = .current) {
        self.rootID = rootID
        self.channelID = channelID
        self.teamID = teamID
        self.service = service
        self.myUserID = myUserID
        self.now = now
        self.calendar = calendar
        self.locale = locale
    }

    // MARK: - Loading

    func load(ifNeeded: Bool = true) async {
        if ifNeeded, phase == .loaded { return }
        await performInitialLoad()
    }

    func reload() async { await performInitialLoad() }
    func retry() async { await performInitialLoad() }

    private func performInitialLoad() async {
        guard !rootID.isEmpty else {
            phase = .failed("No thread is selected.")
            return
        }
        generation += 1
        let requested = generation
        phase = .loading
        loadEarlierError = nil
        do {
            let page = try await service.thread(postID: rootID, fromPost: nil,
                                                fromCreateAt: nil, perPage: service.pageSize)
            guard requested == generation else { return }
            let ordered = page.orderedPosts
            // The endpoint always carries the root; a defensive fallback keeps a proxy that strips
            // it from turning the pane into an empty screen.
            var loadedRoot = page.posts[rootID] ?? ordered.first(where: { $0.id == rootID })
            if loadedRoot == nil {
                loadedRoot = try? await service.post(id: rootID)
            }
            guard let loadedRoot else { throw MMError.notFound }
            root = loadedRoot
            if channelID.isEmpty { channelID = loadedRoot.channelId }
            replies = ThreadDerivation.chain(root: loadedRoot,
                                             replies: ordered.filter { $0.id != rootID })
                .dropFirst().map { $0 }
            repliesByID = Dictionary(uniqueKeysWithValues: replies.map { ($0.id, $0) })
            hasMore = page.order.count >= service.pageSize
            replyCount = ThreadDerivation.replyCount(root: loadedRoot, replies: replies,
                                                     serverCount: max(loadedRoot.replyCount, replies.count))
            await loadThreadRow()
            guard requested == generation else { return }
            await loadProfiles(for: Set(replies.map(\.userId))
                .union((root?.participants ?? []).map(\.id))
                .union([loadedRoot.userId]))
            guard requested == generation else { return }
            rebuild()
            phase = .loaded
        } catch {
            guard requested == generation else { return }
            phase = .failed(Self.message(for: error))
        }
    }

    /// The thread row (follow state + unread counters). A 404 is the server's way of saying "you do
    /// not follow this thread", so it is an answer, not a failure; any other error leaves the state
    /// unknown rather than claiming "not following".
    private func loadThreadRow() async {
        do {
            let row = try await service.followedThread(teamID: teamID, threadID: rootID)
            threadRow = row
            if let row {
                followState = .following
                unread = row.unread
                lastViewedAt = row.lastViewedAt
                takeDividerPosition(row.lastViewedAt)
                replyCount = ThreadDerivation.replyCount(root: root ?? MMPost(id: rootID),
                                                         replies: replies,
                                                         serverCount: max(row.replyCount, replyCount))
            } else {
                followState = .notFollowing
                unread = .none
                lastViewedAt = nil
            }
        } catch {
            threadRow = nil
            followState = .unknown
        }
    }

    private func loadProfiles(for ids: Set<String>) async {
        // A stored **stub** does not count as known (`MMUser.hasProfileDetails`). Filtering on
        // `users[$0] == nil` meant an id-only participant — which `apply(thread:)` stored from a
        // `thread_updated` frame's `participants` — blocked the very request that would have named
        // the reply's author, leaving a blank, 0×0 name button (t_e73f31ce).
        let wanted = ProfileBatch.clean(Array(ids)).filter { users[$0]?.hasProfileDetails != true }
        guard !wanted.isEmpty else { return }
        let report = await ProfileBatch.load(wanted, fetch: { [service] chunk in
            try await service.users(ids: chunk)
        }, onProfiles: { [weak self] loaded in
            guard let self else { return }
            for user in loaded { self.users[user.id] = user }
        })
        if let error = report.error {
            Logger.error("ThreadProfiles", "\(report.line(pane: "thread=\(rootID)")) reason=\(error)")
        }
    }

    /// Load one older page of replies (the end of the chain is the newest, so "more" grows forward).
    @discardableResult
    func loadEarlier() async -> Bool {
        guard phase == .loaded, hasMore, !isLoadingMore, let last = replies.last else { return false }
        isLoadingMore = true
        loadEarlierError = nil
        defer { isLoadingMore = false }
        let requested = generation
        do {
            let page = try await service.thread(postID: rootID,
                                                fromPost: last.id,
                                                fromCreateAt: last.createAt,
                                                perPage: service.pageSize)
            guard requested == generation else { return false }
            let incoming = page.orderedPosts.filter { $0.id != rootID }
            let before = replies.count
            replies = ThreadDerivation.merge(existing: replies, page: incoming, rootID: rootID)
            for reply in replies { repliesByID[reply.id] = reply }
            let grew = replies.count > before
            // A page that carried the root only means the chain ended exactly at the page boundary.
            hasMore = grew && page.order.count >= service.pageSize
            guard grew else { return false }
            await loadProfiles(for: Set(incoming.map(\.userId)))
            guard requested == generation else { return false }
            replyCount = ThreadDerivation.replyCount(root: root ?? MMPost(id: rootID),
                                                     replies: replies, serverCount: replyCount)
            rebuild()
            return true
        } catch {
            guard requested == generation else { return false }
            loadEarlierError = Self.message(for: error)
            return false
        }
    }

    /// Repair this chain after a socket gap (a reconnect, or a delivery stall the watchdog confirmed).
    ///
    /// The seam is the same one the channel pane uses (`TeamSidebarCoordinator.onSocketResync`), and
    /// the rule is the same rule T34-R5 chose there: **merge, never reload**. Joining the seam with
    /// `reload()` would blank the reader's chain to a spinner on every reconnect and every confirmed
    /// stall, and would drop every older page `loadEarlier()` had fetched.
    ///
    /// What it does, and what it deliberately does not:
    ///  - it refetches the **newest page** of `GET /posts/{root}/thread` and merges it: a reply it does
    ///    not hold is inserted, a reply it holds is replaced by the server's copy (an edit made while
    ///    the socket was down), and **nothing is dropped** — the older pages the reader scrolled back
    ///    through stay exactly where they were;
    ///  - a reply the pane holds as a **tombstone** stays a tombstone: the server omits deleted posts
    ///    from later fetches (measured), so "the server no longer returns it" can never mean "undraw
    ///    it" — the same rule `ThreadDerivation.chain` states;
    ///  - it refreshes the root post, the server's `reply_count` / `last_reply_at`, and the
    ///    follow/unread row, adopting a `last_viewed_at` that moved **forward** only (the thread was
    ///    read on another client). The divider's own position is not touched: it is taken once, when
    ///    the pane opens (`dividerViewedAt`), so a repaint can never slide the line the reader is
    ///    looking at;
    ///  - it leaves `phase` alone: the chain on screen is still the server's page as of the last load,
    ///    so a failed sweep costs a retry on the next gap, not an error screen;
    ///  - it is a no-op on a pane that never loaded (its first load is the fetch).
    ///
    /// Returns how many replies were added (`0` when the chain was already current or the request
    /// failed).
    @discardableResult
    func resyncAfterGap() async -> Int {
        guard phase == .loaded else { return 0 }
        let requested = generation
        // Counted before the request: a diagnostic needs to see the attempt, and a refetch that fails
        // is still a refetch the app made.
        resyncCount += 1
        lastResyncInsertedCount = 0
        do {
            let page = try await service.thread(postID: rootID, fromPost: nil,
                                                fromCreateAt: nil, perPage: service.pageSize)
            guard requested == generation else { return 0 }
            let ordered = page.orderedPosts
            let held = Set(replies.map(\.id))
            // A held tombstone is never replaced by a server copy: the endpoint omits deleted posts,
            // so a copy of one can only be a stale read that would resurrect the row.
            let tombstones = Set(replies.filter { $0.deleteAt > 0 }.map(\.id))
            let incoming = ordered.filter { $0.id != rootID && !tombstones.contains($0.id) }
            replies = ThreadDerivation.merge(existing: replies, page: incoming, rootID: rootID)
            for reply in replies { repliesByID[reply.id] = reply }
            let inserted = replies.filter { !held.contains($0.id) }

            let serverRoot = page.posts[rootID] ?? ordered.first(where: { $0.id == rootID })
            if let serverRoot, serverRoot.deleteAt == 0 {
                // The root the server returns is the truth for its body, `reply_count` and
                // `last_reply_at`; the count is re-derived below once the row has answered too.
                var merged = serverRoot
                merged.replyCount = max(serverRoot.replyCount, replyCount)
                merged.lastReplyAt = max(serverRoot.lastReplyAt, root?.lastReplyAt ?? 0)
                root = merged
                if channelID.isEmpty { channelID = serverRoot.channelId }
            }

            await loadProfiles(for: Set(inserted.map(\.userId))
                .union((root?.participants ?? []).map(\.id)))
            guard requested == generation else { return 0 }
            await refreshThreadRowAfterGap()
            guard requested == generation else { return 0 }

            replyCount = ThreadDerivation.replyCount(root: root ?? MMPost(id: rootID),
                                                     replies: replies, serverCount: replyCount)
            if var current = root {
                // The thread row's `last_reply_at` is the server's statement about the chain even when
                // the root post the page carried lags behind it.
                current.replyCount = replyCount
                current.lastReplyAt = max(current.lastReplyAt, threadRow?.lastReplyAt ?? 0)
                root = current
            }
            rebuild()
            notifyReplyActivity()
            lastResyncInsertedCount = inserted.count
            return inserted.count
        } catch {
            return 0
        }
    }

    /// Re-read the follow/unread row for a gap sweep.
    ///
    /// Different from `loadThreadRow()` in two ways that matter for a repair: a **404 is an answer**
    /// (the thread was unfollowed, on this device or another, while the socket was down) and moves the
    /// state to "not following"; a **failed request** is not an answer and leaves the row's state as
    /// the last read stated it — a sweep must never turn a known "Following" into "unknown".
    private func refreshThreadRowAfterGap() async {
        do {
            let row = try await service.followedThread(teamID: teamID, threadID: rootID)
            guard let row else {
                threadRow = nil
                followState = .notFollowing
                unread = .none
                return
            }
            threadRow = row
            followState = .following
            unread = row.unread
            lastViewedAt = max(lastViewedAt ?? 0, row.lastViewedAt)
            replyCount = ThreadDerivation.replyCount(root: root ?? MMPost(id: rootID),
                                                     replies: replies,
                                                     serverCount: max(row.replyCount, replyCount))
        } catch {
            // Leave the state exactly as it was.
        }
    }

    // MARK: - Follow / read state

    /// Follow or unfollow. Optimistic, and reverted with a message when the server refuses: a button
    /// that keeps a state the server rejected is worse than a button that flickers.
    func toggleFollow() async {
        let target: Bool
        switch followState {
        case .following: target = false
        case .notFollowing: target = true
        case .unknown: target = true       // the only honest guess: the reader asked to follow
        }
        let previous = followState
        let previousUnread = unread
        followState = target ? .following : .notFollowing
        if !target { unread = .none }
        do {
            try await service.setFollowing(teamID: teamID, threadID: rootID, following: target)
            // Re-read: the follow write answers only "OK", and the row is the only place the server
            // states the follow state (a 404 for "no").
            await loadThreadRow()
            rebuild()
        } catch {
            followState = previous
            unread = previousUnread
            rebuild()
            lastEventOutcome = .ignored
        }
    }

    /// Mark this thread read now (the pane calls this when it appears, and again when a reply lands
    /// while it is on screen). Only a followed thread has a read state to move — the endpoint is the
    /// followed-thread one, measured to answer for any thread row the user owns.
    func markRead() async {
        guard !didMarkRead || !unread.isUnread else { return }
        let timestamp = Int64(now().timeIntervalSince1970 * 1000)
        do {
            let updated = try await service.markRead(teamID: teamID, threadID: rootID, at: timestamp)
            apply(thread: updated)
            didMarkRead = true
            // A thread the reader opened is one they are following in the thread list sense: the
            // server's row now exists, so the follow button must say "Following" even if it was
            // unknown when the pane opened.
            if followState == .unknown, updated.id == rootID { followState = .following }
            rebuild()
        } catch {
            // Reading is a side effect of looking; a failure must not replace the thread with an
            // error screen. The unread badge simply stays until the next visit.
        }
    }

    /// Mark the thread unread from a reply (upstream's "mark unread" action, same endpoint family).
    func markUnread(from postID: String) async {
        // Upstream stamps the *local* divider position one millisecond before the post
        // (`app/actions/remote/thread.ts` `markThreadAsUnread`: `viewed_at: post.createAt - 1`), so the
        // line appears in front of the row the reader picked without waiting for a socket frame. The
        // server's answer then carries the counters; its `last_viewed_at` is not what draws the line.
        if let post = repliesByID[postID] ?? (root?.id == postID ? root : nil) {
            hasTakenDividerPosition = true
            dividerViewedAt = max(0, post.createAt - 1)
        }
        do {
            let updated = try await service.markUnread(teamID: teamID, threadID: rootID, postID: postID)
            apply(thread: updated)
            rebuild()
        } catch {
            // Same reasoning as `markRead`: the thread is still readable.
        }
    }

    // MARK: - Socket

    /// Apply one event from the server's socket (already scoped to the team on screen).
    ///
    /// The rules, each pinned by a test:
    ///  - a reply to **this** root is appended once (a replay replaces), and its root's reply count
    ///    and participant stack move with it;
    ///  - an edit keeps the reply's position; a delete keeps its slot as a tombstone (the server
    ///    will omit it from any later fetch, so this is the only place the tombstone can come from);
    ///  - `thread_updated` carries the server's own thread object: it patches counters, participants
    ///    and the follow state (the frame is only sent to followers — measured);
    ///  - `thread_follow_changed` is the follow write's echo, from this device or another;
    ///  - `thread_read_changed` moves the read position and the unread counters, including the
    ///    "whole team was marked read" form (an empty `thread_id`), which clears this thread too.
    @discardableResult
    func handle(_ event: SocketEvent) -> EventOutcome {
        let outcome: EventOutcome
        switch event {
        case .posted(let post):
            if !post.pendingPostId.isEmpty, pendingRowIDs[post.pendingPostId] != nil {
                reconcile(pendingID: post.pendingPostId, with: post)
                rebuild()
                return record(.patched)
            }
            guard post.rootId == rootID else {
                // The root itself can be re-sent (a replayed `posted`), which is a patch, not a row.
                if post.id == rootID {
                    root = post
                    rebuild()
                    return record(.patched)
                }
                return record(.ignored)
            }
            if repliesByID[post.id] != nil {
                replaceReply(post)
                outcome = .patched
            } else {
                replies = ThreadDerivation.merge(existing: replies, page: [post], rootID: rootID)
                repliesByID[post.id] = post
                replyCount = ThreadDerivation.replyCount(root: root ?? MMPost(id: rootID),
                                                         replies: replies, serverCount: replyCount)
                if post.deleteAt == 0 { notifyReplyActivity() }
                scheduleProfileLoad(for: post.userId)
                outcome = .appended
            }
            if unread.isUnread == false, didMarkRead {
                // The reader is looking at the thread: a new reply must not leave an unread badge
                // behind on this device (upstream marks read on a new post while the thread is open).
                Task { await self.markRead() }
            }
        case .postEdited(let post):
            if post.id == rootID {
                root = post
                outcome = .patched
            } else if repliesByID[post.id] != nil, post.rootId == rootID {
                replaceReply(post)
                outcome = .patched
            } else {
                return record(.ignored)
            }
        case .postDeleted(let post):
            if post.id == rootID {
                // The thread's root is gone: keep the pane (and its chain) but show the tombstone.
                applyTombstoneToRoot(post)
                outcome = .deleted
            } else if let existing = repliesByID[post.id] {
                applyTombstone(existing, deleteAt: post.deleteAt)
                replyCount = max(0, replyCount - 1)
                notifyReplyActivity()
                outcome = .deleted
            } else {
                return record(.ignored)
            }
        case .reactionAdded(let reaction):
            let added = patchReaction(reaction, adding: true)
            reactions.noteSocketEvent(reaction, adding: true)
            guard added else { return record(.ignored) }
            outcome = .reactions
        case .reactionRemoved(let reaction):
            let removed = patchReaction(reaction, adding: false)
            reactions.noteSocketEvent(reaction, adding: false)
            guard removed else { return record(.ignored) }
            outcome = .reactions
        case .threadUpdated(let update):
            let thread = update.thread
            guard thread.id == rootID else { return record(.ignored) }
            apply(thread: thread)
            followState = .following
            outcome = .patched
        case .threadFollowChanged(let change):
            guard change.threadID == rootID else { return record(.ignored) }
            followState = change.state ? .following : .notFollowing
            if change.replyCount > 0 { replyCount = max(replyCount, change.replyCount) }
            if !change.state { unread = .none }
            outcome = .following
        case .threadReadChanged(let change):
            if change.threadID.isEmpty {
                // The whole team was marked read; this thread's counters move with it.
                unread = .none
                lastViewedAt = max(lastViewedAt ?? 0, change.timestamp)
                // A whole-team read happened **outside** this pane, so the divider's position moves
                // with it too (upstream `markTeamThreadsAsRead` rewrites every thread's `viewed_at`;
                // only the per-thread frame withholds that while the thread is on screen). A thread
                // this pane never had a read position for stays without a divider.
                if hasTakenDividerPosition {
                    dividerViewedAt = max(dividerViewedAt ?? 0, change.timestamp)
                }
                outcome = .unread
            } else {
                guard change.threadID == rootID else { return record(.ignored) }
                apply(readChange: change)
                outcome = .unread
            }
        case .hello, .typing, .statusChange, .preferencesChanged, .preferencesDeleted, .userUpdated,
             .sidebarCategoryUpdated, .channelCreated, .channelDeleted, .channelMemberUpdated,
             .channelUpdated, .channelRestored, .userAdded, .userRemoved,
             .channelViewed, .multipleChannelsViewed, .postUnread, .plugin, .unhandled:
            // `.plugin` frames are a plugin's own sub-protocol; the Calls engine reads them off the
            // socket itself, and a thread has nothing to do with one.
            return record(.ignored)
        }
        rebuild()
        return record(outcome)
    }

    private func record(_ outcome: EventOutcome) -> EventOutcome {
        lastEventOutcome = outcome
        return outcome
    }

    /// Take the server's thread object as the truth for counters, participants and read position.
    private func apply(thread: MMThread) {
        guard thread.id == rootID else { return }
        threadRow = thread
        replyCount = max(thread.replyCount, replyCount)
        lastViewedAt = max(lastViewedAt ?? 0, thread.lastViewedAt)
        unread = thread.unread
        if !thread.participants.isEmpty {
            // Participants are profiles in the thread endpoints (`extended=true`); keep them for the
            // avatar stack even when the chain itself is short.
            root?.participants = thread.participants
            // But a participant can also be an **id-only stub** — the non-extended form a
            // `thread_updated` frame may carry. Storing one over a real profile is what blanked a
            // reply's author name (t_e73f31ce), so a stub may only fill a hole; and any participant
            // the map still cannot name is asked for, because a stub is not "known".
            for participant in thread.participants where !participant.id.isEmpty {
                if !participant.isIdOnlyStub || users[participant.id] == nil {
                    users[participant.id] = participant
                }
            }
            scheduleProfileLoad(for: thread.participants.map(\.id))
        }
        if !thread.post.id.isEmpty {
            // The thread's own `post` is the root; its `reply_count` may lag (measured 2 vs 0), so the
            // thread's count stays authoritative and only the post body/message is taken from it.
            var merged = thread.post
            merged.replyCount = replyCount
            merged.lastReplyAt = max(thread.post.lastReplyAt, thread.lastReplyAt)
            root = merged
        }
        notifyReplyActivity()
    }

    private func apply(readChange: SocketThreadReadChanged) {
        lastViewedAt = max(lastViewedAt ?? 0, readChange.timestamp)
        unread = ThreadUnread(replies: readChange.unreadReplies,
                              mentions: readChange.unreadMentions,
                              isUrgent: unread.isUrgent)
        // The counters are the server's own, so the badge cannot drift from what the thread list
        // shows. `lastViewedAt` moves with them; `dividerViewedAt` deliberately does not — this frame
        // is the read this pane just performed (or one made while it is open), and a divider that
        // erases itself the moment it is drawn would never be seen (upstream's `isThreadVisible`
        // rule in `app/actions/websocket/threads.ts`).
    }

    private func replaceReply(_ post: MMPost) {
        guard let index = replies.firstIndex(where: { $0.id == post.id }) else { return }
        replies[index] = post
        repliesByID[post.id] = post
        notifyReplyActivity()
    }

    private func applyTombstone(_ post: MMPost, deleteAt: Int64) {
        var tombstone = post
        tombstone.deleteAt = deleteAt > 0 ? deleteAt : Int64(now().timeIntervalSince1970 * 1000)
        tombstone.message = ""
        tombstone.fileIds = []
        tombstone.props = nil
        tombstone.metadata = nil
        replaceReply(tombstone)
    }

    private func applyTombstoneToRoot(_ post: MMPost) {
        guard var tombstone = root else { return }
        tombstone.deleteAt = post.deleteAt > 0 ? post.deleteAt : Int64(now().timeIntervalSince1970 * 1000)
        tombstone.message = ""
        tombstone.fileIds = []
        tombstone.props = nil
        tombstone.metadata = nil
        root = tombstone
    }

    private func scheduleProfileLoad(for userID: String) {
        scheduleProfileLoad(for: [userID])
    }

    /// Ask the server for every id this model cannot name yet.
    ///
    /// A stored **stub** is not a name (`MMUser.hasProfileDetails`), so it does not count as known —
    /// that is the defect t_e73f31ce: an id-only participant blocked the request that would have
    /// replaced it, and a reply's author name stayed empty forever.
    private func scheduleProfileLoad(for ids: [String]) {
        let wanted = ProfileBatch.clean(ids).filter { users[$0]?.hasProfileDetails != true }
        guard !wanted.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.loadProfiles(for: Set(wanted))
            self.rebuild()
        }
    }

    // MARK: - Reactions (S16/T37)

    /// The post a reaction belongs to: the root or one of the replies.
    func post(id: String) -> MMPost? {
        if let reply = repliesByID[id] { return reply }
        if root?.id == id { return root }
        return nil
    }

    /// The host side of the write: optimistic apply, rollback and the socket patch all land here, so
    /// one tap and one server event mutate the post by the same set-shaped rule.
    @discardableResult
    func applyReaction(_ reaction: MMReaction, adding: Bool) -> Bool {
        guard let post = post(id: reaction.postId) else { return false }
        let changed = patch(reaction, on: post, adding: adding)
        // The rows are derived from the stored posts: an optimistic tap has no socket handler to
        // rebuild for it, so the pill would keep drawing the old count.
        if changed { rebuild() }
        return changed
    }

    var reactionUserProfiles: [String: MMUser] { users }

    func loadReactionProfiles(for userIDs: [String]) async {
        let ids = Set(userIDs.filter { !$0.isEmpty && users[$0]?.hasProfileDetails != true })
        guard !ids.isEmpty else { return }
        await loadProfiles(for: ids)
    }

    private var reactionCoordinator: ReactionCoordinator?

    /// The pane's reaction writes, created on first use (see `ChannelViewModel.reactions`).
    var reactions: ReactionCoordinator {
        if let reactionCoordinator { return reactionCoordinator }
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
        coordinator.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        reactionCoordinator = coordinator
        return coordinator
    }

    /// Called after a successful react, so the picker's "recently used" row records it.
    var onEmojiUsed: ((String) -> Void)?

    @discardableResult
    func toggleReaction(postID: String, emojiName: String) -> Bool {
        reactions.toggle(postID: postID, emojiName: emojiName)
    }

    private func patchReaction(_ reaction: MMReaction, adding: Bool) -> Bool {
        guard let post = post(id: reaction.postId) else { return false }
        return patch(reaction, on: post, adding: adding)
    }

    /// The set-shaped patch itself. Returns whether the post changed (a duplicate add and a missing
    /// remove are no-ops, which is what makes a socket echo of our own write harmless).
    private func patch(_ reaction: MMReaction, on existingPost: MMPost, adding: Bool) -> Bool {
        var post = existingPost
        var list = post.metadata?["reactions"]?.arrayValue ?? []
        let matches: (JSONValue) -> Bool = { value in
            let existing = try? MMRawJSON(value).decode(MMReaction.self)
            return existing?.userId == reaction.userId && existing?.emojiName == reaction.emojiName
        }
        if adding {
            guard !list.contains(where: matches) else { return false }
            if let data = try? JSONEncoder().encode(reaction),
               let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
                list.append(value)
            }
        } else {
            let before = list.count
            list.removeAll(where: matches)
            guard list.count != before else { return false }
        }
        var object = post.metadata?.objectValue ?? [:]
        object["reactions"] = .array(list)
        post.metadata = .object(object)
        if post.id == rootID {
            root = post
        } else {
            replaceReply(post)
        }
        return true
    }

    // MARK: - The composer's replies (S14/T35's sink, for a thread)

    /// This model is a thread's sink, so the composer writing into it must never leave reply mode
    /// (see `ComposerPostSink.threadAnchor`): the anchor is the root every reply carries as `root_id`.
    var threadAnchor: ComposerThreadAnchor? {
        ComposerThreadAnchor(rootID: rootID, authorLabel: rootAuthorLabel)
    }

    /// The post a reply started from `row` must carry as `root_id`, with the label the banner shows.
    ///
    /// A thread nests exactly one level, so whether the reader tapped the root or one of its replies
    /// the request's `root_id` is **this thread's root** — posting the tapped reply's own id either
    /// errors or orphans the post on the server. The label is a different thing: it names whoever was
    /// tapped, which is why the two travel together and not as one post (kanban t_56159748).
    func replyTarget(from row: PostRowModel) -> (root: MMPost, authorLabel: String)? {
        let root = row.post.id == rootID ? row.post : self.root
        guard let root else { return nil }
        return (root, row.author.displayName)
    }

    /// Show the composer's optimistic reply. Its id is the client's `pending:<uuid>` and its
    /// `pending_post_id` is that same string, which is what the server echoes back.
    func insertPendingPost(_ post: MMPost) {
        guard post.rootId == rootID, !post.id.isEmpty else { return }
        replies = ThreadDerivation.merge(existing: replies, page: [post], rootID: rootID)
        repliesByID[post.id] = post
        pendingReplyIDs.insert(post.id)
        if !post.pendingPostId.isEmpty { pendingRowIDs[post.pendingPostId] = post.id }
        scheduleProfileLoad(for: post.userId)
        rebuild()
    }

    func confirmPendingPost(id pendingID: String, with post: MMPost) {
        let rowID = pendingRowIDs[pendingID] ?? pendingID
        if !post.id.isEmpty {
            pendingRowIDs[pendingID] = post.id
            pendingResolvedPosts[pendingID] = post
        }
        pendingReplyIDs.remove(rowID)
        let belongs = post.rootId == rootID && !post.id.isEmpty
        if rowID != post.id { removeReply(rowID) }
        guard belongs else {
            // A reply that did not come back as a reply of this thread (a channel post sent while the
            // pane was open) is not drawn here; the channel list has it.
            rebuild()
            return
        }
        if repliesByID[post.id] != nil {
            replaceReply(post)
        } else {
            replies = ThreadDerivation.merge(existing: replies, page: [post], rootID: rootID)
            repliesByID[post.id] = post
            scheduleProfileLoad(for: post.userId)
        }
        replyCount = ThreadDerivation.replyCount(root: root ?? MMPost(id: rootID),
                                                 replies: replies, serverCount: replyCount)
        notifyReplyActivity()
        rebuild()
    }

    func removePendingPost(id pendingID: String) {
        let rowID = pendingRowIDs[pendingID] ?? pendingID
        pendingRowIDs[pendingID] = nil
        pendingReplyIDs.remove(rowID)
        removeReply(rowID)
        rebuild()
    }

    func replacePost(_ post: MMPost) {
        if post.id == rootID {
            root = post
        } else if repliesByID[post.id] != nil {
            replaceReply(post)
        } else {
            return
        }
        rebuild()
    }

    /// T48: a pin write from the row menu (or another client's `post_edited`) moves this pane's row
    /// without a reload. The post object is replaced whole — the row derives its badge from it.
    func applyPin(postID: String, isPinned: Bool) {
        if let current = root, current.id == postID {
            guard current.isPinned != isPinned else { return }
            var updated = current
            updated.isPinned = isPinned
            root = updated
            rebuild()
            return
        }
        guard var reply = repliesByID[postID], reply.isPinned != isPinned else { return }
        reply.isPinned = isPinned
        replaceReply(reply)
        rebuild()
    }

    func tombstonePost(id: String) {
        if id == rootID, let root {
            applyTombstoneToRoot(root)
        } else if let post = repliesByID[id] {
            applyTombstone(post, deleteAt: 0)
            replyCount = max(0, replyCount - 1)
            notifyReplyActivity()
        } else {
            return
        }
        rebuild()
    }

    /// Did a reply with this client id already arrive over the socket even though the request failed?
    /// A row that is still pending is **not** a landed post (T35's rule, applied here).
    func post(withPendingID pendingID: String) -> MMPost? {
        if let resolved = pendingResolvedPosts[pendingID] { return resolved }
        guard let rowID = pendingRowIDs[pendingID], !pendingReplyIDs.contains(rowID) else {
            return nil
        }
        return repliesByID[rowID]
    }

    /// Diagnostics/tests: the ids currently drawn as "Sending…".
    var pendingReplyIDsForTests: Set<String> { pendingReplyIDs }

    private func reconcile(pendingID: String, with post: MMPost) {
        let rowID = pendingRowIDs[pendingID] ?? pendingID
        pendingReplyIDs.remove(rowID)
        if !post.id.isEmpty {
            pendingRowIDs[pendingID] = post.id
            pendingResolvedPosts[pendingID] = post
        }
        removeReply(rowID)
        guard post.rootId == rootID, !post.id.isEmpty else { return }
        if repliesByID[post.id] != nil {
            replaceReply(post)
        } else {
            replies = ThreadDerivation.merge(existing: replies, page: [post], rootID: rootID)
            repliesByID[post.id] = post
            replyCount = ThreadDerivation.replyCount(root: root ?? MMPost(id: rootID),
                                                     replies: replies, serverCount: replyCount)
            notifyReplyActivity()
            scheduleProfileLoad(for: post.userId)
        }
    }

    private func removeReply(_ id: String) {
        repliesByID[id] = nil
        replies.removeAll { $0.id == id }
    }

    // MARK: - Reader state

    func toggleExpanded(_ postID: String) {
        if expandedPostIDs.contains(postID) {
            expandedPostIDs.remove(postID)
        } else {
            expandedPostIDs.insert(postID)
        }
        rebuild()
    }

    func isExpanded(_ postID: String) -> Bool { expandedPostIDs.contains(postID) }

    /// Take the divider's position from the thread row, once, when the pane loads.
    ///
    /// Later rows (a follow toggle, a gap sweep, a `thread_updated`) carry a `last_viewed_at` that the
    /// server may have moved — but the line the reader is looking at must stay where it was put when
    /// the pane opened, or it would slide down the list as they read. That is upstream's rule, stated
    /// at `dividerViewedAt`: the position moves on reads that happen *outside* this pane only.
    private func takeDividerPosition(_ viewedAt: Int64) {
        guard !hasTakenDividerPosition else { return }
        hasTakenDividerPosition = true
        dividerViewedAt = viewedAt
    }

    // MARK: - Derivation

    /// Tell the owning pane what the root row should now say. Called from every path that changes the
    /// count, so the channel timeline cannot keep a stale number after a reply from any direction.
    private func notifyReplyActivity() {
        guard let root else { return }
        onReplyActivity?(rootID, replyCount, max(root.lastReplyAt, threadRow?.lastReplyAt ?? 0))
    }

    private func rebuild() {
        guard let root else {
            items = []
            participants = []
            return
        }
        let chain = ThreadDerivation.chain(root: root, replies: replies)
        // The divider comes from the same `PostListDerivation` the channel timeline uses, with the
        // pane's own read position — one rule for both lists, so `thread.viewed_at` handling cannot
        // drift from `channel_member.last_viewed_at` handling. The frozen position is the one to draw
        // from; before the thread row has been read the server's own position is all there is.
        items = PostListDerivation.items(posts: chain,
                                         users: users,
                                         myUserID: myUserID,
                                         lastViewedAt: dividerViewedAt ?? lastViewedAt,
                                         expandedPostIDs: expandedPostIDs,
                                         pendingPostIDs: pendingReplyIDs,
                                         now: now(),
                                         calendar: calendar,
                                         locale: locale)
        participants = ThreadDerivation.participants(root: root, replies: replies, users: users)
        replyCount = ThreadDerivation.replyCount(root: root, replies: replies, serverCount: replyCount)
    }

    // MARK: - Copy

    static func message(for error: Error) -> String {
        MMErrorCopy.message(for: error,
                            offline: "You are offline. The thread will load when the connection is back.",
                            timeout: "The server did not answer in time.",
                            unauthorized: "Your session has expired. Sign in again to read this thread.",
                            forbidden: "You do not have permission to read this thread.",
                            notFound: "This thread no longer exists.",
                            rateLimited: "The server is rate limiting this app. Try again shortly.",
                            fallback: "The thread could not be loaded.")
    }
}

// MARK: - ReactionTarget (S16/T37)

/// The thread pane is the other host a reaction write can target: a root and its replies share the
/// same patch rule, so a pill on a reply and a pill on the root behave identically.
extension ThreadViewModel: ReactionTarget {}
