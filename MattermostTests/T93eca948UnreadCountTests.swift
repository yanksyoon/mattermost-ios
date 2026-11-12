import XCTest
import SwiftUI
import UIKit
@testable import Mattermost

/// t_93eca948 — an unread channel draws the **number of unread messages**, not a dot.
///
/// This is a deliberate divergence from upstream, and the file is written so that the divergence is
/// what is pinned, not merely tolerated:
///
/// * mobile (`app/components/channel_item/channel_item.tsx:210-218`, pin `162f2560`) renders a
///   `Badge` with `value={mentionsCount}`, i.e. mentions only, and carries unread-ness in the bold
///   label; the v12.0.1 webapp draws `ChannelMentionBadge` for mentions and a count-less dot for
///   `isUnread && unreadMentions === 0`;
/// * here, `unread = max(0, channel.total_msg_count − member.msg_count)` is drawn as a number.
///
/// The two adversarial cases the card names are **mutations that were run**, not prose: see
/// `docs/t_93eca948-build-note.md` §5 (`self.badge = mention-only` makes test 1 fail; unread counted
/// from a local counter makes the reopen/reload tests fail).
@MainActor
final class T93eca948UnreadCountTests: XCTestCase {

    // MARK: - Fixtures

    private let suiteSuffix = UUID().uuidString

    private func preferences() -> AppPreferences {
        let name = "T93eca948UnreadCountTests-\(suiteSuffix)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return AppPreferences(defaults: defaults)
    }

    private func server() -> ServerConfig {
        ServerConfig(name: "Example", url: URL(string: "https://mm.example")!)
    }

    private func channel(_ id: String,
                         totalMsgCount: Int64,
                         name: String? = nil) -> MMChannel {
        MMChannel(id: id,
                  name: name ?? id,
                  displayName: (name ?? id).capitalized,
                  type: "O",
                  teamId: "team1",
                  lastPostAt: 10,
                  totalMsgCount: totalMsgCount,
                  createAt: 1,
                  deleteAt: 0)
    }

    private func member(_ channelID: String,
                        msgCount: Int64,
                        mentions: Int64 = 0,
                        urgent: Int64 = 0,
                        muted: Bool = false) -> MMChannelMember {
        MMChannelMember(channelId: channelID,
                        userId: "me",
                        lastViewedAt: 0,
                        msgCount: msgCount,
                        mentionCount: mentions,
                        urgentMentionCount: urgent,
                        notifyProps: .object(["mark_unread": .string(muted ? "mention" : "all")]))
    }

    private func category(_ channelIDs: [String]) -> MMSidebarCategory {
        MMSidebarCategory(id: "chan", userId: "me", teamId: "team1", sortOrder: 10,
                          sorting: "manual", type: "channels", displayName: "Channels",
                          muted: false, collapsed: false, channelIds: channelIDs)
    }

    /// Two channels whose unread counts are deliberately far apart — the card's own example (40 vs 2).
    private func data(fortyUnread: Int64 = 45, fortySeen: Int64 = 5,
                      twoUnread: Int64 = 7, twoSeen: Int64 = 5) -> ChannelSidebarData {
        var data = ChannelSidebarData(
            channels: [channel("forty", totalMsgCount: fortyUnread, name: "forty"),
                       channel("two", totalMsgCount: twoUnread, name: "two")],
            members: [member("forty", msgCount: fortySeen),
                      member("two", msgCount: twoSeen)])
        data.categories = [category(["forty", "two"])]
        data.categoryOrder = ["chan"]
        return data
    }

    private func loadedModel(_ data: ChannelSidebarData) async -> (ChannelListViewModel, FakeChannelSidebarService) {
        let fake = FakeChannelSidebarService(data: data)
        let model = ChannelListViewModel(server: server(), service: fake)
        model.setSelection(teamID: "team1", channelID: nil, channelName: nil)
        await model.load()
        return (model, fake)
    }

    // MARK: - 1. Unread 40, mentions 0 → the badge says 40

    func testAnUnreadChannelWithFortyPostsDrawsTheNumberForty() async {
        let (model, _) = await loadedModel(data())
        let row = model.entry(id: "forty")
        // 45 total − 5 seen = 40, from the two fields the API ships (nothing counted locally).
        XCTAssertEqual(row?.unreadCount, 40)
        XCTAssertEqual(row?.badge, .unread(40))
        XCTAssertEqual(row?.badgeText, "40", "not a dot, and not the mention count (which is 0)")
        XCTAssertTrue(row?.showsUnreadEmphasis == true, "the bold label stays")
        XCTAssertEqual(row?.accessibilityValue, "Unread, 40 unread messages")
    }

