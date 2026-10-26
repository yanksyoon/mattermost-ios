// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: `app/utils/markdown/index.ts` (`parseSearchTerms`, `convertSearchTermToRegex`, and the
//        `results.tsx`/`post_results` rule that decides between the server's `matches` map and the
//        query's own terms), `app/utils/markdown/markdown.tsx` (the `highlight` prop).
// Licence: Apache-2.0 — the term-splitting and matching rules are reimplemented against that
// behaviour; no upstream source copied. Attribution: docs/THIRD_PARTY_NOTICES.md §16.
//
// Why the client highlights at all: `POST /teams/{id}/posts/search` answers a `matches` map only when
// the search backend computed term matches. Measured on the pinned 9.11.19 server (database backend)
// the field is **absent/null on every query** (`scripts/t39_search_probe.py`), so a result list that
// waited for server-side highlighting would never highlight anything. The upstream rule is used
// instead and in the same order: server `matches` when present and the query has no quoted phrase,
// otherwise the terms the reader typed.

import Foundation

/// One term to highlight, as the query's author meant it.
struct SearchHighlightTerm: Equatable, Hashable, Sendable {
    enum Kind: String, Equatable, Hashable, Sendable {
        /// A plain word: matched on word boundaries.
        case word
        /// `rea*`: a prefix, so the end of the match is not a boundary.
        case prefix
        /// `"exact phrase"`: matched as one run, bounded at both ends.
        case phrase
    }

    var text: String
    var kind: Kind
}

/// Turns a query into the terms to highlight, and finds them in text.
///
/// Everything here is a pure function of its arguments: the same query and the same post always
/// produce the same ranges, which is what lets the unit suite pin the rules (word boundaries,
/// longest-first precedence, CJK, the `*` suffix) without a running app.
enum SearchHighlighter {

    // MARK: Terms

    /// The terms to highlight, longest first (upstream sorts by length so the longest match wins when
    /// two terms overlap).
    ///
    /// Modifiers are dropped (`from:alice` names an author, not text) and so are negated terms
    /// (`-release` means "not this", so highlighting it would point at the wrong thing).
    static func terms(from raw: String) -> [SearchHighlightTerm] {
        let parsed = SearchQueryParser.parse(raw)
        var terms: [SearchHighlightTerm] = []
        for word in parsed.words {
            if word.hasSuffix("*"), word.count > 1 {
                terms.append(SearchHighlightTerm(text: String(word.dropLast()), kind: .prefix))
            } else {
                terms.append(SearchHighlightTerm(text: word, kind: .word))
            }
        }
        for phrase in parsed.phrases where !phrase.isEmpty {
            terms.append(SearchHighlightTerm(text: phrase, kind: .phrase))
        }
        var seen = Set<String>()
        return terms
            .filter { seen.insert($0.text.lowercased()).inserted }
            .sorted { lhs, rhs in
                if lhs.text.count != rhs.text.count { return lhs.text.count > rhs.text.count }
                return lhs.text < rhs.text
            }
    }

    /// The terms for one post's row: the server's own `matches` when it sent any **and** the query has
    /// no quoted phrase (a phrase's parts are not the phrase), otherwise the query's terms.
    static func terms(query: String, serverMatches: [String]?) -> [SearchHighlightTerm] {
        let parsed = SearchQueryParser.parse(query)
        if let serverMatches, !serverMatches.isEmpty, parsed.phrases.isEmpty {
            var seen = Set<String>()
            return serverMatches
                .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
                .map { SearchHighlightTerm(text: $0, kind: $0.hasSuffix("*") ? .prefix : .word) }
                .sorted { lhs, rhs in
                    if lhs.text.count != rhs.text.count { return lhs.text.count > rhs.text.count }
                    return lhs.text < rhs.text
                }
        }
        return terms(from: query)
    }

    // MARK: Matching

