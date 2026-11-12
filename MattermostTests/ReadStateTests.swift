// t_e9550303 — the read cursor in the native channel pane.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
//   - `app/actions/remote/channel.ts:746` `markChannelAsRead` → `client.viewMyChannel`
//   - `app/client/rest/channels.ts:369` — `POST /channels/members/me/view`, body
//     `{channel_id, prev_channel_id, collapsed_threads_supported: true}` (not `/channels/{id}/view`,
//     not `mark_read`)
//   - `app/screens/channel/channel_post_list/channel_post_list.tsx:92-109` — posts the view when the
//     post count grows while the app is active, and when the app becomes active; unmount/background
//     sends the empty-channel unset
//   - `app/actions/websocket/channel.ts:141` — `channel_viewed` for a channel that is not current
//     clears it locally
//
// The card's T1-T6 are the spine. The failure each one pins is a real one: no view at all (T1), the
// state clearing only after a refresh (T2), a cursor that advances while nobody is looking (T3), a
// read on another device that never clears this one (T4), a new post that leaves the row bold (T5),
// and the mute rule being broken by the clear (T6).

import XCTest
@testable import Mattermost

@MainActor
final class ReadStateTests: XCTestCase {

    // MARK: - Fixtures

    private let channelID = "c1"
    private let otherChannelID = "c2"
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ReadStateTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// The `ChannelServing` seam: one page of posts and a scripted view answer.
    @MainActor
    final class FakeChannelService: ChannelServing {
        var pageSize = 60
        /// Newest first, the server's order.
        var page: [MMPost] = []
        var viewResponse = MMChannelViewResponse(status: "OK")
        var viewError: Error?
        var viewDelay: Duration = .zero
        private(set) var viewedChannelIDs: [String] = []
        private(set) var previousChannelIDs: [String?] = []

        func channel(id: String) async throws -> MMChannel { throw MMError.notFound }

        func posts(channelID: String, before: String?, perPage: Int) async throws -> MMPostList {
            guard before == nil else { return MMPostList(order: [], posts: [:]) }
            return MMPostList(order: page.map(\.id),
                              posts: Dictionary(uniqueKeysWithValues: page.map { ($0.id, $0) }))
        }

        func users(ids: [String]) async throws -> [MMUser] { [] }

        func fileData(fileID: String, preferThumbnail: Bool) async throws -> Data {
            throw MMError.notFound
        }

        func viewChannel(channelID: String, previousChannelID: String?) async throws -> MMChannelViewResponse {
            viewedChannelIDs.append(channelID)
            previousChannelIDs.append(previousChannelID)
            if viewDelay > .zero { try? await Task.sleep(for: viewDelay) }
            if let viewError { throw viewError }
            return viewResponse
        }
    }

    private func post(_ id: String, at millis: Int64, channel: String? = nil) -> MMPost {
        MMPost(id: id,
               createAt: millis,
               userId: "u1",
               channelId: channel ?? channelID,
               message: "message \(id)")
    }

    private func model(_ service: FakeChannelService) -> ChannelViewModel {
        ChannelViewModel(channelID: channelID,
                         channelName: "Town Square",
                         service: service,
                         myUserID: "me",
                         now: { Date(timeIntervalSince1970: 1_800_000_000) })
    }

    // MARK: - Sidebar fixture

    private func channel(_ id: String, name: String, totalMsgCount: Int64) -> MMChannel {
        MMChannel(id: id, name: name, displayName: name.capitalized, type: "O",
                  teamId: "team1", lastPostAt: 10, totalMsgCount: totalMsgCount,
                  createAt: 1, deleteAt: 0)
    }

    private func member(_ channelID: String, msgCount: Int64, mentions: Int64,
                        muted: Bool = false, manuallyUnread: Bool = false) -> MMChannelMember {
        MMChannelMember(channelId: channelID,
                        userId: "me",
                        lastViewedAt: 0,
                        msgCount: msgCount,
                        mentionCount: mentions,
                        manuallyUnread: manuallyUnread,
                        notifyProps: .object(["mark_unread": .string(muted ? "mention" : "all")]))
    }

