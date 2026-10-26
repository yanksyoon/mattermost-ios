// T37 — emoji reactions and the picker, unit side.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb),
// app/actions/remote/reactions.ts (`toggleReaction` → add/remove, `getEmojiFirstAlias` on every write),
// app/actions/local/reactions.ts (`addRecentReaction`, `MAXIMUM_RECENT_EMOJI = 27`),
// app/screens/reactions/reactions.tsx (`getSortedReactions`: the bar's order is stable while open),
// app/screens/emoji_picker/picker/* (recents → custom → categories; the search strips colons).
//
// What is under test, in the order the acceptance criteria ask for it:
//  1. alias identity — `thumbsup` and `+1` are two server rows but one pill (measured on 9.11.19 with
//     `scripts/t37_reaction_probe.py`);
//  2. the toggle machine — one request in flight, coalesced taps, a single rollback on failure;
//  3. the coordinator — optimistic apply, canonical name on the wire, every held alias deleted, an
//     echo of our own socket event does not double the count;
//  4. the picker's model — recents first, categories, search, custom names;
//  5. the recents MRU rules.
//
// Nothing here touches the network: the writer, the target and the emoji table are all injected.

import XCTest
@testable import Mattermost

@MainActor
final class T37ReactionTests: XCTestCase {

    // MARK: - Fixtures

    /// A post whose `metadata.reactions` is exactly `reactions`.
    private func post(id: String, reactions: [MMReaction] = [], deleteAt: Int64 = 0) -> MMPost {
        var post = MMPost(id: id, createAt: 1_000, deleteAt: deleteAt, userId: "author", channelId: "ch")
        post.metadata = .object(["reactions": .array(reactions.map(Self.value(for:)))])
        return post
    }

    private static func value(for reaction: MMReaction) -> JSONValue {
        .object(["user_id": .string(reaction.userId),
                 "post_id": .string(reaction.postId),
                 "emoji_name": .string(reaction.emojiName),
                 "create_at": .number(Double(reaction.createAt))])
    }

    /// The pane side of the protocol, reduced to what the coordinator uses: a post dictionary whose
    /// reactions are mutated *set-shaped*, exactly like `ChannelViewModel.appendReaction`.
    private final class Target: ReactionTarget {
        var myUserID: String?
        var posts: [String: MMPost]
        var users: [String: MMUser] = [:]
        var profileRequests: [[String]] = []

