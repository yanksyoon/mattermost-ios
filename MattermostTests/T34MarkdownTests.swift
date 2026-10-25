// T34 — the markdown reader's rules.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0,
// app/components/markdown/{markdown.tsx, transform.ts, markdown_link, markdown_code_block,
// markdown_table, markdown_list, markdown_block_quote}, app/utils/markdown.ts (the mention/channel
// link/emoji tokenisation), app/utils/emoji.ts.
//
// The two properties worth testing hardest are the ones that are *safety* properties rather than
// formatting ones: (1) HTML in a post is never interpreted, and (2) a link the app will not open is
// not a link. Everything else here is fidelity to what the web app shows.

import XCTest
@testable import Mattermost

final class T34MarkdownTests: XCTestCase {

    private func parse(_ text: String) -> [MarkdownBlock] {
        MarkdownParser().parse(text)
    }

    // MARK: Blocks

    func testParagraphsSplitOnBlankLines() {
        let blocks = parse("first line\nsecond line\n\nnext paragraph")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].plainText, "first line\nsecond line")
        XCTAssertEqual(blocks[1].plainText, "next paragraph")
    }

    func testHeadingsCarryTheirLevel() {
        let blocks = parse("# one\n\n## two\n\n###### six")
        XCTAssertEqual(blocks.count, 3)
        guard case .heading(let level, _) = blocks[0] else { return XCTFail("not a heading") }
        XCTAssertEqual(level, 1)
        guard case .heading(let deep, _) = blocks[2] else { return XCTFail("not a heading") }
        XCTAssertEqual(deep, 6)
        XCTAssertEqual(blocks[2].plainText, "six")
    }

    func testFencedCodeKeepsItsLanguageAndVerbatimBody() {
        let blocks = parse("```swift\nlet x = 1\n  indented\n```")
        guard case .codeBlock(let language, let code) = blocks[0] else { return XCTFail("not code") }
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(code, "let x = 1\n  indented")
    }

    func testUnterminatedFenceSwallowsTheRestInsteadOfDroppingIt() {
        let blocks = parse("```js\nconst a = 1\nstill code")
        guard case .codeBlock(let language, let code) = blocks[0] else { return XCTFail("not code") }
        XCTAssertEqual(language, "js")
        XCTAssertEqual(code, "const a = 1\nstill code")
    }

    func testTildeFenceIsACodeBlockToo() {
        let blocks = parse("~~~\nplain\n~~~")
        guard case .codeBlock(let language, _) = blocks[0] else { return XCTFail("not code") }
        XCTAssertNil(language)
    }

    func testBlockQuoteNestsBlocks() {
        let blocks = parse("> quoted\n> still quoted\n\n> - a list item")
        XCTAssertEqual(blocks.count, 2)
        guard case .blockQuote(let inner) = blocks[1] else { return XCTFail("not a quote") }
        guard case .list = inner[0] else { return XCTFail("quote lost its list") }
    }

    func testListsKeepOrderAndStartNumber() {
        let bullets = parse("- one\n- two\n* three")
        guard case .list(let ordered, _, let items) = bullets[0] else { return XCTFail("not a list") }
        XCTAssertFalse(ordered)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(MarkdownInline.plainText(items[2]), "three")

        let numbered = parse("3. three\n4. four")
        guard case .list(let isOrdered, let start, let numbers) = numbered[0] else {
            return XCTFail("not a list")
        }
        XCTAssertTrue(isOrdered)
        XCTAssertEqual(start, 3)
        XCTAssertEqual(numbers.count, 2)
    }

    func testTableHasHeaderAndRows() {
        let blocks = parse("| Column | Value |\n|---|---|\n| alpha | 1 |\n| beta | 2 |")
        guard case .table(let header, let rows) = blocks[0] else { return XCTFail("not a table") }
        XCTAssertEqual(header.count, 2)
        XCTAssertEqual(MarkdownInline.plainText(header[1]), "Value")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(MarkdownInline.plainText(rows[1][0]), "beta")
    }

    func testThematicBreak() {
        let blocks = parse("a\n\n---\n\nb")
        XCTAssertEqual(blocks.count, 3)
        guard case .thematicBreak = blocks[1] else { return XCTFail("not a rule") }
    }

    // MARK: Inline

    func testEmphasisNests() {
        let blocks = parse("**bold *and italic***")
        guard case .paragraph(let runs) = blocks[0] else { return XCTFail() }
        XCTAssertEqual(MarkdownInline.plainText(runs), "bold and italic")
        guard case .bold(let inner) = runs[0] else { return XCTFail("not bold") }
        guard case .italic = inner[1] else { return XCTFail("italic lost inside bold") }
    }

    func testStrikethroughAndInlineCode() {
        let blocks = parse("~~gone~~ and `code`")
        guard case .paragraph(let runs) = blocks[0] else { return XCTFail() }
        XCTAssertTrue(runs.contains { if case .strikethrough = $0 { return true }; return false })
        XCTAssertTrue(runs.contains { if case .code(let c) = $0 { return c == "code" }; return false })
    }

    func testCodeSpanSwallowsMarkdownCharacters() {
        let blocks = parse("`**not bold**`")
        guard case .paragraph(let runs) = blocks[0] else { return XCTFail() }
        XCTAssertEqual(runs.count, 1)
        guard case .code(let text) = runs[0] else { return XCTFail("not code") }
        XCTAssertEqual(text, "**not bold**")
    }

    func testMentionChannelLinkAndEmoji() {
        let blocks = parse("@ada look at ~town-square :tada: and :not_a_real_emoji:")
        guard case .paragraph(let runs) = blocks[0] else { return XCTFail() }
        XCTAssertTrue(runs.contains { if case .mention(let name) = $0 { return name == "ada" }; return false })
        XCTAssertTrue(runs.contains {
            if case .channelLink(let name) = $0 { return name == "town-square" }
            return false
        })
        XCTAssertTrue(runs.contains { if case .emoji(let name) = $0 { return name == "tada" }; return false })
        // An unknown shortcode is still a known *shape*: it is kept, and drawn literally.
        XCTAssertTrue(runs.contains {
            if case .emoji(let name) = $0 { return name == "not_a_real_emoji" }
            return false
        })
    }

    func testEmoticonBecomesAnEmoji() {
        let blocks = parse("nice work :)")
        guard case .paragraph(let runs) = blocks[0] else { return XCTFail() }
        XCTAssertTrue(runs.contains { if case .emoji(let name) = $0 { return name == "slightly_smiling_face" }; return false },
                      "emoticon was not converted: \(runs)")
    }

    func testHTMLEntitiesAreDecoded() {
        let blocks = parse("a &amp; b &lt;tag&gt; &#65;")
        XCTAssertEqual(blocks[0].plainText, "a & b <tag> A")
    }

    func testEscapedCharactersStayLiteral() {
        let blocks = parse("\\*not emphasis\\*")
        XCTAssertEqual(blocks[0].plainText, "*not emphasis*")
        XCTAssertFalse(blocks.allInlines.contains { if case .italic = $0 { return true }; return false })
    }

    func testLinkKeepsLabelAndTarget() {
        let blocks = parse("[docs](https://docs.mattermost.com/x?y=1)")
        guard case .paragraph(let runs) = blocks[0] else { return XCTFail() }
        XCTAssertEqual(runs.first?.linkURL, "https://docs.mattermost.com/x?y=1")
        XCTAssertEqual(MarkdownInline.plainText(runs), "docs")
    }

    func testAutolinkAndBareURL() {
        let blocks = parse("see <https://example.com/a> and https://example.com/b and www.example.com")
        guard case .paragraph(let runs) = blocks[0] else { return XCTFail() }
        let urls = runs.compactMap { $0.linkURL }
        XCTAssertEqual(urls, ["https://example.com/a", "https://example.com/b", "https://www.example.com"])
    }

    // MARK: Safety

    func testHTMLIsDrawnAsTextNeverInterpreted() {
        let blocks = parse("<b>bold?</b> <img src=x onerror=alert(1)>")
        // No run is emphasis: the tags are characters, not markup.
        let hasEmphasis = blocks.allInlines.contains {
            switch $0 {
            case .bold, .italic: return true
            default: return false
            }
        }
        XCTAssertFalse(hasEmphasis)
        XCTAssertTrue(blocks[0].plainText.contains("<b>bold?</b>"))
        XCTAssertTrue(blocks[0].plainText.contains("<img src=x onerror=alert(1)>"))
    }

    func testScriptAndStyleContentIsDroppedEntirely() {
        let blocks = parse("before<script>alert('x')</script>after\n\n<style>p{color:red}</style>tail")
        let text = blocks.map(\.plainText).joined(separator: "\n")
        XCTAssertFalse(text.contains("alert"))
        XCTAssertFalse(text.contains("color:red"))
        XCTAssertTrue(text.contains("before"))
        XCTAssertTrue(text.contains("after"))
        XCTAssertTrue(text.contains("tail"))
    }

    func testIframeIsDropped() {
        let blocks = parse("a<iframe src=\"https://evil.example\"></iframe>b")
        let text = blocks.map(\.plainText).joined()
        XCTAssertFalse(text.contains("evil.example"))
    }

    func testJavascriptURLIsNotALink() {
        let blocks = parse("[click](javascript:alert(1)) [data](data:text/html;base64,AAA) [vb](vbscript:x)")
        let urls = blocks.allInlines.compactMap(\.linkURL)
        XCTAssertTrue(urls.allSatisfy { url in
            url.hasPrefix("https://") || url.hasPrefix("http://") || url.hasPrefix("mailto:")
        }, "unsafe link survived: \(urls)")
        // The label is kept (the reader still sees the words), the target is not.
        XCTAssertTrue(blocks[0].plainText.contains("click"))
    }

    func testRelativeLinkIsKeptForTheCurrentServer() {
        let blocks = parse("[channel](/team/channels/town-square)")
        XCTAssertEqual(blocks.allInlines.compactMap(\.linkURL), ["/team/channels/town-square"])
    }

    func testAutolinkRejectsRelativeTarget() {
        // `</b>` must not turn into a link just because it starts with `/`.
        let blocks = parse("a </b> b")
        XCTAssertTrue(blocks.allInlines.compactMap(\.linkURL).isEmpty)
    }

    // MARK: Robustness

    func testPathologicalInputTerminatesAndKeepsItsText() {
        let samples = [
            String(repeating: "*", count: 500),
            String(repeating: "[", count: 200),
            String(repeating: "`", count: 99),
            String(repeating: "a\n\n", count: 300),
            "```\n" + String(repeating: "x", count: 2000),
            "| a |\n|" + String(repeating: "-", count: 400) + "|",
            ":smile:" + String(repeating: ":", count: 100)
        ]
        for sample in samples {
            let blocks = parse(sample)
            XCTAssertFalse(blocks.isEmpty, "input produced no blocks: \(sample.prefix(20))")
        }
    }

    func testRandomInputParsesDeterministicallyAndCannotExplode() {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("abc *_~`[]()<>|#\\:-/.\n1234&;\"'")
        for _ in 0..<200 {
            let length = Int.random(in: 0...120, using: &generator)
            let text = String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
            let first = parse(text)
            let second = parse(text)
            // Deterministic: the same bytes always produce the same tree (no dictionary ordering or
            // hash randomness leaking into what a reader sees).
            XCTAssertEqual(first, second)

            // Bounded: markup can be dropped and an emoticon can expand to an emoji *name*, but the
            // parser cannot manufacture a document out of nothing. A short input stays short.
            let total = first.map(\.plainText).reduce(0) { $0 + $1.count }
            XCTAssertLessThanOrEqual(total, max(64, text.count * 3),
                                     "input grew unexpectedly: \(text.debugDescription)")
        }
    }

    func testEmptyInputHasNoBlocks() {
        XCTAssertTrue(parse("").isEmpty)
        XCTAssertTrue(parse("\n\n   \n").isEmpty)
    }
}
