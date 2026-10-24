import Foundation
import XCTest
@testable import Mattermost

/// T29 acceptance criteria, asserted against the *protocols* so both implementations have to agree:
///
///   * insert/update post (edit + delete)
///   * channel unread counts
///   * draft persistence per channel
///   * cursor round-trip
///   * eviction keeping the newest N
///
/// Plus the preference/user paths the same protocols expose. `SQLiteRepositoryContractTests` and
/// `InMemoryRepositoryContractTests` are the two runs; a disagreement means the store and the test
/// double are describing different worlds, which is exactly what a screen card would trip over.
enum RepositoryContract {

    // MARK: Posts

    static func postInsertAndReadBack(_ set: RepositorySet, file: StaticString, line: UInt) async throws {
        let post = T29Fixtures.post(id: "p1", channelID: "c1", userID: "u1", createAt: 1_000,
                                    message: "first")
        try await set.posts.upsert([post])

        let stored = try set.posts.post("p1")
        XCTAssertEqual(stored?.message, "first", file: file, line: line)
        XCTAssertEqual(stored?.channelId, "c1", file: file, line: line)
        XCTAssertEqual(stored?.createAt, 1_000, file: file, line: line)
        XCTAssertEqual(stored?.deleteAt, 0, file: file, line: line)
        XCTAssertEqual(stored?.props, .object([:]), "props round-trips as the schema default", file: file, line: line)
        XCTAssertEqual(stored?.fileIds, [], file: file, line: line)
        XCTAssertNil(try set.posts.post("nope"), file: file, line: line)
    }

    static func postEditReplacesVisibleContent(_ set: RepositorySet, file: StaticString, line: UInt) async throws {
        try await set.posts.upsert([T29Fixtures.post(id: "p1", createAt: 1_000, message: "before")])
        var edited = T29Fixtures.post(id: "p1", createAt: 1_000, message: "after", updateAt: 2_000)
        edited.editAt = 2_000
        try await set.posts.upsert([edited])

        let stored = try set.posts.post("p1")
        XCTAssertEqual(stored?.message, "after", file: file, line: line)
        XCTAssertEqual(stored?.editAt, 2_000, file: file, line: line)
        XCTAssertEqual(stored?.updateAt, 2_000, file: file, line: line)
    }

    static func stalePayloadDoesNotUndoAnEdit(_ set: RepositorySet, file: StaticString, line: UInt) async throws {
        try await set.posts.upsert([T29Fixtures.post(id: "p1", createAt: 1_000, message: "edited",
                                                     updateAt: 5_000)])
        // A history page fetched before the edit arrives afterwards.
        try await set.posts.upsert([T29Fixtures.post(id: "p1", createAt: 1_000, message: "original",
                                                     updateAt: 1_000)])
        XCTAssertEqual(try set.posts.post("p1")?.message, "edited",
                       "an older update_at must not win", file: file, line: line)
    }

    static func postDeleteIsASoftDeleteWithContentRemoved(_ set: RepositorySet,
                                                         file: StaticString, line: UInt) async throws {
        try await set.posts.upsert([T29Fixtures.post(id: "p1", createAt: 1_000, message: "secret")])
        try await set.posts.upsertReactions([T29Fixtures.reaction(postID: "p1")])
        XCTAssertEqual(try set.posts.reactions(postID: "p1").count, 1, file: file, line: line)

        try await set.posts.markDeleted("p1", at: 3_000)

        let stored = try set.posts.post("p1")
        XCTAssertNotNil(stored, "the row survives so the channel can render a tombstone", file: file, line: line)
        XCTAssertEqual(stored?.deleteAt, 3_000, file: file, line: line)
        XCTAssertEqual(stored?.message, "", "deleted content must not stay readable", file: file, line: line)
        XCTAssertEqual(stored?.fileIds, [], file: file, line: line)
        XCTAssertTrue(try set.posts.reactions(postID: "p1").isEmpty,
                      "reactions on a deleted post are meaningless", file: file, line: line)

        // A replayed pre-delete payload must not resurrect the content.
        try await set.posts.upsert([T29Fixtures.post(id: "p1", createAt: 1_000, message: "secret",
                                                    updateAt: 1_000)])
        XCTAssertEqual(try set.posts.post("p1")?.message, "", file: file, line: line)
    }

