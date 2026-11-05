// T56 (card t_38e0eac6) — one selectable surface for a whole post body.
//
// Owner-reported defect: "the texts on the messages cannot be copied via mouse drag". The cause was
// structural, not a missing modifier: `MarkdownView` draws a body block by block, each block its own
// `Text` with `.textSelection(.enabled)`, and SwiftUI scopes selection to one `Text`. A drag that
// starts in paragraph 1 cannot extend into paragraph 2, so a normal multi-paragraph message can never
// be selected as one range.
//
// This file is the replacement surface: **one** read-only, selectable `UITextView` per post body whose
// content is an `NSAttributedString` built from the *parsed runs* (`MarkdownBlock`/`MarkdownInline`).
//
// Security invariant (the same one `MarkdownView.swift` states, and the test
// `T34MarkdownTests.testHTMLIsDrawnAsTextNeverInterpreted` pins):
//   * there is no HTML path here — no `NSAttributedString(html:)`, no `NSAttributedString(data:options:)`,
//     no WebView. Every character is written by the run walker below, so `<b>x</b>` renders as the seven
//     characters it is, exactly as it does in the SwiftUI renderer.
//   * link targets come from the parser, which already allow-lists http/https/mailto; a tap is routed to
//     the caller's opener (`SwiftUI`'s `openURL`, the same one `Text` links used) and the default
//     handler is refused, so nothing opens that the shell did not decide to open.
//
// Parity note (deliberate divergence from mobile, recorded in `docs/PARITY.md`): the pinned mobile app
// makes post bodies **non-selectable** (`app/components/markdown/markdown.tsx:208-237` sets RN
// `selectable` only for a table cell, and only when `copyAndPasteProtection` is off). The behaviour
// asked for here is the desktop/webapp one: ordinary selection over the whole post, Cmd+C, triple-click
// a paragraph. This is the macOS client, so the desktop behaviour is the target.
//
// Why the whole body is one attributed string rather than a selectable overlay per block: only a single
// text container can hold a selection that crosses a paragraph boundary. The layout deltas that buys
// are stated in `docs/t_38e0eac6-build-note.md` (tables become tab-aligned rows; a fenced block wraps
// instead of scrolling sideways; the quote bar and the code card are drawn by a layout manager).

import SwiftUI
import UIKit

// MARK: - The rendered document

/// One post body flattened into the string and attributes the selectable surface draws.
struct MarkdownBodyDocument: Equatable {
    /// What is drawn and selected. Copies as `.string` minus custom-emoji attachments (which copy as
    /// U+FFFC, the same character a pasteboard would get from any inline image).
    let attributed: NSAttributedString
    /// What a reader *hears*: the drawn sentences with every custom-emoji image replaced by the name
    /// it stands for. This is the text view's accessibility label — a body must never leak the literal
    /// `:shortcode:` the reader does not see.
    let accessibilityText: String
    /// Changes when the drawn characters, the resolved emoji images, the highlight terms or the type
    /// size change. The view resets its text storage only when this changes, so an unrelated redraw
    /// (a reaction landing, the pane re-rendering) cannot clear the reader's selection.
    let revision: String
}

// MARK: - Runs → attributed string

enum MarkdownBodyText {

    /// Custom attributes the layout manager uses to draw block decoration behind the text.
    enum Attribute {
        static let decoration = NSAttributedString.Key("mm.markdown.decoration")
        static let decorationColor = NSAttributedString.Key("mm.markdown.decorationColor")
    }

    enum Decoration: String {
        case code
        case quote
    }

    /// Build the body document. Pure: no view, no catalogue, no HTML — callers pass the already-parsed
    /// blocks plus the resolved emoji images, which is what makes the result testable.
    static func document(_ blocks: [MarkdownBlock],
                         custom: Set<String> = [],
                         images: [String: UIImage] = [:],
                         highlight: [SearchHighlightTerm] = [],
                         contrast: ColorSchemeContrast = .standard,
                         scaleKey: String = "") -> MarkdownBodyDocument {
        let style = Style(custom: custom,
                          images: images,
                          quoteBarColor: UIColor.secondaryLabel.withAlphaComponent(
                              ContrastPolicy.separatorOpacity(0.35, contrast: contrast)))
        let builder = Builder(style: style)
        builder.append(blocks)
        let out = builder.output
        if !highlight.isEmpty {
            applyHighlight(highlight, to: out)
        }
        return MarkdownBodyDocument(attributed: out,
                                    accessibilityText: builder.accessibilityText(),
                                    revision: builder.revision(scaleKey: scaleKey, highlight: highlight))
    }

