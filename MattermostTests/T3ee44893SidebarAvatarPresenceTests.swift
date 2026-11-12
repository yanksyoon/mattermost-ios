// Card t_3ee44893 — the sidebar's DM rows draw the other person's face and their presence instead of
// a generic glyph.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (`channel_item` + `channel_icon` +
// `getStatusesByIds`), Apache-2.0 — see docs/THIRD_PARTY_NOTICES.md §3 and
// `Mattermost/UI/Native/Sidebar/SidebarPresence.swift`'s header.
//
// Every test here is one of the card's acceptance criteria, and each one is written so that the
// *reverted* implementation fails it (the adversarial half of the card):
//  * a static presence value fails `testAStatusChangeFrameMovesTheDotWithoutARequest`;
//  * dropping the freshness filter fails `testTwoHundredRowsCostTwoRequestsAndARedrawCostsNone`;
//  * drawing the picture without initials under it fails `testAFailedPictureFallsBackToTheInitials…`;
//  * ageing nothing fails `testAnUnconfirmedOnlineGoesQuietAfterTheHorizon`.

import XCTest
import SwiftUI
import UIKit
@testable import Mattermost

@MainActor
final class T3ee44893SidebarAvatarPresenceTests: XCTestCase {

    // MARK: - 1. A DM row's avatar is the other person

    func testADirectMessageRowCarriesTheOtherPersonsIdAsItsAvatar() {
        var data = ChannelSidebarData(channels: [dm("dm1", other: "uid-buddy")])
        data.directLabels = ["dm1": "Ada Lovelace"]
        data.directParticipants = ["dm1": [participant("uid-buddy", "Ada Lovelace")]]

        let entry = entries(data).first

        XCTAssertEqual(entry?.kind, .directMessage)
        XCTAssertEqual(entry?.directParticipants.map(\.userID), ["uid-buddy"],
                       "the avatar's cache key and the presence key are the other person's id")
        XCTAssertTrue(entry?.showsDirectAvatar == true, "the row draws a face, not the person glyph")
        XCTAssertEqual(entry?.displayName, "Ada Lovelace")
    }

    func testADirectMessageWithNoResolvablePersonKeepsItsGlyph() {
        // The profile batch failed: the row says "Direct message", and a face cannot be invented.
        var data = ChannelSidebarData(channels: [dm("dm1", other: "uid-buddy")])
        data.directLabels = [:]
        data.directParticipants = [:]

        let entry = entries(data).first

        XCTAssertFalse(entry?.showsDirectAvatar == true)
        XCTAssertEqual(entry?.iconSymbolName, SidebarChannelKind.directMessage.symbolName)
    }

    // MARK: - 2. A GM row carries a composite

    func testAGroupMessageRowCarriesACompositeOfItsParticipants() {
        let gm = MMChannel(id: "gm1", name: "opaque-hash", displayName: "", type: "G")
        var data = ChannelSidebarData(channels: [gm])
        data.directLabels = ["gm1": "Ada Lovelace, Grace Hopper, Katherine Johnson"]
        data.directParticipants = ["gm1": [participant("uid-ada", "Ada Lovelace"),
                                           participant("uid-grace", "Grace Hopper"),
                                           participant("uid-katherine", "Katherine Johnson")]]

        let entry = entries(data).first

        XCTAssertEqual(entry?.kind, .groupMessage)
        XCTAssertEqual(entry?.directParticipants.count, 3,
                       "the composite is drawn from all three people; two faces and a count chip")
        XCTAssertTrue(entry?.showsDirectAvatar == true)
        // A group has no single status, so the row must not claim one.
        XCTAssertEqual(entry?.presence, .unknown)
        XCTAssertEqual(entry?.accessibilityValue, "")
        XCTAssertFalse(entry?.accessibilityValue.contains("Online") == true)
    }

    // MARK: - 3. The four states, from the batched feed