    static func channelPageIsNewestFirstAndPaginates(_ set: RepositorySet,
                                                     file: StaticString, line: UInt) async throws {
        let posts = (1...6).map { T29Fixtures.post(id: "p\($0)", channelID: "c1",
                                                   createAt: Int64($0) * 100, message: "m\($0)") }
        try await set.posts.upsert(posts)
        try await set.posts.upsert([T29Fixtures.post(id: "other", channelID: "c2", createAt: 999)])

        let firstPage = try set.posts.posts(inChannel: "c1", before: nil, limit: 3)
        XCTAssertEqual(firstPage.map(\.id), ["p6", "p5", "p4"], file: file, line: line)

        let secondPage = try set.posts.posts(inChannel: "c1", before: firstPage.last!.createAt, limit: 3)
        XCTAssertEqual(secondPage.map(\.id), ["p3", "p2", "p1"], file: file, line: line)

        XCTAssertEqual(try set.posts.posts(inChannel: "c1", before: nil, limit: 0).count, 0,
                       file: file, line: line)
        XCTAssertEqual(try set.posts.count(inChannel: "c1"), 6, file: file, line: line)
    }

    static func threadReturnsRootThenRepliesOldestFirst(_ set: RepositorySet,
                                                       file: StaticString, line: UInt) async throws {
        try await set.posts.upsert([
            T29Fixtures.post(id: "root", createAt: 100, message: "root"),
            T29Fixtures.post(id: "r1", createAt: 200, message: "one", rootID: "root"),
            T29Fixtures.post(id: "r2", createAt: 300, message: "two", rootID: "root"),
        ])
        let thread = try set.posts.posts(inThread: "root", limit: 10)
        XCTAssertEqual(thread.map(\.id), ["root", "r1", "r2"], file: file, line: line)
    }

    static func evictionKeepsTheNewestNAndTakesChildrenWithIt(_ set: RepositorySet,
                                                             file: StaticString, line: UInt) async throws {
        let posts = (1...10).map {
            T29Fixtures.post(id: "p\($0)", channelID: "c1", createAt: Int64($0) * 100)
        }
        try await set.posts.upsert(posts)
        try await set.posts.upsert([T29Fixtures.post(id: "keep-other", channelID: "c2", createAt: 1)])
        try await set.posts.upsertReactions([
            T29Fixtures.reaction(postID: "p1"), T29Fixtures.reaction(postID: "p10"),
        ])
        try await set.posts.upsertFiles([
            T29Fixtures.file(id: "f1", postID: "p1"), T29Fixtures.file(id: "f10", postID: "p10"),
        ])

        let removed = try await set.posts.evict(channelID: "c1", keepingNewest: 3)
        XCTAssertEqual(removed, 7, file: file, line: line)
        XCTAssertEqual(try set.posts.count(inChannel: "c1"), 3, file: file, line: line)
        XCTAssertEqual(try set.posts.posts(inChannel: "c1", before: nil, limit: 10).map(\.id),
                       ["p10", "p9", "p8"], "the newest N survive", file: file, line: line)
        XCTAssertNotNil(try set.posts.post("p10"), file: file, line: line)
        XCTAssertNil(try set.posts.post("p1"), file: file, line: line)
        XCTAssertTrue(try set.posts.reactions(postID: "p1").isEmpty,
                      "an evicted post's reactions are removed with it", file: file, line: line)
        XCTAssertEqual(try set.posts.reactions(postID: "p10").count, 1, file: file, line: line)
        XCTAssertTrue(try set.posts.files(postID: "p1").isEmpty, file: file, line: line)
        XCTAssertEqual(try set.posts.files(postID: "p10").count, 1, file: file, line: line)
        XCTAssertEqual(try set.posts.count(inChannel: "c2"), 1,
                       "eviction is per channel", file: file, line: line)
        // Evicting again with nothing to do is a no-op, not an error.
        let removedAgain = try await set.posts.evict(channelID: "c1", keepingNewest: 3)
        XCTAssertEqual(removedAgain, 0, file: file, line: line)
    }