    /// The number is a *difference of two server fields*, not a count of anything this client saw.
    func testTheNumberIsTheChannelsTotalMinusTheMembersCursor() {
        let chan = channel("c", totalMsgCount: 1_234)
        XCTAssertEqual(ChannelSidebarDerivation.unreadMessages(channel: chan,
                                                              member: member("c", msgCount: 1_194)), 40)
        // A cursor that is ahead of the channel (a view answered after a refresh) is not negative.
        XCTAssertEqual(ChannelSidebarDerivation.unreadMessages(channel: chan,
                                                              member: member("c", msgCount: 1_300)), 0)
        // No membership row = the count is unknown, which is drawn as nothing rather than 1234.
        XCTAssertEqual(ChannelSidebarDerivation.unreadMessages(channel: chan, member: nil), 0)
    }

    // MARK: - 2. Two unread channels show two different numbers

    func testTwoChannelsShowTheirOwnNumbersInOneList() async {
        let (model, _) = await loadedModel(data())
        XCTAssertEqual(model.entry(id: "forty")?.badgeText, "40")
        XCTAssertEqual(model.entry(id: "two")?.badgeText, "2")
        let group = model.groups.first { $0.id == "chan" }
        XCTAssertEqual(group?.headerBadge, .unread(42), "40 + 2: the section rolls the rows up")
        XCTAssertEqual(model.totals.messages, 42)
    }

    // MARK: - 3. Zero unread → nothing at all

    func testAChannelWithNothingUnreadDrawsNoBadgeAndNoZero() async {
        let (model, _) = await loadedModel(data(twoUnread: 5, twoSeen: 5))
        let row = model.entry(id: "two")
        XCTAssertEqual(row?.unreadCount, 0)
        XCTAssertEqual(row?.badge, ChannelSidebarBadge.none)
        XCTAssertNil(row?.badgeText, "no dot, no '0'")
        XCTAssertEqual(row?.accessibilityValue, "")
    }

    /// "Keep as unread" on a channel with nothing behind it stays **bold only**: there is no number to
    /// draw, and a pill reading 0 would be a claim the data does not support.
    func testKeepAsUnreadWithNothingUnreadStaysBoldOnly() {
        let entry = ChannelSidebarDerivation.entries(from: {
            var data = data(twoUnread: 5, twoSeen: 5)
            data.members[1].manuallyUnread = true
            return data
        }(), selectedChannelID: nil, selectedChannelName: nil).first { $0.id == "two" }
        XCTAssertEqual(entry?.showsUnreadEmphasis, true)
        XCTAssertEqual(entry?.badge, ChannelSidebarBadge.none)
        XCTAssertEqual(entry?.accessibilityValue, "Kept unread")
    }

    // MARK: - 4. Mentions keep their own badge (the choice this card made)

    func testAChannelWithMentionsDrawsTheMentionCountNotThePostCount() {
        // 40 unread posts *and* 3 mentions: one badge, and it is the mention.
        let badge = ChannelSidebarDerivation.badge(mentionCount: 3, urgentMentionCount: 0,
                                                   unreadCount: 40, isMuted: false,
                                                   manuallyUnread: false)
        XCTAssertEqual(badge, .mentions(3, urgent: false))
        XCTAssertEqual(badge.text, "3")
        XCTAssertTrue(badge.isMention, "the mention style (the louder pill) is preserved")
        XCTAssertFalse(badge == .unread(40), "never two badges, never the post count once mentioned")
    }

    func testAnUrgentMentionIsTheMentionCountWithTheLouderStyle() {
        let badge = ChannelSidebarDerivation.badge(mentionCount: 2, urgentMentionCount: 2,
                                                   unreadCount: 9, isMuted: false,
                                                   manuallyUnread: false)
        XCTAssertEqual(badge, .mentions(2, urgent: true))
        XCTAssertEqual(badge.text, "2")
    }

    // MARK: - 5. Muted channels draw nothing (the decision this card kept)