    private func category(_ id: String, channelIDs: [String]) -> MMSidebarCategory {
        MMSidebarCategory(id: id, userId: "me", teamId: "team1", sortOrder: 10,
                          sorting: "manual", type: "channels", displayName: "Channels",
                          muted: false, collapsed: false, channelIds: channelIDs)
    }

    /// Two channels in one category: `c1` unread with mentions, `c2` unread without.
    private func sidebarData(c1Mentions: Int64 = 2,
                             c1Muted: Bool = false,
                             c2Mentions: Int64 = 0) -> ChannelSidebarData {
        var data = ChannelSidebarData(
            channels: [channel(channelID, name: "alpha", totalMsgCount: 10),
                       channel(otherChannelID, name: "bravo", totalMsgCount: 4)],
            members: [member(channelID, msgCount: 4, mentions: c1Mentions, muted: c1Muted),
                      member(otherChannelID, msgCount: 1, mentions: c2Mentions)])
        data.categories = [category("chan", channelIDs: [channelID, otherChannelID])]
        data.categoryOrder = ["chan"]
        return data
    }

    private func server() -> ServerConfig {
        ServerConfig(name: "Example", url: URL(string: "https://mm.example")!)
    }

    private func loadedSidebar(_ data: ChannelSidebarData) async -> (ChannelListViewModel, FakeChannelSidebarService) {
        let fake = FakeChannelSidebarService(data: data)
        let list = ChannelListViewModel(server: server(), service: fake)
        list.setSelection(teamID: "team1", channelID: nil, channelName: nil)
        await list.load()
        return (list, fake)
    }

    private func sessionStore() -> (SessionStore, RecordingBadge) {
        let badge = RecordingBadge()
        let defaults = UserDefaults(suiteName: suiteName)!
        return (SessionStore(preferences: AppPreferences(defaults: defaults), badgeSetter: badge), badge)
    }

    // MARK: - T1: opening posts exactly one view, with the channel id

    func testT1OpeningAChannelPostsExactlyOneViewForThatChannel() async {
        let service = FakeChannelService()
        service.page = [post("c", at: 3_000), post("b", at: 2_000), post("a", at: 1_000)]
        service.viewResponse = MMChannelViewResponse(status: "OK", lastViewedAtTimes: [channelID: 3_000])
        let model = model(service)

        // The pane appears, the scene is active and the reader is at the newest row.
        model.setReadingState(paneVisible: true, sceneActive: true, readerAtNewest: true)
        await model.load()
        await model.awaitViewSettled()

        XCTAssertEqual(service.viewedChannelIDs, [channelID])
        XCTAssertEqual(service.previousChannelIDs, [nil])
        XCTAssertEqual(model.viewCallCount, 1)
        XCTAssertNil(model.lastViewError)
    }

    /// The same model rendered without a host (no pane, no scene) posts nothing — the gate is not a
    /// view-level convention, it is in the model.
    func testT1WithoutReadingStateLoadPostsNoView() async {
        let service = FakeChannelService()
        service.page = [post("a", at: 1_000)]
        let model = model(service)
        await model.load()
        await model.awaitViewSettled()
        XCTAssertEqual(model.viewCallCount, 0)
        XCTAssertEqual(service.viewedChannelIDs, [])
    }

    // MARK: - T2: the response clears row, group and badge in the same update

