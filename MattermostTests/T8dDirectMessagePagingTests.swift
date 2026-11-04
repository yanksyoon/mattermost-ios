import XCTest
@testable import Mattermost

/// T8d (t_8d539b3f) — Direct messages: the 20 most recent are drawn, the rest arrive with a
/// "Load more" row.
///
/// The owner's words: *"For direct messages group, I want to only load recent 20 in view and rest
/// should be loaded on load more button click."*
///
/// Every test below is one line of the card, pinned where it can actually be false:
///
/// | test | pins |
/// |---|---|
/// | `…TwentyMostRecentAndALoadMoreSayingTwentyFiveRemaining` | 45 DMs → 20 rows + "25 remaining"; two activations → 40; a third → 45 and no control; the 20 are the head of the **existing** `recent` sort, asserted by id |
/// | `…BeyondThePageIsDrawnWithoutPressingLoadMore` | an unread DM at recency position 30 is drawn on the first page, and the group marker agrees |
/// | `…PromotionIsStableAcrossBadgeRefreshes` | two identical counter refreshes leave the drawn ids byte-for-byte identical |
/// | `…FilteringSearchesEveryDirectMessage…` | the quick-switcher filter sees all 45 (including the capped one); the sidebar comes back to its page, with whatever Load more had revealed |
/// | `…RollUpAndTotalsAreComputedOverEveryDirectMessage…` | `unreadChannels`/`mentions`/the footer totals are identical capped and uncapped |
/// | `…OnlyTheDirectMessagesGroupIsPaged` | a 45-channel `channels` group is untouched |
/// | `…LoadMoreRowIsItsOwnControl…` | the control's identifier/label/value, and that it is not the header's |
@MainActor
final class T8dDirectMessagePagingTests: XCTestCase {

    private let teamID = "team1"
    private let directCategoryID = "dm_me_team1"

    // MARK: - Fixtures

    private func server() -> ServerConfig {
        ServerConfig(name: "Example", url: URL(string: "https://mm.example")!)
    }

    /// `count` direct messages, **most recent first**: `dm0` carries the newest `lastPostAt` and
    /// `dm<count-1>` the oldest, so the `recent` sort the sidebar already uses orders them by index.
    ///
    /// `unread` / `mentions` are keyed by that index (the recency position), which is how the card
    /// talks about them ("a DM at recency position 30").
    private func directMessageData(count: Int,
                                   unread: [Int: Int] = [:],
                                   mentions: [Int: Int] = [:],
                                   displayNames: [Int: String] = [:]) -> ChannelSidebarData {
        var channels: [MMChannel] = []
        var members: [MMChannelMember] = []
        var labels: [String: String] = [:]
        for index in 0..<count {
            let id = "dm\(index)"
            channels.append(MMChannel(id: id,
                                      name: "me__user\(index)",
                                      type: "D",
                                      teamId: teamID,
                                      lastPostAt: Int64(10_000 - index),
                                      totalMsgCount: Int64(unread[index] ?? 0),
                                      createAt: 1))
            members.append(MMChannelMember(channelId: id,
                                           userId: "me",
                                           msgCount: 0,
                                           mentionCount: Int64(mentions[index] ?? 0),
                                           notifyProps: .object(["mark_unread": .string("all")])))
            labels[id] = displayNames[index] ?? String(format: "Person %02d", index)
        }
        var data = ChannelSidebarData(channels: channels, members: members)
        data.categories = [MMSidebarCategory(id: directCategoryID,
                                             userId: "me",
                                             teamId: teamID,
                                             sortOrder: 20,
                                             sorting: "recent",
                                             type: "direct_messages",
                                             displayName: "Direct Messages")]
        data.categoryOrder = [directCategoryID]
        data.directLabels = labels
        return data
    }

