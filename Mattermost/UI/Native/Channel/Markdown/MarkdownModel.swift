// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/components/markdown/markdown.tsx (the renderer dispatch: paragraph, heading, code block,
//        block quote, list, table, thematic break, and which inline nodes become links/mentions/
//        channel links/emoticons), app/components/markdown/transform.ts (the AST→Mattermost-entity
//        pass: @mention, ~channel, :emoji:, emoticon replacement), app/utils/emoji/helpers.ts
//        (emoticon table shape). Licence: Apache-2.0 — http://www.apache.org/licenses/LICENSE-2.0
//
// This is a *reimplementation* of the render model, not a transpile: the upstream tree is a
// commonmark AST walked by React components, this is a small value-type block/inline tree that
// SwiftUI can diff (docs/component-map.md §1). The deltas are stated where they matter:
//  - **HTML is never interpreted.** Upstream runs the post through a sanitiser and then renders the
//    result; here every tag stays *literal text* (`<b>hi</b>` renders as the eight characters it is),
//    and the contents of `script`/`style`/`iframe`/`object`/`embed`/`svg` blocks are dropped before
//    parsing. That is the shell's security boundary: post text is untrusted (plugin HTML, pasted
//    markup) and a renderer that cannot execute markup cannot be tricked into it.
//  - link targets are allow-listed to http/https/mailto; anything else (`javascript:`, `data:`,
//    `file:`) degrades to its label as plain text, so a link tap can never leave the app's URL
//    handler with an executable scheme.

import Foundation

/// One table cell: a run of inline content.
typealias MarkdownCell = [MarkdownInline]

/// One block-level markdown construct.
enum MarkdownBlock: Equatable, Sendable {
    case paragraph([MarkdownInline])
    case heading(level: Int, [MarkdownInline])
    case codeBlock(language: String?, code: String)
    /// A GFM table: the header row and N body rows, each row a list of cells.
    case table(header: [MarkdownCell], rows: [[MarkdownCell]])
    case blockQuote([MarkdownBlock])
    /// `-`/`*`/`+` items, or `1.`/`1)` items when `ordered`.
    case list(ordered: Bool, start: Int, items: [[MarkdownInline]])
    case thematicBreak
}

/// One run of inline markdown. Nesting is explicit (`bold([...])`) so a renderer can flatten it into
/// an `AttributedString` without re-parsing anything.
indirect enum MarkdownInline: Equatable, Sendable {
    case text(String)
    case bold([MarkdownInline])
    case italic([MarkdownInline])
    case strikethrough([MarkdownInline])
    case code(String)
    case link(text: [MarkdownInline], url: String)
    /// A markdown image (`![alt](url)`). The shell draws it as a labelled link rather than fetching
    /// arbitrary remote images inside a post body; file attachments are the supported image path.
    case image(alt: String, url: String)
    /// A `:`-delimited emoji name (`:tada:`, `:+1:`, and custom names — the renderer decides which
    /// are actually available).
    case emoji(name: String)
    /// `@username`.
    case mention(username: String)
    /// `~channel-name`.
    case channelLink(name: String)
    /// A hard/soft line break inside a paragraph.
    case lineBreak
}

extension MarkdownInline {
    /// The text a screen reader (or a test) can compare against. `nil`-free: every case contributes.
    var plainText: String {
        switch self {
        case .text(let text), .code(let text): return text
        case .bold(let runs), .italic(let runs), .strikethrough(let runs): return Self.plainText(runs)
        case .link(let runs, let url):
            let label = Self.plainText(runs)
            return label.isEmpty ? url : label
        case .image(let alt, _): return alt
        case .emoji(let name): return ":\(name):"
        case .mention(let username): return "@\(username)"
        case .channelLink(let name): return "~\(name)"
        case .lineBreak: return "\n"
        }
    }

    static func plainText(_ runs: [MarkdownInline]) -> String {
        runs.map(\.plainText).joined()
    }

    /// The link target, when this run (or a nested run) carries a live one.
    ///
    /// An empty target is how the parser records "this looked like a link but the app will not open
    /// it" (a `javascript:`/`data:` label): it must read as *no link*, not as a link to nowhere.
    var linkURL: String? {
        switch self {
        case .link(_, let url): return url.isEmpty ? nil : url
        case .bold(let runs), .italic(let runs), .strikethrough(let runs):
            return runs.compactMap(\.linkURL).first
        default: return nil
        }
    }
}

extension MarkdownBlock {
    /// The plain text of a block, one line per block line. Used for accessibility labels and by the
    /// "does this post need folding?" length rule.
    var plainText: String {
        switch self {
        case .paragraph(let runs), .heading(_, let runs): return MarkdownInline.plainText(runs)
        case .codeBlock(_, let code): return code
        case .table(let header, let rows):
            return (header + rows.flatMap { $0 }).map { MarkdownInline.plainText($0) }
                .joined(separator: "\n")
        case .blockQuote(let blocks): return blocks.map(\.plainText).joined(separator: "\n")
        case .list(_, _, let items):
            return items.map { MarkdownInline.plainText($0) }.joined(separator: "\n")
        case .thematicBreak: return "—"
        }
    }
}

extension Array where Element == MarkdownBlock {
    /// Every inline run in the tree, in document order (tests walk this to prove no HTML became a
    /// bold/italic run and that a hostile link never carries a live target).
    var allInlines: [MarkdownInline] {
        var result: [MarkdownInline] = []

        func walk(_ runs: [MarkdownInline]) {
            for run in runs {
                result.append(run)
                switch run {
                case .bold(let inner), .italic(let inner), .strikethrough(let inner):
                    walk(inner)
                case .link(let inner, _):
                    walk(inner)
                default:
                    break
                }
            }
        }

        func walkBlocks(_ blocks: [MarkdownBlock]) {
            for block in blocks {
                switch block {
                case .paragraph(let runs), .heading(_, let runs): walk(runs)
                case .codeBlock: break
                case .table(let header, let rows):
                    for cell in header { walk(cell) }
                    for row in rows { for cell in row { walk(cell) } }
                case .blockQuote(let inner): walkBlocks(inner)
                case .list(_, _, let items): items.forEach(walk)
                case .thematicBreak: break
                }
            }
        }

        walkBlocks(self)
        return result
    }
}