    func testAMutedChannelDrawsNoCountEvenWithFortyUnread() async {
        var withMuted = data()
        withMuted.members[0].notifyProps = .object(["mark_unread": .string("mention")])
        let (model, _) = await loadedModel(withMuted)
        let row = model.entry(id: "forty")
        XCTAssertEqual(row?.isMuted, true)
        XCTAssertEqual(row?.unreadCount, 40, "the number is still known — it is the *drawing* that is silent")
        XCTAssertFalse(row?.showsUnreadEmphasis == true, "no bold for ordinary traffic")
        XCTAssertEqual(row?.badge, ChannelSidebarBadge.none)
        XCTAssertEqual(row?.accessibilityValue, "Muted")
        let group = model.groups.first { $0.id == "chan" }
        XCTAssertEqual(group?.headerBadge, .unread(2), "only the unmuted row's 2 reaches the roll-up")
    }

    // MARK: - 6. Opening the channel clears the number in the same tick

    func testReadingTheChannelClearsItsNumberAndTheGroupsRollUpImmediately() async {
        let (model, _) = await loadedModel(data())
        XCTAssertEqual(model.entry(id: "forty")?.badgeText, "40")
        XCTAssertEqual(model.groups.first { $0.id == "chan" }?.headerBadge, .unread(42))

        // The pane's `POST /channels/members/me/view` landed (t_e9550303's path): the cursor moves to
        // the channel's own total and the row is re-derived in this update — no reload, no request.
        let outcome = model.applyRead(channelID: "forty", cursors: ["forty": 1_700_000_000_000])
        XCTAssertEqual(outcome.applied, true)
        XCTAssertEqual(outcome.clearedUnreadMessages, 40, "the number that was on the row")

        XCTAssertEqual(model.entry(id: "forty")?.badge, ChannelSidebarBadge.none)
        XCTAssertNil(model.entry(id: "forty")?.badgeText, "no badge, no stale 40")
        XCTAssertEqual(model.groups.first { $0.id == "chan" }?.headerBadge, .unread(2),
                       "the roll-up drops in the same tick")
        XCTAssertEqual(model.totals.messages, 2)
    }

    // MARK: - 7. A read from anywhere else clears it too (the socket frame)

    func testARemoteChannelViewedClearsTheNumberWithoutAReload() async {
        let (model, fake) = await loadedModel(data())
        let refreshBefore = fake.refreshCount

        // `channel_viewed` addressed to this user — the same frame a view on another device produces.
        let outcome = model.handle(.channelViewed(SocketChannelViewed(channelID: "forty", userID: "me")),
                                   myUserID: "me")
        XCTAssertEqual(outcome, .counters)
        XCTAssertEqual(model.entry(id: "forty")?.badge, ChannelSidebarBadge.none)
        XCTAssertEqual(model.groups.first { $0.id == "chan" }?.headerBadge, .unread(2))
        XCTAssertEqual(fake.refreshCount, refreshBefore, "the frame *is* the new state: no request")
    }

    /// The view call's own event (`multiple_channels_viewed`), which names every channel whose cursor
    /// moved. Both channels read → the numbers go and the section's count goes with them.
    func testAMultiChannelViewClearsEveryNumberItNames() async {
        let (model, fake) = await loadedModel(data())
        XCTAssertEqual(model.totals.messages, 42)
        let refreshBefore = fake.refreshCount

        let outcome = model.handle(.multipleChannelsViewed(SocketMultipleChannelsViewed(
            userID: "me",
            channelTimes: ["forty": 1, "two": 2])), myUserID: "me")

        XCTAssertEqual(outcome, .counters)
        XCTAssertEqual(model.entry(id: "forty")?.badge, ChannelSidebarBadge.none)
        XCTAssertEqual(model.entry(id: "two")?.badge, ChannelSidebarBadge.none)
        XCTAssertEqual(model.groups.first { $0.id == "chan" }?.headerBadge, ChannelSidebarBadge.none)
        XCTAssertEqual(fake.refreshCount, refreshBefore)
    }

    /// The reconnect half of the card's adversarial case: the number is re-derived from the server's
    /// two fields on the next counter read, so a socket that dropped and came back cannot leave a
    /// locally-incremented total behind. (This is why nothing counts websocket posts.)
    func testAFullReloadReDerivesTheNumberFromTheServerFields() async {
        let (model, fake) = await loadedModel(data())
        XCTAssertEqual(model.entry(id: "forty")?.badgeText, "40")

        // The server moved on while the socket was down: 10 more posts, and the reader is still at 5.
        fake.data.channels[0] = channel("forty", totalMsgCount: 55, name: "forty")
        await model.refreshCounters()

        XCTAssertEqual(model.entry(id: "forty")?.unreadCount, 50)
        XCTAssertEqual(model.entry(id: "forty")?.badgeText, "50")
        XCTAssertEqual(model.entry(id: "forty")?.badge, .unread(50))
    }