    func testT2ALandedViewClearsTheRowTheGroupAndTheBadgeTogether() async {
        let (list, _) = await loadedSidebar(sidebarData())
        let (store, _) = sessionStore()
        let serverID = UUID()
        // The badge starts at two mentions, no unread dot (this channel is the only unread thing).
        store.applyServerCounters(serverID: serverID, mentionCounts: [2], messageCounts: [9])
        XCTAssertEqual(store.badgeNumber, 2)

        let service = FakeChannelService()
        service.page = [post("c", at: 3_000), post("b", at: 2_000)]
        service.viewResponse = MMChannelViewResponse(status: "OK", lastViewedAtTimes: [channelID: 3_000])
        let model = model(service)
        // The app's wiring, through the production function: one landing point for the three values.
        model.onViewed = { [weak list, weak store] viewedChannelID, response in
            ChannelReadApplication.apply(channelID: viewedChannelID,
                                         response: response,
                                         sidebar: list,
                                         sessionStore: store,
                                         serverID: serverID)
        }

        // Before: the row is bold and badged with its mention count (t_93eca948: the row counts), and
        // the group rolls those numbers up.
        let before = list.entry(id: channelID)
        XCTAssertEqual(before?.showsUnreadEmphasis, true)
        XCTAssertEqual(before?.badge, .mentions(2, urgent: false))
        let groupBefore = list.groups.first { $0.id == "chan" }
        XCTAssertEqual(groupBefore?.unreadChannels, 2)
        XCTAssertEqual(groupBefore?.headerBadge, .unread(5),
                       "2 mentions (c1) + 3 unread posts (c2): the header is the sum of what the rows draw")

        model.setReadingState(paneVisible: true, sceneActive: true, readerAtNewest: true)
        await model.load()
        await model.awaitViewSettled()

        // After — all three derived values from the same server answer, with no refresh in between.
        XCTAssertEqual(list.entry(id: channelID)?.showsUnreadEmphasis, false)
        XCTAssertEqual(list.entry(id: channelID)?.badge, ChannelSidebarBadge.none)
        XCTAssertEqual(list.entry(id: channelID)?.mentionCount, 0)
        XCTAssertEqual(list.entry(id: channelID)?.unreadCount, 0)
        XCTAssertEqual(list.groups.first { $0.id == "chan" }?.unreadChannels, 1,
                       "the other unread channel keeps the group marker")
        XCTAssertEqual(list.groups.first { $0.id == "chan" }?.headerBadge, .unread(3),
                       "the roll-up dropped with the row: only c2's 3 unread posts are left")
        XCTAssertEqual(store.totalMentions, 0, "the mention number left the badge in the same tick")
        // The server also said this server still has unread messages, so the badge becomes its
        // message total rather than zero (t_93eca948: a number, not the dot's 1). The rest of the
        // clearing is the counter read's job — the same request the mention poller makes — never a
        // guess made from one channel.
        XCTAssertTrue(store.hasUnread)
        XCTAssertEqual(store.badgeNumber, 9)
    }

    /// The authoritative counter read (the poller's own request) then zeroes the badge too.
    func testT2TheCounterReadZeroesTheBadgeAfterTheLastUnreadChannelIsRead() async {
        let (list, _) = await loadedSidebar(sidebarData(c1Mentions: 2))
        let (store, badge) = sessionStore()
        let serverID = UUID()
        store.applyServerCounters(serverID: serverID, mentionCounts: [2], messageCounts: [9])
        XCTAssertEqual(store.badgeNumber, 2)

        let outcome = ChannelReadApplication.apply(
            channelID: channelID,
            response: MMChannelViewResponse(status: "OK", lastViewedAtTimes: [channelID: 1_000]),
            sidebar: list,
            sessionStore: store,
            serverID: serverID)
        XCTAssertEqual(outcome?.clearedMentions, 2)
        XCTAssertEqual(store.totalMentions, 0)
        XCTAssertEqual(store.badgeNumber, 9, "the mention number left; the server's 9 unread messages remain")

        // `GET /users/me/teams/unread` says every team is now read.
        ChannelReadApplication.applyCounters([MMTeamUnread(teamId: "team1", mentionCount: 0, msgCount: 0)],
                                             sessionStore: store,
                                             serverID: serverID)
        XCTAssertEqual(store.badgeNumber, 0)
        XCTAssertEqual(badge.sets.last, 0, "the badge setter was told about the drop")
    }