    /// Every custom emoji name a block tree uses, in document order, lower-cased.
    ///
    /// The body is fetched in one pass rather than per paragraph: the catalogue deduplicates the image
    /// downloads, and a body with the same emoji in two paragraphs must not ask twice.
    @MainActor
    static func customNames(in blocks: [MarkdownBlock], catalogue: EmojiCatalogue) -> [String] {
        var names: [String] = []

        func walk(_ runs: [MarkdownInline]) {
            for name in EmojiCatalogue.customNames(in: runs, catalogue: catalogue) where !names.contains(name) {
                names.append(name)
            }
        }

        func walkBlocks(_ blocks: [MarkdownBlock]) {
            for block in blocks {
                switch block {
                case .paragraph(let runs), .heading(_, let runs):
                    walk(runs)
                case .codeBlock, .thematicBreak:
                    break
                case .table(let header, let rows):
                    for cell in header { walk(cell) }
                    for row in rows { for cell in row { walk(cell) } }
                case .blockQuote(let inner):
                    walkBlocks(inner)
                case .list(_, _, let items):
                    items.forEach(walk)
                }
            }
        }

        walkBlocks(blocks)
        return names
    }

    /// Paint every match of `terms`, using the same matcher the SwiftUI renderer used, so a search
    /// result highlights the same characters on the selectable surface.
    private static func applyHighlight(_ terms: [SearchHighlightTerm], to out: NSMutableAttributedString) {
        let text = out.string
        for range in SearchHighlighter.matches(in: text, terms: terms) where !range.isEmpty {
            out.addAttribute(.backgroundColor,
                             value: UIColor.systemYellow.withAlphaComponent(0.35),
                             range: NSRange(range, in: text))
        }
    }

    // MARK: Style

    private struct Style {
        var custom: Set<String>
        var images: [String: UIImage]
        var quoteBarColor: UIColor
    }

    private final class Builder {
        let style: Style
        let output = NSMutableAttributedString()
        /// Emoji names inserted as attachments, in draw order — `accessibilityText()` substitutes them
        /// back into the string in the same order.
        private var attachmentNames: [String] = []

        init(style: Style) { self.style = style }

        var bodyFont: UIFont { uiFont(15) }
        var codeFont: UIFont { uiFont(13.5, mono: true) }

        func append(_ blocks: [MarkdownBlock]) {
            for block in blocks { append(block, quoteDepth: 0) }
            // Every paragraph above ends with its own newline (that newline carries the paragraph
            // style, so `paragraphSpacing` applies). The document itself has no trailing empty line.
            if output.length > 0 {
                output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
            }
        }

