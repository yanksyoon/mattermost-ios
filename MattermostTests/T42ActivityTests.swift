// T42 — the rules behind the mentions feed, with no network and no clock.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0
// (`app/screens/home/recent_mentions/recent_mentions.tsx`, `app/actions/remote/search.ts`
// `#fetchRecentMentions`, `app/database/models/server/user.ts` `mentionKeys`,
// `app/utils/post/index.ts` mention matching).
// Licence: Apache-2.0 — behaviour reimplemented; attribution in docs/THIRD_PARTY_NOTICES.md §19.
//
// Asserted through the seams the screen actually uses:
//   * `MentionKeys` for what a mention key is and how a message is matched against it;
//   * `ActivityDerivation` for rows, order, read state, the filter, the live-mention predicate;
//   * `MentionsViewModel` against a fake `ActivityServing` for load / mark-read / socket handling;
//   * `SessionStore.serverBadgeInput` + `applyServerCounters` for the one place counters become a badge.
//
// The measured server facts these build on are in `ActivityModels.swift`'s header and are re-measurable
// with `scripts/t42_activity_probe.py` against the pinned 9.11.19 server.

import XCTest
@testable import Mattermost

@MainActor
final class T42ActivityTests: XCTestCase {

    private let myID = "user0000000000000000000001"
    private let otherID = "user0000000000000000000002"
    private let teamID = "team0000000000000000000001"
    private let channelID = "chan0000000000000000000001"
    private let dmID = "dm00000000000000000000001"

    // MARK: - Fixtures

    private func post(_ id: String,
                      at createAt: Int64,
                      message: String = "hi",
                      channel: String? = nil,
                      author: String? = nil,
                      rootID: String = "",
                      props: JSONValue? = nil,
                      deleteAt: Int64 = 0) -> MMPost {
        MMPost(id: id, createAt: createAt, deleteAt: deleteAt,
               userId: author ?? otherID, channelId: channel ?? channelID,
               rootId: rootID, message: message, props: props)
    }

    private func channel(_ id: String? = nil, team: String? = nil,
                         name: String = "town-square", type: String = "O") -> MMChannel {
        MMChannel(id: id ?? channelID, name: name, displayName: "",
                  type: type, teamId: team ?? teamID)
    }

    private func member(_ channelID: String, viewedAt: Int64, mentions: Int64 = 0) -> MMChannelMember {
        MMChannelMember(channelId: channelID, userId: myID, lastViewedAt: viewedAt,
                        msgCount: 0, mentionCount: mentions)
    }

    private func props(_ pairs: [String: JSONValue]) -> JSONValue { .object(pairs) }

    private func notifyProps(keys: String = "", firstName: String = "false",
                             channel: String = "false") -> JSONValue {
        props(["mention_keys": .string(keys), "first_name": .string(firstName),
               "channel": .string(channel)])
    }

    private var profile: ActivityProfile {
        ActivityProfile(id: myID, username: "perfprobe", firstName: "Perf",
                        lastName: "Probe",
                        notifyProps: notifyProps(keys: "deploybot, "))
    }

    // MARK: - Mention keys: what notifies this reader

    func testKeysAreUpstreamsOrderAndShape() {
        let keys = MentionKeys.derive(profile)
        // 1. the account's own keys (the trailing comma is not a key), 2. first name (flag off),
        // 3. broadcasts (flag off), 4. @username last.
        XCTAssertEqual(keys.keys.map(\.key), ["deploybot", "@perfprobe"])
        XCTAssertEqual(keys.personalKeys.count, 2)
    }

    func testFirstNameAndBroadcastKeysAppearOnlyWhenTheAccountAskedForThem() {
        let props = notifyProps(keys: "", firstName: "true", channel: "true")
        let keys = MentionKeys.derive(username: "perfprobe", firstName: "Perf", notifyProps: props)

        XCTAssertEqual(keys.keys.map(\.key), ["Perf", "@channel", "@all", "@here", "@perfprobe"])
        // The first name is matched case-sensitively (upstream's `mentionKeys`), and it *is* a personal
        // key — a post that says "Perf" notifies this reader as much as "@perfprobe" does.
        XCTAssertEqual(keys.keys.first?.caseSensitive, true)
        XCTAssertEqual(keys.personalKeys.map(\.key), ["Perf", "@perfprobe"])
    }

