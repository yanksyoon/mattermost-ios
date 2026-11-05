// T56 — one selectable surface for a whole post body (card t_38e0eac6).
//
// The defect: `MarkdownView` drew a body block by block, each block its own `Text` with
// `.textSelection(.enabled)`. SwiftUI scopes selection to a single `Text`, so a drag that starts in
// paragraph 1 cannot reach paragraph 2 and a normal multi-paragraph message can never be copied as one
// range. The fix is `SelectableMarkdownBody`: one read-only, selectable `UITextView` per post whose
// content is an `NSAttributedString` built from the parsed runs.
//
// What is proved here (fast, no server):
//   1. three paragraphs become one string, in order, and one selection range covers all three;
//   2. the system Copy action puts exactly that text on the pasteboard (no markdown syntax leakage);
//   3. a fenced block copies its code without the fence or the language;
//   4. a link run still routes a tap to the opener, and the default handler is refused;
//   5. the HTML-is-never-interpreted invariant survives, and no HTML parser appears in the source;
//   6. two bodies cannot share a selection (selecting one post stops at its own text);
//   7. a custom emoji is an image in the drawn string but its *name* in the accessibility text.
//
// The live drag (mouse/gesture) and the legacy-renderer revert are in
// `MattermostUITests/T56SelectionUITests.swift`; the scroll cost is in
// `docs/t_38e0eac6-build-note.md`.

import XCTest
import UIKit
@testable import Mattermost

@MainActor
final class T56SelectionTests: XCTestCase {

    private func parse(_ text: String) -> [MarkdownBlock] {
        MarkdownParser().parse(text)
    }

    private func body(_ text: String,
                      custom: Set<String> = [],
                      images: [String: UIImage] = [:],
                      highlight: [SearchHighlightTerm] = []) -> MarkdownBodyDocument {
        MarkdownBodyText.document(parse(text), custom: custom, images: images, highlight: highlight)
    }

    private func configuredView(_ document: MarkdownBodyDocument,
                                identifier: String = "post.test.body.block0") -> MarkdownBodyUITextView {
        let representable = MarkdownBodyRepresentable(document: document,
                                                      identifier: identifier,
                                                      linkOpener: { _ in })
        let view = MarkdownBodyUITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.delegate = representable.makeCoordinator()
        view.apply(document)
        return view
    }

    // MARK: - T1: one range over three paragraphs

    func testThreeParagraphsAreOneStringAndOneSelectionRange() {
        let document = body("selection alpha\n\nselection beta\n\nselection gamma")
        let view = configuredView(document)

        XCTAssertEqual(document.attributed.string,
                       "selection alpha\nselection beta\nselection gamma",
                       "the three paragraphs must be one string, in order")
        XCTAssertTrue(view.isSelectable, "the body must be selectable")
        XCTAssertFalse(view.isEditable, "the body must not be editable")
        XCTAssertFalse(view.isScrollEnabled, "the body sizes itself inside the row")

        // One range, spanning every paragraph. A per-block surface could not hold this: its text
        // view would end at the first paragraph.
        let whole = NSRange(location: 0, length: view.textStorage.length)
        view.selectedRange = whole
        XCTAssertEqual(view.selectedRange, whole, "selection must be a single range across all blocks")
        XCTAssertEqual(view.selectedText, document.attributed.string)
        XCTAssertTrue(view.selectedText.contains("selection alpha"))
        XCTAssertTrue(view.selectedText.contains("selection beta"))
        XCTAssertTrue(view.selectedText.contains("selection gamma"))
    }

    func testSelectionKeepsEveryParagraphInOrder() {
        let document = body("one\n\ntwo\n\nthree")
        let view = configuredView(document)
        view.selectedRange = NSRange(location: 0, length: view.textStorage.length)
        let lines = view.selectedText.components(separatedBy: "\n")
        XCTAssertEqual(lines, ["one", "two", "three"])
    }