        private func append(_ block: MarkdownBlock, quoteDepth: Int) {
            let indent = CGFloat(quoteDepth) * 14
            switch block {
            case .paragraph(let runs):
                appendParagraph(inline(runs, font: bodyFont, color: .label),
                                style: bodyStyle(indent: indent),
                                decoration: quoteDepth > 0 ? .quote : nil)

            case .heading(let level, let runs):
                appendParagraph(inline(runs, font: headingFont(level), color: .label),
                                style: headingStyle(indent: indent),
                                decoration: quoteDepth > 0 ? .quote : nil)

            case .codeBlock(_, let code):
                // The parser already stripped the fence and the language line. Nothing but the code
                // bytes reaches the string, which is what T3 copies.
                var text = code
                while text.hasSuffix("\n") { text.removeLast() }
                let content = NSAttributedString(string: text.isEmpty ? " " : text,
                                                 attributes: [.font: codeFont,
                                                              .foregroundColor: UIColor.label])
                appendParagraph(content, style: codeStyle(indent: indent), decoration: .code)

            case .blockQuote(let inner):
                for block in inner { append(block, quoteDepth: quoteDepth + 1) }

            case .list(let ordered, let start, let items):
                for (index, item) in items.enumerated() {
                    let marker = ordered ? "\(start + index)." : "•"
                    let content = NSMutableAttributedString(
                        string: marker + "\t",
                        attributes: [.font: bodyFont, .foregroundColor: UIColor.secondaryLabel])
                    content.append(inline(item, font: bodyFont, color: .label))
                    appendParagraph(content,
                                    style: listStyle(indent: indent),
                                    decoration: quoteDepth > 0 ? .quote : nil)
                }

            case .table(let header, let rows):
                // A table in a selectable flow is a row per line with tab stops: the horizontal Grid
                // cannot be part of one text container. Copy yields tab-separated columns, which is
                // what a person pasting a table into a spreadsheet expects.
                appendParagraph(tableRow(header, bold: true),
                                style: tableStyle(indent: indent),
                                decoration: quoteDepth > 0 ? .quote : nil)
                for row in rows {
                    appendParagraph(tableRow(row, bold: false),
                                    style: tableStyle(indent: indent),
                                    decoration: quoteDepth > 0 ? .quote : nil)
                }

            case .thematicBreak:
                appendParagraph(NSAttributedString(string: "———",
                                                   attributes: [.font: bodyFont,
                                                                .foregroundColor: UIColor.tertiaryLabel]),
                                style: bodyStyle(indent: indent),
                                decoration: nil)
            }
        }

        private func tableRow(_ cells: [MarkdownCell], bold: Bool) -> NSAttributedString {
            let row = NSMutableAttributedString()
            for (index, cell) in cells.enumerated() {
                if index > 0 {
                    row.append(NSAttributedString(string: "\t", attributes: [.font: bodyFont]))
                }
                row.append(inline(cell, font: bold ? uiFont(13.5, weight: .semibold) : uiFont(13.5),
                                  color: .label))
            }
            return row
        }

        // MARK: Inline

        private func inline(_ runs: [MarkdownInline],
                            font: UIFont,
                            color: UIColor,
                            bold: Bool = false,
                            italic: Bool = false,
                            strike: Bool = false,
                            link: URL? = nil) -> NSAttributedString {
            let out = NSMutableAttributedString()
            for run in runs {
                switch run {
                case .text(let value):
                    out.append(piece(value, font: font, color: color,
                                     bold: bold, italic: italic, strike: strike, link: link))

                case .code(let value):
                    out.append(piece(value, font: codeFont, color: .label,
                                     bold: bold, italic: italic, strike: strike, link: link))

                case .emoji(let name):
                    let key = name.lowercased()
                    if style.custom.contains(key), let image = style.images[key] {
                        out.append(attachment(image, name: key, font: font))
                    } else if let character = EmojiShortcodes.character(for: name) {
                        out.append(piece(character, font: font, color: color,
                                         bold: bold, italic: italic, strike: strike, link: link))
                    } else {
                        // Unknown shortcode: the server's own web client also draws `:name:`.
                        out.append(piece(":\(name):", font: font, color: color,
                                         bold: bold, italic: italic, strike: strike, link: link))
                    }

                case .mention(let username):
                    out.append(piece("@" + username, font: font, color: .tintColor,
                                     bold: bold, italic: italic, strike: strike, link: link))

                case .channelLink(let name):
                    out.append(piece("~" + name, font: font, color: .tintColor,
                                     bold: bold, italic: italic, strike: strike, link: link))

                case .lineBreak:
                    out.append(piece("\n", font: font, color: color,
                                     bold: bold, italic: italic, strike: strike, link: link))

                case .bold(let inner):
                    out.append(inline(inner, font: font, color: color,
                                      bold: true, italic: italic, strike: strike, link: link))

                case .italic(let inner):
                    out.append(inline(inner, font: font, color: color,
                                      bold: bold, italic: true, strike: strike, link: link))

                case .strikethrough(let inner):
                    out.append(inline(inner, font: font, color: color,
                                      bold: bold, italic: italic, strike: true, link: link))

                case .link(let inner, let url):
                    out.append(inline(inner, font: font, color: color,
                                      bold: bold, italic: italic, strike: strike,
                                      link: url.isEmpty ? nil : URL(string: url)))

                case .image(let alt, let url):
                    // Same rule as the SwiftUI renderer: an image in a body is drawn as its alt text
                    // with the target kept as a link, never fetched.
                    if !alt.isEmpty {
                        out.append(piece(" [\(alt)] ", font: font, color: .secondaryLabel,
                                         bold: bold, italic: italic, strike: strike,
                                         link: URL(string: url)))
                    }
                }
            }
            return out
        }