    // MARK: - 8. Large counts

    /// The ceiling this card chose: exact up to 999, `999+` from 1000 on.
    func testAThousandUnreadRendersAsNineNineNinePlus() async {
        let (model, _) = await loadedModel(data(fortyUnread: 1_005, fortySeen: 5))
        XCTAssertEqual(model.entry(id: "forty")?.unreadCount, 1_000)
        XCTAssertEqual(model.entry(id: "forty")?.badge, .unread(1_000))
        XCTAssertEqual(model.entry(id: "forty")?.badgeText, "999+", "the pill caps, the number is kept")
        XCTAssertTrue(model.entry(id: "forty")?.accessibilityValue.contains("1000 unread messages") == true,
                      "VoiceOver still hears the real number")

        let justUnder = ChannelSidebarBadge.unread(999)
        XCTAssertEqual(justUnder.text, "999", "999 is drawn exactly; the cap starts at 1000")
    }

    /// Two ceilings, deliberately: a mention badge caps at `99+` (upstream's formatting, unchanged),
    /// an unread badge at `999+`.
    func testTheTwoCountsKeepTheirOwnCeilings() {
        XCTAssertEqual(ChannelSidebarBadge.mentions(120, urgent: false).text, "99+")
        XCTAssertEqual(ChannelSidebarBadge.unread(120).text, "120")
        XCTAssertEqual(ChannelSidebarBadge.unread(1_200).text, "999+")
        XCTAssertEqual(ChannelSidebarBadge.mentions(120, urgent: false).count, 120, "the real number is kept")
        XCTAssertEqual(ChannelSidebarBadge.unread(1_200).count, 1_200)
    }

    // MARK: - 9b. The membership read must not stop at page one

