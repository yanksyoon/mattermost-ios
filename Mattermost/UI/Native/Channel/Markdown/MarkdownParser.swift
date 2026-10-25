// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/components/markdown/markdown.tsx, app/components/markdown/transform.ts,
//        @mattermost/commonmark 0.31.2-0 (BSD-2-Clause) — the grammar this parser implements, and
//        app/utils/emoji/helpers.ts (the emoticon table this file mirrors).
// Licence: Apache-2.0 (this file) / BSD-2-Clause (the grammar it implements) — attribution in
// docs/THIRD_PARTY_NOTICES.md §10. No upstream source is copied or transpiled; see MarkdownModel.swift
// for the documented deltas (HTML is literal, link schemes are allow-listed).
//
// Scope, stated so nothing here pretends to be a full CommonMark implementation: ATX headings,
// fenced code, block quotes, flat bullet/ordered lists, GFM tables, thematic breaks, paragraphs, and
// the inline set Mattermost actually renders (emphasis, code spans, links, images, entities,
// emoji names, emoticons, @mentions, ~channel links, autolinks). Setext headings, reference links,
// nested/tight lists, HTML blocks and CommonMark's full label/emphasis-matching rules are **not**
// implemented; that is a documented limit (docs/t34-build-note.md §10), not an accident.

import Foundation

/// A small, allocation-conscious markdown parser: text in, blocks out. Pure and deterministic, so the
/// renderer never needs a network, a main actor or a UI to be tested.
struct MarkdownParser: Sendable {

    /// `@mention` / `~channel` are only recognised when they follow start-of-text or one of these
    /// characters — otherwise `user@example.com` would grow a mention in the middle of an address
    /// (upstream's transform has the same guard).
    private static let boundaryCharacters: Set<Character> = [
        " ", "\t", "\n", "(", "[", "{", "<", "\"", "'", ",", ";", ":", "!", "?", "*", "_", "~", "`",
    ]

    /// The emoticon → emoji-name table, longest first so `:-)` wins over `:)`. Upstream's table is
    /// longer; these are the ones the shell ships, and `docs/t34-build-note.md` §10 records that the
    /// rest fall through as literal text.
    static let emoticons: [(text: String, emoji: String)] = [
        (":-)", "slightly_smiling_face"), (":)", "slightly_smiling_face"),
        (":-D", "smile"), (":D", "smile"),
        (":-(", "slightly_frowning_face"), (":(", "slightly_frowning_face"),
        (";-)", "wink"), (";)", "wink"),
        (":-P", "stuck_out_tongue"), (":P", "stuck_out_tongue"),
        (":-p", "stuck_out_tongue"), (":p", "stuck_out_tongue"),
        (":-/", "confused"), (":/", "confused"),
        (":'(", "cry"),
        (":-O", "open_mouth"), (":O", "open_mouth"),
        ("<3", "heart"),
    ].sorted { $0.text.count > $1.text.count }

    // MARK: - Entry point

    func parse(_ source: String) -> [MarkdownBlock] {
        let cleaned = Self.stripDangerousElements(source)
        let normalised = cleaned
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalised.components(separatedBy: "\n")
        var index = 0
        return parseBlocks(lines, &index)
    }

    // MARK: - Sanitisation

    /// Drop the *contents* of elements that must never reach a renderer, wherever they appear.
    ///
    /// This is a filter, not a sanitiser: nothing is ever parsed as HTML here (see
    /// `MarkdownModel.swift`), so the only thing to remove is payload a human should not have to read
    /// (`<script>` bodies pasted into a post). Everything else stays literal text, which is what makes
    /// "a post can never inject markup" true by construction rather than by matching a block-list.
    static func stripDangerousElements(_ source: String) -> String {
        var result = source
        for tag in ["script", "style", "iframe", "object", "embed", "svg", "math"] {
            result = removingElement(tag, from: result)
        }
        return result
    }

    private static func removingElement(_ tag: String, from source: String) -> String {
        var text = source
        var searchStart = text.startIndex
        while let open = text.range(of: "<\(tag)", options: .caseInsensitive,
                                    range: searchStart..<text.endIndex) {
            let after = open.upperBound
            // `<scripture>` is not `<script>`: require a delimiter after the name.
            if after < text.endIndex, text[after].isLetter || text[after].isNumber {
                searchStart = after
                continue
            }
            guard let close = text.range(of: "</\(tag)>", options: .caseInsensitive,
                                         range: after..<text.endIndex) else {
                text.removeSubrange(open.lowerBound..<text.endIndex)   // unclosed: drop the tail
                return text
            }
            text.removeSubrange(open.lowerBound..<close.upperBound)
            searchStart = open.lowerBound
        }
        return text
    }

