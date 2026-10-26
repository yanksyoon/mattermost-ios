// T39 — the rules behind the search, saved and pinned screens, with no network and no clock.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0, `app/utils/markdown/index.ts`
// (`parseSearchTerms` / `convertSearchTermToRegex`), `app/screens/home/search/` (composition,
// results, recent searches), `app/actions/local/team.ts` (`MAX_TEAM_SEARCHES = 15`),
// `app/screens/saved_posts/` and `app/screens/pinned_messages/` (the two lists).
//
// The service is faked at the `SearchServing` seam, so every assertion here is about a *rule*: which
// query string is composed and sent, what an invalid query says, which characters are highlighted, how
// a page merges, and whether an unpin removes the row without a refetch.
//
// The measured server facts these rules are built on live in the source files' headers
// (SearchGrammar/SearchResults/SearchAPI) and are re-measured by `scripts/t39_search_probe.py`
// against the pinned 9.11.19 server (saved/pinned paths and the pin/unpin/flag writes included).

import XCTest
import SwiftUI
@testable import Mattermost

@MainActor
final class T39SearchTests: XCTestCase {

    private let channelID = "chan0000000000000000000001"
    private let teamID = "team0000000000000000000001"

    // MARK: - Fakes

    @MainActor
    final class FakeSearchService: SearchServing {
        var pageSize: Int = 60
        /// Answers to `search`, consumed in order; the last one repeats.
        var searchPages: [MMSearchResults] = []
        var searchFailure: Error?
        var savedList = MMPostList()
        var savedFailure: Error?
        var pinnedList = MMPostList()
        var pinnedFailure: Error?
        var usersByID: [String: MMUser] = [:]
        var channelsByID: [String: MMChannel] = [:]
        var singlePost: MMPost?
        var singlePostFailure: Error?

        private(set) var searchBodies: [SearchQuery.Body] = []
        private(set) var searchTeams: [String] = []
        private(set) var savedFetchCount = 0
        private(set) var pinnedFetchCount = 0
        private(set) var savedWrites: [(postID: String, saved: Bool)] = []
        private(set) var pinWrites: [(postID: String, pinned: Bool)] = []
        private(set) var singlePostFetches: [String] = []
        private var served = 0

        func search(teamID: String, body: SearchQuery.Body) async throws -> MMSearchResults {
            searchTeams.append(teamID)
            searchBodies.append(body)
            if let searchFailure { throw searchFailure }
            let slot = min(served, max(0, searchPages.count - 1))
            served += 1
            return searchPages.isEmpty ? MMSearchResults() : searchPages[slot]
        }

        func savedPosts(teamID: String?, page: Int, perPage: Int) async throws -> MMPostList {
            savedFetchCount += 1
            if let savedFailure { throw savedFailure }
            return savedList
        }

        func pinnedPosts(channelID: String, page: Int, perPage: Int) async throws -> MMPostList {
            pinnedFetchCount += 1
            if let pinnedFailure { throw pinnedFailure }
            return pinnedList
        }

        func post(id: String) async throws -> MMPost {
            singlePostFetches.append(id)
            if let singlePostFailure { throw singlePostFailure }
            guard let singlePost else { throw MMError.notFound }
            return singlePost
        }

        func users(ids: [String]) async throws -> [MMUser] {
            ids.compactMap { usersByID[$0] }
        }

        func channels(ids: [String], teamID: String) async throws -> [MMChannel] {
            ids.compactMap { channelsByID[$0] }
        }

        func setSaved(postID: String, saved: Bool, userID: String) async throws {
            savedWrites.append((postID, saved))
        }

        func setPinned(postID: String, pinned: Bool) async throws {
            pinWrites.append((postID, pinned))
        }
    }

    final class FakeRecentStore: RecentSearchStoring {
        var storage: [String: [String]] = [:]
        private(set) var saves = 0
        func load(key: String) -> [String] { storage[key] ?? [] }
        func save(_ entries: [String], key: String) {
            saves += 1
            storage[key] = entries
        }
    }

    // MARK: - Fixtures

    private func post(_ id: String, at millis: Int64 = 1_790_000_000_000,
                      user: String = "u1", channel: String? = nil,
                      message: String = "message") -> MMPost {
        MMPost(id: id, createAt: millis, userId: user, channelId: channel ?? channelID,
               message: message)
    }

