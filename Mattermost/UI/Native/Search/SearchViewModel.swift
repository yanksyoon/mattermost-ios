// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: `app/screens/home/search/search.tsx` (the screen: field, submit, recent searches, modifier
//        chips), `app/screens/home/search/results/post_results.tsx` (the result row and the tap that
//        opens the channel at that post), `app/screens/home/search/results/index.tsx` (the list, its
//        footer and its empty state), `app/actions/remote/search.ts` (query → window → row context).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §16; no
// upstream source copied. The view-model shape is this repo's own (component-map.md §1) and mirrors
// `ChannelViewModel` (T34): a generation guard, a service seam, and the rules kept out of the view.
//
// The card's four criteria map onto this file:
//  1. **each modifier is composed and encoded** — `SearchQuery`/`SearchQueryParser` (SearchGrammar);
//  2. **results paginate, highlight, and jumping lands on the right post** — the window here plus
//     `SearchJump` below;
//  3. **saved/pinned match the server** — `PostCollectionViewModel`;
//  4. **an invalid query is a readable error, not an empty list** — `issues`/`errorMessage` here.

import Foundation
import Combine

/// Where a tapped search result has to go.
///
/// A result can be a top-level post (open its channel at that post) or a reply (open its thread: the
/// channel timeline is thread-collapsed, so a reply is not a row there and scrolling to it would
/// scroll to nothing). Deciding this from the post alone is pure, so the rule is unit-tested.
enum SearchJumpTarget: Equatable, Sendable {
    case channel(postID: String)
    case thread(rootID: String)
}

enum SearchJump {
    static func target(for post: MMPost) -> SearchJumpTarget {
        post.rootId.isEmpty ? .channel(postID: post.id) : .thread(rootID: post.rootId)
    }
}

