// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/actions/remote/custom_emoji.ts (load the team's custom emoji once, by name),
//        app/client/rest/custom_emoji.ts (`getCustomEmojis` `/emoji`, `getCustomEmojiImageUrl`),
//        app/components/markdown/markdown.tsx + app/utils/emoji/helpers.ts (an unknown `:name:` is
//        drawn as its shortcode; a *known custom* name is drawn as the server's image).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §10; no
// upstream source copied.
//
// Why this is its own object and not a table in the renderer:
//  - a custom emoji is *server data* (a team can add, rename and delete them), so the names and the
//    images must come from the API, not from a build-time list;
//  - the catalogue is per server and shared by every row, so the name list is fetched once
//    (paginated) and each image at most once;
//  - the loaders are injected, so the pagination, the de-duplication and the caching rules are unit
//    tests without a network — the same seam the other T34 modules use (component-map.md §4).

import UIKit

/// One custom emoji as `GET /api/v4/emoji` returns it.
///
/// The fields this client does not draw (`creator_id`, `update_at`) are still decoded: a payload the
/// server sends must round-trip without inventing a shape (the same rule as `MMTypes.swift`).
struct MMEmoji: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var creatorId: String
    var createAt: Int64
    var updateAt: Int64
    var deleteAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, name
        case creatorId = "creator_id"
        case createAt = "create_at"
        case updateAt = "update_at"
        case deleteAt = "delete_at"
    }

    init(id: String,
         name: String,
         creatorId: String = "",
         createAt: Int64 = 0,
         updateAt: Int64 = 0,
         deleteAt: Int64 = 0) {
        self.id = id
        self.name = name
        self.creatorId = creatorId
        self.createAt = createAt
        self.updateAt = updateAt
        self.deleteAt = deleteAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        creatorId = try values.decodeIfPresent(String.self, forKey: .creatorId) ?? ""
        createAt = try values.decodeIfPresent(Int64.self, forKey: .createAt) ?? 0
        updateAt = try values.decodeIfPresent(Int64.self, forKey: .updateAt) ?? 0
        deleteAt = try values.decodeIfPresent(Int64.self, forKey: .deleteAt) ?? 0
    }

    /// A deleted emoji is not renderable, even if the server still lists it (the mobile client
    /// filters `delete_at > 0` for the same reason).
    var isUsable: Bool { !id.isEmpty && !name.isEmpty && deleteAt == 0 }
}

/// `:name:` → server image, for one server.
@MainActor
final class EmojiCatalogue: ObservableObject {

    /// `/emoji` is paginated; upstream asks for 200 at a time. The cap stops a pathological server
    /// (or a wrong `per_page`) from turning a channel open into an unbounded crawl.
    static let pageSize = 200
    static let maxPages = 10

    private let loadPage: (Int, Int) async throws -> [MMEmoji]
    private let loadImage: (String) async throws -> Data

    /// Lower-cased name → emoji id. Custom emoji names are matched case-insensitively by the server,
    /// and upstream lower-cases the shortcode before lookup.
    ///
    /// Published, not a plain property: `GET /emoji` is fetched once per server and lands *after* the
    /// first page of posts is already drawn, so a row that resolved its shortcodes once would keep
    /// showing `:name:` until it happened to be recycled. T34 review F7 — the live UI run caught a
    /// literal `:t34parrot:` on screen for exactly this reason.
    @Published private(set) var identifiers: [String: String] = [:]
    /// Loaded images, published so the rows redraw as they arrive.
    @Published private(set) var images: [String: UIImage] = [:]
    private(set) var didLoadNames = false
    /// Diagnostics/tests: how many `/emoji` pages this catalogue asked for.
    private(set) var pagesRequested = 0

    private var nameTask: Task<Void, Never>?
    private var imageTasks: [String: Task<UIImage?, Never>] = [:]

    init(loadPage: @escaping (Int, Int) async throws -> [MMEmoji],
         loadImage: @escaping (String) async throws -> Data) {
        self.loadPage = loadPage
        self.loadImage = loadImage
    }

    convenience init(service: ChannelServing) {
        self.init(loadPage: { page, perPage in
                      try await service.customEmoji(page: page, perPage: perPage)
                  },
                  loadImage: { emojiID in
                      try await service.emojiImage(emojiID: emojiID)
                  })
    }

    // MARK: - Names

    /// Load the server's custom emoji list once. A failure is *not* surfaced: a channel that cannot
    /// list its emoji still renders every post, with `:name:` for the ones it cannot resolve — the
    /// same degradation the server itself produces for an unknown shortcode.
    func loadNamesIfNeeded() async {
        if didLoadNames { return }
        if let nameTask { return await nameTask.value }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.fetchNames()
        }
        nameTask = task
        await task.value
    }

    private func fetchNames() async {
        var found: [String: String] = [:]
        for page in 0..<Self.maxPages {
            pagesRequested += 1
            guard let batch = try? await loadPage(page, Self.pageSize) else { break }
            for emoji in batch where emoji.isUsable {
                found[emoji.name.lowercased()] = emoji.id
            }
            if batch.count < Self.pageSize { break }
        }
        identifiers = found
        didLoadNames = true
        nameTask = nil
    }

    /// Whether `name` is a custom emoji this server knows.
    func isCustom(_ name: String) -> Bool {
        identifiers[name.lowercased()] != nil
    }

    /// The custom emoji names used by a run of inline content (lower-cased, in document order).
    static func customNames(in runs: [MarkdownInline], catalogue: EmojiCatalogue?) -> [String] {
        guard let catalogue else { return [] }
        var names: [String] = []
        func walk(_ runs: [MarkdownInline]) {
            for run in runs {
                switch run {
                case .emoji(let name):
                    let key = name.lowercased()
                    if catalogue.isCustom(key), !names.contains(key) { names.append(key) }
                case .bold(let inner), .italic(let inner), .strikethrough(let inner):
                    walk(inner)
                case .link(let inner, _):
                    walk(inner)
                default:
                    break
                }
            }
        }
        walk(runs)
        return names
    }

    // MARK: - Images

    /// The image for one custom emoji name, loading it at most once.
    func image(for name: String) async -> UIImage? {
        let key = name.lowercased()
        if let cached = images[key] { return cached }
        if let running = imageTasks[key] { return await running.value }
        guard let emojiID = identifiers[key] else { return nil }
        let task = Task<UIImage?, Never> { [loadImage] in
            guard let data = try? await loadImage(emojiID), let image = UIImage(data: data) else {
                return nil
            }
            return image
        }
        imageTasks[key] = task
        let image = await task.value
        imageTasks[key] = nil
        if let image { images[key] = image }
        return image
    }

    func imageIfLoaded(for name: String) -> UIImage? { images[name.lowercased()] }

    /// Sign-out / server removal: a new session may be a different team with different emoji.
    func clear() {
        identifiers.removeAll()
        images.removeAll()
        for (_, task) in imageTasks { task.cancel() }
        imageTasks.removeAll()
        nameTask?.cancel()
        nameTask = nil
        didLoadNames = false
        pagesRequested = 0
    }
}
