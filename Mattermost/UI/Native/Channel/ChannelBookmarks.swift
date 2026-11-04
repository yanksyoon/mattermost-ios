// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/components/channel_bookmarks/channel_bookmarks.tsx (the strip: a horizontal list, 48pt,
//        `channel_header.bookmarks.list`, null when there is nothing to draw),
//        app/components/channel_bookmarks/channel_bookmark/channel_bookmark.tsx (one chip:
//        `channel_bookmark.<id>`, a link opens its `link_url`),
//        app/screens/channel/header/bookmarks.tsx (the bar under the navigation header),
//        app/screens/channel/header/header.tsx (`showBookmarkBar = isBookmarksEnabled &&
//        hasBookmarks && shouldRenderBookmarks`),
//        app/client/rest/channel_bookmark.ts (`getChannelBookmarksForChannel` →
//        `GET /channels/{id}/bookmarks`, answering an **array** of `ChannelBookmarkWithFileInfo`).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §17; no
// upstream source copied. The model/service/view split is this repo's own (component-map.md §1),
// matching `ChannelFilesViewModel` and `ChannelInfoViewModel`.
//
// Placement (owner decision on t_05caa678, matching header.tsx:145): the bar belongs to the
// **channel header**, directly under the title row and above the post list. Channel info does not
// list bookmarks — upstream has one place, so this app has one place.
//
// **A 404 is not an error state, it is "this server has no bookmarks".** Measured on the pinned
// 9.11.19 Team Edition fixture (`scripts/t52_channel_probe.py`, re-measured for this card):
// `GET /channels/{id}/bookmarks` answers 404 `api.context.404.app_error` because the route does not
// exist in that build. So the fetch failure rule is closed: whatever goes wrong, the bar is simply
// absent and takes zero height. It never draws an error, a spinner, or an empty box, and it never
// decides whether the rest of the pane exists (the defect class the card names for the sheet's own
// fetch: a missing feature on the server must not look like a broken screen).
//
// Order: the server's own. The endpoint returns the bookmarks sorted by `sort_order` (upstream's
// client sorts the same way); this file keeps that order and does not re-sort by name or time, so a
// reader who arranged their bar sees the arrangement they made.

import SwiftUI

// MARK: - Wire shape

/// One channel bookmark, as `GET /channels/{id}/bookmarks` answers it.
///
/// Only the fields the bar draws, plus `sort_order` for the ordering rule and `delete_at` so a row
/// the server has already tombstoned is dropped rather than drawn.
struct MMChannelBookmark: Decodable, Equatable, Sendable, Identifiable {
    var id: String
    var channelID: String
    var displayName: String
    var type: String
    var sortOrder: Int64
    var linkURL: String
    var imageURL: String
    var emoji: String
    var fileID: String
    var deleteAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, type, emoji
        case channelID = "channel_id"
        case displayName = "display_name"
        case sortOrder = "sort_order"
        case linkURL = "link_url"
        case imageURL = "image_url"
        case fileID = "file_id"
        case deleteAt = "delete_at"
    }

    init(id: String,
         channelID: String = "",
         displayName: String = "",
         type: String = "link",
         sortOrder: Int64 = 0,
         linkURL: String = "",
         imageURL: String = "",
         emoji: String = "",
         fileID: String = "",
         deleteAt: Int64 = 0) {
        self.id = id
        self.channelID = channelID
        self.displayName = displayName
        self.type = type
        self.sortOrder = sortOrder
        self.linkURL = linkURL
        self.imageURL = imageURL
        self.emoji = emoji
        self.fileID = fileID
        self.deleteAt = deleteAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `id` is the only field a row cannot be drawn without; the rest degrade to "" so one odd
        // field on the server never blanks the whole bar.
        id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? ""
        channelID = (try? container.decodeIfPresent(String.self, forKey: .channelID)) ?? ""
        displayName = (try? container.decodeIfPresent(String.self, forKey: .displayName)) ?? ""
        type = (try? container.decodeIfPresent(String.self, forKey: .type)) ?? "link"
        sortOrder = (try? container.decodeIfPresent(Int64.self, forKey: .sortOrder)) ?? 0
        linkURL = (try? container.decodeIfPresent(String.self, forKey: .linkURL)) ?? ""
        imageURL = (try? container.decodeIfPresent(String.self, forKey: .imageURL)) ?? ""
        emoji = (try? container.decodeIfPresent(String.self, forKey: .emoji)) ?? ""
        fileID = (try? container.decodeIfPresent(String.self, forKey: .fileID)) ?? ""
        deleteAt = (try? container.decodeIfPresent(Int64.self, forKey: .deleteAt)) ?? 0
    }
}