    /// T29-AV F1: a reply is always newer than its root, so a window on `create_at` drops the root
    /// first. Nothing with a `root_id` may outlive its root, in either backend.
    static func evictionNeverLeavesARepliesRootBehind(_ set: RepositorySet,
                                                     file: StaticString, line: UInt) async throws {
        // The AV reproduction: root at 1, 200 replies at 2…201, window of 50. The old code kept the
        // 50 newest *replies* and deleted the root.
        var posts = [T29Fixtures.post(id: "root", channelID: "c1", createAt: 1, message: "root")]
        posts += (1...200).map { index in
            T29Fixtures.post(id: "r\(index)", channelID: "c1", createAt: Int64(index + 1),
                             message: "reply \(index)", rootID: "root")
        }
        try await set.posts.upsert(posts)

        let removed = try await set.posts.evict(channelID: "c1", keepingNewest: 50)
        XCTAssertEqual(removed, 201, "the root plus every reply of it is doomed",
                       file: file, line: line)

        // Whatever survived, no row may name a root that is gone.
        let page = try set.posts.posts(inChannel: "c1", before: nil, limit: 500)
        for post in page where !post.rootId.isEmpty {
            XCTAssertNotNil(try set.posts.post(post.rootId),
                            "\(post.id) survived its root \(post.rootId)", file: file, line: line)
        }
        XCTAssertEqual(page.count, 0,
                       "when the root leaves the window its whole thread leaves with it",
                       file: file, line: line)
        XCTAssertNil(try set.posts.post("root"), file: file, line: line)
        XCTAssertNil(try set.posts.post("r200"), "the newest reply goes with the root",
                     file: file, line: line)
        XCTAssertEqual(try set.posts.posts(inThread: "root", limit: 10).count, 0,
                       "a vanished thread reads as empty, not as replies with no root",
                       file: file, line: line)
    }

    /// The other half of F1: a root that *is* inside the window keeps its whole thread, newest
    /// replies included, and unrelated posts are untouched.
    static func aSurvivingRootKeepsItsNewestReplies(_ set: RepositorySet,
                                                    file: StaticString, line: UInt) async throws {
        var posts = (1...100).map { index in
            T29Fixtures.post(id: "p\(index)", channelID: "c1", createAt: Int64(index))
        }
        // The root sits above the filler, its replies above the root: everything about it survives.
        posts.append(T29Fixtures.post(id: "root", channelID: "c1", createAt: 1_000))
        posts += (1...5).map { index in
            T29Fixtures.post(id: "r\(index)", channelID: "c1", createAt: Int64(1_000 + index),
                             rootID: "root")
        }
        try await set.posts.upsert(posts)

        let removed = try await set.posts.evict(channelID: "c1", keepingNewest: 20)
        XCTAssertEqual(removed, 86, "everything below the newest 20 goes", file: file, line: line)
        XCTAssertNotNil(try set.posts.post("root"), file: file, line: line)
        XCTAssertEqual(try set.posts.posts(inThread: "root", limit: 10).map(\.id),
                       ["root", "r1", "r2", "r3", "r4", "r5"],
                       "the surviving root keeps every reply", file: file, line: line)
    }

