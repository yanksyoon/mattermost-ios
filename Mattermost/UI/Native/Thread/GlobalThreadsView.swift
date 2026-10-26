// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/global_threads/global_threads.tsx (the screen),
//        app/screens/global_threads/threads_list/threads_list.tsx (the paged list, `onEndReached`),
//        app/screens/global_threads/threads_list/thread/thread.tsx (a row: root author, preview,
//        footer with reply count), app/screens/global_threads/threads_list/header/index.tsx (the
//        All / Unreads tabs), app/screens/global_threads/threads_list/empty_state.tsx.
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §13; no
// upstream source copied.

import SwiftUI

/// The Threads tab: every thread this account follows in the current team.
struct GlobalThreadsPaneContent: View {
    let server: ServerConfig
    @ObservedObject var navigation: NativeNavigation

    @EnvironmentObject private var threads: ThreadCoordinator

    @State private var model: GlobalThreadsViewModel?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let model {
                GlobalThreadsListView(model: model, navigation: navigation)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("globalThreads.loading")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nativeThreadsList")
        .task(id: navigation.location.teamID) {
            let resolved = threads.globalModel(for: server, teamID: navigation.location.teamID ?? "")
            model = resolved
            await resolved.load(ifNeeded: true)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.headline)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Threads")
                .font(.headline)
                .accessibilityIdentifier("globalThreads.title")
            Spacer(minLength: 8)
            if let model {
                Text(model.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("globalThreads.subtitle")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}

/// The two-tab, paged list of followed threads.
struct GlobalThreadsListView: View {
    @ObservedObject var model: GlobalThreadsViewModel
    @ObservedObject var navigation: NativeNavigation

    var body: some View {
        VStack(spacing: 0) {
            Picker("Threads", selection: tabBinding) {
                ForEach(GlobalThreadsTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .accessibilityIdentifier("globalThreads.tabs")

            Group {
                switch model.phase {
                case .idle, .loading:
                    loadingState
                case .failed(let message):
                    failureState(message)
                case .loaded:
                    if model.rows.isEmpty {
                        emptyState
                    } else {
                        list
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .refreshable { await model.reload() }
    }

    private var tabBinding: Binding<GlobalThreadsTab> {
        Binding(get: { model.tab },
                set: { newTab in Task { await model.select(tab: newTab) } })
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.rows) { row in
                    Button {
                        open(row)
                    } label: {
                        GlobalThreadRowView(row: row)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("globalThreads.row.\(row.threadID)")
                    .onAppear {
                        // Page in the next block when the last row appears — upstream's
                        // `onEndReached`, without a scroll-offset subscription.
                        guard row.threadID == model.rows.last?.threadID else { return }
                        Task { await model.loadMore() }
                    }
                    Divider().padding(.leading, 56)
                }
                if model.isLoadingMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .accessibilityIdentifier("globalThreads.loadingMore")
                } else if let error = model.loadMoreError {
                    HStack(spacing: 8) {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Try again") {
                            Task { await model.loadMore() }
                        }
                        .font(.caption.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .accessibilityIdentifier("globalThreads.loadMoreError")
                } else if !model.hasMore {
                    Text("You're all caught up.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .accessibilityIdentifier("globalThreads.endOfList")
                }
            }
        }
        .accessibilityIdentifier("globalThreads.postList")
    }

    /// Open a thread on top of the channel it belongs to, so Back returns to that conversation.
    private func open(_ row: GlobalThreadRow) {
        let request = NativeChannelRequest(serverID: navigation.location.serverID,
                                           teamID: navigation.location.teamID,
                                           teamName: navigation.location.teamName,
                                           channelID: row.channelID,
                                           channelName: nil,
                                           postID: row.threadID)
        navigation.openThreads(request)
    }

    // MARK: States

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Loading threads…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("globalThreads.loadingState")
    }

    private func failureState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.bubble")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Try again") {
                Task { await model.reload() }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("globalThreads.retry")
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("globalThreads.failed")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(model.tab == .unreads ? "No unread threads" : "No followed threads yet")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Follow a thread from its reply line to see it here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("globalThreads.empty")
    }
}

/// One row: who posted, what they said, how many replies, and whether it is unread.
struct GlobalThreadRowView: View {
    let row: GlobalThreadRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PostAvatarView(author: row.author, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.isMine ? "You" : row.author.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(row.timeLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(row.preview)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    if let count = ThreadDerivation.replyLabel(row.replyCount) {
                        Label(count, systemImage: "arrowshape.turn.up.left")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if row.isUrgent {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .accessibilityLabel("Urgent")
                    }
                    Spacer(minLength: 0)
                }
            }
            if let badge = row.unread.accessibilityLabel {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)
                    .accessibilityLabel(badge)
                    .accessibilityIdentifier("globalThreads.unread.\(row.threadID)")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