        init(myUserID: String?, posts: [MMPost]) {
            self.myUserID = myUserID
            self.posts = Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) })
        }

        var reactionUserProfiles: [String: MMUser] { users }

        func post(id: String) -> MMPost? { posts[id] }

        @discardableResult
        func applyReaction(_ reaction: MMReaction, adding: Bool) -> Bool {
            guard var post = posts[reaction.postId] else { return false }
            var list = post.metadata?["reactions"]?.arrayValue ?? []
            let matches: (JSONValue) -> Bool = { value in
                guard let existing = try? MMRawJSON(value).decode(MMReaction.self) else { return false }
                return existing.userId == reaction.userId && existing.emojiName == reaction.emojiName
            }
            let present = list.contains(where: matches)
            if adding {
                guard !present else { return false }
                list.append(T37ReactionTests.value(for: reaction))
            } else {
                guard present else { return false }
                list.removeAll(where: matches)
            }
            post.metadata = .object(["reactions": .array(list)])
            posts[reaction.postId] = post
            return true
        }

        func loadReactionProfiles(for userIDs: [String]) async {
            profileRequests.append(userIDs)
        }

        /// The reaction rows the pane holds for one post, in order.
        func rows(_ postID: String) -> [MMReaction] {
            (posts[postID]?.metadata?["reactions"]?.arrayValue ?? []).compactMap {
                try? MMRawJSON($0).decode(MMReaction.self)
            }
        }
    }

    private final class Writer {
        var added: [(postID: String, emoji: String, userID: String)] = []
        var removed: [(postID: String, emoji: String, userID: String)] = []
        var failure: Error?
        /// How long each call takes — a test that wants to tap *during* a flight sets this.
        var delay: Duration = .zero
    }

    private func coordinator(_ target: Target, _ writer: Writer) -> ReactionCoordinator {
        ReactionCoordinator(
            add: { postID, emoji, userID in
                if writer.delay != .zero { try? await Task.sleep(for: writer.delay) }
                if let failure = writer.failure { throw failure }
                writer.added.append((postID, emoji, userID))
                return MMReaction(userId: userID, postId: postID, emojiName: emoji, createAt: 1)
            },
            remove: { postID, emoji, userID in
                if writer.delay != .zero { try? await Task.sleep(for: writer.delay) }
                if let failure = writer.failure { throw failure }
                writer.removed.append((postID, emoji, userID))
            },
            target: target)
    }

    /// Let the coordinator's write tasks run to completion.
    private func settle(_ milliseconds: Int = 40) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    // MARK: - 1. Alias identity

    func testAliasesShareOnePillName() {
        let system = SystemEmojiCatalogue.shared
        XCTAssertNil(system.degradedReason,
                     "the bundled emoji.json must be in the app bundle: \(system.degradedReason ?? "")")
        XCTAssertEqual(ReactionAliases.canonical("thumbsup", system: system),
                       ReactionAliases.canonical("+1", system: system))
        XCTAssertFalse(ReactionAliases.canonical("thumbsup", system: system).isEmpty)
    }

    func testUnknownNameKeepsItsServerSpelling() {
        let system = SystemEmojiCatalogue.shared
        // A custom emoji is not the system table's business: the server's spelling is case-sensitive.
        XCTAssertEqual(ReactionAliases.canonical("t34parrot", system: system), "t34parrot")
        XCTAssertEqual(ReactionAliases.canonical("  smile  ", system: system),
                       ReactionAliases.canonical("smile", system: system))
        XCTAssertEqual(ReactionAliases.canonical("", system: system), "")
    }

    func testGroupsFoldAliasesInFirstAppearanceOrder() {
        let system = SystemEmojiCatalogue.shared
        let groups = ReactionAliases.groups(["+1", "thumbsup", "smile"], system: system)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].names, ["+1", "thumbsup"])
        XCTAssertEqual(groups[1].key, "smile")
    }

    // MARK: - 2. The toggle machine

    func testFirstTapSendsAnAdd() {
        var toggles = ReactionToggles()
        let key = ReactionToggles.Key(postID: "p1", emojiName: "smile")
        let step = toggles.tapped(key, current: false)
        XCTAssertEqual(step, .send(desired: true))
        XCTAssertEqual(toggles.toggle(key)?.inFlight, true)
        XCTAssertEqual(toggles.inFlightCount, 1)
    }

    func testATapDuringAFlightIsDeferredAndTheCompletionSendsTheFinalDesire() {
        var toggles = ReactionToggles()
        let key = ReactionToggles.Key(postID: "p1", emojiName: "smile")
        XCTAssertEqual(toggles.tapped(key, current: false), .send(desired: true))
        // Second tap while the add is out: the reader's model is "now it is off".
        XCTAssertEqual(toggles.tapped(key, current: true), .deferred)
        XCTAssertEqual(toggles.toggle(key)?.desired, false)
        // The add lands: the follow-up remove is what the machine owes the server.
        XCTAssertEqual(toggles.sent(key, state: true, success: true), .send(desired: false))
        XCTAssertEqual(toggles.toggle(key)?.inFlight, true)
        XCTAssertEqual(toggles.sent(key, state: false, success: true), .none)
        XCTAssertEqual(toggles.toggle(key)?.confirmed, false)
        XCTAssertEqual(toggles.inFlightCount, 0)
    }

    func testTwoTapsThatReturnToTheOriginalStateSendOneRequest() {
        var toggles = ReactionToggles()
        let key = ReactionToggles.Key(postID: "p1", emojiName: "smile")
        XCTAssertEqual(toggles.tapped(key, current: false), .send(desired: true))
        XCTAssertEqual(toggles.tapped(key, current: true), .deferred)
        XCTAssertEqual(toggles.tapped(key, current: false), .deferred)
        // Back where the server already is: the completion sees desired == confirmed and sends nothing.
        XCTAssertEqual(toggles.sent(key, state: true, success: true), .none)
        XCTAssertEqual(toggles.inFlightCount, 0)
    }

    func testAFailedWriteRollsBackToTheServersStateOnce() {
        var toggles = ReactionToggles()
        let key = ReactionToggles.Key(postID: "p1", emojiName: "smile")
        XCTAssertEqual(toggles.tapped(key, current: false), .send(desired: true))
        XCTAssertEqual(toggles.sent(key, state: true, success: false), .rollback(to: false))
        XCTAssertEqual(toggles.toggle(key)?.desired, false)
        XCTAssertEqual(toggles.toggle(key)?.confirmed, false)
        // The intent is gone: a later tap starts from the truth.
        XCTAssertEqual(toggles.tapped(key, current: false), .send(desired: true))
    }

    func testAFailureAfterAQueuedTapRollsBackToConfirmedOnly() {
        var toggles = ReactionToggles()
        let key = ReactionToggles.Key(postID: "p1", emojiName: "smile")
        XCTAssertEqual(toggles.tapped(key, current: false), .send(desired: true))
        XCTAssertEqual(toggles.tapped(key, current: true), .deferred)     // wants off again
        // The add failed, so the server never had it; the pill must go back to *off* — which is what
        // the reader asked for anyway, so there is nothing left to apply.
        XCTAssertEqual(toggles.sent(key, state: true, success: false), .rollback(to: false))
        XCTAssertEqual(toggles.toggle(key)?.desired, false)
    }

    func testASocketEventAlignsBookkeepingWithoutRequestingAWrite() {
        var toggles = ReactionToggles()
        let key = ReactionToggles.Key(postID: "p1", emojiName: "smile")
        XCTAssertEqual(toggles.tapped(key, current: false), .send(desired: true))
        XCTAssertEqual(toggles.sent(key, state: true, success: true), .none)
        // Another device removed it: the host has already patched the post, the machine follows.
        XCTAssertEqual(toggles.socketEvent(key, present: false), .none)
        XCTAssertEqual(toggles.toggle(key)?.confirmed, false)
        XCTAssertEqual(toggles.toggle(key)?.desired, false)
        XCTAssertEqual(toggles.inFlightCount, 0)
    }

    func testAnInFlightDesireSurvivesAPageAdopt() {
        var toggles = ReactionToggles()
        let key = ReactionToggles.Key(postID: "p1", emojiName: "smile")
        XCTAssertEqual(toggles.tapped(key, current: false), .send(desired: true))
        // The page predates the write; adopting it must not cancel the write the reader asked for.
        XCTAssertEqual(toggles.adoptServerState(key, present: false), .none)
        XCTAssertEqual(toggles.toggle(key)?.desired, true)
        XCTAssertEqual(toggles.toggle(key)?.confirmed, false)
    }

    // MARK: - 3. The coordinator

    func testTapAppliesImmediatelyAndSendsTheCanonicalName() async {
        let target = Target(myUserID: "me", posts: [post(id: "p1")])
        let writer = Writer()
        let reactions = coordinator(target, writer)

        XCTAssertTrue(reactions.toggle(postID: "p1", emojiName: "thumbsup"))
        // Optimistic: the pane holds it before the request is answered.
        XCTAssertEqual(target.rows("p1").map(\.emojiName),
                       [ReactionAliases.canonical("thumbsup", system: .shared)])

        await settle()
        XCTAssertEqual(writer.added.count, 1)
        XCTAssertEqual(writer.added.first?.emoji,
                       ReactionAliases.canonical("thumbsup", system: .shared))
        XCTAssertEqual(writer.added.first?.userID, "me")
        XCTAssertNil(reactions.lastFailure)
        XCTAssertEqual(reactions.toggles.toggle(.init(postID: "p1", emojiName: "+1"))?.confirmed, true)
    }

    func testAFailedWriteRollsThePillBackAndNamesTheEmoji() async throws {
        let target = Target(myUserID: "me", posts: [post(id: "p1")])
        let writer = Writer()
        writer.failure = MMError.offline
        let reactions = coordinator(target, writer)

        XCTAssertTrue(reactions.toggle(postID: "p1", emojiName: "smile"))
        XCTAssertEqual(target.rows("p1").count, 1)

        await settle()
        XCTAssertEqual(target.rows("p1").count, 0, "a rejected write must not leave the pill on")
        let failure = try XCTUnwrap(reactions.lastFailure)
        XCTAssertTrue(failure.contains("smile"), failure)
        XCTAssertFalse(reactions.toggles.values().contains { $0.inFlight })

        // The next tap is a fresh attempt, not a stuck state.
        XCTAssertTrue(reactions.toggle(postID: "p1", emojiName: "smile"))
        XCTAssertEqual(reactions.lastFailure, failure, "the banner stays until a write succeeds")
    }

    func testTappingDuringAFlightCoalescesIntoOneFollowUpRequest() async {
        let target = Target(myUserID: "me", posts: [post(id: "p1")])
        let writer = Writer()
        writer.delay = .milliseconds(30)
        let reactions = coordinator(target, writer)

        reactions.toggle(postID: "p1", emojiName: "smile")   // add
        reactions.toggle(postID: "p1", emojiName: "smile")   // remove, queued
        XCTAssertEqual(reactions.requestsSent, 1)

        await settle(120)
        XCTAssertEqual(writer.added.count, 1)
        XCTAssertEqual(writer.removed.count, 1)
        XCTAssertEqual(target.rows("p1").count, 0)
        XCTAssertEqual(reactions.requestsSent, 2)
    }

    func testRemovingDeletesEveryAliasTheUserHolds() async {
        // The server stores `thumbsup` *and* `+1` as separate rows (measured), so a remove has to
        // name both or one of them survives and the pill returns on the next page load.
        let held = [MMReaction(userId: "me", postId: "p1", emojiName: "+1"),
                    MMReaction(userId: "me", postId: "p1", emojiName: "thumbsup"),
                    MMReaction(userId: "other", postId: "p1", emojiName: "+1")]
        let target = Target(myUserID: "me", posts: [post(id: "p1", reactions: held)])
        let writer = Writer()
        let reactions = coordinator(target, writer)

        XCTAssertTrue(reactions.toggle(postID: "p1", emojiName: "+1"))
        // Mine is gone; the other reader's row is untouched.
        XCTAssertEqual(target.rows("p1").map(\.userId), ["other"])

        await settle()
        XCTAssertEqual(Set(writer.removed.map(\.emoji)), ["+1", "thumbsup"])
        XCTAssertEqual(writer.removed.allSatisfy { $0.userID == "me" }, true)
        XCTAssertTrue(writer.added.isEmpty)
    }

    func testASocketEchoOfOurOwnWriteDoesNotDoubleTheCount() async {
        let target = Target(myUserID: "me", posts: [post(id: "p1")])
        let writer = Writer()
        let reactions = coordinator(target, writer)

        reactions.toggle(postID: "p1", emojiName: "smile")
        await settle()
        XCTAssertEqual(target.rows("p1").count, 1)

        // The socket `reaction_added` for our own write: the pane applies it (a no-op) and the machine
        // is told. The count must stay 1 and no request may follow.
        let echo = MMReaction(userId: "me", postId: "p1", emojiName: "smile")
        XCTAssertEqual(target.applyReaction(echo, adding: true), false, "identical row is a no-op")
        reactions.noteSocketEvent(echo, adding: true)
        await settle()

        XCTAssertEqual(target.rows("p1").count, 1)
        XCTAssertEqual(reactions.requestsSent, 1)
        XCTAssertEqual(writer.added.count, 1)
    }

    func testAReactionOnAnotherUsersRowIsNotMyWrite() async {
        let target = Target(myUserID: "me", posts: [post(id: "p1")])
        let writer = Writer()
        let reactions = coordinator(target, writer)

        reactions.noteSocketEvent(MMReaction(userId: "other", postId: "p1", emojiName: "smile"),
                                  adding: true)
        await settle()
        XCTAssertEqual(reactions.requestsSent, 0)
        XCTAssertTrue(reactions.toggles.keys.isEmpty)
    }

    func testTogglingWithoutASessionUserIsANoOp() {
        let target = Target(myUserID: nil, posts: [post(id: "p1")])
        let writer = Writer()
        let reactions = coordinator(target, writer)
        XCTAssertFalse(reactions.toggle(postID: "p1", emojiName: "smile"))
        XCTAssertEqual(reactions.requestsSent, 0)
    }

    func testTogglingADeletedPostIsANoOp() {
        let target = Target(myUserID: "me", posts: [post(id: "p1", deleteAt: 99)])
        let runner = coordinator(target, Writer())
        XCTAssertFalse(runner.toggle(postID: "p1", emojiName: "smile"))
        XCTAssertEqual(runner.requestsSent, 0)
    }

    func testASuccessfulAddRecordsTheRecent() async {
        let target = Target(myUserID: "me", posts: [post(id: "p1")])
        let writer = Writer()
        var recorded: [String] = []
        let reactions = ReactionCoordinator(
            add: { postID, emoji, userID in
                writer.added.append((postID, emoji, userID))
                return MMReaction(userId: userID, postId: postID, emojiName: emoji)
            },
            remove: { _, _, _ in },
            target: target,
            onReactionAdded: { recorded.append($0) })

        reactions.toggle(postID: "p1", emojiName: "thumbsup")
        await settle()
        XCTAssertEqual(recorded, [ReactionAliases.canonical("thumbsup", system: .shared)])
    }

    // MARK: - 4. The reactor list

    func testReactorRowsResolveNamesAndMarkTheSessionUser() {
        let reactions = [MMReaction(userId: "me", postId: "p1", emojiName: "+1"),
                         MMReaction(userId: "u2", postId: "p1", emojiName: "thumbsup")]
        let users = ["me": MMUser(id: "me", username: "reader", firstName: "Rea"),
                     "u2": MMUser(id: "u2", username: "other", firstName: "Otto")]
        let ids = ReactionReactors.userIDs(forPillEmoji: "+1",
                                           in: post(id: "p1", reactions: reactions),
                                           system: .shared)
        XCTAssertEqual(ids, ["me", "u2"], "aliases of one group are one list, in server order")

        let rows = ReactionReactors.rows(userIDs: ids, myUserID: "me", users: users)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].label, "Rea (you)")
        XCTAssertEqual(rows[0].detail, "@reader")
        XCTAssertEqual(rows[1].label, "Otto")
        XCTAssertFalse(rows[1].isMe)
    }

    func testAnUnknownReactorKeepsAnHonestPlaceholder() {
        let rows = ReactionReactors.rows(userIDs: ["ghost"], myUserID: "me", users: [:])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].label, "Unknown user")
        XCTAssertEqual(rows[0].detail, "")
    }

    func testSheetOrderAppendsNewAndDropsGone() {
        XCTAssertEqual(ReactionSheetOrder.merged(previous: ["+1", "smile"], current: ["smile", "tada"]),
                       ["smile", "tada"])
        // Nothing arrived or left: the order the reader is looking at stays.
        XCTAssertEqual(ReactionSheetOrder.merged(previous: ["smile", "+1"], current: ["+1", "smile"]),
                       ["smile", "+1"])
    }

    // MARK: - 5. Recents

    func testRecentsAreNewestFirstDedupedAndCapped() {
        var names: [String] = []
        for index in 0..<40 { names = EmojiRecentsRule.adding("e\(index)", to: names) }
        XCTAssertEqual(names.count, EmojiRecentsRule.limit)
        XCTAssertEqual(names.first, "e39")
        // 40 inserted, 27 kept: the oldest survivor is the 27th newest — e13.
        XCTAssertEqual(names.last, "e13")

        // A repeat moves the entry to the front instead of adding a second chip.
        names = EmojiRecentsRule.adding("e20", to: names)
        XCTAssertEqual(names.first, "e20")
        XCTAssertEqual(names.filter { $0 == "e20" }.count, 1)
    }

    func testRecentsArePerServerAndPerUser() {
        let a = EmojiRecentsStore.key(serverID: UUID(), userID: "u1")
        let b = EmojiRecentsStore.key(serverID: UUID(), userID: "u1")
        let c = EmojiRecentsStore.key(serverID: UUID(), userID: "u2")
        XCTAssertNotEqual(a, b, "two servers must not share a list")
        XCTAssertNotEqual(b, c, "two accounts on one server must not share a list")
    }

    func testTwoStoresForOneKeyStayInSync() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "t37.recents.\(UUID().uuidString)"))
        let key = EmojiRecentsStore.key(serverID: UUID(), userID: "me")
        let first = EmojiRecentsStore(defaults: defaults, key: key)
        first.record("smile")
        // A second store for the same key (a sheet built later) sees the write, and its own write is
        // not lost when the first one records again.
        let second = EmojiRecentsStore(defaults: defaults, key: key)
        XCTAssertEqual(second.names, ["smile"])
        second.record("tada")
        first.record("+1")
        XCTAssertEqual(defaults.stringArray(forKey: key), ["+1", "tada", "smile"])
    }

    // MARK: - 6. The picker

    private func picker(recents: EmojiRecentsStore? = nil,
                        catalogue: EmojiCatalogue? = nil,
                        mode: EmojiPickerMode = .reaction) -> EmojiPickerViewModel {
        EmojiPickerViewModel(mode: mode, catalogue: catalogue, recents: recents)
    }

    func testPickerStartsWithSystemCategoriesWhenNothingIsRecent() {
        let model = picker()
        XCTAssertFalse(model.sections.isEmpty)
        XCTAssertEqual(model.sections.first?.kind, .system)
        XCTAssertTrue(model.sections.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(model.sections.contains { $0.items.contains { $0.name == "smile" } })
    }

    func testRecentsComeFirstAndDisappearWhenEmpty() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "t37.picker.\(UUID().uuidString)"))
        let store = EmojiRecentsStore(defaults: defaults,
                                      key: EmojiRecentsStore.key(serverID: UUID(), userID: "me"))
        let model = picker(recents: store)
        XCTAssertNotEqual(model.sections.first?.kind, .recent)

        store.record("+1")
        store.record("tada")
        XCTAssertEqual(model.sections.first?.kind, .recent)
        XCTAssertEqual(model.sections.first?.items.map(\.name), ["tada", "+1"])
        // A stored name the table cannot resolve is dropped rather than drawn as a broken chip.
        store.record("not_an_emoji_anywhere")
        XCTAssertFalse(model.sections.first?.items.contains { $0.name == "not_an_emoji_anywhere" } ?? true)
    }

    func testSearchStripsColonsAndRanksPrefixMatchesFirst() {
        let model = picker()
        model.search = ":smile:"
        XCTAssertEqual(model.sections.count, 1)
        XCTAssertEqual(model.sections[0].kind, .search)
        XCTAssertEqual(model.sections[0].items.first?.name, "smile")
        XCTAssertTrue(model.sections[0].items.count > 1, "an alias search returns the whole group")
    }

    func testSearchWithNoMatchIsAnEmptySectionAndTheSheetSaysSo() {
        let model = picker()
        model.search = "zzzzzzzz"
        XCTAssertEqual(model.sections.count, 1)
        XCTAssertTrue(model.sections[0].items.isEmpty)
        XCTAssertTrue(model.isEmpty)
    }

    func testCustomEmojiGetTheirOwnSectionAndSearchResults() async {
        let catalogue = EmojiCatalogue(
            loadPage: { _, _ in [MMEmoji(id: "id1", name: "t34parrot")] },
            loadImage: { _ in throw MMError.notFound })
        await catalogue.loadNamesIfNeeded()

        let model = picker(catalogue: catalogue)
        let custom = model.sections.first { $0.kind == .custom }
        XCTAssertEqual(custom?.items.map(\.name), ["t34parrot"])
        XCTAssertEqual(custom?.items.first?.isCustom, true)

        model.search = "parrot"
        // A system emoji whose name matches ranks first; the server's own name follows it.
        XCTAssertEqual(model.sections[0].items.map(\.name), ["parrot", "t34parrot"])
        XCTAssertEqual(model.sections[0].items.last?.isCustom, true)
    }

    func testPickingRecordsTheRecentAndCallsBack() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "t37.pick.\(UUID().uuidString)"))
        let store = EmojiRecentsStore(defaults: defaults,
                                      key: EmojiRecentsStore.key(serverID: UUID(), userID: "me"))
        var picked: [EmojiPickerItem] = []
        let model = EmojiPickerViewModel(mode: .reaction, recents: store, onPick: { picked.append($0) })
        let item = try XCTUnwrap(model.item(for: "smile"))
        model.pick(item)
        XCTAssertEqual(picked.map(\.name), [item.name])
        XCTAssertEqual(store.names, [item.name])
        XCTAssertEqual(model.insertion(for: item), ":\(item.name):")
    }

    // MARK: - 7. The row's pills (derivation)

    func testAliasesOnOnePostBecomeOnePillWithTheFullCount() {
        let reactions = [MMReaction(userId: "me", postId: "p1", emojiName: "+1"),
                         MMReaction(userId: "u2", postId: "p1", emojiName: "thumbsup"),
                         MMReaction(userId: "u2", postId: "p1", emojiName: "smile")]
        let summary = PostListDerivation.reactions(for: post(id: "p1", reactions: reactions),
                                                   myUserID: "me")
        XCTAssertEqual(summary.count, 2)
        let thumbs = summary.first { $0.emojiName == ReactionAliases.canonical("+1", system: .shared) }
        XCTAssertEqual(thumbs?.count, 2)
        XCTAssertEqual(thumbs?.includesMe, true)
        XCTAssertEqual(thumbs?.userIds, ["me", "u2"])
    }

    func testPillsSortByCountThenName() {
        let reactions = [MMReaction(userId: "a", postId: "p1", emojiName: "smile"),
                         MMReaction(userId: "b", postId: "p1", emojiName: "tada"),
                         MMReaction(userId: "c", postId: "p1", emojiName: "tada")]
        let summary = PostListDerivation.reactions(for: post(id: "p1", reactions: reactions),
                                                   myUserID: nil)
        XCTAssertEqual(summary.map(\.emojiName), ["tada", "smile"])
        XCTAssertEqual(summary.map(\.count), [2, 1])
    }

    func testAPostWithoutMetadataHasNoPills() {
        XCTAssertTrue(PostListDerivation.reactions(for: MMPost(id: "p1"), myUserID: "me").isEmpty)
    }
}

// MARK: - Small helpers the suite needs

private extension ReactionToggles {
    /// Read-only view of the machine's entries (the struct exposes `toggle(_:)` per key only).
    func values() -> [ReactionToggle] {
        keys.compactMap { toggle($0) }
    }
}