    /// T29-AV F6: a pinned post is a deliberate keeper. Eviction skips it and there is a read for it,
    /// so the Pinned screen has something to render offline.
    static func pinnedPostsSurviveEvictionAndAreReadable(_ set: RepositorySet,
                                                         file: StaticString, line: UInt) async throws {
        var posts = (1...20).map { index in
            T29Fixtures.post(id: "p\(index)", channelID: "c1", createAt: Int64(index))
        }
        posts.append(T29Fixtures.post(id: "pinned-old", channelID: "c1", createAt: 1,
                                      message: "the wiki", isPinned: true))
        posts.append(T29Fixtures.post(id: "pinned-new", channelID: "c1", createAt: 2,
                                      message: "onboarding", isPinned: true))
        posts.append(T29Fixtures.post(id: "pinned-other", channelID: "c2", createAt: 3,
                                      isPinned: true))
        try await set.posts.upsert(posts)

        XCTAssertEqual(try set.posts.pinnedPosts(inChannel: "c1", limit: 10).map(\.id),
                       ["pinned-new", "pinned-old"], "pinned, newest first", file: file, line: line)
        XCTAssertEqual(try set.posts.pinnedPosts(inChannel: "c1", limit: 0).count, 0,
                       file: file, line: line)
        XCTAssertEqual(try set.posts.pinnedPosts(inChannel: "c9", limit: 10).count, 0,
                       file: file, line: line)

        let removed = try await set.posts.evict(channelID: "c1", keepingNewest: 5)
        XCTAssertEqual(removed, 15, "only the twenty ordinary posts are in the window",
                       file: file, line: line)
        XCTAssertNotNil(try set.posts.post("pinned-old"),
                        "a pinned post is never selected for eviction", file: file, line: line)
        XCTAssertNotNil(try set.posts.post("pinned-new"), file: file, line: line)
        XCTAssertEqual(try set.posts.count(inChannel: "c1"), 7,
                       "the window plus the channel's pinned posts", file: file, line: line)
        XCTAssertEqual(try set.posts.pinnedPosts(inChannel: "c1", limit: 10).map(\.id),
                       ["pinned-new", "pinned-old"], file: file, line: line)
    }

    // MARK: Channels

    static func unreadCountsComeFromMembership(_ set: RepositorySet,
                                               file: StaticString, line: UInt) async throws {
        try await set.channels.upsert([
            T29Fixtures.channel(id: "c1"), T29Fixtures.channel(id: "c2"), T29Fixtures.channel(id: "c3"),
        ])
        try await set.channels.upsertMembership([
            T29Fixtures.member(channelID: "c1", msgCount: 4, mentionCount: 2, urgentMentionCount: 1,
                               lastViewedAt: 500),
            T29Fixtures.member(channelID: "c2", msgCount: 0, mentionCount: 0, lastViewedAt: 600),
        ])

        let c1 = try set.channels.unread(channelID: "c1", userID: "user-1")
        XCTAssertEqual(c1.messageCount, 4, file: file, line: line)
        XCTAssertEqual(c1.mentionCount, 2, file: file, line: line)
        XCTAssertEqual(c1.urgentMentionCount, 1, file: file, line: line)
        XCTAssertTrue(c1.isUnread, file: file, line: line)

        let c2 = try set.channels.unread(channelID: "c2", userID: "user-1")
        XCTAssertFalse(c2.isUnread, file: file, line: line)

        let unknown = try set.channels.unread(channelID: "c3", userID: "user-1")
        XCTAssertEqual(unknown.messageCount, 0, file: file, line: line)
        XCTAssertFalse(unknown.isUnread, file: file, line: line)

        let byChannel = try set.channels.unreadByChannel(userID: "user-1")
        XCTAssertEqual(byChannel.keys.sorted(), ["c1"], file: file, line: line)

        let totals = try set.channels.unreadTotals(userID: "user-1")
        XCTAssertEqual(totals.messageCount, 4, file: file, line: line)
        XCTAssertEqual(totals.mentionCount, 2, file: file, line: line)
        XCTAssertEqual(totals.urgentMentionCount, 1, file: file, line: line)
        XCTAssertEqual(totals.unreadChannelCount, 1, file: file, line: line)
    }

    static func markReadClearsCountersAndKeepsTheViewTime(_ set: RepositorySet,
                                                         file: StaticString, line: UInt) async throws {
        try await set.channels.upsertMembership([
            T29Fixtures.member(channelID: "c1", msgCount: 3, mentionCount: 1, urgentMentionCount: 1,
                               lastViewedAt: 100, manuallyUnread: true),
        ])
        try await set.channels.markRead(channelID: "c1", userID: "user-1", viewedAt: 900)

        let unread = try set.channels.unread(channelID: "c1", userID: "user-1")
        XCTAssertEqual(unread.messageCount, 0, file: file, line: line)
        XCTAssertEqual(unread.mentionCount, 0, file: file, line: line)
        XCTAssertEqual(unread.urgentMentionCount, 0, file: file, line: line)
        XCTAssertFalse(unread.manuallyUnread, "opening a channel clears a manual unread mark",
                       file: file, line: line)
        XCTAssertEqual(unread.lastViewedAt, 900, file: file, line: line)
        XCTAssertTrue(try set.channels.unreadByChannel(userID: "user-1").isEmpty, file: file, line: line)

        // A view timestamp older than the recorded one does not move it backwards.
        try await set.channels.markRead(channelID: "c1", userID: "user-1", viewedAt: 50)
        XCTAssertEqual(try set.channels.unread(channelID: "c1", userID: "user-1").lastViewedAt, 900,
                       file: file, line: line)
    }

