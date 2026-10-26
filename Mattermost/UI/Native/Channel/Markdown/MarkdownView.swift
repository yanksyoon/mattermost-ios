// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/components/markdown/markdown.tsx (block dispatch), markdown/markdown_block_quote,
//        markdown/markdown_code_block, markdown/markdown_table, markdown/markdown_list,
//        markdown/markdown_heading, markdown/markdown_link, markdown/markdown_latex (not rendered
//        here — see the note below), components/emoji (shortcode → character), app/utils/theme.ts
//        (the type scale a post body uses: 15 pt body, 15 pt semibold headings scaled by level).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §10; no
// upstream source copied. SwiftUI decomposition is this repo's own (component-map.md §1).
//
// The security property this file must keep, and the test that pins it:
// every run is drawn as `Text`/`AttributedString` — there is no `UIViewRepresentable`, no `WKWebView`
// and no `NSAttributedString(html:)` here, so **no post can introduce HTML that the app interprets**.
// `MarkdownParser` leaves tags as characters; this view draws those characters. (T34 test
// `testHTMLIsDrawnAsTextNeverInterpreted`.)

import SwiftUI

/// The little that is shared between block kinds.
private enum MarkdownMetrics {
    static let bodyFont = Font.system(size: 15)
    static let codeFont = Font.system(size: 13.5, design: .monospaced)
    static let bodyLineSpacing: CGFloat = 3
}

/// Draw one post's parsed body.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]
    /// A stable prefix for accessibility identifiers (`post.<id>.body`), used by the UI tests.
    var identifierPrefix: String = "markdown"
    /// The server's custom emoji, when the pane has them. `nil` = draw every shortcode as text.
    var emoji: EmojiCatalogue?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block)
                    .accessibilityIdentifier("\(identifierPrefix).block\(index)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let runs):
            MarkdownInlineText(runs: runs, emoji: emoji)
                .font(MarkdownMetrics.bodyFont)
                .lineSpacing(MarkdownMetrics.bodyLineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let level, let runs):
            MarkdownInlineText(runs: runs, emoji: emoji)
                .font(.system(size: MarkdownMetrics.headingSize(level), weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)

        case .codeBlock(let language, let code):
            CodeBlockView(language: language, code: code)

        case .blockQuote(let inner):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 3)
                MarkdownView(blocks: inner, identifierPrefix: "\(identifierPrefix).quote", emoji: emoji)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ordered ? "\(start + index)." : "•")
                            .font(MarkdownMetrics.bodyFont)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 16, alignment: .trailing)
                        MarkdownInlineText(runs: item, emoji: emoji)
                            .font(MarkdownMetrics.bodyFont)
                            .lineSpacing(MarkdownMetrics.bodyLineSpacing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .table(let header, let rows):
            // A table scrolls sideways rather than squeezing columns into a phone width — the
            // upstream table is also horizontally scrollable once it overflows.
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            MarkdownInlineText(runs: cell, emoji: emoji)
                                .font(.system(size: 13.5, weight: .semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                MarkdownInlineText(runs: cell, emoji: emoji)
                                    .font(.system(size: 13.5))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }

        case .thematicBreak:
            Divider()
        }
    }
}

/// One run of inline content: text (with its emphasis, links and colours) **and** the server's custom
/// emoji drawn as their images.
///
/// A custom emoji cannot live in an `AttributedString` (SwiftUI's `Text` does not render an image
/// attachment from attributes), so the run is split into segments and concatenated: `Text` + `Text`
/// keeps one wrapping paragraph, and each segment keeps the attributes it was given. A shortcode the
/// server does not know stays literal text (`:name:`), which is what the server itself renders.
///
/// The catalogue is **observed** rather than sampled once: `GET /emoji` lands after the first page of
/// posts is already on screen, so a body that resolved its shortcodes at first draw would keep the
/// literal `:name:` until the row was recycled (T34 review F7 — the live render proved it).
struct MarkdownInlineText: View {
    let runs: [MarkdownInline]
    var emoji: EmojiCatalogue?
    /// T39: the search terms to mark inside this run of text. Empty for every ordinary post.
    ///
    /// An environment value rather than a parameter, so a result row can highlight the body without
    /// every caller in between (PostRowView, the attachment section, the fold view) growing a
    /// highlight parameter it does not use.
    @Environment(\.searchHighlightTerms) private var highlight