    private func loadedModel(_ data: ChannelSidebarData) async -> ChannelListViewModel {
        let model = ChannelListViewModel(server: server(),
                                         service: FakeChannelSidebarService(data: data))
        model.setSelection(teamID: teamID, channelID: nil, channelName: nil)
        await model.load(ifNeeded: false)
        return model
    }

    private func directGroup(_ model: ChannelListViewModel) throws -> ChannelSidebarGroup {
        try XCTUnwrap(model.groups.first { $0.kind == .directMessages },
                      "the fixture has a direct_messages category")
    }

    private func ids(_ entries: [ChannelSidebarEntry]) -> [String] { entries.map(\.id) }

    private func recencyIDs(_ count: Int) -> [String] { (0..<count).map { "dm\($0)" } }

    // MARK: - 1. The cap and the control

    func testFortyFiveDirectMessagesDrawTheTwentyMostRecentAndALoadMoreSayingTwentyFiveRemaining() async throws {
        let model = await loadedModel(directMessageData(count: 45))
        var group = try directGroup(model)

        // The cap is a *rendering* fact: the group still holds every DM, which is what keeps the
        // header's roll-up, the totals and the quick switcher honest (tests 5 and 4).
        XCTAssertEqual(ids(group.entries), recencyIDs(45))
        XCTAssertEqual(ids(group.visibleEntries), recencyIDs(20))
        XCTAssertEqual(group.hiddenCount, 25)
        XCTAssertTrue(group.showsLoadMore)
        XCTAssertEqual(group.loadMoreIdentifier, "channelSidebar.loadMore.direct_messages")

        // The 20 drawn are exactly the first 20 of the existing `recent` sort — by id, not by count.
        let recent = ChannelSidebarDerivation.sorted(group.entries, category: group.category)
        XCTAssertEqual(ids(group.visibleEntries), ids(Array(recent.prefix(20))))
        XCTAssertEqual(ids(group.visibleEntries),
                       ids(Array(group.entries.sorted { max($0.lastPostAt, $0.createdAt)
                                                         > max($1.lastPostAt, $1.createdAt) }.prefix(20))))

        // "Load more": the next 20, then the rest; the control disappears with nothing left.
        model.loadMore(categoryID: group.id)
        group = try directGroup(model)
        XCTAssertEqual(ids(group.visibleEntries), recencyIDs(40))
        XCTAssertEqual(group.hiddenCount, 5)
        XCTAssertTrue(group.showsLoadMore)

        model.loadMore(categoryID: group.id)
        group = try directGroup(model)
        XCTAssertEqual(ids(group.visibleEntries), recencyIDs(45))
        XCTAssertEqual(group.hiddenCount, 0)
        XCTAssertFalse(group.showsLoadMore, "nothing left to reveal — the control is gone")

        // A fourth tap (a stale row, a double click) is a no-op: loadMore refuses once nothing is
        // hidden, so the stored page stays at the 60 revealed by the three real activations.
        let revealedAfterThree = model.revealedCount(categoryID: group.id)
        model.loadMore(categoryID: group.id)
        XCTAssertEqual(ids(try directGroup(model).visibleEntries), recencyIDs(45))
        XCTAssertEqual(revealedAfterThree, 60)
        XCTAssertEqual(model.revealedCount(categoryID: group.id), revealedAfterThree)
    }

    /// A short list — 25 DMs — leaves 5 after the first page, and one activation finishes it.
    func testTwentyFiveDirectMessagesNeedOneLoadMoreAndThenTheControlIsGone() async throws {
        let model = await loadedModel(directMessageData(count: 25))
        var group = try directGroup(model)
        XCTAssertEqual(group.visibleEntries.count, 20)
        XCTAssertEqual(group.hiddenCount, 5)

        model.loadMore(categoryID: group.id)
        group = try directGroup(model)
        XCTAssertEqual(ids(group.visibleEntries), recencyIDs(25))
        XCTAssertFalse(group.showsLoadMore)
    }

    // MARK: - 2. Unread is never hidden by the cap

