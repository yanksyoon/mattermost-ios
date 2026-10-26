// T34 — the post list's derivation rules, plus the captured server fixtures.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0,
// app/utils/post_list/index.ts (ordering, `isSameUser`/`POST_COLLAPSE_TIMEOUT`),
// app/components/post_list/post_list.tsx (date separators, new-message line placement),
// app/components/post/header (edited marker), post_body (deleted tombstone), system_message,
// app/components/reactions (grouping and sort), app/components/files (size display).
//
// Every rule is exercised through `PostListDerivation`, which takes its clock and calendar as
// arguments — so "5 minutes" and "yesterday" are exact here instead of flaky.

import XCTest
@testable import Mattermost

final class T34PostListTests: XCTestCase {

    /// 2026-10-25 10:00:00 UTC — the "now" every date rule is measured against.
    private let now = Date(timeIntervalSince1970: 1_793_000_000)
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private let locale = Locale(identifier: "en_US_POSIX")

    private func millis(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    private func minutesAgo(_ minutes: Int) -> Int64 {
        millis(now.addingTimeInterval(-Double(minutes) * 60))
    }

    private func user(_ id: String, username: String, first: String = "", last: String = "",
                      nickname: String = "") -> MMUser {
        MMUser(id: id, username: username, firstName: first, lastName: last, nickname: nickname)
    }

    private func items(_ posts: [MMPost], users: [MMUser] = [], myUserID: String? = "me",
                       lastViewedAt: Int64? = nil) -> [PostListItem] {
        PostListDerivation.items(posts: posts,
                                 users: Dictionary(uniqueKeysWithValues: users.map { ($0.id, $0) }),
                                 myUserID: myUserID,
                                 lastViewedAt: lastViewedAt,
                                 now: now,
                                 calendar: calendar,
                                 locale: locale)
    }

    // MARK: Ordering

    func testItemsAreOldestFirstEvenWhenGivenNewestFirst() {
        let posts = [
            MMPost(id: "c", createAt: minutesAgo(1), userId: "u1", channelId: "ch", message: "three"),
            MMPost(id: "a", createAt: minutesAgo(30), userId: "u1", channelId: "ch", message: "one"),
            MMPost(id: "b", createAt: minutesAgo(20), userId: "u1", channelId: "ch", message: "two")
        ]
        let list = items(posts)
        let ids = list.compactMap(\.postID)
        XCTAssertEqual(ids, ["a", "b", "c"])
    }

    func testSameMillisecondIsOrderedByIDSoRendersAreStable() {
        let posts = [
            MMPost(id: "zzz", createAt: 1_000, userId: "u1", channelId: "ch", message: "z"),
            MMPost(id: "aaa", createAt: 1_000, userId: "u1", channelId: "ch", message: "a")
        ]
        XCTAssertEqual(items(posts).compactMap(\.postID), ["aaa", "zzz"])
    }

    func testPostsWithoutAnIDAreDropped() {
        XCTAssertTrue(items([MMPost(id: "", createAt: 5, userId: "u1", channelId: "ch")]).isEmpty)
    }

    // MARK: Day separators

    func testOneSeparatorPerDayAndTheOldestDayStartsWithOne() {
        let yesterday = millis(now.addingTimeInterval(-26 * 3600))
        let posts = [
            MMPost(id: "c", createAt: minutesAgo(1), userId: "u1", channelId: "ch", message: "today"),
            MMPost(id: "b", createAt: minutesAgo(600), userId: "u1", channelId: "ch", message: "today earlier"),
            MMPost(id: "a", createAt: yesterday, userId: "u1", channelId: "ch", message: "yesterday")
        ]
        let list = items(posts)
        let separators = list.compactMap { item -> String? in
            if case .dateSeparator(let separator) = item { return separator.title }
            return nil
        }
        XCTAssertEqual(separators, ["Yesterday", "Today"])
        // The first item is a separator, not a post: a list never starts mid-day.
        guard case .dateSeparator = list[0] else { return XCTFail("list did not start with a day") }
    }

    func testDayTitlesUseTodayYesterdayThenAWeekday() {
        XCTAssertEqual(PostListDerivation.dayTitle(for: millis(now), now: now,
                                                   calendar: calendar, locale: locale), "Today")
        let yesterday = now.addingTimeInterval(-24 * 3600)
        XCTAssertEqual(PostListDerivation.dayTitle(for: millis(yesterday), now: now,
                                                   calendar: calendar, locale: locale), "Yesterday")
        // `now` is 2026-10-26 UTC (a Monday), so three days back is a Friday — the title is the
        // locale's own weekday name, which is why it is compared against the calendar, not a table.
        let threeDaysAgo = now.addingTimeInterval(-3 * 24 * 3600)
        XCTAssertEqual(PostListDerivation.dayTitle(for: millis(threeDaysAgo), now: now,
                                                   calendar: calendar, locale: locale), "Friday")
        let lastMonth = now.addingTimeInterval(-40 * 24 * 3600)
        let title = PostListDerivation.dayTitle(for: millis(lastMonth), now: now,
                                                calendar: calendar, locale: locale)
        XCTAssertTrue(title.contains("2026"), "expected a full date, got \(title)")
    }

    // MARK: Grouping

    func testSameAuthorInsideFiveMinutesIsGrouped() {
        let posts = [
            MMPost(id: "b", createAt: minutesAgo(4), userId: "u1", channelId: "ch", message: "second"),
            MMPost(id: "a", createAt: minutesAgo(6), userId: "u1", channelId: "ch", message: "first")
        ]
        let rows = items(posts).compactMap { item -> PostRowModel? in
            if case .post(let row) = item { return row }
            return nil
        }
        XCTAssertEqual(rows.count, 2)
        XCTAssertFalse(rows[0].isGrouped, "the first post of a run always shows its header")
        XCTAssertTrue(rows[1].isGrouped, "4 minutes apart by the same author should be grouped")
    }

    func testGroupingStopsAtTheWindowAuthorAndDayBoundary() {
        let posts = [
            MMPost(id: "d", createAt: minutesAgo(1), userId: "u1", channelId: "ch", message: "same author, much later"),
            MMPost(id: "c", createAt: minutesAgo(30), userId: "u2", channelId: "ch", message: "other author"),
            MMPost(id: "b", createAt: minutesAgo(88), userId: "u1", channelId: "ch", message: "2 minutes after a"),
            MMPost(id: "a", createAt: minutesAgo(90), userId: "u1", channelId: "ch", message: "first")
        ]
        let rows = items(posts).compactMap { item -> (String, Bool)? in
            if case .post(let row) = item { return (row.id, row.isGrouped) }
            return nil
        }
        XCTAssertEqual(rows.map(\.0), ["a", "b", "c", "d"])
        // a→b is 2 minutes by the same author (grouped), b→c changes author, c→d changes author and is
        // 29 minutes later (both would block grouping on their own).
        XCTAssertEqual(rows.map(\.1), [false, true, false, false])
    }

    func testGroupingStopsAtTheFiveMinuteBoundaryExactly() {
        let posts = [
            MMPost(id: "b", createAt: minutesAgo(0), userId: "u1", channelId: "ch", message: "after"),
            MMPost(id: "a", createAt: minutesAgo(0) - PostListDerivation.groupingWindow, userId: "u1",
                   channelId: "ch", message: "before")
        ]
        let rows = items(posts).compactMap { item -> PostRowModel? in
            if case .post(let row) = item { return row }
            return nil
        }
        XCTAssertFalse(rows[1].isGrouped, "exactly 5 minutes apart is no longer a run")

        let justInside = [
            MMPost(id: "b", createAt: minutesAgo(0), userId: "u1", channelId: "ch", message: "after"),
            MMPost(id: "a", createAt: minutesAgo(0) - (PostListDerivation.groupingWindow - 1),
                   userId: "u1", channelId: "ch", message: "before")
        ]
        let insideRows = items(justInside).compactMap { item -> PostRowModel? in
            if case .post(let row) = item { return row }
            return nil
        }
        XCTAssertTrue(insideRows[1].isGrouped)
    }

    func testASystemMessageNeverAbsorbsTheNextPost() {
        let posts = [
            MMPost(id: "b", createAt: minutesAgo(1), userId: "u1", channelId: "ch", message: "after system"),
            MMPost(id: "a", createAt: minutesAgo(2), userId: "u1", channelId: "ch",
                   message: "u2 added to the channel.", type: "system_add_to_channel")
        ]
        let rows = items(posts).compactMap { item -> PostRowModel? in
            if case .post(let row) = item { return row }
            return nil
        }
        XCTAssertTrue(rows[0].isSystem)
        XCTAssertFalse(rows[1].isGrouped, "a post after a system message must show its header")
    }

    // MARK: New messages

    func testUnreadDividerSitsBeforeTheFirstUnseenPostAndSkipsMyOwn() {
        let posts = [
            MMPost(id: "c", createAt: 3_000, userId: "u1", channelId: "ch", message: "unseen"),
            MMPost(id: "b", createAt: 2_000, userId: "me", channelId: "ch", message: "mine"),
            MMPost(id: "a", createAt: 1_000, userId: "u1", channelId: "ch", message: "seen")
        ]
        let list = items(posts, lastViewedAt: 1_500)
        guard let divider = list.firstIndex(where: { $0 == .newMessages }) else {
            return XCTFail("no unread divider")
        }
        XCTAssertEqual(list[divider + 1].postID, "c", "divider must precede the first unread post, not my own")
    }

    func testNoDividerWithoutLastViewedAtOrWhenEverythingIsRead() {
        let posts = [
            MMPost(id: "b", createAt: 3_000, userId: "u1", channelId: "ch", message: "unseen"),
            MMPost(id: "a", createAt: 1_000, userId: "u1", channelId: "ch", message: "seen")
        ]
        XCTAssertFalse(items(posts, lastViewedAt: nil).contains(.newMessages))
        XCTAssertFalse(items(posts, lastViewedAt: 9_000).contains(.newMessages))
    }

    func testDividerComesAfterTheDaySeparator() {
        let posts = [
            MMPost(id: "a", createAt: minutesAgo(1), userId: "u1", channelId: "ch", message: "new")
        ]
        let list = items(posts, lastViewedAt: minutesAgo(60))
        XCTAssertEqual(list.count, 3)
        guard case .dateSeparator = list[0] else { return XCTFail() }
        XCTAssertEqual(list[1], .newMessages)
        XCTAssertEqual(list[2].postID, "a")
    }

    // MARK: Flags

    func testEditedDeletedSystemAndPinnedFlags() {
        let posts = [
            MMPost(id: "d", createAt: minutesAgo(1), deleteAt: 5_000, userId: "u1", channelId: "ch",
                   message: "gone"),
            MMPost(id: "c", createAt: minutesAgo(2), editAt: 4_000, isPinned: true, userId: "u1",
                   channelId: "ch", message: "changed"),
            MMPost(id: "b", createAt: minutesAgo(3), userId: "u1", channelId: "ch", message: "joined.",
                   type: "system_join_channel"),
            MMPost(id: "a", createAt: minutesAgo(4), userId: "u1", channelId: "ch", message: "plain")
        ]
        let rows = items(posts).compactMap { item -> PostRowModel? in
            if case .post(let row) = item { return row }
            return nil
        }
        XCTAssertFalse(rows[0].isEdited)
        XCTAssertTrue(rows[0].isPinned == false)
        XCTAssertTrue(rows[1].isSystem)
        XCTAssertTrue(rows[1].blocks.isEmpty, "a system message is one line, not markdown")
        XCTAssertTrue(rows[2].isEdited)
        XCTAssertTrue(rows[2].isPinned)
        XCTAssertTrue(rows[3].isDeleted)
        XCTAssertTrue(rows[3].blocks.isEmpty)
        XCTAssertEqual(rows[3].accessibleText, "This message was deleted.")
    }

    // MARK: Reactions

    func testReactionsGroupSortAndMarkMine() throws {
        let reactions = """
        [{"user_id":"u1","post_id":"p","emoji_name":"tada","create_at":1},
         {"user_id":"u2","post_id":"p","emoji_name":"tada","create_at":2},
         {"user_id":"me","post_id":"p","emoji_name":"thumbsup","create_at":3}]
        """
        let metadata = try JSONDecoder().decode(JSONValue.self,
                                                from: Data("{\"reactions\":\(reactions)}".utf8))
        let post = MMPost(id: "p", createAt: minutesAgo(1), userId: "u1", channelId: "ch",
                          message: "react to me", metadata: metadata)
        let row = PostListDerivation.row(post: post, users: [:], myUserID: "me", grouped: false)
        // T37: `thumbsup` and `+1` are one alias group, and the pill carries the canonical spelling
        // (upstream `getEmojiFirstAlias`), so the row shows "+1" — not the spelling the server stored.
        XCTAssertEqual(row.reactions.map(\.emojiName), ["tada", "+1"], "most-reacted first")
        XCTAssertEqual(row.reactions[0].count, 2)
        XCTAssertFalse(row.reactions[0].includesMe)
        XCTAssertTrue(row.reactions[1].includesMe)
    }

    func testPostWithoutReactionMetadataHasNoSummaries() {
        let post = MMPost(id: "p", createAt: 1, userId: "u1", channelId: "ch", message: "hi")
        XCTAssertTrue(PostListDerivation.reactions(for: post, myUserID: "me").isEmpty)
    }

    // MARK: Attachments

    func testAttachmentsComeFromMetadataFiles() throws {
        let metadata = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"files":[{"id":"f1","post_id":"p","name":"shot.png","mime_type":"image/png","size":2048},
                  {"id":"f2","post_id":"p","name":"notes.txt","mime_type":"text/plain","size":5}]}
        """.utf8))
        let post = MMPost(id: "p", createAt: 1, userId: "u1", channelId: "ch", message: "",
                          metadata: metadata)
        let attachments = PostListDerivation.attachments(for: post)
        XCTAssertEqual(attachments.map(\.id), ["f1", "f2"])
        XCTAssertEqual(attachments[0].kind, .image)
        XCTAssertTrue(attachments[0].hasThumbnail)
        XCTAssertEqual(attachments[0].sizeLabel, "2.0 KB")
        XCTAssertEqual(attachments[1].kind, .file)
        XCTAssertFalse(attachments[1].hasThumbnail)
    }

    func testAttachmentsFallBackToFileIDsWhenMetadataIsMissing() {
        let post = MMPost(id: "p", createAt: 1, userId: "u1", channelId: "ch", message: "",
                          fileIds: ["f1"])
        let attachments = PostListDerivation.attachments(for: post)
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments[0].id, "f1")
        XCTAssertEqual(attachments[0].kind, .file)
    }

    func testSizeLabels() {
        XCTAssertEqual(PostAttachment(id: "a", name: "a", mimeType: "", sizeBytes: 812,
                                      kind: .file, isBlocked: false, hasThumbnail: false).sizeLabel,
                       "812 B")
        XCTAssertEqual(PostAttachment(id: "a", name: "a", mimeType: "", sizeBytes: 81_379,
                                      kind: .file, isBlocked: false, hasThumbnail: false).sizeLabel,
                       "79.5 KB")
        XCTAssertEqual(PostAttachment(id: "a", name: "a", mimeType: "", sizeBytes: 0,
                                      kind: .file, isBlocked: false, hasThumbnail: false).sizeLabel,
                       "")
    }

    // MARK: Folding

    func testALongPostIsFoldedAndCanBeExpanded() throws {
        let message = (1...40).map { "paragraph \($0)" }.joined(separator: "\n\n")
        let post = MMPost(id: "p", createAt: 1, userId: "u1", channelId: "ch", message: message)
        let row = PostListDerivation.row(post: post, users: [:], myUserID: "me", grouped: false)
        XCTAssertNotNil(try XCTUnwrap(row.fold))
        XCTAssertEqual(row.blocksToShow.count, PostListDerivation.foldedBlockCount)
        XCTAssertEqual(row.blocksToShow.count, 6)
        XCTAssertEqual(row.foldSummary, "… 34 more blocks")
        XCTAssertFalse(row.showsAllBlocks(expanded: false))
        XCTAssertTrue(row.showsAllBlocks(expanded: true))

        let expanded = PostListDerivation.row(post: post,
                                              users: [:],
                                              myUserID: "me",
                                              grouped: false,
                                              expanded: true)
        XCTAssertNil(expanded.fold)
        XCTAssertEqual(expanded.blocksToShow.count, expanded.blocks.count)
        XCTAssertEqual(expanded.foldSummary, "")
    }

    func testAShortPostIsNotFolded() {
        let post = MMPost(id: "p", createAt: 1, userId: "u1", channelId: "ch",
                          message: "just one line")
        let row = PostListDerivation.row(post: post, users: [:], myUserID: "me", grouped: false)
        XCTAssertNil(row.fold)
    }

    /// T34 review F6: the fold rule used to return "1 block" for a post that is one block, so a
    /// pasted 40 000-character paragraph rendered in full and "Show more" did nothing. The block is
    /// now capped from the inside.
    func testAOneParagraphPostIsFoldedInsideTheParagraph() throws {
        let message = String(repeating: "the quick brown fox jumps over the lazy dog. ", count: 900)
        XCTAssertGreaterThan(message.count, 40_000)
        let post = MMPost(id: "p", createAt: 1, userId: "u1", channelId: "ch", message: message)
        let row = PostListDerivation.row(post: post, users: [:], myUserID: "me", grouped: false)

        let fold = try XCTUnwrap(row.fold, "a 40k-character paragraph must be folded")
        XCTAssertEqual(row.blocks.count, 1, "the paragraph is a single markdown block")
        let shown = try XCTUnwrap(fold.visibleBlocks.first?.plainText)
        XCTAssertLessThanOrEqual(shown.count, MarkdownFold.characterLimit + 1,   // the ellipsis
                                 "the folded paragraph is still \(shown.count) characters")
        XCTAssertLessThan(shown.count, message.count)
        XCTAssertTrue(fold.hiddenSummary.contains("more characters"), fold.hiddenSummary)
        // The affordance must be worth tapping: the hidden amount is real, not a rounding artefact.
        XCTAssertTrue(fold.hiddenSummary.contains(","), fold.hiddenSummary)
    }

    func testAOneFencePostIsFoldedInsideTheFence() throws {
        let lines = (1...5_000).map { "line \($0) of a pasted log" }
        let message = "```\n" + lines.joined(separator: "\n") + "\n```"
        let post = MMPost(id: "p", createAt: 1, userId: "u1", channelId: "ch", message: message)
        let row = PostListDerivation.row(post: post, users: [:], myUserID: "me", grouped: false)

        let fold = try XCTUnwrap(row.fold, "a 5 000-line fence must be folded")
        XCTAssertEqual(row.blocks.count, 1)
        guard case .codeBlock(let language, let code) = try XCTUnwrap(fold.visibleBlocks.first) else {
            return XCTFail("the folded block is not a code block: \(fold.visibleBlocks)")
        }
        XCTAssertNil(language)
        let keptLines = code.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertLessThanOrEqual(keptLines.count, MarkdownFold.lineLimit + 1)   // the "…" line
        XCTAssertEqual(fold.hiddenSummary, "… 4,980 more lines")
    }

    func testATableWithHundredsOfRowsIsFolded() throws {
        var message = "| a | b |\n|---|---|\n"
        message += (1...300).map { "| row \($0) | value \($0) |" }.joined(separator: "\n")
        let post = MMPost(id: "p", createAt: 1, userId: "u1", channelId: "ch", message: message)
        let row = PostListDerivation.row(post: post, users: [:], myUserID: "me", grouped: false)

        let fold = try XCTUnwrap(row.fold)
        guard case .table(let header, let rows) = try XCTUnwrap(fold.visibleBlocks.first) else {
            return XCTFail("the folded block is not a table: \(fold.visibleBlocks)")
        }
        XCTAssertEqual(header.count, 2)
        XCTAssertEqual(rows.count, MarkdownFold.tableRowLimit)
        XCTAssertEqual(fold.hiddenSummary, "… 295 more rows")
    }

    /// A post over the length threshold whose content already fits must not grow a no-op affordance.
    func testALengthyButShortPostIsNotFolded() {
        let blocks = (1...3).map { "paragraph \($0) " + String(repeating: "x", count: 900) }
        let post = MMPost(id: "p", createAt: 1, userId: "u1", channelId: "ch",
                          message: blocks.joined(separator: "\n\n"))
        let row = PostListDerivation.row(post: post, users: [:], myUserID: "me", grouped: false)
        XCTAssertNil(row.fold, "nothing would be hidden, so there must be no Show more")
    }

    func testFoldKeepsEmphasisInsideTheKeptText() throws {
        // 40 short paragraphs, the 6th of which carries bold text: the fold must keep the runs it
        // draws exactly as the parser produced them (no flattening, no colour loss).
        var message = (1...5).map { "paragraph \($0)" }.joined(separator: "\n\n")
        message += "\n\n**bold six** and plain"
        message += "\n\n" + (7...40).map { "paragraph \($0)" }.joined(separator: "\n\n")
        let post = MMPost(id: "p", createAt: 1, userId: "u1", channelId: "ch", message: message)
        let row = PostListDerivation.row(post: post, users: [:], myUserID: "me", grouped: false)
        let fold = try XCTUnwrap(row.fold)
        XCTAssertEqual(fold.visibleBlocks, Array(row.blocks.prefix(6)))
        let keptBold = [fold.visibleBlocks[5]].allInlines.contains { run in
            if case .bold = run { return true }
            return false
        }
        XCTAssertTrue(keptBold, "the kept block lost its bold run: \(fold.visibleBlocks[5])")
    }

    func testGroupedNumbersReadTheSameInEveryLocale() {
        XCTAssertEqual(MarkdownFold.number(0), "0")
        XCTAssertEqual(MarkdownFold.number(999), "999")
        XCTAssertEqual(MarkdownFold.number(1_000), "1,000")
        XCTAssertEqual(MarkdownFold.number(4_980), "4,980")
        XCTAssertEqual(MarkdownFold.number(1_234_567), "1,234,567")
    }

    // MARK: Authors

    func testDisplayNamePrefersNicknameThenFullNameThenUsername() {
        XCTAssertEqual(PostListDerivation.displayName(
            for: user("1", username: "ada", first: "Ada", last: "Lovelace", nickname: "Ada L")), "Ada L")
        XCTAssertEqual(PostListDerivation.displayName(
            for: user("1", username: "ada", first: "Ada", last: "Lovelace")), "Ada Lovelace")
        XCTAssertEqual(PostListDerivation.displayName(for: user("1", username: "ada")), "ada")
    }

    func testInitialsAndHueAreStable() {
        let ada = PostAuthor(id: "uid-1", username: "ada", displayName: "Ada Lovelace")
        XCTAssertEqual(ada.initials, "AL")
        XCTAssertEqual(PostAuthor(id: "uid-2", username: "opsbot", displayName: "opsbot").initials, "OP")
        XCTAssertEqual(ada.avatarHue, PostAuthor(id: "uid-1", username: "ada", displayName: "Ada Lovelace").avatarHue)
        XCTAssertTrue((0..<1.0).contains(ada.avatarHue))
    }

    func testUnknownAuthorFallsBackToTheUsernameThePostCarries() throws {
        let props = try JSONDecoder().decode(JSONValue.self,
                                             from: Data("{\"username\":\"opsbot\"}".utf8))
        let post = MMPost(id: "p", createAt: 1, userId: "u9", channelId: "ch",
                          message: "joined.", type: "system_join_channel", props: props)
        let author = PostListDerivation.author(for: post, users: [:])
        XCTAssertEqual(author.username, "opsbot")
        XCTAssertEqual(author.displayName, "opsbot")
    }

    func testUnknownAuthorWithNoPropsSaysUnknown() {
        let post = MMPost(id: "p", createAt: 1, userId: "u9", channelId: "ch", message: "?")
        XCTAssertEqual(PostListDerivation.author(for: post, users: [:]).displayName, "Unknown user")
    }
}

// MARK: - Captured server fixtures

/// The same rules, run against real payloads captured from a running Mattermost server
/// (`scripts/t34_capture_fixture.py`). This is what makes the tests evidence rather than a
/// restatement of the code: the shapes are the server's, including the fields this client ignores.
final class T34FixtureTests: XCTestCase {

    struct Fixture: Decodable {
        struct Channel: Decodable {
            let id: String
            let name: String
            let displayName: String
            let type: String
        }
        /// One custom emoji as `GET /emoji` answered it (only the fields the client uses).
        struct CapturedEmoji: Decodable {
            let id: String
            let name: String
            let deleteAt: Int64

            enum CodingKeys: String, CodingKey {
                case id, name
                case deleteAt = "delete_at"
            }
        }
        let channel: Channel
        let users: [String: MMUser]
        let order: [String]
        let posts: [String: MMPost]
        let perPage: Int
        let pageSizes: [Int]
        /// The query parameter the capture was taken with (`collapsedThreads=true` since T34-R5, the
        /// same request the app makes). Optional so an older capture still decodes.
        let collapsedThreads: Bool?
        /// Present on the showcase capture; `nil` when the server had no custom emoji.
        let emoji: [CapturedEmoji]?

        var orderedPosts: [MMPost] { order.compactMap { posts[$0] } }
    }

    private func fixture(_ name: String) throws -> Fixture {
        let data = try T34FixtureLoader.data(named: name)
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    func testShowcaseFixtureCoversEveryRenderingState() throws {
        let fixture = try fixture("t34-showcase-posts")
        XCTAssertGreaterThanOrEqual(fixture.order.count, 10,
                                    "the capture must contain the seeded cases")
        let items = PostListDerivation.items(posts: fixture.orderedPosts,
                                             users: fixture.users,
                                             myUserID: "jruqqzxtobg7tn4wehwmwjjo5c",
                                             lastViewedAt: nil,
                                             now: Date(),
                                             calendar: .current,
                                             locale: Locale(identifier: "en_US_POSIX"))
        let rows = items.compactMap { item -> PostRowModel? in
            if case .post(let row) = item { return row }
            return nil
        }
        XCTAssertEqual(rows.count, fixture.order.count)

        // The system messages are system rows, with their text intact and no markdown parse.
        XCTAssertEqual(rows.filter(\.isSystem).count, 2)
        XCTAssertTrue(rows.allSatisfy { !$0.isSystem || $0.blocks.isEmpty })

        // The seeded edit marker is read from `edit_at`, not guessed from the body.
        XCTAssertEqual(rows.filter(\.isEdited).count, 1)

        // The attachment post exposes a real file with the server's own name and size.
        let attachmentRow = try XCTUnwrap(rows.first { !$0.attachments.isEmpty })
        XCTAssertEqual(attachmentRow.attachments.first?.name, "t34-thumbnail.png")
        XCTAssertEqual(attachmentRow.attachments.first?.kind, .image)
        XCTAssertEqual(attachmentRow.attachments.first?.sizeBytes, 81_379)

        // The blockquote post parses into a quote containing a list, and the table into a table.
        let quoteRow = try XCTUnwrap(rows.first { $0.post.props?["t34_key"]?.stringValue == "quote" })
        guard case .blockQuote = quoteRow.blocks[0] else {
            return XCTFail("quote post did not parse as a block quote: \(quoteRow.blocks)")
        }
        XCTAssertTrue(quoteRow.blocks.contains { if case .list = $0 { return true }; return false })

        let tableRow = try XCTUnwrap(rows.first { $0.post.props?["t34_key"]?.stringValue == "table" })
        XCTAssertTrue(tableRow.blocks.contains { if case .table = $0 { return true }; return false })

        // Both fenced blocks keep their language, which is what the highlighter needs.
        let languages = rows.flatMap { row in
            row.blocks.compactMap { block -> String? in
                if case .codeBlock(let language, _) = block { return language }
                return nil
            }
        }
        XCTAssertEqual(Set(languages), ["json", "swift"])

        // Reactions arrive on the channel-posts payload and are grouped per emoji (T37: per *alias
        // group*, under the canonical spelling).
        let inlineRow = try XCTUnwrap(rows.first { $0.post.props?["t34_key"]?.stringValue == "inline" })
        XCTAssertEqual(inlineRow.reactions.map(\.emojiName), ["tada", "+1"])
        XCTAssertEqual(inlineRow.reactions[0].count, 2)
        XCTAssertEqual(inlineRow.reactions[0].userIds.count, 2)

        // Only the 40-paragraph "long" post is folded here; the two single-block posts that T34 review
        // F6 was about live in their own channel (`t34-fold`) and are covered by the fold tests above
        // plus the UI test that opens that channel.
        XCTAssertEqual(rows.filter { $0.fold != nil }.count, 1)
    }

    /// The server's own custom-emoji answer resolves the shortcode the showcase post carries.
    ///
    /// Captured, not invented: the id comes from the emoji this server created for the fixture, so a
    /// wrong endpoint (`/emoji` vs `/emoji/{id}/image`), a wrong name field or a case-sensitivity bug
    /// fails here rather than in a screenshot nobody compares.
    @MainActor
    func testTheCapturedServerEmojiResolveTheShowcaseShortcode() async throws {
        let fixture = try fixture("t34-showcase-posts")
        let captured = try XCTUnwrap(fixture.emoji, "the showcase capture must carry GET /emoji")
        let parrot = try XCTUnwrap(captured.first { $0.name == "t34parrot" },
                                   "the seeded :t34parrot: is missing from the capture")

        var requested: [String] = []
        let catalogue = EmojiCatalogue(loadPage: { page, _ in
                                            page == 0
                                                ? captured.map { MMEmoji(id: $0.id, name: $0.name,
                                                                         deleteAt: $0.deleteAt) }
                                                : []
                                        },
                                        loadImage: { emojiID in
                                            requested.append(emojiID)
                                            return Data([0x89, 0x50, 0x4E, 0x47])
                                        })
        await catalogue.loadNamesIfNeeded()
        XCTAssertTrue(catalogue.isCustom("t34parrot"))

        // The showcase post's inline runs contain the shortcode, and the renderer would split on it.
        let row = try XCTUnwrap(PostListDerivation.items(posts: fixture.orderedPosts,
                                                         users: fixture.users,
                                                         myUserID: nil,
                                                         lastViewedAt: nil,
                                                         now: Date(),
                                                         calendar: .current,
                                                         locale: Locale(identifier: "en_US_POSIX"))
            .compactMap { item -> PostRowModel? in
                if case .post(let row) = item,
                   row.post.props?["t34_key"]?.stringValue == "custom-emoji" { return row }
                return nil
            }.first)
        let names = EmojiCatalogue.customNames(in: row.blocks.allInlines, catalogue: catalogue)
        XCTAssertEqual(names, ["t34parrot"])
        let segments = MarkdownText.segments(row.blocks.allInlines, custom: Set(names))
        XCTAssertTrue(segments.contains(.emojiImage("t34parrot")) || segments.contains { segment in
            if case .emojiImage("t34parrot") = segment { return true }
            return false
        }, "the shortcode must become an image segment: \(segments)")
        _ = await catalogue.image(for: "t34parrot")
        XCTAssertEqual(requested, [parrot.id], "the image is fetched by the server's emoji id")
    }

    func testShowcaseAuthorsResolveToRealProfiles() throws {
        let fixture = try fixture("t34-showcase-posts")
        let rows = PostListDerivation.items(posts: fixture.orderedPosts,
                                            users: fixture.users,
                                            myUserID: nil,
                                            lastViewedAt: nil,
                                            now: Date(),
                                            calendar: .current,
                                            locale: Locale(identifier: "en_US_POSIX"))
            .compactMap { item -> PostRowModel? in
                if case .post(let row) = item { return row }
                return nil
            }
        // `perfprobe` has a first/last name on the server, so the display name is "Perf Probe".
        XCTAssertTrue(rows.contains { $0.author.username == "perfprobe" && $0.author.displayName == "Perf Probe" })
        // `opsbot` has none, so it falls back to the username.
        XCTAssertTrue(rows.contains { $0.author.username == "opsbot" && $0.author.displayName == "opsbot" })
        // Nothing resolved to the placeholder.
        XCTAssertFalse(rows.contains { $0.author.displayName == "Unknown user" })
    }

    /// The long channel, paged by the **real pager**: `ChannelViewModel.loadEarlier()` three times over
    /// the fixture's own `before` boundaries (100/100/15), asserting the exact id sequence, the absence
    /// of duplicates at every boundary and the `hasMore` transitions.
    ///
    /// This is deliberately not a merge re-implemented in the test body (T34 review F8): the rule
    /// under test is the view model's cursor + dedupe + ordering, so the test has to drive it.
    ///
    /// The fixture is the page the **app** asks for: captured with `collapsedThreads=true`, so it holds
    /// top-level posts only (215 of them, T34-AV-F1). Before T34-R5 it was the same request with the
    /// filter dropped (503 entries, 288 of them replies) and this test proved the window equalled that
    /// sequence — i.e. it entrenched replies-as-rows instead of catching them.
    @MainActor
    func testPagingTheLongChannelThroughTheRealPagerReproducesTheCapturedSequence() async throws {
        let fixture = try fixture("t34-perf-feed-posts")
        XCTAssertEqual(fixture.collapsedThreads, true,
                       "the capture must be the request the app makes (thread-collapsed page)")
        XCTAssertTrue(fixture.orderedPosts.allSatisfy { $0.rootId.isEmpty },
                      "a thread-collapsed page holds no reply")
        XCTAssertEqual(fixture.pageSizes.count, 3, "the capture crossed two real boundaries")
        XCTAssertEqual(fixture.perPage, 100)
        XCTAssertEqual(Array(fixture.pageSizes.dropLast()), Array(repeating: 100, count: 2))
        XCTAssertLessThan(fixture.pageSizes.last ?? 0, 100, "the last page is short, so hasMore stops")

        let service = FixturePageService(fixture: fixture)
        let model = ChannelViewModel(channelID: fixture.channel.id,
                                     channelName: fixture.channel.name,
                                     service: service,
                                     myUserID: nil,
                                     now: { Date() },
                                     calendar: .current,
                                     locale: Locale(identifier: "en_US_POSIX"))
        await model.load()

        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.loadedCount, fixture.pageSizes[0],
                       "the first page is the server's first page")
        XCTAssertEqual(model.loadedPostIDs, Array(fixture.order.prefix(fixture.pageSizes[0])))
        XCTAssertTrue(model.hasMore)

        // The remaining pages, one `loadEarlier` each.
        var loads = 0
        while model.hasMore {
            let grew = await model.loadEarlier()
            loads += 1
            XCTAssertTrue(grew, "loadEarlier must merge page \(loads)")
            XCTAssertLessThanOrEqual(loads, fixture.pageSizes.count,
                                     "the pager must stop when the server runs out")
            XCTAssertEqual(model.loadedPostIDs, Array(fixture.order.prefix(model.loadedCount)),
                           "page \(loads) broke the captured sequence")
            XCTAssertEqual(Set(model.loadedPostIDs).count, model.loadedCount,
                           "page \(loads) produced a duplicate")
            if loads < fixture.pageSizes.count - 1 {
                XCTAssertTrue(model.hasMore, "page \(loads) should not be the last one")
            }
        }

        XCTAssertEqual(loads, fixture.pageSizes.count - 1, "one page was the first, the rest are older")
        XCTAssertEqual(model.loadedCount, fixture.order.count)
        XCTAssertEqual(model.loadedPostIDs, fixture.order, "every captured post, in the server's order")
        XCTAssertEqual(Set(model.loadedPostIDs).count, fixture.order.count)
        XCTAssertFalse(model.hasMore)
        XCTAssertNil(model.loadEarlierError)

        // The cursors are the ids the pagination contract names: the oldest post of the page just read.
        var expectedCursors: [String?] = [nil]
        var boundary = 0
        for size in fixture.pageSizes.dropLast() {
            boundary += size
            expectedCursors.append(fixture.order[boundary - 1])
        }
        XCTAssertEqual(service.requestedCursors, expectedCursors)

        // And the derived list is oldest-first with exactly the days the server's timestamps name.
        let items = PostListDerivation.items(posts: model.loadedPostIDs.compactMap { model.post(id: $0) },
                                             users: fixture.users,
                                             myUserID: nil,
                                             lastViewedAt: nil,
                                             now: Date(),
                                             calendar: .current,
                                             locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertEqual(items.compactMap(\.postID), fixture.order.reversed())
        XCTAssertFalse(items.isEmpty)
        XCTAssertTrue(items.contains { if case .dateSeparator = $0 { return true }; return false })
    }
}

/// A `ChannelServing` that answers from a captured channel page exactly as the server does: the
/// `before` cursor is exclusive, pages are `perPage` long, and the last one is short.
@MainActor
final class FixturePageService: ChannelServing {
    let pageSize: Int
    private let order: [String]
    private let posts: [String: MMPost]
    private let usersByID: [String: MMUser]
    private let channel: T34FixtureTests.Fixture.Channel

    private(set) var requestedCursors: [String?] = []

    init(fixture: T34FixtureTests.Fixture) {
        self.pageSize = fixture.perPage
        self.order = fixture.order
        self.posts = fixture.posts
        self.usersByID = fixture.users
        self.channel = fixture.channel
    }

    func channel(id: String) async throws -> MMChannel {
        MMChannel(id: channel.id, name: channel.name, displayName: channel.displayName,
                  type: channel.type, teamId: "")
    }

    func posts(channelID: String, before: String?, perPage: Int) async throws -> MMPostList {
        requestedCursors.append(before)
        let start: Int
        if let before {
            guard let index = order.firstIndex(of: before) else {
                return MMPostList(order: [], posts: [:], hasNext: false)
            }
            start = index + 1
        } else {
            start = 0
        }
        guard start < order.count else {
            return MMPostList(order: [], posts: [:], hasNext: false)
        }
        let end = min(order.count, start + perPage)
        let slice = Array(order[start..<end])
        var map: [String: MMPost] = [:]
        for id in slice {
            if let post = posts[id] { map[id] = post }
        }
        return MMPostList(order: slice, posts: map)
    }

    func users(ids: [String]) async throws -> [MMUser] {
        ids.compactMap { usersByID[$0] }
    }

    func fileData(fileID: String, preferThumbnail: Bool) async throws -> Data {
        throw MMError.notFound
    }
}

/// Loads the captured JSON from the test bundle, falling back to the source tree so the test also
/// runs when the fixture is not a bundle resource (a synchronized project group copies Swift files,
/// not necessarily arbitrary JSON).
enum T34FixtureLoader {
    private final class BundleToken {}

    static func data(named name: String) throws -> Data {
        if let url = Bundle(for: BundleToken.self).url(forResource: name, withExtension: "json") {
            return try Data(contentsOf: url)
        }
        let sourceTree = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).json")
        return try Data(contentsOf: sourceTree)
    }
}