    /// Every match of `terms` in `text`, non-overlapping, in document order.
    static func matches(in text: String, terms: [SearchHighlightTerm]) -> [Range<String.Index>] {
        guard !text.isEmpty, !terms.isEmpty else { return [] }
        var candidates: [Range<String.Index>] = []
        for term in terms {
            guard !term.text.isEmpty else { continue }
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let hit = text.range(of: term.text,
                                       options: [.caseInsensitive, .diacriticInsensitive],
                                       range: searchStart..<text.endIndex) {
                if hasValidBoundaries(in: text, range: hit, term: term) {
                    candidates.append(hit)
                }
                let next = text.index(after: hit.lowerBound)
                guard next > searchStart else { break }
                searchStart = next
            }
        }
        return resolveOverlaps(candidates, in: text)
    }

    /// A count, for tests and for the result row's own accessibility value.
    static func matchCount(in text: String, terms: [SearchHighlightTerm]) -> Int {
        matches(in: text, terms: terms).count
    }

    /// Word boundaries: the character before and after the hit must not be a letter or a digit.
    ///
    /// A prefix term has no end boundary (that is what `rea*` means), and a CJK term has no boundaries
    /// at all — Japanese and Chinese are written without spaces, and a boundary test there would never
    /// match. Both rules are upstream's (`convertSearchTermToRegex`'s `cjkPattern` branch).
    static func hasValidBoundaries(in text: String,
                                  range: Range<String.Index>,
                                  term: SearchHighlightTerm) -> Bool {
        if containsCJK(term.text) { return true }
        if range.lowerBound > text.startIndex {
            let before = text[text.index(before: range.lowerBound)]
            if isWordCharacter(before) { return false }
        }
        if term.kind != .prefix, range.upperBound < text.endIndex {
            let after = text[range.upperBound]
            if isWordCharacter(after) { return false }
        }
        return true
    }

    /// Keep the earliest match, and within one start the longest — then skip anything overlapping what
    /// was kept (so `real` and `reality` do not paint the same characters twice).
    static func resolveOverlaps(_ ranges: [Range<String.Index>], in text: String) -> [Range<String.Index>] {
        let ordered = ranges.sorted { lhs, rhs in
            let lhsOffset = text.distance(from: text.startIndex, to: lhs.lowerBound)
            let rhsOffset = text.distance(from: text.startIndex, to: rhs.lowerBound)
            if lhsOffset != rhsOffset { return lhsOffset < rhsOffset }
            return text.distance(from: lhs.lowerBound, to: lhs.upperBound)
                > text.distance(from: rhs.lowerBound, to: rhs.upperBound)
        }
        var kept: [Range<String.Index>] = []
        for range in ordered {
            if let last = kept.last, range.lowerBound < last.upperBound { continue }
            kept.append(range)
        }
        return kept
    }

    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// Whether the text carries CJK ideographs or kana (no word spacing).
    static func containsCJK(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF,   // hiragana + katakana
                 0x3400...0x4DBF,   // CJK extension A
                 0x4E00...0x9FFF,   // CJK unified ideographs
                 0xF900...0xFAFF,   // CJK compatibility
                 0xAC00...0xD7AF:   // hangul syllables
                return true
            default:
                continue
            }
        }
        return false
    }

    // MARK: Attributed text

    /// The same ranges, expressed on an `AttributedString`'s own indices.
    ///
    /// `MarkdownText.attributed` appends its runs in document order, so the plain string of the result
    /// and the attributed string's characters agree character for character — which is why the offsets
    /// taken from the plain string are exact. Highlighting is applied per *paragraph/heading run* by
    /// the renderer, so a term split across a bold boundary is highlighted in the pieces it appears in.
    static func ranges(in attributed: AttributedString,
                       terms: [SearchHighlightTerm]) -> [Range<AttributedString.Index>] {
        let plain = String(attributed.characters)
        return matches(in: plain, terms: terms).compactMap { range in
            let lower = plain.distance(from: plain.startIndex, to: range.lowerBound)
            let upper = plain.distance(from: plain.startIndex, to: range.upperBound)
            guard lower < upper else { return nil }
            let start = attributed.characters.index(attributed.startIndex, offsetBy: lower)
            let end = attributed.characters.index(attributed.startIndex, offsetBy: upper)
            return start..<end
        }
    }
}
