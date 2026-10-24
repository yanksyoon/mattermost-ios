import Foundation
import XCTest
@testable import Mattermost

/// T29 — "a measured note on DB size for a seeded ~10k-post fixture", and the eviction policy proved
/// to bound it. The numbers this prints go into `docs/t29-build-note.md` §5; the assertions are
/// deliberately loose (a factor, not a byte count) so a page-layout change in SQLite does not fail
/// the suite, while a 10× regression does.
final class MMStoreSizeTests: XCTestCase {

    private static let channels = 5
    private static let postsPerChannel = 2_000
    private static var totalPosts: Int { channels * postsPerChannel }

    private func seed(_ harness: StoreHarness, batchSize: Int = 2_000) async throws {
        // Users first: real servers have authors, and the username index is part of the footprint.
        let users = (1...20).map { index in
            T29Fixtures.user(id: "user-\(index)", username: "user\(index)")
        }
        try await harness.users.upsert(users)

        let channels = (1...Self.channels).map { index in
            T29Fixtures.channel(id: "channel-\(index)", teamID: "team-1",
                                displayName: "Channel \(index)")
        }
        try await harness.channels.upsert(channels)
        try await harness.channels.upsertMembership(channels.map {
            T29Fixtures.member(channelID: $0.id, lastViewedAt: 1_000)
        })

        var batch: [MMPost] = []
        batch.reserveCapacity(batchSize)
        var reactions: [MMReaction] = []
        var files: [MMFileInfo] = []

        for channel in 1...Self.channels {
            for index in 1...Self.postsPerChannel {
                let ordinal = channel * 100_000 + index
                let post = T29Fixtures.post(
                    id: String(format: "post-%07d", ordinal),
                    channelID: "channel-\(channel)",
                    userID: "user-\((ordinal % 20) + 1)",
                    createAt: Int64(ordinal),
                    message: T29Fixtures.body(seed: ordinal))
                batch.append(post)
                // ~10% of posts carry two reactions, ~5% carry a file: a realistic-ish mix.
                if ordinal % 10 == 0 {
                    reactions.append(T29Fixtures.reaction(postID: post.id, userID: "user-2",
                                                          emojiName: "thumbsup", createAt: Int64(ordinal)))
                    reactions.append(T29Fixtures.reaction(postID: post.id, userID: "user-3",
                                                          emojiName: "tada", createAt: Int64(ordinal)))
                }
                if ordinal % 20 == 0 {
                    files.append(T29Fixtures.file(id: "file-\(ordinal)", postID: post.id))
                }
                if batch.count == batchSize {
                    try await harness.posts.upsert(batch)
                    try await harness.posts.upsertReactions(reactions)
                    try await harness.posts.upsertFiles(files)
                    batch.removeAll(keepingCapacity: true)
                    reactions.removeAll(keepingCapacity: true)
                    files.removeAll(keepingCapacity: true)
                }
            }
        }
        if !batch.isEmpty {
            try await harness.posts.upsert(batch)
            try await harness.posts.upsertReactions(reactions)
            try await harness.posts.upsertFiles(files)
        }
    }

    private func measurePageLatency(_ harness: StoreHarness, iterations: Int = 100) throws -> Double {
        let started = Date()
        for _ in 0..<iterations {
            _ = try harness.posts.posts(inChannel: "channel-3", before: nil, limit: 50)
        }
        return Date().timeIntervalSince(started) / Double(iterations) * 1000
    }

    // MARK: - Unbounded fixture

    func testTenThousandPostFixtureSizeAndLatency() async throws {
        let harness = try StoreHarness(retention: .unbounded)
        defer { harness.cleanup() }

        let seedStarted = Date()
        try await seed(harness)
        let seedSeconds = Date().timeIntervalSince(seedStarted)
        XCTAssertEqual(try harness.posts.count(inChannel: "channel-1"), Self.postsPerChannel)

        try harness.store.checkpoint()
        let size = try harness.store.size()
        let latency = try measurePageLatency(harness)

        let bytesPerPost = Double(size.fileBytes) / Double(Self.totalPosts)
        print("""

        T29-SIZE fixture=unbounded posts=\(Self.totalPosts) channels=\(Self.channels) \
        file_bytes=\(size.fileBytes) used_bytes=\(size.usedBytes) \
        mb=\(String(format: "%.2f", size.megabytes)) bytes_per_post=\(String(format: "%.0f", bytesPerPost)) \
        page_query_ms=\(String(format: "%.2f", latency)) seed_s=\(String(format: "%.2f", seedSeconds))
        """)

        XCTAssertEqual(try harness.store.rowCount(in: "post"), Self.totalPosts)
        XCTAssertGreaterThan(size.fileBytes, 0)
        XCTAssertGreaterThan(bytesPerPost, 100, "a post row plus its index entries cannot be smaller than this")
        XCTAssertLessThan(bytesPerPost, 2_000, "and should not be an order of magnitude larger")
        XCTAssertLessThan(latency, 25, "a 50-post page against 10k rows must not take 25 ms")
    }

    // MARK: - Bounded fixture (the policy the app actually ships)