    var body: some View {
        if let emoji {
            CatalogueInlineText(runs: runs, catalogue: emoji, highlight: highlight)
        } else {
            Text(MarkdownText.attributed(runs, highlight: highlight))
        }
    }
}

/// `MarkdownInlineText` with the server's emoji catalogue in hand.
private struct CatalogueInlineText: View {
    let runs: [MarkdownInline]
    @ObservedObject var catalogue: EmojiCatalogue
    var highlight: [SearchHighlightTerm] = []

    private var customNames: [String] {
        EmojiCatalogue.customNames(in: runs, catalogue: catalogue)
    }

    var body: some View {
        Group {
            if customNames.isEmpty {
                Text(MarkdownText.attributed(runs, highlight: highlight))
            } else {
                MarkdownText.composed(runs,
                                      custom: Set(customNames),
                                      images: catalogue.images)
                    // The composed form is a small `HStack` (text, emoji image, text…), and a bare
                    // stack has an empty accessibility label. Combined, VoiceOver reads the sentence
                    // with the emoji in place; the explicit label names the emoji the server's image
                    // stands for instead of leaking the raw `:shortcode:`.
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text(MarkdownText.accessibilityText(runs,
                                                                            custom: Set(customNames))))
            }
        }
        // One fetch per name, deduplicated inside the catalogue; the published image table redraws
        // this paragraph when the bytes land.
        .task(id: customNames) {
            for name in customNames {
                _ = await catalogue.image(for: name)
            }
        }
    }
}

private extension MarkdownMetrics {
    static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 22
        case 2: return 20
        case 3: return 18
        case 4: return 16.5
        default: return 15.5
        }
    }
}

// MARK: - Code

/// A fenced block: monospaced, horizontally scrollable, decorated by `CodeHighlighter` (colour only —
/// the text is always the bytes the author typed).
struct CodeBlockView: View {
    let language: String?
    let code: String

    var body: some View {
        let attributed = MarkdownText.highlighted(code: code, language: language)
        ScrollView(.horizontal, showsIndicators: true) {
            Text(attributed)
                .font(MarkdownMetrics.codeFont)
                .textSelection(.enabled)
                .padding(10)
                .fixedSize(horizontal: true, vertical: true)
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.2))
        )
        // A code block is a single accessibility element: VoiceOver should read the code, not the
        // colouring, and it must not stop on eleven separate coloured runs.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(language.map { "\($0) code" } ?? "Code")
        .accessibilityValue(code)
    }
}

// MARK: - Runs → AttributedString

enum MarkdownText {

    /// Every inline run, flattened into one `AttributedString`.
    ///
    /// `highlight` (T39) is the search-result emphasis: the terms the reader searched for are painted
    /// behind the characters they match. It is applied here, on the finished attributed string, so the
    /// markdown renderer keeps its single job (runs → attributed text) and the highlighting rules stay
    /// in one pure function (`SearchHighlighter`).
    static func attributed(_ runs: [MarkdownInline],
                           highlight: [SearchHighlightTerm] = []) -> AttributedString {
        var out = AttributedString()
        append(runs, to: &out, bold: false, italic: false, strike: false, link: nil)
        if !highlight.isEmpty {
            applySearchHighlight(highlight, to: &out)
        }
        return out
    }