        private func piece(_ text: String,
                           font: UIFont,
                           color: UIColor,
                           bold: Bool,
                           italic: Bool,
                           strike: Bool,
                           link: URL?) -> NSAttributedString {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: styled(font, bold: bold, italic: italic),
                .foregroundColor: color
            ]
            if strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link { attributes[.link] = link }
            return NSAttributedString(string: text, attributes: attributes)
        }

        private func attachment(_ image: UIImage, name: String, font: UIFont) -> NSAttributedString {
            let sized = image.emojiSized()
            let attachment = NSTextAttachment()
            attachment.image = sized
            attachment.bounds = CGRect(x: 0,
                                       y: (font.capHeight - sized.size.height) / 2,
                                       width: sized.size.width,
                                       height: sized.size.height)
            attachmentNames.append(name)
            return NSAttributedString(attachment: attachment)
        }

        private func styled(_ font: UIFont, bold: Bool, italic: Bool) -> UIFont {
            guard bold || italic else { return font }
            var traits = font.fontDescriptor.symbolicTraits
            if bold { traits.insert(.traitBold) }
            if italic { traits.insert(.traitItalic) }
            guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
            return UIFont(descriptor: descriptor, size: font.pointSize)
        }

        // MARK: Fonts (the UIKit side of `MarkdownMetrics`)

        /// A Dynamic Type font for a designed point size. `MarkdownMetrics.bodyFont` is
        /// `Font.scaled(15)`; this is the same idea through `TypeRole.nearest(to:)`, so the body text
        /// keeps its designed size at the default setting and scales with the reader's setting after.
        private func uiFont(_ pointSize: CGFloat,
                            weight: UIFont.Weight = .regular,
                            mono: Bool = false) -> UIFont {
            let style = TypeRole.nearest(to: pointSize)
            let base = UIFont.preferredFont(forTextStyle: style.uiTextStyle)
            var descriptor = base.fontDescriptor
            if mono { descriptor = descriptor.withDesign(.monospaced) ?? descriptor }
            if weight != .regular {
                descriptor = descriptor.addingAttributes([
                    .traits: [UIFontDescriptor.TraitKey.weight: weight]
                ])
            }
            return UIFont(descriptor: descriptor, size: base.pointSize)
        }

        private func headingFont(_ level: Int) -> UIFont {
            let role = MarkdownMetrics.headingRole(level)
            return UIFontMetrics(forTextStyle: role.uiTextStyle)
                .scaledFont(for: UIFont.systemFont(ofSize: role.defaultPointSize, weight: .semibold))
        }

        // MARK: Paragraph shapes