    func testSearchTermsLeaveOutTheBroadcastKeysAndKeepTheTrailingSpace() {
        let props = notifyProps(keys: "deploybot", firstName: "true", channel: "true")
        let keys = MentionKeys.derive(username: "perfprobe", firstName: "Perf", notifyProps: props)

        // Asking the server for "@channel" would return every broadcast in the workspace, which is not a
        // mention of this reader — upstream's `userMentionKeys` drops the three for the same reason.
        XCTAssertEqual(keys.searchTerms, "deploybot Perf @perfprobe ")
        XCTAssertFalse(keys.searchTerms.contains("@channel"))
        XCTAssertFalse(keys.searchTerms.contains("@all"))
        XCTAssertFalse(keys.searchTerms.contains("@here"))
    }

    func testUsernameIsNotDuplicatedWhenItIsAlsoAnExtraKey() {
        let notify = props(["mention_keys": .string("@perfprobe,deploybot")])
        let keys = MentionKeys.derive(username: "perfprobe", firstName: "", notifyProps: notify)
        XCTAssertEqual(keys.keys.map(\.key), ["@perfprobe", "deploybot"])
    }

    func testAnEmptyAccountHasNoPersonalKeysAndNoTerms() {
        let keys = MentionKeys.derive(username: "", firstName: "", notifyProps: nil)
        XCTAssertTrue(keys.isEmpty)
        XCTAssertEqual(keys.searchTerms, "")
        XCTAssertFalse(keys.matches("hello @someone"))
    }

    // MARK: - Mention matching: the whole-token rule

    func testAKeyMustNotBeGluedToAWordCharacter() {
        let keys = MentionKeys(keys: [MentionKey("@perfprobe")])

        XCTAssertTrue(keys.matches("hello @perfprobe"))
        XCTAssertTrue(keys.matches("@perfprobe, can you look?"))
        XCTAssertTrue(keys.matches("ping @perfprobe."))
        // The two ways a substring match goes wrong: a longer handle that starts with ours, and an
        // email-like glue on the left.
        XCTAssertFalse(keys.matches("hello @perfprobex"))
        XCTAssertFalse(keys.matches("mail foo@perfprobe now"))
        XCTAssertFalse(keys.matches("perfprobe"))
    }

    func testMatchingIgnoresCaseForHandlesButNotForFirstNameKeys() {
        let keys = MentionKeys(keys: [MentionKey("@perfprobe"), MentionKey("Perf", caseSensitive: true)])

        XCTAssertTrue(keys.matches("@PerfProbe are you there?"))
        XCTAssertEqual(keys.matchedKey(in: "@PerfProbe are you there?"), "@perfprobe")

        XCTAssertTrue(keys.matches("Perf is here"))
        // A name is a name: "perf" in ordinary prose is not the reader.
        XCTAssertFalse(keys.matches("the perf run was slow"))
        XCTAssertFalse(keys.matches("Perfs are here"))
    }

    func testBroadcastKeysNeverMatchAMessage() {
        // A post that says "@channel" mentions everybody, so it is not *this* reader's mention: the
        // personal keys decide, and the broadcast keys are not among them.
        let keys = MentionKeys(keys: [MentionKey("@channel"), MentionKey("@perfprobe")])
        XCTAssertFalse(MentionKeys(keys: [MentionKey("@channel")]).matches("@channel heads up"))
        XCTAssertTrue(keys.matches("@channel @perfprobe heads up"))
    }

    // MARK: - The live-mention predicate

    func testYourOwnPostIsNeverYourMention() {
        let keys = MentionKeys(keys: [MentionKey("@perfprobe")])
        let mine = post("p1", at: 1_000, message: "@perfprobe note to self", author: myID)
        XCTAssertFalse(ActivityDerivation.isLiveMention(mine, myUserID: myID, keys: keys))
    }

    func testDeletedPostsAreNotMentions() {
        let keys = MentionKeys(keys: [MentionKey("@perfprobe")])
        let gone = post("p1", at: 1_000, message: "@perfprobe", deleteAt: 2_000)
        XCTAssertFalse(ActivityDerivation.isLiveMention(gone, myUserID: myID, keys: keys))
    }

    func testTheServersOwnMentionsPropWinsWhenItIsPresent() {
        let keys = MentionKeys(keys: [MentionKey("@perfprobe")])
        // The server answered "this post mentions *that* user", not me — even though my key is in the text
        // the server's answer is the notification-accurate one, so the feed follows it.
        let notMine = post("p1", at: 1_000, message: "@perfprobe look",
                           props: props(["mentions": .object([otherID: .bool(true)])]))
        XCTAssertFalse(ActivityDerivation.isLiveMention(notMine, myUserID: myID, keys: keys))

        let mine = post("p2", at: 1_000, message: "look",
                        props: props(["mentions": .object([myID: .bool(true)])]))
        XCTAssertTrue(ActivityDerivation.isLiveMention(mine, myUserID: myID, keys: keys))
    }