    // MARK: - T2: Copy puts that exact text on the pasteboard

    func testCopyOfTheWholeSelectionIsTheDrawnTextWithoutSyntax() {
        let document = body("**bold** and *italic* and `code`\n\nsecond paragraph\n\nthird paragraph")
        let view = configuredView(document)
        view.selectedRange = NSRange(location: 0, length: view.textStorage.length)

        UIPasteboard.general.string = ""
        view.copy(nil)

        let copied = UIPasteboard.general.string ?? ""
        XCTAssertEqual(copied, document.attributed.string,
                       "Copy must put the drawn characters on the pasteboard, got '\(copied)'")
        XCTAssertTrue(copied.contains("bold and italic and code"))
        XCTAssertFalse(copied.contains("**"), "no markdown emphasis syntax in a copy")
        XCTAssertFalse(copied.contains("`"), "no markdown code syntax in a copy")
    }

    // MARK: - T3: code copies without the fence

    func testCodeBlockSelectionCopiesTheCodeWithoutTheFence() {
        let document = body("before\n\n```swift\nlet value = 42\nprint(value)\n```\n\nafter")
        let view = configuredView(document)
        view.selectedRange = NSRange(location: 0, length: view.textStorage.length)
        let text = view.selectedText

        XCTAssertTrue(text.contains("let value = 42"), "code must be selectable, got '\(text)'")
        XCTAssertTrue(text.contains("print(value)"))
        XCTAssertFalse(text.contains("```"), "the fence is not part of the message")
        XCTAssertFalse(text.contains("swift"), "the fence language is not drawn and must not copy")
        XCTAssertTrue(text.hasPrefix("before"), "the paragraphs around the fence stay in order")
        XCTAssertTrue(text.hasSuffix("after"))
    }

    // MARK: - T4: links stay links

    func testLinkTapRoutesThroughTheOpenerAndRefusesTheDefault() {
        var opened: URL?
        let document = body("see [the docs](https://docs.mattermost.com/guide)")
        let representable = MarkdownBodyRepresentable(document: document,
                                                      identifier: "post.test.body.block0",
                                                      linkOpener: { opened = $0 })
        let coordinator = representable.makeCoordinator()
        let view = configuredView(document)
        let target = try! XCTUnwrap(URL(string: "https://docs.mattermost.com/guide"))

        let handled = coordinator.textView(view,
                                           shouldInteractWith: target,
                                           in: NSRange(location: 4, length: 8),
                                           interaction: .invokeDefaultAction)

        XCTAssertFalse(handled, "the default handler must be refused, or Safari opens blindly")
        XCTAssertEqual(opened, target, "the tap must reach the shell's opener")
    }

    func testLinkRunKeepsItsTargetInTheDocument() {
        let document = body("see [the docs](https://docs.mattermost.com/guide)")
        let text = document.attributed.string
        let docsRange = (text as NSString).range(of: "the docs")
        let target = document.attributed.attribute(.link, at: docsRange.location, effectiveRange: nil)
        XCTAssertEqual(target as? URL, URL(string: "https://docs.mattermost.com/guide"))
    }

    // MARK: - T5: the security invariant survives

    func testHTMLIsStillDrawnAsTextNeverInterpreted() {
        // The T34 property, re-asserted on the new surface's own builder: the characters are drawn,
        // and nothing in the document is a link to an executable scheme.
        let blocks = parse("<b>bold?</b> <img src=x onerror=alert(1)>")
        let document = MarkdownBodyText.document(blocks)
        XCTAssertTrue(document.attributed.string.contains("<b>bold?</b>"))
        XCTAssertTrue(document.attributed.string.contains("<img src=x onerror=alert(1)>"))
        XCTAssertNil(document.attributed.attribute(.link, at: 0, effectiveRange: nil),
                     "raw HTML must not become a link or an interpreted run")
    }