// MARK: - Pure derivation

/// What the bar draws, from what the server answered. Pure: every rule below is unit-testable
/// without a server (`MattermostTests/T05ChannelBookmarksTests.swift`).
enum ChannelBookmarksDerivation {

    /// The bar's rows, in the server's order.
    ///
    /// * a tombstoned row (`delete_at != 0`) is not drawn;
    /// * a row with no id is not drawn (it could not be identified, tapped or de-duplicated);
    /// * the order is `sort_order` ascending — the server's arrangement, which the client must not
    ///   replace with an alphabetical one;
    /// * the sort is **stable** on ties: a server that answers equal sort orders keeps its own
    ///   arrival order (Swift's `sorted` is not stable, so the index is the tiebreaker).
    static func rows(from bookmarks: [MMChannelBookmark]) -> [MMChannelBookmark] {
        bookmarks
            .filter { $0.deleteAt == 0 && !$0.id.isEmpty }
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.sortOrder != rhs.element.sortOrder {
                    return lhs.element.sortOrder < rhs.element.sortOrder
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// The chip's label: the name the reader gave it, and never an id — an unnamed bookmark falls
    /// back to a word, the same rule the member list uses for a missing profile.
    static func label(for bookmark: MMChannelBookmark) -> String {
        let name = bookmark.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return bookmark.type == "file" ? "File" : "Bookmark"
    }

    /// The chip's glyph. Upstream draws the bookmark's own image or emoji when it has one; this bar
    /// draws a type glyph, which is honest without pretending to read an emoji name the client has
    /// no catalogue for here.
    static func glyph(for bookmark: MMChannelBookmark) -> String {
        bookmark.type == "file" ? "paperclip" : "link"
    }

    /// Where a chip's tap goes, or `nil` when this bar cannot open it (a file bookmark with no link:
    /// upstream opens its gallery, which is T38's preview and not this card).
    static func url(for bookmark: MMChannelBookmark) -> URL? {
        let raw = bookmark.linkURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    /// Whether a failure means "this server does not have the bookmarks feature" rather than a
    /// transport problem. Only used for the diagnostics line: **the bar is absent either way**.
    static func meansUnsupported(_ error: Error) -> Bool {
        (error as? MMError)?.httpStatus == 404
    }
}

// MARK: - Service

/// What the bar needs from one server: one read.
@MainActor
protocol ChannelBookmarkServing: AnyObject {
    /// `GET /channels/{id}/bookmarks`. Throws `MMError.notFound` on a build without the route.
    func bookmarks(channelID: String) async throws -> [MMChannelBookmark]
}

/// The production implementation: the session's `APIClient`, resolved per call (the same reason
/// `SessionChannelInfoService` does — a service built before the session restored is not a
/// permanently signed-out one).
@MainActor
final class SessionChannelBookmarkService: ChannelBookmarkServing {
    private let resolve: () -> APIClient?

    init(resolve: @escaping () -> APIClient?) {
        self.resolve = resolve
    }

    func bookmarks(channelID: String) async throws -> [MMChannelBookmark] {
        guard let client = resolve() else { throw MMError.notSignedIn }
        return try await client.channelBookmarks(channelID: channelID)
    }
}

extension APIClient {
    /// `GET /channels/{channel_id}/bookmarks` — an **array**, no paging.
    ///
    /// No ETag: the bar is read once per pane appearance and a stale 304 replay would pin it to the
    /// list it had before the reader added one on another client.
    func channelBookmarks(channelID: String) async throws -> [MMChannelBookmark] {
        try await get([MMChannelBookmark].self,
                      path: "/channels/\(channelID)/bookmarks",
                      useETag: false)
    }
}

// MARK: - Model

/// The bar's state for one channel.
///
/// `phase` exists so "not loaded yet" is distinguishable from "loaded and empty" in a test and in
/// the diagnostics line; **the view draws the same thing for every phase except `.loaded` with rows**
/// (nothing at all), which is the card's rule: a 404, a timeout and an empty list must be
/// indistinguishable on screen or the header and post list pay for a feature the server may not have.
@MainActor
final class ChannelBookmarksViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case loading
        /// The server answered; the rows are `bookmarks` (possibly empty).
        case loaded
        /// The server refused or could not be reached — no bar, no message.
        case unavailable
    }

    let channelID: String
    private let service: ChannelBookmarkServing

    @Published private(set) var bookmarks: [MMChannelBookmark] = []
    @Published private(set) var phase: Phase = .idle
    /// One line for the diagnostics/log surface: what the fetch did and why the bar is absent.
    @Published private(set) var outcome: String = "bookmarks=idle"

    /// How many fetches ran (tests: "the pane's appearance is one request, not one per body pass").
    private(set) var loadCount = 0
    /// The fetch in flight, so two callers that arrive together share it.
    ///
    /// Measured on the live suite (t_05caa678): SwiftUI runs the pane's `.task(id:)` more than once
    /// while the post list is settling, and two overlapping `load()` calls were two requests
    /// (`bookmarks_requests: 2` on the fixture proxy). The **unstructured** inner task is also what
    /// makes the answer survive the caller being cancelled mid-flight — a view that goes away
    /// between two appearances must not leave the bar at `.loading` for ever.
    private var inFlight: Task<Void, Never>?

    init(channelID: String, service: ChannelBookmarkServing) {
        self.channelID = channelID
        self.service = service
    }

    /// Whether the bar is drawn. The **only** condition: rows exist. There is no spinner state and
    /// no error state to draw, by design.
    var isVisible: Bool { phase == .loaded && !bookmarks.isEmpty }

    /// The rows' ids in draw order (a test asserts the server's order survives).
    var rowIDs: [String] { bookmarks.map(\.id) }

    /// Fetch once per appearance.
    ///
    /// Never throws: the caller is a `.task` on the pane, and a feature this server does not have
    /// must not surface as a failure anywhere else. A call that arrives while another is in flight
    /// joins it (one request); a call after a successful or refused answer is a no-op (a
    /// re-appearance of the pane keeps the bar it already has, or keeps its absence).
    func load(ifNeeded: Bool = true) async {
        if let running = inFlight {
            await running.value
            if ifNeeded { return }
        }
        if ifNeeded, phase == .loaded || phase == .unavailable { return }
        // Unstructured on purpose: a cancelled view must not cancel the fetch and leave the bar in
        // `.loading`, because the next appearance would then be the only thing that could finish it.
        let task = Task { await self.performLoad() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func performLoad() async {
        loadCount += 1
        if phase == .idle { phase = .loading }
        do {
            let answer = try await service.bookmarks(channelID: channelID)
            let rows = ChannelBookmarksDerivation.rows(from: answer)
            bookmarks = rows
            phase = .loaded
            outcome = "bookmarks=loaded count=\(rows.count)"
            MMLog.info("MMChannelBookmarks", "\(outcome) channel=\(Self.short(channelID))")
        } catch {
            // Closed rule: nothing is drawn and nothing is retried in the background. The reason is
            // kept in `outcome` for a log line and a test, not for the screen.
            bookmarks = []
            phase = .unavailable
            let status = (error as? MMError)?.httpStatus.map(String.init) ?? "none"
            let kind = ChannelBookmarksDerivation.meansUnsupported(error) ? "unsupported" : "failed"
            outcome = "bookmarks=\(kind) status=\(status)"
            MMLog.info("MMChannelBookmarks", "\(outcome) channel=\(Self.short(channelID))")
        }
    }

    private static func short(_ id: String) -> String { String(id.prefix(8)) }
}

// MARK: - View

/// The bookmarks bar: one horizontal row of chips directly under the channel header.
///
/// nil-height when there is nothing to draw — the caller places it unconditionally and the header
/// and post list must be untouched whether the server has bookmarks, has none, or has no route.
struct ChannelBookmarksBar: View {
    @ObservedObject var model: ChannelBookmarksViewModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if model.isVisible {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.bookmarks) { bookmark in
                            chip(bookmark)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: ChannelBookmarksBar.height, alignment: .center)
                }
                .accessibilityIdentifier("channelBookmarks.bar")
                Divider()
            }
        }
    }

    /// Upstream draws the strip at 48pt (`contentContainerStyle: {height: 48}`).
    static let height: CGFloat = 48

    @ViewBuilder
    private func chip(_ bookmark: MMChannelBookmark) -> some View {
        let label = ChannelBookmarksDerivation.label(for: bookmark)
        let glyph = ChannelBookmarksDerivation.glyph(for: bookmark)
        if let url = ChannelBookmarksDerivation.url(for: bookmark) {
            Button {
                openURL(url)
            } label: {
                chipLabel(label, glyph: glyph)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("channelBookmark.\(bookmark.id)")
            .accessibilityLabel(label)
            .accessibilityHint("Opens this bookmark")
        } else {
            // A file bookmark has no destination this bar can open (its gallery is T38's preview).
            // It is still drawn — the reader can see it is there — but it is not a button, because a
            // button that does nothing is worse than a label.
            chipLabel(label, glyph: glyph)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("channelBookmark.\(bookmark.id)")
                .accessibilityLabel(label)
        }
    }

    private func chipLabel(_ label: String, glyph: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: glyph)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(label)
                .font(.subheadline)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.12), in: Capsule())
    }
}
