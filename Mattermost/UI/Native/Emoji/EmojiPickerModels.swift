// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/screens/emoji_picker/picker/picker.tsx (search strips the colons, sections vs filtered),
//        app/screens/emoji_picker/picker/sections/index.tsx (recent → custom → datasource categories,
//        `recent` omitted when empty), app/screens/emoji_picker/picker/filtered/* (search results),
//        app/utils/emoji/helpers.ts (`searchEmojis`, `compareEmojis`, `getEmojiFirstAlias`).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §14.
//
// The picker's two data sources, and why they are kept apart:
//  - the **system** set is bundled (`SystemEmojiCatalogue`): fixed, available offline, no I/O;
//  - the **custom** set is the server's (`EmojiCatalogue`, T34): `GET /emoji` + one image per name.
// A name in both is drawn as the system glyph (the server resolves the shortcode the same way), and a
// custom name the system table also knows still *sends* its own spelling — the server stores custom
// emoji names case-sensitively, and the picker must not rename one.
//
// Recents are the picker's first section and are recorded on a pick (upstream records a successful
// react; this records both a react and an insertion, because both are "used" to the reader).

import Foundation
import Combine

/// What a pick is for. The sheet is identical; what happens on tap is not.
enum EmojiPickerMode: String, Equatable, Sendable {
    /// Tapping toggles that reaction on a post.
    case reaction
    /// Tapping inserts `:name:` into the composer at the caret.
    case composer
}

/// One cell in the picker.
struct EmojiPickerItem: Equatable, Identifiable, Sendable {
    /// The canonical shortcode — what gets inserted, and what gets sent when reacting.
    var name: String
    /// The system glyph, when this is a system emoji.
    var character: String?
    /// Whether the name is the server's own emoji (drawn from an image, not a glyph).
    var isCustom: Bool

    var id: String { (isCustom ? "custom:" : "system:") + name }

    /// What VoiceOver reads and what a UI test can match: the shortcode form, which is unambiguous
    /// even for two emoji that look alike.
    var accessibilityLabel: String { ":\(name):" }
}

/// One section of the picker.
struct EmojiPickerSection: Equatable, Identifiable {
    enum Kind: String, Equatable, Sendable {
        case recent
        case custom
        case search
        case system
    }

    var id: String
    var title: String
    var kind: Kind
    var items: [EmojiPickerItem]
}

/// The picker's state: which sections it shows, what the search box holds, and what a pick does.
@MainActor
final class EmojiPickerViewModel: ObservableObject {

    @Published private(set) var sections: [EmojiPickerSection] = []
    @Published var search: String = "" {
        didSet { rebuild() }
    }

    let mode: EmojiPickerMode

    private let system: SystemEmojiCatalogue
    private let catalogue: EmojiCatalogue?
    private let recents: EmojiRecentsStore?
    private var cancellables = Set<AnyCancellable>()

    /// Called when the reader picks an emoji. The sheet dismisses itself afterwards.
    var onPick: ((EmojiPickerItem) -> Void)?

    init(mode: EmojiPickerMode,
         system: SystemEmojiCatalogue = .shared,
         catalogue: EmojiCatalogue? = nil,
         recents: EmojiRecentsStore? = nil,
         onPick: ((EmojiPickerItem) -> Void)? = nil) {
        self.mode = mode
        self.system = system
        self.catalogue = catalogue
        self.recents = recents
        self.onPick = onPick
        // The custom list and the recents row both change while the sheet is up (a `/emoji` page lands,
        // a react records a new recent). Observing them is what makes the picker redraw instead of
        // showing a section that was empty when it opened.
        //
        // `@Published` fires *before* the property is written, so the publisher's value is used
        // directly: reading `recents.names` inside the closure would rebuild from the previous list
        // and leave the picker one record behind.
        catalogue?.$identifiers
            .sink { [weak self] identifiers in
                self?.rebuild(customNames: Array(identifiers.keys).sorted())
            }
            .store(in: &cancellables)
        recents?.$names
            .sink { [weak self] names in self?.rebuild(recentNames: names) }
            .store(in: &cancellables)
        rebuild()
    }

