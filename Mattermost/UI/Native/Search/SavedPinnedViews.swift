// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: `app/screens/saved_posts/saved_posts.tsx` (the Saved tab: list, empty state, per-row unsave),
//        `app/screens/pinned_messages/pinned_messages.tsx` (the channel's pinned sheet, reached from
//        the channel header, with a per-row unpin).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §16; no
// upstream source copied.
//
// Both screens are the same list over a different source (`PostCollectionViewModel.Kind`), so they
// share one row view and one list body. What differs is the framing: Saved is a tab (S20), Pinned is
// a sheet over its channel (S21) because a pin is a property of one channel, not of the workspace.

import SwiftUI

// MARK: - Saved (S20)

/// The Saved tab: what the reader flagged, newest flag first, with an in-place unsave.
struct SavedPaneContent: View {
    let server: ServerConfig
    @ObservedObject var navigation: NativeNavigation

    @EnvironmentObject private var resolver: SurfaceModeResolver
    @EnvironmentObject private var coordinator: SearchCoordinator

    @State private var model: PostCollectionViewModel?

    private var teamID: String? {
        navigation.location.serverID == server.id ? navigation.location.teamID : nil
    }

    var body: some View {
        Group {
            if resolver.resolvedMode(for: .search) == .native {
                if let model {
                    PostCollectionView(model: model,
                                       server: server,
                                       navigation: navigation,
                                       teamID: teamID,
                                       listIdentifier: "savedPosts")
                } else {
                    ProgressView()
                        .accessibilityIdentifier("savedPosts.loading")
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "bookmark")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("Saved messages are rendered by the web app")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text("The lookup surfaces (search, saved, pinned) share one dual-render switch. "
                         + "Launch with `-surfaceMode search=native` to use the native list.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("savedWebFallback")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nativeSavedPane")
        .task(id: teamID) {
            guard resolver.resolvedMode(for: .search) == .native else { return }
            let resolved = coordinator.saved(for: server)
            resolved.teamID = teamID
            model = resolved
            await resolved.load(ifNeeded: true)
        }
    }
}

// MARK: - Pinned (S21)

/// The channel's pinned messages, presented as a sheet from the channel header.
struct PinnedPostsView: View {
    let server: ServerConfig
    let channelID: String
    let channelName: String?
    @ObservedObject var navigation: NativeNavigation
    /// Called after a successful pin/unpin so the channel's own row flips without a reload.
    var onPinnedChange: ((String, Bool) -> Void)? = nil
    var onClose: () -> Void

    @EnvironmentObject private var coordinator: SearchCoordinator
    @State private var model: PostCollectionViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    PostCollectionView(model: model,
                                       server: server,
                                       navigation: navigation,
                                       teamID: navigation.location.teamID,
                                       listIdentifier: "pinnedPosts")
                } else {
                    ProgressView()
                        .accessibilityIdentifier("pinnedPosts.loading")
                }
            }
            .navigationTitle(channelName.map { "Pinned in \($0)" } ?? "Pinned messages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onClose() }
                        .accessibilityIdentifier("pinnedClose")
                }
            }
        }
        .task {
            let resolved = coordinator.pinned(for: server, channelID: channelID)
            resolved.onPinnedChange = { postID, pinned in onPinnedChange?(postID, pinned) }
            model = resolved
            await resolved.load(ifNeeded: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pinnedSheet")
    }
}

// MARK: - The shared list

/// The list body both screens draw: rows from `PostRowModel`, an unsave/unpin button per row, the
/// empty state, the failure state, and a tap that jumps to the message.
struct PostCollectionView: View {
    @ObservedObject var model: PostCollectionViewModel
    let server: ServerConfig
    @ObservedObject var navigation: NativeNavigation
    var teamID: String?
    /// The `List`'s accessibility identifier (`savedPosts` / `pinnedPosts`).
    let listIdentifier: String

    var body: some View {
        Group {
            switch model.phase {
            case .idle, .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("\(listIdentifier).loading")
            case .failed(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text(message)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("\(listIdentifier).error")
                    Button("Try again") { Task { await model.reload() } }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("\(listIdentifier).retry")
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                if model.rows.isEmpty {
                    empty
                } else {
                    list
                }
            }
        }
        .onChange(of: model.pendingReload) { _, pending in
            // The socket said a post was saved on another device: this list does not hold it, so the
            // honest fix is a refetch rather than an invented row.
            guard pending else { return }
            model.consumePendingReload()
            Task { await model.reload() }
        }
    }

    private var list: some View {
        List {
            ForEach(model.rows) { row in
                HStack(alignment: .top, spacing: 6) {
                    Button {
                        open(row)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            // A saved row says which channel it came from: the tab is team-scoped and
                            // the same message text can exist in several channels (T39-AV F6).
                            if let channel = model.channelLabel(for: row.id) {
                                HStack(spacing: 4) {
                                    Image(systemName: "number")
                                        .font(.caption2)
                                        .accessibilityHidden(true)
                                    Text(channel)
                                        .font(.caption.weight(.semibold))
                                }
                                .foregroundStyle(.secondary)
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier("\(listIdentifier).channel.\(row.id)")
                            }
                            PostRowView(row: row,
                                        isExpanded: false,
                                        imageStore: nil,
                                        emoji: nil,
                                        onToggleExpanded: {})
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("\(listIdentifier).row.\(row.id)")

                    Button {
                        Task { await model.remove(row.id) }
                    } label: {
                        if model.busyPostIDs.contains(row.id) {
                            ProgressView()
                        } else {
                            Image(systemName: model.kind == .saved ? "bookmark.slash" : "pin.slash")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.busyPostIDs.contains(row.id))
                    .accessibilityLabel(model.kind.removeTitle)
                    .accessibilityIdentifier("\(listIdentifier).remove.\(row.id)")
                }
            }
            if model.hasMore {
                Button("Load more") { Task { await model.loadMore() } }
                    .accessibilityIdentifier("\(listIdentifier).loadMore")
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier(listIdentifier)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: model.kind == .saved ? "bookmark" : "pin")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(model.kind.emptyTitle)
                .font(.headline)
            Text(model.kind.emptyBody)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("\(listIdentifier).empty")
    }

    /// Same jump rule as the search results (a reply opens its thread).
    private func open(_ row: PostRowModel) {
        var request = NativeChannelRequest(serverID: server.id,
                                           teamID: teamID,
                                           channelID: row.post.channelId)
        switch SearchJump.target(for: row.post) {
        case .channel(let postID):
            request.postID = postID
            navigation.openChannel(request)
        case .thread(let rootID):
            request.postID = rootID
            navigation.openThreads(request)
        }
    }
}
