// t_0f8e0eb2 — the channel header's subtitle: "{n} members", and `View info` only when unknown.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb),
// app/screens/channel/header/header.tsx:255 (`if (memberCount) { "{count, plural, one {# member}
// other {# members}}" } else { "View info" }`) and app/screens/channel/header/index.ts (the count is
// `undefined` for a direct message: `dm ? undefined : ci?.memberCount`).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md; no upstream
// source copied.
//
// Why a unit case is the right home for the rule: the defect this card closes was that the subtitle was
// a constant. Nothing could say "a channel with 40 members looks identical to a DM" in a test, because
// there was no expression to assert on. `ChannelViewModel.headerSubtitle(memberCount:)` is that
// expression, and the live half (`T05ChannelHeaderUITests.testF…`) proves the number reaches the screen
// from a real 9.11.19 server.
//
// What these cases pin:
//   * the plural half ("1 member" / "2 members" / "40 members");
//   * the fallback half — `nil` **and zero** (upstream tests truthiness, so `0` is the fallback, not
//     "0 members");
//   * where the number comes from: the stats call, once per load, never for a DM;
//   * that a failure is *unknown* rather than zero;
//   * that a join/leave frame moves a **known** count only, for this channel only, and never below zero;
//   * that the header and the channel-info sheet cannot disagree about the same count.

import XCTest
@testable import Mattermost

@MainActor
final class T0fChannelHeaderSubtitleTests: XCTestCase {

    // MARK: - Fake

    /// The `ChannelServing` seam with the one call this card added, plus the minimum a load needs.
    @MainActor
    final class FakeService: ChannelServing {
        var channel: MMChannel?
        /// Every `memberCount` request the model made, in order — "a DM asks nobody" is asserted on this.
        private(set) var countRequests: [String] = []
        /// `nil` = the server answered nothing useful; `failure` = the request was refused.
        var count: Int64?
        var countFailure: Error?

        init(channel: MMChannel? = nil, count: Int64? = nil) {
            self.channel = channel
            self.count = count
        }

        func channel(id: String) async throws -> MMChannel {
            guard let channel else { throw MMError.notFound }
            return channel
        }

        func posts(channelID: String, before: String?, perPage: Int) async throws -> MMPostList {
            MMPostList(order: [], posts: [:])
        }

        func users(ids: [String]) async throws -> [MMUser] { [] }

        func fileData(fileID: String, preferThumbnail: Bool) async throws -> Data {
            throw MMError.notFound
        }

        func memberCount(channelID: String) async throws -> Int64? {
            countRequests.append(channelID)
            if let countFailure { throw countFailure }
            return count
        }
    }

    private func model(_ service: FakeService, channelID: String = "channel-1") -> ChannelViewModel {
        ChannelViewModel(channelID: channelID, service: service)
    }

    // MARK: - The rule itself

    func testAKnownCountIsTheServersNumberWithTheServerPlural() {
        XCTAssertEqual(ChannelViewModel.headerSubtitle(memberCount: 1), "1 member")
        XCTAssertEqual(ChannelViewModel.headerSubtitle(memberCount: 2), "2 members")
        XCTAssertEqual(ChannelViewModel.headerSubtitle(memberCount: 40), "40 members")
        XCTAssertEqual(ChannelViewModel.headerSubtitle(memberCount: 1_234), "1234 members")
    }

    func testNoCountAndAZeroCountBothFallBackToViewInfo() {
        // `nil` is "nobody has read it yet"; `0` is upstream's truthiness test (`if (memberCount)`),
        // which is a fallback too and not "0 members".
        XCTAssertEqual(ChannelViewModel.headerSubtitle(memberCount: nil), "View info")
        XCTAssertEqual(ChannelViewModel.headerSubtitle(memberCount: 0), "View info")
        // A negative count is not a number the server can mean; it must not render as "-1 members".
        XCTAssertEqual(ChannelViewModel.headerSubtitle(memberCount: -1), "View info")
    }

    func testTheHeaderAndTheChannelInfoSheetAgreeAboutTheSameCount() {
        for count in [1, 2, 6, 40] as [Int64] {
            XCTAssertEqual(ChannelViewModel.headerSubtitle(memberCount: count),
                           ChannelInfoHeader.membersText(count: count),
                           "two surfaces of one channel must pluralise \(count) the same way")
        }
    }

    // MARK: - Where the number comes from