        private func bodyStyle(indent: CGFloat) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = MarkdownMetrics.bodyLineSpacing
            style.paragraphSpacing = 8
            style.headIndent = indent
            style.firstLineHeadIndent = indent
            return style
        }

        private func headingStyle(indent: CGFloat) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 2
            style.paragraphSpacingBefore = 6
            style.paragraphSpacing = 6
            style.headIndent = indent
            style.firstLineHeadIndent = indent
            return style
        }

        private func listStyle(indent: CGFloat) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = MarkdownMetrics.bodyLineSpacing
            style.paragraphSpacing = 2
            style.headIndent = indent + 20
            style.firstLineHeadIndent = indent
            style.tabStops = [NSTextTab(textAlignment: .left, location: indent + 20)]
            style.defaultTabInterval = 20
            return style
        }

        private func codeStyle(indent: CGFloat) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 2
            style.paragraphSpacing = 8
            style.headIndent = indent + 10
            style.firstLineHeadIndent = indent + 10
            return style
        }

        private func tableStyle(indent: CGFloat) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 2
            style.paragraphSpacing = 2
            style.headIndent = indent
            style.firstLineHeadIndent = indent
            style.defaultTabInterval = 90
            return style
        }

        private func appendParagraph(_ content: NSAttributedString,
                                     style: NSParagraphStyle,
                                     decoration: Decoration?) {
            let start = output.length
            output.append(content)
            output.append(NSAttributedString(string: "\n",
                                             attributes: [.paragraphStyle: style,
                                                          .font: bodyFont]))
            let range = NSRange(location: start, length: output.length - start)
            output.addAttribute(.paragraphStyle, value: style, range: range)
            if let decoration {
                output.addAttribute(Attribute.decoration, value: decoration.rawValue, range: range)
                if decoration == .quote {
                    output.addAttribute(Attribute.decorationColor,
                                        value: self.style.quoteBarColor,
                                        range: range)
                }
            }
        }

        func revision(scaleKey: String, highlight: [SearchHighlightTerm]) -> String {
            [
                output.string,
                attachmentNames.joined(separator: ","),
                style.images.keys.sorted().joined(separator: ","),
                highlight.map(\.text).joined(separator: ","),
                String(describing: style.quoteBarColor),
                scaleKey,
                "\(bodyFont.pointSize)"
            ].joined(separator: "|")
        }

        func accessibilityText() -> String {
            var text = ""
            var index = 0
            for character in output.string {
                if character == "\u{FFFC}", index < attachmentNames.count {
                    text += attachmentNames[index].replacingOccurrences(of: "_", with: " ")
                    index += 1
                } else {
                    text.append(character)
                }
            }
            return text
        }
    }
}

// MARK: - TypeRole → UIKit

extension TypeRole {
    /// The UIKit text style for this role. `AccessibleType.swift` deliberately exposes only the
    /// SwiftUI `Font.TextStyle`; this is the one UIKit mapping, used solely by the selectable body.
    var uiTextStyle: UIFont.TextStyle {
        switch self {
        case .caption2: return .caption2
        case .caption: return .caption1
        case .footnote: return .footnote
        case .subheadline: return .subheadline
        case .callout: return .callout
        case .body: return .body
        case .title3: return .title3
        case .title2: return .title2
        case .title: return .title1
        case .largeTitle: return .largeTitle
        }
    }
}

// MARK: - The view

/// One post body as a single selectable surface.
struct SelectableMarkdownBody: View {
    let blocks: [MarkdownBlock]
    /// `post.<id>.body` — the surface publishes its one range as `<prefix>.block0`, the identifier the
    /// live suite already reads (`bodyText`), so the text stays addressable exactly as before.
    var identifierPrefix: String
    var emoji: EmojiCatalogue?