    static func manualUnreadKeepsAChannelUnreadWithNoNewMessages(_ set: RepositorySet,
                                                               file: StaticString, line: UInt) async throws {
        try await set.channels.upsertMembership([T29Fixtures.member(channelID: "c1")])
        try await set.channels.setManuallyUnread(channelID: "c1", userID: "user-1", unread: true)
        XCTAssertTrue(try set.channels.unread(channelID: "c1", userID: "user-1").isUnread,
                      file: file, line: line)
        try await set.channels.setManuallyUnread(channelID: "c1", userID: "user-1", unread: false)
        XCTAssertFalse(try set.channels.unread(channelID: "c1", userID: "user-1").isUnread,
                       file: file, line: line)
    }

    static func deletingAChannelRemovesItsMembershipAndPosts(_ set: RepositorySet,
                                                             file: StaticString, line: UInt) async throws {
        try await set.channels.upsert([T29Fixtures.channel(id: "c1"), T29Fixtures.channel(id: "c2")])
        try await set.channels.upsertMembership([
            T29Fixtures.member(channelID: "c1"), T29Fixtures.member(channelID: "c2"),
        ])
        try await set.posts.upsert([
            T29Fixtures.post(id: "p1", channelID: "c1", createAt: 1),
            T29Fixtures.post(id: "p2", channelID: "c1", createAt: 2),
            T29Fixtures.post(id: "p3", channelID: "c2", createAt: 3),
        ])

        let removedPosts = try await set.channels.delete(channelID: "c1")
        XCTAssertEqual(removedPosts, 2, file: file, line: line)
        XCTAssertNil(try set.channels.channel("c1"), file: file, line: line)
        XCTAssertNil(try set.channels.membership(channelID: "c1", userID: "user-1"), file: file, line: line)
        XCTAssertEqual(try set.posts.count(inChannel: "c1"), 0, file: file, line: line)
        XCTAssertEqual(try set.posts.count(inChannel: "c2"), 1, file: file, line: line)
        XCTAssertNotNil(try set.channels.channel("c2"), file: file, line: line)
    }

    // MARK: Drafts

    static func draftsAreSeparatePerChannelAndPerThreadRoot(_ set: RepositorySet,
                                                            file: StaticString, line: UInt) async throws {
        try await set.drafts.save(T29Fixtures.draft(channelID: "c1", message: "channel one", updateAt: 10))
        try await set.drafts.save(T29Fixtures.draft(channelID: "c2", message: "channel two", updateAt: 20))
        try await set.drafts.save(T29Fixtures.draft(channelID: "c1", rootID: "root-1",
                                                    message: "thread reply", updateAt: 30))

        XCTAssertEqual(try set.drafts.draft(channelID: "c1", rootID: "")?.message, "channel one",
                       file: file, line: line)
        XCTAssertEqual(try set.drafts.draft(channelID: "c2", rootID: "")?.message, "channel two",
                       file: file, line: line)
        XCTAssertEqual(try set.drafts.draft(channelID: "c1", rootID: "root-1")?.message, "thread reply",
                       file: file, line: line)
        XCTAssertNil(try set.drafts.draft(channelID: "c3", rootID: ""), file: file, line: line)

        // Overwriting keeps one row per (channel, root) and the newest text wins.
        try await set.drafts.save(T29Fixtures.draft(channelID: "c1", message: "edited draft", updateAt: 40))
        XCTAssertEqual(try set.drafts.draft(channelID: "c1", rootID: "")?.message, "edited draft",
                       file: file, line: line)
        XCTAssertEqual(try set.drafts.count(), 3, file: file, line: line)
        XCTAssertEqual(try set.drafts.drafts(limit: 10).map(\.channelId), ["c1", "c1", "c2"],
                       "most recently edited first", file: file, line: line)

        let deletedFirst = try await set.drafts.delete(channelID: "c1", rootID: "")
        XCTAssertTrue(deletedFirst, file: file, line: line)
        let deletedAgain = try await set.drafts.delete(channelID: "c1", rootID: "")
        XCTAssertFalse(deletedAgain, "deleting a missing draft reports false", file: file, line: line)
        XCTAssertNil(try set.drafts.draft(channelID: "c1", rootID: ""), file: file, line: line)
        XCTAssertEqual(try set.drafts.count(), 2, file: file, line: line)
    }