    /// The live run found this the hard way: `GET /users/me/channel_members` paginates, and with no
    /// `page`/`per_page` the 9.11.19 fixture answered **60 rows for 429 memberships** — `off-topic`
    /// and `perf-feed` were not among them, so the app drew no count while the server said 40 and 2.
    /// The counters live on those rows, so the read walks every page.
    func testTheMembershipReadWalksEveryPageBecauseTheCountsLiveThere() async throws {
        func members(_ count: Int, startingAt offset: Int) -> [[String: Any]] {
            (0..<count).map { index in
                ["channel_id": "c\(offset + index)", "user_id": "u1",
                 "msg_count": 3, "mention_count": 0]
            }
        }
        let transport = FakeAPITransport(stubs: [
            .ok(.json(members(200, startingAt: 0))),
            .ok(.json(members(200, startingAt: 200))),
            .ok(.json(members(10, startingAt: 400)))
        ])
        let client = try APIClient(serverURL: URL(string: "https://mm.example.com")!,
                                   transport: transport,
                                   tokenProvider: { "test-token" })
        let rows = try await client.myChannelMembers(pageSize: 200)
        XCTAssertEqual(rows.count, 410, "three pages, merged — not the first 200")
        XCTAssertEqual(transport.requestCount, 3)
        let pages = transport.requests.compactMap { request -> String? in
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "page" }?.value
        }
        XCTAssertEqual(pages, ["0", "1", "2"], "each page is asked for by number")
    }

    // MARK: - 9. Cost: the sidebar does not ask the server per channel

    /// Requirement 6, measured: drawing the numbers costs **no request**. The numbers arrive in the
    /// two payloads the sidebar already reads (`/users/me/teams/{t}/channels`' `total_msg_count` and
    /// `/users/me/channel_members`' `msg_count`), and a redraw is a pure re-derivation.
    ///
    /// The seam is the whole proof: `ChannelSidebarServing` has no per-channel read at all, so a row
    /// *cannot* ask the server for its own count. The counts below are the fake's own call log.
    func testFiftyRedrawsCostZeroRequests() async {
        let (model, fake) = await loadedModel(data())
        XCTAssertEqual(fake.loadTeamIDs, ["team1"], "one load for the whole list")
        XCTAssertEqual(fake.refreshCount, 0)

        for _ in 0..<50 {
            // What SwiftUI does on every body pass: re-derive the rows from the loaded data.
            _ = model.groups.map { $0.entries.map(\.badgeText) }
        }

        XCTAssertEqual(fake.loadTeamIDs, ["team1"], "a redraw never re-loads")
        XCTAssertEqual(fake.refreshCount, 0, "and never re-reads counters")
        XCTAssertEqual(model.entry(id: "forty")?.badgeText, "40", "the last redraw still has the number")
    }

    // MARK: - 10. The evidence render

    /// The row as drawn (`docs/t_93eca948-shots/unread-counts.png`): 40, 2, 1000 (`999+`), a mention,
    /// an urgent mention and a read row, plus the two section headers' roll-ups.
    func testTheRowsRenderTheirCountsForTheEvidenceScreenshot() async throws {
        func row(_ id: String, _ name: String, unread: Int, mentions: Int = 0, urgent: Int = 0,
                 muted: Bool = false) -> ChannelSidebarEntry {
            ChannelSidebarEntry(id: id, name: name, displayName: name, kind: .publicChannel,
                                unreadCount: unread, mentionCount: mentions,
                                urgentMentionCount: urgent, isMuted: muted,
                                manuallyUnread: false, isFavorite: false, isSelected: false,
                                lastPostAt: 0, createdAt: 0, searchTerms: [])
        }
        let rows = [row("forty", "# ops-standup", unread: 40),
                    row("two", "# release-notes", unread: 2),
                    row("thousand", "# all-hands", unread: 1_000),
                    row("mention", "# town-square", unread: 12, mentions: 3),
                    row("urgent", "# incidents", unread: 4, mentions: 1, urgent: 1),
                    row("muted", "# noise", unread: 40, muted: true),
                    row("read", "# general", unread: 0)]
        let categories = MMSidebarCategory(id: "channels", userId: "me", teamId: "team",
                                          sortOrder: 0, sorting: "manual", type: "channels",
                                          displayName: "", muted: false, collapsed: false,
                                          channelIds: rows.map(\.id))
        let group = ChannelSidebarGroup(category: categories, entries: rows)
        // A second group that is **collapsed**: its header still carries the roll-up, and its rows are
        // not on screen at all — the case the card calls out.
        let hidden = [row("hidden-a", "# design", unread: 7), row("hidden-b", "# ops", unread: 5)]
        let collapsedCategory = MMSidebarCategory(id: "custom-1", userId: "me", teamId: "team",
                                                 sortOrder: 1, sorting: "manual", type: "custom",
                                                 displayName: "Design", muted: false, collapsed: true,
                                                 channelIds: hidden.map(\.id))
        let collapsed = ChannelSidebarGroup(category: collapsedCategory, entries: hidden)
        let list = VStack(alignment: .leading, spacing: 0) {
            CategoryHeader(group: group, isCollapsed: false, canEdit: false,
                           canMoveUp: false, canMoveDown: false, onToggle: {}, onActions: {})
                .padding(.horizontal, 6).padding(.vertical, 6)
            ForEach(rows) { row in
                ChannelSidebarRow(entry: row, canMove: false, action: {}, onMove: { _ in },
                                  onMute: {}, onFavorite: {})
                Divider()
            }
            CategoryHeader(group: collapsed, isCollapsed: true, canEdit: false,
                           canMoveUp: false, canMoveDown: false, onToggle: {}, onActions: {})
                .padding(.horizontal, 6).padding(.vertical, 6)
        }
        .frame(width: 260)
        .background(Color(.systemBackground))

        let controller = UIHostingController(rootView: list)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 260, height: 430))
        window.rootViewController = controller
        controller.view.frame = window.bounds
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        try? await Task.sleep(nanoseconds: 300_000_000)
        controller.view.layoutIfNeeded()

        let renderer = UIGraphicsImageRenderer(bounds: controller.view.bounds)
        let image = renderer.image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("t_93eca948", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = directory.appendingPathComponent("unread-counts.png")
        try image.pngData()?.write(to: png)
        print("EVIDENCE \(png.path) bytes=\(try Data(contentsOf: png).count)")
        print("EVIDENCE AX " + rows.map { "\($0.id)=\"\($0.badge.text ?? "-")\" / \"\($0.accessibilityValue)\"" }
            .joined(separator: " | "))

        XCTAssertGreaterThan((try? Data(contentsOf: png).count) ?? 0, 3_000,
                             "the rows really rendered: a blank canvas of this size compresses far smaller")
        XCTAssertEqual(rows.map(\.badgeText), ["40", "2", "999+", "3", "1", nil, nil])
        // The two headers: the open one rolls the whole group up (1046 → `999+`), the collapsed one
        // still counts its two hidden rows (7 + 5).
        XCTAssertEqual(group.headerBadge.text, "999+")
        XCTAssertEqual(collapsed.headerBadge.text, "12")
    }
}
