// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/channel_files/ (the list, its paging and its empty state),
//        app/actions/remote/file.ts (`getFilesForChannel`-equivalent search), app/client/rest/files.ts.
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §15; no
// upstream source copied. The view-model shape is this repo's own (component-map.md §1): a generation
// guard, a service seam, and every rule kept out of the view.
//
// The route that answers this list is measured in `ChannelFilesModels.swift`'s header: there is no
// `GET /channels/{id}/files`, and `POST /teams/{tid}/files/search` with `in:<channel-name>` is the
// server's own channel filter. Paging follows the server's `next_file_info_id` cursor; on the pinned
// 9.11.19 fixture that cursor is always empty because the server answered every match in one page
// (measured with per_page 2/5/10/20), so the list is one page there and the code still follows a
// cursor a paging server would send.

import Foundation
import Combine

/// One channel's files, newest first, in pages.
@MainActor
final class ChannelFilesViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    let channelID: String
    let teamID: String
    /// The channel's URL name — the `in:` term the server's file search understands.
    let channelName: String

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var rows: [ChannelFileRow] = []
    @Published private(set) var hasMore = false
    @Published private(set) var isLoadingMore = false
    /// A failure that is not the first page's (so the list stays on screen and says what failed).
    @Published private(set) var banner: String?

    private let service: ChannelInfoServing
    private var page = 0
    private var cursor = ""
    private var generation = 0

    /// Page size asked of the server. It is a request, not a promise: the fixture ignores it.
    var pageSize: Int { 50 }

    init(channelID: String,
         teamID: String,
         channelName: String,
         service: ChannelInfoServing) {
        self.channelID = channelID
        self.teamID = teamID
        self.channelName = channelName
        self.service = service
    }

    func load() async {
        generation += 1
        let token = generation
        if phase != .ready { phase = .loading }
        banner = nil
        page = 0
        cursor = ""
        do {
            let result = try await service.channelFiles(teamID: teamID,
                                                        channelName: channelName,
                                                        page: 0,
                                                        perPage: pageSize)
            guard token == generation else { return }
            rows = ChannelFileDerivation.rows(from: result)
            hasMore = ChannelFileDerivation.hasMore(after: result)
            cursor = result.nextFileInfoID
            page = 1
            phase = .ready
        } catch {
            guard token == generation else { return }
            phase = .failed(Self.copy(for: error, fallback: "This channel's files could not be loaded."))
        }
    }

    /// The next page, when the server said there is one.
    func loadMore() async {
        guard hasMore, !isLoadingMore, phase == .ready else { return }
        guard !cursor.isEmpty else {
            // A server that says "more" but gives no cursor cannot be followed; stop asking rather
            // than request page after page of the same rows.
            hasMore = false
            return
        }
        isLoadingMore = true
        let token = generation
        defer { isLoadingMore = false }
        do {
            let result = try await service.channelFiles(teamID: teamID,
                                                        channelName: channelName,
                                                        page: page,
                                                        perPage: pageSize)
            guard token == generation else { return }
            let newRows = ChannelFileDerivation.rows(from: result)
            let known = Set(rows.map(\.id))
            rows.append(contentsOf: newRows.filter { !known.contains($0.id) })
            let nextCursor = result.nextFileInfoID
            // A cursor that has not moved would loop forever; an unchanged cursor ends the list.
            let moved = nextCursor != cursor
            cursor = nextCursor
            page += 1
            hasMore = ChannelFileDerivation.hasMore(after: result) && moved
            if newRows.isEmpty { hasMore = false }
        } catch {
            guard token == generation else { return }
            banner = Self.copy(for: error, fallback: "More files could not be loaded.")
        }
    }

    /// The image rows in the list, in list order — the gallery's pages when a thumbnail is tapped.
    var imageAttachments: [PostAttachment] {
        rows.filter(\.isInlineImage).map(\.attachment)
    }

    static func copy(for error: Error, fallback: String) -> String {
        MMErrorCopy.message(for: error,
                            offline: "You appear to be offline. Try again when you have a connection.",
                            timeout: "The server took too long to answer. Try again.",
                            unauthorized: "Your session has expired. Please sign in again.",
                            forbidden: "You do not have permission to look at this channel's files.",
                            notFound: "This channel no longer exists.",
                            rateLimited: "The server is busy. Try again shortly.",
                            fallback: fallback)
    }
}