    func testAnUnreadDirectMessageBeyondThePageIsDrawnWithoutPressingLoadMore() async throws {
        // 45 DMs, and the one at recency position 30 has four unread posts.
        let model = await loadedModel(directMessageData(count: 45, unread: [30: 4]))
        let group = try directGroup(model)
        let drawn = ids(group.visibleEntries)

        // Present on the first page — no Load more needed, so the row the header points at exists.
        XCTAssertTrue(drawn.contains("dm30"), "an unread DM must never sit below the cap")
        // …and the first page's own order is untouched: promotion appends, it does not reshuffle.
        XCTAssertEqual(Array(drawn.prefix(20)), recencyIDs(20))
        XCTAssertEqual(drawn.last, "dm30", "promoted rows are appended in the group's draw order")
        XCTAssertEqual(group.hiddenCount, 24, "the promoted row is drawn, so it is not 'remaining'")

        // The header's marker and the promotion agree by construction: both read the row rule.
        XCTAssertEqual(group.unreadChannels, 1)
        XCTAssertTrue(group.hasUnread)
        XCTAssertEqual(group.headerBadge, .dot)
        XCTAssertTrue(group.accessibilityValue.contains("Unread"))
    }

    func testPromotionIsStableAcrossBadgeRefreshes() async throws {
        let model = await loadedModel(directMessageData(count: 45, unread: [30: 4, 37: 2]))
        let before = ids(try directGroup(model).visibleEntries)
        XCTAssertEqual(before, recencyIDs(20) + ["dm30", "dm37"])

        // Two identical refreshes: the counters are re-read, nothing about unread changed, so the
        // drawn list must be identical — no reshuffle on every badge tick.
        await model.refreshCounters()
        XCTAssertEqual(ids(try directGroup(model).visibleEntries), before)
        await model.refreshCounters()
        XCTAssertEqual(ids(try directGroup(model).visibleEntries), before)

        // And a page already revealed keeps its promotions where they were.
        model.loadMore(categoryID: try directGroup(model).id)
        let afterPage = ids(try directGroup(model).visibleEntries)
        XCTAssertEqual(Array(afterPage.prefix(40)), recencyIDs(40))
        await model.refreshCounters()
        XCTAssertEqual(ids(try directGroup(model).visibleEntries), afterPage)
    }

    /// A read DM drops out of the promoted tail — the one thing that may change the drawn list — and
    /// the twenty recent rows still do not move.
    func testReadingAPromotedDirectMessageOnlyRemovesItFromTheTail() async throws {
        let model = await loadedModel(directMessageData(count: 45, unread: [30: 4]))
        XCTAssertEqual(ids(try directGroup(model).visibleEntries), recencyIDs(20) + ["dm30"])

        model.handle(.channelViewed(SocketChannelViewed(channelID: "dm30", userID: "me")), myUserID: "me")
        let group = try directGroup(model)
        XCTAssertEqual(ids(group.visibleEntries), recencyIDs(20))
        XCTAssertEqual(group.hiddenCount, 25)
    }

    // MARK: - 3. Filtering bypasses the cap

    func testFilteringSearchesEveryDirectMessageAndClearingItComesBackToThePage() async throws {
        let model = await loadedModel(directMessageData(count: 45, displayNames: [30: "Ana Outside"]))
        var group = try directGroup(model)
        XCTAssertFalse(ids(group.visibleEntries).contains("dm30"), "the fixture must start capped")

        // Typing searches every DM, not the page: the match at recency position 30 is found.
        XCTAssertEqual(model.searchResults(for: "ana").map(\.id).first, "dm30")
        // "person" matches the other 44 labels ("Person 00"…) — including rows the cap is hiding,
        // which is the whole point: dm40 is a page past the DMs on screen.
        let people = model.searchResults(for: "person")
        XCTAssertEqual(people.count, 44)
        XCTAssertTrue(people.map(\.id).contains("dm40"))
        XCTAssertTrue(people.map(\.id).contains("dm44"))
        // Asking the filter did not page the sidebar.
        XCTAssertEqual(ids(try directGroup(model).visibleEntries), recencyIDs(20))

        // A page revealed before the filter is still there after it is cleared.
        model.loadMore(categoryID: group.id)
        group = try directGroup(model)
        XCTAssertEqual(group.visibleEntries.count, 40)
        _ = model.searchResults(for: "ana")
        XCTAssertEqual(try directGroup(model).visibleEntries.count, 40)

        // Clearing the filter (an empty query) returns the whole list, and the sidebar is back on
        // its page — 20 here, because nothing had been revealed in this session yet.
        XCTAssertEqual(model.searchResults(for: "").count, 45)
        XCTAssertEqual(try directGroup(model).visibleEntries.count, 40)
    }