    func testWithoutThePropTheKeysDecide() throws {
        // Measured on 9.11.19: `props` is `{}` on a post that incremented the mention counter, so the text
        // match is not a fallback for a rare shape — it is the shipping path.
        let keys = MentionKeys(keys: [MentionKey("@perfprobe")])
        let emptyProps = post("p1", at: 1_000, message: "hey @perfprobe",
                              props: props([:]))
        XCTAssertTrue(ActivityDerivation.isLiveMention(emptyProps, myUserID: myID, keys: keys))
    }

    // MARK: - Rows: order, labels, read state

    func testRowsAreNewestFirstWithTheIdAsTiebreak() {
        let rows = ActivityDerivation.rows(posts: [post("p1", at: 10), post("p3", at: 30),
                                                   post("p2", at: 20), post("p4", at: 20)],
                                           channels: [channelID: channel()], users: [:],
                                           myUserID: myID, cursors: [:], threadUnread: [:])
        XCTAssertEqual(rows.map(\.postID), ["p3", "p4", "p2", "p1"])
    }

    func testARowCarriesItsChannelLabelAndTeamAndTheJumpItOpens() {
        let rows = ActivityDerivation.rows(posts: [post("p1", at: 10), post("p2", at: 20, rootID: "p1")],
                                           channels: [channelID: channel(name: "town-square")],
                                           users: [:], myUserID: myID, cursors: [:], threadUnread: [:])
        let root = try! XCTUnwrap(rows.first { $0.postID == "p1" })
        XCTAssertEqual(root.channelLabel, "#town-square")
        XCTAssertEqual(root.teamID, teamID)
        XCTAssertEqual(root.jump, .channel(postID: "p1"))

        let reply = try! XCTUnwrap(rows.first { $0.postID == "p2" })
        XCTAssertEqual(reply.jump, .thread(rootID: "p1"))
    }

    func testAnUnresolvedChannelSaysChannelRatherThanGuessing() {
        let rows = ActivityDerivation.rows(posts: [post("p1", at: 10)], channels: [:], users: [:],
                                           myUserID: myID, cursors: [:], threadUnread: [:])
        XCTAssertEqual(rows.first?.channelLabel, "channel")
        XCTAssertNil(rows.first?.teamID)
    }

    func testAChannelWithNoCursorIsUnread() {
        // A fresh channel member row answers `last_viewed_at: 0` with `mention_count > 0` (measured), so
        // "never read on this account" has to read as unread rather than as "older than my cursor".
        XCTAssertTrue(ActivityDerivation.isUnread(post("p1", at: 10), cursor: nil))
        XCTAssertTrue(ActivityDerivation.isUnread(post("p1", at: 10),
                                                  cursor: ActivityChannelCursor(channelID: channelID,
                                                                                lastViewedAt: 0)))
    }

    func testTheChannelCursorDecidesARootRow() {
        let cursor = ActivityChannelCursor(channelID: channelID, lastViewedAt: 1_000)
        XCTAssertFalse(ActivityDerivation.isUnread(post("p1", at: 900), cursor: cursor))
        XCTAssertTrue(ActivityDerivation.isUnread(post("p2", at: 1_001), cursor: cursor))
    }

    func testAReplyTakesItsReadStateFromTheThreadNotTheChannel() {
        // Reading a thread does not move the channel's `last_viewed_at` (measured), so a reply row whose
        // channel cursor is already past it is still unread — and the other way round.
        let rows = ActivityDerivation.rows(
            posts: [post("r1", at: 500, rootID: "root1"), post("r2", at: 500, rootID: "root2")],
            channels: [channelID: channel()], users: [:], myUserID: myID,
            cursors: [channelID: ActivityChannelCursor(channelID: channelID, lastViewedAt: 10_000)],
            threadUnread: ["root1": ActivityThreadUnread(rootID: "root1", unreadReplies: 0,
                                                         unreadMentions: 2),
                           "root2": ActivityThreadUnread(rootID: "root2", unreadReplies: 0,
                                                         unreadMentions: 0)])

        XCTAssertEqual(rows.first { $0.postID == "r1" }?.isUnread, true)
        XCTAssertEqual(rows.first { $0.postID == "r2" }?.isUnread, false)
        XCTAssertEqual(rows.first { $0.postID == "r1" }?.isThreadRow, true)
    }

    func testAReplyWithNoThreadStateFallsBackToTheChannelAndSaysSo() {
        let rows = ActivityDerivation.rows(
            posts: [post("r1", at: 500, rootID: "root1")], channels: [channelID: channel()],
            users: [:], myUserID: myID,
            cursors: [channelID: ActivityChannelCursor(channelID: channelID, lastViewedAt: 100)],
            threadUnread: [:])
        XCTAssertEqual(rows.first?.isUnread, true)
        // Not from a thread state: the view's swipe action must say "mark channel read", not "mark thread
        // read", because that is what it would actually do.
        XCTAssertEqual(rows.first?.isThreadRow, false)
    }