    func testTheDotReflectsEachOfTheFourStatesFromABatchedFeed() async {
        let rows = [("dm-online", "u-online", "online"),
                    ("dm-away", "u-away", "away"),
                    ("dm-dnd", "u-dnd", "dnd"),
                    ("dm-offline", "u-offline", "offline")]
        var data = ChannelSidebarData(channels: rows.map { dm($0.0, other: $0.1) })
        for (channelID, userID, _) in rows {
            data.directLabels[channelID] = userID
            data.directParticipants[channelID] = [participant(userID, userID)]
        }
        let service = PresenceService(data: data)
        service.statusesByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.1, $0.2) })

        let model = ChannelListViewModel(server: server(), service: service)
        model.setSelection(teamID: "t1", channelID: nil, channelName: nil)
        await model.load()

        XCTAssertEqual(service.statusCalls, 1, "one batch for every person on the list")
        XCTAssertEqual(row(model, "dm-online")?.presence, .online)
        XCTAssertEqual(row(model, "dm-away")?.presence, .away)
        XCTAssertEqual(row(model, "dm-dnd")?.presence, .dnd)
        XCTAssertEqual(row(model, "dm-offline")?.presence, .offline)
        // The words VoiceOver gains, from the same four answers.
        XCTAssertEqual(row(model, "dm-online")?.accessibilityValue, "Online")
        XCTAssertEqual(row(model, "dm-away")?.accessibilityValue, "Away")
        XCTAssertEqual(row(model, "dm-dnd")?.accessibilityValue, "Do not disturb")
        XCTAssertEqual(row(model, "dm-offline")?.accessibilityValue, "Offline")
    }

    func testARowWhoseStatusHasNotBeenReadSaysNothingRatherThanOffline() {
        // No answer yet: the dot draws the quiet ring, but the value must not claim "Offline".
        var data = ChannelSidebarData(channels: [dm("dm1", other: "uid-buddy")])
        data.directLabels = ["dm1": "Ada Lovelace"]
        data.directParticipants = ["dm1": [participant("uid-buddy", "Ada Lovelace")]]

        let entry = entries(data).first

        XCTAssertEqual(entry?.presence, .unknown)
        XCTAssertEqual(entry?.accessibilityValue, "")
        XCTAssertTrue(SidebarPresencePalette.isHollow(.unknown), "quiet, not absent")
        XCTAssertTrue(SidebarPresencePalette.isHollow(.offline), "quiet, not absent")
        XCTAssertFalse(SidebarPresencePalette.isHollow(.online))
    }

    // MARK: - 4. A status_change frame moves the dot

    func testAStatusChangeFrameMovesTheDotWithoutARequest() async {
        var data = ChannelSidebarData(channels: [dm("dm1", other: "uid-buddy")])
        data.directLabels = ["dm1": "Ada Lovelace"]
        data.directParticipants = ["dm1": [participant("uid-buddy", "Ada Lovelace")]]
        let service = PresenceService(data: data)
        service.statusesByID = ["uid-buddy": "online"]

        let model = ChannelListViewModel(server: server(), service: service)
        model.setSelection(teamID: "t1", channelID: nil, channelName: nil)
        await model.load()
        XCTAssertEqual(row(model, "dm1")?.presence, .online)
        let requestsAfterLoad = service.statusCalls

        let outcome = model.handle(.statusChange(SocketStatusChange(userID: "uid-buddy",
                                                                    status: "offline")),
                                   myUserID: "me")

        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(row(model, "dm1")?.presence, .offline, "the dot moved on the frame alone")
        XCTAssertEqual(row(model, "dm1")?.accessibilityValue, "Offline")
        XCTAssertEqual(service.statusCalls, requestsAfterLoad,
                       "no request, let alone a reload: the payload carried the new value")
    }

    func testAStatusChangeAboutSomebodyWithNoRowHereIsIgnored() async {
        var data = ChannelSidebarData(channels: [dm("dm1", other: "uid-buddy")])
        data.directLabels = ["dm1": "Ada Lovelace"]
        data.directParticipants = ["dm1": [participant("uid-buddy", "Ada Lovelace")]]
        let service = PresenceService(data: data)
        service.statusesByID = ["uid-buddy": "online"]

        let model = ChannelListViewModel(server: server(), service: service)
        model.setSelection(teamID: "t1", channelID: nil, channelName: nil)
        await model.load()

        let outcome = model.handle(.statusChange(SocketStatusChange(userID: "uid-stranger",
                                                                    status: "offline")),
                                   myUserID: "me")

        XCTAssertEqual(outcome, .ignored)
        XCTAssertEqual(row(model, "dm1")?.presence, .online)
    }

    // MARK: - 4b. A green dot expires

    func testAnUnconfirmedOnlineGoesQuietAfterTheHorizon() async {
        let clock = Clock()
        var data = ChannelSidebarData(channels: [dm("dm1", other: "uid-buddy")])
        data.directLabels = ["dm1": "Ada Lovelace"]
        data.directParticipants = ["dm1": [participant("uid-buddy", "Ada Lovelace")]]
        let service = PresenceService(data: data)
        service.statusesByID = ["uid-buddy": "online"]

        let model = ChannelListViewModel(server: server(), service: service, now: { clock.now })
        model.setSelection(teamID: "t1", channelID: nil, channelName: nil)
        await model.load()
        XCTAssertEqual(row(model, "dm1")?.presence, .online)

        // The socket went quiet and the read cannot answer: nothing new is known about this person.
        service.statusError = MMError.offline
        clock.now = clock.now.addingTimeInterval(SidebarPresenceRules.staleAfter + 60)
        await model.refreshPresence()

        XCTAssertEqual(row(model, "dm1")?.presence, .offline,
                       "an unconfirmed online must not outlive the horizon")
        XCTAssertEqual(row(model, "dm1")?.accessibilityValue, "Offline")
    }

    // MARK: - 5. A failed picture degrades to initials

    func testAFailedPictureFallsBackToTheInitialsAndIsNotRequestedAgain() async {
        var loads = 0
        let store = AvatarImageStore(load: { _ in
            loads += 1
            throw MMError.notFound
        })

        let picture = await store.image(for: "uid-buddy")

        XCTAssertNil(picture, "the view draws its initials when the store has no picture")
        XCTAssertEqual(loads, 1)
        // A 404 is "this account has no picture", a fact for the session: a redraw must not re-ask.
        _ = await store.image(for: "uid-buddy")
        XCTAssertEqual(loads, 1, "a scroll tick must not become a request per row")
        XCTAssertEqual(store.missedCount, 1)

        let person = participant("uid-buddy", "Ada Lovelace")
        XCTAssertEqual(person.initials, "AL", "the fallback the row draws under the picture")
    }

    func testEachPersonCostsOnePictureRequestHoweverManyRowsAndRedraws() async {
        var requested: [String] = []
        let store = AvatarImageStore(load: { id in
            requested.append(id)
            throw MMError.notFound
        })

        // 200 rows, each drawn twice: the store's cache is per person, not per row.
        let ids = (0..<200).map { "u\($0)" }
        for _ in 0..<2 {
            for id in ids { _ = await store.image(for: id) }
        }

        XCTAssertEqual(requested.count, 200, "one request per distinct person, never per redraw")
        XCTAssertEqual(Set(requested).count, 200)
    }

    // MARK: - 6. The 200-row cost

    func testTwoHundredRowsCostTwoRequestsAndARedrawCostsNone() async {
        let channels = (0..<200).map { dm("dm\($0)", other: "u\($0)") }
        var data = ChannelSidebarData(channels: channels)
        for index in 0..<200 {
            data.directLabels["dm\(index)"] = "Person \(index)"
            data.directParticipants["dm\(index)"] = [participant("u\(index)", "Person \(index)")]
        }
        let service = PresenceService(data: data)
        service.statusesByID = Dictionary(uniqueKeysWithValues: (0..<200).map { ("u\($0)", "online") })

        let model = ChannelListViewModel(server: server(), service: service)
        model.setSelection(teamID: "t1", channelID: nil, channelName: nil)
        await model.load()

        XCTAssertEqual(allEntries(model).count, 200)
        XCTAssertEqual(service.statusCalls, 2,
                       "200 people, chunked at \(SidebarPresenceRules.statusBatchSize) per request")
        XCTAssertEqual(service.statusIDs.count, 200)

        // A redraw and a poll inside the freshness window are free: the cache answers.
        _ = model.groups.flatMap(\.entries)
        await model.refreshPresence()
        await model.refreshPresence()

        XCTAssertEqual(service.statusCalls, 2, "the freshness window is the cache; nothing re-asked")
        XCTAssertTrue(model.presenceDiagnostics.contains("requests=2"), model.presenceDiagnostics)
        XCTAssertEqual(row(model, "dm0")?.presence, .online)
    }

    func testAPollAfterTheWindowAsksAgainOnce() async {
        let clock = Clock()
        var data = ChannelSidebarData(channels: (0..<200).map { dm("dm\($0)", other: "u\($0)") })
        for index in 0..<200 {
            data.directLabels["dm\(index)"] = "Person \(index)"
            data.directParticipants["dm\(index)"] = [participant("u\(index)", "Person \(index)")]
        }
        let service = PresenceService(data: data)
        service.statusesByID = Dictionary(uniqueKeysWithValues: (0..<200).map { ("u\($0)", "online") })

        let model = ChannelListViewModel(server: server(), service: service, now: { clock.now })
        model.setSelection(teamID: "t1", channelID: nil, channelName: nil)
        await model.load()
        XCTAssertEqual(service.statusCalls, 2)

        clock.now = clock.now.addingTimeInterval(SidebarPresenceRules.refreshInterval + 1)
        await model.refreshPresence()

        XCTAssertEqual(service.statusCalls, 4, "one poll costs two requests for 200 rows — never 200")
    }

    // MARK: - 7. The existing row facts are untouched

    func testTheUnreadBoldAndMentionBadgeStillRuleTheRow() {
        var data = ChannelSidebarData(channels: [dm("dm1", other: "uid-buddy")])
        data.directLabels = ["dm1": "Ada Lovelace"]
        data.directParticipants = ["dm1": [participant("uid-buddy", "Ada Lovelace")]]
        data.members = [MMChannelMember(channelId: "dm1", userId: "me", mentionCount: 3)]
        data.presence = ["uid-buddy": SidebarPresenceSnapshot(userID: "uid-buddy",
                                                             presence: .online,
                                                             observedAt: Date())]

        let entry = entries(data).first

        XCTAssertTrue(entry?.showsUnreadEmphasis == true)
        XCTAssertEqual(entry?.badge, .mentions(3, urgent: false))
        XCTAssertEqual(entry?.accessibilityValue, "3 mentions, Online",
                       "the presence word joins the row's value; the label is still the name")
    }

    // MARK: - Evidence: the row as it is drawn

    /// Renders the real row view (not a mock) and writes a PNG, so the card's "screenshot of a DM row
    /// showing avatar + status" is the view code's own output. The five states are drawn in one
    /// column: online, away, dnd, offline, a GM composite, and an account with no picture (initials).
    ///
    /// It also prints the row's accessibility value for each state, which is what VoiceOver reads —
    /// the row is one element (T8e), so that value is the presence surface in the tree.
    func testTheRowRendersItsFaceAndPresenceForTheEvidenceScreenshot() async throws {
        let store = AvatarImageStore(load: { [weak self] id in
            // The last row is the "no picture" account: a 404 is the server's answer, and the row
            // must then draw its initials (the fallback the card asks to see).
            guard id != "u-nopicture" else { throw MMError.notFound }
            guard let self else { throw MMError.offline }
            return try self.facePNG(for: id)
        })
        let rows: [ChannelSidebarEntry] = [
            entry(id: "dm-online", presence: .online, people: [participant("u-online", "Ada Lovelace")]),
            entry(id: "dm-away", presence: .away, people: [participant("u-away", "Grace Hopper")]),
            entry(id: "dm-dnd", presence: .dnd, people: [participant("u-dnd", "Katherine Johnson")]),
            entry(id: "dm-offline", presence: .offline, people: [participant("u-offline", "Margaret Hamilton")]),
            entry(id: "gm-composite", kind: .groupMessage, presence: .unknown,
                  people: [participant("u-a", "Ada Lovelace"),
                           participant("u-b", "Grace Hopper"),
                           participant("u-c", "Katherine Johnson")]),
            entry(id: "dm-initials", presence: .online, people: [participant("u-nopicture", "Alan Turing")])
        ]

        let list = VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                ChannelSidebarRow(entry: row, canMove: false, action: {}, onMove: { _ in },
                                  onMute: {}, onFavorite: {})
                Divider()
            }
        }
        .frame(width: 240)
        .background(Color(.systemBackground))
        .environment(\.avatarImages, store)

        let controller = UIHostingController(rootView: list)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 240, height: 320))
        window.rootViewController = controller
        controller.view.frame = window.bounds
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        // Let `AvatarPicture.task` land: the pictures are fetched through the store above.
        try? await Task.sleep(nanoseconds: 600_000_000)
        controller.view.layoutIfNeeded()

        let renderer = UIGraphicsImageRenderer(bounds: controller.view.bounds)
        let image = renderer.image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("t_3ee44893", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = directory.appendingPathComponent("dm-rows.png")
        try image.pngData()?.write(to: png)
        print("EVIDENCE \(png.path) bytes=\(try Data(contentsOf: png).count)")
        print("EVIDENCE AX " + rows.map { "\($0.id)=\"\($0.accessibilityValue)\"" }.joined(separator: " | "))

        XCTAssertGreaterThan((try? Data(contentsOf: png).count) ?? 0, 2_000,
                            "the row really rendered: a blank 240x320 image compresses far smaller")
        XCTAssertEqual(rows[0].accessibilityValue, "Online")
        XCTAssertEqual(rows[3].accessibilityValue, "Offline")
    }

    /// A small PNG per account, so the picture (not just the initials) is what the screenshot shows.
    private func facePNG(for id: String) throws -> Data {
        let size = CGSize(width: 64, height: 64)
        let renderer = UIGraphicsImageRenderer(size: size)
        let hue: CGFloat = CGFloat(abs(id.hashValue % 360)) / 360
        let image = renderer.image { context in
            let colour = UIColor(hue: hue, saturation: 0.55, brightness: 0.8, alpha: 1)
            colour.setFill()
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }
        guard let data = image.pngData() else { throw MMError.offline }
        return data
    }

    private func entry(id: String,
                       kind: SidebarChannelKind = .directMessage,
                       presence: UserPresence,
                       people: [SidebarParticipant]) -> ChannelSidebarEntry {
        var entry = ChannelSidebarEntry(id: id,
                                        name: id,
                                        displayName: people.map(\.displayName).joined(separator: ", "),
                                        kind: kind,
                                        unreadCount: 0,
                                        mentionCount: 0,
                                        isMuted: false,
                                        manuallyUnread: false,
                                        isFavorite: false,
                                        isSelected: false,
                                        lastPostAt: 0,
                                        createdAt: 0,
                                        searchTerms: [])
        entry.directParticipants = people
        entry.presence = presence
        return entry
    }

    // MARK: - Harness

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
    }

    private func server() -> ServerConfig {
        ServerConfig(name: "perf", url: URL(string: "https://perf.example.com")!)
    }

    private func participant(_ id: String, _ name: String) -> SidebarParticipant {
        SidebarParticipant(userID: id,
                           displayName: name,
                           initials: ChannelMemberDerivation.initials(name))
    }

    private func dm(_ id: String, other: String) -> MMChannel {
        MMChannel(id: id, name: "me__\(other)", displayName: "", type: "D")
    }

    private func entries(_ data: ChannelSidebarData) -> [ChannelSidebarEntry] {
        ChannelSidebarDerivation.groups(from: data,
                                        selectedChannelID: nil,
                                        selectedChannelName: nil).flatMap(\.entries)
    }

    private func allEntries(_ model: ChannelListViewModel) -> [ChannelSidebarEntry] {
        model.groups.flatMap(\.entries)
    }

    private func row(_ model: ChannelListViewModel, _ id: String) -> ChannelSidebarEntry? {
        allEntries(model).first { $0.id == id }
    }
}

// MARK: - The service double

/// A sidebar service whose presence answers are scripted, and whose request count is the cost
/// measurement. Everything else is the honest minimum a list needs to load.
@MainActor
private final class PresenceService: ChannelSidebarServing {
    var data: ChannelSidebarData
    var statusesByID: [String: String] = [:]
    var statusError: Error?

    private(set) var statusCalls = 0
    private(set) var statusIDs: [String] = []

    init(data: ChannelSidebarData) {
        self.data = data
    }

    func load(teamID: String) async throws -> ChannelSidebarData { data }

    func refresh(teamID: String) async throws -> ChannelSidebarRefresh {
        ChannelSidebarRefresh(channels: data.channels, members: data.members)
    }

    func save(categories: [MMSidebarCategory], teamID: String) async throws -> [MMSidebarCategory] {
        categories
    }

    func setMuted(_ muted: Bool, channelID: String) async throws {}

    func statuses(ids: [String]) async throws -> [MMStatus] {
        statusCalls += 1
        statusIDs.append(contentsOf: ids)
        if let statusError { throw statusError }
        return ids.compactMap { id in
            statusesByID[id].map { MMStatus(userId: id, status: $0) }
        }
    }
}