    func testAFreshModelStartsOnTheFirstPageEvenAfterAnotherSessionRevealedMore() async throws {
        let data = directMessageData(count: 45)
        let first = await loadedModel(data)
        first.loadMore(categoryID: try directGroup(first).id)
        XCTAssertEqual(try directGroup(first).visibleEntries.count, 40)

        // No persistence: a second model (a relaunch) is back to 20.
        let second = await loadedModel(data)
        XCTAssertEqual(try directGroup(second).visibleEntries.count, 20)
        XCTAssertNil(second.revealedCount(categoryID: directCategoryID))
    }

    // MARK: - 4. The roll-up and the totals stay honest

    func testTheGroupRollUpAndTheTotalsAreComputedOverEveryDirectMessageNotThePage() async throws {
        let data = directMessageData(count: 45,
                                     unread: [3: 2, 30: 5, 41: 1],
                                     mentions: [30: 2])
        let model = await loadedModel(data)
        let capped = try directGroup(model)
        let uncapped = try XCTUnwrap(ChannelSidebarDerivation
            .groups(from: data,
                    selectedChannelID: nil,
                    selectedChannelName: nil,
                    revealed: [directCategoryID: 45])
            .first)

        XCTAssertEqual(capped.visibleEntries.count, 22, "20 recent + the two unread rows beyond them")
        // Same numbers as a group that draws every row: the cap cannot make the header under-report.
        XCTAssertEqual(capped.unreadChannels, 3)
        XCTAssertEqual(capped.mentions, 2)
        XCTAssertEqual(capped.unreadChannels, uncapped.unreadChannels)
        XCTAssertEqual(capped.mentions, uncapped.mentions)
        XCTAssertEqual(ChannelSidebarDerivation.totals([capped]),
                       ChannelSidebarDerivation.totals([uncapped]))

        // …and the footer the model publishes is those totals, not the page's.
        XCTAssertEqual(model.totals.messages, 8, "2 + 5 + 1 unread posts, all beyond/inside the page")
        XCTAssertEqual(model.totals.mentions, 2)
        XCTAssertEqual(model.totals.unreadChannels, 3)
    }

    // MARK: - 5. Only Direct messages is paged

    func testOnlyTheDirectMessagesGroupIsPaged() async throws {
        var data = directMessageData(count: 45)
        var channels: [MMChannel] = []
        var members: [MMChannelMember] = []
        var channelIDs: [String] = []
        for index in 0..<45 {
            let id = "c\(index)"
            channelIDs.append(id)
            channels.append(MMChannel(id: id,
                                      name: "chan-\(index)",
                                      displayName: "Chan \(String(format: "%02d", index))",
                                      type: "O",
                                      teamId: teamID,
                                      createAt: Int64(index + 1)))
            members.append(MMChannelMember(channelId: id, userId: "me"))
        }
        data.channels += channels
        data.members += members
        data.categories.append(MMSidebarCategory(id: "channels_me_team1",
                                                 userId: "me",
                                                 teamId: teamID,
                                                 sortOrder: 10,
                                                 sorting: "alpha",
                                                 type: "channels",
                                                 displayName: "Channels",
                                                 channelIds: channelIDs))
        data.categoryOrder = ["channels_me_team1", directCategoryID]

        let model = await loadedModel(data)
        let named = try XCTUnwrap(model.groups.first { $0.kind == .channels })
        XCTAssertEqual(named.entries.count, 45)
        XCTAssertEqual(named.visibleEntries.count, 45, "a named category is drawn whole")
        XCTAssertFalse(named.showsLoadMore)
        XCTAssertEqual(named.revealed, .max)
        XCTAssertEqual(try directGroup(model).visibleEntries.count, 20)
    }