    @Environment(\.openURL) private var openURL
    @Environment(\.searchHighlightTerms) private var highlight
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if let emoji {
                CatalogueBody(blocks: blocks,
                              identifier: "\(identifierPrefix).block0",
                              catalogue: emoji,
                              highlight: highlight,
                              contrast: contrast,
                              scaleKey: "\(typeSize)",
                              linkOpener: { openURL($0) })
            } else {
                MarkdownBodyRepresentable(
                    document: MarkdownBodyText.document(blocks,
                                                        highlight: highlight,
                                                        contrast: contrast,
                                                        scaleKey: "\(typeSize)"),
                    identifier: "\(identifierPrefix).block0",
                    linkOpener: { openURL($0) })
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `SelectableMarkdownBody` with the server's emoji catalogue in hand.
///
/// The catalogue is observed rather than sampled: `GET /emoji` lands after the first posts are drawn,
/// so a body that resolved its shortcodes once would keep the literal `:name:` until the row was
/// recycled (the defect T34 review F7 found in the SwiftUI renderer — the same rule has to hold here).
private struct CatalogueBody: View {
    let blocks: [MarkdownBlock]
    let identifier: String
    @ObservedObject var catalogue: EmojiCatalogue
    var highlight: [SearchHighlightTerm]
    var contrast: ColorSchemeContrast
    var scaleKey: String
    var linkOpener: (URL) -> Void

    private var customNames: [String] {
        MarkdownBodyText.customNames(in: blocks, catalogue: catalogue)
    }

    var body: some View {
        MarkdownBodyRepresentable(document: MarkdownBodyText.document(blocks,
                                                                      custom: Set(customNames),
                                                                      images: images,
                                                                      highlight: highlight,
                                                                      contrast: contrast,
                                                                      scaleKey: scaleKey),
                                  identifier: identifier,
                                  linkOpener: linkOpener)
            .task(id: customNames) {
                for name in customNames {
                    _ = await catalogue.image(for: name)
                }
            }
    }

    /// Only the images that have actually landed: a nil image keeps the shortcode's character (or the
    /// literal name) in place until the bytes arrive, which is what stops a slow image from leaving a
    /// gap in the sentence.
    private var images: [String: UIImage] {
        var map: [String: UIImage] = [:]
        for name in customNames {
            if let image = catalogue.images[name] { map[name] = image }
        }
        return map
    }
}

// MARK: - UIViewRepresentable

struct MarkdownBodyRepresentable: UIViewRepresentable {
    let document: MarkdownBodyDocument
    let identifier: String
    let linkOpener: (URL) -> Void

    func makeUIView(context: Context) -> MarkdownBodyUITextView {
        let view = MarkdownBodyUITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.adjustsFontForContentSizeCategory = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.contentInset = .zero
        view.dataDetectorTypes = []
        view.linkTextAttributes = [.foregroundColor: UIColor.tintColor]
        view.accessibilityIdentifier = identifier
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        context.coordinator.apply(document, to: view)
        return view
    }

    func updateUIView(_ view: MarkdownBodyUITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(document, to: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiView: MarkdownBodyUITextView,
                      context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: uiView.height(forWidth: width))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownBodyRepresentable

        init(parent: MarkdownBodyRepresentable) {
            self.parent = parent
        }

        func apply(_ document: MarkdownBodyDocument, to view: MarkdownBodyUITextView) {
            view.onCopy = MarkdownBodyDiagnostics.isEnabled
                ? { [weak view] text in
                    view?.accessibilityValue = "copied:" + text
                }
                : nil
            view.apply(document)
            if MarkdownBodyDiagnostics.isEnabled, view.accessibilityValue == nil {
                view.accessibilityValue = "selection:"
            }
        }

        /// A tap on a link run goes to the caller's opener; the default handler is refused, so a post
        /// cannot make the shell open a URL the shell did not choose to open.
        func textView(_ textView: UITextView,
                      shouldInteractWith URL: URL,
                      in characterRange: NSRange,
                      interaction: UITextItemInteraction) -> Bool {
            parent.linkOpener(URL)
            return false
        }

        /// The pre-iOS-10 form is still what Catalyst routes some clicks through.
        func textView(_ textView: UITextView,
                      shouldInteractWith URL: URL,
                      in characterRange: NSRange) -> Bool {
            parent.linkOpener(URL)
            return false
        }

        /// `-uiTestExposeBodySelection` only: publish what is selected — and, while a selection exists,
        /// the window-space point of its end handle. On iOS touch the system shows the edit menu on
        /// the long press and a person extends the selection by dragging the handle; a live test needs
        /// that handle's position to do the same thing a person does.
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard MarkdownBodyDiagnostics.isEnabled else { return }
            guard let body = textView as? MarkdownBodyUITextView,
                  textView.selectedRange.length > 0,
                  let handle = body.selectionEndHandlePoint() else {
                textView.accessibilityValue = "selection:"
                return
            }
            textView.accessibilityValue = "selection:x=\(handle.x);y=\(handle.y);" + body.selectedText
        }
    }
}

// MARK: - The text view

/// A self-sizing, read-only, selectable text view that draws block decoration behind its text.
///
/// TextKit 1 is used deliberately: the quote bar and the code card are painted by
/// `MarkdownBodyLayoutManager.drawBackground`, which a TextKit 2 `UITextView()` does not give us a
/// layout manager for.
final class MarkdownBodyUITextView: UITextView {
    private var currentRevision: String?
    private var measuredWidth: CGFloat = 0
    /// Called after a Copy action, with the pasteboard's new string. Only set by the UI-test seam.
    var onCopy: ((String) -> Void)?

    init() {
        let storage = NSTextStorage()
        let layout = MarkdownBodyLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
    }

    required init?(coder: NSCoder) {
        fatalError("MarkdownBodyUITextView is created in code only")
    }