    // MARK: - Block level

    private func parseBlocks(_ lines: [String], _ index: inout Int) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }
            if let fence = Self.fenceStart(trimmed) {
                blocks.append(consumeFencedCode(lines, &index, fence: fence))
                continue
            }
            if let heading = Self.heading(trimmed) {
                blocks.append(.heading(level: heading.level, inline(heading.text)))
                index += 1
                continue
            }
            if Self.isThematicBreak(trimmed) {
                blocks.append(.thematicBreak)
                index += 1
                continue
            }
            if trimmed.hasPrefix(">") {
                blocks.append(consumeBlockQuote(lines, &index))
                continue
            }
            if Self.listItem(trimmed) != nil {
                blocks.append(consumeList(lines, &index))
                continue
            }
            if trimmed.contains("|"), index + 1 < lines.count,
               Self.isTableDelimiterRow(lines[index + 1]) {
                blocks.append(consumeTable(lines, &index))
                continue
            }
            blocks.append(consumeParagraph(lines, &index))
        }
        return blocks
    }

    private struct Fence {
        var marker: Character
        var count: Int
        var language: String
    }

    private static func fenceStart(_ trimmed: String) -> Fence? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        var count = 0
        for character in trimmed {
            guard character == first else { break }
            count += 1
        }
        guard count >= 3 else { return nil }
        let info = trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces)
        // A backtick fence's info string may not contain a backtick (CommonMark: it is inline code).
        if first == "`", info.contains("`") { return nil }
        let language = info.split(separator: " ").first.map(String.init) ?? ""
        return Fence(marker: first, count: count, language: language)
    }

    private func consumeFencedCode(_ lines: [String], _ index: inout Int, fence: Fence) -> MarkdownBlock {
        index += 1
        var body: [String] = []
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            var run = 0
            for character in trimmed {
                guard character == fence.marker else { break }
                run += 1
            }
            if run >= fence.count, trimmed.dropFirst(run).trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                break
            }
            body.append(lines[index])
            index += 1
        }
        return .codeBlock(language: fence.language.isEmpty ? nil : fence.language.lowercased(),
                          code: body.joined(separator: "\n"))
    }

    private static func heading(_ trimmed: String) -> (level: Int, text: String)? {
        guard trimmed.first == "#" else { return nil }
        var level = 0
        for character in trimmed {
            guard character == "#" else { break }
            level += 1
        }
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.first == " " || rest.isEmpty else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // CommonMark's optional closing sequence: `## title ##`.
        while text.hasSuffix("#") { text.removeLast() }
        return (level, text.trimmingCharacters(in: .whitespaces))
    }

    private static func isThematicBreak(_ trimmed: String) -> Bool {
        guard let first = trimmed.first, "-*_".contains(first) else { return false }
        let stripped = trimmed.filter { $0 != " " && $0 != "\t" }
        return stripped.count >= 3 && stripped.allSatisfy { $0 == first }
    }

    private func consumeBlockQuote(_ lines: [String], _ index: inout Int) -> MarkdownBlock {
        var inner: [String] = []
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(">") else { break }
            var content = trimmed.dropFirst()
            if content.first == " " { content = content.dropFirst() }
            inner.append(String(content))
            index += 1
        }
        var nested = 0
        return .blockQuote(parseBlocks(inner, &nested))
    }

    private static func listItem(_ trimmed: String) -> (ordered: Bool, number: Int, text: String)? {
        guard let first = trimmed.first else { return nil }
        if "-*+".contains(first) {
            let rest = trimmed.dropFirst()
            guard rest.first == " " || rest.isEmpty else { return nil }
            let text = rest.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return (false, 1, text)
        }
        var digits = ""
        var rest = trimmed[...]
        while let character = rest.first, character.isNumber {
            digits.append(character)
            rest = rest.dropFirst()
        }
        guard !digits.isEmpty, let marker = rest.first, marker == "." || marker == ")" else { return nil }
        rest = rest.dropFirst()
        guard rest.first == " " || rest.isEmpty else { return nil }
        return (true, Int(digits) ?? 1, String(rest).trimmingCharacters(in: .whitespaces))
    }

    private func consumeList(_ lines: [String], _ index: inout Int) -> MarkdownBlock {
        var items: [[MarkdownInline]] = []
        var ordered = false
        var start = 1
        var first = true
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard let item = Self.listItem(trimmed) else { break }
            if first {
                ordered = item.ordered
                start = item.number
                first = false
            }
            // A list of one kind does not swallow the other kind: `- a` then `1. b` is two lists.
            guard item.ordered == ordered else { break }
            var text = item.text
            index += 1
            // Indented continuation lines belong to this item; a blank line ends the list.
            while index < lines.count {
                let next = lines[index]
                let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                if nextTrimmed.isEmpty { break }
                guard next.first == " " || next.first == "\t" else { break }
                guard Self.listItem(nextTrimmed) == nil else { break }
                text += " " + nextTrimmed
                index += 1
            }
            items.append(inline(text))
        }
        return .list(ordered: ordered, start: start, items: items)
    }

    private static func isTableDelimiterRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-") else { return false }
        let cells = splitTableRow(trimmed)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            var body = cell.trimmingCharacters(in: .whitespaces)
            if body.hasPrefix(":") { body.removeFirst() }
            if body.hasSuffix(":") { body.removeLast() }
            return !body.isEmpty && body.allSatisfy { $0 == "-" }
        }
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in line {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                current.append(character)
                continue
            }
            if character == "|" {
                cells.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        cells.append(current)
        // Leading/trailing pipes produce empty first/last cells: they are decoration, not columns.
        if let first = cells.first, first.trimmingCharacters(in: .whitespaces).isEmpty { cells.removeFirst() }
        if let last = cells.last, last.trimmingCharacters(in: .whitespaces).isEmpty { cells.removeLast() }
        return cells
    }

    private func consumeTable(_ lines: [String], _ index: inout Int) -> MarkdownBlock {
        func cells(_ line: String) -> [MarkdownCell] {
            Self.splitTableRow(line).map { cell in
                inline(cell.trimmingCharacters(in: .whitespaces))
            }
        }
        let header = cells(lines[index])
        index += 2       // header + delimiter row
        var rows: [[MarkdownCell]] = []
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.contains("|") else { break }
            var normalised: [MarkdownCell] = Array(cells(line).prefix(max(1, header.count)))
            // A row with the wrong width is padded/truncated to the header: a table can never draw a
            // ragged column set (which is what would break a `Grid`'s column count).
            while normalised.count < header.count { normalised.append([MarkdownInline.text("")]) }
            rows.append(normalised)
            index += 1
        }
        return .table(header: header, rows: rows)
    }

    private func consumeParagraph(_ lines: [String], _ index: inout Int) -> MarkdownBlock {
        var body: [String] = []
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { break }
            if !body.isEmpty,
               Self.fenceStart(trimmed) != nil || Self.heading(trimmed) != nil
                || Self.isThematicBreak(trimmed) || trimmed.hasPrefix(">")
                || Self.listItem(trimmed) != nil {
                break
            }
            body.append(trimmed)
            index += 1
        }
        return .paragraph(inline(body.joined(separator: "\n")))
    }

    // MARK: - Inline level

    func inline(_ text: String) -> [MarkdownInline] {
        var characters = Array(text)
        var position = 0
        return parseInline(&characters, &position)
    }

    /// One pass over the inline text. Emphasis and link labels recurse; nothing else does, so depth is
    /// bounded by nesting the author wrote.
    private func parseInline(_ characters: inout [Character], _ position: inout Int) -> [MarkdownInline] {
        var runs: [MarkdownInline] = []
        var buffer = ""

        func flushText() {
            guard !buffer.isEmpty else { return }
            runs.append(.text(buffer))
            buffer = ""
        }

        while position < characters.count {
            let character = characters[position]

            switch character {
            case "\\":
                if position + 1 < characters.count {
                    let next = characters[position + 1]
                    if next.isPunctuation || next.isWhitespace || next.isSymbol {
                        buffer.append(next)
                        position += 2
                        continue
                    }
                }
                buffer.append(character)
                position += 1

            case "`":
                if let span = consumeCodeSpan(characters, position) {
                    flushText()
                    runs.append(.code(span.code))
                    position = span.end
                } else {
                    buffer.append(character)
                    position += 1
                }

            case "*", "_":
                let doubled = position + 1 < characters.count && characters[position + 1] == character
                if doubled, let emphasis = consumeEmphasis(characters, position, marker: character,
                                                           markers: 2) {
                    flushText()
                    runs.append(.bold(emphasis.runs))
                    position = emphasis.end
                } else if let emphasis = consumeEmphasis(characters, position, marker: character,
                                                          markers: 1) {
                    flushText()
                    runs.append(.italic(emphasis.runs))
                    position = emphasis.end
                } else {
                    buffer.append(character)
                    position += 1
                }

            case "~":
                if position + 1 < characters.count, characters[position + 1] == "~",
                   let strike = consumeEmphasis(characters, position, marker: "~", markers: 2) {
                    flushText()
                    runs.append(.strikethrough(strike.runs))
                    position = strike.end
                    continue
                }
                if let link = consumeChannelLink(characters, position, buffer: buffer) {
                    flushText()
                    runs.append(.channelLink(name: link.name))
                    position = link.end
                } else {
                    buffer.append(character)
                    position += 1
                }

            case "!":
                if let image = consumeImage(characters, position) {
                    flushText()
                    runs.append(.image(alt: image.alt, url: image.url))
                    position = image.end
                } else {
                    buffer.append(character)
                    position += 1
                }

            case "[":
                if let link = consumeLink(characters, position) {
                    flushText()
                    // A disallowed scheme yields `url == ""`: the label renders as plain text, so no
                    // tap target exists to hand a hostile string to the URL opener.
                    runs.append(.link(text: link.text, url: link.url))
                    position = link.end
                } else {
                    buffer.append(character)
                    position += 1
                }

            case "<":
                if let emoticon = consumeEmoticon(characters, position) {
                    // `<3` is a heart in Mattermost's emoticon table; it must be read before the
                    // autolink branch, which would otherwise treat it as a tag-ish token.
                    flushText()
                    runs.append(.emoji(name: emoticon.emoji))
                    position = emoticon.end
                } else if let autolink = consumeAutolink(characters, position) {
                    flushText()
                    runs.append(autolink.inline)
                    position = autolink.end
                } else {
                    // An HTML tag is *literal text*. It is never handed to a markup parser, so it
                    // can neither render nor execute; the characters simply reach the screen.
                    buffer.append(character)
                    position += 1
                }

            case "&":
                if let decoded = consumeEntity(characters, position) {
                    buffer.append(decoded.text)
                    position = decoded.end
                } else {
                    buffer.append(character)
                    position += 1
                }

            case ":":
                if let emoticon = consumeEmoticon(characters, position) {
                    flushText()
                    runs.append(.emoji(name: emoticon.emoji))
                    position = emoticon.end
                } else if let emoji = consumeEmojiName(characters, position) {
                    flushText()
                    runs.append(.emoji(name: emoji.name))
                    position = emoji.end
                } else {
                    buffer.append(character)
                    position += 1
                }

            case "@":
                if Self.isBoundary(buffer: buffer), let mention = consumeMention(characters, position) {
                    flushText()
                    runs.append(.mention(username: mention.name))
                    position = mention.end
                } else {
                    buffer.append(character)
                    position += 1
                }

            case "h", "w":
                if Self.isBoundary(buffer: buffer), let url = consumeBareURL(characters, position) {
                    flushText()
                    runs.append(.link(text: [.text(url.display)], url: url.target))
                    position = url.end
                } else {
                    buffer.append(character)
                    position += 1
                }

            case "\n":
                flushText()
                runs.append(.lineBreak)
                position += 1

            default:
                buffer.append(character)
                position += 1
            }
        }
        flushText()
        return runs
    }

    // MARK: - Inline consumers

    private func consumeCodeSpan(_ characters: [Character], _ start: Int) -> (code: String, end: Int)? {
        var ticks = 0
        while start + ticks < characters.count, characters[start + ticks] == "`" { ticks += 1 }
        guard ticks > 0 else { return nil }
        var index = start + ticks
        while index < characters.count {
            var run = 0
            while index + run < characters.count, characters[index + run] == "`" { run += 1 }
            if run == ticks {
                var content = String(characters[(start + ticks)..<index])
                if content.hasPrefix(" "), content.hasSuffix(" "), content.count > 1 {
                    content.removeFirst()
                    content.removeLast()
                }
                return (content, index + run)
            }
            index += max(1, run)
        }
        return nil
    }

    private func consumeEmphasis(_ characters: [Character], _ start: Int, marker: Character,
                                 markers: Int) -> (runs: [MarkdownInline], end: Int)? {
        let contentStart = start + markers
        guard contentStart < characters.count else { return nil }
        // Emphasis cannot open on whitespace; `_` inside a word is not emphasis (snake_case names).
        if characters[contentStart].isWhitespace { return nil }
        if marker == "_", start > 0,
           characters[start - 1].isLetter || characters[start - 1].isNumber {
            return nil
        }
        var cursor = contentStart
        while cursor < characters.count {
            if characters[cursor] == "\\" {
                cursor += 2
                continue
            }
            if characters[cursor] == marker {
                var run = 0
                while cursor + run < characters.count, characters[cursor + run] == marker { run += 1 }
                // A longer run closes the *innermost* span first: in `**bold *and italic***` the
                // three closing stars close the italic and then the bold, so a nested span is not
                // swallowed whole (commonmark's rule, and what the web app renders).
                let closeAt = cursor + run - markers
                if run >= markers, closeAt > contentStart, !characters[closeAt - 1].isWhitespace {
                    var inner = Array(characters[contentStart..<closeAt])
                    var innerPosition = 0
                    let runs = parseInline(&inner, &innerPosition)
                    return (runs, min(cursor + run, characters.count))
                }
                cursor += run
                continue
            }
            if characters[cursor] == "\n" { return nil }       // emphasis does not span paragraphs
            cursor += 1
        }
        return nil
    }

    private func consumeChannelLink(_ characters: [Character], _ start: Int,
                                    buffer: String) -> (name: String, end: Int)? {
        guard Self.isBoundary(buffer: buffer) else { return nil }
        var index = start + 1
        var name = ""
        while index < characters.count {
            let character = characters[index]
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                name.append(character)
                index += 1
            } else {
                break
            }
        }
        guard let first = name.first, first.isLetter || first.isNumber else { return nil }
        return (name, index)
    }

    private func consumeImage(_ characters: [Character], _ start: Int) -> (alt: String, url: String, end: Int)? {
        guard start + 1 < characters.count, characters[start + 1] == "[" else { return nil }
        guard let close = findClosing(characters, from: start + 2, open: "[", close: "]"),
              close + 1 < characters.count, characters[close + 1] == "(",
              let paren = findClosing(characters, from: close + 2, open: "(", close: ")") else { return nil }
        let alt = String(characters[(start + 2)..<close])
        let raw = String(characters[(close + 2)..<paren]).trimmingCharacters(in: .whitespaces)
        return (alt, Self.sanitisedURL(raw) ?? "", paren + 1)
    }

    private func consumeLink(_ characters: [Character], _ start: Int)
        -> (text: [MarkdownInline], url: String, end: Int)? {
        guard let close = findClosing(characters, from: start + 1, open: "[", close: "]"),
              close + 1 < characters.count, characters[close + 1] == "(",
              let paren = findClosing(characters, from: close + 2, open: "(", close: ")") else { return nil }
        var inner = Array(characters[(start + 1)..<close])
        var position = 0
        let text = parseInline(&inner, &position)
        let raw = String(characters[(close + 2)..<paren]).trimmingCharacters(in: .whitespaces)
        // `[label](url "title")`: drop the optional title.
        let url = raw.split(separator: " ").first.map(String.init) ?? raw
        return (text, Self.sanitisedURL(url) ?? "", paren + 1)
    }

    private func findClosing(_ characters: [Character], from start: Int,
                             open: Character, close: Character) -> Int? {
        var depth = 1
        var index = start
        while index < characters.count {
            let character = characters[index]
            if character == "\\" {
                index += 2
                continue
            }
            if character == open { depth += 1 }
            if character == close {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    private func consumeAutolink(_ characters: [Character], _ start: Int)
        -> (inline: MarkdownInline, end: Int)? {
        guard let end = findClosing(characters, from: start + 1, open: "<", close: ">") else { return nil }
        let inner = String(characters[(start + 1)..<end])
        guard let url = Self.sanitisedURL(inner, allowRelative: false) else { return nil }
        return (.link(text: [.text(inner)], url: url), end + 1)
    }

    private func consumeEntity(_ characters: [Character], _ start: Int) -> (text: String, end: Int)? {
        var index = start + 1
        var name = ""
        while index < characters.count, characters[index] != ";", name.count < 10 {
            name.append(characters[index])
            index += 1
        }
        guard index < characters.count, characters[index] == ";" else { return nil }
        if let decoded = Self.namedEntities[name] { return (decoded, index + 1) }
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value: UInt32?
            if digits.first == "x" || digits.first == "X" {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits)
            }
            if let value, let scalar = Unicode.Scalar(value) {
                return (String(Character(scalar)), index + 1)
            }
        }
        return nil
    }

    private func consumeEmoticon(_ characters: [Character], _ start: Int) -> (emoji: String, end: Int)? {
        for entry in Self.emoticons {
            let length = entry.text.count
            guard start + length <= characters.count else { continue }
            if String(characters[start..<(start + length)]) == entry.text {
                return (entry.emoji, start + length)
            }
        }
        return nil
    }

    private func consumeEmojiName(_ characters: [Character], _ start: Int) -> (name: String, end: Int)? {
        var index = start + 1
        var name = ""
        while index < characters.count {
            let character = characters[index]
            if character.isLetter || character.isNumber
                || character == "_" || character == "+" || character == "-" {
                name.append(character)
                index += 1
                continue
            }
            break
        }
        guard !name.isEmpty, index < characters.count, characters[index] == ":" else { return nil }
        return (name, index + 1)
    }

    private func consumeMention(_ characters: [Character], _ start: Int) -> (name: String, end: Int)? {
        var index = start + 1
        var name = ""
        while index < characters.count {
            let character = characters[index]
            if character.isLetter || character.isNumber
                || character == "." || character == "_" || character == "-" {
                name.append(character)
                index += 1
                continue
            }
            break
        }
        // Trailing punctuation belongs to the sentence, not the handle (`@opsbot.`).
        while let last = name.last, last == "." || last == "-" || last == "_" {
            name.removeLast()
            index -= 1
        }
        guard let first = name.first, first.isLetter || first.isNumber else { return nil }
        return (name, index)
    }

    private func consumeBareURL(_ characters: [Character], _ start: Int)
        -> (display: String, target: String, end: Int)? {
        let remaining = String(characters[start...]).lowercased()
        let prefix: String
        if remaining.hasPrefix("https://") { prefix = "https://" }
        else if remaining.hasPrefix("http://") { prefix = "http://" }
        else if remaining.hasPrefix("www.") { prefix = "www." }
        else { return nil }
        var end = start + prefix.count
        while end < characters.count, !characters[end].isWhitespace,
              characters[end] != "<", characters[end] != ">" {
            if "),.;:!?'\"".contains(characters[end]) {
                let rest = String(characters[(end + 1)...])
                if rest.isEmpty || rest.first!.isWhitespace || rest.first! == "<" { break }
                if characters[end] == ")" {
                    let urlPart = String(characters[start..<end])
                    let opens = urlPart.filter { $0 == "(" }.count
                    let closes = urlPart.filter { $0 == ")" }.count
                    if closes >= opens { break }
                }
            }
            end += 1
        }
        let display = String(characters[start..<end])
        guard display.count > prefix.count else { return nil }
        let target = prefix == "www." ? "https://" + display : display
        guard Self.sanitisedURL(target) != nil else { return nil }
        return (display, target, end)
    }

    private static func isBoundary(buffer: String) -> Bool {
        guard let last = buffer.last else { return true }
        return boundaryCharacters.contains(last)
    }

    /// The allow-list. A link this client will not open is not a link at all.
    ///
    /// - Parameter allowRelative: same-server absolute paths (`/channels/…`) are links inside a post
    ///   body; they are *never* accepted for an autolink (`<...>`), where `/b` would otherwise turn a
    ///   literal HTML close tag into a tap target.
    static func sanitisedURL(_ raw: String, allowRelative: Bool = true) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        // Control characters are how a `java\nscript:` bypass is built; refuse the string outright.
        if trimmed.unicodeScalars.contains(where: { $0.value < 0x20 }) { return nil }
        for scheme in ["http://", "https://", "mailto:"] where lower.hasPrefix(scheme) {
            return trimmed
        }
        // Absolute paths are same-server links, not schemes.
        if allowRelative, trimmed.hasPrefix("/"), !trimmed.hasPrefix("//") { return trimmed }
        return nil
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "copy": "©", "reg": "®", "hellip": "…", "mdash": "—", "ndash": "–", "laquo": "«",
        "raquo": "»", "trade": "™",
    ]
}