    func testTheUnreadFilterKeepsOnlyUnreadRows() {
        let all = ActivityDerivation.rows(
            posts: [post("p1", at: 10), post("p2", at: 20)], channels: [channelID: channel()],
            users: [:], myUserID: myID,
            cursors: [channelID: ActivityChannelCursor(channelID: channelID, lastViewedAt: 15)],
            threadUnread: [:])
        XCTAssertEqual(ActivityDerivation.visible(all, filter: .all).map(\.postID), ["p2", "p1"])
        XCTAssertEqual(ActivityDerivation.visible(all, filter: .unread).map(\.postID), ["p2"])
    }

    func testTheSubtitleAndEmptyCopySayWhatIsActuallyThere() {
        XCTAssertEqual(ActivityDerivation.subtitle(rows: []), "No mentions yet")
        XCTAssertEqual(ActivityDerivation.emptyCopy(filter: .all, totalRows: 0),
                       "Messages that mention you appear here — from every channel and team.")
        XCTAssertEqual(ActivityDerivation.emptyCopy(filter: .unread, totalRows: 3),
                       "You have read every mention in this window.")
        XCTAssertEqual(ActivityDerivation.emptyCopy(filter: .unread, totalRows: 0),
                       "You have no mentions yet.")
    }

    func testMarkableChannelIDsAreDeduplicatedAndOnlyUnreadOnes() {
        let rows = ActivityDerivation.rows(
            posts: [post("p1", at: 10, channel: "c1"), post("p2", at: 20, channel: "c1"),
                    post("p3", at: 5, channel: "c2"), post("p4", at: 30, channel: "c2")],
            channels: ["c1": channel("c1"), "c2": channel("c2")], users: [:], myUserID: myID,
            cursors: ["c1": ActivityChannelCursor(channelID: "c1", lastViewedAt: 0),
                      "c2": ActivityChannelCursor(channelID: "c2", lastViewedAt: 25)],
            threadUnread: [:])
        // Newest-first order, so c2 (a newer unread) comes first; c1 is deduplicated across its two rows.
        XCTAssertEqual(ActivityDerivation.unreadChannelIDs(rows), ["c2", "c1"])
    }

    func testALiveRowIsInsertedInTheServersOrderAndReplacesItself() {
        let existing = ActivityDerivation.rows(posts: [post("p1", at: 10), post("p3", at: 30)],
                                               channels: [channelID: channel()], users: [:],
                                               myUserID: myID, cursors: [:], threadUnread: [:])
        let fresh = ActivityDerivation.rows(posts: [post("p2", at: 20)],
                                            channels: [channelID: channel()], users: [:],
                                            myUserID: myID, cursors: [:], threadUnread: [:])
        let merged = ActivityDerivation.inserting(fresh[0], into: existing)
        XCTAssertEqual(merged.map(\.postID), ["p3", "p2", "p1"])

        // The same id arriving twice (a re-delivered frame) must not double the row.
        let again = ActivityDerivation.inserting(fresh[0], into: merged)
        XCTAssertEqual(again.map(\.postID), ["p3", "p2", "p1"])
    }

    func testTeamIDsAreDistinctAndSorted() {
        let rows = ActivityDerivation.rows(posts: [post("p1", at: 10, channel: "c1"),
                                                   post("p2", at: 20, channel: "c2"),
                                                   post("p3", at: 30, channel: "c3")],
                                           channels: ["c1": channel("c1", team: "tB"),
                                                      "c2": channel("c2", team: "tA"),
                                                      "c3": channel("c3", team: "tB")],
                                           users: [:], myUserID: myID, cursors: [:], threadUnread: [:])
        XCTAssertEqual(ActivityDerivation.teamIDs(rows), ["tA", "tB"])
    }

    // MARK: - The view model

    @MainActor
    final class FakeActivityService: ActivityServing {
        var profileAnswer = ActivityProfile()
        var windowAnswer = MMSearchResults()
        var pages: [Int: MMSearchResults] = [:]
        var channelsByID: [String: MMChannel] = [:]
        var usersByID: [String: MMUser] = [:]
        var readsByTeam: [String: [MMChannelMember]] = [:]
        var readByChannel: [String: MMChannelMember] = [:]
        var threadStates: [String: [ActivityThreadUnread]] = [:]
        var counters: [MMTeamUnread] = []
        var markReadAnswer: ((_ channelIDs: [String], _ userID: String) -> MMChannelViewResponse)?
        var markThreadAnswer: ((String) -> ActivityThreadUnread)?
        var failure: Error?
        var writeFailure: Error?
        var pageSize = 60