    /// Reading one channel must not clear a different one (the card's second adversarial case).
    func testT2ReadingOneChannelDoesNotClearAnother() async {
        let (list, _) = await loadedSidebar(sidebarData(c2Mentions: 1))
        let (store, _) = sessionStore()
        let serverID = UUID()
        store.applyServerCounters(serverID: serverID, mentionCounts: [3], messageCounts: [9])

        let service = FakeChannelService()
        service.page = [post("a", at: 1_000)]
        service.viewResponse = MMChannelViewResponse(status: "OK", lastViewedAtTimes: [channelID: 1_000])
        let model = model(service)
        model.onViewed = { [weak list, weak store] viewedChannelID, response in
            ChannelReadApplication.apply(channelID: viewedChannelID,
                                         response: response,
                                         sidebar: list,
                                         sessionStore: store,
                                         serverID: serverID)
        }
        model.setReadingState(paneVisible: true, sceneActive: true, readerAtNewest: true)
        await model.load()
        await model.awaitViewSettled()

        XCTAssertEqual(list.entry(id: channelID)?.showsUnreadEmphasis, false)
        XCTAssertEqual(list.entry(id: otherChannelID)?.showsUnreadEmphasis, true)
        XCTAssertEqual(list.entry(id: otherChannelID)?.mentionCount, 1)
        XCTAssertEqual(store.totalMentions, 1, "only this channel's mentions left the badge")
        XCTAssertEqual(store.badgeNumber, 1)
    }

    // MARK: - T3: a channel that is not being read posts nothing

    func testT3BackgroundSceneScrollUpAndHiddenPaneAllPostNothing() async {
        for (paneVisible, sceneActive, atNewest, label) in [
            (true, false, true, "backgrounded scene"),
            (true, true, false, "scrolled up into history"),
            (false, true, true, "pane not visible (another tab/thread on top)"),
        ] {
            let service = FakeChannelService()
            service.page = [post("c", at: 3_000), post("b", at: 2_000)]
            let model = model(service)
            model.setReadingState(paneVisible: paneVisible,
                                  sceneActive: sceneActive,
                                  readerAtNewest: atNewest)
            await model.load()
            await model.awaitViewSettled()
            XCTAssertEqual(model.viewCallCount, 0, "posted a view while \(label)")
            XCTAssertEqual(service.viewedChannelIDs, [], "posted a view while \(label)")
        }
    }

    /// Scrolling back to the newest row is what re-arms the cursor; nothing is posted before that.
    func testT3ReturningToTheNewestRowPostsTheView() async {
        let service = FakeChannelService()
        service.page = [post("b", at: 2_000), post("a", at: 1_000)]
        service.viewResponse = MMChannelViewResponse(status: "OK", lastViewedAtTimes: [channelID: 2_000])
        let model = model(service)
        model.setReadingState(paneVisible: true, sceneActive: true, readerAtNewest: false)
        await model.load()
        await model.awaitViewSettled()
        XCTAssertEqual(model.viewCallCount, 0)

        model.setReadingState(paneVisible: true, sceneActive: true, readerAtNewest: true)
        await model.awaitViewSettled()
        XCTAssertEqual(model.viewCallCount, 1)
        XCTAssertEqual(service.viewedChannelIDs, [channelID])
    }

    // MARK: - T4: channel_viewed from another device clears here

    func testT4ChannelViewedFromAnotherDeviceClearsTheRowAndGroup() async {
        let (list, _) = await loadedSidebar(sidebarData())
        XCTAssertEqual(list.entry(id: channelID)?.showsUnreadEmphasis, true)

        // The same user, a different client: `channel_viewed` carries the user id, not the device.
        let outcome = list.handle(.channelViewed(SocketChannelViewed(channelID: channelID, userID: "me")),
                                  myUserID: "me")
        XCTAssertEqual(outcome, .counters)
        XCTAssertEqual(list.entry(id: channelID)?.showsUnreadEmphasis, false)
        XCTAssertEqual(list.entry(id: channelID)?.badge, ChannelSidebarBadge.none)
        XCTAssertEqual(list.groups.first { $0.id == "chan" }?.unreadChannels, 1,
                       "the untouched channel keeps the group marker")
    }