/// The search screen's state: what was asked, what came back, and what to say when it did not.
@MainActor
final class SearchViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case searching
        case results
        case failed(String)
    }

    // MARK: State

    /// The field's text (two-way bound).
    @Published var query: String = ""
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var window = SearchResultWindow()
    /// Why the current query cannot be sent. Empty means "sendable".
    @Published private(set) var issues: [SearchQueryIssue] = []
    /// A failure from the server (never the validation above — that never becomes a request).
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoadingMore = false
    /// The query as it was sent (normalised). The list's copy quotes this, not the live field.
    @Published private(set) var submittedText: String = ""
    @Published private(set) var rows: [SearchResultRow] = []
    /// Whether the server answered before any page could carry a result.
    @Published private(set) var hasSearched = false

    /// The channel of one result, as the row's subtitle draws it.
    private(set) var channels: [String: MMChannel] = [:]
    private(set) var users: [String: MMUser] = [:]

    // MARK: Collaborators

    let recents: RecentSearchesStore
    private let service: SearchServing
    private let myUserID: String?

    // MARK: Request state

    /// The team the last search ran against (kept so paging re-uses it). The coordinator sets it when
    /// it hands the model to a pane, so a search runs in the team the shell is showing.
    var teamID: String?
    private var composed: SearchQuery?
    /// Every search takes a number; a late answer for an older one is dropped (a fast typist must not
    /// see results for the query they already replaced).
    private var generation = 0

    init(service: SearchServing,
         recents: RecentSearchesStore,
         myUserID: String? = nil) {
        self.service = service
        self.recents = recents
        self.myUserID = myUserID
    }

    // MARK: Derived copy

    var summary: String? {
        guard phase == .results else { return nil }
        return SearchResultCopy.summary(count: window.count, query: submittedText)
    }

    /// The note explaining a server that cannot page past its window (database backend).
    var windowNote: String? {
        guard phase == .results, !window.hasMore else { return nil }
        // Only a window that actually reached the server's cap is truncated. A three-result answer
        // that ends is a *complete* answer; saying otherwise would be the kind of lie this card is
        // about. The threshold is the measured cap, not the page size.
        guard window.count >= SearchResultWindow.databaseWindowCap else { return nil }
        return SearchResultCopy.windowLimit(count: window.count, isDatabaseBackend: true)
    }

    var emptyCopy: String {
        SearchResultCopy.empty(query: submittedText)
    }

    /// The first validation sentence (the field's error line).
    var validationMessage: String? {
        issues.first?.message
    }

    /// Whether the Load more control should be drawn. `hasMore` is the honest answer; the launch-arg
    /// seam exists so a live test can drive the paging request on a server that refuses to page.
    var canLoadMore: Bool {
        phase == .results && (window.hasMore || SearchUITestHook.exposesPaging)
    }

    /// What the seam button reports (and what a test asserts changed): the page cursor, the window
    /// size, and whether the model thinks another page exists.
    var pagingStateDescription: String {
        "page \(window.nextPage), \(window.count) results, hasMore \(window.hasMore)"
    }

    var highlightTerms: [SearchHighlightTerm] {
        SearchHighlighter.terms(from: submittedText)
    }

    // MARK: - Searching

    /// Validate, compose and run one search.
    ///
    /// The order matters and is the acceptance criterion: **validate first**, so a malformed query
    /// never reaches the server and never produces the empty list the card forbids. The server's own
    /// 400 (an empty `terms` field can still reach it through a proxy) is surfaced verbatim.
    func submit(teamID: String?) async {
        let parsed = SearchQueryParser.parse(query)
        issues = parsed.issues
        guard parsed.issues.isEmpty else {
            // Clear a previous result set: leaving it under an error banner would read as "these are
            // the results for what you just typed".
            phase = .idle
            window.reset(pageSize: service.pageSize)
            rows = []
            submittedText = parsed.terms
            channels = [:]
            errorMessage = nil
            hasSearched = false
            composed = nil
            return
        }
        let resolvedTeam = teamID ?? self.teamID
        guard let resolvedTeam, !resolvedTeam.isEmpty else {
            phase = .failed("Choose a team before searching.")
            errorMessage = "Choose a team before searching."
            return
        }
        self.teamID = resolvedTeam
        let request = SearchQuery.compose(from: query,
                                          timeZoneOffsetSeconds: TimeZone.current.secondsFromGMT())
        composed = request
        submittedText = request.terms
        generation += 1
        let requested = generation
        window.reset(pageSize: service.pageSize)
        rows = []
        channels = [:]
        users = [:]
        errorMessage = nil
        hasSearched = true
        phase = .searching
        do {
            let results = try await service.search(teamID: resolvedTeam,
                                                  body: request.body(page: 0,
                                                                      perPage: service.pageSize))
            guard requested == generation else { return }
            window.merge(results, pageSize: service.pageSize)
            await loadRowContext(teamID: resolvedTeam, requested: requested)
            guard requested == generation else { return }
            recents.record(request.terms)
            rebuildRows()
            phase = .results
        } catch {
            guard requested == generation else { return }
            let message = Self.message(for: error)
            errorMessage = message
            phase = .failed(message)
        }
    }

    /// Ask for the next page. Appends what is new; reports exhaustion.
    @discardableResult
    func loadMore() async -> SearchPageOutcome? {
        guard phase == .results, !isLoadingMore, let composed, let teamID else { return nil }
        guard window.hasMore || SearchUITestHook.exposesPaging else { return nil }
        isLoadingMore = true
        defer { isLoadingMore = false }
        generation += 1
        let requested = generation
        do {
            let results = try await service.search(teamID: teamID,
                                                  body: composed.body(page: window.nextPage,
                                                                      perPage: service.pageSize))
            guard requested == generation else { return nil }
            let outcome = window.merge(results, pageSize: service.pageSize)
            await loadRowContext(teamID: teamID, requested: requested)
            guard requested == generation else { return nil }
            rebuildRows()
            return outcome
        } catch {
            guard requested == generation else { return nil }
            // A failed *page* keeps the rows already on screen: they are still true results.
            errorMessage = Self.message(for: error)
            return nil
        }
    }

    /// Back to the initial state (the field's clear button).
    func clear() {
        generation += 1
        query = ""
        submittedText = ""
        issues = []
        errorMessage = nil
        phase = .idle
        hasSearched = false
        composed = nil
        window.reset(pageSize: service.pageSize)
        rows = []
        channels = [:]
        users = [:]
    }

    /// The recent-search row's action: run the stored query.
    func repeatSearch(_ text: String, teamID: String?) async {
        query = text
        await submit(teamID: teamID)
    }

    // MARK: - Row context

    /// The profiles and channel names a result window needs. Both are best-effort: a failed batch
    /// leaves the rows readable (author from the post's own ids, channel as "channel") instead of
    /// failing the search.
    private func loadRowContext(teamID: String, requested: Int) async {
        let posts = window.posts
        guard !posts.isEmpty else { return }
        let profileIDs = SearchResultRows.profileIDs(posts)
        let channelIDs = SearchResultRows.channelIDs(posts)
        let profiles = (try? await service.users(ids: profileIDs)) ?? []
        guard requested == generation else { return }
        for user in profiles { users[user.id] = user }
        let missing = channelIDs.filter { channels[$0] == nil }
        if !missing.isEmpty, let fetched = try? await service.channels(ids: missing, teamID: teamID) {
            guard requested == generation else { return }
            for channel in fetched { channels[channel.id] = channel }
        }
    }

    private func rebuildRows() {
        rows = SearchResultRows.rows(window: window,
                                     users: users,
                                     channels: channels,
                                     query: submittedText,
                                     myUserID: myUserID)
    }

    // MARK: - Copy

    static func message(for error: Error) -> String {
        // A 400 from this endpoint carries the server's own sentence ("Invalid or missing terms in
        // request body."), and that is more useful than a generic line, so it is passed through.
        if case let MMError.client(status, message) = error, status == 400, let message, !message.isEmpty {
            return message
        }
        return MMErrorCopy.message(for: error,
                                   offline: "You are offline. Search needs a connection to the server.",
                                   timeout: "The server did not answer the search in time.",
                                   unauthorized: "Your session has expired. Sign in again to search.",
                                   forbidden: "You do not have permission to search this team.",
                                   notFound: "This team no longer exists on the server.",
                                   rateLimited: "The server is rate limiting searches. Try again shortly.",
                                   fallback: "The search could not be run.")
    }
}

/// Launch-argument seams for this screen's UI tests (same shape as `ChannelUITestHook`).
///
/// Read from `ProcessInfo` at launch, never from a persisted setting, so a build a person runs cannot
/// reach this code path. `-uiTestExposeSearchPaging` draws the Load more control even when the server
/// says there is no next page — the one thing a database-backed server makes untestable otherwise —
/// and the control still performs a **real** `page=1` request through the shipping code path.
enum SearchUITestHook {
    static var exposesPaging: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTestExposeSearchPaging")
    }
}
