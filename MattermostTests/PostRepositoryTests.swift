import Foundation
import XCTest
import GRDB
@testable import Mattermost

/// T29 — SQLite-specific behaviour of `PostRepository`: the retention policy wired into writes, the
/// orphan cleanup that eviction owes, and the fact that the page query really uses the index the
/// schema claims it needs. (Protocol-level behaviour is covered by `RepositoryContractTests`.)
final class PostRepositoryTests: XCTestCase {

    private var harness: StoreHarness!

    override func setUpWithError() throws {
        harness = try StoreHarness()
    }

    override func tearDownWithError() throws {
        harness.cleanup()
        harness = nil
    }

    // MARK: Retention policy

    func testWriteTimeEvictionKeepsTheChannelInsideItsBudget() async throws {
        harness.cleanup()
        // 5 posts kept, 2 posts of slack: a trim happens only once the channel passes 7.
        harness = try StoreHarness(retention: MMRetentionPolicy(maxPostsPerChannel: 5,
                                                               evictOnWrite: true,
                                                               evictionSlack: 2))
        let posts = (1...6).map {
            T29Fixtures.post(id: "p\($0)", channelID: "c1", createAt: Int64($0))
        }
        try await harness.posts.upsert(posts)
        XCTAssertEqual(try harness.posts.count(inChannel: "c1"), 6, "inside the slack, nothing is trimmed")

        try await harness.posts.upsert([
            T29Fixtures.post(id: "p7", channelID: "c1", createAt: 7),
            T29Fixtures.post(id: "p8", channelID: "c1", createAt: 8),
        ])
        XCTAssertEqual(try harness.posts.count(inChannel: "c1"), 5, "trimmed back to the window")
        XCTAssertEqual(try harness.posts.posts(inChannel: "c1", before: nil, limit: 10).map(\.id),
                       ["p8", "p7", "p6", "p5", "p4"])
    }

    func testUnboundedPolicyNeverTrims() async throws {
        harness.cleanup()
        harness = try StoreHarness(retention: .unbounded)
        let posts = (1...300).map {
            T29Fixtures.post(id: "p\($0)", channelID: "c1", createAt: Int64($0))
        }
        try await harness.posts.upsert(posts)
        XCTAssertEqual(try harness.posts.count(inChannel: "c1"), 300)
        let evictNoOp1 = try await harness.posts.evictIfNeeded(channelID: "c1")
        XCTAssertEqual(evictNoOp1, 0)
        XCTAssertEqual(try harness.posts.count(inChannel: "c1"), 300)
    }

    func testEvictIfNeededIsANoOpInsideBudget() async throws {
        harness.cleanup()
        harness = try StoreHarness(retention: MMRetentionPolicy(maxPostsPerChannel: 10,
                                                               evictOnWrite: true,
                                                               evictionSlack: 0))
        try await harness.posts.upsert((1...4).map {
            T29Fixtures.post(id: "p\($0)", channelID: "c1", createAt: Int64($0))
        })
        let evictNoOp2 = try await harness.posts.evictIfNeeded(channelID: "c1")
        XCTAssertEqual(evictNoOp2, 0)
        XCTAssertEqual(try harness.posts.count(inChannel: "c1"), 4)
    }

    func testDefaultPolicyIsTwoHundredPostsPerChannel() {
        XCTAssertEqual(MMRetentionPolicy.default.maxPostsPerChannel, 200)
        XCTAssertEqual(MMRetentionPolicy.default.evictionSlack, 50)
        XCTAssertEqual(MMRetentionPolicy.default.writeThreshold, 250)
        XCTAssertNil(MMRetentionPolicy.unbounded.writeThreshold)
    }

    // MARK: Orphan cleanup

    func testEvictingEverythingLeavesNoReactionOrFileRows() async throws {
        // Enough posts to cross the eviction chunk size (400) — the cleanup is chunked, and an
        // off-by-one in the chunk loop would leave the tail behind.
        let posts = (1...900).map {
            T29Fixtures.post(id: "p\($0)", channelID: "c1", createAt: Int64($0))
        }
        try await harness.posts.upsert(posts)
        try await harness.posts.upsertReactions((1...900).map { T29Fixtures.reaction(postID: "p\($0)") })
        try await harness.posts.upsertFiles((1...900).map { T29Fixtures.file(id: "f\($0)", postID: "p\($0)") })

        let removed = try await harness.posts.evict(channelID: "c1", keepingNewest: 0)
        XCTAssertEqual(removed, 900)
        XCTAssertEqual(try harness.posts.count(inChannel: "c1"), 0)
        XCTAssertEqual(try harness.store.rowCount(in: "post_reaction"), 0,
                       "no orphan reactions")
        XCTAssertEqual(try harness.store.rowCount(in: "file_info"), 0,
                       "no orphan files")
    }

    /// The AV reproduction as a raw-SQL assertion (T29-AV F1): after an eviction no `post` row may
    /// name a `root_id` that is not in the table. Counted from the database, not through the
    /// repository, so a repository that hides orphans from its own read cannot pass this.
    func testEvictionLeavesNoOrphanReplyRows() async throws {
        harness.cleanup()
        // The shipping shape from the AV probe: window 50, no slack, eviction on write.
        harness = try StoreHarness(retention: MMRetentionPolicy(maxPostsPerChannel: 50,
                                                                evictOnWrite: true,
                                                                evictionSlack: 0))
        var posts = [T29Fixtures.post(id: "root", channelID: "c1", createAt: 1, message: "root")]
        posts += (1...200).map { index in
            T29Fixtures.post(id: "r\(index)", channelID: "c1", createAt: Int64(index + 1),
                             rootID: "root")
        }
        // One batch: the write-time eviction runs inside the same transaction as the insert.
        try await harness.posts.upsert(posts)

        let orphans = try orphanReplyCount()
        XCTAssertEqual(orphans, 0, "no post with a root_id may outlive its root")
        XCTAssertEqual(try harness.posts.count(inChannel: "c1"), 0,
                       "the root left the window, so its whole thread left with it")
        XCTAssertEqual(try harness.store.rowCount(in: "post"), 0)

        // And the check itself is not vacuous: an orphan the repository cannot see is detectable.
        try await harness.store.write { db in
            try db.execute(sql: """
                INSERT INTO post (id, channel_id, root_id, create_at) VALUES ('orphan', 'c1', 'gone', 9)
                """)
        }
        XCTAssertEqual(try orphanReplyCount(), 1, "the orphan query does see an orphan when there is one")
    }

