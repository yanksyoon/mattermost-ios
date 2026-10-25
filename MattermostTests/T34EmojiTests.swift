// T34 — the custom emoji path: `GET /emoji` name list + `GET /emoji/{id}/image`, and the renderer rule
// that turns a *known* `:name:` into an image while an unknown one stays literal text.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0, app/actions/remote/custom_emoji.ts,
// app/client/rest/custom_emoji.ts, app/components/markdown/transform.ts (emoji lookup order).
// The loaders are injected, so nothing here touches a network: what is under test is the pagination,
// the case-insensitive name map, the deleted-emoji filter, the at-most-once image load and the
// segment split the view renders.

import XCTest
@testable import Mattermost

@MainActor
final class T34EmojiTests: XCTestCase {

    /// One pixel of PNG — enough for `UIImage(data:)` to succeed.
    private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8AAAwAB/AF+gx0aAAAAAElFTkSuQmCC")!

    private final class Stub {
        var pages: [Int: [MMEmoji]] = [:]
        var failingPages: Set<Int> = []
        var imageRequests: [String] = []
        var pageRequests: [(page: Int, perPage: Int)] = []
        var imageFailure = false
    }

    private func catalogue(_ stub: Stub) -> EmojiCatalogue {
        EmojiCatalogue(
            loadPage: { page, perPage in
                stub.pageRequests.append((page, perPage))
                if stub.failingPages.contains(page) { throw MMError.offline }
                return stub.pages[page] ?? []
            },
            loadImage: { emojiID in
                stub.imageRequests.append(emojiID)
                if stub.imageFailure { throw MMError.notFound }
                return Self.png
            })
    }

    private func emoji(_ id: String, _ name: String, deleted: Int64 = 0) -> MMEmoji {
        MMEmoji(id: id, name: name, deleteAt: deleted)
    }

    // MARK: - Decoding