    func testAChannelLoadsItsCountIntoTheHeader() async {
        let service = FakeService(channel: MMChannel(id: "channel-1", name: "town-square",
                                                     displayName: "Town Square", type: "O"),
                                  count: 40)
        let model = model(service)
        await model.load()

        XCTAssertEqual(service.countRequests, ["channel-1"], "one stats call per load")
        XCTAssertEqual(model.memberCount, 40)
        XCTAssertEqual(ChannelViewModel.headerSubtitle(memberCount: model.memberCount), "40 members")
    }

    func testAGroupMessageAlsoShowsItsCount() async {
        // Upstream drops the count only when the conversation has a **DM** user (`dmUser` is defined
        // for `General.DM_CHANNEL` alone), so a group message keeps its number.
        let service = FakeService(channel: MMChannel(id: "channel-1", name: "a1b2c3d4e5f6",
                                                     displayName: "Group message", type: "G"),
                                  count: 3)
        let model = model(service)
        await model.load()

        XCTAssertEqual(model.memberCount, 3)
        XCTAssertEqual(ChannelViewModel.headerSubtitle(memberCount: model.memberCount), "3 members")
    }

    func testADirectMessageKeepsTheFallbackAndAsksNobody() async {
        // `GET /channels/{id}/stats` would answer `member_count: 2` for a DM; upstream never reads it,
        // because a DM's subtitle is the fallback (its second line belongs to the custom status).
        let service = FakeService(channel: MMChannel(id: "channel-1", name: "aaaaaaaa__bbbbbbbb",
                                                     displayName: "", type: "D"),
                                  count: 2)
        let model = model(service)
        await model.load()

        XCTAssertEqual(service.countRequests, [], "a direct message must not ask for a count")
        XCTAssertNil(model.memberCount)
        XCTAssertEqual(ChannelViewModel.headerSubtitle(memberCount: model.memberCount), "View info")
    }

    func testAFailedStatsCallLeavesTheFallbackRatherThanZero() async {
        let service = FakeService(channel: MMChannel(id: "channel-1", name: "town-square",
                                                     displayName: "Town Square", type: "O"),
                                  count: 40)
        service.countFailure = MMError.timeout
        let model = model(service)
        await model.load()

        XCTAssertNil(model.memberCount, "a refused request is unknown, not a channel with no members")
        XCTAssertEqual(ChannelViewModel.headerSubtitle(memberCount: model.memberCount), "View info")
    }

    // MARK: - A count that moves while the pane is open

    func testJoinAndLeaveFramesMoveTheCountForThisChannelOnly() async {
        let service = FakeService(channel: MMChannel(id: "channel-1", name: "town-square",
                                                     displayName: "Town Square", type: "O"),
                                  count: 3)
        let model = model(service)
        await model.load()
        XCTAssertEqual(model.memberCount, 3)

        // Somebody joins another channel: this header says nothing about it.
        model.handle(.userAdded(SocketMembershipChange(channelID: "channel-2", userID: "u9")))
        XCTAssertEqual(model.memberCount, 3, "another channel's join must not move this count")

        model.handle(.userAdded(SocketMembershipChange(channelID: "channel-1", userID: "u9")))
        XCTAssertEqual(model.memberCount, 4)
        XCTAssertEqual(ChannelViewModel.headerSubtitle(memberCount: model.memberCount), "4 members")

        model.handle(.userRemoved(SocketMembershipChange(channelID: "channel-1", userID: "u9")))
        XCTAssertEqual(model.memberCount, 3)

        // Down to the floor, never below it.
        for _ in 0..<5 {
            model.handle(.userRemoved(SocketMembershipChange(channelID: "channel-1", userID: "u9")))
        }
        XCTAssertEqual(model.memberCount, 0)
        // And upstream's truthiness rule takes it from there: a zero count is the fallback.
        XCTAssertEqual(ChannelViewModel.headerSubtitle(memberCount: model.memberCount), "View info")
    }

    func testAnUnknownCountIsNotInventedByAJoinFrame() async {
        // The stats call never answered, so a "+1" has nothing to add to. A header that invented a
        // total would be worse than one that says "View info".
        let service = FakeService(channel: MMChannel(id: "channel-1", name: "town-square",
                                                     displayName: "Town Square", type: "O"),
                                  count: nil)
        let model = model(service)
        await model.load()
        XCTAssertNil(model.memberCount)

        model.handle(.userAdded(SocketMembershipChange(channelID: "channel-1", userID: "u9")))
        XCTAssertNil(model.memberCount)
        XCTAssertEqual(ChannelViewModel.headerSubtitle(memberCount: model.memberCount), "View info")
    }
}