    // MARK: Cursors

    static func cursorsRoundTripPerScopeAndKey(_ set: RepositorySet,
                                                file: StaticString, line: UInt) async throws {
        XCTAssertNil(try set.cursors.lastSocketEventID(serverID: "server-1"), file: file, line: line)

        try await set.cursors.setLastSocketEventID("event-1", serverID: "server-1", updatedAt: 100)
        XCTAssertEqual(try set.cursors.lastSocketEventID(serverID: "server-1"), "event-1",
                       file: file, line: line)

        try await set.cursors.setLastSocketEventID("event-2", serverID: "server-1", updatedAt: 200)
        XCTAssertEqual(try set.cursors.lastSocketEventID(serverID: "server-1"), "event-2",
                       "a cursor overwrites rather than accumulates", file: file, line: line)
        XCTAssertNil(try set.cursors.lastSocketEventID(serverID: "server-2"),
                     "cursors are per server", file: file, line: line)

        try await set.cursors.setLastPostID("post-9", channelID: "c1", updatedAt: 300)
        try await set.cursors.setLastPostID("post-7", channelID: "c2", updatedAt: 400)
        XCTAssertEqual(try set.cursors.lastPostID(channelID: "c1"), "post-9", file: file, line: line)
        XCTAssertEqual(try set.cursors.lastPostID(channelID: "c2"), "post-7", file: file, line: line)
        XCTAssertNil(try set.cursors.lastPostID(channelID: "c3"), file: file, line: line)

        let recorded = try set.cursors.cursor(scope: .channelLastPost, scopeKey: "c1")
        XCTAssertEqual(recorded?.cursor, "post-9", file: file, line: line)
        XCTAssertEqual(recorded?.updatedAt, 300, file: file, line: line)

        XCTAssertEqual(try set.cursors.all(scope: .channelLastPost).count, 2, file: file, line: line)
        let cleared = try await set.cursors.clear(scope: .channelLastPost, scopeKey: "c1")
        XCTAssertTrue(cleared, file: file, line: line)
        XCTAssertNil(try set.cursors.lastPostID(channelID: "c1"), file: file, line: line)
        let clearedAll = try await set.cursors.clearAll()
        XCTAssertEqual(clearedAll, 2, "socket cursor + c2 post cursor", file: file, line: line)
    }

    // MARK: Preferences and users

    static func preferencesUpsertByCategory(_ set: RepositorySet,
                                            file: StaticString, line: UInt) async throws {
        try await set.preferences.upsert([
            MMPreference(userId: "user-1", category: "theme", name: "theme", value: "dark"),
            MMPreference(userId: "user-1", category: "theme", name: "use_system_theme", value: "true"),
            MMPreference(userId: "user-1", category: "sidebar_settings", name: "show_unread", value: "1"),
        ])
        XCTAssertEqual(try set.preferences.preferences(userID: "user-1", category: "theme").map(\.name),
                       ["theme", "use_system_theme"], file: file, line: line)
        XCTAssertEqual(try set.preferences.value(userID: "user-1", category: "theme", name: "theme"),
                       "dark", file: file, line: line)

        try await set.preferences.upsert([
            MMPreference(userId: "user-1", category: "theme", name: "theme", value: "light"),
        ])
        XCTAssertEqual(try set.preferences.value(userID: "user-1", category: "theme", name: "theme"),
                       "light", file: file, line: line)
        XCTAssertEqual(try set.preferences.count(), 3, file: file, line: line)

        let removedPreference = try await set.preferences.delete(userID: "user-1", category: "theme",
                                                                 name: "theme")
        XCTAssertTrue(removedPreference, file: file, line: line)
        XCTAssertNil(try set.preferences.value(userID: "user-1", category: "theme", name: "theme"),
                     file: file, line: line)
        let removedAll = try await set.preferences.deleteAll(userID: "user-1")
        XCTAssertEqual(removedAll, 2, file: file, line: line)
        XCTAssertEqual(try set.preferences.count(), 0, file: file, line: line)
    }