        private(set) var profileCalls = 0
        private(set) var mentionCalls: [(terms: String, page: Int, perPage: Int)] = []
        private(set) var channelCalls: [String] = []
        private(set) var userCalls: [[String]] = []
        private(set) var readTeamCalls: [(teamID: String, userID: String)] = []
        private(set) var readChannelCalls: [String] = []
        private(set) var markReadCalls: [[String]] = []
        private(set) var markThreadCalls: [(teamID: String, rootID: String, at: Int64)] = []
        private(set) var counterCalls = 0

        func profile() async throws -> ActivityProfile {
            profileCalls += 1
            if let failure { throw failure }
            return profileAnswer
        }

        func mentions(terms: String, page: Int, perPage: Int) async throws -> MMSearchResults {
            mentionCalls.append((terms, page, perPage))
            if let failure { throw failure }
            return pages[page] ?? windowAnswer
        }

        func channel(id: String) async throws -> MMChannel {
            channelCalls.append(id)
            guard let channel = channelsByID[id] else { throw MMError.notFound }
            return channel
        }

        func users(ids: [String]) async throws -> [MMUser] {
            userCalls.append(ids)
            return ids.compactMap { usersByID[$0] }
        }

        func channelReads(teamID: String, userID: String) async throws -> [MMChannelMember] {
            readTeamCalls.append((teamID, userID))
            return readsByTeam[teamID] ?? []
        }

        func channelRead(channelID: String, userID: String) async throws -> MMChannelMember {
            readChannelCalls.append(channelID)
            guard let member = readByChannel[channelID] else { throw MMError.notFound }
            return member
        }

        func markChannelsRead(channelIDs: [String], userID: String) async throws -> MMChannelViewResponse {
            markReadCalls.append(channelIDs)
            if let writeFailure { throw writeFailure }
            if let markReadAnswer { return markReadAnswer(channelIDs, userID) }
            // The server's own answer: every marked channel is now read as of `now`.
            return MMChannelViewResponse(status: "ok",
                                         lastViewedAtTimes: Dictionary(uniqueKeysWithValues:
                                             channelIDs.map { ($0, 9_000) }))
        }

        func unreadThreads(teamID: String) async throws -> [ActivityThreadUnread] {
            threadStates[teamID] ?? []
        }

        func markThreadRead(teamID: String, rootID: String,
                            at timestamp: Int64) async throws -> ActivityThreadUnread {
            markThreadCalls.append((teamID, rootID, timestamp))
            if let writeFailure { throw writeFailure }
            return markThreadAnswer?(rootID)
                ?? ActivityThreadUnread(rootID: rootID, unreadReplies: 0, unreadMentions: 0,
                                        lastViewedAt: timestamp)
        }

        func badgeCounters() async throws -> [MMTeamUnread] {
            counterCalls += 1
            return counters
        }
    }

    private func makeService() -> FakeActivityService {
        let service = FakeActivityService()
        service.profileAnswer = profile
        service.channelsByID = [channelID: channel()]
        service.usersByID = [otherID: MMUser(id: otherID, username: "avone72453",
                                            firstName: "Ada", lastName: "Vone")]
        service.counters = [MMTeamUnread(teamId: teamID, mentionCount: 2, msgCount: 5)]
        return service
    }

    private func makeModel(_ service: FakeActivityService,
                           now: @escaping () -> Int64 = { 9_000 }) -> MentionsViewModel {
        MentionsViewModel(service: service, myUserID: myID, now: now)
    }

    func testLoadAsksForTheKeysWindowAndBuildsRowsWithTheirReadState() async {
        let service = makeService()
        service.windowAnswer = MMSearchResults(order: ["p2", "p1"],
                                               posts: ["p1": post("p1", at: 500, message: "hey @perfprobe"),
                                                       "p2": post("p2", at: 1_500, message: "@perfprobe again")])
        service.readsByTeam[teamID] = [member(channelID, viewedAt: 1_000)]
        let model = makeModel(service)

        var badge: [(Int, Bool)] = []
        model.onBadgeInput = { badge.append(($0, $1)) }

        await model.load()

        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(service.profileCalls, 1)
        // One search, with upstream's terms (personal keys only, trailing space) and the page size.
        XCTAssertEqual(service.mentionCalls.count, 1)
        XCTAssertEqual(service.mentionCalls.first?.terms, "deploybot @perfprobe ")
        XCTAssertEqual(service.mentionCalls.first?.page, 0)
        XCTAssertEqual(service.mentionCalls.first?.perPage, 60)

        // One channel read + one batched profile read, not one per row.
        XCTAssertEqual(service.channelCalls, [channelID])
        XCTAssertEqual(service.userCalls.count, 1)
        XCTAssertEqual(service.readTeamCalls.map(\.teamID), [teamID])
        XCTAssertEqual(service.readTeamCalls.first?.userID, myID)

        XCTAssertEqual(model.loadedPostIDs, ["p2", "p1"])
        XCTAssertEqual(model.row(postID: "p2")?.isUnread, true)
        XCTAssertEqual(model.row(postID: "p1")?.isUnread, false)
        XCTAssertEqual(model.row(postID: "p2")?.channelLabel, "#town-square")
        XCTAssertEqual(model.subtitle, "2 mentions · 1 unread")

        // The badge came from the server's counters, through the store's own math.
        XCTAssertEqual(badge.count, 1)
        XCTAssertEqual(badge.first?.0, 2)
        XCTAssertEqual(badge.first?.1, true)
    }