    private func searchAnswer(_ posts: [MMPost], hasNext: Bool? = nil,
                              matches: [String: [String]]? = nil) -> MMSearchResults {
        MMSearchResults(order: posts.map(\.id),
                        posts: Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) }),
                        matches: matches,
                        hasNext: hasNext)
    }

    private func recentStore() -> RecentSearchesStore {
        RecentSearchesStore(store: FakeRecentStore(), key: "s.\(teamID)")
    }

    private func searchModel(_ service: FakeSearchService,
                             recents: RecentSearchesStore? = nil) -> SearchViewModel {
        SearchViewModel(service: service,
                        recents: recents ?? recentStore(),
                        myUserID: "me")
    }

    // MARK: - 1. The documented modifiers: composition and encoding

    /// Each documented modifier is parsed, kept with its value, and lands in `terms` exactly as typed —
    /// the server parses this string, so the client's only job is to not corrupt it.
    func testEachDocumentedModifierIsParsedComposedAndSentVerbatim() {
        let cases: [(input: String, kind: SearchModifierKind, value: String)] = [
            ("deploy from:alice", .from, "alice"),
            ("deploy in:town-square", .inChannel, "town-square"),
            ("deploy before:2026-01-31", .before, "2026-01-31"),
            ("deploy after:2026-01-31", .after, "2026-01-31"),
            ("deploy on:2026-01-31", .on, "2026-01-31")
        ]
        for testCase in cases {
            let parsed = SearchQueryParser.parse(testCase.input)
            XCTAssertTrue(parsed.issues.isEmpty, "\(testCase.input): \(parsed.issues)")
            XCTAssertEqual(parsed.modifiers.count, 1, testCase.input)
            XCTAssertEqual(parsed.modifiers.first?.kind, testCase.kind, testCase.input)
            XCTAssertEqual(parsed.modifiers.first?.value, testCase.value, testCase.input)
            XCTAssertEqual(parsed.modifiers.first?.composed,
                           testCase.kind.token + testCase.value, testCase.input)
            // What is *encoded* is the normalised query, which for a well-formed query is the input.
            XCTAssertEqual(SearchQuery.compose(from: testCase.input).terms, testCase.input)
        }
    }

    /// The request body the endpoint actually receives, key by key (snake_case names included).
    ///
    /// `time_zone_offset` is **seconds east of UTC**, which is what the server reads: Go's
    /// `time.FixedZone(name, offset)` takes seconds (`server/public/model/utils.go`,
    /// `GetStartOfDayMillis`), and both reference clients send `utcOffset() * 60`. The assertion is a
    /// real UTC-7 offset (-25200), not the -420 a minutes-encoding would produce: the two are
    /// different numbers *and* different days for a PDT reader (T39 shipped minutes; measured —
    /// `in:t34-showcase on:2026-10-26` answered 3 posts at -420 and 1 at -25200 on 9.11.19).
    func testTheRequestBodyCarriesEveryDocumentedField() throws {
        let query = SearchQuery.compose(from: "deploy from:alice in:town-square before:2026-01-31",
                                        timeZoneOffsetSeconds: -7 * 60 * 60)
        let body = query.body(page: 2, perPage: 30)
        let data = try JSONEncoder().encode(body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["terms"] as? String,
                       "deploy from:alice in:town-square before:2026-01-31")
        XCTAssertEqual(json["is_or_search"] as? Bool, false)
        XCTAssertEqual(json["time_zone_offset"] as? Int, -25200,
                       "seconds east of UTC — -420 would be the minutes encoding the server reads as "
                       + "7 minutes west, i.e. a UTC day for every `on:`")
        XCTAssertEqual(json["page"] as? Int, 2)
        XCTAssertEqual(json["per_page"] as? Int, 30)
        XCTAssertEqual(json["include_deleted_channels"] as? Bool, true)
    }

    /// The default is the device's own offset **in seconds**, so a screen that forgets to pass one
    /// still sends the unit the server reads.
    func testTheComposedQueryDefaultsToTheDevicesOffsetInSeconds() {
        let zone = TimeZone.current
        XCTAssertEqual(SearchQuery.compose(from: "deploy").timeZoneOffsetSeconds,
                       zone.secondsFromGMT())
        XCTAssertEqual(SearchQuery.compose(from: "deploy").body().timeZoneOffset,
                       zone.secondsFromGMT())
    }

    /// Quotes: a phrase stays one phrase, and the curly quotes a phone keyboard types become the
    /// straight ones the server's grammar uses (upstream's `getSearchParams`).
    func testQuotedPhrasesArePreservedAndSmartQuotesAreNormalised() {
        let parsed = SearchQueryParser.parse("\u{201C}release notes\u{201D} from:alice")
        XCTAssertTrue(parsed.issues.isEmpty, "\(parsed.issues)")
        XCTAssertEqual(parsed.phrases, ["release notes"])
        XCTAssertEqual(parsed.terms, "\"release notes\" from:alice",
                       "curly quotes are straightened, the phrase is otherwise untouched")
        XCTAssertEqual(parsed.modifiers.first?.kind, .from)

        // Internal whitespace inside a phrase is the phrase: it must not be collapsed away.
        XCTAssertEqual(SearchQuery.normalize("  \"two   spaces\"   here  "), "\"two   spaces\" here")
        // …and outside it, a run of spaces is one separator.
        XCTAssertEqual(SearchQuery.normalize("a    b\tc"), "a b c")
    }

    /// Wildcards: only a trailing `*` is a wildcard (docs: `*each` and `re*ch` are invalid).
    func testWildcardsAreAcceptedOnlyAtTheEndOfAWord() {
        XCTAssertTrue(SearchQueryParser.parse("rea*").issues.isEmpty)
        XCTAssertEqual(SearchQueryParser.issues(in: "*each").count, 1)
        XCTAssertEqual(SearchQueryParser.issues(in: "re*ch").count, 1)
        if case .misplacedWildcard(let term)? = SearchQueryParser.issues(in: "re*ch").first {
            XCTAssertEqual(term, "re*ch", "the copy quotes what the reader typed, wildcard included")
        } else {
            XCTFail("a middle wildcard must be reported as .misplacedWildcard")
        }
    }

    /// The exclusion prefix is part of the grammar (docs: `test -release -in:release-discussion`).
    func testNegationPrefixesAreParsedAndDoNotBecomeSearchTerms() {
        let parsed = SearchQueryParser.parse("test -release -in:release-discussion -from:eric")
        XCTAssertTrue(parsed.hasNegation)
        XCTAssertEqual(parsed.words, ["test"], "the un-negated word is the search text")
        XCTAssertEqual(parsed.negatedWords, ["release"],
                       "an excluded word is kept apart: it must never be highlighted")
        let negated = parsed.modifiers.filter(\.isNegated)
        XCTAssertEqual(negated.map(\.kind), [.inChannel, .from])
        XCTAssertEqual(negated.map(\.composed), ["-in:release-discussion", "-from:eric"])
        // The string sent to the server still carries every piece, negation included.
        XCTAssertEqual(parsed.terms, "test -release -in:release-discussion -from:eric")
    }

    // MARK: - 2. Invalid queries: a sentence, not an empty list

    /// The card's fourth criterion. Every case here is one the **server** answers 200 to with an empty
    /// or unrelated result set (measured), so the client is the only thing that can explain it.
    func testMalformedQueriesProduceReadableSentencesInsteadOfRequests() {
        XCTAssertEqual(SearchQueryParser.issues(in: "   ").first, .emptyQuery)
        XCTAssertEqual(SearchQueryParser.issues(in: "\"unclosed").first, .unterminatedQuote)
        XCTAssertEqual(SearchQueryParser.issues(in: "in:").first, .emptyModifier(.inChannel))
        XCTAssertEqual(SearchQueryParser.issues(in: "before:").first, .emptyModifier(.before))
        XCTAssertEqual(SearchQueryParser.issues(in: "before:notadate").first,
                       .invalidDate(.before, value: "notadate"))
        XCTAssertEqual(SearchQueryParser.issues(in: "on:today").first,
                       .invalidDate(.on, value: "today"),
                       "the server silently drops a relative date (measured: on:today -> 0 results)")
        XCTAssertEqual(SearchQueryParser.issues(in: "after:2026-02-31").first,
                       .invalidDate(.after, value: "2026-02-31"),
                       "a rolled-over date is not a date")

        // The copy names the field and what it wants, and never says "no results".
        let message = SearchQueryIssue.invalidDate(.before, value: "notadate").message
        XCTAssertTrue(message.contains("before:"), message)
        XCTAssertTrue(message.contains("YYYY-MM-DD"), message)
        XCTAssertTrue(message.contains("notadate"), message)
        XCTAssertFalse(message.isEmpty)
        for issue in [SearchQueryIssue.emptyQuery, .unterminatedQuote,
                      .emptyModifier(.from), .misplacedWildcard(term: "each")] {
            XCTAssertFalse(issue.message.isEmpty, "\(issue) must have copy")
        }
    }

    /// Valid dates are exactly the documented `YYYY-MM-DD` form.
    func testTheDateGrammarIsTheDocumentedOne() {
        XCTAssertTrue(SearchDate.isValid("2026-01-31"))
        XCTAssertTrue(SearchDate.isValid("2024-02-29"), "a leap day exists")
        XCTAssertFalse(SearchDate.isValid("2026-02-29"), "and a non-leap one does not")
        XCTAssertFalse(SearchDate.isValid("2026-1-31"), "not zero-padded")
        XCTAssertFalse(SearchDate.isValid("31-01-2026"))
        XCTAssertFalse(SearchDate.isValid("2026-01-31T10:00"))
        XCTAssertFalse(SearchDate.isValid(""))
    }

    /// A screen never sends a malformed query: the view model validates before it composes.
    func testSubmitRefusesAMalformedQueryWithoutCallingTheServer() async {
        let service = FakeSearchService()
        let model = searchModel(service)
        model.query = "before:notadate"

        await model.submit(teamID: teamID)

        XCTAssertTrue(service.searchBodies.isEmpty, "no request may be sent for a malformed query")
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.validationMessage,
                       SearchQueryIssue.invalidDate(.before, value: "notadate").message)
        XCTAssertTrue(model.rows.isEmpty)
    }

    // MARK: - 3. Highlighting

    /// The terms come from the query, not from the modifiers: `from:alice` is an author filter, not
    /// text, and a negated term means "not this", so highlighting it would point at the wrong thing.
    func testHighlightTermsDropModifiersAndNegationsAndSortLongestFirst() {
        let terms = SearchHighlighter.terms(from: "re rea* \"two words\" from:alice -secret")
        XCTAssertEqual(terms.map(\.text), ["two words", "rea", "re"])
        XCTAssertEqual(terms.map(\.kind), [.phrase, .prefix, .word])
    }

    func testMatchingRespectsWordBoundariesCaseAndPrefixes() {
        let text = "Deploy the reality, really rea*ing"
        let word = [SearchHighlightTerm(text: "real", kind: .word)]
        XCTAssertEqual(SearchHighlighter.matchCount(in: text, terms: word), 0,
                       "\"real\" must not match inside \"reality\" or \"really\"")

        let sentence = "the real thing"
        XCTAssertEqual(SearchHighlighter.matchCount(in: sentence, terms: word), 1)

        let prefix = [SearchHighlightTerm(text: "rea", kind: .prefix)]
        XCTAssertEqual(SearchHighlighter.matchCount(in: text, terms: prefix), 3,
                       "\"reality\", \"really\" and \"rea*ing\" all start with rea")

        let lower = [SearchHighlightTerm(text: "deploy", kind: .word)]
        XCTAssertEqual(SearchHighlighter.matchCount(in: text, terms: lower), 1,
                       "matching is case-insensitive")

        let phrase = [SearchHighlightTerm(text: "the real", kind: .phrase)]
        XCTAssertEqual(SearchHighlighter.matchCount(in: sentence, terms: phrase), 1)
    }

    /// CJK has no word spacing, so a boundary test there would never match (upstream's `cjkPattern`).
    func testCJKTermsMatchWithoutWordBoundaries() {
        let terms = [SearchHighlightTerm(text: "日本", kind: .word)]
        XCTAssertEqual(SearchHighlighter.matchCount(in: "日本語のテキスト", terms: terms), 1)
    }

    /// Overlapping terms paint once, at the longest match (upstream sorts by length for this reason).
    func testOverlappingTermsResolveToTheEarliestLongestMatch() {
        let terms = [SearchHighlightTerm(text: "reality", kind: .word),
                     SearchHighlightTerm(text: "real", kind: .prefix)]
        let ranges = SearchHighlighter.matches(in: "reality", terms: terms)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges.first.map { String("reality"[$0]) }, "reality")
    }

    /// The server's `matches` map wins when it sent one — except for a quoted query, whose parts are
    /// not the phrase (upstream's `hasPhrases` rule). Measured: the database backend sends none.
    func testServerMatchesWinUnlessTheQueryHasAPhrase() {
        let fromServer = SearchHighlighter.terms(query: "deploy",
                                                 serverMatches: ["deploy", "release"])
        XCTAssertEqual(fromServer.map(\.text), ["release", "deploy"])

        let withPhrase = SearchHighlighter.terms(query: "\"deploy now\"",
                                                serverMatches: ["deploy"])
        XCTAssertEqual(withPhrase.map(\.text), ["deploy now"])

        let none = SearchHighlighter.terms(query: "deploy", serverMatches: nil)
        XCTAssertEqual(none.map(\.text), ["deploy"])
    }

    /// The renderer really paints the match: the attributed string carries a background on exactly the
    /// matched characters. This is what "results highlight matches" means on screen.
    func testTheMarkdownRendererMarksTheMatchedCharacters() {
        let runs: [MarkdownInline] = [.text("the real deploy, reality aside")]
        let terms = [SearchHighlightTerm(text: "real", kind: .word)]
        let highlighted = MarkdownText.attributed(runs, highlight: terms)
        let painted = highlighted.runs.filter { $0.backgroundColor != nil }
            .map { String(highlighted[$0.range].characters) }
        XCTAssertEqual(painted, ["real"])

        let unhighlighted = MarkdownText.attributed(runs)
        XCTAssertTrue(unhighlighted.runs.allSatisfy { $0.backgroundColor == nil },
                      "a channel's own rows must not be marked")
    }

    // MARK: - 4. The result window and its paging

    func testAPageAppendsNewPostsAndDeduplicatesRepeats() {
        var window = SearchResultWindow()
        let first = [post("p3"), post("p2"), post("p1")]
        XCTAssertEqual(window.merge(searchAnswer(first, hasNext: true), pageSize: 3), .appended(3))
        XCTAssertEqual(window.postIDs, ["p3", "p2", "p1"])
        XCTAssertEqual(window.nextPage, 1)
        XCTAssertTrue(window.hasMore)

        // A page that overlaps the previous one (a post arrived between the two requests) adds only
        // what is new and keeps the server's order.
        let second = [post("p2"), post("p1"), post("p0")]
        XCTAssertEqual(window.merge(searchAnswer(second, hasNext: false), pageSize: 3), .appended(1))
        XCTAssertEqual(window.postIDs, ["p3", "p2", "p1", "p0"])
        XCTAssertEqual(window.nextPage, 2)
        XCTAssertFalse(window.hasMore, "has_next: false ends the window")
    }

    /// The measured database-backend answer: one capped page, `has_next: false`, and `page=1` answers
    /// nothing. The window must call that exhausted rather than offering a Load more that cannot work.
    func testTheDatabaseBackendWindowIsReportedExhausted() {
        var window = SearchResultWindow()
        let page = (0..<100).map { post("p\($0)") }
        XCTAssertEqual(window.merge(searchAnswer(page, hasNext: false), pageSize: 60), .appended(100))
        XCTAssertFalse(window.hasMore)
        XCTAssertEqual(window.merge(searchAnswer([], hasNext: false), pageSize: 60), .exhausted)
        XCTAssertEqual(window.count, 100, "an empty page never removes what is on screen")
    }

    /// Without `has_next` the page length is the only signal (the rule the channel list uses).
    func testAFullPageWithoutHasNextKeepsAsking() {
        var window = SearchResultWindow()
        window.merge(searchAnswer([post("a"), post("b")]), pageSize: 2)
        XCTAssertTrue(window.hasMore)
        window.merge(searchAnswer([post("c")]), pageSize: 2)
        XCTAssertFalse(window.hasMore, "a short page ends the window")
    }

    func testTheRowCarriesItsChannelLabelAndItsHighlightTerms() {
        let service = FakeSearchService()
        var channel = MMChannel(id: channelID, name: "t34-showcase", displayName: "T34 Showcase",
                                type: "O", teamId: teamID)
        channel.teamId = teamID
        service.channelsByID[channelID] = channel
        service.usersByID["u1"] = MMUser(id: "u1", username: "alice", email: "",
                                         firstName: "Alice", lastName: "A")
        let message = post("p1", message: "the deploy is real")
        var window = SearchResultWindow()
        window.merge(searchAnswer([message], hasNext: false), pageSize: 60)

        let rows = SearchResultRows.rows(window: window,
                                        users: service.usersByID,
                                        channels: service.channelsByID,
                                        query: "deploy",
                                        myUserID: "me")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.channelLabel, "#t34-showcase")
        XCTAssertEqual(rows.first?.highlight.map(\.text), ["deploy"])
        XCTAssertEqual(rows.first?.model.author.displayName, "Alice A")
        XCTAssertEqual(rows.first?.model.accessibleText, "the deploy is real")
    }

    func testChannelLabelsCoverPublicDirectAndUnknown() {
        var publicChannel = MMChannel(id: "c1", name: "town-square", displayName: "Town Square",
                                      type: "O", teamId: teamID)
        publicChannel.teamId = teamID
        var direct = MMChannel(id: "c2", name: "alice__bob", displayName: "Alice, Bob",
                               type: "D", teamId: teamID)
        direct.teamId = teamID
        XCTAssertEqual(SearchResultCopy.channelLabel(publicChannel), "#town-square")
        XCTAssertEqual(SearchResultCopy.channelLabel(direct), "Alice, Bob")
        XCTAssertEqual(SearchResultCopy.channelLabel(nil), "channel")
    }

    func testResultCopyNamesTheCountAndTheQuery() throws {
        XCTAssertEqual(SearchResultCopy.summary(count: 1, query: "deploy"),
                       "1 result for \u{201C}deploy\u{201D}")
        XCTAssertEqual(SearchResultCopy.summary(count: 12, query: "deploy"),
                       "12 results for \u{201C}deploy\u{201D}")
        XCTAssertTrue(SearchResultCopy.empty(query: "deploy").contains("Nothing matched"))
        let capped = try XCTUnwrap(SearchResultCopy.windowLimit(count: 100, isDatabaseBackend: true))
        XCTAssertTrue(capped.contains("first 100"))
        XCTAssertNil(SearchResultCopy.windowLimit(count: 100, isDatabaseBackend: false))
    }

    // MARK: - 5. The search view model

    func testASearchRunsAgainstTheCurrentTeamAndRecordsTheQuery() async {
        let service = FakeSearchService()
        service.searchPages = [searchAnswer([post("p1"), post("p2")], hasNext: false)]
        let recents = recentStore()
        let model = searchModel(service, recents: recents)

        model.query = "  deploy   from:alice "
        await model.submit(teamID: teamID)

        XCTAssertEqual(service.searchTeams, [teamID])
        XCTAssertEqual(service.searchBodies.first?.terms, "deploy from:alice")
        XCTAssertEqual(service.searchBodies.first?.page, 0)
        XCTAssertEqual(model.phase, .results)
        XCTAssertEqual(model.rows.count, 2)
        XCTAssertEqual(model.summary, "2 results for \u{201C}deploy from:alice\u{201D}")
        XCTAssertEqual(recents.entries, ["deploy from:alice"])
        XCTAssertNil(model.windowNote, "has_next: false is the server saying the window is complete — "
                     + "the database-backend note is for a capped window, not an exhausted one")
    }

    func testAServerFailuresEndsAsASentenceNotAnEmptyList() async {
        let service = FakeSearchService()
        service.searchFailure = MMError.client(status: 400,
                                               message: "Invalid or missing terms in request body.")
        let model = searchModel(service)
        model.query = "deploy"

        await model.submit(teamID: teamID)

        if case .failed(let message) = model.phase {
            XCTAssertEqual(message, "Invalid or missing terms in request body.",
                           "the server's own sentence is more useful than a generic one")
        } else {
            XCTFail("a 400 must be a failure state, not an empty result list")
        }
        XCTAssertEqual(model.errorMessage, "Invalid or missing terms in request body.")
    }

    func testLoadMoreAppendsTheNextPageAndStopsWhenTheServerIsDone() async {
        let service = FakeSearchService()
        service.pageSize = 2
        service.searchPages = [
            searchAnswer([post("p3"), post("p2")], hasNext: true),
            searchAnswer([post("p1")], hasNext: false)
        ]
        let model = searchModel(service)
        model.query = "deploy"
        await model.submit(teamID: teamID)
        XCTAssertEqual(model.rows.count, 2)

        let outcome = await model.loadMore()

        XCTAssertEqual(outcome, .appended(1))
        XCTAssertEqual(service.searchBodies.map(\.page), [0, 1],
                       "the second request asks for page 1")
        XCTAssertEqual(model.rows.map(\.id), ["p3", "p2", "p1"])
        XCTAssertFalse(model.window.hasMore)
        let exhausted = await model.loadMore()
        XCTAssertNil(exhausted, "an exhausted window makes no further request")
        XCTAssertEqual(service.searchBodies.count, 2)
    }

    /// The window note appears only at the server's measured cap (100 posts per query). A three-
    /// result answer that ends is complete: telling the reader it was truncated would be a lie.
    func testTheWindowNoteOnlyAppearsAtTheMeasuredCap() async {
        let service = FakeSearchService()
        let capped = (0..<SearchResultWindow.databaseWindowCap).map { post("cap\($0)") }
        service.searchPages = [searchAnswer(capped, hasNext: false)]
        let model = searchModel(service)
        model.query = "deploy"

        await model.submit(teamID: teamID)

        XCTAssertEqual(model.window.count, SearchResultWindow.databaseWindowCap)
        XCTAssertFalse(model.window.hasMore)
        XCTAssertNotNil(model.windowNote, "a capped window must say the server returns one window")
        XCTAssertTrue((model.windowNote ?? "").contains("first 100"))

        let short = FakeSearchService()
        short.searchPages = [searchAnswer([post("p1")], hasNext: false)]
        let shortModel = searchModel(short)
        shortModel.query = "deploy"
        await shortModel.submit(teamID: teamID)
        XCTAssertNil(shortModel.windowNote, "one match is the whole answer, not a truncated one")
    }

    func testClearingASearchForgetsTheResultSetButNotTheHistory() async {
        let service = FakeSearchService()
        service.searchPages = [searchAnswer([post("p1")], hasNext: false)]
        let recents = recentStore()
        let model = searchModel(service, recents: recents)
        model.query = "deploy"
        await model.submit(teamID: teamID)
        XCTAssertEqual(model.rows.count, 1)

        model.clear()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(recents.entries, ["deploy"], "history survives a cleared field")
    }

    // MARK: - 6. Recent searches

    func testRecentSearchesAreDedupedNewestFirstAndCapped() {
        var recent = RecentSearches()
        recent.record("Deploy")
        recent.record("  deploy  ")
        XCTAssertEqual(recent.entries, ["deploy"],
                       "the same search twice is one row, newest spelling, trimmed")

        recent.record("release")
        XCTAssertEqual(recent.entries, ["release", "deploy"])

        for index in 0..<20 { recent.record("q\(index)") }
        XCTAssertEqual(recent.entries.count, RecentSearches.limit)
        XCTAssertEqual(recent.entries.first, "q19")
        XCTAssertFalse(recent.entries.contains("Deploy"))
    }

    func testTheStoreRoundTripsThroughItsKey() {
        let store = FakeRecentStore()
        let key = UserDefaultsRecentSearchStore.key(serverID: UUID(), teamID: teamID)
        let first = RecentSearchesStore(store: store, key: key)
        first.record("deploy")
        XCTAssertEqual(store.saves, 1)

        let second = RecentSearchesStore(store: store, key: key)
        XCTAssertEqual(second.entries, ["deploy"], "a new screen reads the saved history")
    }

    func testTheDefaultsKeyIsScopedToServerAndTeam() {
        let server = UUID()
        let other = UUID()
        XCTAssertNotEqual(UserDefaultsRecentSearchStore.key(serverID: server, teamID: teamID),
                          UserDefaultsRecentSearchStore.key(serverID: other, teamID: teamID))
        XCTAssertNotEqual(UserDefaultsRecentSearchStore.key(serverID: server, teamID: teamID),
                          UserDefaultsRecentSearchStore.key(serverID: server, teamID: "t2"))
    }

    // MARK: - 7. Jumping to a result

    func testAJumpTargetIsAChannelForARootAndAThreadForAReply() {
        XCTAssertEqual(SearchJump.target(for: post("p1")), .channel(postID: "p1"))
        var reply = post("p2")
        reply.rootId = "p1"
        XCTAssertEqual(SearchJump.target(for: reply), .thread(rootID: "p1"))
    }

    // MARK: - 8. Saved and pinned lists

    private func collectionModel(_ service: FakeSearchService,
                                 kind: PostCollectionViewModel.Kind) -> PostCollectionViewModel {
        let model = PostCollectionViewModel(kind: kind, service: service, myUserID: "me")
        model.teamID = teamID
        model.channelID = channelID
        return model
    }

    func testTheSavedListLoadsTheServersPostsWithTheirAuthors() async {
        let service = FakeSearchService()
        let saved = post("p1", message: "keep this")
        service.savedList = MMPostList(order: ["p1"],
                                       posts: ["p1": saved],
                                       hasNext: false)
        service.usersByID["u1"] = MMUser(id: "u1", username: "alice", email: "",
                                         firstName: "Alice", lastName: "A")
        let model = collectionModel(service, kind: .saved)

        await model.load()

        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.rows.map(\.id), ["p1"])
        XCTAssertEqual(model.rows.first?.author.displayName, "Alice A")
        XCTAssertEqual(service.savedFetchCount, 1)
    }

    /// The card's "un-pinning updates in place": the write happens, the row leaves the list, and no
    /// second read is issued to find that out.
    func testUnpinningRemovesTheRowInPlaceWithoutARefetch() async {
        let service = FakeSearchService()
        service.pinnedList = MMPostList(order: ["p1", "p2"],
                                        posts: ["p1": post("p1"), "p2": post("p2")],
                                        hasNext: false)
        let model = collectionModel(service, kind: .pinned)
        var changes: [(String, Bool)] = []
        model.onPinnedChange = { changes.append(($0, $1)) }
        await model.load()
        XCTAssertEqual(model.rows.count, 2)

        let removed = await model.remove("p1")

        XCTAssertTrue(removed)
        XCTAssertEqual(service.pinWrites.map { "\($0.postID):\($0.pinned)" }, ["p1:false"])
        XCTAssertEqual(model.rows.map(\.id), ["p2"], "the row is gone from the list on screen")
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.0, "p1")
        XCTAssertEqual(changes.first?.1, false, "and the channel's own row is told, so it flips too")
        XCTAssertEqual(service.pinnedFetchCount, 1, "no refetch: a reload would flicker for a known result")
    }

    func testUnsavingWritesThePreferenceAndDropsTheRow() async {
        let service = FakeSearchService()
        service.savedList = MMPostList(order: ["p1"], posts: ["p1": post("p1")], hasNext: false)
        let model = collectionModel(service, kind: .saved)
        await model.load()

        let removed = await model.remove("p1")
        XCTAssertTrue(removed)

        XCTAssertEqual(service.savedWrites.map { "\($0.postID):\($0.saved)" }, ["p1:false"])
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(service.savedFetchCount, 1)
    }

    /// A save made on another device arrives as a preference socket event. The row cannot be invented
    /// (this list does not hold the post), so the model asks the view to reload — and an unsave is
    /// applied immediately.
    func testSocketPreferenceChangesPatchTheSavedList() async {
        let service = FakeSearchService()
        service.savedList = MMPostList(order: ["p1", "p2"],
                                       posts: ["p1": post("p1"), "p2": post("p2")],
                                       hasNext: false)
        let model = collectionModel(service, kind: .saved)
        await model.load()

        let unsave = MMPreference(userId: "me", category: APIClient.savedPostCategory,
                                  name: "p1", value: "false")
        XCTAssertTrue(model.handle(.preferencesChanged([unsave])))
        XCTAssertEqual(model.rows.map(\.id), ["p2"])
        XCTAssertFalse(model.pendingReload)

        let saveElsewhere = MMPreference(userId: "me", category: APIClient.savedPostCategory,
                                         name: "p9", value: "true")
        XCTAssertTrue(model.handle(.preferencesChanged([saveElsewhere])))
        XCTAssertTrue(model.pendingReload, "a post this list does not hold needs a refetch")

        // A different preference category is none of this list's business.
        let theme = MMPreference(userId: "me", category: "theme", name: "", value: "dark")
        XCTAssertFalse(model.handle(.preferencesChanged([theme])))
    }

    func testAPinnedListFailureIsASentence() async {
        let service = FakeSearchService()
        service.pinnedFailure = MMError.offline
        let model = collectionModel(service, kind: .pinned)

        await model.load()

        if case .failed(let message) = model.phase {
            XCTAssertTrue(message.contains("offline"), message)
        } else {
            XCTFail("a failed pinned read must be a failure state")
        }
    }

    /// `post_edited` from the socket keeps a pinned row's text current without a reload.
    func testSocketPostEditedPatchesARowInPlace() async {
        let service = FakeSearchService()
        service.pinnedList = MMPostList(order: ["p1"], posts: ["p1": post("p1", message: "old")],
                                        hasNext: false)
        let model = collectionModel(service, kind: .pinned)
        await model.load()

        var edited = post("p1", message: "edited")
        edited.isPinned = true
        XCTAssertTrue(model.handle(.postEdited(edited)))
        XCTAssertEqual(model.rows.first?.post.message, "edited")
        XCTAssertEqual(service.pinnedFetchCount, 1)
    }

    // MARK: - 9. The jump's fetch-by-id path and its failure sentences (T39-AV F5)

    /// A `ChannelServing` whose window and single-post answer are set per test.
    @MainActor
    final class FakeChannelService: ChannelServing {
        var pageSize = 60
        /// The newest page the pane loads.
        var page = MMPostList()
        var singlePost: MMPost?
        var singlePostFailure: Error?
        private(set) var singlePostFetches: [String] = []

        func channel(id: String) async throws -> MMChannel {
            MMChannel(id: id, name: "t34-showcase", displayName: "t34-showcase", type: "O")
        }

        func posts(channelID: String, before: String?, perPage: Int) async throws -> MMPostList {
            page
        }

        func users(ids: [String]) async throws -> [MMUser] { [] }

        func post(id: String) async throws -> MMPost {
            singlePostFetches.append(id)
            if let singlePostFailure { throw singlePostFailure }
            guard let singlePost else { throw MMError.notFound }
            return singlePost
        }

        func fileData(fileID: String, preferThumbnail: Bool) async throws -> Data {
            throw MMError.notFound
        }
    }

    /// A channel whose newest page is a three-post window; `postID` is 100 messages older and only
    /// reachable by `GET /posts/{id}`.
    private func loadedChannel(_ service: FakeChannelService) async -> ChannelViewModel {
        let model = ChannelViewModel(channelID: channelID, channelName: "t34-showcase",
                                     service: service, myUserID: "me")
        await model.load()
        return model
    }

    private func windowPost(_ id: String, at millis: Int64) -> MMPost {
        MMPost(id: id, createAt: millis, userId: "u1", channelId: channelID, message: "newest page")
    }

    /// The path the shipped live test cannot reach: the post is **not** in the window, so `focus` has
    /// to fetch it by id, merge it, and mark it. Without this the handoff's "jump fetches by id" claim
    /// had no unit witness (T39-AV F5).
    func testFocusFetchesAPostTheWindowDoesNotHoldAndMarksIt() async {
        let service = FakeChannelService()
        let newest: Int64 = 1_790_000_000_000
        service.page = MMPostList(order: ["n3", "n2", "n1"],
                                  posts: ["n3": windowPost("n3", at: newest - 1000),
                                          "n2": windowPost("n2", at: newest - 2000),
                                          "n1": windowPost("n1", at: newest - 3000)],
                                  hasNext: false)
        let old = MMPost(id: "old", createAt: newest - 100_000_000, userId: "u1",
                         channelId: channelID, message: "the post the reader searched for")
        service.singlePost = old
        let model = await loadedChannel(service)

        await model.focus(postID: "old")

        XCTAssertEqual(service.singlePostFetches, ["old"], "the id path must be exercised")
        XCTAssertEqual(model.focusedPostID, "old")
        XCTAssertEqual(model.jumpTarget, "old")
        XCTAssertNil(model.focusError)
        XCTAssertNotNil(model.post(id: "old"), "the fetched post is merged into the window")
    }

    /// The merged post is not contiguous with the newest page: the list must say so with a `.gap`
    /// separator instead of drawing ~140 unknown messages as if they were the neighbours (T39-AV F2).
    func testAFetchedOldPostIsSeparatedFromTheNewestPageByAGap() async {
        let service = FakeChannelService()
        let newest: Int64 = 1_790_000_000_000
        service.page = MMPostList(order: ["n2", "n1"],
                                  posts: ["n2": windowPost("n2", at: newest - 1000),
                                          "n1": windowPost("n1", at: newest - 2000)],
                                  hasNext: false)
        service.singlePost = MMPost(id: "old", createAt: newest - 100_000_000, userId: "u1",
                                    channelId: channelID, message: "old")
        let model = await loadedChannel(service)
        XCTAssertFalse(model.items.contains { if case .gap = $0 { return true }; return false },
                       "a whole window needs no gap marker")

        await model.focus(postID: "old")

        let order = model.items.map { item -> String in
            switch item {
            case .gap: return "GAP"
            case .post(let row): return row.id
            case .dateSeparator: return "day"
            case .newMessages: return "new"
            }
        }
        let gapIndex = try? XCTUnwrap(order.firstIndex(of: "GAP"))
        let oldIndex = try? XCTUnwrap(order.firstIndex(of: "old"))
        let newestIndex = try? XCTUnwrap(order.firstIndex(of: "n2"))
        XCTAssertNotNil(gapIndex, "the jump must draw a gap separator: \(order)")
        XCTAssertNotNil(oldIndex)
        XCTAssertNotNil(newestIndex)
        if let gapIndex, let oldIndex, let newestIndex {
            // Display order is oldest first: jumped post, gap, then the contiguous newest block.
            XCTAssertLessThan(oldIndex, gapIndex)
            XCTAssertLessThan(gapIndex, newestIndex)
        }
    }

    /// Failure path 1: the post belongs to another channel. The pane must refuse it in a sentence and
    /// must not merge a row into the wrong channel's timeline.
    func testFocusRefusesAPostFromAnotherChannel() async {
        let service = FakeChannelService()
        let newest: Int64 = 1_790_000_000_000
        service.page = MMPostList(order: ["n1"],
                                  posts: ["n1": windowPost("n1", at: newest)], hasNext: false)
        service.singlePost = MMPost(id: "other", createAt: newest - 1000, userId: "u1",
                                    channelId: "chan_other", message: "elsewhere")
        let model = await loadedChannel(service)

        await model.focus(postID: "other")

        XCTAssertEqual(model.focusError, "That message belongs to a different channel.")
        XCTAssertNil(model.focusedPostID, "a foreign post must not be marked in this channel")
        XCTAssertNil(model.jumpTarget, "and must not scroll the list")
        XCTAssertNil(model.post(id: "other"), "nor be merged into this channel's window")
    }

    /// Failure path 2: the post is gone (deleted between the search and the tap). A 404 is its own
    /// sentence, not the generic "could not be opened".
    func testFocusExplainsADeletedPost() async {
        let service = FakeChannelService()
        let newest: Int64 = 1_790_000_000_000
        service.page = MMPostList(order: ["n1"],
                                  posts: ["n1": windowPost("n1", at: newest)], hasNext: false)
        service.singlePostFailure = MMError.notFound
        let model = await loadedChannel(service)

        await model.focus(postID: "gone")

        XCTAssertEqual(model.focusError, "That message no longer exists on the server.")
        XCTAssertNil(model.focusedPostID)
        XCTAssertNil(model.jumpTarget)
    }

    /// A reply cannot be a row of a thread-collapsed timeline, so its jump is its thread — decided from
    /// the **fetched** post, which is the branch the window path cannot cover.
    func testFocusOnAFetchedReplyOpensItsThread() async {
        let service = FakeChannelService()
        let newest: Int64 = 1_790_000_000_000
        service.page = MMPostList(order: ["n1"],
                                  posts: ["n1": windowPost("n1", at: newest)], hasNext: false)
        var reply = MMPost(id: "reply", createAt: newest - 1000, userId: "u1",
                           channelId: channelID, message: "a reply")
        reply.rootId = "root"
        service.singlePost = reply
        let model = await loadedChannel(service)

        await model.focus(postID: "reply")

        XCTAssertEqual(model.threadJumpRootID, "root")
        XCTAssertNil(model.jumpTarget, "a reply is not a timeline row: nothing to scroll to")
        XCTAssertNil(model.focusedPostID)
    }

    /// A post the window already holds takes the `postsByID` branch: no request, and no gap either —
    /// the list is contiguous there.
    func testFocusOnAPostInTheWindowDoesNotFetch() async {
        let service = FakeChannelService()
        let newest: Int64 = 1_790_000_000_000
        service.page = MMPostList(order: ["n1"],
                                  posts: ["n1": windowPost("n1", at: newest)], hasNext: false)
        let model = await loadedChannel(service)

        await model.focus(postID: "n1")

        XCTAssertTrue(service.singlePostFetches.isEmpty)
        XCTAssertEqual(model.focusedPostID, "n1")
        XCTAssertEqual(model.jumpTarget, "n1")
    }

    // MARK: - 10. Saved rows name their channel (T39-AV F6)

    func testTheSavedRowNamesTheChannelItCameFrom() async {
        let service = FakeSearchService()
        service.savedList = MMPostList(order: ["p1"], posts: ["p1": post("p1")], hasNext: false)
        service.channelsByID[channelID] = MMChannel(id: channelID, name: "t34-showcase",
                                                   displayName: "t34-showcase", type: "O")
        let model = collectionModel(service, kind: .saved)

        await model.load()

        XCTAssertEqual(model.channelLabel(for: "p1"), "#t34-showcase")
    }

    /// The pinned sheet already names its channel in its own title, so its rows carry no label.
    func testAPinnedRowCarriesNoChannelLabelButALoadedSavedRowDoes() async {
        let service = FakeSearchService()
        service.pinnedList = MMPostList(order: ["p1"], posts: ["p1": post("p1")], hasNext: false)
        service.channelsByID[channelID] = MMChannel(id: channelID, name: "t34-showcase", type: "O")
        let pinned = collectionModel(service, kind: .pinned)

        await pinned.load()

        XCTAssertNil(pinned.channelLabel(for: "p1"))
    }

    // MARK: - 11. Recent searches can be forgotten (T39-AV F7)

    /// The row's delete and the clear-all both reach the store, so the list a reader sees is the list
    /// that persists — not an in-memory edit that comes back on the next launch.
    func testARecentSearchCanBeRemovedAndTheListClearedThroughTheStore() {
        let store = FakeRecentStore()
        let recents = RecentSearchesStore(store: store, key: "s.\(teamID)")
        recents.record("deploy")
        recents.record("payload")
        XCTAssertEqual(recents.entries, ["payload", "deploy"])

        recents.remove("deploy")
        XCTAssertEqual(recents.entries, ["payload"])
        XCTAssertEqual(store.storage["s.\(teamID)"], ["payload"],
                       "the removal is persisted, not just published")

        recents.removeAll()
        XCTAssertTrue(recents.entries.isEmpty)
        XCTAssertEqual(store.storage["s.\(teamID)"], [])
    }
}