    static func usersUpsertBatchAndPrefixSearch(_ set: RepositorySet,
                                                file: StaticString, line: UInt) async throws {
        try await set.users.upsert([
            T29Fixtures.user(id: "u1", username: "ada"),
            T29Fixtures.user(id: "u2", username: "adam"),
            T29Fixtures.user(id: "u3", username: "bob"),
        ])
        XCTAssertEqual(try set.users.user("u1")?.username, "ada", file: file, line: line)
        XCTAssertNil(try set.users.user("nope"), file: file, line: line)

        XCTAssertEqual(Set(try set.users.users(ids: ["u1", "u3"]).map(\.id)), ["u1", "u3"],
                       file: file, line: line)
        XCTAssertEqual(try set.users.users(ids: []).count, 0, file: file, line: line)

        XCTAssertEqual(try set.users.searchUsers(usernamePrefix: "ada", limit: 10).map(\.username),
                       ["ada", "adam"], "prefix match, username order", file: file, line: line)
        XCTAssertEqual(try set.users.searchUsers(usernamePrefix: "@Ada", limit: 10).map(\.username),
                       ["ada", "adam"], "the @ is stripped and the match is case-insensitive",
                       file: file, line: line)
        XCTAssertEqual(try set.users.searchUsers(usernamePrefix: "ada", limit: 1).count, 1,
                       file: file, line: line)

        // A stale profile payload does not overwrite a newer one.
        try await set.users.upsert([T29Fixtures.user(id: "u1", username: "ada", updateAt: 900)])
        try await set.users.upsert([T29Fixtures.user(id: "u1", username: "ada-old", updateAt: 100)])
        XCTAssertEqual(try set.users.user("u1")?.username, "ada", file: file, line: line)
    }
}

// MARK: - The two runs

final class SQLiteRepositoryContractTests: XCTestCase {
    private var harness: StoreHarness!

    override func setUpWithError() throws { harness = try StoreHarness() }
    override func tearDownWithError() throws { harness.cleanup(); harness = nil }

    private var set: RepositorySet { harness.repositories }