    func testASecondLoadDoesNotRefetchTheReaderOrTheChannel() async {
        let service = makeService()
        service.windowAnswer = MMSearchResults(order: ["p1"], posts: ["p1": post("p1", at: 500)])
        let model = makeModel(service)

        await model.load()
        await model.reload()

        XCTAssertEqual(service.profileCalls, 1)
        XCTAssertEqual(service.channelCalls, [channelID])
        XCTAssertEqual(service.mentionCalls.count, 2)
    }

    func testADirectMessageRowReadsItsOwnCursorBecauseNoTeamListCoversIt() async {
        let service = makeService()
        service.channelsByID = [dmID: channel(dmID, team: "", name: "ada--perf", type: "D"),
                                channelID: channel()]
        service.windowAnswer = MMSearchResults(order: ["p1"], posts: ["p1": post("p1", at: 500,
                                                                                channel: dmID)])
        service.readByChannel[dmID] = member(dmID, viewedAt: 100)
        let model = makeModel(service)

        await model.load()

        XCTAssertEqual(service.readChannelCalls, [dmID])
        XCTAssertEqual(model.row(postID: "p1")?.isUnread, true)
        // A DM's label is its display name, not "#name".
        XCTAssertEqual(model.row(postID: "p1")?.channelLabel, "ada--perf")
        XCTAssertNil(model.row(postID: "p1")?.teamID)
    }

    func testMarkingARootRowReadUsesTheChannelsReadEndpointAndClearsTheDot() async {
        let service = makeService()
        service.windowAnswer = MMSearchResults(order: ["p1"], posts: ["p1": post("p1", at: 500)])
        service.readsByTeam[teamID] = [member(channelID, viewedAt: 100)]
        let model = makeModel(service)
        await model.load()
        XCTAssertEqual(model.row(postID: "p1")?.isUnread, true)

        let row = try! XCTUnwrap(model.row(postID: "p1"))
        let ok = await model.markRead(row)

        XCTAssertTrue(ok)
        XCTAssertEqual(service.markReadCalls, [[channelID]])
        XCTAssertEqual(service.markThreadCalls.count, 0)
        XCTAssertEqual(model.row(postID: "p1")?.isUnread, false)
        XCTAssertNil(model.actionError)
    }

    func testMarkingAReplyReadUsesTheThreadReadEndpoint() async {
        let service = makeService()
        service.windowAnswer = MMSearchResults(order: ["r1"], posts: ["r1": post("r1", at: 500,
                                                                                rootID: "root1")])
        service.readsByTeam[teamID] = [member(channelID, viewedAt: 10_000)]
        service.threadStates[teamID] = [ActivityThreadUnread(rootID: "root1", unreadReplies: 0,
                                                             unreadMentions: 1)]
        let model = makeModel(service)
        await model.load()
        let row = try! XCTUnwrap(model.row(postID: "r1"))
        XCTAssertTrue(row.isUnread)

        let ok = await model.markRead(row)

        XCTAssertTrue(ok)
        XCTAssertEqual(service.markThreadCalls.count, 1)
        XCTAssertEqual(service.markThreadCalls.first?.teamID, teamID)
        XCTAssertEqual(service.markThreadCalls.first?.rootID, "root1")
        XCTAssertEqual(service.markThreadCalls.first?.at, 9_000)
        XCTAssertEqual(service.markReadCalls.count, 0)
        XCTAssertEqual(model.row(postID: "r1")?.isUnread, false)
    }