    /// The custom emoji names, sorted, so two opens of the sheet show the same order (the catalogue's
    /// storage is a name→id map, which has no order of its own).
    var customNames: [String] {
        (catalogue?.identifiers.keys).map { Array($0).sorted() } ?? []
    }

    /// Whether any emoji can be offered at all — the sheet's empty state.
    var isEmpty: Bool { sections.allSatisfy { $0.items.isEmpty } }

    func rebuild(recentNames: [String]? = nil, customNames custom: [String]? = nil) {
        let term = Self.normalisedTerm(search)
        if !term.isEmpty {
            sections = [EmojiPickerSection(id: "search",
                                           title: "Search Results",
                                           kind: .search,
                                           items: results(for: term))]
            return
        }
        var built: [EmojiPickerSection] = []

        // Recent first, and only when it has something to show (upstream pops the section entirely).
        let recents = recentNames ?? self.recents?.names ?? []
        if !recents.isEmpty {
            let items = recents.compactMap { item(for: $0) }
            if !items.isEmpty {
                built.append(EmojiPickerSection(id: "recent", title: "Recently Used",
                                                kind: .recent, items: items))
            }
        }

        let customList = custom ?? customNames
        if !customList.isEmpty {
            built.append(EmojiPickerSection(id: "custom", title: "Custom", kind: .custom,
                                            items: customList.map { EmojiPickerItem(name: $0,
                                                                                  character: nil,
                                                                                  isCustom: true) }))
        }

        for category in system.categories {
            built.append(EmojiPickerSection(id: category.id,
                                            title: category.title,
                                            kind: .system,
                                            items: category.emojis.map {
                                                EmojiPickerItem(name: $0.name,
                                                                character: $0.char,
                                                                isCustom: false)
                                            }))
        }
        sections = built
    }

    /// The search result list: system matches (ranked) then custom names containing the term.
    func results(for term: String) -> [EmojiPickerItem] {
        var items = system.search(term).map {
            EmojiPickerItem(name: $0.name, character: $0.char, isCustom: false)
        }
        var seen = Set(items.map(\.name))
        for name in customNames where name.contains(term) && !seen.contains(name) {
            seen.insert(name)
            items.append(EmojiPickerItem(name: name, character: nil, isCustom: true))
        }
        return items
    }

    /// The reader picked an emoji: record it and hand it to the host.
    func pick(_ item: EmojiPickerItem) {
        recents?.record(item.name)
        onPick?(item)
    }

    /// The `:name:` insertion text (one rule, shared with the composer's autocomplete).
    func insertion(for item: EmojiPickerItem) -> String { emojiInsertion(item.name) }

    // MARK: - Helpers

    /// `:smile:` typed into the search box is the same query as `smile` — upstream strips the colons
    /// (`searchTerm.replace(/^:|:$/g, '')`), and a reader who pasted a shortcode expects a result.
    static func normalisedTerm(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while text.hasPrefix(":") { text.removeFirst() }
        while text.hasSuffix(":") { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// One item for a shortcode, resolving which side it belongs to.
    func item(for name: String) -> EmojiPickerItem? {
        if let emoji = system.emoji(named: name) {
            // A custom emoji that shadows a system one is still drawn as the system glyph, but the
            // picker offers the server's name when it has one (the send needs the server's spelling).
            let isCustom = catalogue?.isCustom(name) ?? false
            return EmojiPickerItem(name: isCustom ? name : emoji.name,
                                   character: emoji.char,
                                   isCustom: isCustom)
        }
        if catalogue?.isCustom(name) ?? false {
            return EmojiPickerItem(name: name, character: nil, isCustom: true)
        }
        // A stored recent this server can no longer resolve: drop the chip rather than draw a name the
        // server would answer 404 for.
        return nil
    }
}