    /// Paint every match of `terms` with a marking background.
    ///
    /// The ranges are found on the attributed string's own character view, so they cannot drift from
    /// what is drawn (the plain string and the attributed string's characters are appended in the same
    /// order by `append` above).
    static func applySearchHighlight(_ terms: [SearchHighlightTerm], to out: inout AttributedString) {
        for range in SearchHighlighter.ranges(in: out, terms: terms) where !range.isEmpty {
            out[range].backgroundColor = Color.yellow.opacity(0.35)
        }
    }

    private static func append(_ runs: [MarkdownInline],
                               to out: inout AttributedString,
                               bold: Bool,
                               italic: Bool,
                               strike: Bool,
                               link: URL?) {
        for run in runs {
            var piece = AttributedString(text(of: run))
            if bold { piece.inlinePresentationIntent = .stronglyEmphasized }
            if italic { piece.inlinePresentationIntent = .emphasized }
            if strike { piece.strikethroughStyle = .single }
            if let link { piece.link = link }
            if let tint = tint(of: run) { piece.foregroundColor = tint }
            if isCode(run) { piece.font = MarkdownMetrics.codeFont }
            out.append(piece)

            switch run {
            case .bold(let inner):
                append(inner, to: &out, bold: true, italic: italic, strike: strike, link: link)
            case .italic(let inner):
                append(inner, to: &out, bold: bold, italic: true, strike: strike, link: link)
            case .strikethrough(let inner):
                append(inner, to: &out, bold: bold, italic: italic, strike: true, link: link)
            case .link(let inner, let url):
                append(inner, to: &out, bold: bold, italic: italic, strike: strike,
                       link: url.isEmpty ? nil : URL(string: url))
            case .image(let alt, let url):
                // An image *in a post body* is not fetched by T34 (attachments S18; remote images
                // need the image proxy). It is drawn as its alt text with the URL kept as a link, so
                // what the author pointed at is still reachable and never silently disappears.
                if !alt.isEmpty {
                    var caption = AttributedString(" [\(alt)] ")
                    if let url = URL(string: url) { caption.link = url }
                    caption.foregroundColor = .secondary
                    out.append(caption)
                }
            case .text, .code, .emoji, .mention, .channelLink, .lineBreak:
                break
            }
        }
    }

    /// The characters a run contributes. A bold run contributes both its own (empty) text and then
    /// its children's — so containers return `""` and only leaves produce characters.
    private static func text(of run: MarkdownInline) -> String {
        switch run {
        case .text(let value): return value
        case .code(let value): return value
        case .emoji(let name): return EmojiShortcodes.character(for: name) ?? ":\(name):"
        case .mention(let username): return "@\(username)"
        case .channelLink(let name): return "~\(name)"
        case .lineBreak: return "\n"
        case .bold, .italic, .strikethrough, .link, .image: return ""
        }
    }

    private static func isCode(_ run: MarkdownInline) -> Bool {
        if case .code = run { return true }
        return false
    }

    private static func tint(of run: MarkdownInline) -> Color? {
        switch run {
        case .mention, .channelLink, .link: return .accentColor
        case .code: return .primary
        default: return nil
        }
    }

    /// Coloured code, from `CodeHighlighter`'s tokens.
    static func highlighted(code: String, language: String?) -> AttributedString {
        var out = AttributedString()
        for token in CodeHighlighter.tokens(code: code, language: language) {
            var piece = AttributedString(token.text)
            switch token.kind {
            case .keyword: piece.foregroundColor = Color.purple
            case .string: piece.foregroundColor = Color.red
            case .comment: piece.foregroundColor = Color.secondary
            case .number: piece.foregroundColor = Color.blue
            case .type: piece.foregroundColor = Color.teal
            case .plain: break
            }
            out.append(piece)
        }
        // An empty block still needs one character so the row keeps its height.
        return out.characters.isEmpty ? AttributedString(" ") : out
    }
}

// MARK: - Custom emoji