    func testPostInsertAndReadBack() async throws {
        try await RepositoryContract.postInsertAndReadBack(set, file: #file, line: #line)
    }

    func testPostEdit() async throws {
        try await RepositoryContract.postEditReplacesVisibleContent(set, file: #file, line: #line)
    }

    func testStalePayloadDoesNotUndoAnEdit() async throws {
        try await RepositoryContract.stalePayloadDoesNotUndoAnEdit(set, file: #file, line: #line)
    }

    func testPostDelete() async throws {
        try await RepositoryContract.postDeleteIsASoftDeleteWithContentRemoved(set, file: #file, line: #line)
    }

    func testChannelPage() async throws {
        try await RepositoryContract.channelPageIsNewestFirstAndPaginates(set, file: #file, line: #line)
    }

    func testThreadOrder() async throws {
        try await RepositoryContract.threadReturnsRootThenRepliesOldestFirst(set, file: #file, line: #line)
    }

    func testEviction() async throws {
        try await RepositoryContract.evictionKeepsTheNewestNAndTakesChildrenWithIt(set, file: #file, line: #line)
    }

    func testEvictionNeverLeavesARepliesRootBehind() async throws {
        try await RepositoryContract.evictionNeverLeavesARepliesRootBehind(set, file: #file, line: #line)
    }

    func testASurvivingRootKeepsItsNewestReplies() async throws {
        try await RepositoryContract.aSurvivingRootKeepsItsNewestReplies(set, file: #file, line: #line)
    }

    func testPinnedPostsSurviveEviction() async throws {
        try await RepositoryContract.pinnedPostsSurviveEvictionAndAreReadable(set, file: #file, line: #line)
    }

    func testUnreadCounts() async throws {
        try await RepositoryContract.unreadCountsComeFromMembership(set, file: #file, line: #line)
    }

    func testMarkRead() async throws {
        try await RepositoryContract.markReadClearsCountersAndKeepsTheViewTime(set, file: #file, line: #line)
    }

    func testManualUnread() async throws {
        try await RepositoryContract.manualUnreadKeepsAChannelUnreadWithNoNewMessages(set, file: #file, line: #line)
    }

    func testChannelDelete() async throws {
        try await RepositoryContract.deletingAChannelRemovesItsMembershipAndPosts(set, file: #file, line: #line)
    }

    func testDrafts() async throws {
        try await RepositoryContract.draftsAreSeparatePerChannelAndPerThreadRoot(set, file: #file, line: #line)
    }

    func testCursors() async throws {
        try await RepositoryContract.cursorsRoundTripPerScopeAndKey(set, file: #file, line: #line)
    }

    func testPreferences() async throws {
        try await RepositoryContract.preferencesUpsertByCategory(set, file: #file, line: #line)
    }

    func testUsers() async throws {
        try await RepositoryContract.usersUpsertBatchAndPrefixSearch(set, file: #file, line: #line)
    }
}

final class InMemoryRepositoryContractTests: XCTestCase {
    private let harness = MemoryHarness()
    private var set: RepositorySet { harness.repositories }

    func testPostInsertAndReadBack() async throws {
        try await RepositoryContract.postInsertAndReadBack(set, file: #file, line: #line)
    }

    func testPostEdit() async throws {
        try await RepositoryContract.postEditReplacesVisibleContent(set, file: #file, line: #line)
    }

    func testStalePayloadDoesNotUndoAnEdit() async throws {
        try await RepositoryContract.stalePayloadDoesNotUndoAnEdit(set, file: #file, line: #line)
    }

    func testPostDelete() async throws {
        try await RepositoryContract.postDeleteIsASoftDeleteWithContentRemoved(set, file: #file, line: #line)
    }

    func testChannelPage() async throws {
        try await RepositoryContract.channelPageIsNewestFirstAndPaginates(set, file: #file, line: #line)
    }

    func testThreadOrder() async throws {
        try await RepositoryContract.threadReturnsRootThenRepliesOldestFirst(set, file: #file, line: #line)
    }

    func testEviction() async throws {
        try await RepositoryContract.evictionKeepsTheNewestNAndTakesChildrenWithIt(set, file: #file, line: #line)
    }

    func testEvictionNeverLeavesARepliesRootBehind() async throws {
        try await RepositoryContract.evictionNeverLeavesARepliesRootBehind(set, file: #file, line: #line)
    }

    func testASurvivingRootKeepsItsNewestReplies() async throws {
        try await RepositoryContract.aSurvivingRootKeepsItsNewestReplies(set, file: #file, line: #line)
    }

    func testPinnedPostsSurviveEviction() async throws {
        try await RepositoryContract.pinnedPostsSurviveEvictionAndAreReadable(set, file: #file, line: #line)
    }

    func testUnreadCounts() async throws {
        try await RepositoryContract.unreadCountsComeFromMembership(set, file: #file, line: #line)
    }

    func testMarkRead() async throws {
        try await RepositoryContract.markReadClearsCountersAndKeepsTheViewTime(set, file: #file, line: #line)
    }

    func testManualUnread() async throws {
        try await RepositoryContract.manualUnreadKeepsAChannelUnreadWithNoNewMessages(set, file: #file, line: #line)
    }

    func testChannelDelete() async throws {
        try await RepositoryContract.deletingAChannelRemovesItsMembershipAndPosts(set, file: #file, line: #line)
    }

    func testDrafts() async throws {
        try await RepositoryContract.draftsAreSeparatePerChannelAndPerThreadRoot(set, file: #file, line: #line)
    }

    func testCursors() async throws {
        try await RepositoryContract.cursorsRoundTripPerScopeAndKey(set, file: #file, line: #line)
    }

    func testPreferences() async throws {
        try await RepositoryContract.preferencesUpsertByCategory(set, file: #file, line: #line)
    }

    func testUsers() async throws {
        try await RepositoryContract.usersUpsertBatchAndPrefixSearch(set, file: #file, line: #line)
    }
}