    func testNoHTMLParserInEitherRenderer() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = [
            "Mattermost/UI/Native/Channel/Markdown/MarkdownView.swift",
            "Mattermost/UI/Native/Channel/Markdown/MarkdownSelectionView.swift"
        ]
        for file in files {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            // Comments are allowed to *discuss* the invariant (`MarkdownView.swift`'s header names the
            // HTML initialiser it does not call); only executable lines are scanned.
            let code = source.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") }
                .joined(separator: "\n")
            XCTAssertFalse(code.contains("NSAttributedString(html"),
                           "\(file) must not parse HTML")
            XCTAssertFalse(code.contains("NSAttributedString(data:"),
                           "\(file) must not parse HTML from data")
            XCTAssertFalse(code.contains("WKWebView("),
                           "\(file) must not render a post in a web view")
        }
    }

    // MARK: - AV: one post's selection cannot reach the next post's text

    func testSelectingOnePostDoesNotExtendIntoTheNext() {
        let first = configuredView(body("first post alpha\n\nfirst post beta"),
                                   identifier: "post.first.body.block0")
        let second = configuredView(body("second post gamma"),
                                    identifier: "post.second.body.block0")

        first.selectedRange = NSRange(location: 0, length: first.textStorage.length)

        XCTAssertEqual(second.selectedRange.length, 0,
                       "a selection in one body must not exist in the next body")
        XCTAssertFalse(first.selectedText.contains("second post gamma"),
                       "one post's selection cannot reach the next post's text")
    }

    // MARK: - Custom emoji

    func testCustomEmojiIsAnImageInTheStringAndItsNameInAccessibilityText() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let document = body("a :t56bird: beside it",
                            custom: ["t56bird"],
                            images: ["t56bird": image])

        XCTAssertTrue(document.attributed.string.contains("\u{FFFC}"),
                      "a custom emoji with an image is drawn as an attachment")
        XCTAssertEqual(document.accessibilityText, "a t56bird beside it",
                       "the reader hears the name, never the literal :shortcode:")
        XCTAssertFalse(document.accessibilityText.contains(":t56bird:"),
                       "a literal shortcode must not leak into the accessibility label")
    }

    func testUnknownShortcodeStaysLiteralInBothTexts() {
        let document = body("a :definitely_unknown_t56: here")
        XCTAssertTrue(document.attributed.string.contains(":definitely_unknown_t56:"))
        XCTAssertTrue(document.accessibilityText.contains(":definitely_unknown_t56:"))
    }

    // MARK: - Block kinds are all in the one surface

    func testEveryBlockKindIsInTheSameString() {
        let document = body("""
        # heading

        paragraph

        > quoted

        - bullet one
        - bullet two

        1. ordered

        ```json
        {"a": 1}
        ```

        | Column | Value |
        |---|---|
        | alpha | 1 |
        """)
        let text = document.attributed.string
        for piece in ["heading", "paragraph", "quoted", "bullet one", "bullet two",
                      "ordered", "{\"a\": 1}", "Column", "alpha"] {
            XCTAssertTrue(text.contains(piece), "\(piece) must be selectable text, got '\(text)'")
        }
    }

    // MARK: - Sizing

    func testTheSurfaceSizesItselfToItsWidth() {
        let view = configuredView(body(String(repeating: "the quick brown fox jumps over the lazy dog. ",
                                             count: 6)))
        let wide = view.height(forWidth: 600)
        let narrow = view.height(forWidth: 120)
        XCTAssertGreaterThan(wide, 0)
        XCTAssertGreaterThan(narrow, wide, "a narrower body is taller — the text view wraps")
    }

    func testFontsFollowDynamicTypeRoles() {
        // The designed sizes are the ones `MarkdownMetrics` names; the role mapping is T45's, reused.
        XCTAssertEqual(TypeRole.nearest(to: 15), .subheadline)
        XCTAssertEqual(TypeRole.nearest(to: 13.5), .footnote)
        XCTAssertEqual(MarkdownMetrics.headingRole(1).uiTextStyle, .title2)
    }
}