/// One piece of a paragraph: attributed text, or a custom emoji the server has an image for.
///
/// Splitting (rather than special-casing inside `attributed`) is what makes the custom-emoji rule
/// testable without a view: `segments` is a pure function of the runs and the set of custom names.
enum MarkdownSegment: Equatable {
    case text(AttributedString)
    /// The lower-cased emoji name; the view resolves it against the catalogue's loaded images.
    case emojiImage(String)
}

extension MarkdownText {

    /// Inline runs → segments, where every `:name:` in `custom` becomes an image segment.
    ///
    /// Text keeps its emphasis, colour and link attributes across a segment boundary: the walker
    /// carries the same attribute state the flat `attributed` walker does, and flushes a buffer
    /// whenever an image interrupts it.
    static func segments(_ runs: [MarkdownInline], custom: Set<String>) -> [MarkdownSegment] {
        var output: [MarkdownSegment] = []
        var buffer = AttributedString()

        func flush() {
            if !buffer.characters.isEmpty {
                output.append(.text(buffer))
                buffer = AttributedString()
            }
        }

        func walk(_ runs: [MarkdownInline], bold: Bool, italic: Bool, strike: Bool, link: URL?) {
            for run in runs {
                if case .emoji(let name) = run, custom.contains(name.lowercased()) {
                    flush()
                    output.append(.emojiImage(name.lowercased()))
                    continue
                }
                var piece = AttributedString(text(of: run))
                if bold { piece.inlinePresentationIntent = .stronglyEmphasized }
                if italic { piece.inlinePresentationIntent = .emphasized }
                if strike { piece.strikethroughStyle = .single }
                if let link { piece.link = link }
                if let tint = tint(of: run) { piece.foregroundColor = tint }
                if isCode(run) { piece.font = MarkdownMetrics.codeFont }
                buffer.append(piece)

                switch run {
                case .bold(let inner):
                    walk(inner, bold: true, italic: italic, strike: strike, link: link)
                case .italic(let inner):
                    walk(inner, bold: bold, italic: true, strike: strike, link: link)
                case .strikethrough(let inner):
                    walk(inner, bold: bold, italic: italic, strike: true, link: link)
                case .link(let inner, let url):
                    walk(inner, bold: bold, italic: italic, strike: strike,
                         link: url.isEmpty ? nil : URL(string: url))
                case .image(let alt, let url):
                    if !alt.isEmpty {
                        var caption = AttributedString(" [\(alt)] ")
                        if let url = URL(string: url) { caption.link = url }
                        caption.foregroundColor = .secondary
                        buffer.append(caption)
                    }
                case .text, .code, .emoji, .mention, .channelLink, .lineBreak:
                    break
                }
            }
        }

        walk(runs, bold: false, italic: false, strike: false, link: nil)
        flush()
        return output
    }

    /// The sentence as it should be *heard*: text segments verbatim, every resolved custom emoji as
    /// its name instead of the raw `:shortcode:` the reader never sees.
    ///
    /// Used as the accessibility label of a composed paragraph, where the rendered `HStack` of text
    /// runs and images has no label of its own.
    static func accessibilityText(_ runs: [MarkdownInline], custom: Set<String>) -> String {
        segments(runs, custom: custom).map { segment in
            switch segment {
            case .text(let attributed):
                return String(attributed.characters)
            case .emojiImage(let name):
                return name.replacingOccurrences(of: "_", with: " ")
            }
        }.joined()
    }

    /// The rendered paragraph: `Text` concatenation so custom emoji images sit inline with the text.
    /// An image for a name that has not loaded yet falls back to the shortcode's character (or the
    /// literal `:name:`), so a slow image never leaves a gap in the sentence.
    static func composed(_ runs: [MarkdownInline],
                         custom: Set<String>,
                         images: [String: UIImage]) -> Text {
        segments(runs, custom: custom).reduce(Text(verbatim: "")) { text, segment in
            switch segment {
            case .text(let attributed):
                return text + Text(attributed)
            case .emojiImage(let name):
                if let image = images[name] {
                    // Text-sized, not the upload's own pixels: a 40 pt PNG inside `Text` pushes the
                    // paragraph's lines apart and drops the emoji onto its own line instead of
                    // sitting inline with the sentence.
                    return text + Text(Image(uiImage: image.emojiSized()).renderingMode(.original))
                }
                return text + Text(EmojiShortcodes.character(for: name) ?? ":\(name):")
            }
        }
    }
}