    func apply(_ document: MarkdownBodyDocument) {
        if currentRevision != document.revision {
            currentRevision = document.revision
            // Keep the reader's selection across a content-preserving redraw; clamp it if the text
            // really did change (an edit, an emoji image landing).
            let previous = selectedRange
            textStorage.setAttributedString(document.attributed)
            let length = textStorage.length
            let location = min(previous.location, length)
            selectedRange = NSRange(location: location, length: min(previous.length, length - location))
            invalidateIntrinsicContentSize()
        }
        accessibilityLabel = document.accessibilityText
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        textContainer.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        return ceil(layoutManager.usedRect(for: textContainer).height)
    }

    override var intrinsicContentSize: CGSize {
        let width = bounds.width > 0 ? bounds.width : (superview?.bounds.width ?? 0)
        guard width > 0 else { return CGSize(width: UIView.noIntrinsicMetric, height: 1) }
        return CGSize(width: UIView.noIntrinsicMetric, height: height(forWidth: width))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(bounds.width - measuredWidth) > 0.5 {
            measuredWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }

    /// The system Copy action, observed (never replaced). The pasteboard is written by UIKit; the seam
    /// reads it back from *this* process, so a test does not need the cross-app paste prompt.
    override func copy(_ sender: Any?) {
        super.copy(sender)
        onCopy?(UIPasteboard.general.string ?? "")
    }

    var selectedText: String {
        guard selectedRange.length > 0,
              NSMaxRange(selectedRange) <= textStorage.length else { return "" }
        return (textStorage.string as NSString).substring(with: selectedRange)
    }

    /// The window-space point of the selection's **end** handle — the small dot a person drags to
    /// extend a selection. Only read by the UI-test seam; the drawing is the system's own.
    func selectionEndHandlePoint() -> CGPoint? {
        guard let range = selectedTextRange else { return nil }
        let rects = selectionRects(for: range)
        guard let last = rects.last else { return nil }
        let point = CGPoint(x: last.rect.maxX, y: last.rect.maxY)
        guard point.x.isFinite, point.y.isFinite else { return nil }
        return convert(point, to: nil)
    }
}

/// Draws the quote bar and the code card behind the glyphs they belong to.
final class MarkdownBodyLayoutManager: NSLayoutManager {

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        guard let storage = textStorage else {
            super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(MarkdownBodyText.Attribute.decoration, in: characters) { value, range, _ in
            guard let raw = value as? String,
                  let decoration = MarkdownBodyText.Decoration(rawValue: raw),
                  let container = textContainers.first else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var lineRects: [CGRect] = []
            var minX = CGFloat.greatestFiniteMagnitude
            var union = CGRect.null
            enumerateLineFragments(forGlyphRange: glyphs) { lineRect, usedRect, _, _, _ in
                lineRects.append(lineRect)
                minX = min(minX, usedRect.minX)
                union = union.union(usedRect)
            }
            guard !lineRects.isEmpty, !union.isNull else { return }
            switch decoration {
            case .code:
                let width = container.size.width
                UIColor.secondarySystemBackground.setFill()
                UIBezierPath(roundedRect: CGRect(x: 0,
                                                 y: union.minY + 1,
                                                 width: width,
                                                 height: max(0, union.height - 2))
                                .offsetBy(dx: origin.x, dy: origin.y),
                             cornerRadius: 8).fill()
            case .quote:
                let color = storage.attribute(MarkdownBodyText.Attribute.decorationColor,
                                              at: range.location,
                                              effectiveRange: nil) as? UIColor
                (color ?? UIColor.secondaryLabel).setFill()
                UIBezierPath(rect: CGRect(x: minX - 9,
                                          y: union.minY,
                                          width: 3,
                                          height: union.height)
                                .offsetBy(dx: origin.x, dy: origin.y)).fill()
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

// MARK: - UI-test seams

/// Launch-argument-only diagnostics for the live selection test.
///
/// Same shape as every other seam in this repo (`ChannelUITestHook`): read `ProcessInfo` at launch, so
/// a build a person runs cannot reach this code path.
enum MarkdownBodyDiagnostics {
    /// `-uiTestExposeBodySelection` publishes `selection:<text>` and `copied:<text>` as the body
    /// surface's accessibility value. A UI test can then read what a drag selected and what Copy put
    /// on the pasteboard without the cross-app paste permission prompt.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTestExposeBodySelection")
    }
}