    func testEmojiDecodeFromTheServersPayload() throws {
        let json = """
        [{"id":"abc123","creator_id":"me","name":"party_parrot","create_at":1700000000000,
          "update_at":1700000000001,"delete_at":0}]
        """
        let decoded = try JSONDecoder().decode([MMEmoji].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].id, "abc123")
        XCTAssertEqual(decoded[0].name, "party_parrot")
        XCTAssertEqual(decoded[0].creatorId, "me")
        XCTAssertEqual(decoded[0].createAt, 1_700_000_000_000)
        XCTAssertTrue(decoded[0].isUsable)
    }

    func testAnEmojiMissingOptionalFieldsStillDecodes() throws {
        let decoded = try JSONDecoder().decode(MMEmoji.self, from: Data("{\"id\":\"a\",\"name\":\"b\"}".utf8))
        XCTAssertEqual(decoded.id, "a")
        XCTAssertEqual(decoded.deleteAt, 0)
        XCTAssertTrue(decoded.isUsable)
    }

    // MARK: - The name list

    func testNamesAreLowerCasedAndDeletedEmojiAreExcluded() async {
        let stub = Stub()
        stub.pages[0] = [emoji("1", "Party_Parrot"), emoji("2", "gone", deleted: 99), emoji("3", "shrug")]
        let catalogue = catalogue(stub)
        await catalogue.loadNamesIfNeeded()

        XCTAssertTrue(catalogue.didLoadNames)
        XCTAssertTrue(catalogue.isCustom("party_parrot"), "names are matched case-insensitively")
        XCTAssertTrue(catalogue.isCustom("PARTY_PARROT"))
        XCTAssertTrue(catalogue.isCustom("shrug"))
        XCTAssertFalse(catalogue.isCustom("gone"), "a deleted emoji must not render")
        XCTAssertFalse(catalogue.isCustom("tada"))
        XCTAssertEqual(stub.pageRequests.count, 1, "a short page ends the pagination")
    }

    func testAPageFullOfEmojiAsksForTheNextOne() async {
        let stub = Stub()
        let fullPage = (0..<EmojiCatalogue.pageSize).map { emoji("id\($0)", "e\($0)") }
        stub.pages[0] = fullPage
        stub.pages[1] = [emoji("last", "last_one")]
        let catalogue = catalogue(stub)
        await catalogue.loadNamesIfNeeded()

        XCTAssertTrue(catalogue.isCustom("e0"))
        XCTAssertTrue(catalogue.isCustom("last_one"))
        XCTAssertEqual(stub.pageRequests.map(\.page), [0, 1])
        XCTAssertTrue(stub.pageRequests.allSatisfy { $0.perPage == EmojiCatalogue.pageSize })
    }

    func testAStalledPageAlsoEndsThePagination() async {
        let stub = Stub()
        stub.pages[0] = (0..<EmojiCatalogue.pageSize).map { emoji("id\($0)", "e\($0)") }
        stub.failingPages = [1]
        let catalogue = catalogue(stub)
        await catalogue.loadNamesIfNeeded()

        XCTAssertTrue(catalogue.isCustom("e0"), "the names already read are kept")
        XCTAssertEqual(stub.pageRequests.map(\.page), [0, 1])
        XCTAssertTrue(catalogue.didLoadNames)
    }

    func testLoadingNamesTwiceHitsTheServerOnce() async {
        let stub = Stub()
        stub.pages[0] = [emoji("1", "one")]
        let catalogue = catalogue(stub)
        await catalogue.loadNamesIfNeeded()
        await catalogue.loadNamesIfNeeded()
        XCTAssertEqual(stub.pageRequests.count, 1)
    }

    // MARK: - Images

    func testAnImageIsFetchedOnceAndCached() async {
        let stub = Stub()
        stub.pages[0] = [emoji("id1", "parrot")]
        let catalogue = catalogue(stub)
        await catalogue.loadNamesIfNeeded()

        let first = await catalogue.image(for: "parrot")
        let second = await catalogue.image(for: "PARROT")
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(stub.imageRequests, ["id1"], "one request per emoji, not per row")
        XCTAssertNotNil(catalogue.imageIfLoaded(for: "parrot"))
    }

    func testAnUnknownNameHasNoImageAndNoRequest() async {
        let stub = Stub()
        stub.pages[0] = [emoji("id1", "parrot")]
        let catalogue = catalogue(stub)
        await catalogue.loadNamesIfNeeded()
        let image = await catalogue.image(for: "not_an_emoji")
        XCTAssertNil(image)
        XCTAssertTrue(stub.imageRequests.isEmpty)
    }

    func testAFailedImageLoadDegradesWithoutThrowing() async {
        let stub = Stub()
        stub.pages[0] = [emoji("id1", "parrot")]
        stub.imageFailure = true
        let catalogue = catalogue(stub)
        await catalogue.loadNamesIfNeeded()
        let image = await catalogue.image(for: "parrot")
        XCTAssertNil(image)
        XCTAssertNil(catalogue.imageIfLoaded(for: "parrot"))
    }

    func testClearingForgetsTheServerListAndItsImages() async {
        let stub = Stub()
        stub.pages[0] = [emoji("id1", "parrot")]
        let catalogue = catalogue(stub)
        await catalogue.loadNamesIfNeeded()
        _ = await catalogue.image(for: "parrot")

        catalogue.clear()
        XCTAssertFalse(catalogue.isCustom("parrot"))
        XCTAssertNil(catalogue.imageIfLoaded(for: "parrot"))
        XCTAssertFalse(catalogue.didLoadNames)
    }

    // MARK: - The names a paragraph uses

    func testCustomNamesAreCollectedFromNestedRuns() async {
        let stub = Stub()
        stub.pages[0] = [emoji("1", "parrot"), emoji("2", "shrug")]
        let catalogue = catalogue(stub)
        await catalogue.loadNamesIfNeeded()

        let runs: [MarkdownInline] = [
            .text("hello "),
            .bold([.emoji(name: "parrot")]),
            .text(" and "),
            .link(text: [.emoji(name: "Shrug")], url: "https://example.com"),
            .emoji(name: "tada")
        ]
        XCTAssertEqual(EmojiCatalogue.customNames(in: runs, catalogue: catalogue), ["parrot", "shrug"])
        XCTAssertEqual(EmojiCatalogue.customNames(in: runs, catalogue: nil), [])
    }

    // MARK: - Rendering rule

    func testSegmentsSplitExactlyAtCustomEmoji() {
        let runs: [MarkdownInline] = [.text("hi "),
                                      .emoji(name: "parrot"),
                                      .text(" there")]
        let segments = MarkdownText.segments(runs, custom: ["parrot"])
        XCTAssertEqual(segments.count, 3)
        guard case .text(let first) = segments[0] else { return XCTFail("first segment") }
        XCTAssertEqual(String(first.characters), "hi ")
        guard case .emojiImage(let name) = segments[1] else { return XCTFail("middle segment") }
        XCTAssertEqual(name, "parrot")
        guard case .text(let last) = segments[2] else { return XCTFail("last segment") }
        XCTAssertEqual(String(last.characters), " there")
    }

    func testAnUnknownOrUnlistedShortcodeStaysText() {
        // `tada` is a built-in character, `parrot` is not custom on this server: both stay text.
        let runs: [MarkdownInline] = [.emoji(name: "tada"), .text(" "), .emoji(name: "parrot")]
        let segments = MarkdownText.segments(runs, custom: [])
        XCTAssertEqual(segments.count, 1, "no image segments when nothing is custom")
        guard case .text(let text) = segments[0] else { return XCTFail("expected one text segment") }
        XCTAssertEqual(String(text.characters), "🎉 :parrot:")
    }

    func testEmphasisSurvivesAroundAnEmojiSegment() {
        let runs: [MarkdownInline] = [.bold([.text("wow"), .emoji(name: "parrot")]), .text("!")]
        let segments = MarkdownText.segments(runs, custom: ["parrot"])
        XCTAssertEqual(segments.count, 3)
        guard case .text(let boldPart) = segments[0] else { return XCTFail("bold segment") }
        XCTAssertEqual(String(boldPart.characters), "wow")
        XCTAssertEqual(boldPart.inlinePresentationIntent, .stronglyEmphasized)
        guard case .emojiImage = segments[1] else { return XCTFail("image segment") }
        guard case .text(let tail) = segments[2] else { return XCTFail("tail segment") }
        XCTAssertEqual(tail.inlinePresentationIntent, nil)
    }
}