extension UIImage {
    /// A copy of a server emoji image at the height of body text.
    ///
    /// `/emoji/{id}/image` answers with whatever the uploader sent (the T34 fixture's is 40×40).
    /// `Text(Image)` draws that at full size, which is how a custom emoji ended up breaking the line it
    /// belongs to; the emoji is drawn at `height` points with its aspect ratio kept.
    func emojiSized(height: CGFloat = 18) -> UIImage {
        let aspect = size.height > 0 ? size.width / size.height : 1
        let target = CGSize(width: (height * aspect).rounded(), height: height)
        guard size.height > height || size.width > target.width else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

// MARK: - Emoji

/// The shortcodes a reader meets most often, rendered as characters.
///
/// This is the **built-in** Unicode set only. A `:name:` that is not here is resolved against the
/// server's own custom emoji (`EmojiCatalogue` → `GET /emoji`), and only when the server does not
/// know it either does it stay literal `:name:` — which is what the server's own web client renders
/// for an unknown shortcode too.
enum EmojiShortcodes {
    static let table: [String: String] = [
        "tada": "🎉", "heart": "❤️", "red_heart": "❤️", "broken_heart": "💔",
        "thumbsup": "👍", "+1": "👍", "thumbsdown": "👎", "-1": "👎",
        "smile": "😄", "smiley": "😃", "grinning": "😀", "joy": "😂", "laughing": "😆",
        "wink": "😉", "thinking_face": "🤔", "thinking": "🤔", "sob": "😭", "cry": "😢",
        "sunglasses": "😎", "heart_eyes": "😍", "blush": "😊", "neutral_face": "😐",
        "rocket": "🚀", "fire": "🔥", "eyes": "👀", "100": "💯", "clap": "👏",
        "raised_hands": "🙌", "pray": "🙏", "muscle": "💪", "wave": "👋", "ok_hand": "👌",
        "point_right": "👉", "point_left": "👈", "point_up": "☝️", "skull": "💀",
        "white_check_mark": "✅", "heavy_check_mark": "✔️", "x": "❌", "warning": "⚠️",
        "bulb": "💡", "sparkles": "✨", "star": "⭐", "zap": "⚡", "bug": "🐛",
        "package": "📦", "book": "📖", "memo": "📝", "calendar": "📆", "clock1": "🕐",
        "coffee": "☕", "beer": "🍺", "pizza": "🍕", "cake": "🍰", "apple": "🍎"
    ]

    static func character(for name: String) -> String? {
        table[name.lowercased()]
    }
}

// MARK: - Search highlighting (T39)

/// The search terms a markdown body should mark.
///
/// An environment value, not a parameter: the search result row is the only producer, and the consumer
/// is `MarkdownInlineText` several views deep inside `PostRowView`. Threading it as a parameter would
/// add a highlight argument to every row/attachment/fold initialiser on the way, most of which would
/// always pass `[]`.
///
/// The default is empty, so every non-search rendering (a channel's timeline, a thread, a preview) is
/// byte-for-byte what it drew before T39.
struct SearchHighlightTermsKey: EnvironmentKey {
    static let defaultValue: [SearchHighlightTerm] = []
}

extension EnvironmentValues {
    var searchHighlightTerms: [SearchHighlightTerm] {
        get { self[SearchHighlightTermsKey.self] }
        set { self[SearchHighlightTermsKey.self] = newValue }
    }
}
