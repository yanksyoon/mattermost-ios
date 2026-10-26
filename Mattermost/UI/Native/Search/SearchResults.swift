// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: `app/screens/home/search/results/post_results.tsx` (the result row: post body + the
//        channel it lives in), `app/screens/home/search/results/index.tsx` (the result list and its
//        "load more" footer), `app/actions/remote/search.ts` (`getSearchParams`, the request body).
// Server contract: https://api.mattermost.com `POST /api/v4/teams/{team_id}/posts/search` →
//        `PostListWithSearchMatches` (`order`, `posts`, `matches`, `has_next`, `next_post_id`,
//        `first_inaccessible_post_time`).
// Licence: Apache-2.0 — reimplemented; no upstream source copied. Attribution:
// docs/THIRD_PARTY_NOTICES.md §16.
//
// ## Paging, and what the server actually does (measured 2026-10-26, 9.11.19)
//
// `posts.yaml` documents `page`/`per_page` on this endpoint as "Only works with Elasticsearch". The
// pinned server reports `ActiveSearchBackend: database` (`GET /api/v4/system/ping`), and there:
//  - `per_page` is ignored: 3, 10, 200 and 500 all answer the same 100-id window;
//  - `page` is ignored: `page=0` and `page=1` answer the *same* set (and `page=1` on a query with few
//    matches answers an empty one);
//  - `has_next` is `false` on that window.
//
// So the window is a single capped page of at most 100 posts and the client cannot ask for more. The
// paging state machine below is still the honest one: it asks for the next page, appends what it has
// not seen, and stops when the server answers nothing new or says there is no next page. On an
// Elasticsearch-backed server (or a plugin backend that honours the parameters) the same code pages
// properly; on a database server it makes exactly one extra request and reports exhaustion. What the
// screen must not do is pretend: past the window, the copy says the results are the first N.

import Foundation

/// `POST /teams/{team_id}/posts/search`'s answer.
///
/// Tolerant like every other model here: `matches` is absent from a database-backed answer (measured),
/// and the cursors are optional so a proxy that strips them still decodes.
struct MMSearchResults: Decodable, Equatable, Sendable {
    var order: [String]
    var posts: [String: MMPost]
    /// Post id → the terms the *server* matched. Absent/null on the database backend.
    var matches: [String: [String]]?
    var hasNext: Bool?
    var nextPostID: String
    var prevPostID: String
    /// Posts before this timestamp exist but are not visible to this account (the server's own note
    /// that the window is not the whole history).
    var firstInaccessiblePostTime: Int64

    enum CodingKeys: String, CodingKey {
        case order, posts, matches
        case hasNext = "has_next"
        case nextPostID = "next_post_id"
        case prevPostID = "prev_post_id"
        case firstInaccessiblePostTime = "first_inaccessible_post_time"
    }

    init(order: [String] = [],
         posts: [String: MMPost] = [:],
         matches: [String: [String]]? = nil,
         hasNext: Bool? = nil,
         nextPostID: String = "",
         prevPostID: String = "",
         firstInaccessiblePostTime: Int64 = 0) {
        self.order = order
        self.posts = posts
        self.matches = matches
        self.hasNext = hasNext
        self.nextPostID = nextPostID
        self.prevPostID = prevPostID
        self.firstInaccessiblePostTime = firstInaccessiblePostTime
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        order = try values.decodeIfPresent([String].self, forKey: .order) ?? []
        posts = try values.decodeIfPresent([String: MMPost].self, forKey: .posts) ?? [:]
        matches = try values.decodeIfPresent([String: [String]].self, forKey: .matches)
        hasNext = try values.decodeIfPresent(Bool.self, forKey: .hasNext)
        nextPostID = try values.decodeIfPresent(String.self, forKey: .nextPostID) ?? ""
        prevPostID = try values.decodeIfPresent(String.self, forKey: .prevPostID) ?? ""
        firstInaccessiblePostTime =
            try values.decodeIfPresent(Int64.self, forKey: .firstInaccessiblePostTime) ?? 0
    }

    /// The posts in the server's order, dropping ids the payload did not carry.
    var orderedPosts: [MMPost] {
        order.compactMap { posts[$0] }
    }
}

/// What one page did to the result window.
enum SearchPageOutcome: Equatable, Sendable {
    /// The window grew by N rows.
    case appended(Int)
    /// The server had nothing new: the window is complete as far as this server can answer.
    case exhausted
}

/// The accumulated result window: the posts on screen, their highlight source, and whether another
/// page is worth asking for.
struct SearchResultWindow: Equatable, Sendable {
    /// Server order (newest first, as the search endpoint answers it).
    private(set) var posts: [MMPost] = []
    /// Post id → server-matched terms, when the backend computed any.
    private(set) var matches: [String: [String]] = [:]
    /// The next page index to request.
    private(set) var nextPage: Int = 0
    /// Whether asking for another page can produce anything.
    private(set) var hasMore: Bool = true
    /// The page size the last merge was told to expect (for the length heuristic below).
    private(set) var pageSize: Int = 60