    /// Another account's view does not clear mine.
    func testT4AnotherAccountsChannelViewedIsIgnored() async {
        let (list, _) = await loadedSidebar(sidebarData())
        let outcome = list.handle(.channelViewed(SocketChannelViewed(channelID: channelID, userID: "them")),
                                  myUserID: "me")
        XCTAssertEqual(outcome, .ignored)
        XCTAssertEqual(list.entry(id: channelID)?.showsUnreadEmphasis, true)
    }

    // MARK: - T5: a post while the reader is looking re-posts and clears again

    func testT5ANewPostWhileVisibleRePostsTheViewAndClearsAgain() async {
        let (list, _) = await loadedSidebar(sidebarData())
        let service = FakeChannelService()
        service.page = [post("b", at: 2_000), post("a", at: 1_000)]
        service.viewResponse = MMChannelViewResponse(status: "OK", lastViewedAtTimes: [channelID: 2_000])
        let model = model(service)
        model.onViewed = { [weak list] viewedChannelID, response in
            list?.applyRead(channelID: viewedChannelID, cursors: response.lastViewedAtTimes)
        }
        model.setReadingState(paneVisible: true, sceneActive: true, readerAtNewest: true)
        await model.load()
        await model.awaitViewSettled()
        XCTAssertEqual(model.viewCallCount, 1)
        XCTAssertEqual(list.entry(id: channelID)?.showsUnreadEmphasis, false)

        // The server delivers a new post to the visible pane.
        service.viewResponse = MMChannelViewResponse(status: "OK", lastViewedAtTimes: [channelID: 9_000])
        let appended = model.handle(.posted(post("d", at: 9_000)))
        XCTAssertEqual(appended, .appended)
        await model.awaitViewSettled()

        XCTAssertEqual(model.viewCallCount, 2)
        XCTAssertEqual(service.viewedChannelIDs, [channelID, channelID])
        XCTAssertEqual(model.loadedPostIDs.first, "d")
        XCTAssertEqual(list.entry(id: channelID)?.showsUnreadEmphasis, false)
    }

    /// A post while the reader is scrolled up does not advance the cursor; scrolling back does.
    func testT5ANewPostWhileScrolledUpDoesNotPost() async {
        let service = FakeChannelService()
        service.page = [post("b", at: 2_000)]
        let model = model(service)
        model.setReadingState(paneVisible: true, sceneActive: true, readerAtNewest: false)
        await model.load()
        await model.awaitViewSettled()
        _ = model.handle(.posted(post("e", at: 9_000)))
        await model.awaitViewSettled()
        XCTAssertEqual(model.viewCallCount, 0)

        model.setReadingState(paneVisible: true, sceneActive: true, readerAtNewest: true)
        await model.awaitViewSettled()
        XCTAssertEqual(model.viewCallCount, 1)
        XCTAssertEqual(service.viewedChannelIDs, [channelID])
    }

    /// Coming back to the foreground re-posts even when the newest row did not change — upstream's
    /// `channel_post_list.tsx:102` behaviour.
    func testT5ForegroundingWhileVisibleRePosts() async {
        let service = FakeChannelService()
        service.page = [post("b", at: 2_000)]
        service.viewResponse = MMChannelViewResponse(status: "OK", lastViewedAtTimes: [channelID: 2_000])
        let model = model(service)
        model.setReadingState(paneVisible: true, sceneActive: true, readerAtNewest: true)
        await model.load()
        await model.awaitViewSettled()
        XCTAssertEqual(model.viewCallCount, 1)

        model.setReadingState(paneVisible: true, sceneActive: false, readerAtNewest: true)
        model.setReadingState(paneVisible: true, sceneActive: true, readerAtNewest: true)
        await model.awaitViewSettled()
        XCTAssertEqual(model.viewCallCount, 2)
    }