    func testRetentionPolicyBoundsDiskForABusyServer() async throws {
        let unbounded = try StoreHarness(retention: .unbounded)
        defer { unbounded.cleanup() }
        try await seed(unbounded)
        try unbounded.store.checkpoint()
        let unboundedBytes = try unbounded.store.size().fileBytes

        // The shipping configuration: 200 posts per channel, trimmed lazily.
        let bounded = try StoreHarness(retention: .default)
        defer { bounded.cleanup() }
        try await seed(bounded)
        try bounded.store.checkpoint()
        let boundedSize = try bounded.store.size()
        let boundedPerChannel = try bounded.posts.count(inChannel: "channel-1")

        print("""

        T29-SIZE retention unbounded_bytes=\(unboundedBytes) \
        bounded_bytes=\(boundedSize.fileBytes) mb=\(String(format: "%.2f", boundedSize.megabytes)) \
        posts_kept_per_channel=\(boundedPerChannel) max=\(MMRetentionPolicy.default.maxPostsPerChannel ?? -1)
        """)

        XCTAssertLessThanOrEqual(boundedPerChannel, MMRetentionPolicy.default.maxPostsPerChannel!,
                                 "the window is the budget")
        XCTAssertGreaterThan(boundedPerChannel, 0, "trimming must not empty the channel")
        XCTAssertEqual(try bounded.store.rowCount(in: "post"), boundedPerChannel * Self.channels,
                       "every channel is trimmed to the same window")
        XCTAssertLessThan(boundedSize.fileBytes, unboundedBytes / 2,
                          "bounded history must be materially smaller than unbounded history")
    }

    // MARK: - 100 channels, the shipping shape (T29-AV F3)

    /// The number `docs/t29-build-note.md` §4 quotes for "a busy server": 100 channels at the
    /// shipping 200-post window. It used to be an extrapolation from five channels (0.30 MB each →
    /// "≈ 30 MB") that was 4.4× too high; T29-AV measured 6.79 MB and this test makes that
    /// reproducible, printing `T29-SIZE channels=100 …`.
    func testHundredChannelsAtTheShippingWindow() async throws {
        let channelCount = 100
        // 251 = the window (200) + the slack (50) + 1: every channel must trim exactly once, so the
        // file includes the freelist the trims leave behind, which is what "steady state" means.
        let postsPerChannel = 251
        let harness = try StoreHarness(retention: .default)
        defer { harness.cleanup() }

        let started = Date()
        try await harness.users.upsert((1...20).map { T29Fixtures.user(id: "user-\($0)", username: "user\($0)") })
        let channels = (1...channelCount).map {
            T29Fixtures.channel(id: "channel-\($0)", teamID: "team-1", displayName: "Channel \($0)")
        }
        try await harness.channels.upsert(channels)
        try await harness.channels.upsertMembership(channels.map {
            T29Fixtures.member(channelID: $0.id, lastViewedAt: 1_000)
        })
        for channel in 1...channelCount {
            let batch = (1...postsPerChannel).map { index in
                let ordinal = channel * 100_000 + index
                return T29Fixtures.post(id: String(format: "post-%07d", ordinal),
                                        channelID: "channel-\(channel)",
                                        userID: "user-\((ordinal % 20) + 1)",
                                        createAt: Int64(ordinal),
                                        message: T29Fixtures.body(seed: ordinal))
            }
            try await harness.posts.upsert(batch)
        }
        let seedSeconds = Date().timeIntervalSince(started)
        try harness.store.checkpoint()
        let size = try harness.store.size()
        let kept = try harness.posts.count(inChannel: "channel-1")
        let totalKept = try harness.store.rowCount(in: "post")
        let megabytesPerChannel = size.megabytes / Double(channelCount)

        print("""

        T29-SIZE channels=\(channelCount) kept=\(kept) file_bytes=\(size.fileBytes) \
        mb=\(String(format: "%.2f", size.megabytes)) \
        mb_per_channel=\(String(format: "%.3f", megabytesPerChannel)) \
        seed_s=\(String(format: "%.2f", seedSeconds))
        """)

        XCTAssertEqual(kept, 200, "the window is the budget, at 100 channels as at 5")
        XCTAssertEqual(totalKept, kept * channelCount,
                       "every channel is trimmed to the same window (no unbounded channel)")
        XCTAssertLessThan(megabytesPerChannel, 0.20,
                          "the shipping shape must not cost the old extrapolation's 0.30 MB/channel")
        XCTAssertGreaterThan(megabytesPerChannel, 0.01,
                             "and it is not free: ~200 posts and their indices take real pages")
    }

    func testEvictionReclaimsSpaceAfterTrim() async throws {
        // Rows freed by eviction are reusable: SQLite keeps them on the freelist rather than
        // shrinking the file, which is why the retention number matters more than VACUUM.
        let harness = try StoreHarness(retention: MMRetentionPolicy(maxPostsPerChannel: 50,
                                                                    evictOnWrite: false,
                                                                    evictionSlack: 0))
        defer { harness.cleanup() }
        try await seed(harness, batchSize: 1_000)
        try harness.store.checkpoint()
        let before = try harness.store.size()
        XCTAssertEqual(try harness.posts.count(inChannel: "channel-1"), Self.postsPerChannel)

        for channel in 1...Self.channels {
            _ = try await harness.posts.evict(channelID: "channel-\(channel)", keepingNewest: 50)
        }
        try harness.store.checkpoint()
        let after = try harness.store.size()
        let kept = try harness.posts.count(inChannel: "channel-1")

        print("""

        T29-SIZE eviction before_bytes=\(before.fileBytes) after_bytes=\(after.fileBytes) \
        before_free_pages=\(before.freePageCount) after_free_pages=\(after.freePageCount) \
        posts_kept=\(kept)
        """)

        XCTAssertEqual(kept, 50)
        XCTAssertGreaterThan(after.freePageCount, 0,
                             "eviction returns pages to the freelist, ready for reuse")
    }
}