    func testMarkAllReadSendsEveryUnreadChannelOnceAndClearsReplyRowsToo() async {
        let service = makeService()
        service.channelsByID = ["c1": channel("c1"), "c2": channel("c2")]
        service.windowAnswer = MMSearchResults(
            order: ["r1", "p2", "p1"],
            posts: ["p1": post("p1", at: 500, channel: "c1"),
                    "p2": post("p2", at: 600, channel: "c2"),
                    "r1": post("r1", at: 700, channel: "c1", rootID: "root1")])
        service.readsByTeam[teamID] = [member("c1", viewedAt: 0), member("c2", viewedAt: 0)]
        service.threadStates[teamID] = [ActivityThreadUnread(rootID: "root1", unreadReplies: 0,
                                                             unreadMentions: 1)]
        let model = makeModel(service)
        await model.load()
        XCTAssertEqual(model.unreadCount, 3)

        let ok = await model.markAllRead()

        XCTAssertTrue(ok)
        XCTAssertEqual(service.markReadCalls.count, 1)
        XCTAssertEqual(service.markReadCalls.first, ["c1", "c2"])
        // The server recomputes the channel rows on a read — thread mentions included — so a reply row in
        // one of those channels must not be left behind by "mark all read".
        XCTAssertEqual(model.unreadCount, 0)
        XCTAssertEqual(model.visibleRows.count, 3)
    }

    func testMarkAllReadWithNothingUnreadIsNotARequest() async {
        let service = makeService()
        service.windowAnswer = MMSearchResults(order: ["p1"], posts: ["p1": post("p1", at: 500)])
        service.readsByTeam[teamID] = [member(channelID, viewedAt: 10_000)]
        let model = makeModel(service)
        await model.load()

        let ok = await model.markAllRead()

        XCTAssertTrue(ok)
        XCTAssertEqual(service.markReadCalls.count, 0)
    }

    func testAFailedWriteSaysSoAndLeavesTheRowUnread() async {
        let service = makeService()
        service.windowAnswer = MMSearchResults(order: ["p1"], posts: ["p1": post("p1", at: 500)])
        service.readsByTeam[teamID] = [member(channelID, viewedAt: 100)]
        service.writeFailure = MMError.offline
        let model = makeModel(service)
        await model.load()

        let row = try! XCTUnwrap(model.row(postID: "p1"))
        let ok = await model.markRead(row)

        XCTAssertFalse(ok)
        XCTAssertEqual(model.row(postID: "p1")?.isUnread, true)
        XCTAssertEqual(model.actionError,
                       "You are offline. This mention stays unread until the connection is back.")
    }

    func testAFailedLoadSaysSoInsteadOfShowingAnEmptyInbox() async {
        let service = makeService()
        service.failure = MMError.offline
        let model = makeModel(service)

        await model.load()

        guard case .failed(let message) = model.phase else {
            return XCTFail("expected a failed phase, got \(model.phase)")
        }
        XCTAssertEqual(message, "You are offline. Your mentions will load when the connection is back.")
    }

    func testTheFilterSwitchesWithoutAnotherRequest() async {
        let service = makeService()
        service.windowAnswer = MMSearchResults(order: ["p2", "p1"],
                                               posts: ["p1": post("p1", at: 500),
                                                       "p2": post("p2", at: 1_500)])
        service.readsByTeam[teamID] = [member(channelID, viewedAt: 1_000)]
        let model = makeModel(service)
        await model.load()
        XCTAssertEqual(model.visibleRows.map(\.postID), ["p2", "p1"])

        model.select(filter: .unread)

        XCTAssertEqual(model.visibleRows.map(\.postID), ["p2"])
        XCTAssertEqual(model.emptyCopy, "You have read every mention in this window.")
        XCTAssertEqual(service.mentionCalls.count, 1)
    }

    // MARK: - The feed is live

    func testAMentionThatArrivesWhileOpenIsInsertedWithoutAReload() async throws {
        let service = makeService()
        service.windowAnswer = MMSearchResults(order: ["p1"], posts: ["p1": post("p1", at: 500)])
        service.readsByTeam[teamID] = [member(channelID, viewedAt: 100)]
        service.readByChannel[channelID] = member(channelID, viewedAt: 100)
        let model = makeModel(service)
        await model.load()

        let live = post("p9", at: 2_000, message: "hey @perfprobe, the build is green")
        let outcome = model.handle(.posted(live))
        XCTAssertEqual(outcome, .inserted)

        // The row lands when its channel and author are resolved, off the event path.
        for _ in 0..<200 where model.row(postID: "p9") == nil {
            await Task.yield()
        }
        let row = try XCTUnwrap(model.row(postID: "p9"))
        XCTAssertEqual(row.isUnread, true)
        XCTAssertEqual(row.channelLabel, "#town-square")
        XCTAssertEqual(model.loadedPostIDs, ["p9", "p1"])
        XCTAssertEqual(model.insertedRowID, "p9")
        XCTAssertEqual(service.mentionCalls.count, 1, "a live insert must not refetch the window")
    }