    /// The most posts a database-backed server answers for one query (measured: `page=1` answers an
    /// empty order, so the window is the whole answer, not the first slice of a pageable list).
    static let databaseWindowCap = 100

    var count: Int { posts.count }
    var isEmpty: Bool { posts.isEmpty }
    var postIDs: [String] { posts.map(\.id) }

    mutating func reset(pageSize: Int = 60) {
        posts = []
        matches = [:]
        nextPage = 0
        hasMore = true
        self.pageSize = pageSize
    }

    /// Merge one page. Returns whether the window grew, and whether paging is over.
    ///
    /// The dedupe is by post id: a page that overlaps the previous one (a live post arriving between
    /// two requests can shift an offset-paged window) must not draw the same message twice.
    @discardableResult
    mutating func merge(_ results: MMSearchResults, pageSize: Int) -> SearchPageOutcome {
        self.pageSize = pageSize
        var known = Set(posts.map(\.id))
        var fresh: [MMPost] = []
        for id in results.order {
            guard !known.contains(id), let post = results.posts[id] else { continue }
            known.insert(id)
            fresh.append(post)
        }
        posts.append(contentsOf: fresh)
        for (id, terms) in results.matches ?? [:] where results.posts[id] != nil {
            matches[id] = terms
        }
        nextPage += 1
        // `has_next` is authoritative when present; otherwise a full page means "ask again" (the same
        // rule the channel list applies, where `has_next` was measured to be untrustworthy).
        if let hasNext = results.hasNext {
            hasMore = hasNext
        } else {
            hasMore = results.order.count >= pageSize
        }
        if results.order.isEmpty { hasMore = false }
        return fresh.isEmpty ? .exhausted : .appended(fresh.count)
    }

    /// The terms to highlight for one post (server matches first, then the query's own terms).
    func highlightTerms(for postID: String, query: String) -> [SearchHighlightTerm] {
        SearchHighlighter.terms(query: query, serverMatches: matches[postID])
    }
}

/// The words the search screen shows about its own result set.
enum SearchResultCopy {

    /// "12 results for “report before:2026-01-31”".
    static func summary(count: Int, query: String) -> String {
        let noun = count == 1 ? "result" : "results"
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "\(count) \(noun)" : "\(count) \(noun) for \u{201C}\(trimmed)\u{201D}"
    }

    /// The copy for a query the server answered with nothing. Deliberately not "no results": on a
    /// database backend a stop word or a modifier-only query can also answer nothing, and the reader
    /// needs to know the difference between "nothing matched" and "the query was narrowed away".
    static func empty(query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Nothing matched \u{201C}\(trimmed)\u{201D}. Try a different word, or remove a "
            + "modifier such as before: or in:."
    }

    /// The line under the list when the server cannot page any further than the window it answered.
    static func windowLimit(count: Int, isDatabaseBackend: Bool) -> String? {
        guard count > 0 else { return nil }
        if isDatabaseBackend {
            return "Showing the first \(count) matches. This server searches its database, which "
                + "returns one window per query — narrow the search to see different messages."
        }
        return nil
    }

    /// The channel a result lives in, as the row's subtitle draws it: `#town-square`, or a direct
    /// message's display name.
    static func channelLabel(_ channel: MMChannel?) -> String {
        guard let channel else { return "channel" }
        switch channel.type {
        case "O", "P":
            return "#" + (channel.name.isEmpty ? channel.displayName : channel.name)
        default:
            let display = channel.displayName
            return display.isEmpty ? channel.name : display
        }
    }
}

/// One result row: the post, its derived model (body markdown, author, attachments), and the channel
/// it belongs to.
struct SearchResultRow: Identifiable, Equatable, Sendable {
    var model: PostRowModel
    var channelLabel: String
    var channelID: String
    /// The terms this row highlights (server matches when the backend sent them).
    var highlight: [SearchHighlightTerm]

    var id: String { model.id }
}

/// Builds the rows from the window. Pure, so the ordering/labelling/highlight rules are unit-tested.
enum SearchResultRows {

    static func rows(window: SearchResultWindow,
                     users: [String: MMUser],
                     channels: [String: MMChannel],
                     query: String,
                     myUserID: String?) -> [SearchResultRow] {
        window.posts.map { post in
            SearchResultRow(
                model: PostListDerivation.row(post: post,
                                              users: users,
                                              myUserID: myUserID,
                                              grouped: false),
                channelLabel: SearchResultCopy.channelLabel(channels[post.channelId]),
                channelID: post.channelId,
                highlight: window.highlightTerms(for: post.id, query: query))
        }
    }

    /// The ids the result list must ask the server for: the authors on screen, and the channels the
    /// rows name. Sorted, so the request is the same for the same window (a cached profile batch hits).
    static func profileIDs(_ posts: [MMPost]) -> [String] {
        Array(Set(posts.map(\.userId).filter { !$0.isEmpty })).sorted()
    }

    static func channelIDs(_ posts: [MMPost]) -> [String] {
        Array(Set(posts.map(\.channelId).filter { !$0.isEmpty })).sorted()
    }
}