    // MARK: - T6: the mute rule survives the clear

    func testT6AMutedChannelStillFollowsTheBoldRuleAfterViewing() async {
        // A muted channel with ordinary unread messages: no bold, no dot (the whole point of muting),
        // and a read leaves it that way — it never had emphasis to lose.
        let (mutedList, _) = await loadedSidebar(sidebarData(c1Mentions: 0, c1Muted: true))
        XCTAssertEqual(mutedList.entry(id: channelID)?.showsUnreadEmphasis, false)
        XCTAssertEqual(mutedList.entry(id: channelID)?.badge, ChannelSidebarBadge.none)
        mutedList.applyRead(channelID: channelID, cursors: [channelID: 3_000])
        XCTAssertEqual(mutedList.entry(id: channelID)?.showsUnreadEmphasis, false)
        XCTAssertEqual(mutedList.entry(id: channelID)?.badge, ChannelSidebarBadge.none)
        XCTAssertEqual(mutedList.entry(id: channelID)?.isMuted, true)

        // A muted channel with an explicit mention is emphasised (`mark_unread == "mention"`), and a
        // read is what removes that mention — after which the mute rule applies again.
        let (mentionedList, _) = await loadedSidebar(sidebarData(c1Mentions: 1, c1Muted: true))
        XCTAssertEqual(mentionedList.entry(id: channelID)?.showsUnreadEmphasis, true)
        XCTAssertEqual(mentionedList.entry(id: channelID)?.badge, .mentions(1, urgent: false))
        mentionedList.applyRead(channelID: channelID, cursors: [channelID: 3_000])
        XCTAssertEqual(mentionedList.entry(id: channelID)?.showsUnreadEmphasis, false)
        XCTAssertEqual(mentionedList.entry(id: channelID)?.badge, ChannelSidebarBadge.none)
    }

    // MARK: - The write itself

    func testAFailedViewIsCountedAndLeavesTheStateAlone() async {
        let service = FakeChannelService()
        service.page = [post("a", at: 1_000)]
        service.viewError = MMError.notSignedIn
        let model = model(service)
        model.setReadingState(paneVisible: true, sceneActive: true, readerAtNewest: true)
        await model.load()
        await model.awaitViewSettled()
        XCTAssertEqual(model.viewCallCount, 1)
        XCTAssertNotNil(model.lastViewError)
        // A reading pane whose cursor did not land still reads: the failure is not drawn into the list.
        XCTAssertEqual(model.phase, .loaded)
    }

    /// A post that arrives while the view is in flight is not covered by the cursor the server stamps;
    /// the model sends one follow-up for the new newest row.
    func testAPostArrivingDuringTheViewTriggersOneFollowUp() async {
        let service = FakeChannelService()
        service.page = [post("b", at: 2_000)]
        service.viewResponse = MMChannelViewResponse(status: "OK", lastViewedAtTimes: [channelID: 2_000])
        service.viewDelay = .milliseconds(120)
        let model = model(service)
        model.onViewed = { [weak service] viewedChannelID, _ in
            // The socket frame lands while the REST answer is still on the wire.
            if let service, service.viewedChannelIDs.count == 1 {
                _ = model.handle(.posted(MMPost(id: "c", createAt: 3_000, userId: "u1",
                                                channelId: viewedChannelID, message: "late")))
            }
        }
        model.setReadingState(paneVisible: true, sceneActive: true, readerAtNewest: true)
        await model.load()
        await model.awaitViewSettled()
        // First call for "b"; the handler appended "c" while it was in flight, so one more for "c".
        XCTAssertEqual(service.viewedChannelIDs, [channelID, channelID])
        XCTAssertEqual(model.viewCallCount, 2)
    }
}
