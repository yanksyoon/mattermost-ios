// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/components/post_body/post_body.tsx (the "Show more"/"Show less" fold and where it
//        places the affordance), app/components/markdown/markdown_code_block,
//        app/components/markdown/markdown_table.
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §10; no
// upstream source copied. This file is this repo's own decomposition (component-map.md §4
// "logic-first"): upstream folds by *measuring rendered height*, which needs a laid-out view; here
// the same reader-facing promise ("a long post must not push a channel into a wall of text") is
// answered by a deterministic rule that runs before layout.
//
// Why a second fold rule (T34 review F6):
//  upstream's "Show more" shortens the *rendered* post, so it works for any shape. A rule that only
//  counted markdown blocks is a no-op for a post that is one block — a pasted 5 000-line log, a
//  40 000-character paragraph, a 500-row table — which is exactly the shape that blows a list up.
//  `shorten` therefore also caps a block *from the inside*: lines for code, characters for prose,
//  rows for tables, items for lists. Every cap is a constant here so a test can pin it.

import Foundation

/// The in-block half of the fold rule: shorten one block that is too tall on its own.
enum MarkdownFold {

    /// How many lines of a single block (code, or a paragraph's hard breaks) a folded post shows.
    static let lineLimit = 20
    /// How many characters of a single block a folded post shows.
    static let characterLimit = 1_200
    /// How many body rows of a table a folded post shows.
    static let tableRowLimit = 5
    /// How many items of a list a folded post shows.
    static let listItemLimit = 8

    struct Shortened: Equatable, Sendable {
        var block: MarkdownBlock
        /// What the reader is not seeing yet — "… 4 980 more lines". Rendered next to the affordance
        /// and read by VoiceOver, so folding never silently hides content.
        var note: String
    }

    /// The visible prefix of `block`, or `nil` when the block already fits both caps.
    static func shorten(_ block: MarkdownBlock) -> Shortened? {
        switch block {
        case .paragraph(let runs):
            return shortenRuns(runs).map { Shortened(block: .paragraph($0.runs), note: $0.note) }
        case .heading(let level, let runs):
            return shortenRuns(runs).map { Shortened(block: .heading(level: level, $0.runs), note: $0.note) }
        case .codeBlock(let language, let code):
            return shortenCode(language: language, code: code)
        case .table(let header, let rows):
            guard rows.count > tableRowLimit else { return nil }
            let kept = Array(rows.prefix(tableRowLimit))
            return Shortened(block: .table(header: header, rows: kept),
                             note: "… \(number(rows.count - kept.count)) more rows")
        case .list(let ordered, let start, let items):
            guard items.count > listItemLimit else {
                // A short list can still hold one enormous item ("1. <40 000 chars>").
                var shortened = items
                for index in items.indices.reversed() {
                    guard let clip = shortenRuns(items[index]) else { continue }
                    shortened[index] = clip.runs
                    return Shortened(block: .list(ordered: ordered, start: start, items: shortened),
                                     note: clip.note)
                }
                return nil
            }
            let kept = items.prefix(listItemLimit).map { shortenRuns($0)?.runs ?? $0 }
            return Shortened(block: .list(ordered: ordered, start: start, items: Array(kept)),
                             note: "… \(number(items.count - listItemLimit)) more items")
        case .blockQuote(let inner):
            // A quote is a container: shorten the first inner block that is itself too tall (a quote
            // of one giant paragraph is the common shape) and leave the rest alone.
            guard block.plainText.count > characterLimit
                    || block.plainText.split(separator: "\n", omittingEmptySubsequences: false).count > lineLimit
            else { return nil }
            var shortened = inner
            for index in inner.indices {
                guard let clip = shorten(inner[index]) else { continue }
                shortened[index] = clip.block
                return Shortened(block: .blockQuote(shortened), note: clip.note)
            }
            return nil
        case .thematicBreak:
            return nil
        }
    }

    // MARK: - Code

    private static func shortenCode(language: String?, code: String) -> Shortened? {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > lineLimit {
            var kept = lines.prefix(lineLimit).joined(separator: "\n")
            // A single line can also be enormous (a minified bundle): cap the characters too, so
            // the horizontal scroll view is not 300 000 points wide.
            if kept.count > characterLimit {
                let hidden = code.count - characterLimit
                kept = String(kept.prefix(characterLimit))
                return Shortened(block: .codeBlock(language: language, code: kept + "\n…"),
                                 note: "… \(number(hidden)) more characters")
            }
            return Shortened(block: .codeBlock(language: language, code: kept + "\n…"),
                             note: "… \(number(lines.count - lineLimit)) more lines")
        }
        if code.count > characterLimit {
            return Shortened(block: .codeBlock(language: language,
                                               code: String(code.prefix(characterLimit)) + "…"),
                             note: "… \(number(code.count - characterLimit)) more characters")
        }
        return nil
    }