    // MARK: - 6. The control itself

    func testTheLoadMoreRowIsItsOwnControlWithAStableIdentifierAndTheRemainingCountAsItsValue() throws {
        let data = directMessageData(count: 45, unread: [30: 4])
        let group = try XCTUnwrap(ChannelSidebarDerivation
            .groups(from: data, selectedChannelID: nil, selectedChannelName: nil)
            .first)

        XCTAssertEqual(group.identifier, "channelSidebar.category.direct_messages",
                       "the header's identifier is unchanged, so existing UI tests keep matching")
        XCTAssertEqual(group.loadMoreIdentifier, "channelSidebar.loadMore.direct_messages")
        XCTAssertNotEqual(group.loadMoreIdentifier, group.identifier,
                          "the control is not the header: a different identifier, a different element")

        // The row is labelled "Load more" and carries the remaining count as its accessibility
        // value, which is what a VoiceOver user (and a UI test) reads.
        let row = ChannelSidebarLoadMoreRow(remaining: group.hiddenCount,
                                            identifier: group.loadMoreIdentifier) {}
        XCTAssertEqual(row.accessibilityValue, "24 remaining")
        XCTAssertEqual(ChannelSidebarLoadMoreRow(remaining: 1, identifier: "x") {}
            .accessibilityValue, "1 remaining")
        XCTAssertEqual(group.hiddenCount, 24)

        // A group with nothing hidden says nothing: the control only exists while it can do work.
        let whole = try XCTUnwrap(ChannelSidebarDerivation
            .groups(from: directMessageData(count: 12), selectedChannelID: nil, selectedChannelName: nil)
            .first)
        XCTAssertEqual(whole.visibleEntries.count, 12)
        XCTAssertFalse(whole.showsLoadMore)
        XCTAssertEqual(whole.revealed, ChannelSidebarDerivation.directMessagesPageSize,
                       "a short group is paged by the same page size, it just has nothing for it to hide")
    }

    /// The 45-row assertion again, this time on the derivation alone (no model), so a change to the
    /// **page arithmetic** fails here even if the model's bookkeeping masks it.
    func testTheDerivationPagesTheDirectMessagesGroupToTwentyOnItsOwn() throws {
        let data = directMessageData(count: 45)
        let group = try XCTUnwrap(ChannelSidebarDerivation
            .groups(from: data, selectedChannelID: nil, selectedChannelName: nil)
            .first)
        XCTAssertEqual(group.revealed, 20)
        XCTAssertEqual(group.visibleEntries.count, 20)
        XCTAssertEqual(group.hiddenCount, 25)

        let more = try XCTUnwrap(ChannelSidebarDerivation
            .groups(from: data,
                    selectedChannelID: nil,
                    selectedChannelName: nil,
                    revealed: [directCategoryID: 40])
            .first)
        XCTAssertEqual(more.visibleEntries.count, 40)
        XCTAssertEqual(more.hiddenCount, 5)

        // A value below the first page cannot shorten it (a guard against a bad default).
        let tiny = try XCTUnwrap(ChannelSidebarDerivation
            .groups(from: data,
                    selectedChannelID: nil,
                    selectedChannelName: nil,
                    revealed: [directCategoryID: 1])
            .first)
        XCTAssertEqual(tiny.visibleEntries.count, 20)
    }
}
