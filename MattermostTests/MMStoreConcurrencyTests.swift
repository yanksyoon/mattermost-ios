import Foundation
import XCTest
@testable import Mattermost

/// T29 — thread-safety, proved rather than asserted in a comment:
///
///  * every write runs on the store's writer queue, never on the main actor;
///  * a read on the main thread does not wait for an in-flight write (WAL snapshot);
///  * concurrent writers serialise without losing rows or throwing `SQLITE_BUSY`;
///  * a second connection to the same file (a future notification extension) sees committed writes;
///  * a throwing write is rolled back whole.
final class MMStoreConcurrencyTests: XCTestCase {

    /// A tiny thread-safe flag. `NSLock` rather than an actor because the write closure is
    /// synchronous and must not hop tasks to set it.
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() {
            lock.lock()
            defer { lock.unlock() }
            value = true
        }

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private var harness: StoreHarness!

    override func setUpWithError() throws { harness = try StoreHarness() }
    override func tearDownWithError() throws { harness.cleanup(); harness = nil }

    @MainActor
    func testWritesRunOffTheMainThread() async throws {
        let observations = Observations()
        try await harness.store.write { db in
            observations.append(main: Thread.isMainThread,
                                name: Thread.current.name ?? "<unnamed>")
            return 0
        }
        XCTAssertFalse(observations.first?.main ?? true,
                       "a write from a main-actor call site must not execute SQL on the main thread")
    }

    @MainActor
    func testAReadOnTheMainThreadDoesNotWaitForAnInFlightWrite() async throws {
        let writeStarted = Flag()
        let store = harness.store
        let write = Task {
            try await store.write { db in
                try db.execute(sql: "INSERT INTO channel (id, team_id) VALUES ('c1', '')")
                writeStarted.set()
                // Hold the write transaction open long enough to make the overlap certain.
                Thread.sleep(forTimeInterval: 0.4)
                try db.execute(sql: "INSERT INTO channel (id, team_id) VALUES ('c2', '')")
                return 0
            }
        }

        var spins = 0
        while !writeStarted.isSet && spins < 400 {
            try await Task.sleep(nanoseconds: 5_000_000)
            spins += 1
        }
        XCTAssertTrue(writeStarted.isSet, "the write never started")

        let started = Date()
        let duringWrite = try harness.channels.channels(teamID: "")
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 0.2,
                          "a WAL snapshot read must not block behind the writer (took \(elapsed)s)")
        XCTAssertTrue(duringWrite.isEmpty,
                      "the read sees the last committed snapshot, not the uncommitted write")

        try await write.value
        XCTAssertEqual(try harness.channels.channels(teamID: "").count, 2)
    }

    func testManyConcurrentWritersAllLand() async throws {
        let store = harness.store
        let posts = harness.posts
        try await withThrowingTaskGroup(of: Void.self) { group in
            for writer in 0..<20 {
                group.addTask {
                    let batch = (0..<50).map { index in
                        T29Fixtures.post(id: "w\(writer)-p\(index)", channelID: "c1",
                                         createAt: Int64(writer * 1000 + index))
                    }
                    try await posts.upsert(batch)
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(try posts.count(inChannel: "c1"), 1000)
        XCTAssertEqual(try store.rowCount(in: "post"), 1000)
    }

    func testAThrowingWriteIsRolledBackWhole() async throws {
        struct Boom: Error {}
        let store = harness.store
        var thrown = false
        do {
            try await store.write { db in
                try db.execute(sql: "INSERT INTO channel (id, team_id) VALUES ('c1', '')")
                try db.execute(sql: "INSERT INTO channel (id, team_id) VALUES ('c2', '')")
                throw Boom()
            }
        } catch {
            thrown = true
        }
        XCTAssertTrue(thrown)
        XCTAssertEqual(try store.rowCount(in: "channel"), 0,
                       "a failed transaction leaves no half-applied rows")

        // The store is still usable afterwards.
        try await harness.channels.upsert([T29Fixtures.channel(id: "c3")])
        XCTAssertEqual(try store.rowCount(in: "channel"), 1)
    }

    func testASecondConnectionToTheSameFileSeesCommittedWrites() async throws {
        // The shape a notification-service extension will use: two processes, one file, WAL.
        let second = try MMStore.open(at: harness.path, serverID: "server-1",
                                      serverURL: URL(string: "https://mm.invalid")!)
        defer { second.close() }
        let secondPosts = SQLitePostRepository(store: second)

        try await harness.posts.upsert([T29Fixtures.post(id: "p1", channelID: "c1", createAt: 1)])
        XCTAssertEqual(try secondPosts.post("p1")?.message, "hello")

        try await secondPosts.upsert([T29Fixtures.post(id: "p2", channelID: "c1", createAt: 2)])
        XCTAssertEqual(try harness.posts.count(inChannel: "c1"), 2,
                       "writes from the second connection are visible to the first")
    }

    func testEvictionDuringConcurrentInsertsKeepsTheBudget() async throws {
        harness.cleanup()
        harness = try StoreHarness(retention: MMRetentionPolicy(maxPostsPerChannel: 100,
                                                               evictOnWrite: true,
                                                               evictionSlack: 0))
        let posts = harness.posts
        let store = harness.store
        try await withThrowingTaskGroup(of: Void.self) { group in
            for writer in 0..<8 {
                group.addTask {
                    for batch in 0..<20 {
                        let items = (0..<25).map { index -> MMPost in
                            let ordinal = writer * 500 + batch * 25 + index
                            return T29Fixtures.post(id: "p\(ordinal)", channelID: "c1",
                                                    createAt: Int64(ordinal))
                        }
                        try await posts.upsert(items)
                    }
                }
            }
            try await group.waitForAll()
        }
        let stored = try posts.count(inChannel: "c1")
        XCTAssertLessThanOrEqual(stored, 100,
                                 "concurrent writes cannot push a channel past its window")
        XCTAssertGreaterThan(stored, 0)
        XCTAssertEqual(try store.rowCount(in: "post"), stored,
                       "no orphan rows left by concurrent evictions")
    }
}

/// Records observations from inside a write closure.
final class Observations: @unchecked Sendable {
    struct Entry {
        let main: Bool
        let name: String
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func append(main: Bool, name: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(Entry(main: main, name: name))
    }

    var first: Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries.first
    }
}
