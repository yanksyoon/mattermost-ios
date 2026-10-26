// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/emoji_picker/index.tsx (a bottom sheet whose pick calls back and closes),
//        app/screens/emoji_picker/picker/picker.tsx (search bar over sections; a non-empty term
//        switches the list to filtered results), app/screens/emoji_picker/picker/sections/* (a
//        section header per category, a grid of cells), app/components/emoji_category_bar/*
//        (the horizontal category strip).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §14.
//
// Identifiers an XCUITest can rely on (also listed in docs/t37-build-note.md):
//   emojiPicker                 the sheet
//   emojiPicker.search          the search field
//   emojiPicker.close           dismiss
//   emojiPicker.category.<id>   a category-strip button (`recent`, `custom`, `flags`, …)
//   emojiPicker.emoji.<name>    a system emoji cell (also inside search results)
//   emojiPicker.custom.<name>   a server custom emoji cell
//   emojiPicker.recent.<name>   a recently-used cell
//   emojiPicker.empty           "nothing matches" copy

import SwiftUI

struct EmojiPickerView: View {
    /// Owned by the view, not passed in as an observed object: the sheet body is re-evaluated
    /// whenever the pane redraws (a socket post, a reaction), and a view model created inline in that
    /// closure would be rebuilt each time — losing the search text while the reader types it.
    @StateObject private var model: EmojiPickerViewModel
    /// The server's custom emoji, so a custom cell can draw its image (T34's catalogue).
    var emoji: EmojiCatalogue?
    @Environment(\.dismiss) private var dismiss

    @State private var scrolledSection: String?

    init(model: EmojiPickerViewModel, emoji: EmojiCatalogue? = nil) {
        _model = StateObject(wrappedValue: model)
        self.emoji = emoji
    }

    private let columns = [GridItem(.adaptive(minimum: 44, maximum: 56), spacing: 2)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                searchField
                categoryStrip
                Divider()
                content
            }
            .padding(.top, 8)
            .navigationTitle(model.mode == .reaction ? "Add a reaction" : "Emoji")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("emojiPicker.close")
                }
            }
            .accessibilityIdentifier("emojiPicker")
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            TextField("Search emoji", text: Binding(get: { model.search },
                                                   set: { model.search = $0 }))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityIdentifier("emojiPicker.search")
            if !model.search.isEmpty {
                Button {
                    model.search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("emojiPicker.search.clear")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
    }

    // MARK: - Category strip

    private var categoryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(model.sections) { section in
                    Button {
                        scrolledSection = section.id
                    } label: {
                        Text(Self.stripLabel(for: section))
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(scrolledSection == section.id
                                        ? Color.accentColor.opacity(0.18)
                                        : Color.clear,
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                    // Only a *section* is addressable from the strip; a search result list is not a
                    // category, so it gets no chip.
                    .accessibilityIdentifier(section.kind == .search
                                             ? "emojiPicker.category.search"
                                             : "emojiPicker.category.\(section.id)")
                }
            }
            .padding(.horizontal, 12)
        }
        .opacity(model.sections.contains(where: { $0.kind == .search }) ? 0.4 : 1)
    }

    private static func stripLabel(for section: EmojiPickerSection) -> String {
        switch section.kind {
        case .recent: return "Recent"
        case .custom: return "Custom"
        case .search: return "Results"
        case .system: return section.title
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if model.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(.tertiary)
                Text("No emoji match “\(model.search)”")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("emojiPicker.empty")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6, pinnedViews: [.sectionHeaders]) {
                        ForEach(model.sections) { section in
                            Section {
                                LazyVGrid(columns: columns, spacing: 2) {
                                    ForEach(section.items) { item in
                                        cell(item, in: section)
                                    }
                                }
                                .padding(.horizontal, 8)
                            } header: {
                                Text(section.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                                    .background(Color(.systemBackground))
                            }
                            .id(section.id)
                        }
                    }
                    .padding(.bottom, 12)
                }
                .onChange(of: scrolledSection) { _, target in
                    guard let target else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
            }
        }
    }

    private func cell(_ item: EmojiPickerItem, in section: EmojiPickerSection) -> some View {
        Button {
            model.pick(item)
        } label: {
            ZStack {
                if let character = item.character {
                    Text(character).font(.system(size: 26))
                } else {
                    // A custom emoji is the server's image; until those bytes land this draws the
                    // shortcode, exactly like a post body does (T34).
                    EmojiGlyph(name: item.name, emoji: emoji, size: 26)
                        .frame(width: 32, height: 32)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.accessibilityLabel)
        .accessibilityIdentifier(identifier(for: item, in: section))
    }

    private func identifier(for item: EmojiPickerItem, in section: EmojiPickerSection) -> String {
        // The section decides the identifier prefix, so a test can say *where* it found the emoji:
        // the recent row and the full grid are different assertions.
        switch section.kind {
        case .recent: return "emojiPicker.recent.\(item.name)"
        case .custom: return "emojiPicker.custom.\(item.name)"
        case .search, .system: return "emojiPicker.emoji.\(item.name)"
        }
    }
}