    /// The count of `post` rows whose `root_id` names a row that is not there — the invariant
    /// `PostRepository.evict` owes, measured directly.
    private func orphanReplyCount() throws -> Int {
        try harness.store.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM post AS reply
                 WHERE reply.root_id <> ''
                   AND NOT EXISTS (SELECT 1 FROM post AS root WHERE root.id = reply.root_id)
                """) ?? -1
        }
    }

    /// T29-AV F6: a pinned post is not part of the window, even when the eviction comes from the
    /// write path (not just an explicit `evict` call), and the pinned read finds it.
    func testPinnedPostSurvivesWriteTimeEviction() async throws {
        harness.cleanup()
        harness = try StoreHarness(retention: MMRetentionPolicy(maxPostsPerChannel: 10,
                                                                evictOnWrite: true,
                                                                evictionSlack: 0))
        try await harness.posts.upsert([
            T29Fixtures.post(id: "pinned", channelID: "c1", createAt: 1, message: "keep me",
                             isPinned: true),
        ])
        try await harness.posts.upsert((1...30).map {
            T29Fixtures.post(id: "p\($0)", channelID: "c1", createAt: Int64($0 + 1))
        })

        XCTAssertNotNil(try harness.posts.post("pinned"),
                        "pinned posts are outside the eviction window")
        XCTAssertEqual(try harness.posts.count(inChannel: "c1"), 11,
                       "the window plus the one pinned post")
        XCTAssertEqual(try harness.posts.pinnedPosts(inChannel: "c1", limit: 10).map(\.id),
                       ["pinned"])

        // Unpinning puts it back in the window, and the next trim can take it.
        try await harness.posts.upsert([
            T29Fixtures.post(id: "pinned", channelID: "c1", createAt: 1, updateAt: 99, isPinned: false),
        ])
        _ = try await harness.posts.evict(channelID: "c1", keepingNewest: 10)
        XCTAssertNil(try harness.posts.post("pinned"))
    }

    func testMarkDeletedOnAMissingPostIsHarmless() async throws {
        try await harness.posts.markDeleted("does-not-exist", at: 1_000)
        XCTAssertNil(try harness.posts.post("does-not-exist"))
    }

    func testReactionRemovalIsTargeted() async throws {
        try await harness.posts.upsert([T29Fixtures.post(id: "p1", createAt: 1)])
        try await harness.posts.upsertReactions([
            T29Fixtures.reaction(postID: "p1", userID: "u1", emojiName: "thumbsup"),
            T29Fixtures.reaction(postID: "p1", userID: "u2", emojiName: "thumbsup"),
            T29Fixtures.reaction(postID: "p1", userID: "u1", emojiName: "tada"),
        ])
        XCTAssertEqual(try harness.posts.reactions(postID: "p1").count, 3)

        try await harness.posts.removeReaction(postID: "p1", userID: "u1", emojiName: "thumbsup")
        let remaining = try harness.posts.reactions(postID: "p1")
        XCTAssertEqual(remaining.count, 2)
        XCTAssertFalse(remaining.contains { $0.userId == "u1" && $0.emojiName == "thumbsup" })
    }

    func testReactionInsertIsIdempotent() async throws {
        try await harness.posts.upsert([T29Fixtures.post(id: "p1", createAt: 1)])
        let reaction = T29Fixtures.reaction(postID: "p1")
        try await harness.posts.upsertReactions([reaction])
        try await harness.posts.upsertReactions([reaction])
        XCTAssertEqual(try harness.posts.reactions(postID: "p1").count, 1)
    }

    // MARK: Query plans

    func testChannelPageQueryUsesTheChannelWindowIndex() throws {
        let plan = try harness.store.read { db in
            try Row.fetchAll(db, sql: """
                EXPLAIN QUERY PLAN
                SELECT * FROM post
                 WHERE channel_id = ? AND (? IS NULL OR create_at < ?)
                 ORDER BY create_at DESC, id DESC
                 LIMIT ?
                """, arguments: ["c1", nil, 100, 50]).map { $0["detail"] as String? ?? "" }
        }
        XCTAssertTrue(plan.contains { $0.contains("idx_post_channel_window") },
                      "the page query must use idx_post_channel_window, plan was: \(plan)")
        XCTAssertFalse(plan.contains { $0.contains("TEMP B-TREE") },
                       "no sort step: the index already provides the order, plan was: \(plan)")
    }

    func testThreadQueryUsesTheRootWindowIndex() throws {
        let plan = try harness.store.read { db in
            try Row.fetchAll(db, sql: """
                EXPLAIN QUERY PLAN
                SELECT * FROM post WHERE root_id = ? ORDER BY create_at DESC LIMIT ?
                """, arguments: ["root", 50]).map { $0["detail"] as String? ?? "" }
        }
        XCTAssertTrue(plan.contains { $0.contains("idx_post_root_window") },
                      "the thread query must use idx_post_root_window, plan was: \(plan)")
    }
}