    // MARK: - Inline runs

    /// A character/line budget, spent as the run tree is walked.
    private struct Budget {
        var characters: Int
        var lines: Int
    }

    private static func shortenRuns(_ runs: [MarkdownInline]) -> (runs: [MarkdownInline], note: String)? {
        let text = MarkdownInline.plainText(runs)
        let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
        guard text.count > characterLimit || lineCount > lineLimit else { return nil }

        var budget = Budget(characters: characterLimit, lines: lineLimit)
        let (kept, _) = truncate(runs, budget: &budget)
        let keptText = MarkdownInline.plainText(kept)
        let hiddenCharacters = max(0, text.count - keptText.count)
        let hiddenLines = max(0, lineCount - keptText.split(separator: "\n",
                                                           omittingEmptySubsequences: false).count)
        let note = hiddenLines > 0
            ? "… \(number(hiddenLines)) more lines"
            : "… \(number(hiddenCharacters)) more characters"
        // The ellipsis is a separate run so emphasis/link runs stay exactly as the author wrote them
        // (a `**bold**` run never gains a character it did not have).
        return (kept + [.text("…")], note)
    }

    /// Walk `runs`, keeping characters until the budget is spent. Returns the kept runs and whether
    /// anything was dropped.
    private static func truncate(_ runs: [MarkdownInline],
                                 budget: inout Budget) -> ([MarkdownInline], Bool) {
        var output: [MarkdownInline] = []
        for run in runs {
            if budget.characters <= 0 || budget.lines <= 0 { return (output, true) }
            switch run {
            case .text(let value):
                let take = min(value.count, budget.characters)
                output.append(.text(String(value.prefix(take))))
                budget.characters -= take
                if take < value.count { return (output, true) }
            case .code(let value):
                let take = min(value.count, budget.characters)
                output.append(.code(String(value.prefix(take))))
                budget.characters -= take
                if take < value.count { return (output, true) }
            case .emoji(let name):
                output.append(run)
                budget.characters -= name.count + 2
            case .mention(let username):
                output.append(run)
                budget.characters -= username.count + 1
            case .channelLink(let name):
                output.append(run)
                budget.characters -= name.count + 1
            case .lineBreak:
                guard budget.lines > 1 else { return (output, true) }
                output.append(run)
                budget.lines -= 1
                budget.characters -= 1
            case .bold(let inner):
                let (kept, cut) = truncate(inner, budget: &budget)
                if !kept.isEmpty { output.append(.bold(kept)) }
                if cut { return (output, true) }
            case .italic(let inner):
                let (kept, cut) = truncate(inner, budget: &budget)
                if !kept.isEmpty { output.append(.italic(kept)) }
                if cut { return (output, true) }
            case .strikethrough(let inner):
                let (kept, cut) = truncate(inner, budget: &budget)
                if !kept.isEmpty { output.append(.strikethrough(kept)) }
                if cut { return (output, true) }
            case .link(let inner, let url):
                let (kept, cut) = truncate(inner, budget: &budget)
                if !kept.isEmpty { output.append(.link(text: kept, url: url)) }
                if cut { return (output, true) }
            case .image(let alt, let url):
                let take = min(alt.count, max(0, budget.characters))
                output.append(.image(alt: String(alt.prefix(take)), url: url))
                budget.characters -= take
                if take < alt.count { return (output, true) }
            }
        }
        return (output, false)
    }

    // MARK: - Numbers

    /// `4 980` → "4,980", locale-independent so a test can pin the exact note. Not a formatter:
    /// the app's copy is English here (docs/t34-build-note.md §2) and a grouped number reads the same
    /// in every locale this client ships today.
    static func number(_ value: Int) -> String {
        let digits = String(max(0, value))
        guard digits.count > 3 else { return digits }
        var grouped: [String] = []
        var remainder = Array(digits.reversed())
        while remainder.count > 3 {
            grouped.append(String(remainder.prefix(3).reversed()))
            remainder.removeFirst(3)
        }
        grouped.append(String(remainder.reversed()))
        return grouped.reversed().joined(separator: ",")
    }
}
