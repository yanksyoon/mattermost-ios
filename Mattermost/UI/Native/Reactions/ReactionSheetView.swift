// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/reactions/index.tsx + reactions.tsx (a sheet with an emoji bar over a reactors
//        list, the bar's order held stable while the sheet is open), reactions/reactors_list/index.tsx
//        (one row per reactor, fetching only the profiles it does not already hold),
//        reactions/reactors_list/reactor/reactor.tsx (the row itself).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §14.
//
// Identifiers an XCUITest can rely on:
//   reactions.sheet               the sheet
//   reactions.tab.<emoji>         one emoji in the bar (selects whose reactors are listed)
//   reactions.count.<emoji>       the count drawn on that tab
//   reactionReactor.<userID>      one reactor row (label carries the name, and "(you)" for mine)
//   reactions.close               dismiss

import SwiftUI

struct ReactionSheetView<Source: ReactionTarget & ObservableObject>: View {
    @ObservedObject var source: Source
    let postID: String
    /// The pill that was long-pressed: the sheet opens on it.
    let initialEmoji: String
    var emojiCatalogue: EmojiCatalogue?
    var system: SystemEmojiCatalogue = .shared
    @Environment(\.dismiss) private var dismiss

    /// The bar's order, held stable while the sheet is open (upstream `getSortedReactions`).
    @State private var order: [String] = []
    @State private var selected: String = ""

    private var post: MMPost? { source.post(id: postID) }

    /// Every alias group on this post, in server order, as the pane currently holds them.
    private var currentPills: [String] {
        guard let post else { return [] }
        var names: [String] = []
        for value in post.metadata?["reactions"]?.arrayValue ?? [] {
            guard let reaction = try? MMRawJSON(value).decode(MMReaction.self),
                  !reaction.emojiName.isEmpty else { continue }
            names.append(reaction.emojiName)
        }
        return ReactionAliases.groups(names, system: system).map(\.key)
    }

    private var reactors: [ReactionReactor] {
        guard let post else { return [] }
        let ids = ReactionReactors.userIDs(forPillEmoji: selected, in: post, system: system)
        return ReactionReactors.rows(userIDs: ids,
                                     myUserID: source.myUserID,
                                     users: source.reactionUserProfiles)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if order.isEmpty {
                    emptyState
                } else {
                    emojiBar
                    Divider()
                    list
                }
            }
            .navigationTitle("Reactions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("reactions.close")
                }
            }
            .accessibilityIdentifier("reactions.sheet")
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            order = ReactionSheetOrder.merged(previous: order, current: currentPills)
            if selected.isEmpty { selected = order.contains(initialEmoji) ? initialEmoji
                                                                         : (order.first ?? "") }
            loadMissingProfiles()
        }
        // A reaction that arrives over the socket while the sheet is up must be visible without
        // closing it — but it must not move the tab the reader is on.
        .onChange(of: currentPills) { _, current in
            order = ReactionSheetOrder.merged(previous: order, current: current)
            if !order.contains(selected) { selected = order.first ?? "" }
            loadMissingProfiles()
        }
    }

    private var emojiBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(order, id: \.self) { name in
                    let summary = summary(for: name)
                    Button {
                        selected = name
                    } label: {
                        HStack(spacing: 3) {
                            EmojiGlyph(name: name, emoji: emojiCatalogue)
                            Text("\(summary.count)")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(name == selected
                                    ? Color.accentColor.opacity(0.18)
                                    : Color(.secondarySystemBackground),
                                    in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(name) \(summary.count)")
                    .accessibilityIdentifier("reactions.tab.\(name)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(reactors) { reactor in
                    HStack(spacing: 10) {
                        PostAvatarView(author: PostAuthor(id: reactor.userID,
                                                          username: reactor.username,
                                                          displayName: reactor.displayName),
                                       size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(reactor.label)
                                .font(.system(size: 14, weight: .medium))
                                .accessibilityIdentifier("reactionReactor.\(reactor.userID).name")
                            if !reactor.detail.isEmpty {
                                Text(reactor.detail)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel([reactor.label, reactor.detail]
                        .filter { !$0.isEmpty }.joined(separator: ", "))
                    .accessibilityIdentifier("reactionReactor.\(reactor.userID)")
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "face.smiling")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("No reactions left")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("reactions.empty")
    }

    private func summary(for name: String) -> PostReactionSummary {
        guard let post else {
            return PostReactionSummary(emojiName: name, count: 0, includesMe: false, userIds: [])
        }
        let ids = ReactionReactors.userIDs(forPillEmoji: name, in: post, system: system)
        let includesMe = source.myUserID.map { ids.contains($0) } ?? false
        return PostReactionSummary(emojiName: name, count: ids.count,
                                   includesMe: includesMe, userIds: ids)
    }

    private func loadMissingProfiles() {
        let ids = reactors.map(\.id).filter { source.reactionUserProfiles[$0] == nil }
        guard !ids.isEmpty else { return }
        Task { await source.loadReactionProfiles(for: ids) }
    }
}
