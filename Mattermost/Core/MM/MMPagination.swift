// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0,
// `ios/Gekidou/Sources/Gekidou/Networking/Network+Posts.swift` (the `page`/`per_page`,
// `since` and `fromCreateAt`/`direction` query shapes) and
// `app/utils/post_list/index.ts` (list ordering). Own implementation per docs/path-b-adr.md §3.

import Foundation

/// One page request against the post-list endpoints.
///
/// Mattermost pages a channel's posts three ways and the client must not mix them up:
///
///  - **`page` / `per_page`** — offset paging from the newest post (`page=0` is the newest page).
///  - **`before=<post_id>`** — the page *older* than that post (scrolling up in a channel).
///  - **`after=<post_id>`** — the page *newer* than that post (catching up after a gap).
///
/// `GET /channels/{id}/posts` with `before`/`after` returns `order` (newest → oldest for a
/// channel), plus `prev_post_id` / `next_post_id` cursors. `MMPostPage.nextOlderPage(from:)`
/// reads the cursor out of the response instead of the caller guessing an index, which is the
/// bug this type exists to prevent (a new post arriving mid-scroll must not shift the window).
struct MMPostPage: Equatable, Sendable {
    enum Cursor: Equatable, Sendable {
        case page(Int)
        case before(String)
        case after(String)
        case since(Int64)
    }

    var cursor: Cursor
    var perPage: Int

    init(cursor: Cursor = .page(0), perPage: Int = 60) {
        self.cursor = cursor
        self.perPage = max(1, perPage)
    }

    static func first(perPage: Int = 60) -> MMPostPage {
        MMPostPage(cursor: .page(0), perPage: perPage)
    }

    /// `per_page` is always sent (the server defaults to 60 and silently truncates above 200, so
    /// clamping here keeps a caller from asking for something it will not get).
    var queryItems: [URLQueryItem] {
        var items = [URLQueryItem(name: "per_page", value: String(min(perPage, 200)))]
        switch cursor {
        case .page(let page):
            items.insert(URLQueryItem(name: "page", value: String(max(0, page))), at: 0)
        case .before(let id):
            items.insert(URLQueryItem(name: "before", value: id), at: 0)
        case .after(let id):
            items.insert(URLQueryItem(name: "after", value: id), at: 0)
        case .since(let millis):
            items.insert(URLQueryItem(name: "since", value: String(millis)), at: 0)
        }
        return items
    }

    /// The page older than what `list` returned, or `nil` when the server says there is none.
    ///
    /// For a channel page (`order` newest → oldest) the oldest delivered post id is the cursor.
    /// `has_next == false` is authoritative; when the server did not send `has_next`, an empty
    /// page and an exhausted page are indistinguishable, so an empty `order` also ends paging.
    func nextOlderPage(from list: MMPostList) -> MMPostPage? {
        if let hasNext = list.hasNext, hasNext == false { return nil }
        guard let oldest = list.order.last, !oldest.isEmpty else { return nil }
        return MMPostPage(cursor: .before(oldest), perPage: perPage)
    }

    /// The page newer than what `list` returned (catching up after a reconnect gap).
    func nextNewerPage(from list: MMPostList) -> MMPostPage? {
        if let hasNext = list.hasNext, hasNext == false { return nil }
        guard let newest = list.order.first, !newest.isEmpty else { return nil }
        return MMPostPage(cursor: .after(newest), perPage: perPage)
    }
}
