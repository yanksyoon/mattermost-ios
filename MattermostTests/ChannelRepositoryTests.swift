import Foundation
import XCTest
@testable import Mattermost

/// T29 — channel ordering and the unread aggregates the sidebar/badge read, plus the "a deleted
/// channel takes its posts with it" bookkeeping. Protocol-level parity is in
/// `RepositoryContractTests`; this file covers the SQL-side ordering and scoping.
final class ChannelRepositoryTests: XCTestCase {

    private var harness: StoreHarness!

    override func setUpWithError() throws { harness = try StoreHarness() }
    override func tearDownWithError() throws { harness.cleanup(); harness = nil }

    func testChannelsAreOrderedByNewestActivityInsideATeam() async throws {
        try await harness.channels.upsert([
            T29Fixtures.channel(id: "c1", teamID: "t1", displayName: "Alpha", lastPostAt: 100),
            T29Fixtures.channel(id: "c2", teamID: "t1", displayName: "Beta", lastPostAt: 300),
            T29Fixtures.channel(id: "c3", teamID: "t1", displayName: "Gamma", lastPostAt: 200),
            T29Fixtures.channel(id: "c4", teamID: "t2", displayName: "Other", lastPostAt: 999),
            T29Fixtures.channel(id: "dm1", teamID: "", displayName: "ada", type: "D", lastPostAt: 50),
        ])
        XCTAssertEqual(try harness.channels.channels(teamID: "t1").map(\.id), ["c2", "c3", "c1"])
        XCTAssertEqual(try harness.channels.channels(teamID: "t2").map(\.id), ["c4"])
        XCTAssertEqual(try harness.channels.channels(teamID: "").map(\.id), ["dm1"])
        XCTAssertEqual(try harness.channels.channels(teamID: "missing").count, 0)
    }

    func testRecentChannelsFollowLastViewed() async throws {
        try await harness.channels.upsert([
            T29Fixtures.channel(id: "c1"), T29Fixtures.channel(id: "c2"), T29Fixtures.channel(id: "c3"),
        ])
        try await harness.channels.upsertMembership([
            T29Fixtures.member(channelID: "c1", lastViewedAt: 100),
            T29Fixtures.member(channelID: "c2", lastViewedAt: 900),
            T29Fixtures.member(channelID: "c3", lastViewedAt: 500),
            // A channel the user is not a member of must not appear.
            T29Fixtures.member(channelID: "c9", userID: "someone-else", lastViewedAt: 1000),
        ])
        XCTAssertEqual(try harness.channels.recentChannels(userID: "user-1", limit: 10).map(\.id),
                       ["c2", "c3", "c1"])
        XCTAssertEqual(try harness.channels.recentChannels(userID: "user-1", limit: 2).map(\.id),
                       ["c2", "c3"])
        XCTAssertEqual(try harness.channels.recentChannels(userID: "user-1", limit: 0).count, 0)
    }

    func testUnreadTotalsAreScopedToOneUser() async throws {
        try await harness.channels.upsertMembership([
            T29Fixtures.member(channelID: "c1", userID: "user-1", msgCount: 3, mentionCount: 1),
            T29Fixtures.member(channelID: "c2", userID: "user-1", msgCount: 2, mentionCount: 0),
            T29Fixtures.member(channelID: "c1", userID: "user-2", msgCount: 99, mentionCount: 99),
        ])
        let totals = try harness.channels.unreadTotals(userID: "user-1")
        XCTAssertEqual(totals.messageCount, 5)
        XCTAssertEqual(totals.mentionCount, 1)
        XCTAssertEqual(totals.unreadChannelCount, 2)
        XCTAssertEqual(try harness.channels.unreadByChannel(userID: "user-2").count, 1)
    }

    func testServerUnreadCountersApplyAfterARead() async throws {
        try await harness.channels.upsertMembership([
            T29Fixtures.member(channelID: "c1", msgCount: 3, mentionCount: 2, lastViewedAt: 100),
        ])
        try await harness.channels.markRead(channelID: "c1", userID: "user-1", viewedAt: 200)
        XCTAssertFalse(try harness.channels.unread(channelID: "c1", userID: "user-1").isUnread)

        // A later server snapshot brings new unread messages.
        try await harness.channels.setUnread(channelID: "c1", userID: "user-1",
                                             messageCount: 7, mentionCount: 1, lastViewedAt: 200)
        let unread = try harness.channels.unread(channelID: "c1", userID: "user-1")
        XCTAssertEqual(unread.messageCount, 7)
        XCTAssertEqual(unread.mentionCount, 1)
        XCTAssertTrue(unread.isUnread)
        XCTAssertEqual(unread.lastViewedAt, 200)
    }

    func testSetUnreadOnAChannelWithNoMembershipRowIsANoOp() async throws {
        try await harness.channels.setUnread(channelID: "c1", userID: "user-1",
                                             messageCount: 5, mentionCount: 1, lastViewedAt: 1)
        XCTAssertNil(try harness.channels.membership(channelID: "c1", userID: "user-1"))
        XCTAssertEqual(try harness.channels.unread(channelID: "c1", userID: "user-1").messageCount, 0)
    }

    func testDeletingAChannelAlsoRemovesItsReactionsAndFiles() async throws {
        try await harness.channels.upsert([T29Fixtures.channel(id: "c1")])
        try await harness.posts.upsert([T29Fixtures.post(id: "p1", channelID: "c1", createAt: 1)])
        try await harness.posts.upsertReactions([T29Fixtures.reaction(postID: "p1")])
        try await harness.posts.upsertFiles([T29Fixtures.file(id: "f1", postID: "p1")])

        let removed = try await harness.channels.delete(channelID: "c1")
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(try harness.store.rowCount(in: "post"), 0)
        XCTAssertEqual(try harness.store.rowCount(in: "post_reaction"), 0)
        XCTAssertEqual(try harness.store.rowCount(in: "file_info"), 0)
    }

    func testChannelUpsertIsIdempotentAndUpdatesInPlace() async throws {
        try await harness.channels.upsert([T29Fixtures.channel(id: "c1", displayName: "Before")])
        try await harness.channels.upsert([T29Fixtures.channel(id: "c1", displayName: "After",
                                                               lastPostAt: 42)])
        XCTAssertEqual(try harness.channels.channel("c1")?.displayName, "After")
        XCTAssertEqual(try harness.channels.channel("c1")?.lastPostAt, 42)
        XCTAssertEqual(try harness.store.rowCount(in: "channel"), 1)
    }
}