    func testAPostThatIsNotAMentionOfMeIsIgnored() async {
        let service = makeService()
        service.windowAnswer = MMSearchResults(order: [], posts: [:])
        let model = makeModel(service)
        await model.load()

        let other = post("p8", at: 2_000, message: "morning all")
        XCTAssertEqual(model.handle(.posted(other)), .ignored)
        XCTAssertEqual(model.loadedCount, 0)
    }

    func testMyOwnPostIsNotInserted() async {
        let service = makeService()
        service.windowAnswer = MMSearchResults(order: [], posts: [:])
        let model = makeModel(service)
        await model.load()

        let mine = post("p7", at: 2_000, message: "@perfprobe to self", author: myID)
        XCTAssertEqual(model.handle(.posted(mine)), .ignored)
    }

    func testADeletedPostLeavesTheList() async {
        let service = makeService()
        service.windowAnswer = MMSearchResults(order: ["p1", "p2"],
                                               posts: ["p1": post("p1", at: 500),
                                                       "p2": post("p2", at: 600)])
        let model = makeModel(service)
        await model.load()
        XCTAssertEqual(model.loadedCount, 2)

        XCTAssertEqual(model.handle(.postDeleted(post("p2", at: 600))), .removed)
        XCTAssertEqual(model.loadedPostIDs, ["p1"])
    }

    func testMyReadStateMovingElsewhereIsFollowed() async {
        let service = makeService()
        service.windowAnswer = MMSearchResults(order: ["p1"], posts: ["p1": post("p1", at: 500)])
        service.readsByTeam[teamID] = [member(channelID, viewedAt: 100)]
        let model = makeModel(service)
        await model.load()
        XCTAssertEqual(model.row(postID: "p1")?.isUnread, true)

        // Another client of mine read the channel: the frame carries the server's own cursor.
        let outcome = model.handle(.multipleChannelsViewed(
            SocketMultipleChannelsViewed(userID: myID, channelTimes: [channelID: 1_000])))
        XCTAssertEqual(outcome, .readStateChanged)
        XCTAssertEqual(model.row(postID: "p1")?.isUnread, false)
    }

    func testAChannelRenameArrivingOverTheSocketRelabelsItsRows() async {
        let service = makeService()
        service.windowAnswer = MMSearchResults(order: ["p1"], posts: ["p1": post("p1", at: 500)])
        let model = makeModel(service)
        await model.load()
        XCTAssertEqual(model.row(postID: "p1")?.channelLabel, "#town-square")

        XCTAssertEqual(model.handle(.channelUpdated(channel(name: "engineering"))), .patched)
        XCTAssertEqual(model.row(postID: "p1")?.channelLabel, "#engineering")
    }

    // MARK: - The badge's single arithmetic

    func testServerCountersBecomeOneBadgeInput() {
        let input = SessionStore.serverBadgeInput(mentionCounts: [2, 0, 3], messageCounts: [10, 0, 4])
        XCTAssertEqual(input.mentions, 5)
        XCTAssertEqual(input.isUnread, true)

        // Mentions are the badge's number; an unread message with no mention is still "something new".
        let quiet = SessionStore.serverBadgeInput(mentionCounts: [0, 0], messageCounts: [0, 1])
        XCTAssertEqual(quiet.mentions, 0)
        XCTAssertEqual(quiet.isUnread, true)

        let nothing = SessionStore.serverBadgeInput(mentionCounts: [], messageCounts: [])
        XCTAssertEqual(nothing.mentions, 0)
        XCTAssertEqual(nothing.isUnread, false)
    }

    func testTheFeedAndThePollerReachTheStoreThroughTheSameEntryPoint() throws {
        let suiteName = "T42ActivityTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SessionStore(preferences: AppPreferences(defaults: defaults),
                                 badgeSetter: NoopBadge())
        let serverID = UUID()

        store.applyServerCounters(serverID: serverID,
                                  mentionCounts: [1, 2], messageCounts: [0, 0])
        XCTAssertEqual(store.totalMentions, 3)
        XCTAssertEqual(store.hasUnread, true)
        XCTAssertEqual(store.badgeNumber, 3)

        store.applyServerCounters(serverID: serverID, mentionCounts: [0], messageCounts: [0])
        XCTAssertEqual(store.totalMentions, 0)
        XCTAssertEqual(store.hasUnread, false)
        XCTAssertEqual(store.badgeNumber, 0)
    }

    private struct NoopBadge: BadgeSettable {
        func setBadge(_ count: Int) {}
    }
}
