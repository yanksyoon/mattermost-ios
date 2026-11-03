// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/global_drafts/index.tsx + global_drafts_list.tsx (the rows, tap to open,
//        swipe/trailing delete), global_drafts/empty.tsx.
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §20; no
// upstream source copied.
//
// A row is deliberately **not** a `Button` wrapping a second `Button`: T50 measured a control sharing
// a `Form` row with another one swallowing its tap, and the same shape in a `List` row is the same
// trap. The row is an `HStack` with a tap gesture (`.isButton` for VoiceOver) and the delete control
// is its own `Button` beside it, so both are addressable and both work.

import SwiftUI

/// The global drafts list (S26): every draft the local table holds, for this server and team.
struct GlobalDraftsView: View {
    @StateObject private var model: GlobalDraftsViewModel
    /// Open the row's conversation (channel composer, or the thread pane for a thread draft).
    let onOpen: (GlobalDraftRow) -> Void
    /// Drop a warm composer's in-memory copy when the store row is deleted.
    let onDiscard: (GlobalDraftRow) -> Void

    /// One clock for the whole sheet, so every row's "5 min ago" is relative to the same moment and
    /// two rows saved a second apart cannot disagree about it.
    private let now: Date

    @Environment(\.dismiss) private var dismiss

    init(teamID: String?,
         drafts: ComposerDraftStoring,
         labels: [String: DraftChannelLabel],
         onOpen: @escaping (GlobalDraftRow) -> Void,
         onDiscard: @escaping (GlobalDraftRow) -> Void,
         now: Date = Date()) {
        _model = StateObject(wrappedValue: GlobalDraftsViewModel(teamID: teamID,
                                                                drafts: drafts,
                                                                labels: labels))
        self.onOpen = onOpen
        self.onDiscard = onDiscard
        self.now = now
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.phase == .loading && model.rows.isEmpty {
                    ProgressView("Loading drafts…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("globalDrafts.loading")
                } else if model.rows.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Drafts")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("globalDrafts.close")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let error = model.actionError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.thinMaterial)
                        .accessibilityIdentifier("globalDrafts.error")
                }
            }
            .task { await model.load() }
        }
        // `.contain` after the identifier: a bare identifier on a container overwrites its
        // descendants' identifiers (T35's composer lesson), so the rows would all read
        // `globalDrafts` and none of them could be tapped.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("globalDrafts")
    }

    // MARK: Rows

    private var list: some View {
        List {
            ForEach(model.rows) { row in
                rowView(row)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 8))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            delete(row)
                        } label: {
                            Label("Delete draft", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.plain)
        .refreshable { await model.load() }
        .accessibilityIdentifier("globalDrafts.list")
    }

    private func rowView(_ row: GlobalDraftRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            rowContent(row)
            Spacer(minLength: 0)
            deleteButton(row)
        }
    }

    /// The tappable part of the row: one accessibility element (glyph + three lines) with one
    /// sentence, which is also what a VoiceOver reader hears. It wraps **only** the content, so the
    /// delete control beside it stays its own element and can be addressed on its own — a row that
    /// combined *its* children too would swallow the delete button (T50's shared-row trap).
    private func rowContent(_ row: GlobalDraftRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: glyph(row))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.scaled(15, weight: .medium))
                    .mmLineLimit(1)
                Text(row.snippet)
                    .font(.scaled(14))
                    .foregroundStyle(.secondary)
                    .mmLineLimit(2)
                Text(subtitle(row))
                    .font(.scaled(12))
                    .foregroundStyle(.tertiary)
                    .mmLineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { onOpen(row) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(row.accessibilityLabel(now: now))
        .accessibilityIdentifier("globalDrafts.row.\(row.id)")
    }

    private func deleteButton(_ row: GlobalDraftRow) -> some View {
        Button {
            delete(row)
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Delete draft in \(row.title)")
        .accessibilityIdentifier("globalDrafts.row.\(row.id).delete")
    }

    private func glyph(_ row: GlobalDraftRow) -> String {
        if row.isThreadDraft { return "text.bubble" }
        return row.channelLabel?.kind?.symbolName ?? "questionmark.circle"
    }

    /// "Thread draft · Edited 4 min ago", and the unlisted marker where it matters.
    private func subtitle(_ row: GlobalDraftRow) -> String {
        var parts = [row.kindCopy]
        if row.availability == .notListed { parts.append("Channel not in this team's list") }
        parts.append(row.editedCopy(now: now))
        return parts.joined(separator: " · ")
    }

    private func delete(_ row: GlobalDraftRow) {
        Task { await model.delete(row, onDiscard: onDiscard) }
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.and.pencil")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No drafts")
                .font(.headline)
            Text("A message you have typed but not sent appears here — even from a channel that is "
                 + "no longer in your list.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("globalDrafts.empty")
    }
}
